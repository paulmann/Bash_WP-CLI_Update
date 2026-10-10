###############################################################################
# Section 29 - health report (--report)
###############################################################################
#
# The question a fleet operator actually asks on Monday morning is not "did the
# update run" but "what state is everything in, and what needs attention". Every
# field below is read-only: no counter moves, nothing is written, and the mode is
# safe to schedule more often than the updates themselves.
#
# All of it is collected with `--format=count`, `--format=json` or `config get`
# rather than by parsing human-readable tables, because a table's column order is
# not part of WP-CLI's contract and changes between releases.

# report_php_info SITE USER -> "php|phpversion|wpcliversion"
report_php_info() { # SITE USER
    local site="$1" user="$2" body phpv='' cliv='' phpbin=''
    if wp_data "$site" "$user" '' cli info 2>/dev/null && ((WP_STATUS == 0)); then
        body="$WP_OUTPUT"
        phpv="$(awk -F': *' '/^PHP version/ {print $2; exit}' <<<"$body")"
        phpbin="$(awk -F': *' '/^PHP binary/ {print $2; exit}' <<<"$body")"
        cliv="$(awk -F': *' '/^WP-CLI version/ {print $2; exit}' <<<"$body")"
    fi
    printf '%s\t%s\t%s\t%s' "$(trim "$phpbin")" "$(trim "$phpv")" "$(trim "$cliv")" ''
    return 0
}

# report_db_bytes SITE USER URL -> database size in bytes, empty when unknown.
# information_schema first, because the answer is a single integer and does not
# depend on how `db size` decides to render its table this release.
report_db_bytes() { # SITE USER URL
    local site="$1" user="$2" url="$3" out=''
    if wp_probe "$site" "$user" "$url" db query \
        'SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()' \
        --skip-column-names 2>/dev/null; then
        out="${WP_PROBE//[^0-9]/}"
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    if wp_data "$site" "$user" "$url" db size --size_format=bytes 2>/dev/null && ((WP_STATUS == 0)); then
        out="$(grep -o '[0-9]\+' <<<"$WP_OUTPUT" | tail -n 1)"
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    printf ''
    return 1
}

# report_count SITE USER URL ARGS... -> an integer, 0 when unavailable
report_count() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    if wp_probe "$site" "$user" "$url" "$@" --format=count 2>/dev/null; then
        local n="${WP_PROBE//[^0-9]/}"
        printf '%s' "${n:-0}"
        return 0
    fi
    printf '0'
    return 0
}

REPORT_HEADERS='SITE	OWNER	WP	PHP	HOME	MULTISITE	PLUGINS	PLUGIN_UPDATES	THEMES	THEME_UPDATES	USERS	ADMINS	DB_SIZE	UPLOADS	CRON	DISK_FREE_MIB	CORE_UPDATE'

