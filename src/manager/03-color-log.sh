###############################################################################
# Section 5 - colour policy
###############################################################################
#
# Colour is a console affordance, never data. Every rule here exists to keep
# escape sequences out of log files, pipes, cron mail and CI output, where they
# are noise at best and break a parser at worst.

C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''

# color_resolve WHEN -> 0 when colour should be emitted
color_resolve() {
    local want="${1:-auto}"
    case "$want" in
        always) return 0 ;;
        never) return 1 ;;
        auto)
            # Logs are redirected more often than they are watched. Colour only
            # when both streams are terminals, and never when the caller opted
            # out through the de-facto standard NO_COLOR variable.
            [ -n "${NO_COLOR:-}" ] && return 1
            [ "${TERM:-}" = 'dumb' ] && return 1
            [ "${CLICOLOR:-1}" = '0' ] && return 1
            [ -t 1 ] && [ -t 2 ] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

color_init() {
    if color_resolve "${COLOR:-auto}"; then
        C_RESET=$'\033[0m' C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[1;33m' C_BLUE=$'\033[0;34m' C_CYAN=$'\033[0;36m'
        C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    else
        C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
        C_BOLD='' C_DIM=''
    fi
    return 0
}

# is_machine_format -> 0 when stdout must carry data only.
is_machine_format() {
    [ "${JSON_LINES:-false}" = 'true' ] && return 0
    case "${OUTPUT_FORMAT:-table}" in
        json | csv | tsv) return 0 ;;
    esac
    return 1
}

# Stream policy: every log line, warning and progress message goes to stderr in
# every format, including the human-readable table. The rule "stdout is data,
# stderr is prose" is what makes `--report > report.tsv`,
# `--list-plugins --format csv | ...` and `--full 2>> maintenance.err` all
# behave, and it is the rule the machine-readable formats already had to follow.
# Applying it to the table format too removes the one case where a redirect
# captured the log as well as the result.
#
# What still goes to stdout is the payload of the mode itself: the tables, the
# JSON, the --check report and the --status listing. Those are the answer to the
# question that was asked, not commentary on how it was obtained.
#
# A previous revision had a prose_stream() helper that returned the file
# descriptor as a string and was called through a command substitution. That is
# one fork per log line, and a 200-site run writes tens of thousands of them.
# The destination is now the constant it always should have been.

###############################################################################
# Section 6 - logging, redaction, rotation
###############################################################################
#
# Fork discipline
# ---------------
# Nothing on the logging path creates a process. Timestamps come from bash's own
# `printf '%(...)T'`, redaction and JSON escaping publish their result in a
# global instead of on stdout, and the log size is tracked in memory rather than
# stat(2)ed after every line. This is not micro-optimisation for its own sake:
# a fleet run writes one log line per site per operation, so a fork per line is a
# fork per `wp` invocation and then some, the run takes measurably longer, and on
# a host that is at its process limit the tool stops working entirely. The
# convention is documented here because it is the one rule a new log helper is
# most likely to break by accident.

LOG_INIT='false'
declare -A LOG_RANK=([debug]=10 [info]=20 [warn]=30 [error]=40)

# Values that must never reach a log line, a console or a report. Filled as soon
# as they are known; redact() walks the list on every message.
REDACT_VALUES=()

# Placeholder that travels through argv in place of a secret.
LICENCE_MARKER='@@WP_CLI_UPDATE_LICENCE@@'

WARNED_NO_LOGGER='false'
SYSLOG_TAG=''

# Result globals, set instead of printed. See the fork discipline note above.
REDACTED=''
LOG_TS=''

# redact_register VALUE : remember a secret so it can be masked everywhere
redact_register() {
    local v="${1:-}" known
    [ -n "$v" ] || return 0
    # A three-character "secret" would redact half the alphabet and turn the log
    # into noise, which is how redaction gets switched off.
    ((${#v} < 4)) && return 0
    for known in ${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}; do
        [ "$known" = "$v" ] && return 0
    done
    REDACT_VALUES+=("$v")
    return 0
}

# redact TEXT -> sets REDACTED to TEXT with every registered secret and the
# licence marker replaced. Applied on the way into the log file, onto the
# console, into the error detail log and into every report field.
redact() {
    local text="${1-}" v
    if ((${#REDACT_VALUES[@]} > 0)); then
        for v in ${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}; do
            [ -n "$v" ] || continue
            text="${text//"$v"/<redacted>}"
        done
    fi
    # The marker is not a secret, but printing it verbatim in an error line looks
    # like a bug to whoever reads the log at 3 a.m.
    REDACTED="${text//$LICENCE_MARKER/<licence>}"
    return 0
}

# log_ts : current local time as YYYY-mm-dd HH:MM:SS, without forking date(1).
log_ts() {
    printf -v LOG_TS '%(%Y-%m-%d %H:%M:%S)T' -1
    return 0
}

log_level_enabled() {
    local want="${1:-info}"
    ((${LOG_RANK[$want]:-20} >= ${LOG_RANK[${LOG_LEVEL:-info}]:-20}))
}

# Log sizes are tracked in memory. rotate_log used to stat(2) the file after
# every single line, which is a fork per line for an answer that changes only by
# the length of that line.
LOG_FILE_BYTES=0
ERROR_LOG_BYTES=0

# rotate_log FILE : keep LOG_KEEP generations once the file passes LOG_MAX_BYTES.
rotate_log() { # FILE
    local f="${1:-}" n
    [ -n "$f" ] && [ -f "$f" ] || return 0
    is_uint "${LOG_MAX_BYTES:-0}" || return 0
    ((LOG_MAX_BYTES > 0)) || return 0
    ((LOG_KEEP >= 1)) || return 0
    file_size "$f"
    ((FILE_SIZE < LOG_MAX_BYTES)) && return 0
    # Oldest generation falls off the end, then everything shifts up by one.
    rm -f -- "${f}.${LOG_KEEP}" 2>/dev/null
    for ((n = LOG_KEEP; n >= 2; n--)); do
        [ -f "${f}.$((n - 1))" ] && mv -f -- "${f}.$((n - 1))" "${f}.${n}" 2>/dev/null
    done
    mv -f -- "$f" "${f}.1" 2>/dev/null || : >"$f"
    return 0
}

# syslog_write LEVEL MESSAGE : optional mirror of every line into syslog, so a
# host that already ships journald or rsyslog somewhere gets the maintenance
# history for free. logger(1) is probed, never assumed, and this is the one
# logging helper that is allowed to fork, because it only runs when the operator
# explicitly asked for syslog.
syslog_write() { # LEVEL MESSAGE
    [ "${SYSLOG:-false}" = 'true' ] || return 0
    if ! have logger; then
        if [ "$WARNED_NO_LOGGER" = 'false' ]; then
            WARNED_NO_LOGGER='true'
            printf 'WRN logger(1) not found; SYSLOG is ignored\n' >&2
        fi
        return 0
    fi
    local prio
    case "${1:-info}" in
        error) prio='user.err' ;;
        warn) prio='user.warning' ;;
        debug) prio='user.debug' ;;
        *) prio='user.info' ;;
    esac
    [ -n "$SYSLOG_TAG" ] || SYSLOG_TAG="${PROG_NAME%.*}"
    logger -t "$SYSLOG_TAG" -p "$prio" -- "${2:-}" 2>/dev/null
    return 0
}

# log_write_file LEVEL MESSAGE
log_write_file() { # LEVEL MESSAGE
    local level="${1:-info}" msg="${2-}" line=''
    [ "$LOG_INIT" = 'true' ] || return 0
    log_ts
    redact "$msg"
    if [ "${LOG_FORMAT:-text}" = 'json' ]; then
        json_escape "$REDACTED"
        line="{\"ts\":\"${LOG_TS}\",\"level\":\"${level}\",\"pid\":$$,\"msg\":\"${JSON_ESCAPED}\"}"
    else
        line="[${LOG_TS}] [${level^^}] ${REDACTED}"
        [ "${LOG_PID:-false}" = 'true' ] && line="[$$] ${line}"
    fi
    # Inside a worker the shared log file is off limits: concurrent appends from
    # several sites interleave, and rotate_log could fire mid-batch. The line
    # goes to the worker fragment and the parent appends the fragments in site
    # order after the barrier.
    if [ "${PARALLEL:-false}" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '%s\n' "$line" >>"${WORKER_DIR}/log" 2>/dev/null
        return 0
    fi
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null
    LOG_FILE_BYTES=$((LOG_FILE_BYTES + ${#line} + 1))
    if ((LOG_MAX_BYTES > 0)) && ((LOG_FILE_BYTES >= LOG_MAX_BYTES)); then
        rotate_log "$LOG_FILE"
        LOG_FILE_BYTES=0
    fi
    return 0
}

# log LEVEL MESSAGE
#
# One console prefix per level. Everything the operator sees goes through here,
# so the log file never receives colour codes and the console never receives a
# raw timestamp.
log() { # LEVEL MESSAGE
    local level="${1:-info}" msg="${2-}" mark color file_level
    case "$level" in
        debug) mark='DBG'; color="$C_CYAN" ;;
        info) mark='INF'; color="$C_BLUE" ;;
        ok) mark=' OK'; color="$C_GREEN" ;;
        warn) mark='WRN'; color="$C_YELLOW" ;;
        error) mark='ERR'; color="$C_RED" ;;
        *) mark='LOG'; color='' ;;
    esac
    file_level="$level"
    [ "$level" = 'ok' ] && file_level='info'

    log_write_file "$file_level" "$msg"
    redact "$msg"
    syslog_write "$file_level" "$REDACTED"
    log_level_enabled "$file_level" || return 0
    if [ "${QUIET:-false}" = 'true' ]; then
        case "$level" in warn | error) ;; *) return 0 ;; esac
    fi
    # A worker's console output is captured into its fragment and replayed by the
    # parent in site order; writing straight to the terminal would interleave
    # three sites into unreadable noise.
    if [ "${PARALLEL:-false}" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$REDACTED" >>"${WORKER_DIR}/out"
        return 0
    fi
    printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$REDACTED" >&2
    return 0
}

log_debug() { log debug "${1:-}"; }
log_info() { log info "${1:-}"; }
log_ok() { log ok "${1:-}"; }
log_warn() {
    STATS_WARNINGS=$((STATS_WARNINGS + 1))
    log warn "${1:-}"
}
log_error() { log error "${1:-}"; }

# head_lines N < TEXT -> sets HEAD_LINES to the first N lines. Pure bash: the
# error path already runs when something went wrong, and forking there is how a
# tool manages to fail twice.
HEAD_LINES=''
head_lines() { # N
    local n="${1:-20}" line i=0
    HEAD_LINES=''
    is_uint "$n" || n=20
    while IFS= read -r line; do
        ((i >= n)) && break
        HEAD_LINES+="${HEAD_LINES:+$'\n'}${line}"
        i=$((i + 1))
    done
    return 0
}

# log_error_detail CONTEXT COMMAND OUTPUT EXIT_CODE
#
# The full text of a failure, in one place, with the timestamp and the argv that
# produced it. The console gets a short box; this file is what you open when the
# box is not enough.
log_error_detail() { # CONTEXT COMMAND OUTPUT EXIT_CODE
    local context="${1:-}" command="${2:-}" output="${3:-}" rc="${4:-0}"
    [ -n "${ERROR_LOG_FILE:-}" ] || return 0
    log_ts
    {
        printf '[%s] [ERROR DETAIL] pid=%s\n' "$LOG_TS" "$$"
        printf 'Context  : %s\n' "$context"
        redact "$command"
        printf 'Command  : %s\n' "$REDACTED"
        printf 'Exit code: %s\n' "$rc"
        printf 'Output (first %s lines):\n' "${ERROR_OUTPUT_LINES:-20}"
        head_lines "${ERROR_OUTPUT_LINES:-20}" <<<"$output"
        redact "$HEAD_LINES"
        printf '%s\n' "$REDACTED"
        printf -- '---\n'
    } >>"$ERROR_LOG_FILE" 2>/dev/null
    ERROR_LOG_BYTES=$((ERROR_LOG_BYTES + ${#output} + 128))
    if ((LOG_MAX_BYTES > 0)) && ((ERROR_LOG_BYTES >= LOG_MAX_BYTES)); then
        rotate_log "$ERROR_LOG_FILE"
        ERROR_LOG_BYTES=0
    fi
    return 0
}

# print_error_box SITE COMMAND OUTPUT
#
# The first lines of a failing command, on the console, inside a box: a 200-site
# run still has to say *why* site 137 failed without anybody scrolling.
print_error_box() { # SITE COMMAND OUTPUT
    local site="${1:-}" command="${2:-}" output="${3:-}"
    local line shown=0
    [ "${QUIET:-false}" = 'true' ] && return 0
    is_machine_format && return 0
    redact "$command"
    printf '\n%s+--%s\n' "$C_RED" "$C_RESET" >&2
    printf '%s| %s%s\n' "$C_RED" "$REDACTED" "$C_RESET" >&2
    printf '%s| site: %s%s\n' "$C_RED" "$site" "$C_RESET" >&2
    printf '%s+--%s\n' "$C_RED" "$C_RESET" >&2
    while IFS= read -r line; do
        ((shown >= ${ERROR_OUTPUT_LINES:-20})) && break
        redact "$line"
        printf '| %s\n' "$REDACTED" >&2
        shown=$((shown + 1))
    done <<<"$output"
    printf '+-- full detail: %s\n\n' "${ERROR_LOG_FILE:-<disabled>}" >&2
    return 0
}

# log_init : make sure both log destinations are usable before the first line is
# written, and say so when they are not. A tool that silently loses its log is
# worse than one that complains once.
log_init() {
    LOG_INIT='true'
    local dir='' f='' stamp=''
    for f in "${LOG_FILE:-}" "${ERROR_LOG_FILE:-}"; do
        [ -n "$f" ] || continue
        dir="${f%/*}"
        [ "$dir" = "$f" ] && dir='.'
        if [ "$dir" != '.' ] && [ ! -d "$dir" ]; then
            mkdir -p -- "$dir" 2>/dev/null || {
                printf 'WRN cannot create log directory %s; file logging disabled\n' "$dir" >&2
                LOG_FILE='' ERROR_LOG_FILE=''
                return 0
            }
        fi
    done
    if [ -n "${LOG_FILE:-}" ] && ! : >>"$LOG_FILE" 2>/dev/null; then
        printf 'WRN log file %s is not writable; file logging disabled\n' "$LOG_FILE" >&2
        LOG_FILE=''
    fi
    if [ -n "${ERROR_LOG_FILE:-}" ] && ! : >>"$ERROR_LOG_FILE" 2>/dev/null; then
        printf 'WRN error log %s is not writable; error detail logging disabled\n' "$ERROR_LOG_FILE" >&2
        ERROR_LOG_FILE=''
    fi
    # Seed the in-memory size counters once, so rotation happens at the right
    # moment for a log that already existed.
    if [ -n "$LOG_FILE" ]; then
        file_size "$LOG_FILE"; LOG_FILE_BYTES="$FILE_SIZE"
        printf -v stamp '%(%a, %d %b %Y %H:%M:%S %z)T' -1
        printf '=== %s %s started at %s (pid %s, mode %s) ===\n' \
            "$PROG_NAME" "$SCRIPT_VERSION" "$stamp" "$$" "${MODE:-none}" \
            >>"$LOG_FILE" 2>/dev/null
    fi
    if [ -n "$ERROR_LOG_FILE" ]; then
        file_size "$ERROR_LOG_FILE"; ERROR_LOG_BYTES="$FILE_SIZE"
        [ -n "$stamp" ] || printf -v stamp '%(%a, %d %b %Y %H:%M:%S %z)T' -1
        printf '=== %s %s started at %s (pid %s) ===\n' \
            "$PROG_NAME" "$SCRIPT_VERSION" "$stamp" "$$" \
            >>"$ERROR_LOG_FILE" 2>/dev/null
    fi
    return 0
}
