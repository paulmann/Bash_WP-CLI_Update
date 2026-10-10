###############################################################################
# Section 18 - WP-CLI invocation
###############################################################################
#
# One function executes WP-CLI: wp_exec. Everything else in the tool is a caller
# of it. That is deliberate. Every guarantee this project makes -- no shell
# strings, secrets out of argv, per-command timeouts, a user switch, a stable
# environment, redacted logs -- is enforced in one place, so it cannot be
# forgotten by the next mode somebody adds.

# WP_CAPTURE selects what wp_exec puts into WP_OUTPUT:
#   merged  stdout and stderr interleaved, in the order they happened. Right for
#           anything a human reads: WP-CLI writes progress to stderr and data to
#           stdout, and separating them reorders the story.
#   stdout  stdout only, stderr captured separately for the log. Right for every
#           machine-readable fetch, because one deprecation notice from one
#           plugin on stderr is otherwise glued to the front of a JSON document
#           and the whole parse fails.
WP_CAPTURE='merged'
WP_STDERR=''
WP_ERR_FILE=''

# wp_err_file -> a scratch path for the stderr capture, private to this process.
# A worker resets WP_ERR_FILE on entry, so parallel sites never share one file.
wp_err_file() {
    if [ -n "$WP_ERR_FILE" ]; then
        printf '%s' "$WP_ERR_FILE"
        return 0
    fi
    if [ -n "${WORKER_DIR:-}" ]; then
        WP_ERR_FILE="${WORKER_DIR}/err"
    else
        WP_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.stderr.XXXXXX" 2>/dev/null)" || {
            WP_ERR_FILE=''
            return 1
        }
        tmp_register "$WP_ERR_FILE"
    fi
    : >"$WP_ERR_FILE" 2>/dev/null
    printf '%s' "$WP_ERR_FILE"
}

# `--skip-plugins` belongs on operations that *change* plugins or themes. On a
# listing it hides exactly the plugins the operator asked to see, so it is added
# there only when SKIP_PLUGINS_FOR_LISTING says so. Passing it to `db optimize`
# or `cron event run` is noise at best and an error on old WP-CLI at worst.
skip_plugins_applies_to() { # SUBCOMMAND [SECOND]
    case "${1:-}" in
        plugin | theme)
            case "${2:-}" in
                list | status | get | search | is-installed | verify-checksums)
                    [ "$SKIP_PLUGINS_FOR_LISTING" = 'true' ] && return 0
                    return 1
                    ;;
            esac
            return 0
            ;;
        language)
            case "${2:-}" in
                plugin | theme) return 0 ;;
            esac
            return 1
            ;;
        brainstormforce) return 0 ;;
        *) return 1 ;;
    esac
}

# timeout_argv -> zero or more argv elements for the GNU timeout prefix.
#
# The prefix is emitted *inside* the command that run_as_user executes, so it
# runs as the site user and supervises the wp process group directly. Wrapping
# run_as_user in another shell instead would have meant quoting a command line
# twice, which is exactly the bug class this project keeps hitting.
TIMEOUT_SUPPORTED=''
timeout_argv() {
    ((TIMEOUT > 0)) || return 0
    if ! have timeout; then
        return 1        # the caller decides what to do without it
    fi
    if [ -z "$TIMEOUT_SUPPORTED" ]; then
        # -k is a GNU extension; probe it once instead of assuming it, because
        # BusyBox and the *BSD timeout both exist in the wild.
        if ((KILL_AFTER > 0)) && timeout -k 1 -s TERM 1 true >/dev/null 2>&1; then
            TIMEOUT_SUPPORTED='kill-after'
        else
            TIMEOUT_SUPPORTED='plain'
        fi
    fi
    printf '%s\n' timeout "--signal=$TIMEOUT_SIGNAL"
    if [ "$TIMEOUT_SUPPORTED" = 'kill-after' ] && ((KILL_AFTER > 0)); then
        printf '%s\n' -k "$KILL_AFTER"
    fi
    printf '%s\n' "$TIMEOUT"
    return 0
}

WARNED_PORTABLE_TIMEOUT='false'