# report_unit INDEX -> one TSV row for one work unit
report_unit() { # INDEX
    local i="$1" site="${UNIT_PATH[i]}" user="${UNIT_USER[i]}" url="${UNIT_URL[i]}"
    local wpver='' home='' multi='no' dbb='' upl='' cron='?' coreupd='no'
    local plugins=0 pupd=0 themes=0 tupd=0 users=0 admins=0 phpv='' phpbin='' cliv=''

    if wp_probe "$site" "$user" "$url" core version; then wpver="$WP_PROBE"; fi
    home="$(site_home "$site" "$user")"

    # `cli info` once, because PHP and WP-CLI versions come from the same answer.
    local info
    info="$(report_php_info "$site" "$user")"
    phpbin="${info%%$'\t'*}"; info="${info#*$'\t'}"
    phpv="${info%%$'\t'*}"; info="${info#*$'\t'}"
    cliv="${info%%$'\t'*}"

    if [ "$MULTISITE" != 'off' ]; then
        local subs
        subs="$(report_count "$site" "$user" "$url" site list)"
        if ((${subs:-0} > 0)); then multi="yes(${subs})"; fi
    fi

    plugins="$(report_count "$site" "$user" "$url" plugin list)"
    pupd="$(report_count "$site" "$user" "$url" plugin list --update=available)"
    themes="$(report_count "$site" "$user" "$url" theme list)"
    tupd="$(report_count "$site" "$user" "$url" theme list --update=available)"
    users="$(report_count "$site" "$user" "$url" user list)"
    admins="$(report_count "$site" "$user" "$url" user list --role=administrator)"

    if [ "$REPORT_DB_SIZE" = 'true' ]; then
        dbb="$(report_db_bytes "$site" "$user" "$url")"
    fi
    if [ "$REPORT_UPLOADS_SIZE" = 'true' ] && [ -d "${site}/wp-content/uploads" ]; then
        local kib
        kib="$(dir_kib "${site}/wp-content/uploads")"
        [ -n "$kib" ] && upl="$((kib * 1024))"
    fi
    if [ "$REPORT_CRON_TEST" = 'true' ]; then
        if wp_data "$site" "$user" "$url" cron test >/dev/null 2>&1 && ((WP_STATUS == 0)); then
            cron='ok'
        else
            cron='BROKEN'
        fi
    fi
    # A pending core update is the single most actionable field in the report.
    wp_data "$site" "$user" "$url" core check-update --format=json >/dev/null 2>&1
    if ((WP_STATUS == 0)) && json_array_slice "$WP_OUTPUT" >/dev/null 2>&1; then
        local slice
        if slice="$(json_array_slice "$WP_OUTPUT")" && [ -n "$slice" ] && [ "$slice" != '[]' ]; then
            coreupd='yes'
        fi
    fi

    REPORT_ROW="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "${UNIT_LABEL[i]}" "$user" "${wpver:-?}" "${phpv:-?}" "${home:-?}" "$multi" \
        "$plugins" "$pupd" "$themes" "$tupd" "$users" "$admins" \
        "$([ -n "$dbb" ] && human_bytes "$dbb" || printf -- '-')" \
        "$([ -n "$upl" ] && human_bytes "$upl" || printf -- '-')" \
        "$cron" "$(free_mib "$site" 2>/dev/null || printf '?')" "$coreupd")"

    # The machine-readable form carries the raw numbers, because a monitoring
    # system cannot do anything useful with "1.5 MiB".
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        local jv
        if [ "$coreupd" = 'yes' ]; then jv='true'; else jv='false'; fi
        printf '{"type":"report","path":%s,"owner":%s,"url":%s,"wp_version":%s,"php_version":%s,"wpcli_version":%s,"home":%s,"multisite":%s,"plugins":%s,"plugin_updates":%s,"themes":%s,"theme_updates":%s,"users":%s,"administrators":%s,"db_bytes":%s,"uploads_bytes":%s,"cron":%s,"core_update":%s}\n' \
            "$(json_quote "$site")" "$(json_quote "$user")" "$(json_quote "$url")" \
            "$(json_quote "${wpver:-}")" "$(json_quote "${phpv:-}")" "$(json_quote "${cliv:-}")" \
            "$(json_quote "${home:-}")" "$(json_quote "$multi")" \
            "$plugins" "$pupd" "$themes" "$tupd" "$users" "$admins" \
            "$(json_quote "${dbb:-}")" "$(json_quote "${upl:-}")" \
            "$(json_quote "$cron")" "$jv" | sink_append "$(data_sink)"
    fi
    if [ -n "$wpver" ]; then
        UNIT_WP_VERSION["$site"]="$wpver"
    fi
    return 0
}

# mode_report SITE USER URL : one row of the fleet report.
#
# The row goes to report_row_sink, which is a per-worker file in a parallel run
# and the shared buffer in a sequential one (section 41). Streaming a table
# straight to stdout would force a guess at the column widths, and streaming it
# from four workers at once would produce an unreadable interleave.
mode_report() { # SITE USER URL
    local sink dsink
    report_unit "$CURRENT_UNIT"
    sink="$(report_row_sink)"
    dsink="$(data_sink)"
    case "$OUTPUT_FORMAT" in
        json)
            : # report_unit already emitted the JSON object to the data sink
            ;;
        table)
            printf '%s\n' "$REPORT_ROW" | sink_append "$sink"
            ;;
        tsv)
            if [ "$REPORT_HEADER_PRINTED" != 'true' ]; then
                printf '%s\n' "$REPORT_HEADERS" | sink_append "$dsink"
                REPORT_HEADER_PRINTED='true'
            fi
            printf '%s\n' "$REPORT_ROW" | sink_append "$dsink"
            ;;
        csv)
            if [ "$REPORT_HEADER_PRINTED" != 'true' ]; then
                printf '%s\n' "$REPORT_HEADERS" | tsv_to_csv | sink_append "$dsink"
                REPORT_HEADER_PRINTED='true'
            fi
            printf '%s\n' "$REPORT_ROW" | tsv_to_csv | sink_append "$dsink"
            ;;
    esac
    return 0
}
REPORT_HEADER_PRINTED='false'
REPORT_ROW=''

###############################################################################
# Section 30 - security and integrity audit (--security)
###############################################################################
#
# A read-only audit that answers "which of my sites is a problem?" in one pass.
# Every check produces a finding with a severity, and the severities drive both
# the score and the exit code, so this mode can be the thing a monitoring system
# alerts on instead of a report somebody has to read.
#
#   crit   the site is very likely compromised or exposed right now
#   warn   a configuration that should not ship to production
#   info   worth knowing, not worth a page
#
# Scoring is deliberately simple and documented: start at 100, minus 25 per crit,
# minus 8 per warn, minus 1 per info, floor at 0. A number that cannot be
# explained is a number nobody trusts.

FIND_SEV=()
FIND_CHECK=()
FIND_MSG=()
SITE_SCORE=100

