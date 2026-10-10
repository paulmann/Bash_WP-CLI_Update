###############################################################################
# Section 23 - maintenance operations
###############################################################################
#
# One mode = one function, so a new mode is a new function plus one case branch
# in process_site and nothing else. Every function returns non-zero when the site
# failed. Every function takes (SITE USER URL), because a multisite expands into
# several units that share a path and an owner and differ only in the URL.

# mode_core SITE USER URL
#
# Order matters: files first, then the database schema. WordPress itself updates
# in that order, and `core update-db` before `core update` would run the old
# schema upgrade against the new files.
#
# --skip-plugins on the schema upgrade is what WordPress does during an update: a
# broken plugin must not be able to block a database migration.
mode_core() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user" "$url"
    run_wp "$site" "$user" "$url" core update || rc=1
    run_wp "$site" "$user" "$url" core update-db --skip-plugins || rc=1
    return "$rc"
}

# core_report_available SITE USER URL
core_report_available() { # SITE USER URL
    local label
    label="$(path_base "$1")"
    info_wp "$1" "$2" "$3" core check-update
    case "$WP_OUTPUT" in
        *'WordPress database upgrade required'*)
            log_info "${label}: a WordPress database upgrade is pending"
            ;;
        *'update_type'* | *'package'*)
            log_info "${label}: a WordPress core update is available"
            ;;
        *)
            log_info "${label}: WordPress core is up to date"
            ;;
    esac
    return 0
}

# plugins_update_selected SITE USER URL
#
# Update only the plugins that need it, minus the ones the operator excluded.
# WP-CLI has no "all except these" for `plugin update`, so the set is enumerated
# from `plugin list` and passed by slug. That also means one broken plugin cannot
# hide behind `--all`: the enumeration is per slug, and a slug that fails is
# reported by name.
plugins_update_selected() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local -a targets=()
    plugin_select_targets "$site" "$user" "$url" || return 1
    mapfile -t targets <<<"$PLUGIN_SELECTION"
    if ((${#targets[@]} == 0)) || { ((${#targets[@]} == 1)) && [ -z "${targets[0]}" ]; }; then
        log_info "$(path_base "$site"): nothing to update among the selected plugins"
        return 0
    fi
    log_info "$(path_base "$site"): updating ${#targets[@]} plugin(s): ${targets[*]}"
    run_wp "$site" "$user" "$url" plugin update "${targets[@]}"
}

mode_plugins() { # SITE USER URL
    if [ "$ONLY_ACTIVE" = 'true' ] || [ -n "$EXCLUDE_PLUGINS" ]; then
        plugins_update_selected "$1" "$2" "$3"
        return $?
    fi
    run_wp "$1" "$2" "$3" plugin update --all
}

mode_themes() { # SITE USER URL
    run_wp "$1" "$2" "$3" theme update --all
}

# mode_languages SITE USER URL
#
# Translations are the update everybody forgets, which is why a site can be
# running a current core with a year-old German language pack. `language` needs
# WP-CLI 2.2+, so it is probed rather than assumed: on an older build the mode
# says so instead of failing with a confusing "not a registered command".
mode_languages() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    if ! wp_supported "$site" "$user" language; then
        log_warn "$(path_base "$site"): this WP-CLI has no 'language' command (2.2+ needed); translations were not updated"
        return 0
    fi
    run_wp_soft "$site" "$user" "$url" language core update || true
    run_wp_soft "$site" "$user" "$url" language plugin update --all || true
    run_wp_soft "$site" "$user" "$url" language theme update --all || true
    return "$rc"
}

mode_db_optimize() { # SITE USER URL
    local rc=0
    run_wp "$1" "$2" "$3" db optimize || rc=1
    run_wp "$1" "$2" "$3" db repair || rc=1
    return "$rc"
}

mode_db_fix() { # SITE USER URL
    run_wp "$1" "$2" "$3" db repair
}

mode_cron() { # SITE USER URL
    run_wp "$1" "$2" "$3" cron event run --due-now
}

# mode_cache SITE USER URL
#
# The repository this tool grew out of advertised "cache flush" for years and did
# not have it, so a site that was updated correctly kept serving stale pages
# until somebody logged in and clicked a button. This mode is the fix.
#
# Three layers, because they are three different caches:
#   object cache   `wp cache flush`          -- the in-process/drop-in cache
#   transients     `wp transient delete`     -- the options-table cache
#   rewrite rules  `wp rewrite flush`        -- needed after a core update
#                                              changed the permalink handling
#
# Page caches owned by a plugin (WP Rocket, LiteSpeed, W3 Total Cache, WP Fastest
# Cache) are not guessed at: CACHE_EXTRA takes their wp subcommands as plain
# tokens, each of which becomes one argv element and is never interpreted by a
# shell. Tokens are validated to a conservative character set, so the worst a
# config file can do is name a wp subcommand -- which is exactly what this tool
# does for a living anyway, and the config file is root-owned and mode-checked.
mode_cache() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 tok
    run_wp "$site" "$user" "$url" cache flush || rc=1
    case "$CACHE_TRANSIENTS" in
        all)
            run_wp_soft "$site" "$user" "$url" transient delete --all || true
            ;;
        expired)
            run_wp_soft "$site" "$user" "$url" transient delete --expired || true
            ;;
        none) log_debug 'CACHE_TRANSIENTS=none; transients left alone' ;;
    esac
    if [ "$CACHE_REWRITE_FLUSH" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" rewrite flush || true
    fi
    for tok in $CACHE_EXTRA; do
        # shellcheck disable=SC2206  # the token list is validated by 'tokens'
        local -a extra=($tok)
        log_info "$(path_base "$site"): extra cache command: wp ${tok}"
        run_wp_soft "$site" "$user" "$url" ${extra[@]+"${extra[@]}"} || true
    done
    return "$rc"
}

