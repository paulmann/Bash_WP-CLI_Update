###############################################################################
# Section 32 - fleet report streams
###############################################################################
#
# One object per unit plus a final summary object, as JSON Lines rather than a
# JSON array. A fleet run is a stream: with an array the operator gets nothing
# until the last site finishes, and a run that is killed produces invalid JSON.
# With Lines, `... --json | while read -r o; do ...` sees every site as it lands,
# and a killed run still leaves a parseable prefix.

# emit_unit_json INDEX STATUS
emit_unit_json() { # INDEX STATUS
    local i="$1" status="$2" sink
    sink="$(data_sink)"
    printf '{"type":"site","path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s}\n' \
        "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
        "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
        "$(json_quote "$status")" \
        "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" | sink_append "$sink"
    return 0
}

# run_document EXIT_CODE : the full machine-readable record of this run.
# Printed once, used by --json (as the summary line), by the state file and by
# the webhook payload, so that all three consumers see exactly the same document.
run_document() { # EXIT_CODE
    local rc="${1:-0}" i elapsed=0
    now_epoch >/dev/null
    elapsed=$((EPOCH_NOW - START_TIME))
    printf '{"type":"summary","tool":%s,"version":"%s","build":%s,"host":%s,"mode":%s,"exit":%s,' \
        "$(json_quote "$PROG_NAME")" "$SCRIPT_VERSION" "$(json_quote "$BUILD_ID")" \
        "$(json_quote "$(uname -n 2>/dev/null)")" "$(json_quote "$MODE")" "$rc"
    printf '"started_at":%s,"finished_at":%s,"duration_seconds":%s,"dry_run":%s,"jobs":%s,' \
        "$START_TIME" "$EPOCH_NOW" "$elapsed" "$DRY_RUN" "$JOBS"
    printf '"backup":%s,"sites_total":%s,"sites_ok":%s,"sites_failed":%s,"sites_skipped":%s,' \
        "$(json_quote "$BACKUP")" "$STATS_SITES_TOTAL" "$STATS_SITES_OK" \
        "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED"
    printf '"ops_ok":%s,"ops_failed":%s,"warnings":%s,"retries":%s,"backups":%s,' \
        "$STATS_OPS_OK" "$STATS_OPS_FAILED" "$STATS_WARNINGS" "$STATS_RETRIES" "$STATS_BACKUPS"
    printf '"smoke_ok":%s,"smoke_failed":%s,"findings":%s,"critical":%s,"cleaned":%s,' \
        "$STATS_SMOKE_OK" "$STATS_SMOKE_FAILED" "$STATS_FINDINGS" "$STATS_CRITICAL" "$STATS_CLEANED"
    printf '"stopped_early":%s,"stop_reason":%s,"wpcli_version":%s,"results":[' \
        "$([ "$STOPPED_EARLY" = 'true' ] && printf 'true' || printf 'false')" \
        "$(json_quote "$STOP_REASON")" "$(json_quote "$WP_CLI_VERSION")"
    local first=1
    for ((i = 0; i < UNIT_COUNT; i++)); do
        ((first)) || printf ','
        first=0
        printf '{"path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s,"wp_version":%s}' \
            "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
            "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
            "$(json_quote "${UNIT_STATUS[${UNIT_LABEL[i]}]-UNKNOWN}")" \
            "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" \
            "$(json_quote "${UNIT_WP_VERSION[${UNIT_PATH[i]}]-}")"
    done
    printf ']}\n'
    return 0
}

emit_summary_json() { # EXIT_CODE
    run_document "$1" | sink_append "$(data_sink)"
    return 0
}

###############################################################################
# Section 33 - state file and Prometheus metrics
###############################################################################
#
# Both are written atomically, after the summary and even after an interrupt, so
# a monitoring system never reads a half-written document and never misses the
# run that crashed. Both are optional: a host with no monitoring should not have
# to disable anything to use this tool.

write_state_file() { # EXIT_CODE
    [ -n "$STATE_FILE" ] || return 0
    if ! ensure_parent_dir "$STATE_FILE"; then
        log_warn "cannot create the directory for the state file ${STATE_FILE}"
        return 0
    fi
    if ! run_document "$1" | atomic_write "$STATE_FILE"; then
        log_warn "cannot write the state file ${STATE_FILE}"
        return 0
    fi
    log_debug "state written to ${STATE_FILE}"
    return 0
}

# write_metrics_file EXIT_CODE
#
# Prometheus textfile-collector format. Gauges only, one label set per unit, and
# a `wpu_up` series so that "the exporter stopped" is distinguishable from
# "everything is fine". A label value carries the site path, which is why the
# path is escaped for Prometheus rather than for JSON: the two languages differ
# in exactly the characters that appear in real paths.
prom_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