# finding SEVERITY CHECK MESSAGE
finding() { # SEVERITY CHECK MESSAGE
    local sev="${1:-info}"
    FIND_SEV+=("$sev")
    FIND_CHECK+=("${2:-check}")
    FIND_MSG+=("${3:-}")
    STATS_FINDINGS=$((STATS_FINDINGS + 1))
    case "$sev" in
        crit)
            STATS_CRITICAL=$((STATS_CRITICAL + 1))
            SITE_SCORE=$((SITE_SCORE - 25))
            log_error "CRIT ${2:-check}: ${3:-}"
            ;;
        warn)
            SITE_SCORE=$((SITE_SCORE - 8))
            log_warn "${2:-check}: ${3:-}"
            ;;
        *)
            SITE_SCORE=$((SITE_SCORE - 1))
            log_info "info ${2:-check}: ${3:-}"
            ;;
    esac
    return 0
}

finding_ok() { # CHECK MESSAGE
    log_debug "ok   ${1:-check}: ${2:-}"
    return 0
}

# audit_permissions SITE : file mode checks that need no WordPress at all.
audit_permissions() { # SITE
    local site="$1" cfg mode='' uploads
    if cfg="$(wp_config_path "$site")"; then
        mode="$(file_mode "$cfg")"
        path_base "$cfg" >/dev/null
        local cfg_name="$PATH_BASE" m=0
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
            # Bit arithmetic, not digit eyeballing. The severity ladder is the
            # one an incident responder would draw: other-write means any local
            # account can own the site (crit); group-write means the same for a
            # whole group (warn, because on a shared host that group is often
            # "every customer"); other-read leaks the database credentials
            # (warn); 0640 and stricter is the recommended shape and passes.
            m=$((8#${mode}))
            if ((m & 8#002)); then
                finding crit 'wp-config perms' \
                    "${cfg_name} is writable by any local account (mode ${mode}). chmod 0640"
            elif ((m & 8#020)); then
                finding warn 'wp-config perms' \
                    "${cfg_name} is writable by its group (mode ${mode}); check who is in that group. chmod 0640"
            elif ((m & 8#004)); then
                finding warn 'wp-config perms' \
                    "${cfg_name} is world-readable (mode ${mode}); it holds the database credentials. chmod 0640"
            else
                finding_ok 'wp-config perms' "mode ${mode}"
            fi
        elif [ -n "$mode" ]; then
            finding warn 'wp-config perms' "unparsable mode '${mode}' on ${cfg_name}"
        fi
    else
        finding warn 'wp-config' "no wp-config.php found for ${site}"
    fi

    if [ "$SECURITY_WORLD_WRITABLE" = 'true' ] && [ -d "${site}/wp-content" ]; then
        local n=0
        n="$(find "${site}/wp-content" -maxdepth 4 -type f -name '*.php' -perm -o+w -print 2>/dev/null | head -n 20 | count_lines)"
        if ((n > 0)); then
            finding crit 'world-writable php' \
                "${n} world-writable PHP file(s) under wp-content (showing at most 20); any local account can edit them"
        else
            finding_ok 'world-writable php' 'none found'
        fi
    fi

    if [ "$SECURITY_UPLOADS_SCAN" = 'true' ]; then
        uploads="${site}/wp-content/uploads"
        if [ -d "$uploads" ]; then
            # Executable code in uploads is the single most common WordPress
            # backdoor location, because uploads is the one directory an
            # unauthenticated user can write to.
            local php_n=0 sus=''
            php_n="$(find "$uploads" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' -o -name '*.phar' \) -print 2>/dev/null | head -n 20 | count_lines)"
            if ((php_n > 0)); then
                sus="$(find "$uploads" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' -o -name '*.phar' \) -print 2>/dev/null | head -n 5 | tr '\n' ' ')"
                finding crit 'php in uploads' \
                    "${php_n} PHP file(s) inside wp-content/uploads, e.g. ${sus}; this is how backdoors are planted"
            else
                finding_ok 'php in uploads' 'none found'
            fi
            # Dumps and archives left in the web root are a data leak, not a
            # tidiness problem: they are served by the web server.
            local dump_n=0
            dump_n="$(find "$uploads" -maxdepth 3 -type f \
                \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.bak' -o -name '*.old' -o -name '*~' -o -name '*.tar.gz' -o -name '*.zip' \) \
                -print 2>/dev/null | head -n 20 | count_lines)"
            if ((dump_n > 0)); then
                finding warn 'backups in webroot' \
                    "${dump_n} dump/archive file(s) inside wp-content/uploads are reachable over HTTP"
            fi
        fi
    fi
    return 0
}

# audit_wp_config SITE : the constants that decide how much damage a compromise does.
audit_wp_config() { # SITE
    local site="$1" cfg v
    cfg="$(wp_config_path "$site")" || return 0

    v="$(wp_config_constant "$cfg" WP_DEBUG)"
    case "${v,,}" in
        true | 1)
            finding warn 'WP_DEBUG' 'debugging is enabled; stack traces and SQL are written where a visitor can trigger them'
            ;;
        *) finding_ok 'WP_DEBUG' 'off' ;;
    esac

    v="$(wp_config_constant "$cfg" DISALLOW_FILE_EDIT)"
    case "${v,,}" in
        true | 1) finding_ok 'DISALLOW_FILE_EDIT' 'the plugin/theme editor is disabled' ;;
        *)
            finding warn 'DISALLOW_FILE_EDIT' \
                'not set; any administrator can edit plugin PHP from the dashboard, which is the shortest path from a stolen admin account to a webshell'
            ;;
    esac

    v="$(wp_config_constant "$cfg" DISALLOW_FILE_MODS)"
    case "${v,,}" in
        true | 1) finding_ok 'DISALLOW_FILE_MODS' 'plugin/theme installation is disabled' ;;
        *) log_debug 'DISALLOW_FILE_MODS is not set (normal for most hosts)' ;;
    esac

    v="$(wp_config_constant "$cfg" WP_AUTO_UPDATE_CORE)"
    case "${v,,}" in
        false | 0)
            finding info 'WP_AUTO_UPDATE_CORE' 'core auto-updates are disabled; security releases will not apply themselves'
            ;;
        minor) finding_ok 'WP_AUTO_UPDATE_CORE' 'minor (security) releases apply automatically' ;;
        true | 1) finding_ok 'WP_AUTO_UPDATE_CORE' 'all core releases apply automatically' ;;
        *) : ;;
    esac

    # The table prefix is not a vulnerability, and calling it one trains people to
    # ignore the audit. It is reported as information, nothing more.
    v="$(wp_config_constant "$cfg" table_prefix)"
    [ -z "$v" ] && v="$(grep -o "\$table_prefix *= *'[^']*'" "$cfg" 2>/dev/null | head -n1 | sed "s/.*'\\(.*\\)'.*/\\1/")"
    if [ "$v" = 'wp_' ]; then
        finding info 'table prefix' 'the default wp_ prefix is in use'
    fi
    return 0
}

