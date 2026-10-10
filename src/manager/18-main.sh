###############################################################################
# Section 46 - startup checks
###############################################################################

# startup_checks : everything that must be true before a single site is touched.
#
# Each check either fixes something quietly (resolving the wp binary), warns once
# about a degraded capability (no HTTP client, so no smoke test), or refuses to
# run (no WP-CLI, or a version below the floor). A degraded capability is not a
# reason to stop a maintenance run; a missing tool it depends on is.
startup_checks() {
    local v
    if ! wp_ensure; then
        exit "$EXIT_ENV"
    fi
    if ! wpcli_version_gate; then
        exit "$EXIT_ENV"
    fi
    if [ -n "$USER_OVERRIDE" ]; then
        if ! is_valid_username "$USER_OVERRIDE"; then
            env_error "--user '${USER_OVERRIDE}' is not a valid account name"
        fi
        id -u "$USER_OVERRIDE" >/dev/null 2>&1 ||
            env_error "--user ${USER_OVERRIDE}: no such system user"
    fi
    for v in $USER_ENV; do
        if ! is_set "$v"; then
            log_warn "--user-env: '${v}' is not set in this environment; it will not be passed on"
        fi
    done
    if [ "$SMOKE_TEST" = 'true' ] && ! http_client_resolve >/dev/null 2>&1; then
        log_warn '--smoke-test needs curl(1) or wget(1); the smoke test is disabled for this run'
    fi
    if [ -n "$NOTIFY_WEBHOOK_URL" ] && [ "$NOTIFY_ON" != 'never' ] &&
       ! http_client_resolve >/dev/null 2>&1; then
        log_warn 'a webhook is configured but no HTTP client is installed; notifications will not be sent'
    fi
    if [ -n "$NOTIFY_COMMAND" ] && [ "$NOTIFY_ON" != 'never' ] && [ ! -x "$NOTIFY_COMMAND" ]; then
        log_warn "NOTIFY_COMMAND is not an executable file: ${NOTIFY_COMMAND}"
    fi
    if ((TIMEOUT > 0)) && ! have timeout && ! portable_timeout_available; then
        log_warn "--timeout ${TIMEOUT} cannot be enforced: neither timeout(1) nor perl(1) is installed"
    fi
    if [ "$BACKUP" != 'off' ] && [ -n "$BACKUP_DIR" ]; then
        if ! ensure_parent_dir "${BACKUP_DIR}/.probe"; then
            log_warn "the backup directory ${BACKUP_DIR} cannot be created; backups will fail and skip their sites"
        fi
    fi
    if [ -n "$LICENCE_VALUE" ]; then
        redact_register "$LICENCE_VALUE"
    fi
    # The config-layer spelling of the same secret gets registered too, so it is
    # masked from the first log line onwards and not only from the moment the
    # Astra step happens to resolve it.
    if [ -n "${LICENCE:-}" ]; then
        redact_register "$LICENCE"
    fi
    return 0
}

banner() {
    [ "$QUIET" = 'true' ] && return 0
    # The banner is prose, not data: it goes to stderr so that stdout carries
    # only what a machine would want to parse, in every format.
    local line
    line="$(printf '%*s' 72 '')"
    {
        printf '\n%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf ' %s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
        printf ' mode: %s%s%s\n' "$C_BOLD" "$MODE" "$C_RESET"
        printf '%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf '  %-18s %s\n' 'units:' \
            "$([ -n "$TARGET_SITE" ] && printf '%s' "$TARGET_SITE" || printf '%s from %s' "$UNIT_COUNT" "$SITES_FILE")"
        printf '  %-18s %s\n' 'wp-cli:' "${WP_RESOLVED}${WP_CLI_VERSION:+ (${WP_CLI_VERSION})}"
        printf '  %-18s %s\n' 'user switch:' "$(switch_mechanism)"
        printf '  %-18s %s\n' 'log level:' "$LOG_LEVEL"
        if ((JOBS > 1)); then
            printf '  %-18s %s\n' 'parallelism:' "${JOBS} units per batch"
        fi
        if [ "$BACKUP" != 'off' ]; then
            printf '  %-18s %s\n' 'backup:' "${BACKUP} -> $(backup_dir_of) (keep ${KEEP_BACKUPS})"
        fi
        if [ -n "$URL" ]; then
            printf '  %-18s %s\n' 'url:' "$URL"
        fi
        if [ "$MULTISITE" = 'all' ]; then
            printf '  %-18s %s\n' 'multisite:' 'every subsite is a separate unit'
        fi
        if [ "$MAINTENANCE_MODE" = 'true' ]; then
            printf '  %-18s %s\n' 'maintenance:' 'sites go offline while they are updated'
        fi
        if [ "$SMOKE_TEST" = 'true' ]; then
            printf '  %-18s %s\n' 'smoke test:' "expect HTTP ${SMOKE_EXPECT}"
        fi
        if [ "$NO_USER_SWITCH" = 'true' ]; then
            printf '  %-18s %sfiles created by this run will be owned by %s%s\n' 'warning:' "$C_YELLOW" "$(id -un)" "$C_RESET"
        fi
        if ((MAX_DURATION > 0)); then
            printf '  %-18s %s\n' 'run budget:' "$(duration_human "$MAX_DURATION")"
        fi
        if [ "$DRY_RUN" = 'true' ]; then
            printf '  %-18s %sDRY RUN - nothing will be executed%s\n' 'mode:' "$C_YELLOW" "$C_RESET"
        fi
        printf '\n'
    } >&2
    return 0
}