write_metrics_file() { # EXIT_CODE
    local rc="${1:-0}" i status elapsed
    [ -n "$METRICS_FILE" ] || return 0
    if ! ensure_parent_dir "$METRICS_FILE"; then
        log_warn "cannot create the directory for the metrics file ${METRICS_FILE}"
        return 0
    fi
    {
        printf '# HELP wpu_up The last maintenance run completed and wrote these metrics.\n'
        printf '# TYPE wpu_up gauge\n'
        printf 'wpu_up 1\n'
        printf '# HELP wpu_info Build and mode of the last run.\n'
        printf '# TYPE wpu_info gauge\n'
        printf 'wpu_info{version="%s",build="%s",mode="%s",host="%s"} 1\n' \
            "$(prom_escape "$SCRIPT_VERSION")" "$(prom_escape "$BUILD_ID")" \
            "$(prom_escape "$MODE")" "$(prom_escape "$(uname -n 2>/dev/null)")"
        printf '# HELP wpu_exit_code Exit code of the last run.\n'
        printf '# TYPE wpu_exit_code gauge\n'
        printf 'wpu_exit_code %s\n' "$rc"
        printf '# HELP wpu_run_timestamp_seconds Unix time of the last run.\n'
        printf '# TYPE wpu_run_timestamp_seconds gauge\n'
        now_epoch >/dev/null
        printf 'wpu_run_timestamp_seconds %s\n' "$EPOCH_NOW"
        printf '# HELP wpu_duration_seconds Wall-clock duration of the last run.\n'
        printf '# TYPE wpu_duration_seconds gauge\n'
        printf 'wpu_duration_seconds %s\n' "$((EPOCH_NOW - START_TIME))"
        printf '# HELP wpu_sites_total Work units processed in the last run.\n'
        printf '# TYPE wpu_sites_total gauge\n'
        printf 'wpu_sites_total %s\n' "$STATS_SITES_TOTAL"
        printf '# HELP wpu_sites_ok Work units that finished without error.\n'
        printf '# TYPE wpu_sites_ok gauge\n'
        printf 'wpu_sites_ok %s\n' "$STATS_SITES_OK"
        printf '# HELP wpu_sites_failed Work units with at least one failed operation.\n'
        printf '# TYPE wpu_sites_failed gauge\n'
        printf 'wpu_sites_failed %s\n' "$STATS_SITES_FAILED"
        printf '# HELP wpu_sites_skipped Entries skipped before processing.\n'
        printf '# TYPE wpu_sites_skipped gauge\n'
        printf 'wpu_sites_skipped %s\n' "$STATS_SITES_SKIPPED"
        printf '# HELP wpu_ops_ok WP-CLI operations that succeeded.\n'
        printf '# TYPE wpu_ops_ok gauge\n'
        printf 'wpu_ops_ok %s\n' "$STATS_OPS_OK"
        printf '# HELP wpu_ops_failed WP-CLI operations that failed.\n'
        printf '# TYPE wpu_ops_failed gauge\n'
        printf 'wpu_ops_failed %s\n' "$STATS_OPS_FAILED"
        printf '# HELP wpu_warnings Warnings logged during the last run.\n'
        printf '# TYPE wpu_warnings gauge\n'
        printf 'wpu_warnings %s\n' "$STATS_WARNINGS"
        printf '# HELP wpu_findings Audit findings from --security and --verify.\n'
        printf '# TYPE wpu_findings gauge\n'
        printf 'wpu_findings %s\n' "$STATS_FINDINGS"
        printf '# HELP wpu_findings_critical Critical audit findings.\n'
        printf '# TYPE wpu_findings_critical gauge\n'
        printf 'wpu_findings_critical %s\n' "$STATS_CRITICAL"
        printf '# HELP wpu_backups Archives written during the last run.\n'
        printf '# TYPE wpu_backups gauge\n'
        printf 'wpu_backups %s\n' "$STATS_BACKUPS"
        printf '# HELP wpu_smoke_failed Post-update smoke tests that failed.\n'
        printf '# TYPE wpu_smoke_failed gauge\n'
        printf 'wpu_smoke_failed %s\n' "$STATS_SMOKE_FAILED"
        printf '# HELP wpu_stopped_early The run stopped before the end of the site list.\n'
        printf '# TYPE wpu_stopped_early gauge\n'
        printf 'wpu_stopped_early %s\n' "$([ "$STOPPED_EARLY" = 'true' ] && printf 1 || printf 0)"
        printf '# HELP wpu_unit_status Per-unit outcome: 1 ok, 0 failed, -1 skipped.\n'
        printf '# TYPE wpu_unit_status gauge\n'
        for ((i = 0; i < UNIT_COUNT; i++)); do
            status="${UNIT_STATUS[${UNIT_LABEL[i]}]-UNKNOWN}"
            case "$status" in
                OK) status=1 ;;
                SKIPPED) status=-1 ;;
                *) status=0 ;;
            esac
            printf 'wpu_unit_status{path="%s",label="%s",owner="%s",url="%s"} %s\n' \
                "$(prom_escape "${UNIT_PATH[i]}")" "$(prom_escape "${UNIT_LABEL[i]}")" \
                "$(prom_escape "${UNIT_USER[i]}")" "$(prom_escape "${UNIT_URL[i]}")" "$status"
        done
        printf '# HELP wpu_unit_elapsed_seconds Per-unit wall-clock duration.\n'
        printf '# TYPE wpu_unit_elapsed_seconds gauge\n'
        for ((i = 0; i < UNIT_COUNT; i++)); do
            printf 'wpu_unit_elapsed_seconds{path="%s",label="%s"} %s\n' \
                "$(prom_escape "${UNIT_PATH[i]}")" "$(prom_escape "${UNIT_LABEL[i]}")" \
                "${UNIT_ELAPSED[i]-0}"
        done
    } | atomic_write "$METRICS_FILE" || {
        log_warn "cannot write the metrics file ${METRICS_FILE}"
        return 0
    }
    log_debug "metrics written to ${METRICS_FILE}"
    return 0
}