# perl_supervisor ARGV... -> run ARGV under a portable timeout.
#
# `timeout -k` is GNU-only and `timeout` itself is missing on a surprising number
# of minimal images. Without any bound, one hung `wp` -- a database lock, an NFS
# stall, a plugin waiting on a dead API -- holds the whole fleet run until
# somebody notices. The supervisor below is the fallback: TERM to the process
# *group* after TIMEOUT seconds, KILL after KILL_AFTER more.
#
# Every value the supervisor needs travels in argv. An earlier revision put the
# limit in an environment variable, and because the assignment was a temporary on
# the command it never reached perl, so `alarm undef` turned the whole thing into
# a no-op that looked like it worked.
perl_supervisor() { # LIMIT SIGNAL GRACE PROGRAM [ARGS...]
    local limit="$1" sig="$2" grace="$3"
    shift 3
    "$PERL_BIN" -e '
        my ($limit, $sig, $grace, @cmd) = @ARGV;
        my $pid = fork();
        die "fork failed\n" unless defined $pid;
        if ($pid == 0) {
            # Own process group, so killing the group reaches grandchildren too.
            # Without this a wp wrapper that leaves a child behind keeps the
            # command-substitution pipe open and the caller blocks until that
            # orphan finishes -- the timeout would look useless.
            setpgrp(0, 0);
            exec { $cmd[0] } @cmd;
            exit 127;
        }
        my $state = 0;
        $SIG{ALRM} = sub {
            if ($state == 0) {
                $state = 1;
                kill "-$sig", $pid; kill $sig, $pid;
                alarm $grace;
            } else {
                # SIGKILL cannot be trapped or deferred, and the child is reaped
                # below before exiting: a live orphan would keep the pipe open.
                kill "-KILL", $pid; kill "KILL", $pid;
                $state = 2;
            }
        };
        alarm $limit;
        # waitpid returns -1/EINTR when the alarm interrupts it. Reading that as
        # "the child exited" made the supervisor leave before the escalation
        # alarm could fire, and a hung command survived its own kill. Loop until
        # a real child status arrives.
        my $st = 0;
        while (1) {
            my $got = waitpid($pid, 0);
            if ($got == $pid) { $st = $? >> 8; last; }
            if ($got == -1) {
                next if $! == 4;      # EINTR: the alarm interrupted the wait
                last if $! == 10;     # ECHILD: already reaped
                last;                 # anything else: do not spin forever
            }
        }
        exit 124 if $state >= 1 && $st == 0;
        exit($st);
    ' "$limit" "$sig" "$grace" "$@"
}

PERL_BIN=''
# portable_timeout_available -> 0 when the perl supervisor can be used
portable_timeout_available() {
    ((TIMEOUT > 0)) || return 1
    if [ -z "$PERL_BIN" ]; then
        if have perl; then PERL_BIN="$(command -v perl)"; else PERL_BIN='none'; fi
    fi
    [ "$PERL_BIN" != 'none' ]
}

# wp_timeout_warning : say once that a bound was asked for and cannot be had.
wp_timeout_warning() {
    if [ "$WARNED_NO_TIMEOUT" = 'false' ]; then
        log_warn "neither timeout(1) nor perl(1) was found; --timeout ${TIMEOUT} is ignored and a hung wp process will block the run"
        WARNED_NO_TIMEOUT='true'
    fi
    return 0
}

