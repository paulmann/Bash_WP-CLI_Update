###############################################################################
# Section 28 - plugin inventory and management
###############################################################################

PLUGIN_FIELDS_DEFAULT='name,status,update,version'

plugin_columns() {
    local list="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    printf '%s' "${list//,/ }"
}

# data_sink -> where a machine-readable or tabular payload must go.
#
# In parallel mode a worker's stdout is a file that the parent replays into the
# *right* stream after the barrier, so everything the operator or a parser wants
# has to be routed to the data fragment. An empty result means "the caller's own
# stdout", which is what sink_write turns into no redirection at all -- see the
# note on /dev/stdout in section 3.
#
# Sets DATA_SINK and prints it, so a hot caller can skip the subshell.
DATA_SINK=''
data_sink() {
    if [ "${PARALLEL:-false}" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        DATA_SINK="${WORKER_DIR}/data"
    else
        DATA_SINK=''
    fi
    printf '%s' "$DATA_SINK"
    return 0
}

# plugin_list_site SITE USER URL
plugin_list_site() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local -a fields=()
    local body tsv sink
    read -r -a fields <<<"$(plugin_columns)"

    wp_data "$site" "$user" "$url" plugin list --format=json \
        --fields="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        count_op_failed
        log_error "cannot list plugins on ${site} (exit ${WP_STATUS})"
        log_error_detail 'plugin_list' 'wp plugin list --format=json' \
            "${WP_OUTPUT}${WP_STDERR:+$'\n'"$WP_STDERR"}" "$WP_STATUS"
        return 1
    fi
    if ! body="$(json_array_slice "$WP_OUTPUT")"; then
        count_op_failed
        log_error "wp on ${site} did not return a JSON plugin list"
        log_error_detail 'plugin_list' 'wp plugin list --format=json' "$WP_OUTPUT" 0
        return 1
    fi
    count_op_ok

    if ! tsv="$(printf '%s' "$body" | json_to_tsv "${fields[@]}")"; then
        log_error "cannot parse the JSON plugin list from ${site}"
        return 1
    fi
    tsv="$(printf '%s\n' "$tsv" | plugin_filter)"

    sink="$(data_sink)"
    case "$OUTPUT_FORMAT" in
        json) printf '%s\n' "$body" | sink_write "$sink" ;;
        csv) printf '%s\n' "$tsv" | tsv_to_csv | sink_write "$sink" ;;
        tsv) printf '%s\n' "$tsv" | sink_write "$sink" ;;
        table | *)
            {
                printf '%s%s%s\n' "$C_BOLD" "$site" "$C_RESET"
                printf '%s\n' "$tsv" | table_render "$PAGE_LIMIT"
            } | sink_write "$sink"
            ;;
    esac
    return 0
}

# plugin_filter < TSV -> TSV, keeping the rows whose first column matches --name
# as a case-insensitive *substring*. A substring match is deliberate: it is what
# an operator means by "the woo one", and it can never be interpreted as a
# pattern, so nothing needs escaping.
plugin_filter() {
    local needle="${FILTER_NAME,,}" line first=1 lower
    while IFS= read -r line || [ -n "$line" ]; do
        if ((first)); then printf '%s\n' "$line"; first=0; continue; fi
        [ -n "$needle" ] || { printf '%s\n' "$line"; continue; }
        lower="${line,,}"
        case "$lower" in
            *"$needle"*) printf '%s\n' "$line" ;;
        esac
    done
    return 0
}

# plugin_select_targets SITE USER URL -> fills PLUGIN_SELECTION (newline
# separated slugs) honouring --only-active and --exclude-plugins.
PLUGIN_SELECTION=''
plugin_select_targets() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local body tsv line name slug status update
    local -A excluded=()
    local ex
    PLUGIN_SELECTION=''

    while IFS= read -r ex; do
        [ -n "$ex" ] && excluded["${ex,,}"]=1
    done < <(split_csv "$EXCLUDE_PLUGINS")

    wp_data "$site" "$user" "$url" plugin list --format=json --fields=name,slug,status,update
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        log_error "cannot enumerate plugins on ${site} (wp exit ${WP_STATUS}); nothing was updated"
        return 1
    fi
    if ! body="$(json_array_slice "$WP_OUTPUT")"; then
        log_error "wp on ${site} did not return a JSON plugin list; nothing was updated"
        return 1
    fi
    if ! tsv="$(printf '%s' "$body" | json_to_tsv name slug status update)"; then
        log_error "cannot parse the plugin list from ${site}; nothing was updated"
        return 1
    fi
    while IFS=$'\t' read -r name slug status update; do
        [ "$slug" = 'slug' ] && continue
        [ -n "$slug" ] || continue
        if [ -n "${excluded[${slug,,}]-}" ] || [ -n "${excluded[${name,,}]-}" ]; then
            log_debug "excluded by --exclude-plugins: ${slug}"
            continue
        fi
        if [ "$ONLY_ACTIVE" = 'true' ]; then
            if [ "$status" != 'active' ]; then
                log_debug "not active, skipped: ${slug}"
                continue
            fi
            if [ "$update" != 'available' ]; then
                log_debug "up to date, skipped: ${slug}"
                continue
            fi
        fi
        PLUGIN_SELECTION+="${PLUGIN_SELECTION:+$'\n'}${slug}"
    done <<<"$tsv"
    return 0
}

