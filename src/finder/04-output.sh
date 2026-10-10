###############################################################################
# 7. Rendering
###############################################################################

json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

csv_escape() { # VALUE DELIMITER
    local v="${1-}" d="${2:-,}"
    case "$v" in
        *"$d"* | *'"'* | *$'\n'* | *$'\r'*) printf '"%s"' "${v//\"/\"\"}" ;;
        *) printf '%s' "$v" ;;
    esac
}

# emit_result: write the site list in the requested format.
# `paths` (the default) writes one absolute path per line, which is exactly what
# Bash_WP-CLI_Update.sh consumes; the other formats are for humans and tooling.
emit_result() { # < NUL-separated sorted list
    local site owner group mtime version dbname first=1 d cell out
    local -a row=() hdr=(path owner group modified wp_version db_name)
    case "$OUTPUT_FORMAT" in
        tsv) d=$'\t' ;;
        csv) d="${DELIMITER:-,}" ;;
        *) d=$'\t' ;;
    esac
    case "$OUTPUT_FORMAT" in
        json)
            printf '['
            ;;
        tsv | csv)
            out=''
            for cell in "${hdr[@]}"; do
                if [ "$OUTPUT_FORMAT" = 'csv' ]; then
                    out+="${out:+$d}$(csv_escape "$cell" "$d")"
                else
                    out+="${out:+$d}${cell}"
                fi
            done
            printf '%s\n' "$out"
            ;;
    esac
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='<unknown>'
        group="$(stat -c '%G' -- "$site" 2>/dev/null)" || group='<unknown>'
        mtime="$(stat -c '%y' -- "$site" 2>/dev/null)" || mtime='<unknown>'
        mtime="${mtime%%.*}"
        version="$(wp_version_of "$site")" || version=''
        dbname="$(db_name_of "$site")" || dbname=''
        case "$OUTPUT_FORMAT" in
            paths)
                # --print0 exists for the next program in the pipeline: a site
                # path may legally contain a newline, and a line-oriented list
                # silently drops that site, which for a maintenance tool means
                # "this one is never updated and nothing says so".
                if [ "$PRINT_NUL" = 'true' ]; then
                    printf '%s\0' "$site"
                else
                    printf '%s\n' "$site"
                fi
                ;;
            json)
                ((first)) || printf ','
                first=0
                printf '{"path":"%s","owner":"%s","group":"%s","modified":"%s","wp_version":"%s","db_name":"%s"}' \
                    "$(json_escape "$site")" "$(json_escape "$owner")" "$(json_escape "$group")" \
                    "$(json_escape "$mtime")" "$(json_escape "$version")" "$(json_escape "$dbname")"
                ;;
            *)
                row=("$site" "$owner" "$group" "$mtime" "$version" "$dbname")
                out=''
                for cell in "${row[@]}"; do
                    if [ "$OUTPUT_FORMAT" = 'csv' ]; then
                        out+="${out:+$d}$(csv_escape "$cell" "$d")"
                    else
                        out+="${out:+$d}${cell}"
                    fi
                done
                printf '%s\n' "$out"
                ;;
        esac
    done
    [ "$OUTPUT_FORMAT" = 'json' ] && printf ']\n'
    return 0
}

# write_output: atomic replace, so a reader never sees a half-written list.
# The list arrives on stdin; the destination is the global OUTPUT_FILE. Taking
# the destination as $1 looked tidier but silently produced an empty target,
# because a caller writing `write_output <"$SORTED_FILE"` passes no arguments.
write_output() { # < NUL-separated sorted list
    local target="$OUTPUT_FILE" tmp dir
    if [ "$target" = '-' ]; then
        emit_result
        return 0
    fi
    dir="$(dirname -- "$target")"
    if [ ! -d "$dir" ]; then
        mkdir -p -- "$dir" 2>/dev/null || {
            log_error "cannot create the output directory: ${dir}"
            return 1
        }
    fi
    make_tmp output || return 1
    tmp="$TMP_LAST"
    if ! emit_result >"$tmp"; then
        log_error "cannot render the result"
        return 1
    fi
    # Preserve the permissions of an existing list: cron may read it as another
    # user, and a fresh 0600 file would break that silently.
    if [ -f "$target" ]; then
        chmod --reference="$target" "$tmp" 2>/dev/null
        chown --reference="$target" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp" 2>/dev/null
    fi
    if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
        log_error "cannot write the output file: ${target}"
        return 1
    fi
    return 0
}

