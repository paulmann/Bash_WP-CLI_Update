# _audit_each < NUL list : run the audit over the discovered set.
_audit_each() {
    local site
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        audit_site "$site"
    done
    return 0
}

main() {
    parse_args "$@"
    validate_args
    color_init
    [ "$VERBOSE" = 'true' ] && QUIET='false'
    START_TIME="$(date +%s)"

    if [ "$STATUS_ONLY" = 'true' ]; then
        status_report "$OUTPUT_FILE"
        exit "$EXIT_OK"
    fi
    if [ -n "$VERIFY_LIST" ]; then
        # Verification is a different question from discovery: it audits a list
        # that already exists, so it needs no roots, no scanning and no output
        # file, and it must not overwrite anything.
        verify_list "$VERIFY_LIST"
        exit $?
    fi

    resolve_excludes
    resolve_roots || exit "$EXIT_ERROR"

    log_info "${PROG_NAME} ${SCRIPT_VERSION}: ${#SEARCH_ROOTS[@]} root(s), depth ${MIN_DEPTH}..${MAX_DEPTH}, format ${OUTPUT_FORMAT}"
    log_debug "excluded names: ${EXCLUDE_NAMES[*]:-<none>}"
    log_debug "excluded paths: ${EXCLUDE_PATHS[*]:-<none>}"

    collect_results

    if [ "$SKIP_EXISTING" = 'true' ] && [ "$OUTPUT_FILE" != '-' ]; then
        local filtered
        make_tmp filtered; filtered="$TMP_LAST"
        filter_existing "$OUTPUT_FILE" <"$SORTED_FILE" >"$filtered"
        SORTED_FILE="$filtered"
        FOUND_COUNT="$(tr -cd '\0' <"$SORTED_FILE" | wc -c)"
        FOUND_COUNT="${FOUND_COUNT//[^0-9]/}"
        FOUND_COUNT="${FOUND_COUNT:-0}"
    fi

    if ((FOUND_COUNT == 0)); then
        log_warn "no WordPress installation found under: ${SEARCH_ROOTS[*]}"
        report_skipped
        # Still write an empty list: a stale list from a previous run is far more
        # dangerous than an empty one, because the manager would happily work on
        # sites that are no longer there.
        if [ "$OUTPUT_FILE" != '-' ]; then
            write_output <"$SORTED_FILE" || exit "$EXIT_ERROR"
            log_info "empty site list written: ${OUTPUT_FILE}"
        fi
        if [ "$FAIL_EMPTY" = 'true' ]; then
            exit "$EXIT_ERROR"
        fi
        exit "$EXIT_NOT_FOUND"
    fi

    if ! write_output <"$SORTED_FILE"; then
        exit "$EXIT_ERROR"
    fi
    if [ -n "$MANIFEST_FILE" ]; then
        write_manifest <"$SORTED_FILE" || exit "$EXIT_ERROR"
    fi
    if [ "$AUDIT" = 'true' ]; then
        log_info "auditing ${FOUND_COUNT} installation(s)"
        _audit_each <"$SORTED_FILE"
        if ((AUDIT_FINDINGS > 0)); then
            log_warn "the audit reported ${AUDIT_FINDINGS} finding(s); re-run with --audit to see them again"
        else
            log_ok 'the audit found nothing to report'
        fi
    fi

    log_ok "found ${FOUND_COUNT} installation(s)"
    report_skipped
    if [ "$OUTPUT_FILE" = '-' ]; then
        log_info 'result written to stdout'
    else
        log_info "site list written: ${OUTPUT_FILE}"
        print_table <"$SORTED_FILE"
    fi
    log_info "finished in $(( $(date +%s) - START_TIME ))s"
    exit "$EXIT_OK"
}


main "$@"
