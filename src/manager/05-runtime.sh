###############################################################################
# Section 10 - runtime state
###############################################################################
#
# Every mutable global the tool has, declared in one place with its initial
# value. A grep for `^STATS_` or `^WP_` therefore answers "what does this run
# remember?" without reading 4000 lines.

# --- counters ----------------------------------------------------------------
STATS_SITES_TOTAL=0
STATS_SITES_OK=0
STATS_SITES_FAILED=0
STATS_SITES_SKIPPED=0
STATS_OPS_OK=0
STATS_OPS_FAILED=0
STATS_WARNINGS=0
STATS_RETRIES=0
STATS_SMOKE_OK=0
STATS_SMOKE_FAILED=0
STATS_BACKUPS=0
STATS_FINDINGS=0            # security and integrity findings
STATS_CRITICAL=0
STATS_CLEANED=0             # objects removed by --cleanup
START_TIME=0
SUMMARY_PRINTED='false'
STOPPED_EARLY='false'
STOP_REASON=''

# --- fleet -------------------------------------------------------------------
# A work unit is one (path, user, url) triple. The fleet is a list of units, not
# a list of paths: a multisite installation expands into one unit per subsite,
# and `--url` becomes a property of the unit instead of a global that every mode
# has to remember to pass on.
UNIT_PATH=()
UNIT_USER=()
UNIT_URL=()
UNIT_LABEL=()
UNIT_COUNT=0
declare -A SITE_USER=()
declare -A UNIT_STATUS=()
declare -A UNIT_ELAPSED=()
declare -A UNIT_OPS_OK=()
declare -A UNIT_OPS_FAILED=()
declare -A UNIT_WP_VERSION=()
SITES_FILE_RESOLVED=''
SITES_FROM_STDIN='false'

# --- per-call WP-CLI results -------------------------------------------------
WP_OUTPUT=''
WP_STATUS=0
WP_SKIPPED='false'
WP_RESOLVED=''
WP_CLI_VERSION=''
WP_LATEST_VERSION=''
WP_LATEST_CHECKED='false'

# --- parallel execution ------------------------------------------------------
WORK_DIR=''
PARALLEL='false'
WORKER_DIR=''

# --- locks and temporaries ---------------------------------------------------
LOCK_FD=''
LOCK_HELD='false'
TMP_FILES=()
WARNED_NO_TIMEOUT='false'
WARNED_NO_FLOCK='false'
WARNED_NO_TAR='false'
WARNED_NO_JQ='false'

# --- per-site scratch, filled by the modes ----------------------------------
CURRENT_SITE=''
CURRENT_USER=''
CURRENT_URL=''
CURRENT_LABEL=''
CURRENT_START=0
PLUGIN_SELECTION=''
LAST_BACKUP_DB=''           # the dump taken during this run, for --restore
SITE_HOME_CACHE=''
SITE_HOME_CACHE_FOR=''

###############################################################################
# Section 11 - locking, traps, temporary files
###############################################################################
#
# A maintenance run that overlaps itself corrupts databases far more reliably
# than any plugin does. flock(2) when available, a pid file when not, and a
# clear refusal in both cases.

