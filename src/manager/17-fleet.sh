###############################################################################
# Section 41 - the report buffer
###############################################################################
#
# A table cannot be aligned until its widest row is known, and a fleet report
# does not know its widest row until the last site has answered. The rows are
# therefore buffered: in a sequential run in one file, in a parallel run in one
# file per worker that the parent appends in site order after each barrier. The
# buffering is file-based rather than array-based for one reason only: an array
# filled inside a worker subshell disappears when the worker exits, and that is a
# bug that shows up exclusively under -j, which is the worst possible time for a
# bug to be exclusive.

REPORT_BUFFER=''
REPORT_TABLE_FILE=''

# report_init : create the buffer for a --report run.
report_init() {
    [ "$MODE" = 'report' ] || return 0
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.report.XXXXXX" 2>/dev/null)" || return 0
        chmod 700 "$WORK_DIR" 2>/dev/null
        tmp_register "$WORK_DIR"
    fi
    REPORT_TABLE_FILE="${WORK_DIR}/report-rows.tsv"
    : >"$REPORT_TABLE_FILE" 2>/dev/null
    REPORT_BUFFER="$REPORT_TABLE_FILE"
    return 0
}

# report_row_sink -> where one TSV row goes
report_row_sink() {
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '%s/rows' "$WORKER_DIR"
        return 0
    fi
    if [ -n "$REPORT_BUFFER" ]; then
        printf '%s' "$REPORT_BUFFER"
        return 0
    fi
    printf ''
    return 0
}

# report_finish : render the buffered table once every unit has reported.
report_finish() {
    [ -n "$REPORT_TABLE_FILE" ] || return 0
    [ -s "$REPORT_TABLE_FILE" ] || { log_debug 'the report collected no rows'; return 0; }
    local i rows=0
    while IFS= read -r _; do rows=$((rows + 1)); done <"$REPORT_TABLE_FILE"
    case "$OUTPUT_FORMAT" in
        table)
            {
                printf '%s\n' "$REPORT_HEADERS"
                cat -- "$REPORT_TABLE_FILE"
            } | table_render "$PAGE_LIMIT"
            ;;
        tsv)
            printf '%s\n' "$REPORT_HEADERS"
            cat -- "$REPORT_TABLE_FILE"
            ;;
        csv)
            {
                printf '%s\n' "$REPORT_HEADERS"
                cat -- "$REPORT_TABLE_FILE"
            } | tsv_to_csv
            ;;
    esac
    log_debug "report rendered ${rows} row(s) in ${OUTPUT_FORMAT} format"
    return 0
}

###############################################################################
# Section 42 - maintenance mode
###############################################################################
#
# WordPress 5.5 ships a maintenance mode and WP-CLI 2.4 exposes it. Turning it on
# for the duration of an update is the difference between "the shop was down for
# forty seconds" and "a customer bought a product at half price because the cart
# was rebuilt mid-request". It is off by default because a fleet of 200 sites
# going into maintenance mode at 03:00 is a decision the operator has to make,
# not one the tool makes for them.

MAINTENANCE_SUPPORTED=''
MAINTENANCE_ACTIVE='false'

maintenance_start() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    [ "$MAINTENANCE_MODE" = 'true' ] || return 0
    [ "$DRY_RUN" = 'true' ] && return 0
    if [ -z "$MAINTENANCE_SUPPORTED" ]; then
        if wp_supported "$site" "$user" maintenance-mode; then
            MAINTENANCE_SUPPORTED='yes'
        else
            MAINTENANCE_SUPPORTED='no'
            log_warn 'this WP-CLI has no maintenance-mode command (2.4+ and WordPress 5.5+ needed); --maintenance-mode is ignored'
        fi
    fi
    [ "$MAINTENANCE_SUPPORTED" = 'yes' ] || return 0
    if run_wp_soft "$site" "$user" "$url" maintenance-mode activate >/dev/null; then
        MAINTENANCE_ACTIVE='true'
        log_debug "$(path_base "$site"): maintenance mode on"
    else
        log_warn "$(path_base "$site"): maintenance mode could not be activated; continuing without it"
    fi
    return 0
}