# audit_wp SITE USER URL : everything that needs a running WordPress.
audit_wp() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local ver='' home='' n=0 body=''

    if wp_probe "$site" "$user" "$url" core version; then
        ver="$WP_PROBE"
        UNIT_WP_VERSION["$site"]="$ver"
        if [ -n "$SECURITY_MIN_WP" ] && ! version_at_least "$ver" "$SECURITY_MIN_WP"; then
            finding crit 'core version' \
                "WordPress ${ver} is below the required ${SECURITY_MIN_WP}; it no longer receives security releases"
        else
            finding_ok 'core version' "$ver"
        fi
    else
        finding crit 'core version' 'the WordPress version could not be read; the site may be broken'
    fi

    # A pending *minor* core update is an unapplied security release. That is a
    # different thing from "a new feature version is out", and it is the only
    # update finding that deserves crit.
    wp_data "$site" "$user" "$url" core check-update --format=json >/dev/null 2>&1
    if ((WP_STATUS == 0)); then
        if body="$(json_array_slice "$WP_OUTPUT")" && [ -n "$body" ] && [ "$body" != '[]' ]; then
            local tsv upver='' uptype=''
            tsv="$(printf '%s' "$body" | json_to_tsv version update_type 2>/dev/null)"
            while IFS=$'\t' read -r upver uptype; do
                [ "$upver" = 'version' ] && continue
                [ -n "$upver" ] || continue
                break
            done <<<"$tsv"
            if [ "$uptype" = 'minor' ]; then
                finding crit 'core update' \
                    "security release ${upver} is pending; minor updates are the ones that fix exploited vulnerabilities"
            else
                finding warn 'core update' "WordPress ${upver:-a newer version} is available (${uptype:-major})"
            fi
        else
            finding_ok 'core update' 'core is current'
        fi
    fi

    if home="$(site_home "$site" "$user")"; then
        case "$home" in
            https://*) finding_ok 'https' "$home" ;;
            http://*)
                finding warn 'https' "the site URL is plain HTTP (${home}); credentials and sessions travel in the clear"
                ;;
        esac
    fi

    # Checksums. `core verify-checksums` needs network access to wordpress.org;
    # when it cannot reach it, that is a warning about the audit, not a finding
    # about the site, and the difference has to be visible.
    if wp_supported "$site" "$user" core verify-checksums; then
        wp_data "$site" "$user" "$url" core verify-checksums >/dev/null 2>&1
        case "$WP_STATUS" in
            0) finding_ok 'core checksums' 'all core files match the published manifest' ;;
            255 | 1)
                finding crit 'core checksums' \
                    "core files do not match the WordPress.org manifest: $(printf '%s' "$WP_OUTPUT" | head -n 3 | tr '\n' '; ')"
                ;;
            *) finding warn 'core checksums' "verification returned ${WP_STATUS}; it may need network access" ;;
        esac
        wp_data "$site" "$user" "$url" plugin verify-checksums --all >/dev/null 2>&1
        case "$WP_STATUS" in
            0) finding_ok 'plugin checksums' 'all wordpress.org plugins match' ;;
            1)
                finding crit 'plugin checksums' \
                    "at least one plugin does not match its published files: $(printf '%s' "$WP_OUTPUT" | head -n 3 | tr '\n' '; ')"
                ;;
            *) log_debug "plugin checksum verification returned ${WP_STATUS}" ;;
        esac
    fi

    # Pending plugin updates, split by whether the plugin is active: an active
    # plugin with a pending update is exposed surface, an inactive one is clutter.
    n="$(report_count "$site" "$user" "$url" plugin list --update=available --status=active)"
    if ((n > 0)); then
        finding warn 'plugin updates' "${n} active plugin(s) have an update available"
    else
        finding_ok 'plugin updates' 'no active plugin is behind'
    fi
    n="$(report_count "$site" "$user" "$url" plugin list --update=available --status=inactive)"
    if ((n > 0)); then
        finding info 'inactive plugins' "${n} inactive plugin(s) are behind; an inactive plugin is still code on disk"
    fi

    n="$(report_count "$site" "$user" "$url" user list --role=administrator)"
    if ((SECURITY_MAX_ADMINS > 0)) && ((n > SECURITY_MAX_ADMINS)); then
        finding warn 'administrators' "${n} administrator accounts, more than the configured ${SECURITY_MAX_ADMINS}"
    else
        finding_ok 'administrators' "${n} account(s)"
    fi
    # A login literally named `admin` is the first credential a brute-force
    # attack tries, and the check costs one query. It is `info`, not `warn`:
    # on a site with a strong password and 2FA it is a style choice, and an
    # audit that shouts about style gets switched off.
    if wp_data "$site" "$user" "$url" user list --fields=user_login --format=csv >/dev/null 2>&1 \
       && ((WP_STATUS == 0)); then
        if grep -qix 'admin' <<<"$WP_OUTPUT"; then
            finding info 'admin login' 'an account with the login name "admin" exists; rename it or make sure it is 2FA-protected'
        fi
    fi
    return 0
}