###############################################################################
# Section 24 - cleanup
###############################################################################
#
# Revisions, trash, spam and expired transients are the four things that make a
# WordPress database grow without anybody adding content. Deleting them is safe
# when the ids come from WP-CLI and are validated as integers before they become
# arguments; it is destructive when a count is guessed. Everything below therefore
# enumerates first, reports the count, and only then deletes.
#
# Without --yes and without a terminal, this mode reports what it would delete and
# changes nothing. A cron job that quietly deleted 40k revisions on the first run
# would be a tool nobody trusts twice.

CLEANUP_BATCH=200

# ids_from_wp SITE USER URL ARGS... -> validated integer ids, one per line
ids_from_wp() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    wp_data "$site" "$user" "$url" "$@" --format=ids
    [ "$WP_SKIPPED" = 'true' ] && return 0
    ((WP_STATUS == 0)) || return 1
    # --format=ids prints a space separated list on one line for posts and one id
    # per line for comments, depending on the version. Normalise both.
    printf '%s\n' "$WP_OUTPUT" | tr ' ' '\n' | numeric_lines
    return 0
}

# delete_in_batches SITE USER URL KIND ID_ARGS... : delete validated ids in
# ARG_MAX-sized batches, counting what actually went away.
delete_in_batches() { # SITE USER URL DELETE_CMD... < IDS
    local site="$1" user="$2" url="$3"
    shift 3
    local -a cmd=("$@") batch=() ids=()
    local line total=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2206  # the batch is a list of validated integers
        batch=($line)
        if run_wp "$site" "$user" "$url" "${cmd[@]}" "${batch[@]}"; then
            total=$((total + ${#batch[@]}))
        fi
    done
    STATS_CLEANED=$((STATS_CLEANED + total))
    printf '%s' "$total"
    return 0
}

# revisions_to_delete SITE USER URL -> ids of the revisions beyond the keep limit
#
# Keeping "the newest N per post" rather than "the newest N overall" is the
# difference between a cleanup and a data loss event: a blog with one very active
# post would otherwise have every other post's history wiped. WP-CLI returns
# revisions newest first, so the first N rows of each post_parent group are the
# keepers and the rest are the targets.
revisions_to_delete() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local body tsv id parent date
    local -A kept=()
    wp_data "$site" "$user" "$url" post list --post_type=revision \
        --fields=ID,post_parent,post_date --format=json
    [ "$WP_SKIPPED" = 'true' ] && return 0
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT" 2>/dev/null)" || return 0
    tsv="$(printf '%s' "$body" | json_to_tsv ID post_parent post_date 2>/dev/null)" || return 0
    while IFS=$'\t' read -r id parent date; do
        [ "$id" = 'ID' ] && continue
        is_uint "$id" || continue
        parent="${parent:-0}"
        is_uint "$parent" || parent=0
        local n="${kept[$parent]-0}"
        if ((n < CLEANUP_REVISIONS_KEEP)); then
            kept[$parent]=$((n + 1))
            continue
        fi
        printf '%s\n' "$id"
    done <<<"$tsv"
    return 0
}

# count_id_words < BATCHES -> how many ids in total, across space separated lines
count_id_words() {
    local line w n=0
    while IFS= read -r line; do
        for w in $line; do
            is_uint "$w" && n=$((n + 1))
        done
    done
    printf '%s' "$n"
}

# cleanup_step SITE USER URL LABEL IDS DELETE_CMD...
#
# One enumerated object class, handled identically everywhere: count it, report
# it, and delete it only when the operator said --yes. Keeping this in one
# function is what stops the four cleanup kinds from drifting apart, which is how
# a tool ends up deleting trash but only reporting spam.
cleanup_step() { # SITE USER URL KIND IDS CMD...
    local site="$1" user="$2" url="$3" kind="$4" ids="$5"
    shift 5
    local -a cmd=("$@")
    local n=0 label
    label="$(path_base "$site")"
    n="$(printf '%s\n' "$ids" | count_id_words)"
    if ((n == 0)); then
        log_debug "${label}: no ${kind} to remove"
        return 0
    fi
    log_info "${label}: ${n} ${kind}"
    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        return 0
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: wp ${cmd[*]} <${n} ids>"
        STATS_CLEANED=$((STATS_CLEANED + n))
        return 0
    fi
    # A here-string, not a pipe: the counters have to survive in this shell.
    delete_in_batches "$site" "$user" "$url" "${cmd[@]}" <<<"$ids" >/dev/null
    return $?
}

mode_cleanup() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 ids='' label status
    label="$(path_base "$site")"
    local before="$STATS_CLEANED"

    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        if [ "$DRY_RUN" = 'true' ]; then
            log_info "${label}: cleanup dry run; reporting what would be deleted"
        elif [ ! -t 0 ]; then
            log_warn "${label}: --cleanup deletes content; pass --yes to allow it in a non-interactive run"
            log_info "${label}: reporting what would be deleted"
        fi
    fi

    # Revisions: the newest CLEANUP_REVISIONS_KEEP per post survive.
    ids="$(revisions_to_delete "$site" "$user" "$url" 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
    cleanup_step "$site" "$user" "$url" 'revision(s) beyond the keep limit' "$ids" \
        post delete --force || rc=1

    if [ "$CLEANUP_AUTODRAFT" = 'true' ]; then
        ids="$(ids_from_wp "$site" "$user" "$url" post list --post_status=auto-draft 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
        cleanup_step "$site" "$user" "$url" 'auto-draft(s)' "$ids" post delete --force || rc=1
    fi

    if [ "$CLEANUP_TRASH" = 'true' ]; then
        ids="$(ids_from_wp "$site" "$user" "$url" post list --post_status=trash 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
        cleanup_step "$site" "$user" "$url" 'trashed post(s)' "$ids" post delete --force || rc=1
    fi

    if [ "$CLEANUP_SPAM" = 'true' ]; then
        for status in spam trash; do
            ids="$(ids_from_wp "$site" "$user" "$url" comment list --status="$status" 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
            cleanup_step "$site" "$user" "$url" "${status} comment(s)" "$ids" comment delete --force || rc=1
        done
    fi

    case "$CLEANUP_TRANSIENTS" in
        all)
            log_info "${label}: all transients"
            if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ]; then
                if [ "$DRY_RUN" = 'true' ]; then
                    log_info '[dry-run] would run: wp transient delete --all'
                else
                    run_wp_soft "$site" "$user" "$url" transient delete --all || true
                fi
            fi
            ;;
        expired)
            log_info "${label}: expired transients"
            if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ]; then
                if [ "$DRY_RUN" = 'true' ]; then
                    log_info '[dry-run] would run: wp transient delete --expired'
                else
                    run_wp_soft "$site" "$user" "$url" transient delete --expired || true
                fi
            fi
            ;;
        none) log_debug "${label}: transients left alone" ;;
    esac

    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        log_info "${label}: nothing was deleted (add --yes to apply)"
        return 0
    fi
    if [ "$CLEANUP_OPTIMIZE" = 'true' ] && ((STATS_CLEANED > before)) && [ "$DRY_RUN" != 'true' ]; then
        log_info "${label}: optimizing the database after the cleanup"
        run_wp_soft "$site" "$user" "$url" db optimize || true
    fi
    return "$rc"
}