# maintenance_stop : always called, including after a failure. Leaving a site in
# maintenance mode because an update failed is a second outage caused by the tool
# that was supposed to prevent one.
maintenance_stop() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    [ "$MAINTENANCE_ACTIVE" = 'true' ] || return 0
    MAINTENANCE_ACTIVE='false'
    [ "$DRY_RUN" = 'true' ] && return 0
    if run_wp_soft "$site" "$user" "$url" maintenance-mode deactivate >/dev/null; then
        log_debug "$(path_base "$site"): maintenance mode off"
    else
        # This is the one warning in the tool worth reading twice: a site left in
        # maintenance mode is offline to its visitors and online to wp.
        log_warn "$(path_base "$site"): MAINTENANCE MODE COULD NOT BE DEACTIVATED; run 'wp maintenance-mode deactivate' in ${site} now"
    fi
    return 0
}

###############################################################################
# Section 43 - smoke test
###############################################################################
#
# "The update succeeded" and "the site still works" are different claims, and
# only the second one is interesting. A white screen after a plugin update is the
# most common fleet incident there is, and it is invisible to every exit code
# WP-CLI returns. Probing the site URL after the change costs one HTTP request
# and turns that incident into a line in the report at 03:12 instead of a phone
# call at 08:00.

SMOKE_PROBED=0

# smoke_test SITE USER URL -> 0 healthy, 1 unhealthy, 2 not probed
smoke_test() { # SITE USER URL
    local site="$1" user="$2" url="$3" target='' code=''
    [ "$SMOKE_TEST" = 'true' ] || return 2
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would probe the site URL after the change"
        return 2
    fi
    if ! http_client_resolve >/dev/null 2>&1; then
        return 2
    fi
    target="$url"
    if [ -z "$target" ]; then
        target="$(site_home "$site" "$user")"
    fi
    case "$target" in
        http://* | https://*) ;;
        *)
            log_debug "$(path_base "$site"): no usable site URL for the smoke test"
            return 2
            ;;
    esac
    SMOKE_PROBED=$((SMOKE_PROBED + 1))
    code="$(http_status "$target" "$SMOKE_TIMEOUT")"
    if [ "$code" = '000' ]; then
        log_warn "$(path_base "$site"): the smoke test could not reach ${target} (no answer within ${SMOKE_TIMEOUT}s)"
    elif in_csv_list "$code" "$SMOKE_EXPECT"; then
        log_ok "$(path_base "$site"): smoke test passed (HTTP ${code} from ${target})"
        STATS_SMOKE_OK=$((STATS_SMOKE_OK + 1))
        return 0
    else
        log_warn "$(path_base "$site"): the smoke test got HTTP ${code} from ${target}, expected one of ${SMOKE_EXPECT}"
    fi
    STATS_SMOKE_FAILED=$((STATS_SMOKE_FAILED + 1))
    if [ "$SMOKE_ON_FAIL" = 'warn' ]; then
        return 0
    fi
    return 1
}

###############################################################################
# Section 44 - per-unit processing
###############################################################################

# dispatch_mode SITE USER URL -> the mode function's status
dispatch_mode() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    case "$MODE" in
        full) mode_full "$site" "$user" "$url" ;;
        core) mode_core "$site" "$user" "$url" ;;
        plugins) mode_plugins "$site" "$user" "$url" ;;
        themes) mode_themes "$site" "$user" "$url" ;;
        languages) mode_languages "$site" "$user" "$url" ;;
        cache) mode_cache "$site" "$user" "$url" ;;
        cleanup) mode_cleanup "$site" "$user" "$url" ;;
        db-optimize) mode_db_optimize "$site" "$user" "$url" ;;
        db-fix) mode_db_fix "$site" "$user" "$url" ;;
        cron) mode_cron "$site" "$user" "$url" ;;
        astra) mode_astra "$site" "$user" "$url" ;;
        verify) mode_verify "$site" "$user" "$url" ;;
        report) mode_report "$site" "$user" "$url" ;;
        security) mode_security "$site" "$user" "$url" ;;
        secrets) mode_secrets "$site" "$user" "$url" ;;
        list-plugins) mode_list_plugins "$site" "$user" "$url" ;;
        plugin-manage) mode_plugin_manage "$site" "$user" "$url" ;;
        restore) mode_restore "$site" "$user" ;;
        *)
            log_error "internal: unknown mode '${MODE}'"
            return 1
            ;;
    esac
}

CURRENT_UNIT=0