emit_state_and_metrics() { # EXIT_CODE
    write_state_file "$1"
    write_metrics_file "$1"
    return 0
}

###############################################################################
# Section 34 - notifications
###############################################################################
#
# A maintenance run that finishes at 03:12 and tells nobody is a run whose
# failure is discovered by a customer. Two channels are supported and both are
# deliberately dumb:
#
#   webhook  a JSON POST. Slack, Discord, Telegram, Mattermost, an n8n hook and
#            a hundred internal gateways all accept one; the payload shape is
#            configurable because their field names differ and nothing else does.
#   command  an executable, invoked with the summary in argv and in the
#            environment. It is never passed through a shell, so a config file
#            cannot turn a notification into arbitrary code -- it can name an
#            executable, which is a strictly smaller grant than a shell would be.
#
# A notification failure is a warning, never a run failure: the maintenance work
# happened, and paging somebody because the pager is down hides that fact.

# notify_summary_text -> one short human-readable line for a chat channel
notify_summary_text() { # EXIT_CODE
    local rc="${1:-0}" dry=
    now_epoch >/dev/null
    duration_human "$((EPOCH_NOW - START_TIME))" >/dev/null
    [ "$DRY_RUN" = 'true' ] && dry=' [dry-run]'
    printf '%s %s %s on %s: %s site(s), %s ok, %s failed, %s skipped, %s operation(s) failed, %s warning(s), %s%s' \
        "$PROG_NAME" "$SCRIPT_VERSION" "$MODE" "$(uname -n 2>/dev/null || printf '?')" \
        "$STATS_SITES_TOTAL" "$STATS_SITES_OK" "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED" \
        "$STATS_OPS_FAILED" "$STATS_WARNINGS" "$DURATION_HUMAN" "$dry"
    return 0
}

notify_webhook() { # EXIT_CODE
    local rc="${1:-0}" text body=''
    [ -n "$NOTIFY_WEBHOOK_URL" ] || return 0
    if ! http_client_resolve >/dev/null 2>&1; then
        log_warn 'a webhook is configured but no HTTP client is installed; the notification was not sent'
        return 0
    fi
    text="$(notify_summary_text "$rc")"
    case "$NOTIFY_WEBHOOK_FORMAT" in
        slack) body="$(printf '{"text":%s}' "$(json_quote "$text")")" ;;
        discord) body="$(printf '{"content":%s}' "$(json_quote "$text")")" ;;
        telegram) body="$(printf '{"text":%s,"disable_web_page_preview":true}' "$(json_quote "$text")")" ;;
        generic | *) body="$(run_document "$rc")" ;;
    esac
    if http_post_json "$NOTIFY_WEBHOOK_URL" "$body" 20; then
        log_ok "notification posted to the ${NOTIFY_WEBHOOK_FORMAT} webhook"
    else
        log_warn "the webhook at ${NOTIFY_WEBHOOK_URL} did not accept the notification"
    fi
    return 0
}