###############################################################################
# Section 25 - Astra Pro licence
###############################################################################

# astra_step SITE USER URL STRICT
#
# Update first, because that is the common case and it needs no licence. Only
# reach for the licence when the update actually failed, which is what "the
# licence expired" looks like from the outside.
# rc == 2 means dry run: nothing happened and nothing should be retried.
astra_step() { # SITE USER URL STRICT
    local site="$1" user="$2" url="$3" strict="${4:-false}" rc=0 label
    label="$(path_base "$site")"
    run_wp_soft "$site" "$user" "$url" plugin update "$ASTRA_SLUG"
    rc=$?
    ((rc == 0)) && { log_ok "${label}: ${ASTRA_SLUG} updated"; return 0; }
    ((rc == 2)) && return 0

    if ! licence_resolve "$strict"; then
        if [ "$strict" = 'true' ]; then return 1; fi
        log_warn "${label}: no Astra licence configured; the licence step is skipped"
        return 0
    fi
    log_info "${label}: the update failed, trying a licence activation"
    run_wp_soft "$site" "$user" "$url" brainstormforce license activate "$ASTRA_SLUG" "$LICENCE_MARKER"
    rc=$?
    if ((rc == 1)); then
        log_warn "${label}: licence activation did not succeed"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    ((rc == 2)) && return 0
    log_ok "${label}: licence activated"
    run_wp_soft "$site" "$user" "$url" plugin update "$ASTRA_SLUG"
    rc=$?
    if ((rc == 1)); then
        log_warn "${label}: ${ASTRA_SLUG} still did not update after activation"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    log_ok "${label}: ${ASTRA_SLUG} updated after licence activation"
    return 0
}