# units_build_raw : the loose variant used by --check.
#
# --check exists to explain why a fleet is broken, so it cannot apply the filters
# that a run applies: a site that is not a directory, a directory that is not a
# WordPress root, and an owner that cannot be determined are precisely the three
# findings the operator is looking for. Skipping them would make --check report
# "all good" about a list of holes.
units_build_raw() {
    local site user
    units_reset
    for site in ${SITES[@]+"${SITES[@]}"}; do
        user="${SITE_FORCED_USER[$site]-}"
        if [ -z "$user" ]; then
            user="$(site_user_resolve "$site" 2>/dev/null)" || user=''
        fi
        units_add "$site" "$user" "$URL" "$(path_base "$site")"
    done
    return 0
}

###############################################################################
# Section 47 - main
###############################################################################

# colour_pre_scan : look at the command line for a colour preference before any
# output happens. --help and --version are printed from inside parse_args, so by
# the time the real parse finishes it is too late to colour them.
colour_pre_scan() {
    local prev='' a
    for a in "$@"; do
        case "$prev" in
            --color) COLOR="${a,,}"; CLI_SET[COLOR]=1 ;;
        esac
        case "$a" in
            --no-color) COLOR='never'; CLI_SET[COLOR]=1 ;;
            --color=*) COLOR="${a#--color=}"; COLOR="${COLOR,,}"; CLI_SET[COLOR]=1 ;;
        esac
        prev="$a"
    done
    color_init
    return 0
}

# run_wpcli_mode : the WP-CLI self-management path.
#
# These four modes do not need a site list, do not need root, and must work on a
# host where every WordPress installation is broken -- which is exactly when an
# operator reaches for them. They therefore run before the site list is read and
# before the environment checks that assume one.
run_wpcli_mode() {
    local rc=0
    log_init
    now_epoch >/dev/null; START_TIME="$EPOCH_NOW"
    log_info "${PROG_NAME} ${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"
    if [ "$NO_LOCK" != 'true' ]; then
        lock_acquire
    fi
    case "$MODE" in
        wpcli-check) mode_wpcli_check || rc=$? ;;
        wpcli-update | wpcli-install) mode_wpcli_update || rc=$? ;;
        wpcli-rollback) mode_wpcli_rollback || rc=$? ;;
    esac
    SUMMARY_PRINTED='true'
    exit "$rc"
}