notify_command() { # EXIT_CODE
    local rc="${1:-0}" summary=
    [ -n "$NOTIFY_COMMAND" ] || return 0
    now_epoch >/dev/null
    summary="$(notify_summary_text "$rc")"
    if [ ! -x "$NOTIFY_COMMAND" ]; then
        log_warn "NOTIFY_COMMAND is not an executable file: ${NOTIFY_COMMAND}"
        return 0
    fi
    local out='' nrc=0
    # The summary travels in both argv and the environment: argv is convenient
    # for a one-liner script, the environment is convenient for anything that
    # wants to branch on a number. Neither goes through a shell.
    out="$(
        WPU_EXIT="$rc" \
        WPU_MODE="$MODE" \
        WPU_VERSION="$SCRIPT_VERSION" \
        WPU_HOST="$(uname -n 2>/dev/null)" \
        WPU_SITES_TOTAL="$STATS_SITES_TOTAL" \
        WPU_SITES_OK="$STATS_SITES_OK" \
        WPU_SITES_FAILED="$STATS_SITES_FAILED" \
        WPU_SITES_SKIPPED="$STATS_SITES_SKIPPED" \
        WPU_OPS_OK="$STATS_OPS_OK" \
        WPU_OPS_FAILED="$STATS_OPS_FAILED" \
        WPU_WARNINGS="$STATS_WARNINGS" \
        WPU_FINDINGS="$STATS_FINDINGS" \
        WPU_CRITICAL="$STATS_CRITICAL" \
        WPU_DURATION="$((EPOCH_NOW - START_TIME))" \
        WPU_DRY_RUN="$DRY_RUN" \
        WPU_STATE_FILE="$STATE_FILE" \
        WPU_LOG_FILE="$LOG_FILE" \
        WPU_ERROR_LOG_FILE="$ERROR_LOG_FILE" \
        WPU_SUMMARY="$summary" \
            "$NOTIFY_COMMAND" \
            --exit "$rc" --mode "$MODE" \
            --sites "$STATS_SITES_TOTAL" --ok "$STATS_SITES_OK" \
            --failed "$STATS_SITES_FAILED" --skipped "$STATS_SITES_SKIPPED" \
            --warnings "$STATS_WARNINGS" --duration "$((EPOCH_NOW - START_TIME))" \
            --state-file "$STATE_FILE" --log-file "$LOG_FILE" 2>&1 </dev/null
    )" || nrc=$?
    if ((nrc != 0)); then
        log_warn "the notification command exited ${nrc}: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
    else
        log_debug "notification command ran: ${NOTIFY_COMMAND}"
    fi
    return 0
}

notify_run() { # EXIT_CODE
    local rc="${1:-0}"
    case "$NOTIFY_ON" in
        always) : ;;
        failure) ((rc == 0)) && return 0 ;;
        never | *) return 0 ;;
    esac
    if [ "$DRY_RUN" = 'true' ]; then
        log_debug 'a dry run does not notify'
        return 0
    fi
    notify_webhook "$rc"
    notify_command "$rc"
    return 0
}

###############################################################################
# Section 35 - summary and exit code
###############################################################################