mode_astra() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    if ! licence_resolve 'false' && [ -z "$LICENCE_VALUE" ]; then
        # Resolve strictly only when the mode is the point of the run: --astra
        # with no licence is a configuration error, while --full without one is
        # a normal host that does not use Astra Pro.
        licence_resolve 'true' || return 1
    fi
    astra_step "$site" "$user" "$url" 'true'
}

###############################################################################
# Section 26 - integrity verification
###############################################################################

# mode_verify SITE USER URL
#
# Read-only. `verify-checksums` compares every shipped file against the
# WordPress.org manifest, which is the cheapest way to find a half-finished
# update or a tampered core file before touching anything. A mismatch is a
# *finding*: it is reported and it fails the site, but nothing is modified, so
# the mode is safe to schedule hourly.
mode_verify() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 label
    label="$(path_base "$site")"
    if ! run_wp "$site" "$user" "$url" core verify-checksums; then
        log_error "${label}: core checksums do not match"
        STATS_FINDINGS=$((STATS_FINDINGS + 1))
        rc=1
    fi
    if ! run_wp "$site" "$user" "$url" plugin verify-checksums --all; then
        log_error "${label}: at least one plugin failed its checksum verification"
        STATS_FINDINGS=$((STATS_FINDINGS + 1))
        rc=1
    fi
    return "$rc"
}

###############################################################################
# Section 27 - --full
###############################################################################
#
# The order is the order WordPress itself uses, with the caches at the end:
#   1. core files, 2. core schema, 3. plugins, 4. themes, 5. translations,
#   6. cron, 7. caches and rewrite rules, 8. database optimize, 9. Astra.
#
# `db repair` is deliberately NOT part of --full by default. It runs
# `mysqlcheck --repair`, which on InnoDB is a no-op that still walks every table,
# and on MyISAM takes a lock. Running it on every site of every nightly update is
# a self-inflicted outage window for no benefit; a repair belongs in --db-fix,
# after something has actually been reported as broken. FULL_DB_REPAIR=true puts
# it back for hosts that want the old behaviour.
mode_full() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user" "$url"
    run_wp "$site" "$user" "$url" core update || rc=1
    run_wp "$site" "$user" "$url" core update-db --skip-plugins || rc=1
    mode_plugins "$site" "$user" "$url" || rc=1
    run_wp "$site" "$user" "$url" theme update --all || rc=1
    if [ "$FULL_LANGUAGES" = 'true' ]; then
        mode_languages "$site" "$user" "$url" || true
    fi
    run_wp_soft "$site" "$user" "$url" cron event run --due-now || true
    if [ "$FULL_CACHE" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" cache flush || true
        case "$CACHE_TRANSIENTS" in
            expired) run_wp_soft "$site" "$user" "$url" transient delete --expired || true ;;
            all) run_wp_soft "$site" "$user" "$url" transient delete --all || true ;;
        esac
        [ "$CACHE_REWRITE_FLUSH" = 'true' ] &&
            run_wp_soft "$site" "$user" "$url" rewrite flush || true
    fi
    run_wp_soft "$site" "$user" "$url" db optimize || true
    if [ "$FULL_DB_REPAIR" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" db repair || true
    fi
    if [ -n "$LICENCE_VALUE" ] || licence_resolve 'false'; then
        astra_step "$site" "$user" "$url" 'false' || true
    fi
    return "$rc"
}