# process_unit INDEX : everything that happens to one work unit, in order.
#
# The order is the contract, and each step is there for a reason that somebody
# learned the hard way:
#   1. backup, before anything is touched, and a failed backup skips the site;
#   2. maintenance mode on, so visitors do not see a half-updated site;
#   3. the mode itself;
#   4. maintenance mode off, unconditionally, even after a failure;
#   5. the smoke test, because "wp exited 0" is not "the site works";
#   6. the record, so a JSON consumer sees this unit as soon as it lands.
process_unit() { # INDEX
    local i="$1"
    local site="${UNIT_PATH[i]}" user="${UNIT_USER[i]}" url="${UNIT_URL[i]}"
    local rc=0 attempt=0 tries=1
    CURRENT_UNIT="$i"
    CURRENT_SITE="$site" CURRENT_USER="$user" CURRENT_URL="$url"
    CURRENT_LABEL="${UNIT_LABEL[i]}"
    now_epoch >/dev/null; CURRENT_START="$EPOCH_NOW"
    MAINTENANCE_ACTIVE='false'
    SITE_HOME_CACHE='' SITE_HOME_CACHE_FOR=''
    WP_ERR_FILE=''

    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    if [ -n "$url" ]; then
        log_info "site ${site} [${url}] (as ${user})"
    else
        log_info "site ${site} (as ${user})"
    fi

    if ! maybe_backup "$site" "$user"; then
        if [ "$FAIL_ON" != 'never' ]; then
            log_error "${site}: the backup failed; skipping this site rather than updating it unprotected"
            UNIT_STATUS["${UNIT_LABEL[i]}"]='BACKUP_FAILED'
            STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
            now_epoch >/dev/null
            UNIT_ELAPSED[i]=$((EPOCH_NOW - CURRENT_START))
            emit_unit_record "$i" "${UNIT_STATUS[${UNIT_LABEL[i]}]}"
            return 1
        fi
        log_warn "${site}: the backup failed and --fail-on never says to continue unprotected"
    fi

    is_uint "$RETRY" || RETRY=0
    tries=$((RETRY + 1))
    local ops_before="$STATS_OPS_OK" fails_before="$STATS_OPS_FAILED"
    while :; do
        attempt=$((attempt + 1))
        maintenance_start "$site" "$user" "$url"
        dispatch_mode "$site" "$user" "$url"
        rc=$?
        maintenance_stop "$site" "$user" "$url"
        if ((rc == 0)) || ((attempt >= tries)); then
            break
        fi
        STATS_RETRIES=$((STATS_RETRIES + 1))
        log_warn "${site}: attempt ${attempt} of ${tries} failed; retrying"
        sleep 1
    done
    # Per-unit counters, so the JSON report and the metrics file can say which
    # site was expensive and which one produced the failures. The deltas are
    # taken from the run-wide counters because a worker owns them exclusively.
    UNIT_OPS_OK[i]=$((STATS_OPS_OK - ops_before))
    UNIT_OPS_FAILED[i]=$((STATS_OPS_FAILED - fails_before))

    if ((rc == 0)) && [ "$SMOKE_TEST" = 'true' ] && ! mode_is_readonly "$MODE"; then
        if ! smoke_test "$site" "$user" "$url"; then
            log_error "${site}: the update reported success but the site did not answer correctly"
            rc=1
        fi
    fi

    now_epoch >/dev/null
    UNIT_ELAPSED[i]=$((EPOCH_NOW - CURRENT_START))
    if ((rc == 0)); then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        UNIT_STATUS["${UNIT_LABEL[i]}"]='OK'
        log_ok "$(path_base "$site"): finished in $(duration_human "${UNIT_ELAPSED[i]}")"
    else
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        UNIT_STATUS["${UNIT_LABEL[i]}"]='FAILED'
        log_error "unit failed: ${UNIT_LABEL[i]} ($(duration_human "${UNIT_ELAPSED[i]}"))"
    fi
    emit_unit_record "$i" "${UNIT_STATUS[${UNIT_LABEL[i]}]}"
    return "$rc"
}

# emit_unit_record INDEX STATUS : the JSON Lines record for one unit.
emit_unit_record() { # INDEX STATUS
    [ "$JSON_LINES" = 'true' ] || return 0
    local i="$1" sink
    data_sink
    sink="$DATA_SINK"
    printf '{"type":"site","path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s}\n' \
        "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
        "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
        "$(json_quote "$2")" \
        "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" | sink_append "$sink"
    return 0
}