# print_summary EXIT_CODE
print_summary() { # EXIT_CODE
    local rc="${1:-0}" elapsed=0 line
    now_epoch >/dev/null
    elapsed=$((EPOCH_NOW - START_TIME))
    SUMMARY_PRINTED='true'
    line="$(printf '%*s' 70 '')"
    {
        printf -- '----------------------------------------------------------------------\n'
        printf '%s summary\n' "$PROG_NAME"
        printf -- '----------------------------------------------------------------------\n'
        printf '  %-22s %s\n' 'mode:' "$MODE"
        printf '  %-22s %s\n' 'sites processed:' "$STATS_SITES_TOTAL"
        printf '  %-22s %s\n' 'sites ok:' "$STATS_SITES_OK"
        printf '  %-22s %s\n' 'sites failed:' "$STATS_SITES_FAILED"
        printf '  %-22s %s\n' 'sites skipped:' "$STATS_SITES_SKIPPED"
        printf '  %-22s %s\n' 'operations ok:' "$STATS_OPS_OK"
        printf '  %-22s %s\n' 'operations failed:' "$STATS_OPS_FAILED"
        printf '  %-22s %s\n' 'warnings:' "$STATS_WARNINGS"
        if ((STATS_RETRIES > 0)); then
            printf '  %-22s %s\n' 'retries:' "$STATS_RETRIES"
        fi
        if ((STATS_BACKUPS > 0)); then
            printf '  %-22s %s\n' 'backups written:' "$STATS_BACKUPS"
        fi
        if ((STATS_SMOKE_OK + STATS_SMOKE_FAILED > 0)); then
            printf '  %-22s %s ok, %s failed\n' 'smoke tests:' "$STATS_SMOKE_OK" "$STATS_SMOKE_FAILED"
        fi
        if ((STATS_FINDINGS > 0)); then
            printf '  %-22s %s (%s critical)\n' 'audit findings:' "$STATS_FINDINGS" "$STATS_CRITICAL"
        fi
        if ((STATS_CLEANED > 0)); then
            printf '  %-22s %s\n' 'objects removed:' "$STATS_CLEANED"
        fi
        if [ "$STOPPED_EARLY" = 'true' ]; then
            printf '  %-22s %s%s%s (%s)\n' 'stopped early:' "$C_YELLOW" 'yes' "$C_RESET" "$STOP_REASON"
        fi
        if ((JOBS > 1)); then
            printf '  %-22s %s\n' 'parallelism:' "${JOBS} units per batch"
        fi
        if [ "$BACKUP" != 'off' ]; then
            printf '  %-22s %s\n' 'backup:' "${BACKUP} -> $(backup_dir_of) (keep ${KEEP_BACKUPS})"
        fi
        printf '  %-22s %s (%ss)\n' 'duration:' "$(duration_human "$elapsed")" "$elapsed"
        [ -n "$LOG_FILE" ] && printf '  %-22s %s\n' 'log:' "$LOG_FILE"
        [ -n "$ERROR_LOG_FILE" ] && printf '  %-22s %s\n' 'error log:' "$ERROR_LOG_FILE"
        [ -n "$STATE_FILE" ] && printf '  %-22s %s\n' 'state file:' "$STATE_FILE"
        [ -n "$METRICS_FILE" ] && printf '  %-22s %s\n' 'metrics file:' "$METRICS_FILE"
        printf -- '----------------------------------------------------------------------\n'
        if ((rc == 0)); then
            printf '%s%s run finished without errors%s\n' "$C_GREEN" "$CHECK_OK" "$C_RESET"
        else
            printf '%s%s run finished with errors (exit %s)%s\n' "$C_RED" "$CHECK_NO" "$rc" "$C_RESET"
        fi
    } >&2

    if [ "$JSON_LINES" = 'true' ]; then
        emit_summary_json "$rc"
    fi
    return 0
}

# final_exit_code -> 0 or 1, before the special codes are applied.
#
# --strict turns "it ran, but something smelled" into a non-zero exit, which is
# what a pipeline needs: a warning about a stale lock or a skipped site is
# invisible to cron otherwise. It is checked before the --fail-on policy, because
# `--fail-on never --strict` has to mean "ignore site failures, but not
# warnings", not "ignore everything".
final_exit_code() {
    if [ "$STRICT" = 'true' ] && ((STATS_WARNINGS > 0)); then
        log_warn "--strict: ${STATS_WARNINGS} warning(s) make this run a failure"
        return 1
    fi
    if [ "$STRICT" = 'true' ] && ((STATS_CRITICAL > 0)); then
        log_warn "--strict: ${STATS_CRITICAL} critical finding(s) make this run a failure"
        return 1
    fi
    case "$FAIL_ON" in
        never) return 0 ;;
        all)
            ((STATS_SITES_TOTAL > 0)) || return 0
            ((STATS_SITES_FAILED >= STATS_SITES_TOTAL)) && return 1
            return 0
            ;;
        any | *)
            ((STATS_SITES_FAILED > 0)) && return 1
            return 0
            ;;
    esac
}

# finish_run EXIT_HINT : the single exit path of a fleet run.
#
# Every terminal branch of main() used to repeat "compute the code, print the
# summary, write the state, notify, exit" in a slightly different order, and the
# differences were bugs: an interrupted run printed a summary but wrote no state
# file, so the dashboard showed the previous night's numbers. One function, one
# order, no drift.
finish_run() { # EXIT_HINT
    local hint="${1:-0}" code=0
    final_exit_code || code="$EXIT_ERROR"
    if [ "$STOPPED_EARLY" = 'true' ] && ((code == 0)); then
        code="$EXIT_STOPPED"
    fi
    if ((hint != 0)) && ((code == 0)); then
        code="$hint"
    fi
    print_summary "$code"
    emit_state_and_metrics "$code"
    notify_run "$code"
    log_info "finished with exit ${code}"
    SUMMARY_PRINTED='true'
    exit "$code"
}