# A human-readable table on stderr, so it never pollutes a piped result.
print_table() { # < NUL-separated sorted list
    [ "$QUIET" = 'true' ] && return 0
    local site owner mtime version
    printf '%s\n' "${C_BOLD}PATH                                        OWNER           WP VERSION  MODIFIED${C_RESET}" >&2
    printf '%s\n' "${C_DIM}-----------------------------------------------------------------------------------${C_RESET}" >&2
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='?'
        mtime="$(stat -c '%y' -- "$site" 2>/dev/null)" || mtime='?'
        version="$(wp_version_of "$site")" || version='-'
        printf '%-44s %-15s %-11s %s\n' "$site" "$owner" "${version:--}" "${mtime%%.*}" >&2
    done
    return 0
}

# --skip-existing: drop sites that are already in the current list. Used to grow
# an inventory without re-processing what is already there.
filter_existing() { # LIST_FILE < NUL list
    local list="${1:-}" site
    [ -f "$list" ] || { cat; return 0; }
    local -A seen=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"          # CR only: a trailing space is part of a path
        case "$line" in '' | '#'*) continue ;; esac
        seen["$line"]=1
    done <"$list"
    while IFS= read -r -d '' site; do
        if [ -n "${seen[$site]-}" ]; then
            SKIPPED_DUPLICATE=$((SKIPPED_DUPLICATE + 1))
            continue
        fi
        printf '%s\0' "$site"
    done
}

###############################################################################
# 8. --status: report on the list that already exists, without scanning
###############################################################################

status_report() {
    local list="${1:-}" site owner version count=0
    if [ ! -f "$list" ]; then
        log_info "no site list at ${list} yet"
        return 0
    fi
    printf '%s\n' "${C_BOLD}site list${C_RESET}  ${list}" >&2
    printf '%s\n' "${C_BOLD}size${C_RESET}       $(stat -c '%s bytes, modified %y' -- "$list" 2>/dev/null)" >&2
    printf '%s\n' "${C_BOLD}PATH                                        OWNER           WP VERSION${C_RESET}" >&2
    while IFS= read -r site || [ -n "$site" ]; do
        site="${site%$'\r'}"          # CR only: a trailing space is part of a path
        case "$site" in '' | '#'*) continue ;; esac
        count=$((count + 1))
        if [ ! -d "$site" ]; then
            printf '%-44s %s\n' "$site" "${C_RED}<missing>${C_RESET}" >&2
            continue
        fi
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='?'
        version="$(wp_version_of "$site")" || version='-'
        printf '%-44s %-15s %s\n' "$site" "$owner" "${version:--}" >&2
    done <"$list"
    printf '%s\n' "${C_BOLD}entries${C_RESET}    ${count}" >&2
    return 0
}

###############################################################################
# 8b. NUL-separated output, manifest, audit, list verification
###############################################################################

# emit_paths_nul < NUL-separated sorted list
#
# For the next program in a pipeline. A site path may legally contain a newline,
# and a list that cannot represent one is a list that silently drops a site --
# which for a maintenance tool means "this one never gets updated, and nothing
# says so".
emit_paths_nul() {
    local site
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        printf '%s\0' "$site"
    done
    return 0
}

# manifest_headers -> the column list, honouring --fields
MANIFEST_ALL_FIELDS='path owner group mode config_mode wp_version db_name multisite opt_out modified'
manifest_headers() {
    local list="${FIELD_LIST:-$MANIFEST_ALL_FIELDS}"
    printf '%s' "${list//,/ }"
}

# manifest_value FIELD SITE -> one cell
manifest_value() { # FIELD SITE
    local field="$1" site="$2" cfg v
    case "$field" in
        path) printf '%s' "$site" ;;
        owner) stat -c '%U' -- "$site" 2>/dev/null || printf '?' ;;
        group) stat -c '%G' -- "$site" 2>/dev/null || printf '?' ;;
        mode) stat -c '%a' -- "$site" 2>/dev/null || printf '?' ;;
        config_mode)
            cfg="$(finder_config_path "$site")"
            [ -n "$cfg" ] && { stat -c '%a' -- "$cfg" 2>/dev/null || printf '?'; } || printf '?'
            ;;
        wp_version) wp_version_of "$site" 2>/dev/null || printf '' ;;
        db_name) db_name_of "$site" 2>/dev/null || printf '' ;;
        multisite) is_multisite "$site" && printf 'yes' || printf 'no' ;;
        opt_out) [ -e "${site}/${OPT_OUT_MARKER}" ] && printf 'yes' || printf 'no' ;;
        modified)
            v="$(stat -c '%y' -- "$site" 2>/dev/null)"
            printf '%s' "${v%%.*}"
            ;;
        *) printf '' ;;
    esac
    return 0
}