# wp_is_readonly ARGS... -> 0 when the command changes nothing.
#
# This classification is what makes --dry-run useful instead of decorative. A dry
# run that also skipped every query cannot enumerate revisions, cannot resolve a
# plugin name to a slug, cannot build a report and cannot tell the operator what
# it would have done -- which is the only thing a dry run is for. So: read-only
# commands execute for real, mutating commands are printed and skipped.
#
# The list is an allowlist, not a denylist. Anything unknown is treated as
# mutating, because guessing wrong in that direction costs a no-op and guessing
# wrong in the other direction costs data.
wp_is_readonly() {
    local c="${1-}" sub="${2-}" third="${3-}" sql=''
    case "$c" in
        cli)
            case "$sub" in
                version | info | check-update | has-command) return 0 ;;
            esac
            ;;
        help) return 0 ;;
        core)
            case "$sub" in
                version | check-update | verify-checksums | is-installed |                     download | md5sum | update-db)
                # `download` writes a file but touches no site data, and
                # `update-db` is not read-only at all: it is listed here only so
                # that the reader notices it was considered and rejected.
                case "$sub" in
                    download | update-db) return 1 ;;
                    *) return 0 ;;
                esac
                ;;
            esac
            ;;
        plugin | theme)
            case "$sub" in
                list | status | get | search | is-installed | verify-checksums) return 0 ;;
            esac
            ;;
        language)
            case "$third" in
                list | is-installed) return 0 ;;
            esac
            ;;
        option | config)
            case "$sub" in
                get | list | has | exists) return 0 ;;
            esac
            ;;
        user | post | comment | site | network | term | menu | widget | sidebar | cron)
            case "$sub" in
                list | get | exists | is-installed) return 0 ;;
            esac
            [ "$c" = 'cron' ] && [ "$sub" = 'test' ] && return 0
            [ "$c" = 'cron' ] && [ "$sub" = 'event' ] && [ "$third" = 'list' ] && return 0
            ;;
        transient)
            case "$sub" in
                list | get | type) return 0 ;;
            esac
            ;;
        rewrite)
            case "$sub" in
                list | structure | flush) [ "$sub" = 'flush' ] && return 1; return 0 ;;
            esac
            ;;
        db)
            case "$sub" in
                size | tables | columns | prefix | check | tables) return 0 ;;
                query)
                    # `db query` can do anything, so it is read-only only when the
                    # statement is unmistakably a read. This is the one place the
                    # allowlist has to look at an argument, and it looks at the
                    # first word only.
                    sql="${3-}"
                    sql="${sql#"${sql%%[![:space:]]*}"}"
                    case "${sql^^}" in
                        SELECT* | SHOW* | DESCRIBE* | DESC* | EXPLAIN* | USE* | WITH*) return 0 ;;
                    esac
                    return 1
                    ;;
            esac
            ;;
        maintenance-mode)
            [ "$sub" = 'status' ] && return 0
            ;;
        eval | eval-file | shell)
            # Arbitrary PHP. Never treated as read-only, whatever it claims.
            return 1
            ;;
    esac
    return 1
}

# wp_exec SITE USER URL ARGS...
#
# Fills WP_OUTPUT / WP_STATUS / WP_STDERR and always returns 0, so a failing
# site cannot abort a caller that runs under `set -e`-ish discipline; the status
# travels in the variable and the counters live in the wrappers below.
wp_exec() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    local -a argv=() pre=() envv=() run=()
    local ar start end display errfile rc=0

    WP_OUTPUT='' WP_STATUS=0 WP_SKIPPED='false' WP_STDERR=''

    if [ ! -d "$site" ]; then
        WP_STATUS=2
        WP_OUTPUT="not a directory: ${site}"
        return 0
    fi
    if ! wp_ensure; then
        WP_STATUS=3
        WP_OUTPUT='WP-CLI is not available'
        return 0
    fi

    mapfile -t envv < <(site_env_argv "$site" "$user")
    argv=(env "${envv[@]}")
    pre=()
    mapfile -t pre < <(timeout_argv 2>/dev/null)
    ((${#pre[@]} > 0)) && argv+=("${pre[@]}")
    argv+=("$WP_RESOLVED" "--path=$site")
    if [ -n "$url" ]; then
        argv+=("--url=$url")
    elif [ -n "$URL" ]; then
        argv+=("--url=$URL")
    fi
    ar="$(allow_root_flag)"
    [ -n "$ar" ] && argv+=("$ar")
    if [ -n "$SKIP_PLUGINS" ] && skip_plugins_applies_to "${1:-}" "${2:-}"; then
        argv+=("--skip-plugins=$SKIP_PLUGINS")
    fi
    argv+=("$@")

    if [ "$DRY_RUN" = 'true' ] && ! wp_is_readonly "$@"; then
        display="$(argv_display "${argv[@]}")"
        # A dry run must show the *real* command, but never a secret.
        display="${display//$LICENCE_MARKER/<licence>}"
        log_info "[dry-run] (${user}@$(path_base "$site")) would run: ${display}"
        WP_SKIPPED='true'
        return 0
    fi

    if [ "$VERBOSE" = 'true' ]; then
        display="$(argv_display "${argv[@]}")"
        log_debug "exec as ${user}: ${display//$LICENCE_MARKER/<licence>}"
    fi

    if needs_licence_handoff "$@"; then
        licence_open || {
            WP_STATUS=1
            WP_OUTPUT='cannot prepare the licence hand-off'
            return 0
        }
        if ! mapfile -t run < <(child_argv WP_CLI_LICENCE "${argv[@]}"); then
            WP_STATUS=1
            WP_OUTPUT='cannot build the licence hand-off command'
            return 0
        fi
    else
        run=("${argv[@]}")
    fi

    now_epoch >/dev/null; start="$EPOCH_NOW"
    if [ "$WP_CAPTURE" = 'stdout' ]; then
        errfile="$(wp_err_file)" || errfile='/dev/null'
        : >"$errfile" 2>/dev/null
        if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ] && needs_licence_handoff "$@"; then
            WP_OUTPUT="$(printf '%s\n' "$LICENCE_VALUE" |
                run_as_user "$site" "$user" "${run[@]}" 2>"$errfile")" || rc=$?
        else
            WP_OUTPUT="$(run_as_user "$site" "$user" "${run[@]}" 2>"$errfile" </dev/null)" || rc=$?
        fi
        WP_STATUS=$rc
        WP_STDERR="$(head -c 65536 -- "$errfile" 2>/dev/null)"
    else
        if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ] && needs_licence_handoff "$@"; then
            WP_OUTPUT="$(printf '%s\n' "$LICENCE_VALUE" |
                run_as_user "$site" "$user" "${run[@]}" 2>&1)" || rc=$?
        else
            # </dev/null is not cosmetic: a wp command that decides to prompt
            # would otherwise wait forever on a cron job's closed stdin, and the
            # symptom is a fleet run that hangs with no message at all.
            WP_OUTPUT="$(run_as_user "$site" "$user" "${run[@]}" 2>&1 </dev/null)" || rc=$?
        fi
        WP_STATUS=$rc
    fi
    licence_close
    now_epoch >/dev/null; end="$EPOCH_NOW"

    # timeout(1) reports 124, and 137 when it had to escalate to SIGKILL. The
    # perl supervisor reports 124 for both.
    case "$WP_STATUS" in
        124 | 137 | 143)
            WP_OUTPUT="${WP_OUTPUT}