# audit_secrets SITE : run the repository's own scanner over the site config.
audit_secrets() { # SITE
    local site="$1" scanner cfg
    [ "$SECURITY_SECRETS" = 'true' ] || return 0
    scanner="${SCRIPT_DIR}/tools/scan-secrets.sh"
    if [ ! -f "$scanner" ]; then
        log_debug "the secret scanner is not installed at ${scanner}; the check is skipped"
        return 0
    fi
    cfg="$(wp_config_path "$site")" || return 0
    local out='' rc=0
    out="$(bash "$scanner" --quiet "$cfg" 2>/dev/null)" || rc=$?
    if ((rc == 0)); then
        finding_ok 'hardcoded secrets' "nothing suspicious in $(path_base "$cfg")"
        return 0
    fi
    # A database password in wp-config.php is *expected*; the scanner's allowlist
    # knows that. Anything it still reports is worth a look and not a crit, so it
    # is a warning with the first findings quoted.
    finding warn 'hardcoded secrets' \
        "the scanner reported value(s) in $(path_base "$cfg"): $(printf '%s' "$out" | head -n 3 | tr '\n' '; ')"
    return 0
}

# mode_security SITE USER URL
mode_security() { # SITE USER URL
    local site="$1" user="$2" url="$3" i
    FIND_SEV=() FIND_CHECK=() FIND_MSG=()
    SITE_SCORE=100
    audit_permissions "$site"
    audit_wp_config "$site"
    audit_wp "$site" "$user" "$url"
    audit_secrets "$site"
    ((SITE_SCORE < 0)) && SITE_SCORE=0

    local crit=0 warn=0 info=0
    for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
        case "${FIND_SEV[i]}" in
            crit) crit=$((crit + 1)) ;;
            warn) warn=$((warn + 1)) ;;
            *) info=$((info + 1)) ;;
        esac
    done

    local sink
    data_sink
    sink="$DATA_SINK"
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        {
            printf '{"type":"security","path":%s,"owner":%s,"score":%s,"critical":%s,"warn":%s,"info":%s,"findings":[' \
                "$(json_quote "$site")" "$(json_quote "$user")" "$SITE_SCORE" "$crit" "$warn" "$info"
            for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
                ((i > 0)) && printf ','
                printf '{"severity":%s,"check":%s,"message":%s}' \
                    "$(json_quote "${FIND_SEV[i]}")" "$(json_quote "${FIND_CHECK[i]}")" \
                    "$(json_quote "${FIND_MSG[i]}")"
            done
            printf ']}\n'
        } | sink_append "$sink"
    elif [ "$OUTPUT_FORMAT" = 'table' ]; then
        {
            printf '%s%s%s  score %s/100  (%s crit, %s warn, %s info)\n' \
                "$C_BOLD" "$site" "$C_RESET" "$SITE_SCORE" "$crit" "$warn" "$info"
            for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
                printf '  %-5s %-22s %s\n' "${FIND_SEV[i]^^}" "${FIND_CHECK[i]}" "${FIND_MSG[i]}"
            done
            printf '\n'
        } | sink_append "$sink"
    fi

    log_info "$(path_base "$site"): security score ${SITE_SCORE}/100 (${crit} critical, ${warn} warning, ${info} info)"
    UNIT_STATUS["${site}|score"]="$SITE_SCORE"
    if ((crit > 0)); then
        return 1
    fi
    if [ "$STRICT" = 'true' ] && ((warn > 0)); then
        return 1
    fi
    return 0
}