###############################################################################
# Section 45 - fleet execution
###############################################################################
#
# Parallelism is batched, not a continuous pool: bash 4.2 has no `wait -n`, so a
# pool would need a job server and a fifo. A batch barrier is one `wait`, and on a
# fleet of similar sites the difference is seconds.
#
# Four things have to survive the fork, and none of them survives by itself:
#
#   1. Counters. A subshell cannot increment a parent variable, so every worker
#      writes its numbers to a result file and the parent folds them in. Reading a
#      counter inside the subshell -- what an early draft did -- reports the value
#      from before the site started.
#   2. Console output. Interleaved lines from concurrent sites are unreadable, so
#      a worker writes to its own fragment and the parent replays the fragments
#      in site order after the barrier.
#   3. Log lines. The same problem, worse, because the log file is shared. In
#      parallel mode log() writes to the worker fragment, and the parent appends
#      the fragments in order.
#   4. Data. `--format json` must stay parseable, so machine-readable output is
#      emitted by the parent during the ordered replay, never by the workers.

worker_dir() { printf '%s/w%s' "$WORK_DIR" "$1"; }

worker_init() { # INDEX
    local d
    d="$(worker_dir "$1")"
    mkdir -p -- "$d" || return 1
    : >"${d}/out"
    : >"${d}/log"
    : >"${d}/data"
    : >"${d}/rows"
    return 0
}

# worker_run INDEX : the body of one parallel worker.
worker_run() { # INDEX
    local idx="$1" d rc=0
    local site="${UNIT_PATH[idx]}" user="${UNIT_USER[idx]}"
    d="$(worker_dir "$idx")"
    WORKER_DIR="$d"
    PARALLEL='true'
    # A forked worker inherits the parent's counters, and the parent has already
    # folded in the previous batches by the time this one starts. Zeroing them
    # here makes the numbers this worker writes exactly its own contribution,
    # which is the only thing the parent can safely add up. Without this, every
    # batch after the first reports a running total and the summary
    # double-counts.
    STATS_OPS_OK=0
    STATS_OPS_FAILED=0
    STATS_SITES_TOTAL=0
    STATS_SITES_OK=0
    STATS_SITES_FAILED=0
    STATS_WARNINGS=0
    STATS_FINDINGS=0
    STATS_CRITICAL=0
    STATS_CLEANED=0
    STATS_RETRIES=0
    STATS_SMOKE_OK=0
    STATS_SMOKE_FAILED=0
    STATS_BACKUPS=0
    WP_ERR_FILE=''
    process_unit "$idx" >"${d}/out" 2>&1
    rc=$?
    PARALLEL='false'
    WORKER_DIR=''
    {
        printf 'rc=%s\n' "$rc"
        printf 'ops_ok=%s\n' "$STATS_OPS_OK"
        printf 'ops_failed=%s\n' "$STATS_OPS_FAILED"
        printf 'sites_total=%s\n' "$STATS_SITES_TOTAL"
        printf 'sites_ok=%s\n' "$STATS_SITES_OK"
        printf 'sites_failed=%s\n' "$STATS_SITES_FAILED"
        printf 'warnings=%s\n' "$STATS_WARNINGS"
        printf 'findings=%s\n' "$STATS_FINDINGS"
        printf 'critical=%s\n' "$STATS_CRITICAL"
        printf 'cleaned=%s\n' "$STATS_CLEANED"
        printf 'retries=%s\n' "$STATS_RETRIES"
        printf 'smoke_ok=%s\n' "$STATS_SMOKE_OK"
        printf 'smoke_failed=%s\n' "$STATS_SMOKE_FAILED"
        printf 'backups=%s\n' "$STATS_BACKUPS"
        printf 'elapsed=%s\n' "${UNIT_ELAPSED[idx]-0}"
        printf 'status=%s\n' "${UNIT_STATUS[${UNIT_LABEL[idx]}]-UNKNOWN}"
        printf 'wp_version=%s\n' "${UNIT_WP_VERSION[${UNIT_PATH[idx]}]-}"
    } >"${d}/res"
    return 0
}