[command exceeded ${TIMEOUT}s and was terminated with ${TIMEOUT_SIGNAL}]"
            log_warn "wp timed out after ${TIMEOUT}s on ${site}: $(argv_display "$@")"
            ;;
    esac
    redact "$*"
    log_debug "wp exited ${WP_STATUS} in $((end - start))s: ${REDACTED}"
    return 0
}

# wp_exec_portable SITE USER URL ARGS...
#
# The fallback path used when timeout(1) is absent: the whole switch-and-exec
# argv goes under the perl supervisor, so the bound also covers a `su` that
# stalls. Kept separate from wp_exec so the normal path stays readable and the
# rare path stays reviewable.
wp_exec_portable() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    local -a argv=() envv=() run=() outer=()
    local ar start end rc=0 errfile=''

    WP_OUTPUT='' WP_STATUS=0 WP_SKIPPED='false' WP_STDERR=''
    if [ ! -d "$site" ]; then
        WP_STATUS=2; WP_OUTPUT="not a directory: ${site}"; return 0
    fi
    wp_ensure || { WP_STATUS=3; WP_OUTPUT='WP-CLI is not available'; return 0; }

    mapfile -t envv < <(site_env_argv "$site" "$user")
    argv=(env "${envv[@]}" "$WP_RESOLVED" "--path=$site")
    if [ -n "$url" ]; then
        argv+=("--url=$url")
    elif [ -n "$URL" ]; then
        argv+=("--url=$URL")
    fi
    ar="$(allow_root_flag)"
    [ -n "$ar" ] && argv+=("$ar")
    if [ -n "$SKIP_PLUGINS" ] && skip_plugins_applies_to "${1:-}" "${2:-}"; then
        argv+=("--skip-plugins=$SKIP_PLUGINS")
    fi
    argv+=("$@")

    if [ "$DRY_RUN" = 'true' ] && ! wp_is_readonly "$@"; then
        log_info "[dry-run] (${user}@$(path_base "$site")) would run: $(argv_display "${argv[@]}")"
        WP_SKIPPED='true'
        return 0
    fi
    if needs_licence_handoff "$@"; then
        licence_open || { WP_STATUS=1; WP_OUTPUT='cannot prepare the licence hand-off'; return 0; }
        if ! mapfile -t run < <(child_argv WP_CLI_LICENCE "${argv[@]}"); then
            WP_STATUS=1; WP_OUTPUT='cannot build the licence hand-off command'; return 0
        fi
    else
        run=("${argv[@]}")
    fi
    if ! user_switch_argv "$site" "$user" "${run[@]}"; then
        WP_STATUS=127; WP_OUTPUT="cannot switch to ${user}"; licence_close; return 0
    fi
    outer=("${USER_SWITCH_ARGV[@]}")

    if [ "$WARNED_PORTABLE_TIMEOUT" = 'false' ]; then
        log_debug "timeout(1) not found; using the perl supervisor for --timeout ${TIMEOUT}"
        WARNED_PORTABLE_TIMEOUT='true'
    fi
    now_epoch >/dev/null; start="$EPOCH_NOW"
    if [ "$WP_CAPTURE" = 'stdout' ]; then
        errfile="$(wp_err_file)" || errfile='/dev/null'
        : >"$errfile" 2>/dev/null
        if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ] && needs_licence_handoff "$@"; then
            WP_OUTPUT="$(printf '%s\n' "$LICENCE_VALUE" |
                perl_supervisor "$TIMEOUT" "$TIMEOUT_SIGNAL" "$KILL_AFTER" \
                    "${outer[@]}" 2>"$errfile")" || rc=$?
        else
            WP_OUTPUT="$(perl_supervisor "$TIMEOUT" "$TIMEOUT_SIGNAL" "$KILL_AFTER" \
                "${outer[@]}" 2>"$errfile" </dev/null)" || rc=$?
        fi
        WP_STDERR="$(head -c 65536 -- "$errfile" 2>/dev/null)"
    else
        if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ] && needs_licence_handoff "$@"; then
            WP_OUTPUT="$(printf '%s\n' "$LICENCE_VALUE" |
                perl_supervisor "$TIMEOUT" "$TIMEOUT_SIGNAL" "$KILL_AFTER" \
                    "${outer[@]}" 2>&1)" || rc=$?
        else
            WP_OUTPUT="$(perl_supervisor "$TIMEOUT" "$TIMEOUT_SIGNAL" "$KILL_AFTER" \
                "${outer[@]}" 2>&1 </dev/null)" || rc=$?
        fi
    fi
    WP_STATUS=$rc
    licence_close
    now_epoch >/dev/null; end="$EPOCH_NOW"
    case "$WP_STATUS" in
        124 | 137 | 143)
            WP_OUTPUT="${WP_OUTPUT}