main() {
    # Defaults first, then the command line, then the file and environment
    # layers. Reversing any two of these silently loses a setting: parse_args
    # writes into the same variables config_init_defaults fills, so a defaults
    # pass that runs afterwards would erase every flag the operator typed.
    config_init_defaults
    colour_pre_scan "$@"
    parse_args "$@"

    # --- commands that need no configuration at all -------------------------
    if [ "$LIST_MODES" = 'true' ]; then
        list_modes
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ -n "$COMPLETION" ]; then
        completion_script "$COMPLETION"
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ "$SHOW_VERSION_DETAIL" = 'true' ]; then
        version_detail
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    # config_load refuses to overwrite a key the command line already fixed, and
    # validate_args then checks the *effective* value no matter which layer
    # produced it, so a bad flag exits 2 and a bad file exits 4.
    config_load
    config_apply

    if [ "$INIT_CONFIG_REQUESTED" = 'true' ]; then
        init_config "$INIT_CONFIG"
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ "$PRINT_CONFIG" = 'true' ]; then
        color_init
        print_config
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    validate_args
    color_init          # re-resolved: a config layer may have changed COLOR

    # --- inspection commands that work without wp, without root, without a lock
    if [ "$LIST_SITES" = 'true' ]; then
        # Runs after validate_args, because that is where the dual meaning of -J
        # is resolved; before it, `--list-sites --json` would print the table.
        print_site_list
        SUMMARY_PRINTED='true'
        if ((UNIT_COUNT == 0)); then exit "$EXIT_NOTFOUND"; fi
        exit "$EXIT_OK"
    fi

    case "$MODE" in
        wpcli-check | wpcli-update | wpcli-install | wpcli-rollback)
            run_wpcli_mode
            ;;
    esac

    log_init
    now_epoch >/dev/null; START_TIME="$EPOCH_NOW"
    log_info "${PROG_NAME} ${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"
    log_debug "script directory: ${SCRIPT_DIR}"
    log_debug "config file used: ${CONFIG_FILE_USED:-<none>}"
    log_debug "build: ${BUILD_ID} (${BUILD_DATE})"

    if [ "$MODE" = 'status' ]; then
        local src=0
        status_report || src=$?
        SUMMARY_PRINTED='true'
        exit "$src"
    fi

    # --- the fleet path ----------------------------------------------------
    if [ -n "$TARGET_SITE" ]; then
        if [ ! -d "$TARGET_SITE" ]; then
            if [ "$MODE" = 'check' ]; then
                SITES=("$TARGET_SITE")
                SITE_FORCED_USER=()
            else
                log_error "--site is not a directory: ${TARGET_SITE}"
                print_summary "$EXIT_ERROR"
                SUMMARY_PRINTED='true'
                exit "$EXIT_ERROR"
            fi
        else
            SITES=("$TARGET_SITE")
            SITE_FORCED_USER=()
            if [ -n "$SITE_USER" ]; then
                SITE_FORCED_USER["$TARGET_SITE"]="$SITE_USER"
            fi
        fi
    else
        if [ "$MODE" = 'check' ]; then
            # --check is read-only, so it must not run discovery: writing a site
            # list is a change, and "check what would happen" that changes
            # something is not a check. It reports the version gate instead of
            # enforcing it, for the same reason.
            if wp_ensure 2>/dev/null; then
                wpcli_version_gate || log_warn 'the WP-CLI version gate failed; --check reports it and changes nothing'
            fi
            load_site_list "$SITES_FILE" || SITES=()
        else
            if ! ensure_site_list; then
                # A missing list is an environment problem; an empty one is not an
                # error at all, it just means there is nothing to do.
                if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
                    log_error "no site list to work from: ${SITES_FILE}"
                    print_summary "$EXIT_ENV"
                    SUMMARY_PRINTED='true'
                    exit "$EXIT_ENV"
                fi
            fi
            if ! load_site_list "$SITES_FILE"; then
                print_summary "$EXIT_ENV"
                SUMMARY_PRINTED='true'
                exit "$EXIT_ENV"
            fi
        fi
    fi

    if [ "$MODE" = 'check' ]; then
        units_build_raw
        run_check_mode
        local crc=$?
        SUMMARY_PRINTED='true'
        exit "$crc"
    fi

    startup_checks
    units_build
    privilege_preflight

    if ((UNIT_COUNT == 0)); then
        # "Nothing to do" is a warning, and --strict exists precisely so that a
        # cron job can be told to treat one as a failure: a maintenance run that
        # silently processed zero sites is the failure mode nobody notices.
        log_warn 'no work unit to process; nothing to do'
        print_summary "$EXIT_NOTFOUND"
        emit_state_and_metrics "$EXIT_NOTFOUND"
        notify_run "$EXIT_NOTFOUND"
        SUMMARY_PRINTED='true'
        if [ "$STRICT" = 'true' ] || [ "$FAIL_ON" != 'never' ]; then
            exit "$EXIT_NOTFOUND"
        fi
        exit "$EXIT_OK"
    fi

    if [ "$NO_LOCK" != 'true' ]; then
        lock_acquire
    else
        log_debug 'the lock is disabled by --no-lock'
    fi

    banner
    report_init
    log_info "processing ${UNIT_COUNT} unit(s) in mode '${MODE}'"

    run_fleet || true
    report_finish
    finish_run 0
}

main "$@"