# plugin_resolve_slug SITE USER URL NAME -> exactly one slug.
#
# Exact match on slug or display name wins outright; otherwise a case-insensitive
# substring match, and ambiguity is an error rather than a coin toss. Deleting
# "the seo one" on a site that has two of them is not a decision a maintenance
# tool should make quietly.
plugin_resolve_slug() { # SITE USER URL NAME
    local site="$1" user="$2" url="$3" needle="${4,,}"
    local body tsv n s st exact='' match='' matches=0
    wp_data "$site" "$user" "$url" plugin list --format=json --fields=name,slug,status
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT")" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv name slug status)" || return 1
    while IFS=$'\t' read -r n s st; do
        [ "$s" = 'slug' ] && continue
        [ -n "$s" ] || continue
        if [ "${n,,}" = "$needle" ] || [ "${s,,}" = "$needle" ]; then
            exact="$s"
            break
        fi
        case "${n,,}" in *"$needle"*) match="$s"; matches=$((matches + 1)) ;; esac
        case "${s,,}" in
            *"$needle"*)
                # A slug that equals an already-counted name match is the same
                # plugin, not a second candidate. Counting it twice turned
                # "jetpack" into an ambiguity error on every site that had it.
                [ "$match" = "$s" ] || { match="$s"; matches=$((matches + 1)); }
                ;;
        esac
    done <<<"$tsv"
    if [ -n "$exact" ]; then
        printf '%s' "$exact"
        return 0
    fi
    if ((matches == 0)); then
        log_error "no plugin matching '${4}' on ${site}"
        return 1
    fi
    if ((matches > 1)); then
        log_error "'${4}' is ambiguous on ${site}; pass the exact slug"
        return 1
    fi
    printf '%s' "$match"
    return 0
}

# mode_plugin_manage SITE USER URL
mode_plugin_manage() { # SITE USER URL
    local site="$1" user="$2" url="$3" slug='' wp_action=''
    case "$PLUGIN_ACTION" in
        activate | deactivate | delete | install | update | status)
            wp_action="$PLUGIN_ACTION"
            ;;
        *)
            log_error "--plugin-manage needs --action activate|deactivate|delete|install|update|status"
            return 1
            ;;
    esac
    [ -n "$PLUGIN_NAME" ] || { log_error "--plugin-manage needs --name NAME"; return 1; }

    # `install` takes a wordpress.org slug, which by definition is not installed
    # yet, so there is nothing to resolve and no local list to consult.
    if [ "$wp_action" = 'install' ]; then
        if [[ ! "$PLUGIN_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
            log_error "--name for --action install must be a wordpress.org slug (lowercase letters, digits, dots, dashes)"
            return 1
        fi
        if [ "$DRY_RUN" != 'true' ] && ! confirm_destructive "install plugin '${PLUGIN_NAME}' on ${site}?"; then
            return 1
        fi
        run_wp "$site" "$user" "$url" plugin install "$PLUGIN_NAME"
        return $?
    fi

    slug="$(plugin_resolve_slug "$site" "$user" "$url" "$PLUGIN_NAME")" || return 1
    log_debug "resolved '${PLUGIN_NAME}' to '${slug}' on ${site}"

    case "$wp_action" in
        status)
            run_wp "$site" "$user" "$url" plugin status "$slug"
            return $?
            ;;
        update)
            run_wp "$site" "$user" "$url" plugin update "$slug"
            return $?
            ;;
        delete)
            if ! confirm_destructive "delete plugin '${slug}' on ${site}? This cannot be undone."; then
                return 1
            fi
            # After this call there is no other copy of the plugin anywhere.
            backup_plugin "$site" "$slug"
            # Deactivate first. `plugin delete` on an active plugin leaves its
            # options, tables and cron events behind, because the deactivation
            # hooks never run; deactivating first gives the plugin the chance to
            # clean up after itself. A failure here is not fatal: the operator
            # asked for the plugin to go, and deleting an inactive plugin is
            # still what they want.
            run_wp_soft "$site" "$user" "$url" plugin deactivate "$slug" >/dev/null
            run_wp "$site" "$user" "$url" plugin delete "$slug"
            return $?
            ;;
    esac
    run_wp "$site" "$user" "$url" plugin "$wp_action" "$slug"
}

mode_list_plugins() { # SITE USER URL
    plugin_list_site "$1" "$2" "$3"
}