# finder_config_path SITE -> the wp-config.php for this site, empty when absent.
# WordPress allows it one level up; an inventory that reports "no config" for a
# correctly installed site is an inventory nobody trusts.
finder_config_path() { # SITE
    local site="${1-}"
    if [ -f "${site}/wp-config.php" ]; then
        printf '%s' "${site}/wp-config.php"
        return 0
    fi
    local up
    up="$(dirname -- "$site")"
    if [ -f "${up}/wp-config.php" ]; then
        printf '%s' "${up}/wp-config.php"
        return 0
    fi
    return 1
}

# write_manifest < NUL-separated sorted list
#
# The site list the manager consumes is deliberately dumb: one path per line.
# Everything else an operator wants to know about the fleet -- who owns it, which
# WordPress it runs, which database, whether it is a multisite, whether its
# wp-config.php is world-readable -- belongs in a manifest, because it changes
# more often than the list and is read by different tools.
write_manifest() { # < NUL list
    local target="$MANIFEST_FILE"
    [ -n "$target" ] || { cat >/dev/null; return 0; }
    local tmp dir
    local -a fields=()
    read -r -a fields <<<"$(manifest_headers)"
    if [ "$target" != '-' ]; then
        dir="$(dirname -- "$target")"
        if [ ! -d "$dir" ]; then
            mkdir -p -- "$dir" 2>/dev/null || {
                log_error "cannot create the manifest directory: ${dir}"
                cat >/dev/null
                return 1
            }
        fi
        make_tmp manifest || { cat >/dev/null; return 1; }
        tmp="$TMP_LAST"
    else
        tmp=''
    fi
    _manifest_render "$tmp" "${fields[@]}"
    local rc=$?
    if [ "$target" != '-' ]; then
        if [ -f "$target" ]; then
            chmod --reference="$target" "$tmp" 2>/dev/null
            chown --reference="$target" "$tmp" 2>/dev/null
        else
            chmod 640 "$tmp" 2>/dev/null
        fi
        if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
            log_error "cannot write the manifest: ${target}"
            return 1
        fi
        log_ok "manifest written to ${target} (${MANIFEST_FORMAT})"
    fi
    return "$rc"
}

# _manifest_render DEST FIELDS... < NUL list
#
# DEST may be empty, which means stdout. Redirecting to /dev/stdout instead is
# not portable: the name is a symlink to /proc/self/fd/1, so it vanishes in a
# chroot without /proc, is missing on some minimal images, and fails with ENXIO
# when fd 1 is a socket. An empty destination means "do not redirect at all".
_manifest_render() { # DEST FIELDS...
    local dest="${1-}"; shift
    local -a fields=("$@")
    local site f out first cell
    _manifest_body() {
        case "$MANIFEST_FORMAT" in
            json) printf '[' ;;
            *)
                out=''
                for f in ${fields[@]+"${fields[@]}"}; do
                    if [ "$MANIFEST_FORMAT" = 'csv' ]; then
                        out+="${out:+,}$(csv_escape "$f" ',')"
                    else
                        out+="${out:+$'\t'}${f}"
                    fi
                done
                printf '%s\n' "$out"
                ;;
        esac
        first=1
        while IFS= read -r -d '' site; do
            [ -n "$site" ] || continue
            case "$MANIFEST_FORMAT" in
                json)
                    ((first)) || printf ','
                    first=0
                    printf '{'
                    local jfirst=1
                    for f in ${fields[@]+"${fields[@]}"}; do
                        ((jfirst)) || printf ','
                        jfirst=0
                        printf '"%s":"%s"' "$(json_escape "$f")" \
                            "$(json_escape "$(manifest_value "$f" "$site")")"
                    done
                    printf '}'
                    ;;
                csv)
                    out=''
                    for f in ${fields[@]+"${fields[@]}"}; do
                        cell="$(manifest_value "$f" "$site")"
                        out+="${out:+,}$(csv_escape "$cell" ',')"
                    done
                    printf '%s\n' "$out"
                    ;;
                *)
                    out=''
                    for f in ${fields[@]+"${fields[@]}"}; do
                        cell="$(manifest_value "$f" "$site")"
                        # A tab inside a value would invent a column; nothing a
                        # stat(1) or a version.php can contain legitimately needs one.
                        out+="${out:+$'\t'}${cell//$'\t'/ }"
                    done
                    printf '%s\n' "$out"
                    ;;
            esac
        done
        [ "$MANIFEST_FORMAT" = 'json' ] && printf ']\n'
    }
    if [ -n "$dest" ]; then
        _manifest_body >"$dest"
    else
        _manifest_body
    fi
    return 0
}