# lock_acquire : take the run lock, honouring LOCK_TIMEOUT and LOCK_REQUIRED.
lock_acquire() {
    local dir other waited=0 rc=0
    dir="$(path_dir "$LOCK_FILE")"
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        # /var/run is not writable in a container or for a non-root operator.
        # Falling back to a per-uid file in TMPDIR keeps the guarantee that
        # matters (this user cannot run twice) without failing the run.
        LOCK_FILE="${TMPDIR:-/tmp}/${PROG_NAME}.$(id -u).lock"
        log_debug "lock directory not writable; using ${LOCK_FILE} instead"
    fi

    if have flock; then
        # The braces matter. `exec {FD}>>file 2>/dev/null` would attach the
        # redirection to exec permanently and silence stderr for the rest of the
        # run; the group redirects only this attempt.
        if ! { exec {LOCK_FD}>>"$LOCK_FILE"; } 2>/dev/null; then
            LOCK_FD=''
            if [ "$LOCK_REQUIRED" = 'true' ]; then
                log_error "cannot open the lock file ${LOCK_FILE} and LOCK_REQUIRED is set"
                exit "$EXIT_ENV"
            fi
            log_warn "cannot open lock file ${LOCK_FILE}; concurrent runs are not prevented"
            return 0
        fi
        while :; do
            if flock -n "$LOCK_FD"; then rc=0; break; fi
            if ((LOCK_TIMEOUT > 0)) && ((waited < LOCK_TIMEOUT)); then
                sleep 1
                waited=$((waited + 1))
                ((waited % 10 == 0)) && log_info "waiting for the lock (${waited}s of ${LOCK_TIMEOUT}s)"
                continue
            fi
            rc=1
            break
        done
        if ((rc != 0)); then
            exec {LOCK_FD}>&- 2>/dev/null
            LOCK_FD=''
            other="$(head -n 1 -- "$LOCK_FILE" 2>/dev/null)"
            log_error "another ${PROG_NAME} run holds ${LOCK_FILE}${other:+ (pid ${other})}; refusing to run concurrently"
            log_error "raise LOCK_TIMEOUT to wait instead, or pass --no-lock if you are certain no other run is active"
            exit "$EXIT_ENV"
        fi
    else
        if [ "$WARNED_NO_FLOCK" = 'false' ]; then
            log_warn 'flock(1) not found; using a pid file, which does not protect against a crash mid-run'
            WARNED_NO_FLOCK='true'
        fi
        if [ -s "$LOCK_FILE" ]; then
            other="$(head -n 1 -- "$LOCK_FILE" 2>/dev/null)"
            if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
                if [ "$LOCK_REQUIRED" = 'true' ] || ((LOCK_TIMEOUT == 0)); then
                    log_error "another ${PROG_NAME} run holds ${LOCK_FILE} (pid ${other}); refusing to run concurrently"
                    exit "$EXIT_ENV"
                fi
                while ((waited < LOCK_TIMEOUT)); do
                    kill -0 "$other" 2>/dev/null || break
                    sleep 1
                    waited=$((waited + 1))
                done
                if kill -0 "$other" 2>/dev/null; then
                    log_error "pid ${other} still holds ${LOCK_FILE} after ${waited}s"
                    exit "$EXIT_ENV"
                fi
            else
                [ -n "$other" ] && [ "$other" != "$$" ] &&
                    log_warn "removing a stale lock left by pid ${other}"
            fi
        fi
    fi

    : >"$LOCK_FILE" 2>/dev/null
    printf '%s\n' "$$" >"$LOCK_FILE" 2>/dev/null
    LOCK_HELD='true'
    log_debug "lock acquired: ${LOCK_FILE} (waited ${waited}s)"
    return 0
}

# shellcheck disable=SC2329,SC2317  # invoked from tmp_cleanup only
lock_release() {
    if [ -n "$LOCK_FD" ]; then
        exec {LOCK_FD}>&- 2>/dev/null
        LOCK_FD=''
    fi
    if [ "$LOCK_HELD" = 'true' ]; then
        # Only remove the pid file when it is still ours: a lock that timed out
        # may already belong to the next run, and deleting it would let a third
        # run in.
        local holder
        holder="$(head -n 1 -- "$LOCK_FILE" 2>/dev/null)"
        if [ -z "$holder" ] || [ "$holder" = "$$" ]; then
            rm -f -- "$LOCK_FILE" 2>/dev/null
        fi
        LOCK_HELD='false'
    fi
    return 0
}

tmp_register() { TMP_FILES+=("$1"); }

# shellcheck disable=SC2329,SC2317  # invoked from the EXIT trap only
tmp_cleanup() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
        [ -e "$f" ] && rm -rf -- "$f" 2>/dev/null
    done
    TMP_FILES=()
    lock_release
    return 0
}

# budget_exceeded -> 0 when the whole-run budget is used up.
# A cron window is a real constraint: a run that is still going when the next
# one starts either overlaps (the lock refuses it) or gets killed by the
# scheduler (no summary, no state file, no notification). Stopping between sites
# keeps the report honest about what did and did not run.
budget_exceeded() {
    ((MAX_DURATION > 0)) || return 1
    local elapsed
    now_epoch >/dev/null
    elapsed=$((EPOCH_NOW - START_TIME))
    ((elapsed >= MAX_DURATION))
}

budget_remaining() {
    ((MAX_DURATION > 0)) || { printf '0'; return 0; }
    now_epoch >/dev/null
    local left=$((MAX_DURATION - (EPOCH_NOW - START_TIME)))
    ((left < 0)) && left=0
    printf '%s' "$left"
}

# shellcheck disable=SC2329,SC2317  # registered as the EXIT trap
on_exit() {
    local rc=$?
    tmp_cleanup
    # The summary is printed even on interrupt: a half-finished fleet run has to
    # tell the operator how far it got, and the state file and the notification
    # have to reflect the partial truth rather than nothing.
    if [ "$SUMMARY_PRINTED" = 'false' ] && [ "$START_TIME" -gt 0 ] &&
       [ "$NO_ACTION" != 'true' ] && [ "$LIST_MODES" != 'true' ]; then
        printf '\n' >&2
        log_warn "interrupted or aborted (exit ${rc}); the partial summary follows"
        print_summary "$rc"
        emit_state_and_metrics "$rc"
        notify_run "$rc"
    fi
    # Re-assert the original status: an `exit` inside a trap replaces the status
    # the script was already carrying, which once turned a usage error (2) into
    # an environment error (3) on its way out.
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 131' HUP