# read_counter KEY FILE -> an integer from a result file, 0 when absent
read_counter() { # KEY FILE
    local key="$1" file="$2" v=''
    [ -r "$file" ] || { printf '0'; return 0; }
    v="$(sed -n "s/^${key}=//p" -- "$file" 2>/dev/null | head -n 1)"
    v="${v//[^0-9]/}"
    printf '%s' "${v:-0}"
    return 0
}

# read_field KEY FILE -> a raw string from a result file
read_field() { # KEY FILE
    local key="$1" file="$2"
    [ -r "$file" ] || return 0
    sed -n "s/^${key}=//p" -- "$file" 2>/dev/null | head -n 1
}

# fold_worker INDEX : read one worker's results back into the parent, replay its
# console output, append its log lines, emit its data.
fold_worker() { # INDEX
    local idx="$1" d rc ops_ok ops_failed warnings findings critical
    local cleaned retries smoke_ok smoke_failed backups elapsed status wpver
    d="$(worker_dir "$idx")"
    if [ ! -r "${d}/res" ]; then
        # A worker that produced no result file was killed: OOM, SIGKILL, a full
        # disk. Say so instead of silently counting it as a success, which is what
        # the first version did and which made a memory-starved host look healthy.
        log_error "the worker for ${UNIT_LABEL[idx]} produced no result; counting it as failed"
        STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        UNIT_STATUS["${UNIT_LABEL[idx]}"]='FAILED'
        [ -s "${d}/out" ] && cat -- "${d}/out" >&2
        return 1
    fi
    rc="$(read_field rc "${d}/res")"
    ops_ok="$(read_counter ops_ok "${d}/res")"
    ops_failed="$(read_counter ops_failed "${d}/res")"
    warnings="$(read_counter warnings "${d}/res")"
    findings="$(read_counter findings "${d}/res")"
    critical="$(read_counter critical "${d}/res")"
    cleaned="$(read_counter cleaned "${d}/res")"
    retries="$(read_counter retries "${d}/res")"
    smoke_ok="$(read_counter smoke_ok "${d}/res")"
    smoke_failed="$(read_counter smoke_failed "${d}/res")"
    backups="$(read_counter backups "${d}/res")"
    elapsed="$(read_counter elapsed "${d}/res")"
    status="$(read_field status "${d}/res")"
    wpver="$(read_field wp_version "${d}/res")"

    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    STATS_OPS_OK=$((STATS_OPS_OK + ops_ok))
    STATS_OPS_FAILED=$((STATS_OPS_FAILED + ops_failed))
    STATS_WARNINGS=$((STATS_WARNINGS + warnings))
    STATS_FINDINGS=$((STATS_FINDINGS + findings))
    STATS_CRITICAL=$((STATS_CRITICAL + critical))
    STATS_CLEANED=$((STATS_CLEANED + cleaned))
    STATS_RETRIES=$((STATS_RETRIES + retries))
    STATS_SMOKE_OK=$((STATS_SMOKE_OK + smoke_ok))
    STATS_SMOKE_FAILED=$((STATS_SMOKE_FAILED + smoke_failed))
    STATS_BACKUPS=$((STATS_BACKUPS + backups))
    UNIT_ELAPSED[idx]="$elapsed"
    UNIT_OPS_OK[idx]="$ops_ok"
    UNIT_OPS_FAILED[idx]="$ops_failed"
    [ -n "$wpver" ] && UNIT_WP_VERSION["${UNIT_PATH[idx]}"]="$wpver"

    # Console first, then the log: the operator watching the terminal and the
    # operator reading the file tomorrow must see the same story in the same order.
    [ -s "${d}/out" ] && cat -- "${d}/out" >&2
    if [ -s "${d}/log" ] && [ -n "$LOG_FILE" ]; then
        cat -- "${d}/log" >>"$LOG_FILE" 2>/dev/null
        rotate_log "$LOG_FILE"
    fi
    # Machine-readable payload, in site order rather than completion order.
    [ -s "${d}/data" ] && cat -- "${d}/data"
    # Report rows go to the parent's buffer so the table can be aligned at the end.
    if [ "$MODE" = 'report' ] && [ "$OUTPUT_FORMAT" = 'table' ] && [ -s "${d}/rows" ]; then
        cat -- "${d}/rows" >>"$REPORT_TABLE_FILE" 2>/dev/null
    fi

    if [ "${rc:-1}" = '0' ]; then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        [ -n "$status" ] || status='OK'
        UNIT_STATUS["${UNIT_LABEL[idx]}"]="$status"
        return 0
    fi
    STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
    [ -n "$status" ] || status='FAILED'
    UNIT_STATUS["${UNIT_LABEL[idx]}"]="$status"
    return 1
}