[command exceeded ${TIMEOUT}s and was terminated with ${TIMEOUT_SIGNAL}]"
            log_warn "wp timed out after ${TIMEOUT}s on ${site}: $(argv_display "$@")"
            ;;
    esac
    redact "$*"
    log_debug "wp exited ${WP_STATUS} in $((end - start))s (portable timeout): ${REDACTED}"
    return 0
}

# wp_dispatch SITE USER URL ARGS... : choose the execution path once per call.
wp_dispatch() { # SITE USER URL ARGS...
    if ((TIMEOUT > 0)) && ! have timeout && portable_timeout_available; then
        wp_exec_portable "$@"
        return 0
    fi
    if ((TIMEOUT > 0)) && ! have timeout && ! portable_timeout_available; then
        wp_timeout_warning
    fi
    wp_exec "$@"
}

# count_op OK(0|1) : the single place where operation counters move.
count_op_ok() { STATS_OPS_OK=$((STATS_OPS_OK + 1)); }
count_op_failed() { STATS_OPS_FAILED=$((STATS_OPS_FAILED + 1)); }

# run_wp SITE USER URL ARGS...
# A hard operation: a failure is logged, counted, boxed on the console and
# returned. The fleet continues with the next site.
run_wp() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    wp_dispatch "$site" "$user" "$url" "$@"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS == 0)); then
        count_op_ok
        if [ -n "$WP_OUTPUT" ] && [ "$QUIET" != 'true' ] && [ "$VERBOSE" = 'true' ] &&
           ! is_machine_format; then
            printf '%s\n' "$WP_OUTPUT"
        elif [ -n "$WP_STDERR" ] && [ "$VERBOSE" = 'true' ]; then
            redact "$WP_STDERR"
            log_debug "stderr: ${REDACTED}"
        fi
        return 0
    fi
    count_op_failed
    log_error "wp $* failed on ${site} (exit ${WP_STATUS})"
    log_error_detail 'run_wp' "wp $*" "${WP_OUTPUT}${WP_STDERR:+$'\n'"$WP_STDERR"}" "$WP_STATUS"
    print_error_box "$site" "wp $*" "$WP_OUTPUT"
    return 1
}