# mode_secrets SITE USER URL : the standalone scanner run over a whole site tree.
mode_secrets() { # SITE USER URL
    local site="$1" scanner="${SCRIPT_DIR}/tools/scan-secrets.sh" out='' rc=0
    if [ ! -f "$scanner" ]; then
        log_error "the secret scanner is not installed at ${scanner}"
        return 1
    fi
    log_info "scanning ${site} for credential-looking values"
    out="$(bash "$scanner" --strict "$site" 2>&1)" || rc=$?
    if ((rc == 0)); then
        log_ok "no credential-looking values found in ${site}"
        return 0
    fi
    printf '%s\n' "$out" | head -n 40 >&2
    log_warn "the scanner reported findings in ${site} (exit ${rc})"
    STATS_FINDINGS=$((STATS_FINDINGS + 1))
    return 1
}

###############################################################################
# Section 31 - --check and --status
###############################################################################

CHECK_OK=$'\xe2\x9c\x93'
CHECK_NO=$'\xe2\x9c\x97'
CHECK_WARN='!'

# check_report SITE USER : the per-site half of --check
check_report() { # SITE USER
    local site="${1-}" user="${2:-}" rc=0 cfg='' mode=''
    printf '%s\n' "${C_BOLD}site            ${C_RESET}: ${site}"
    if [ ! -d "$site" ]; then
        printf '  %s%s%s not a directory\n' "$C_RED" "$CHECK_NO" "$C_RESET"
        return 1
    fi
    if cfg="$(wp_config_path "$site")"; then
        mode="$(file_mode "$cfg")"
        path_base "$cfg" >/dev/null
        local cfg_name="$PATH_BASE" m=0
        printf '  %s%s%s %s (mode %s)\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" \
            "$cfg_name" "${mode:-?}"
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
            # Bit arithmetic, not digit eyeballing: 0640 is the recommended mode
            # (the web server group can read it), and a check that flags it
            # trains operators to ignore --check. What matters is any group or
            # other write (mask 022) and other-read (the 4-bit of the last
            # digit), which exposes the database credentials to every account.
            m=$((8#${mode}))
            if ((m & 8#022)); then
                printf '  %s%s%s %s is writable by group or others; whoever is in that group owns the site\n' \
                    "$C_RED" "$CHECK_NO" "$C_RESET" "$cfg_name"
                rc=1
            elif ((m & 8#004)); then
                printf '  %s%s%s %s is world-readable (mode %s); chmod 0640 is the usual answer\n' \
                    "$C_YELLOW" "$CHECK_WARN" "$C_RESET" "$cfg_name" "$mode"
            fi
        fi
    else
        printf '  %s%s%s no wp-config.php (looked in the site root and one level up)\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET"
        rc=1
    fi
    if [ -f "${site}/wp-load.php" ]; then
        printf '  %s%s%s wp-load.php\n' "$C_GREEN" "$CHECK_OK" "$C_RESET"
    elif [ -f "${site}/wp-includes/version.php" ]; then
        printf '  %s%s%s wp-includes/version.php (no wp-load.php: a Bedrock-style layout?)\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    else
        printf '  %s%s%s not a WordPress root (no wp-load.php, no wp-includes/version.php)\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    fi
    if [ -f "${site}/.no_wp_cli" ]; then
        printf '  %s%s%s opt-out marker .no_wp_cli is present; the finder will not list this site\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    fi
    if [ -n "$user" ]; then
        printf '  %s%s%s owner: %s\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" "$user"
    else
        printf '  %s%s%s owner: cannot be determined\n' "$C_RED" "$CHECK_NO" "$C_RESET"
        rc=1
    fi
    if [ -d "${site}/wp-content/uploads" ]; then
        if [ -w "${site}/wp-content/uploads" ] || { [ -n "$user" ] && [ "$(file_owner "${site}/wp-content/uploads")" = "$user" ]; }; then
            printf '  %s%s%s wp-content/uploads is writable by the site owner\n' \
                "$C_GREEN" "$CHECK_OK" "$C_RESET"
        else
            printf '  %s%s%s wp-content/uploads may not be writable by %s\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET" "${user:-the owner}"
        fi
    fi
    local free
    free="$(free_mib "$site" 2>/dev/null || printf 0)"
    if is_uint "$free" && ((free > 0)) && ((free < 200)); then
        printf '  %s%s%s only %s MiB free on the filesystem holding this site\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET" "$free"
        rc=1
    elif is_uint "$free" && ((free > 0)); then
        printf '  %s%s%s %s MiB free on this filesystem\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" "$free"
    fi
    return "$rc"
}

# check_environment : the host half of --check
check_environment() {
    local rc=0 i user installed='' latest='' lock_kind='pid file' timeout_desc='disabled'
    printf '\n%s== environment ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'bash            : %s\n' "$BASH_VERSION"
    printf 'script          : %s %s (%s, build %s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$SCRIPT_DIR" "$BUILD_ID"
    printf 'running as      : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'hostname        : %s\n' "$(uname -n 2>/dev/null || printf '?')"
    if wp_ensure; then
        printf 'wp-cli          : %s\n' "$WP_RESOLVED"
        printf 'wp-cli resolved : %s (%s install)\n' "$(wp_realpath)" "$(wp_install_kind)"
        if installed="$(wpcli_version_local)"; then
            printf 'wp-cli version  : %s' "$installed"
            if [ -n "$WP_CLI_MIN_VERSION" ]; then
                if version_at_least "$installed" "$WP_CLI_MIN_VERSION"; then
                    printf ' %s(satisfies the %s minimum)%s\n' "$C_GREEN" "$WP_CLI_MIN_VERSION" "$C_RESET"
                else
                    printf ' %s(BELOW the %s minimum)%s\n' "$C_RED" "$WP_CLI_MIN_VERSION" "$C_RESET"
                    rc=1
                fi
            else
                printf '\n'
            fi
        else
            printf 'wp-cli version  : %scould not be determined%s\n' "$C_YELLOW" "$C_RESET"
        fi
        if [ "$WP_CLI_LATEST_CHECK" = 'true' ] && latest="$(wpcli_latest)"; then
            printf 'wp-cli newest   : %s%s\n' "$latest" \
                "$([ "$(version_compare "$installed" "$latest")" = '-1' ] && printf ' (an update is available)')"
        fi
    else
        printf 'wp-cli          : %sNOT FOUND%s (install with --wpcli-install)\n' "$C_RED" "$C_RESET"
        rc=1
    fi
    printf 'php             : %s\n' "$(command -v "${PHP_BIN:-php}" 2>/dev/null || printf 'not found')"
    printf 'user switch     : %s\n' "$(switch_mechanism)"
    have flock && lock_kind='flock'
    printf 'lock            : %s (%s, timeout %ss)\n' "$LOCK_FILE" "$lock_kind" "$LOCK_TIMEOUT"
    if ((TIMEOUT > 0)); then
        timeout_desc="${TIMEOUT}s, signal ${TIMEOUT_SIGNAL}, kill-after ${KILL_AFTER}s"
        if ! have timeout && ! portable_timeout_available; then
            timeout_desc="${timeout_desc} (NOT ENFORCEABLE: no timeout(1) and no perl(1))"
            rc=1
        fi
    fi
    printf 'timeout         : %s\n' "$timeout_desc"
    printf 'log             : %s (max %s bytes, keep %s, format %s)\n' \
        "${LOG_FILE:-<disabled>}" "$LOG_MAX_BYTES" "$LOG_KEEP" "$LOG_FORMAT"
    printf 'error log       : %s\n' "${ERROR_LOG_FILE:-<disabled>}"
    printf 'syslog          : %s\n' "$([ "$SYSLOG" = 'true' ] && printf 'on' || printf 'off')"
    printf 'config file     : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'http client     : %s\n' "$(http_client_resolve 2>/dev/null || printf 'none (release checks, smoke tests and webhooks disabled)')"
    printf 'jq              : %s\n' "$(jq_available 2>/dev/null || printf 'not used; the built-in JSON reader is active')"
    printf 'skip-plugins    : %s\n' "${SKIP_PLUGINS:-<none>}"
    printf 'allow-root      : %s\n' "$ALLOW_ROOT"
    printf 'licence         : %s\n' \
        "$([ -n "$LICENCE_VALUE" ] && printf 'configured (value redacted, handoff %s)' "$LICENCE_HANDOFF" || printf '<not configured>')"
    printf 'dry-run         : %s\n' "$DRY_RUN"
    printf 'fail-on         : %s\n' "$FAIL_ON"
    printf 'strict          : %s\n' "$STRICT"
    printf 'fail-fast       : %s\n' "$FAIL_FAST"
    printf 'jobs            : %s\n' "$JOBS"
    printf 'retry           : %s\n' "$RETRY"
    printf 'stagger         : %ss\n' "$STAGGER"
    printf 'run budget      : %s\n' "$(((MAX_DURATION > 0)) && duration_human "$MAX_DURATION" || printf 'unlimited')"
    printf 'backup          : %s%s\n' "$BACKUP" \
        "$([ "$BACKUP" != 'off' ] && printf ' -> %s (keep %s)' "$(backup_dir_of)" "$KEEP_BACKUPS")"
    printf 'maintenance mode: %s\n' "$MAINTENANCE_MODE"
    printf 'smoke test      : %s\n' "$([ "$SMOKE_TEST" = 'true' ] && printf 'on (expect %s, %ss timeout)' "$SMOKE_EXPECT" "$SMOKE_TIMEOUT" || printf 'off')"
    printf 'multisite       : %s\n' "$MULTISITE"
    printf 'only-active     : %s\n' "$ONLY_ACTIVE"
    printf 'exclude-plugins : %s\n' "${EXCLUDE_PLUGINS:-<none>}"
    printf 'include-sites   : %s\n' "${INCLUDE_SITES:-<none>}"
    printf 'exclude-sites   : %s\n' "${EXCLUDE_SITES:-<none>}"
    printf 'url             : %s\n' "${URL:-<none>}"
    printf 'state file      : %s\n' "${STATE_FILE:-<disabled>}"
    printf 'metrics file    : %s\n' "${METRICS_FILE:-<disabled>}"
    printf 'notification    : %s\n' "$(describe_notify)"

    printf '\n%s== work list ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'file            : %s\n' "$SITES_FILE"
    if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
        printf '  %s%s%s the file does not exist (AUTO_DISCOVER=%s)\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET" "$AUTO_DISCOVER"
        rc=1
    else
        printf 'units           : %s\n' "$UNIT_COUNT"
        if ((UNIT_COUNT == 0)); then
            printf '  %s%s%s the list is empty, or every entry was skipped or filtered out\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        fi
        for ((i = 0; i < UNIT_COUNT; i++)); do
            user="${UNIT_USER[i]}"
            check_report "${UNIT_PATH[i]}" "$user" || rc=1
        done
    fi
    printf '\n'
    return "$rc"
}

describe_notify() {
    local parts=''
    [ "$NOTIFY_ON" = 'never' ] && { printf 'off'; return 0; }
    parts="on ${NOTIFY_ON}"
    [ -n "$NOTIFY_WEBHOOK_URL" ] && parts="${parts}, webhook (${NOTIFY_WEBHOOK_FORMAT})"
    [ -n "$NOTIFY_COMMAND" ] && parts="${parts}, command"
    printf '%s' "$parts"
}

# status_report : what the last run did, without running anything.
#
# The state file is the primary source, because it is structured and complete.
# The log is the fallback, because a host upgraded from an older release has
# logs and no state file, and "your monitoring just went blind" is not an
# acceptable answer to --status.
status_report() {
    local rc=0
    printf '\n%s== last run ==%s\n' "$C_BOLD" "$C_RESET"
    if [ -n "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; then
        printf 'state file      : %s\n' "$STATE_FILE"
        printf '%s\n' "$(head -c 8192 -- "$STATE_FILE" 2>/dev/null)"
    elif [ -n "$LOG_FILE" ] && [ -r "$LOG_FILE" ]; then
        printf 'state file      : %s\n' '<none; falling back to the log>'
        printf '\n%s-- last run headers --%s\n' "$C_BOLD" "$C_RESET"
        grep -a '=== .* started at' "$LOG_FILE" 2>/dev/null | tail -n 5
        printf '\n%s-- last 20 lines --%s\n' "$C_BOLD" "$C_RESET"
        tail -n 20 -- "$LOG_FILE" 2>/dev/null
    else
        printf '%s%s%s no state file and no readable log; nothing has been recorded yet\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        rc=1
    fi

    printf '\n%s== log sizes ==%s\n' "$C_BOLD" "$C_RESET"
    local f
    for f in "$LOG_FILE" "$ERROR_LOG_FILE"; do
        [ -n "$f" ] || continue
        if [ -f "$f" ]; then
            printf '%-40s %10s  %s\n' "$f" "$(human_bytes "$(file_size "$f")")" \
                "$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
        else
            printf '%-40s %10s\n' "$f" '<absent>'
        fi
        local g
        for g in "$f".1 "$f".2 "$f".3; do
            [ -f "$g" ] && printf '%-40s %10s\n' "$g" "$(human_bytes "$(file_size "$g")")"
        done
    done

    printf '\n%s== backups ==%s\n' "$C_BOLD" "$C_RESET"
    local bdir n=0 total=0
    bdir="$(backup_dir_of)"
    if [ -d "$bdir" ]; then
        printf 'directory       : %s\n' "$bdir"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$((n + 1))
            total=$((total + $(file_size "$f")))
        done < <(find "$bdir" -type f \( -name 'db-*.sql' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) -print 2>/dev/null)
        printf 'archives        : %s (%s)\n' "$n" "$(human_bytes "$total")"
        local free
        free="$(free_mib "$bdir" 2>/dev/null || printf '?')"
        printf 'free space      : %s MiB\n' "$free"
        if ((n == 0)); then
            printf '%s%s%s no archive yet; run with --backup db to create one\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        fi
    else
        printf 'directory       : %s (does not exist)\n' "$bdir"
    fi
    printf '\n'
    return "$rc"
}