# audit_site SITE : permission and hygiene findings for one installation.
#
# Discovery already walks the tree and already opens wp-config.php for the
# database name, so reporting what it sees costs nothing extra -- and the finding
# that matters most on a shared host (a 0644 wp-config.php next door to every
# other account) is exactly the one nobody looks for until after the incident.
audit_site() { # SITE
    local site="$1" cfg mode='' findings=0
    cfg="$(finder_config_path "$site")"
    if [ -z "$cfg" ]; then
        log_warn "${site}: no wp-config.php found in the site root or one level up"
        AUDIT_FINDINGS=$((AUDIT_FINDINGS + 1))
        return 0
    fi
    mode="$(stat -c '%a' -- "$cfg" 2>/dev/null)"
    if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
        # Bit arithmetic, not digit eyeballing: 0640 is the *recommended* mode
        # (group-read for the web server), and a check that flags it teaches the
        # operator to ignore the audit. What matters is other-read (the last
        # digit's 4-bit) and any group/other write (mask 022).
        local m=$((8#${mode}))
        if ((m & 8#022)); then
            log_warn "${cfg}: writable by group or others (mode ${mode}); anybody in that group can replace the site's code. chmod 0640"
            findings=$((findings + 1))
        elif ((m & 8#004)); then
            # World-readable wp-config.php: on a shared host this hands the
            # database credentials to every other account.
            log_warn "${cfg}: world-readable (mode ${mode}); it holds the database credentials. chmod 0640"
            findings=$((findings + 1))
        fi
    fi
    local owner
    owner="$(stat -c '%U' -- "$site" 2>/dev/null)"
    if [ "$owner" = 'root' ]; then
        log_info "${site}: owned by root; a maintenance run will use root for WP-CLI unless the site list names another owner"
    fi
    if [ -d "${site}/wp-content/uploads" ]; then
        local n=0
        n="$(find "${site}/wp-content/uploads" -maxdepth 3 -type f -name '*.php' -print 2>/dev/null | head -n 5 | wc -l)"
        n="${n//[^0-9]/}"
        if ((${n:-0} > 0)); then
            log_warn "${site}: ${n} PHP file(s) inside wp-content/uploads; this is the most common backdoor location"
            findings=$((findings + 1))
        fi
    fi
    AUDIT_FINDINGS=$((AUDIT_FINDINGS + findings))
    return 0
}

# verify_list FILE : report on a site list that already exists.
#
# The list is the input to every maintenance run, and it rots: a site is deleted,
# a directory is renamed, a disk is remounted. Without this check the symptom is
# "skipped, not a directory" repeated in a log nobody reads. With it, one command
# answers "is my inventory still true?".
verify_list() { # FILE
    local list="${1-}" line site count=0 missing=0 notwp=0 opted=0 ok=0
    if [ ! -f "$list" ]; then
        log_error "no such site list: ${list}"
        return 1
    fi
    printf '\n%s== verifying %s ==%s\n' "$C_BOLD" "$list" "$C_RESET" >&2
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in '' | '#'*) continue ;; esac
        site="${line%%$'\t'*}"
        count=$((count + 1))
        if [ ! -d "$site" ]; then
            printf '  %sMISSING%s   %s\n' "$C_RED" "$C_RESET" "$site" >&2
            missing=$((missing + 1))
            continue
        fi
        if [ -e "${site}/${OPT_OUT_MARKER}" ]; then
            printf '  %sOPTED-OUT%s %s\n' "$C_YELLOW" "$C_RESET" "$site" >&2
            opted=$((opted + 1))
            continue
        fi
        if ! is_valid_wp "$site"; then
            printf '  %sNOT-WP%s    %s\n' "$C_YELLOW" "$C_RESET" "$site" >&2
            notwp=$((notwp + 1))
            continue
        fi
        ok=$((ok + 1))
        if [ "$VERBOSE" = 'true' ]; then
            printf '  %sOK%s        %s (owner %s, WP %s)\n' "$C_GREEN" "$C_RESET" "$site" \
                "$(stat -c '%U' -- "$site" 2>/dev/null || printf '?')" \
                "$(wp_version_of "$site" 2>/dev/null || printf '?')" >&2
        fi
        [ "$AUDIT" = 'true' ] && audit_site "$site"
    done <"$list"
    local audit_note=''
    if ((AUDIT_FINDINGS > 0)); then
        audit_note="$(printf ', %s audit finding(s)' "$AUDIT_FINDINGS")"
    fi
    printf '\n  entries %s: %s ok, %s missing, %s not a WordPress root, %s opted out%s\n' \
        "$count" "$ok" "$missing" "$notwp" "$opted" "$audit_note" >&2
    if ((missing > 0)) || ((notwp > 0)); then
        return 1
    fi
    return 0
}