# run_wp_soft SITE USER URL ARGS...
#
# An opportunistic step: a failure is a warning and is NOT counted as a failed
# operation. Used for the Astra licence dance inside --full and for anything
# where aborting a whole site over one hiccup would be worse than reporting it.
# It still *returns* the outcome, because a caller such as astra_step has to know
# whether to retry:
#   0 succeeded, 1 failed softly, 2 not executed (dry run).
run_wp_soft() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    wp_dispatch "$site" "$user" "$url" "$@"
    [ "$WP_SKIPPED" = 'true' ] && return 2
    if ((WP_STATUS == 0)); then
        count_op_ok
        return 0
    fi
    log_warn "wp $* did not succeed on ${site} (exit ${WP_STATUS}); continuing"
    log_error_detail 'run_wp_soft' "wp $*" "${WP_OUTPUT}${WP_STDERR:+$'\n'"$WP_STDERR"}" "$WP_STATUS"
    return 1
}

# info_wp SITE USER URL ARGS...
#
# Information only. It never touches the operation counters, because several
# WP-CLI commands legitimately exit non-zero when there is nothing to do
# (`core check-update`, `cli check-update`, `plugin list --update=available`),
# and counting those as failures would cry wolf on every healthy run.
info_wp() { # SITE USER URL ARGS...
    wp_dispatch "$@"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS == 0)); then
        if [ -n "$WP_OUTPUT" ]; then
            redact "${WP_OUTPUT//$'\n'/ | }"
            log_debug "info: ${REDACTED}"
        fi
    else
        redact "${WP_OUTPUT//$'\n'/ | }"
        log_debug "info returned ${WP_STATUS}: ${REDACTED}"
    fi
    return 0
}

# wp_data SITE USER URL ARGS... : a machine-readable fetch.
# stdout only, so a plugin's deprecation notice cannot corrupt the payload, and
# stderr is kept for the log. Every `--format=json`, `option get` and `db size`
# call in this tool goes through here.
wp_data() { # SITE USER URL ARGS...
    local saved="$WP_CAPTURE"
    WP_CAPTURE='stdout'
    wp_dispatch "$@"
    WP_CAPTURE="$saved"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)) && [ -n "$WP_STDERR" ]; then
        redact "$WP_STDERR"
        log_debug "wp stderr: ${REDACTED}"
    fi
    return 0
}

# wp_probe SITE USER URL ARGS... -> the trimmed stdout of a read-only call.
# Prints nothing and counts nothing on failure; the caller checks the status.
wp_probe() { # SITE USER URL ARGS...
    wp_data "$@"
    [ "$WP_SKIPPED" = 'true' ] && return 1
    ((WP_STATUS == 0)) || return 1
    WP_PROBE="$(trim "$WP_OUTPUT")"
    return 0
}
WP_PROBE=''

# wp_json SITE USER URL ARGS... -> the JSON array slice of a read-only call,
# empty and non-zero when wp did not return one.
wp_json() { # SITE USER URL ARGS...
    wp_data "$@"
    [ "$WP_SKIPPED" = 'true' ] && return 1
    ((WP_STATUS == 0)) || return 1
    json_array_slice "$WP_OUTPUT"
}

# wp_supported SITE USER SUB... -> 0 when this WP-CLI knows the subcommand.
# `maintenance-mode` needs WP 5.5 and WP-CLI 2.4; `language` needs 2.2; `db
# size` needs 2.3. Probing with `help` is cheaper and more honest than a version
# table, and it caches per subcommand for the whole run.
declare -A WP_HAS_COMMAND=()
wp_supported() { # SITE USER SUB...
    local site="$1" user="$2"
    shift 2
    local key="$*"
    if [ -n "${WP_HAS_COMMAND[$key]+x}" ]; then
        [ "${WP_HAS_COMMAND[$key]}" = 'yes' ] && return 0
        return 1
    fi
    wp_data "$site" "$user" '' help "$@"
    if ((WP_STATUS == 0)); then
        WP_HAS_COMMAND["$key"]='yes'
        return 0
    fi
    WP_HAS_COMMAND["$key"]='no'
    log_debug "this WP-CLI does not support: wp ${key}"
    return 1
}