run_sequential() {
    local i rc=0 first=1
    for ((i = 0; i < UNIT_COUNT; i++)); do
        if budget_exceeded; then
            STOPPED_EARLY='true'
            STOP_REASON="--max-duration ${MAX_DURATION}s used up after ${i} of ${UNIT_COUNT} unit(s)"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            rc=1
            break
        fi
        if ((first == 0)) && ((STAGGER > 0)); then
            log_debug "staggering ${STAGGER}s before the next site"
            sleep "$STAGGER"
        fi
        first=0
        process_unit "$i"
        local urc=$?
        UNIT_OPS_OK[i]="$((UNIT_OPS_OK[i] + 0))"
        if ((urc != 0)); then
            rc=1
            if [ "$FAIL_FAST" = 'true' ]; then
                STOPPED_EARLY='true'
                STOP_REASON="--fail-fast after ${UNIT_LABEL[i]}"
                log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i - 1)) unit(s) were not processed"
                break
            fi
        fi
    done
    return "$rc"
}

run_batched() {
    local i=0 j=0 rc=0
    local -a batch=()
    WORK_DIR="${WORK_DIR:-}"
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.workers.XXXXXX")" || {
            log_warn "cannot create a working directory for ${JOBS} parallel workers; falling back to sequential processing"
            run_sequential
            return $?
        }
        chmod 700 "$WORK_DIR" 2>/dev/null
        tmp_register "$WORK_DIR"
    fi
    log_info "processing ${UNIT_COUNT} unit(s) in batches of ${JOBS}"

    while ((i < UNIT_COUNT)); do
        if budget_exceeded; then
            STOPPED_EARLY='true'
            STOP_REASON="--max-duration ${MAX_DURATION}s used up after ${i} of ${UNIT_COUNT} unit(s)"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            rc=1
            break
        fi
        batch=()
        while ((i < UNIT_COUNT && ${#batch[@]} < JOBS)); do
            if worker_init "$i"; then
                worker_run "$i" &
                batch+=("$i")
            else
                log_error "cannot prepare a worker for ${UNIT_LABEL[i]}; running it in the parent"
                process_unit "$i" || rc=1
            fi
            i=$((i + 1))
        done
        # The barrier. `wait` without arguments also reaps anything else that may
        # have been backgrounded, which is fine: nothing else is.
        wait
        # Replay in site order, so the report reads like the site list and not
        # like a race.
        for j in ${batch[@]+"${batch[@]}"}; do
            fold_worker "$j" || rc=1
            rm -rf -- "$(worker_dir "$j")" 2>/dev/null
        done
        if [ "$FAIL_FAST" = 'true' ] && ((STATS_SITES_FAILED > 0)); then
            STOPPED_EARLY='true'
            STOP_REASON="--fail-fast after a batch failure"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            break
        fi
        if ((STAGGER > 0)) && ((i < UNIT_COUNT)); then
            log_debug "staggering ${STAGGER}s before the next batch"
            sleep "$STAGGER"
        fi
    done
    return "$rc"
}

run_fleet() {
    if ((UNIT_COUNT == 0)); then
        return 0
    fi
    if ((JOBS <= 1)) || ((UNIT_COUNT <= 1)); then
        if ((JOBS > 1)) && ((UNIT_COUNT <= 1)); then
            log_debug "one unit to process; --jobs ${JOBS} makes no difference"
        fi
        run_sequential
        return $?
    fi
    run_batched
    return $?
}

# run_check_mode : --check reads the list if it exists but never fails because
# of it, and it changes nothing.
run_check_mode() {
    local rc=0
    NO_ACTION='true'
    check_environment || rc=1
    if [ -n "$TARGET_SITE" ]; then
        local user=''
        user="$(site_user_resolve "$TARGET_SITE" 2>/dev/null)" || user=''
        printf '\n%s== requested site ==%s\n' "$C_BOLD" "$C_RESET"
        check_report "$TARGET_SITE" "$user" || rc=1
    fi
    return "$rc"
}
