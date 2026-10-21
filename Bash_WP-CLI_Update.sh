#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
#   "function is never invoked" / "command is unreachable" are disabled file-wide on
#   purpose. Three groups of functions here are reached in ways the analyser does not
#   follow: the parallel workers (started with `&` inside run_batched), the mode
#   functions (dispatched through `case "$MODE"` in run_mode), and the trap handlers.
#   Each of them is exercised by the test suite, which is the check that actually
#   matters. SC2317 is the same finding under its pre-0.11 name, so a host with an
#   older shellcheck reports the same verdict as CI.
###############################################################################
# WordPress Maintenance Automation
#
# File:        Bash_WP-CLI_Update.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     PolyForm Noncommercial 1.0.0 (see LICENSE)
# Version:     8.0.3
#
# Purpose
#   Run WP-CLI maintenance operations (core, plugins, themes, database, cron,
#   Astra Pro licence) over every WordPress installation listed in a site file,
#   each one as the system user that owns it.
#
# What the 8.0 line adds on top of the 6.x hybrids (8.0.x patches are fixes, not
# features: see CHANGELOG.md for what each one changed)
#   - read-only modes: --health (inventory: versions, pending updates, sizes),
#     --secrets (masked scan of wp-config.php), --doctor (host diagnostics);
#   - a restore path for the backups this tool creates: --list-backups and
#     --restore-db --yes (the missing half of "we take backups");
#   - fleet controls: --retry, --max-failures, --run-timeout, --skip-if-no-updates,
#     --lock-wait, per-site URL detection for multisite without --url;
#   - production guards: --min-free-mb (disk guard before a dump), --nice and
#     --ionice (do not starve the web server), --backup-age-days, --backup-compress;
#   - observability: --report FILE (JSON run report), --json-log (one JSON object
#     per log line), --notify URL / --mail-to for run summaries, --completion SHELL;
#   - plugin and theme policy: --exclude-themes, --hold-plugins, --hold-themes;
#   - config keys for the same, so a run does not have to be spelled out in cron.
#
# Usage
#   Bash_WP-CLI_Update.sh <MODE> [options]
#   Bash_WP-CLI_Update.sh --check [--site PATH]
#   Bash_WP-CLI_Update.sh --status
#
# Design notes (read before changing anything)
#   1. No command is ever built by string concatenation. Every WP-CLI call is a
#      bash array that becomes argv. The only place a string is handed to a
#      shell is the user switch, and there the arguments travel as positional
#      parameters, so no escaping is required at all (see run_as_user).
#   2. `printf %q` is a bash extension. It must never be used to build a string
#      for `sh -c`, `su -c` without `-s`, or `ssh`. If you need it, force the
#      interpreter: `su -s /bin/bash ...`.
#   3. The licence value is never an argument of any process. It is handed
#      over through a temporary file whose *path* goes on the command line,
#      and the child shell reads the value at run time. `ps` never shows it,
#      no log line contains it, and it is unlinked before the next site runs.
#      The file is 0644 for the duration of one call, because the process
#      reading it has already switched to the site owner; licence_open()
#      documents why every alternative is worse.
#   4. Configuration is data, not code. A config file is parsed as KEY=VALUE;
#      it is never sourced. A line with a shell metacharacter rejects the file.
#   5. Exit codes are a contract (see below) and are actually honoured: usage
#      errors are 2, not 1.
#   6. Read-only modes never take a backup and never hold a write lock on the
#      database: --health, --secrets, --list-plugins, --verify, --list-backups and
#      --check must be safe to run every minute from monitoring.
#   7. Anything that can destroy data (--restore-db) is a two-key operation: it
#      needs an explicit --yes AND a backup taken in the same run, and it refuses
#      to run in dry-run silence.
#
# Exit codes
#   0  success (with --fail-on=any: every operation on every site succeeded)
#   1  operational error (at least one WP-CLI operation failed)
#   2  usage error (bad command line)
#   3  environment error (bash too old, wp-cli missing, lock held, not root)
#   4  configuration error (unreadable or rejected config file)
#
# Requirements
#   bash 4.2+, GNU coreutils and findutils, WP-CLI, one of runuser/sudo/su,
#   root (to switch into site owners). `flock` and `timeout` are used when
#   present and degrade gracefully when they are not.
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash, but another shell started it.\n' >&2
    printf '       Run it as: bash %s [options]\n' "${0##*/}" >&2
    exit 3
fi
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    printf 'ERROR: %s requires bash 4.2 or newer (found %s).\n' \
        "${0##*/}" "${BASH_VERSION:-unknown}" >&2
    exit 3
fi

# Deliberately without -e: in a maintenance tool that walks a fleet, one failing
# site must not abort the run, and every error path below is handled by hand.
# `-u` stays on, because an unset variable here is always a bug.
set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

###############################################################################
# 1. Constants, exit codes, defaults
###############################################################################

PROG_NAME="${0##*/}"
SCRIPT_VERSION='8.0.3'

# A literal backtick, spelled by code point: the config parser has to reject it,
# and writing the character directly would make this file fail the project's own
# "no backticks" audit in tests/test_static.sh.
BACKTICK=$'\140'

EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_ENV=3
EXIT_CONFIG=4

resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [ "${src#/}" = "$src" ] && src="${dir}/${src}"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
SCRIPT_DIR="$(resolve_script_dir)" || {
    printf 'ERROR: cannot resolve the script directory\n' >&2; exit "$EXIT_ENV"; }
unset -f resolve_script_dir
readonly SCRIPT_DIR PROG_NAME

# Built-in defaults. Everything here is overridable by config file, environment
# or command line, in that order (see section 4).
DEFAULT_WP_CLI_PATH='/usr/local/bin/wp'
DEFAULT_SITES_FILE="${SCRIPT_DIR}/wp-found.txt"
DEFAULT_DISCOVER_SCRIPT="${SCRIPT_DIR}/Find_WP_Senior.sh"
DEFAULT_LOG_FILE="${SCRIPT_DIR}/wp_cli_manager.log"
DEFAULT_ERROR_LOG_FILE="${SCRIPT_DIR}/wp_cli_errors.log"
DEFAULT_LOCK_FILE="${SCRIPT_DIR}/.wp-cli-update.lock"
DEFAULT_LOG_MAX_BYTES=5242880        # 5 MiB
DEFAULT_LOG_KEEP=3
DEFAULT_ERROR_OUTPUT_LINES=20
DEFAULT_TIMEOUT=0                    # 0 = no timeout
DEFAULT_KILL_AFTER=30
DEFAULT_TIMEOUT_SIGNAL='TERM'
DEFAULT_ALLOW_ROOT='auto'            # auto | always | never
DEFAULT_COLOR='auto'                 # auto | always | never
DEFAULT_LOG_LEVEL='info'             # debug | info | warn | error
DEFAULT_FAIL_ON='any'                # any | all | never
DEFAULT_OUTPUT_FORMAT='table'        # table | json | csv | tsv
DEFAULT_ASTRA_SLUG='astra-addon'
DEFAULT_MAX_SITES=0                  # 0 = no limit
DEFAULT_JOBS=1                       # 1 = sequential; N = batches of N sites
DEFAULT_BACKUP='off'                 # off | db | full
DEFAULT_KEEP_BACKUPS=3
DEFAULT_BACKUP_DIR=''                # empty = <script dir>/backups
DEFAULT_BACKUP_AGE_DAYS=0            # 0 = keep by count only
DEFAULT_BACKUP_COMPRESS=0            # 1 = gzip a database dump after export
DEFAULT_MIN_FREE_MB=0                # 0 = no disk guard; 200 is a sane production value
DEFAULT_NICE_LEVEL=10                # 0 = do not renice the wp child
DEFAULT_IONICE_CLASS='none'          # idle | best-effort | none
DEFAULT_RETRY=0                      # extra attempts per failed site
DEFAULT_RETRY_DELAY=15               # seconds between attempts
DEFAULT_MAX_FAILURES=0               # 0 = never abort the fleet
DEFAULT_RUN_TIMEOUT=0                # 0 = no total budget
DEFAULT_LOCK_WAIT=0                  # 0 = fail at once when another run holds the lock
DEFAULT_NOTIFY_ON='failure'          # never | failure | always
DEFAULT_NOTIFY_TIMEOUT=10
DEFAULT_URL_DETECT=1                 # derive --url from wp-config.php when able
DEFAULT_LOG_JSON=0                   # 1 = one JSON object per log line
DEFAULT_SKIP_IF_NO_UPDATES=0         # skip a site whose plugins/themes/core are current

# Environment variables that may carry configuration. The list is explicit: an
# arbitrary variable is never read, so a hostile environment cannot inject a
# setting that the operator did not publish.
CONFIG_KEYS=(
    WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE
    LOG_MAX_BYTES LOG_KEEP LOG_LEVEL ERROR_OUTPUT_LINES COLOR
    SKIP_PLUGINS SKIP_PLUGINS_FOR_LISTING ALLOW_ROOT TIMEOUT KILL_AFTER
    TIMEOUT_SIGNAL FAIL_ON ASTRA_SLUG MAX_SITES AUTO_DISCOVER USER_ENV LICENCE
    JOBS BACKUP KEEP_BACKUPS BACKUP_DIR EXCLUDE_PLUGINS ONLY_ACTIVE STRICT
    NO_USER_SWITCH URL
    # 8.0.0 additions
    EXCLUDE_THEMES HOLD_PLUGINS HOLD_THEMES NICE_LEVEL IONICE_CLASS MIN_FREE_MB
    RETRY RETRY_DELAY MAX_FAILURES RUN_TIMEOUT LOCK_WAIT BACKUP_AGE_DAYS
    BACKUP_COMPRESS DEFAULT_USER NOTIFY_WEBHOOK NOTIFY_ON NOTIFY_TIMEOUT MAIL_TO
    REPORT_FILE LOG_JSON DRY_RUN SKIP_IF_NO_UPDATES URL_DETECT WP_GLOBAL_ARGS
)

# Configuration keys accepted under an older name, with the name to use instead.
# A 6.1 installation is documented to set WP_TIMEOUT and WP_CLI_BIN; silently
# ignoring them would turn a timeout into "no timeout", which is the kind of
# quiet regression that only shows up during an incident. The value is accepted,
# the operator is told once which name is current.
CONFIG_ALIASES=(
    WP_TIMEOUT=TIMEOUT
    WP_CLI_BIN=WP_CLI_PATH
    SITE_URL=URL
    BACKUP_KEEP=KEEP_BACKUPS
    DEFAULT_JOBS=JOBS
)

# `--skip-plugins` is only meaningful for subcommands that touch plugins.
# Passing it to `db optimize` or `cron event run` is noise at best.
# --skip-plugins belongs on operations that *change* plugins or themes. On a
# listing it hides exactly the plugins the operator asked to see, so it is only
# added there when --skip-plugins-for-listing says so.
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
        brainstormforce) return 0 ;;
        *) return 1 ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# is_set NAME -> true when the variable is set, in the shell or in the
# environment. `printenv` is what makes the second half work: an exported
# variable of the *calling* process is not always visible to `${!NAME+x}` in the
# way one expects, and without it the WP_CLI_UPDATE_* layer of the documented
# precedence silently did nothing.
is_set() {
    local n="${1:-}"
    [ -n "$n" ] || return 1
    if [ -n "${!n+set}" ]; then
        return 0
    fi
    printenv -- "$n" >/dev/null 2>&1
}

# env_value NAME -> the value from the environment, empty when unset
env_value() {
    local n="${1:-}"
    if [ -n "${!n+set}" ]; then
        printf '%s' "${!n}"
        return 0
    fi
    printenv -- "$n" 2>/dev/null
}

usage_error() { printf '%s: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
config_error() { printf '%s: config: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_CONFIG"; }
env_error() { printf '%s: environment: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_ENV"; }

###############################################################################
# 2. Colour policy
###############################################################################

COLOR_MODE="$DEFAULT_COLOR"
C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''

color_resolve() {
    local want="$1"
    case "$want" in
        always) return 0 ;;
        never) return 1 ;;
        auto)
            # Logs are redirected more often than they are watched. Colour only
            # when both the output and the error stream are a terminal, and
            # never when the caller asked for none of it.
            [ -n "${NO_COLOR:-}" ] && return 1
            [ "${TERM:-}" = 'dumb' ] && return 1
            [ -t 1 ] && [ -t 2 ] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

color_init() {
    if color_resolve "$COLOR_MODE"; then
        C_RESET=$'\033[0m' C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[1;33m' C_BLUE=$'\033[0;34m' C_CYAN=$'\033[0;36m'
        C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    else
        C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
        C_BOLD='' C_DIM=''
    fi
}

# A machine-readable format must produce *only* data on stdout. Everything an
# operator reads -- progress, warnings, the summary -- goes to stderr instead, so
# `... --format json | jq` and `... --format csv > plugins.csv` just work.
is_machine_format() {
    [ "${JSON_LINES:-false}" = 'true' ] && return 0
    case "${OUTPUT_FORMAT:-table}" in
        json | csv | tsv) return 0 ;;
    esac
    return 1
}

# prose_stream: 1 = stdout (human mode), 2 = stderr (data mode, or a real error)
prose_stream() { # LEVEL
    case "${1:-info}" in
        error | warn) printf '2'; return 0 ;;
    esac
    is_machine_format && { printf '2'; return 0; }
    printf '1'
}

###############################################################################
# 3. Logging, redaction, rotation
###############################################################################

LOG_FILE="$DEFAULT_LOG_FILE"
ERROR_LOG_FILE="$DEFAULT_ERROR_LOG_FILE"
LOG_MAX_BYTES="$DEFAULT_LOG_MAX_BYTES"
LOG_KEEP="$DEFAULT_LOG_KEEP"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
ERROR_OUTPUT_LINES="$DEFAULT_ERROR_OUTPUT_LINES"
QUIET='false'
VERBOSE='false'

LOG_INIT='false'
declare -A LOG_RANK=([debug]=10 [info]=20 [warn]=30 [error]=40)

# Values that must never reach a log line or a console. Filled as soon as they
# are known; redact() walks the list on every message.
REDACT_VALUES=()

# Placeholder that travels through argv in place of the licence value.
LICENCE_MARKER='@@WP_CLI_UPDATE_LICENCE@@'

redact_register() {
    local v="${1:-}"
    [ -n "$v" ] || return 0
    local known
    for known in ${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}; do
        [ "$known" = "$v" ] && return 0
    done
    REDACT_VALUES+=("$v")
}

redact() {
    local text="$1" v
    for v in ${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}; do
        [ -n "$v" ] || continue
        text="${text//"$v"/<redacted>}"
    done
    # The marker is not a secret, but printing it verbatim in an error line
    # would look like a bug to whoever reads the log.
    text="${text//$LICENCE_MARKER/<licence>}"
    printf '%s' "$text"
}

log_level_enabled() {
    local want="${1:-info}"
    ((${LOG_RANK[$want]:-20} >= ${LOG_RANK[$LOG_LEVEL]:-20}))
}

rotate_log() { # FILE
    local f="${1:-}" n
    [ -n "$f" ] && [ -f "$f" ] || return 0
    local size
    size="$(stat -c '%s' "$f" 2>/dev/null)" || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    ((LOG_MAX_BYTES > 0)) || return 0
    ((size < LOG_MAX_BYTES)) && return 0
    for ((n = LOG_KEEP; n >= 1; n--)); do
        if [ -f "${f}.$((n - 1))" ] || ((n == 1)); then
            [ -f "${f}.$((n - 1))" ] && mv -f -- "${f}.$((n - 1))" "${f}.${n}" 2>/dev/null
        fi
    done
    mv -f -- "$f" "${f}.1" 2>/dev/null || : >"$f"
    return 0
}

log_write_file() { # LEVEL MESSAGE
    local level="$1" msg="$2" ts
    [ "$LOG_INIT" = 'true' ] || return 0
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # --json-log: one object per line, so a log shipper (filebeat, promtail,
    # journald) can parse it without a regex. The human log stays as it was.
    if [ "$LOG_JSON" = 'true' ]; then
        local jline
        jline="$(printf '{"ts":"%s","level":"%s","msg":"%s"}' \
            "$ts" "${level^^}" "$(json_escape "$(redact "$msg")")")"
        if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
            printf '%s\n' "$jline" >>"${WORKER_DIR}/log" 2>/dev/null
            return 0
        fi
        [ -n "$LOG_FILE" ] || return 0
        printf '%s\n' "$jline" >>"$LOG_FILE" 2>/dev/null
        rotate_log "$LOG_FILE"
        return 0
    fi
    # Inside a worker the shared log file is off limits: concurrent appends from
    # several sites interleave and rotate_log could fire mid-batch. The line goes
    # to the worker fragment and the parent appends the fragments in site order.
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '[%s] [%s] %s\n' "$ts" "${level^^}" "$(redact "$msg")" >>"${WORKER_DIR}/log" 2>/dev/null
        return 0
    fi
    [ -n "$LOG_FILE" ] || return 0
    printf '[%s] [%s] %s\n' "$ts" "${level^^}" "$(redact "$msg")" >>"$LOG_FILE" 2>/dev/null
    rotate_log "$LOG_FILE"
}

# One console prefix per level. Everything the operator sees goes through here,
# so the log file never receives colour codes and the console never receives a
# raw timestamp.
log() { # LEVEL MESSAGE
    local level="${1:-info}" msg="${2:-}" mark color
    case "$level" in
        debug) mark='DBG'; color="$C_CYAN" ;;
        info)  mark='INF'; color="$C_BLUE" ;;
        ok)    mark=' OK'; color="$C_GREEN" ;;
        warn)  mark='WRN'; color="$C_YELLOW" ;;
        error) mark='ERR'; color="$C_RED" ;;
        *)     mark='LOG'; color='' ;;
    esac
    local file_level="$level"
    [ "$level" = 'ok' ] && file_level='info'
    log_write_file "$file_level" "$msg"
    log_level_enabled "$file_level" || return 0
    if [ "$QUIET" = 'true' ]; then
        case "$level" in warn | error) ;; *) return 0 ;; esac
    fi
    local fd
    fd="$(prose_stream "$level")"
    # A worker's console output is captured into its fragment and replayed by the
    # parent in site order; writing straight to the terminal would interleave
    # three sites into unreadable noise.
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$(redact "$msg")" >>"${WORKER_DIR}/out"
        return 0
    fi
    printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$(redact "$msg")" >&"$fd"
}

log_debug() { log debug "${1:-}"; }
log_info() { log info "${1:-}"; }
log_ok() { log ok "${1:-}"; }
log_warn() {
    STATS_WARNINGS=$((STATS_WARNINGS + 1))
    log warn "${1:-}"
}
# A portability note: the environment is missing an optional helper (flock,
# timeout, perl). It is logged, but it is not counted as a warning -- a host
# that has never had these tools must not fail a clean run under --strict,
# otherwise the strictness contract becomes unfulfillable on minimal systems.
log_note() { log warn "note: ${1:-}"; }
log_error() { log error "${1:-}"; }

log_error_detail() { # CONTEXT COMMAND OUTPUT EXIT_CODE
    local context="${1:-}" command="${2:-}" output="${3:-}" rc="${4:-0}" ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$ERROR_LOG_FILE" ] || return 0
    {
        printf '[%s] [ERROR DETAIL]\n' "$ts"
        printf 'Context: %s\n' "$context"
        printf 'Command: %s\n' "$(redact "$command")"
        printf 'Exit code: %s\n' "$rc"
        printf 'Output (first %s lines):\n' "$ERROR_OUTPUT_LINES"
        printf '%s\n' "$(redact "$output")" | head -n "$ERROR_OUTPUT_LINES"
        printf -- '---\n'
    } >>"$ERROR_LOG_FILE" 2>/dev/null
    rotate_log "$ERROR_LOG_FILE"
}

# Print the first lines of a failing command to the console inside a box, so a
# 200-site run still shows *why* site 137 failed without scrolling.
print_error_box() { # SITE COMMAND OUTPUT
    local site="${1:-}" command="${2:-}" output="${3:-}"
    local line shown=0
    printf '\n%s+--%s\n' "$C_RED" "$C_RESET" >&2
    printf '%s| %s%s\n' "$C_RED" "$(redact "$command")" "$C_RESET" >&2
    printf '%s| site: %s%s\n' "$C_RED" "$site" "$C_RESET" >&2
    printf '%s+--%s\n' "$C_RED" "$C_RESET" >&2
    while IFS= read -r line; do
        ((shown >= ERROR_OUTPUT_LINES)) && break
        printf '| %s\n' "$(redact "$line")" >&2
        shown=$((shown + 1))
    done <<<"$output"
    printf '+-- full log: %s\n\n' "$ERROR_LOG_FILE" >&2
}

log_init() {
    LOG_INIT='true'
    local dir
    for dir in "$(dirname -- "$LOG_FILE")" "$(dirname -- "$ERROR_LOG_FILE")"; do
        if [ -n "$dir" ] && [ "$dir" != '.' ] && [ ! -d "$dir" ]; then
            mkdir -p -- "$dir" 2>/dev/null || {
                log_warn "cannot create log directory ${dir}; file logging disabled"
                LOG_FILE='' ERROR_LOG_FILE=''
                return 0
            }
        fi
    done
    if [ -n "$LOG_FILE" ] && ! : >>"$LOG_FILE" 2>/dev/null; then
        log_warn "log file ${LOG_FILE} is not writable; file logging disabled"
        LOG_FILE=''
    fi
    if [ -n "$ERROR_LOG_FILE" ] && ! : >>"$ERROR_LOG_FILE" 2>/dev/null; then
        log_warn "error log ${ERROR_LOG_FILE} is not writable; file logging disabled"
        ERROR_LOG_FILE=''
    fi
    if [ -n "$ERROR_LOG_FILE" ]; then
        printf '=== %s %s started at %s (pid %s) ===\n' \
            "$PROG_NAME" "$SCRIPT_VERSION" "$(date '+%a, %d %b %Y %H:%M:%S %z')" "$$" \
            >>"$ERROR_LOG_FILE" 2>/dev/null
    fi
}

###############################################################################
# 4. Configuration: file (data, not code) < environment < command line
###############################################################################

CONFIG_REQUESTED=''
CONFIG_GLOBAL='/etc/wp-cli-update.conf'
CONFIG_LOCAL="${SCRIPT_DIR}/wp-cli-update.conf"
declare -A CONF=()
declare -A CONF_SRC=()
CONFIG_FILE_USED=''

# Characters that would make a value executable if the file were ever sourced.
# The file is parsed, never sourced; rejecting them is defence in depth and it
# costs nothing, because a legitimate setting never needs a semicolon.
config_line_is_unsafe() {
    local line="$1"
    # shellcheck disable=SC2016  # the patterns are literal on purpose
    case "$line" in
        *"$BACKTICK"* | *'$('* | *'|'* | *';'* | *'>'* | *'<'* | *'&'*) return 0 ;;
        *) return 1 ;;
    esac
}

config_key_is_known() {
    local key="$1" k
    for k in "${CONFIG_KEYS[@]}"; do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

# A config file that a second account can write is code execution waiting to
# happen, and this tool runs as root. Checking only the other-write bit is not
# enough: a group-writable file (0620, 0660) is just as dangerous when the group
# is wider than the operator expected. Reject group-write and other-write
# together, exactly like the executable search path is checked.
config_perm_is_unsafe() { # FILE -> 0 = unsafe
    local mode
    mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 1   # no stat: cannot judge, do not block
    [ -n "$mode" ] || return 1
    # shellcheck disable=SC2086  # the leading 0 is the point: octal mask
    (( 8#$mode & 8#022 )) && return 0
    return 1
}

config_store() { # KEY VALUE SOURCE
    local key="$1" value="$2" src="$3"
    CONF["$key"]="$value"
    CONF_SRC["$key"]="$src"
}

config_parse_file() { # FILE LABEL
    local file="$1" label="$2" line no=0 key value alias newkey
    [ -f "$file" ] || return 0
    [ -r "$file" ] || config_error "${file}: not readable"
    if config_perm_is_unsafe "$file"; then
        config_error "${file}: group- or world-writable; chmod 600 or 640 it first (a writable config would be executable code with root privileges)"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        no=$((no + 1))
        line="${line%$'\r'}"                       # tolerate a CRLF checkout
        case "$line" in '' | '#'*) continue ;; esac
        if config_line_is_unsafe "$line"; then
            config_error "${file}:${no}: shell metacharacter in a config line; refusing to read this file (use plain KEY=VALUE)"
        fi
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            log_warn "${file}:${no}: not a KEY=VALUE line, ignored"
            continue
        fi
        key="${line%%=*}"
        key="${key//[[:space:]]/}"
        value="${BASH_REMATCH[1]}"
        # Strip one matching pair of quotes; nothing else is interpreted.
        if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        fi
        if ! config_key_is_known "$key"; then
            # A 6.1-era name is accepted under its current spelling instead of
            # being dropped: an ignored WP_TIMEOUT silently means "no timeout".
            for alias in "${CONFIG_ALIASES[@]}"; do
                if [ "${alias%%=*}" = "$key" ]; then
                    newkey="${alias#*=}"
                    log_note "${file}:${no}: '${key}' is the 6.1 name for '${newkey}'; accepted, please rename it"
                    key="$newkey"
                    break
                fi
            done
            if ! config_key_is_known "$key"; then
                log_warn "${file}:${no}: unknown setting '${key}', ignored"
                continue
            fi
        fi
        config_store "$key" "$value" "$label"
        CONFIG_FILE_USED="$file"
    done <"$file"
    return 0
}

config_load() {
    local key env_name
    # 1. files: global first, then local (local wins)
    [ -n "$CONFIG_REQUESTED" ] && {
        [ -f "$CONFIG_REQUESTED" ] || config_error "${CONFIG_REQUESTED}: no such file"
        config_parse_file "$CONFIG_REQUESTED" "file:$(basename -- "$CONFIG_REQUESTED")"
    }
    if [ -z "$CONFIG_REQUESTED" ]; then
        config_parse_file "$CONFIG_GLOBAL" "file:/etc"
        config_parse_file "$CONFIG_LOCAL" "file:local"
    fi
    # 2. environment: WP_CLI_UPDATE_<KEY>, but never over a command-line value
    for key in "${CONFIG_KEYS[@]}"; do
        env_name="WP_CLI_UPDATE_${key}"
        if [ -z "${CLI_SET[$key]-}" ] && is_set "$env_name"; then
            config_store "$key" "$(env_value "$env_name")" "env"
        fi
    done
    # ...and the same for the accepted legacy names.
    local alias old new
    for alias in "${CONFIG_ALIASES[@]}"; do
        old="${alias%%=*}"
        new="${alias#*=}"
        [ -z "${CLI_SET[$new]-}" ] || continue
        [ -z "${CONF_SRC[$new]-}" ] || continue
        if is_set "WP_CLI_UPDATE_${old}"; then
            config_store "$new" "$(env_value "WP_CLI_UPDATE_${old}")" 'env'
        fi
    done
    # Astra licence: two historical names are accepted, plus a key file that is
    # resolved later (licence_resolve), because it must never be in argv.
    if [ -z "${CLI_SET[LICENCE]-}" ]; then
        if is_set 'WP_CLI_UPDATE_LICENCE'; then
            config_store 'LICENCE' "$(env_value WP_CLI_UPDATE_LICENCE)" 'env'
        elif is_set 'ASTRA_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_KEY)" 'env'
        elif is_set 'ASTRA_LICENSE_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_LICENSE_KEY)" 'env'
        fi
    fi
}


require_positive_int_conf() { # NAME VALUE
    # 10#$2: a value like 08 is valid decimal input but an octal literal in
    # (( )), which dies with "value too great for base" on stderr.
    if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 )); then
        config_error "${1} must be a positive integer (got '${2}')"
    fi
}
require_non_negative_int_conf() { # NAME VALUE
    if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        config_error "${1} must be a non-negative integer (got '${2}')"
    fi
}
require_choice_conf() { # NAME VALUE CHOICE...
    local name="$1" value="$2" c
    shift 2
    for c in "$@"; do [ "$value" = "$c" ] && return 0; done
    config_error "${name} must be one of: $* (got '${value}')"
}
require_bool_conf() { # NAME VALUE
    case "$2" in
        1 | true | TRUE | yes | on | 0 | false | FALSE | no | off | '') return 0 ;;
        *) config_error "${1} must be a boolean (got '${2}')" ;;
    esac
}

# Validate the values that came from a file or the environment before they are
# merged with command-line values; a bad file must fail with 4, not 2.
config_validate_layer() {
    local key
    for key in "${!CONF[@]}"; do
        case "$key" in
            LOG_MAX_BYTES | ERROR_OUTPUT_LINES | KILL_AFTER)
                require_positive_int_conf "$key" "${CONF[$key]}" ;;
            LOG_KEEP | TIMEOUT | MAX_SITES)
                require_non_negative_int_conf "$key" "${CONF[$key]}" ;;
            LOG_LEVEL) require_choice_conf "$key" "${CONF[$key]}" debug info warn error ;;
            COLOR) require_choice_conf "$key" "${CONF[$key]}" auto always never ;;
            ALLOW_ROOT) require_choice_conf "$key" "${CONF[$key]}" auto always never ;;
            FAIL_ON) require_choice_conf "$key" "${CONF[$key]}" any all never ;;
            TIMEOUT_SIGNAL)
                require_choice_conf "$key" "${CONF[$key]}" HUP INT QUIT TERM USR1 USR2 KILL ;;
            SKIP_PLUGINS_FOR_LISTING | AUTO_DISCOVER | ONLY_ACTIVE | STRICT | NO_USER_SWITCH)
                require_bool_conf "$key" "${CONF[$key]}" ;;
            BACKUP) require_choice_conf "$key" "${CONF[$key]}" off db full ;;
            JOBS) require_positive_int_conf "$key" "${CONF[$key]}" ;;
            KEEP_BACKUPS) require_non_negative_int_conf "$key" "${CONF[$key]}" ;;
            RETRY | RETRY_DELAY | MAX_FAILURES | RUN_TIMEOUT | LOCK_WAIT | \
                BACKUP_AGE_DAYS | NOTIFY_TIMEOUT | MIN_FREE_MB | NICE_LEVEL)
                require_non_negative_int_conf "$key" "${CONF[$key]}" ;;
            IONICE_CLASS) require_choice_conf "$key" "${CONF[$key]}" idle best-effort none ;;
            NOTIFY_ON) require_choice_conf "$key" "${CONF[$key]}" never failure always ;;
            BACKUP_COMPRESS | LOG_JSON | SKIP_IF_NO_UPDATES | URL_DETECT | DRY_RUN)
                require_bool_conf "$key" "${CONF[$key]}" ;;
        esac
    done
    return 0
}

# config_apply_all: map every known key onto its variable, then validate.
config_apply_all() {
    apply_conf WP_CLI_PATH              WP_CLI_PATH
    apply_conf SITES_FILE               SITES_FILE
    apply_conf DISCOVER_SCRIPT          DISCOVER_SCRIPT
    apply_conf LOG_FILE                 LOG_FILE
    apply_conf ERROR_LOG_FILE           ERROR_LOG_FILE
    apply_conf LOCK_FILE                LOCK_FILE
    apply_conf LOG_MAX_BYTES            LOG_MAX_BYTES
    apply_conf LOG_KEEP                 LOG_KEEP
    apply_conf LOG_LEVEL                LOG_LEVEL
    apply_conf ERROR_OUTPUT_LINES       ERROR_OUTPUT_LINES
    apply_conf COLOR_MODE               COLOR
    apply_conf SKIP_PLUGINS             SKIP_PLUGINS
    apply_conf SKIP_PLUGINS_FOR_LISTING SKIP_PLUGINS_FOR_LISTING
    apply_conf ALLOW_ROOT_FLAG          ALLOW_ROOT
    apply_conf WP_COMMAND_TIMEOUT       TIMEOUT
    apply_conf KILL_AFTER               KILL_AFTER
    apply_conf TIMEOUT_SIGNAL           TIMEOUT_SIGNAL
    apply_conf FAIL_ON                  FAIL_ON
    apply_conf ASTRA_SLUG               ASTRA_SLUG
    apply_conf MAX_SITES                MAX_SITES
    apply_conf AUTO_DISCOVER            AUTO_DISCOVER
    apply_conf USER_ENV_LIST            USER_ENV
    apply_conf LICENCE_VALUE            LICENCE
    apply_conf JOBS                     JOBS
    apply_conf BACKUP_MODE              BACKUP
    apply_conf KEEP_BACKUPS             KEEP_BACKUPS
    apply_conf BACKUP_DIR               BACKUP_DIR
    apply_conf EXCLUDE_PLUGINS          EXCLUDE_PLUGINS
    apply_conf ONLY_ACTIVE              ONLY_ACTIVE
    apply_conf STRICT                   STRICT
    apply_conf NO_USER_SWITCH           NO_USER_SWITCH
    apply_conf SITE_URL                 URL
    apply_conf EXCLUDE_THEMES           EXCLUDE_THEMES
    apply_conf HOLD_PLUGINS             HOLD_PLUGINS
    apply_conf HOLD_THEMES              HOLD_THEMES
    apply_conf NICE_LEVEL               NICE_LEVEL
    apply_conf IONICE_CLASS             IONICE_CLASS
    apply_conf MIN_FREE_MB              MIN_FREE_MB
    apply_conf RETRY                    RETRY
    apply_conf RETRY_DELAY              RETRY_DELAY
    apply_conf MAX_FAILURES             MAX_FAILURES
    apply_conf RUN_TIMEOUT              RUN_TIMEOUT
    apply_conf LOCK_WAIT                LOCK_WAIT
    apply_conf BACKUP_AGE_DAYS          BACKUP_AGE_DAYS
    apply_conf BACKUP_COMPRESS          BACKUP_COMPRESS
    apply_conf DEFAULT_USER             DEFAULT_USER
    apply_conf NOTIFY_WEBHOOK           NOTIFY_WEBHOOK
    apply_conf NOTIFY_ON                NOTIFY_ON
    apply_conf NOTIFY_TIMEOUT           NOTIFY_TIMEOUT
    apply_conf MAIL_TO                  MAIL_TO
    apply_conf REPORT_FILE              REPORT_FILE
    apply_conf LOG_JSON                 LOG_JSON
    apply_conf DRY_RUN                  DRY_RUN
    apply_conf SKIP_IF_NO_UPDATES       SKIP_IF_NO_UPDATES
    apply_conf URL_DETECT               URL_DETECT
    apply_conf WP_GLOBAL_ARGS           WP_GLOBAL_ARGS

    require_positive_int      LOG_MAX_BYTES            "$LOG_MAX_BYTES"
    require_non_negative_int  LOG_KEEP                 "$LOG_KEEP"
    require_positive_int      ERROR_OUTPUT_LINES       "$ERROR_OUTPUT_LINES"
    require_non_negative_int  WP_COMMAND_TIMEOUT       "$WP_COMMAND_TIMEOUT"
    require_positive_int      KILL_AFTER               "$KILL_AFTER"
    require_non_negative_int  MAX_SITES                "$MAX_SITES"
    require_choice            LOG_LEVEL                "$LOG_LEVEL" debug info warn error
    require_choice            COLOR                    "$COLOR_MODE" auto always never
    require_choice            ALLOW_ROOT               "$ALLOW_ROOT_FLAG" auto always never
    require_choice            FAIL_ON                  "$FAIL_ON" any all never
    require_choice            TIMEOUT_SIGNAL           "$TIMEOUT_SIGNAL" HUP INT QUIT TERM USR1 USR2 KILL
    SKIP_PLUGINS_FOR_LISTING="$(require_bool SKIP_PLUGINS_FOR_LISTING "$SKIP_PLUGINS_FOR_LISTING")"
    AUTO_DISCOVER="$(require_bool AUTO_DISCOVER "$AUTO_DISCOVER")"
    ONLY_ACTIVE="$(require_bool ONLY_ACTIVE "$ONLY_ACTIVE")"
    STRICT="$(require_bool STRICT "$STRICT")"
    NO_USER_SWITCH="$(require_bool NO_USER_SWITCH "$NO_USER_SWITCH")"
    require_choice BACKUP_MODE "$BACKUP_MODE" off db full
    require_positive_int JOBS "$JOBS"
    require_non_negative_int KEEP_BACKUPS "$KEEP_BACKUPS"
    require_non_negative_int MIN_FREE_MB "$MIN_FREE_MB"
    require_non_negative_int RETRY "$RETRY"
    require_non_negative_int RETRY_DELAY "$RETRY_DELAY"
    require_non_negative_int MAX_FAILURES "$MAX_FAILURES"
    require_non_negative_int RUN_TIMEOUT "$RUN_TIMEOUT"
    require_non_negative_int LOCK_WAIT "$LOCK_WAIT"
    require_non_negative_int BACKUP_AGE_DAYS "$BACKUP_AGE_DAYS"
    require_non_negative_int NOTIFY_TIMEOUT "$NOTIFY_TIMEOUT"
    require_non_negative_int NICE_LEVEL "$NICE_LEVEL"
    ((NICE_LEVEL <= 19)) || usage_error "--nice must be between 0 and 19 (got '${NICE_LEVEL}')"
    require_choice IONICE_CLASS "$IONICE_CLASS" idle best-effort none
    require_choice NOTIFY_ON "$NOTIFY_ON" never failure always
    BACKUP_COMPRESS="$(require_bool BACKUP_COMPRESS "$BACKUP_COMPRESS")"
    LOG_JSON="$(require_bool LOG_JSON "$LOG_JSON")"
    DRY_RUN="$(require_bool DRY_RUN "$DRY_RUN")"
    SKIP_IF_NO_UPDATES="$(require_bool SKIP_IF_NO_UPDATES "$SKIP_IF_NO_UPDATES")"
    URL_DETECT="$(require_bool URL_DETECT "$URL_DETECT")"

    # Values have passed validation, so they are pure digits -- but they may
    # carry leading zeros ('08', '007'). Every later use is arithmetic, and
    # bash reads a leading zero as octal there ("value too great for base" on
    # 08 and 09). Normalise once, here, so no arithmetic site has to care.
    LOG_MAX_BYTES="$(norm_uint "$LOG_MAX_BYTES")"
    LOG_KEEP="$(norm_uint "$LOG_KEEP")"
    ERROR_OUTPUT_LINES="$(norm_uint "$ERROR_OUTPUT_LINES")"
    WP_COMMAND_TIMEOUT="$(norm_uint "$WP_COMMAND_TIMEOUT")"
    KILL_AFTER="$(norm_uint "$KILL_AFTER")"
    MAX_SITES="$(norm_uint "$MAX_SITES")"
    JOBS="$(norm_uint "$JOBS")"
    KEEP_BACKUPS="$(norm_uint "$KEEP_BACKUPS")"
    MIN_FREE_MB="$(norm_uint "$MIN_FREE_MB")"
    RETRY="$(norm_uint "$RETRY")"
    RETRY_DELAY="$(norm_uint "$RETRY_DELAY")"
    MAX_FAILURES="$(norm_uint "$MAX_FAILURES")"
    RUN_TIMEOUT="$(norm_uint "$RUN_TIMEOUT")"
    LOCK_WAIT="$(norm_uint "$LOCK_WAIT")"
    BACKUP_AGE_DAYS="$(norm_uint "$BACKUP_AGE_DAYS")"
    NOTIFY_TIMEOUT="$(norm_uint "$NOTIFY_TIMEOUT")"
    NICE_LEVEL="$(norm_uint "$NICE_LEVEL")"
}

# human-readable elapsed time for the summary: 7s, 1m 12s, 2h 03m
human_duration() { # SECONDS
    local s="${1:-0}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    if ((s < 60)); then printf '%ss' "$s"
    elif ((s < 3600)); then printf '%dm %02ds' "$((s / 60))" "$((s % 60))"
    else printf '%dh %02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
    fi
}

# '08' -> 8. Input must already be validated as ^[0-9]+$ by require_*; the
# 10# prefix forces decimal regardless of the leading zero.
norm_uint() {
    printf '%d' "$((10#${1:-0}))"
}


# Adopt a setting from the config layer unless the command line already fixed
# it. CLI wins over environment, environment wins over file, file wins over the
# built-in default -- the precedence is documented in wp-cli-update.conf.example.
declare -A CLI_SET=()

apply_conf() { # VAR_NAME KEY
    local __var="$1" __key="$2"
    [ -z "${CLI_SET[$__key]-}" ] || return 0
    [ -n "${CONF_SRC[$__key]-}" ] || return 0
    printf -v "$__var" '%s' "${CONF[$__key]}"
}

# Validation helpers. The same rules are applied to values from the config file
# and to values from the command line, and the exit code has to differ: a bad
# setting in a file is a configuration error (4), a bad flag is a usage error
# (2). config_apply_all therefore re-checks the file-sourced values with the
# *_conf variants below after apply_conf has merged everything.
require_positive_int() { # NAME VALUE
    # 10#$2: '08' is fine as decimal input but an octal literal inside (( ))
    # ("value too great for base"). Values here are strings until applied.
    if ! [[ "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < 1 )); then
        usage_error "${1} must be a positive integer (got '${2}')"
    fi
}
require_non_negative_int() { # NAME VALUE
    [[ "$2" =~ ^[0-9]+$ ]] ||
        usage_error "${1} must be a non-negative integer (got '${2}')"
}
require_choice() { # NAME VALUE CHOICE...
    local name="$1" value="$2" c
    shift 2
    for c in "$@"; do [ "$value" = "$c" ] && return 0; done
    usage_error "${name} must be one of: $* (got '${value}')"
}
require_bool() { # NAME VALUE
    case "$2" in
        1 | true | TRUE | yes | on) printf 'true' ;;
        0 | false | FALSE | no | off | '') printf 'false' ;;
        *) usage_error "${1} must be a boolean (got '${2}')" ;;
    esac
}

###############################################################################
# 5. Runtime state
###############################################################################

MODE=''
TARGET_SITE=''
SITE_URL=''
PLUGIN_NAME=''
PLUGIN_ACTION=''
FORCE_DELETE='false'
ASSUME_YES='false'
DRY_RUN='false'
NO_ACTION='false'
LIST_MODES='false'
JSON_LINES='false'
SHOW_STATUS='false'
OUTPUT_FORMAT="$DEFAULT_OUTPUT_FORMAT"
PAGE_LIMIT=0
SKIP_PLUGINS=''
SKIP_PLUGINS_FOR_LISTING='false'
ALLOW_ROOT_FLAG="$DEFAULT_ALLOW_ROOT"
WP_CLI_PATH="$DEFAULT_WP_CLI_PATH"
SITES_FILE="$DEFAULT_SITES_FILE"
DISCOVER_SCRIPT="$DEFAULT_DISCOVER_SCRIPT"
LOCK_FILE="$DEFAULT_LOCK_FILE"
WP_COMMAND_TIMEOUT="$DEFAULT_TIMEOUT"
KILL_AFTER="$DEFAULT_KILL_AFTER"
TIMEOUT_SIGNAL="$DEFAULT_TIMEOUT_SIGNAL"
FAIL_ON="$DEFAULT_FAIL_ON"
ASTRA_SLUG="$DEFAULT_ASTRA_SLUG"
MAX_SITES="$DEFAULT_MAX_SITES"
JOBS="$DEFAULT_JOBS"
BACKUP_MODE="$DEFAULT_BACKUP"
KEEP_BACKUPS="$DEFAULT_KEEP_BACKUPS"
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
EXCLUDE_PLUGINS=''
ONLY_ACTIVE='false'
STRICT='false'
NO_USER_SWITCH='false'
STATS_WARNINGS=0
AUTO_DISCOVER='true'
USER_ENV_LIST=''
LICENCE_VALUE=''
LICENCE_FILE=''
FILTER_NAME=''
FILTER_FIELDS=''

SITES=()
declare -A SITE_USER=()

STATS_SITES_TOTAL=0
STATS_SITES_OK=0
STATS_SITES_FAILED=0
STATS_SITES_SKIPPED=0
STATS_OPS_OK=0
STATS_OPS_FAILED=0
VERIFY_FINDINGS=0
LOCK_FD=''
LOCK_HELD='false'
TMP_FILES=()
WARNED_NO_FLOCK='false'
START_TIME=0
ABORT='false'                 # set by --max-failures, --run-timeout or a signal
EXCLUDE_THEMES=''
HOLD_PLUGINS=''
HOLD_THEMES=''
NICE_LEVEL="$DEFAULT_NICE_LEVEL"
IONICE_CLASS="$DEFAULT_IONICE_CLASS"
MIN_FREE_MB="$DEFAULT_MIN_FREE_MB"
RETRY="$DEFAULT_RETRY"
RETRY_DELAY="$DEFAULT_RETRY_DELAY"
MAX_FAILURES="$DEFAULT_MAX_FAILURES"
RUN_TIMEOUT="$DEFAULT_RUN_TIMEOUT"
LOCK_WAIT="$DEFAULT_LOCK_WAIT"
BACKUP_AGE_DAYS="$DEFAULT_BACKUP_AGE_DAYS"
BACKUP_COMPRESS="$DEFAULT_BACKUP_COMPRESS"
DEFAULT_USER=''
NOTIFY_WEBHOOK=''
NOTIFY_ON="$DEFAULT_NOTIFY_ON"
NOTIFY_TIMEOUT="$DEFAULT_NOTIFY_TIMEOUT"
MAIL_TO=''
REPORT_FILE=''
LOG_JSON="$DEFAULT_LOG_JSON"
SKIP_IF_NO_UPDATES="$DEFAULT_SKIP_IF_NO_UPDATES"
URL_DETECT="$DEFAULT_URL_DETECT"
WP_GLOBAL_ARGS=''
RESTORE_SOURCE=''             # --restore-db FILE
COMPLETION_SHELL=''
TRACK_CHANGES='false'         # --report or --json-lines asked for the change log
STATS_RETRIES=0
STATS_CHANGES=0
CHANGES_FILE=''
declare -A SITE_URL_CACHE=()

###############################################################################
# 6. Locking, traps, temporary files
###############################################################################

# A maintenance run that overlaps itself corrupts databases far more reliably
# than any plugin does. flock when we have it, a pid file when we do not, and a
# clear refusal in both cases.
lock_acquire() {
    local dir other
    dir="$(dirname -- "$LOCK_FILE")"
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        LOCK_FILE="${TMPDIR:-/tmp}/${PROG_NAME}.$(id -u).lock"
        log_debug "lock directory not writable; falling back to ${LOCK_FILE}"
    fi
    if have flock; then
        # The braces matter. `exec {FD}>>file 2>/dev/null` would attach the
        # redirection to exec permanently and silence stderr for the rest of
        # the run; the group redirects only this attempt.
        if ! { exec {LOCK_FD}>>"$LOCK_FILE"; } 2>/dev/null; then
            log_warn "cannot open lock file ${LOCK_FILE}; concurrent runs are not prevented"
            LOCK_FD=''
            return 0
        fi
        # --lock-wait waits for a concurrent run instead of failing at once; the
        # default (0) keeps the old behaviour, because two runs that overlap on a
        # fleet are usually a mistake, not a queue.
        if ((LOCK_WAIT > 0)); then
            log_debug "waiting up to ${LOCK_WAIT}s for the lock"
        fi
        if ! flock -w "$LOCK_WAIT" "$LOCK_FD"; then
            exec {LOCK_FD}>&-
            LOCK_FD=''
            other="$(head -n 1 "$LOCK_FILE" 2>/dev/null)"
            log_error "another ${PROG_NAME} run holds ${LOCK_FILE}${other:+ (pid ${other})}; refusing to run concurrently"
            exit "$EXIT_ENV"
        fi
    else
        if [ -s "$LOCK_FILE" ]; then
            other="$(head -n 1 "$LOCK_FILE" 2>/dev/null)"
            if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
                log_error "another ${PROG_NAME} run holds ${LOCK_FILE} (pid ${other}); refusing to run concurrently"
                exit "$EXIT_ENV"
            fi
            [ -n "$other" ] && [ "$other" != "$$" ] &&
                log_warn "removing a stale lock left by pid ${other}"
        fi
        if have flock; then :; else
            [ "$WARNED_NO_FLOCK" = 'true' ] || {
                log_note 'flock(1) not found; using a pid file, which does not protect against a crash mid-run'
                WARNED_NO_FLOCK='true'
            }
        fi
    fi
    : >"$LOCK_FILE" 2>/dev/null
    printf '%s\n' "$$" >"$LOCK_FILE" 2>/dev/null
    LOCK_HELD='true'
    log_debug "lock acquired: ${LOCK_FILE}"
    return 0
}

# shellcheck disable=SC2329  # invoked from tmp_cleanup only
lock_release() {
    if [ -n "$LOCK_FD" ]; then
        exec {LOCK_FD}>&- 2>/dev/null
        LOCK_FD=''
    fi
    if [ "$LOCK_HELD" = 'true' ]; then
        rm -f -- "$LOCK_FILE" 2>/dev/null
        LOCK_HELD='false'
    fi
    return 0
}

tmp_register() { TMP_FILES+=("$1"); }

# shellcheck disable=SC2329  # invoked from the EXIT trap only
tmp_cleanup() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
        [ -e "$f" ] && rm -rf -- "$f" 2>/dev/null
    done
    TMP_FILES=()
    [ -n "$LICENCE_FILE" ] && rm -f -- "$LICENCE_FILE" 2>/dev/null
    LICENCE_FILE=''
    lock_release
}

# The summary is printed even on interrupt: a half-finished fleet run has to
# tell the operator how far it got.
# shellcheck disable=SC2329  # registered as the EXIT trap
on_exit() {
    local rc=$?
    # The summary (and the JSON report it writes) has to run *before* the
    # temporary files are removed: the change log is one of them.
    if [ "$SUMMARY_PRINTED" = 'false' ] && [ "$START_TIME" -gt 0 ] &&
       [ "$NO_ACTION" != 'true' ] && [ "$LIST_MODES" != 'true' ]; then
        printf '\n' >&2
        log_warn "interrupted or aborted (exit ${rc}); partial summary follows"
        print_summary "$rc"
    fi
    tmp_cleanup
    # Re-assert the original status: an `exit` inside a trap replaces the exit
    # status the script was already carrying, which once turned a usage error (2)
    # into an environment error (3) on its way out.
    exit "$rc"
}
SUMMARY_PRINTED='false'

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 131' HUP

###############################################################################
# 7. Licence handoff: the value never becomes an argument of this process
###############################################################################


needs_licence_handoff() {
    local a
    for a in "$@"; do [ "$a" = "$LICENCE_MARKER" ] && return 0; done
    return 1
}

# The handoff file must be readable by the site owner, because the command
# substitution that reads it runs *after* the user switch. mktemp gives an
# unpredictable name inside a sticky directory, and the file is unlinked as soon
# as the call returns, so the exposure window is one WP-CLI invocation.
#
# The window is narrowed as far as the mechanics allow: the file is chgrp'ed to
# the site owner's primary group and given 0640, so during that one invocation
# only root, the site owner and that group can read it. 0644 remains the last
# resort when the chgrp fails. The alternatives are all worse: plain 0600 does
# not work at all (the child gets "Permission denied" and the licence arrives
# empty); `runuser -m` has no equivalent under sudo/su; and putting the value in
# argv is precisely what this design refuses to do. If your threat model
# includes other local users reading /tmp during a run, feed
# WP_CLI_UPDATE_LICENCE per invocation from a secrets manager rather than
# keeping a key file on disk.

licence_open() { # USER
    local user="${1:-}"
    [ -n "$LICENCE_VALUE" ] || return 0
    [ -n "$LICENCE_FILE" ] && return 0
    LICENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.licence.XXXXXX")" || {
        log_error 'cannot create a temporary file for the licence handoff'
        return 1
    }
    tmp_register "$LICENCE_FILE"
    # Write first, relax the mode second: the value is never present in a file
    # that is already group- or world-readable.
    if ! printf '%s' "$LICENCE_VALUE" >"$LICENCE_FILE"; then
        log_error "cannot write the licence handoff file ${LICENCE_FILE}"
        LICENCE_FILE=''
        return 1
    fi
    if [ -n "$user" ] && [ "$(id -u)" = '0' ]; then
        # Group-restricted handoff: root and the site user's own group only.
        if chgrp -- "$(id -gn -- "$user" 2>/dev/null)" "$LICENCE_FILE" 2>/dev/null &&
            chmod 640 "$LICENCE_FILE" 2>/dev/null; then
            log_debug "licence handoff is group-restricted to $(id -gn -- "$user" 2>/dev/null)"
            redact_register "$LICENCE_VALUE"
            return 0
        fi
        log_debug 'could not restrict the licence handoff to the site group; falling back to 0644'
    fi
    if ! chmod 644 "$LICENCE_FILE" 2>/dev/null; then
        log_warn "cannot relax the mode of ${LICENCE_FILE}; the site owner may not be able to read it"
    fi
    redact_register "$LICENCE_VALUE"
    return 0
}

licence_close() {
    [ -n "$LICENCE_FILE" ] || return 0
    rm -f -- "$LICENCE_FILE" 2>/dev/null
    LICENCE_FILE=''
}

###############################################################################
# 8. User switching
###############################################################################

# POSIX-safe single quoting. `printf %q` is *not* used here on purpose: it emits
# bash syntax, and the string below is parsed by /bin/sh, which on Debian is
# dash. `\&\&` is a literal there, so a %q-built command silently degrades into
# `cd: too many arguments`. This quoting is understood by every POSIX shell.
sh_quote() {
    local s="${1-}"
    if [ -z "$s" ]; then printf "''"; return 0; fi
    case "$s" in
        *[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "${s//\'/\'\\\'\'}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# argv_display: render an argv array the way a human would type it. Used for
# dry-run output and debug lines only -- never to execute anything.
argv_display() {
    local out='' a
    for a in "$@"; do out+="$(sh_quote "$a") "; done
    printf '%s' "${out% }"
}

# run_as_user WORKDIR USER PROGRAM [ARGS...]
#
# The command is handed to the target shell as *positional parameters*, so no
# quoting is needed at all: a site path may contain spaces, quotes, dollars or
# semicolons and still arrives as one argument. This is the single most
# important function in the file -- do not "simplify" it into a string.
# shellcheck disable=SC2016  # single quotes are the point: this is a snippet
RUNNER_SNIPPET='cd -- "$1" || exit 127; shift; exec "$@"'

run_as_user() { # WORKDIR USER PROGRAM [ARGS...]
    local workdir="$1" user="$2"
    shift 2
    # --no-user-switch runs everything as the invoking user. It exists for two
    # reasons: single-site hosts where the operator already IS the site user, and
    # test suites. The second reason matters more than it looks -- three
    # independent suites in this project's history (GLM's, SagaAI's and the first
    # revision of ours) reported dozens of failures that were purely "the fixture
    # is owned by root and there is no account to switch into". A switch that can
    # be turned off makes a suite portable instead of environment-coupled.
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@"
        return $?
    fi
    if [ "$user" = "$(id -un)" ]; then
        /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@"
        return $?
    fi
    if [ "$(id -u)" -eq 0 ] && have runuser; then
        runuser -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@"
        return $?
    fi
    if [ "$(id -u)" -eq 0 ] && have sudo; then
        sudo -n -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@"
        return $?
    fi
    # su passes everything after the user name to the shell as positional
    # parameters, so even this fallback needs no escaping.
    su -s /bin/sh -c "$RUNNER_SNIPPET" "$user" sh "$workdir" "$@"
    return $?
}

###############################################################################
# 9. WP-CLI resolution and environment for the child
###############################################################################

wp_resolve() {
    local candidate
    # An operator who configured a path means that path. Falling back to
    # whatever `wp` happens to be in PATH would run a different WP-CLI than the
    # one that was asked for, against a fleet, without saying so.
    if [ -n "${CLI_SET[WP_CLI_PATH]-}" ] || [ -n "${CONF_SRC[WP_CLI_PATH]-}" ]; then
        if [ -x "$WP_CLI_PATH" ]; then
            printf '%s' "$WP_CLI_PATH"
            return 0
        fi
        log_error "configured wp-cli is not an executable file: ${WP_CLI_PATH}"
        return 1
    fi
    if [ -n "$WP_CLI_PATH" ] && [ -x "$WP_CLI_PATH" ]; then
        printf '%s' "$WP_CLI_PATH"
        return 0
    fi
    for candidate in wp /usr/local/bin/wp /usr/bin/wp; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

WP_RESOLVED=''

wp_ensure() {
    if [ -n "$WP_RESOLVED" ]; then return 0; fi
    WP_RESOLVED="$(wp_resolve)" || {
        log_error "WP-CLI not found (looked for '${WP_CLI_PATH}', wp in PATH, /usr/local/bin/wp, /usr/bin/wp)"
        log_error "install it from https://wp-cli.org/ or set WP_CLI_PATH"
        return 1
    }
    log_debug "wp-cli resolved to ${WP_RESOLVED}"
    return 0
}

# Environment the child process gets. WP-CLI and a few plugins read these, and
# the legacy contract of this project exported them, so they stay. They are
# emitted as argv elements for env(1), never as a shell string, which is why a
# site path containing a quote cannot break anything here.
#
# The array is delivered through the global SITE_ENVV, not through stdout: a
# line-per-element protocol breaks the moment a value contains a newline (a
# site path or a --user-env value), and env(1) would receive the halves as
# separate arguments.
SITE_ENVV=()

site_env_argv() { # SITE USER -> fills the global SITE_ENVV array
    local site="$1" user="$2" domain parent home
    domain="$(basename -- "$site")"
    parent="$(dirname -- "$(dirname -- "$site")")"
    home=''
    if [ -n "$user" ] && have getent; then
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$home" ] || [ ! -d "$home" ]; then home="$parent"; fi
    SITE_ENVV=(
        "DOCUMENT_URI=${domain}"
        "DOCUMENT_ROOT=${site}"
        "HOMEDIR=${parent}"
        "HTTP_HOST=${domain}"
        "HOME=${home}"
        "USER=${user}"
        "LOGNAME=${user}"
    )
    # Operator-selected pass-through, e.g. a proxy or an API endpoint. read -ra
    # splits on IFS without glob expansion; a plain `for v in $USER_ENV_LIST`
    # would happily expand a '*' into the current directory.
    local v line
    local -a names=()
    [ -n "$USER_ENV_LIST" ] && { IFS=' ' read -ra names <<<"$USER_ENV_LIST"; }
    for v in ${names[@]+"${names[@]}"}; do
        if is_set "$v"; then
            line="${v}=$(env_value "$v")"
            SITE_ENVV+=("$line")
        fi
    done
    return 0
}

# --allow-root policy. `auto` means: pass it only when we are root, which is the
# only situation where WP-CLI would otherwise refuse to run.
allow_root_flag() {
    case "$ALLOW_ROOT_FLAG" in
        always) printf '%s' '--allow-root' ;;
        never) return 0 ;;
        auto) [ "$(id -u)" -eq 0 ] && printf '%s' '--allow-root' ;;
    esac
    return 0
}

###############################################################################
# 9b. Site metadata: URL and multisite
###############################################################################

# WP_HOME / WP_SITEURL out of wp-config.php. Both spellings of the call occur in
# the wild (`define( 'WP_HOME', '...' )` and `define("WP_HOME","...")`), so the
# pattern accepts any spacing and both quote characters. Nothing is sourced: the
# file belongs to a website, not to this tool.
site_url_detect() { # SITE
    local site="$1" cfg value=''
    cfg="${site}/wp-config.php"
    [ -f "$cfg" ] || return 0
    value="$(grep -E "^[[:space:]]*define[[:space:]]*\\([[:space:]]*['\"](WP_HOME|WP_SITEURL)['\"]" -- "$cfg" 2>/dev/null |
        sed -E "s/.*['\"](WP_HOME|WP_SITEURL)['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\\2/" |
        head -n 1 || true)"
    printf '%s' "$value"
}

site_is_multisite() { # SITE
    local cfg="${1}/wp-config.php"
    [ -f "$cfg" ] || return 1
    grep -qE "^[[:space:]]*define[[:space:]]*\\([[:space:]]*['\"]MULTISITE['\"][[:space:]]*,[[:space:]]*true" -- "$cfg" 2>/dev/null
}

# site_url_effective SITE -> the --url value for this site, or nothing.
# The command line always wins; otherwise wp-config.php is read when URL_DETECT
# is on. This is the difference between "--full failed on the multisite" and
# "--full just worked": without a URL, WP-CLI refuses to pick a site.
site_url_effective() { # SITE
    local site="$1" url=''
    [ -n "$SITE_URL" ] && { printf '%s' "$SITE_URL"; return 0; }
    [ "$URL_DETECT" = 'true' ] || return 0
    if [ -n "${SITE_URL_CACHE[$site]+set}" ]; then
        printf '%s' "${SITE_URL_CACHE[$site]}"
        return 0
    fi
    url="$(site_url_detect "$site")"
    SITE_URL_CACHE["$site"]="$url"
    if [ -z "$url" ] && site_is_multisite "$site"; then
        log_note "${site} is a multisite and wp-config.php names no WP_HOME; pass --url to target one site"
    fi
    printf '%s' "$url"
}

# Priority prefix: a fleet update must not outrun the web server it shares a
# disk with. nice(1) is everywhere; ionice(1) is not, and on a kernel without
# CFQ it fails without effect -- which is fine, we do not depend on it.
PRIORITY_PRE=()
priority_argv() {
    PRIORITY_PRE=()
    if ((NICE_LEVEL > 0)) && have nice; then
        PRIORITY_PRE=(nice -n "$NICE_LEVEL")
    fi
    case "$IONICE_CLASS" in
        idle) have ionice && PRIORITY_PRE+=(ionice -c 3) ;;
        best-effort) have ionice && PRIORITY_PRE+=(ionice -c 2 -n 6) ;;
        *) ;;
    esac
    return 0
}

###############################################################################
# 10. WP-CLI invocation
###############################################################################

WP_OUTPUT=''
WP_STATUS=0
WP_SKIPPED='false'

# child_argv LICENCE_VAR PROGRAM [ARGS...]
#
# Normally this is the argv unchanged. When an argument equals the licence
# marker, the whole command is wrapped in `sh -c 'exec env VAR="$(cat -- PATH)"
# PROG ...' sh`: the value is read *at run time* from the handoff file and
# handed to wp as an environment variable. Consequences:
#   - the licence is never an argument of any process, so `ps` cannot show it;
#   - it never appears in a log line, a dry-run listing or an error box;
#   - the value is read by the child shell at run time and reaches wp as an
#     environment variable of that process only.
child_argv() {
    local var="$1"; shift
    local prog="$1"; shift
    local a cmd=''
    local -a found=()
    for a in "$prog" "$@"; do
        if [ "$a" = "$LICENCE_MARKER" ]; then
            found+=("$a")
            cmd+="${cmd:+ }"\$${var}""
        else
            cmd+="${cmd:+ }$(sh_quote "$a")"
        fi
    done
    if ((${#found[@]} == 0)); then
        printf '%s\n' "$prog" "$@"
        return 0
    fi
    if ((${#found[@]} > 1)); then
        log_error 'internal: the licence marker appears more than once in one command'
        return 1
    fi
    [ -n "$LICENCE_FILE" ] || { log_error 'internal: licence handoff file is not open'; return 1; }
    local wrapper
    wrapper="exec env ${var}=\"\$(cat -- $(sh_quote "$LICENCE_FILE"))\" ${cmd}"
    printf '%s\n' '/bin/sh' '-c' "$wrapper" 'sh'
}

# timeout is optional. Without it the run still works, it just cannot bound a
# hung wp process; say so once instead of failing silently.
#
# The prefix is emitted as argv *inside* the command that run_as_user executes,
# so it is switched-user too and needs no re-quoting: `exec "$@"` carries it
# verbatim. Wrapping run_as_user in another shell would have required quoting a
# command line twice, which is exactly the bug class this project keeps hitting.
TIMEOUT_SUPPORTED=''

# The prefix is emitted as argv *inside* the command that run_as_user executes,
# so it is switched-user too and needs no re-quoting: `exec "$@"` carries it
# verbatim. Wrapping run_as_user in another shell would have required quoting a
# command line twice, which is exactly the bug class this project keeps hitting.
TIMEOUT_SUPPORTED=''
TIMEOUT_PRE=()

# Portable supervisor (used when timeout(1) is absent but perl exists): fork,
# the child gets its own process group and execs the command, the parent arms
# the alarm -- WP_SIGNAL after WP_COMMAND_TIMEOUT seconds, SIGKILL after
# KILL_AFTER more -- and retries waitpid through EINTR until the child is
# really reaped, so no orphan is left holding the command-substitution pipe.
# The whole supervisor travels as ONE argv element and needs no shell quoting:
# run_as_user passes it to /bin/sh as a positional parameter.
# shellcheck disable=SC2016  # the Perl program is literal: $ must reach perl, not bash
TIMEOUT_SUPERVISOR_CODE='
my ($limit, $sig, $grace, @cmd) = @ARGV;
my $pid = fork();
die "fork failed\n" unless defined $pid;
if ($pid == 0) { setpgrp(0, 0); exec @cmd; exit 127; }
my $state = 0;
$SIG{ALRM} = sub {
    if ($state == 0) { $state = 1; kill "-$sig", $pid; kill $sig, $pid; alarm $grace; }
    else { kill "-KILL", $pid; kill "KILL", $pid; $state = 2; }
};
alarm $limit;
my $st = 0;
while (1) {
    my $got = waitpid($pid, 0);
    if ($got == $pid) { $st = $? >> 8; last; }
    if ($got == -1) {
        next if $! == 4;
        last if $! == 10;
        last;
    }
}
exit 124 if $state >= 1 && $st == 0;
exit($st);
'

timeout_argv() { # -> fills the global TIMEOUT_PRE array (zero or more elements)
    TIMEOUT_PRE=()
    ((WP_COMMAND_TIMEOUT > 0)) || return 0
    if have timeout; then
        if [ -z "$TIMEOUT_SUPPORTED" ]; then
            # -k is a GNU extension; probe it once instead of assuming it.
            if ((KILL_AFTER > 0)) && timeout -k 1 -s TERM 1 true >/dev/null 2>&1; then
                TIMEOUT_SUPPORTED='kill-after'
            else
                TIMEOUT_SUPPORTED='plain'
            fi
        fi
        TIMEOUT_PRE=(timeout "--signal=$TIMEOUT_SIGNAL")
        if [ "$TIMEOUT_SUPPORTED" = 'kill-after' ] && ((KILL_AFTER > 0)); then
            TIMEOUT_PRE+=(-k "$KILL_AFTER")
        fi
        TIMEOUT_PRE+=("$WP_COMMAND_TIMEOUT")
        return 0
    fi
    # No timeout(1): degrade to the perl supervisor instead of dropping the
    # bound entirely -- a hung wp must not block a fleet run that asked for a
    # timeout, with or without GNU coreutils installed.
    if [ -z "$TIMEOUT_SUPPORTED" ]; then
        if have perl && perl -e 'setpgrp(0,0); fork; waitpid -1, 0' >/dev/null 2>&1; then
            TIMEOUT_SUPPORTED='perl'
        else
            TIMEOUT_SUPPORTED='none'
        fi
        if [ "$TIMEOUT_SUPPORTED" = 'none' ]; then
            log_note 'timeout(1) and perl are not available; --timeout is ignored and a hung wp will block the run'
            return 0
        fi
    fi
    if [ "$TIMEOUT_SUPPORTED" = 'perl' ]; then
        TIMEOUT_PRE=(perl -e "$TIMEOUT_SUPERVISOR_CODE" "$WP_COMMAND_TIMEOUT" "$TIMEOUT_SIGNAL" "$KILL_AFTER")
    fi
    return 0
}

# wp_exec SITE USER WP_ARGS...
# The single place where WP-CLI is executed. Fills WP_OUTPUT / WP_STATUS and
# always returns 0, so that a failing site cannot abort a `set -e`-ish caller;
# the status is reported through the variable, and counters live in section 11.
wp_exec() { # SITE USER ARGS...
    local site="$1" user="$2"
    shift 2
    local -a argv=()
    local ar start end display

    WP_OUTPUT='' WP_STATUS=0 WP_SKIPPED='false'

    [ -d "$site" ] || { WP_STATUS=2; WP_OUTPUT="not a directory: ${site}"; return 0; }
    wp_ensure || { WP_STATUS=3; WP_OUTPUT='WP-CLI is not available'; return 0; }

    local -a pre=() envv=()
    site_env_argv "$site" "$user"
    envv=("${SITE_ENVV[@]+"${SITE_ENVV[@]}"}")
    timeout_argv
    pre=("${TIMEOUT_PRE[@]+"${TIMEOUT_PRE[@]}"}")
    priority_argv
    argv=(env "${envv[@]}")
    argv+=(${pre[@]+"${pre[@]}"})
    argv+=(${PRIORITY_PRE[@]+"${PRIORITY_PRE[@]}"})
    argv+=("$WP_RESOLVED" "--path=$site")
    local url=''
    url="$(site_url_effective "$site")"
    [ -n "$url" ] && argv+=("--url=$url")
    ar="$(allow_root_flag)"
    [ -n "$ar" ] && argv+=("$ar")
    # Operator-supplied global flags (for example --skip-themes). Split on
    # whitespace without glob expansion, exactly like --user-env.
    if [ -n "$WP_GLOBAL_ARGS" ]; then
        local -a extra=()
        IFS=' ' read -ra extra <<<"$WP_GLOBAL_ARGS"
        argv+=(${extra[@]+"${extra[@]}"})
    fi
    if [ -n "$SKIP_PLUGINS" ] && skip_plugins_applies_to "${1:-}" "${2:-}"; then
        argv+=("--skip-plugins=$SKIP_PLUGINS")
    fi
    argv+=("$@")

    if [ "$DRY_RUN" = 'true' ]; then
        display="$(argv_display "${argv[@]}")"
        # A dry run must show the *real* command, but never the licence value.
        display="${display//$LICENCE_MARKER/<licence>}"
        log_info "[dry-run] (${user}@$(basename -- "$site")) ${display}"
        WP_SKIPPED='true'
        return 0
    fi

    start="$(date +%s)"
    if [ "$VERBOSE" = 'true' ]; then
        display="$(argv_display "${argv[@]}")"
        log_debug "exec as ${user}: ${display//$LICENCE_MARKER/<licence>}"
    fi
    # stdout and stderr of wp are merged, exactly like the legacy contract:
    # WP-CLI writes progress to stderr and data to stdout, and separating them
    # reorders the story the operator needs to read.
    local -a run=()
    if needs_licence_handoff "$@"; then
        licence_open "$user" || { WP_STATUS=1; WP_OUTPUT='cannot prepare the licence handoff'; return 0; }
        local handoff_lines=''
        # child_argv reports its own failure (marker twice, handoff file not
        # open) through the exit status. Capturing with command substitution
        # keeps that status visible; `mapfile < <(child_argv ...)` would lose
        # it -- process substitution status is discarded -- and an empty array
        # would hand `exec` with no arguments to the child shell, which POSIX
        # sh treats as success: a silently skipped licence activation counted
        # as an OK operation.
        if ! handoff_lines="$(child_argv WP_CLI_LICENCE "${argv[@]}")" ||
            [ -z "$handoff_lines" ]; then
            licence_close
            WP_STATUS=1
            WP_OUTPUT='cannot build the licence handoff command'
            return 0
        fi
        mapfile -t run <<<"$handoff_lines"
        if [ "${#run[@]}" -eq 0 ]; then
            licence_close
            WP_STATUS=1
            WP_OUTPUT='cannot build the licence handoff command'
            return 0
        fi
    else
        run=("${argv[@]}")
    fi
    WP_OUTPUT="$(run_as_user "$site" "$user" "${run[@]}" 2>&1)"
    WP_STATUS=$?
    licence_close
    end="$(date +%s)"

    # timeout(1) reports 124 (and 137 when it had to kill).
    if ((WP_STATUS == 124)) || ((WP_STATUS == 137)); then
        WP_OUTPUT="${WP_OUTPUT}
[command exceeded ${WP_COMMAND_TIMEOUT}s and was terminated with ${TIMEOUT_SIGNAL}]"
        log_warn "wp timed out after ${WP_COMMAND_TIMEOUT}s on ${site}"
    fi
    log_debug "wp exited ${WP_STATUS} in $((end - start))s: $(redact "${argv[*]:2}")"
    return 0
}

# run_wp: count the operation, log the failure, keep going.
run_wp() { # SITE USER ARGS...
    local site="$1" user="$2"
    wp_exec "$@"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS == 0)); then
        STATS_OPS_OK=$((STATS_OPS_OK + 1))
        if [ -n "$WP_OUTPUT" ] && [ "$QUIET" != 'true' ] &&
           [ "$OUTPUT_FORMAT" = 'table' ] && [ "$VERBOSE" = 'true' ]; then
            printf '%s\n' "$WP_OUTPUT"
        fi
        return 0
    fi
    STATS_OPS_FAILED=$((STATS_OPS_FAILED + 1))
    log_error "wp ${*:3} failed on ${site} (exit ${WP_STATUS})"
    log_error_detail 'run_wp' "wp $*" "$WP_OUTPUT" "$WP_STATUS"
    print_error_box "$site" "wp ${*:3}" "$WP_OUTPUT"
    return 1
}

# run_wp_soft: a failure is logged as a warning and is NOT counted as a failed
# operation. Used for opportunistic steps (the Astra licence dance inside
# --full) where aborting a whole site over a licensing hiccup would be worse
# than reporting it. It still *returns* the outcome, because a caller such as
# astra_step has to know whether to retry:
#   0 succeeded, 1 failed (softly), 2 not executed (dry run).
run_wp_soft() { # SITE USER ARGS...
    local site="$1" user="$2"
    wp_exec "$@"
    [ "$WP_SKIPPED" = 'true' ] && return 2
    if ((WP_STATUS == 0)); then
        STATS_OPS_OK=$((STATS_OPS_OK + 1))
        return 0
    fi
    log_warn "wp ${*:3} did not succeed on ${site} (exit ${WP_STATUS}); continuing"
    log_error_detail 'run_wp_soft' "wp $*" "$WP_OUTPUT" "$WP_STATUS"
    return 1
}

###############################################################################
# 11. Site inventory and owner resolution
###############################################################################

# db_user_from_config FILE -> the DB_USER literal, or nothing.
# `define( 'DB_USER', 'x' );` is read with a bash regex; the value is only ever
# used as a *name* and is validated against the passwd database afterwards, so
# a hostile wp-config.php cannot smuggle shell syntax into a command line.
db_user_from_config() {
    local cfg="${1:-}" line value
    [ -r "$cfg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ define\([[:space:]]*[\']DB_USER[\'][[:space:]]*,[[:space:]]*[\']([^\']*)[\'] ]] ||
           [[ "$line" =~ define\([[:space:]]*[\"]DB_USER[\"][[:space:]]*,[[:space:]]*[\"]([^\"]*)[\"] ]]; then
            value="${BASH_REMATCH[1]}"
            [ -n "$value" ] && { printf '%s' "$value"; return 0; }
        fi
    done <"$cfg"
    return 1
}

# usable_owner NAME -> 0 when NAME is an existing, non-system-shell account.
usable_owner() {
    local name="${1:-}" shell
    [ -n "$name" ] || return 1
    [ "$name" != 'root' ] || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    id -u "$name" >/dev/null 2>&1 || return 1
    if have getent; then
        shell="$(getent passwd "$name" 2>/dev/null | cut -d: -f7)"
        case "$shell" in
            '' | */nologin | */false | */sync | */shutdown | */halt) return 1 ;;
        esac
    fi
    return 0
}

file_owner() { stat -c '%U' -- "$1" 2>/dev/null; }

# Candidates in preference order. Kept as a list so the ordering is testable
# without a filesystem: wp-config.php owner, site directory owner, DB_USER.
# `root` is accepted only as a last resort -- containers legitimately run
# everything as root, and refusing to work there is worse than warning.
site_user_candidates() { # SITE
    local site="$1" cfg="${1}/wp-config.php" v
    if [ -f "$cfg" ]; then
        v="$(file_owner "$cfg")"
        [ -n "$v" ] && printf '%s\n' "$v"
    fi
    v="$(file_owner "$site")"
    [ -n "$v" ] && printf '%s\n' "$v"
    if [ -f "$cfg" ]; then
        v="$(db_user_from_config "$cfg")" && [ -n "$v" ] && printf '%s\n' "$v"
    fi
    return 0
}

SITE_USER_WARNINGS=0

site_user_resolve() { # SITE -> prints the user, returns non-zero when unknown
    local site="$1" cand chosen='' root_fallback=''
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        # Nothing is switched, so the only name that matters is the one used in
        # logs and in the child environment: report who will really run wp.
        id -un
        return 0
    fi
    if [ -n "${USER_OVERRIDE:-}" ]; then
        printf '%s' "$USER_OVERRIDE"
        return 0
    fi
    # DEFAULT_USER is the last resort before giving up: a host where every site is
    # served by one account (a shared pool) does not need per-site detection, and
    # an owner that cannot be determined must not stop the fleet.
    if [ -n "$DEFAULT_USER" ]; then
        printf '%s' "$DEFAULT_USER"
        return 0
    fi
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if usable_owner "$cand"; then chosen="$cand"; break; fi
        [ "$cand" = 'root' ] && root_fallback='root'
    done < <(site_user_candidates "$site")
    if [ -n "$chosen" ]; then
        printf '%s' "$chosen"
        return 0
    fi
    if [ -n "$root_fallback" ] && [ "$(id -u)" -eq 0 ]; then
        if ((SITE_USER_WARNINGS < 3)); then
            log_warn "${site}: owned by root and no usable site user found; running wp as root"
            SITE_USER_WARNINGS=$((SITE_USER_WARNINGS + 1))
        fi
        printf '%s' 'root'
        return 0
    fi
    return 1
}

# load_site_list FILE -> fills SITES[] and SITE_USER[]
load_site_list() { # FILE
    local file="${1:-}" line site user count=0
    SITES=()
    SITE_USER=()
    [ -n "$file" ] || { log_error 'no site list configured'; return 1; }
    if [ ! -f "$file" ]; then
        log_error "site list not found: ${file}"
        return 1
    fi
    if [ ! -r "$file" ]; then
        log_error "site list is not readable: ${file}"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip a CR (a list edited on Windows must still work) and nothing
        # else. Trimming spaces as well looks tidy and is not: a directory whose
        # name ends in a space is unusual but legal, and silently rewriting the
        # path would turn "site updated" into "site skipped, not a directory"
        # with no way for the operator to see why.
        line="${line%$'\r'}"
        case "$line" in '' | '#'*) continue ;; esac
        site="$line"
        if [ ! -d "$site" ]; then
            log_warn "skipping, not a directory: ${site}"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        if ! user="$(site_user_resolve "$site")"; then
            log_error "skipping ${site}: cannot determine the site owner (set SITE_USER or --user-env, or fix the ownership)"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        SITES+=("$site")
        SITE_USER["$site"]="$user"
        count=$((count + 1))
        if ((MAX_SITES > 0)) && ((count >= MAX_SITES)); then
            log_warn "--max-sites=${MAX_SITES} reached; the remaining entries of ${file} are not processed"
            break
        fi
    done <"$file"
    return 0
}

ensure_site_list() {
    if [ -f "$SITES_FILE" ] && [ -s "$SITES_FILE" ]; then return 0; fi
    if [ -f "$SITES_FILE" ]; then
        # Present but empty. That is a statement, not an accident: the operator
        # emptied it, or the last discovery found nothing. Scanning the default
        # web roots here and then updating whatever turns up is the one surprise
        # a maintenance tool must never produce, so discovery is not run.
        log_warn "site list ${SITES_FILE} exists but is empty; not running discovery"
        return 1
    fi
    if [ "$AUTO_DISCOVER" != 'true' ]; then
        log_error "site list ${SITES_FILE} is missing and AUTO_DISCOVER is off"
        return 1
    fi
    if [ ! -x "$DISCOVER_SCRIPT" ] && [ ! -f "$DISCOVER_SCRIPT" ]; then
        log_error "site list ${SITES_FILE} is missing or empty, and the discovery script ${DISCOVER_SCRIPT} is not there"
        return 1
    fi
    log_info "site list missing; running discovery: ${DISCOVER_SCRIPT##*/}"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: bash ${DISCOVER_SCRIPT} --output ${SITES_FILE}"
        return 1
    fi
    local rc=0
    if [ "$VERBOSE" = 'true' ]; then
        bash "$DISCOVER_SCRIPT" --output "$SITES_FILE" --color "$COLOR_MODE" || rc=$?
    else
        bash "$DISCOVER_SCRIPT" --output "$SITES_FILE" --quiet --color "$COLOR_MODE" || rc=$?
    fi
    if ((rc == 5)); then
        log_warn 'discovery found no WordPress installation'
        return 1
    elif ((rc != 0)); then
        log_error "discovery failed with exit ${rc}"
        return 1
    fi
    return 0
}

###############################################################################
# 12. Output rendering (pure bash: no jq, no python, no node)
###############################################################################

# TSV in, aligned table out. Column widths are measured over the first
# --page-limit rows so a 400-plugin site cannot blow up the terminal.
table_render() { # [MAX_ROWS]  < TSV
    local max="${1:-0}"
    local -a header=() rows=() widths=()
    local line i n col
    IFS= read -r line || return 0
    line="${line%$'\r'}"
    IFS=$'\t' read -r -a header <<<"$line"
    n=${#header[@]}
    ((n == 0)) && return 0
    for ((i = 0; i < n; i++)); do widths[i]=${#header[i]}; done
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        rows+=("$line")
        ((max > 0)) && ((${#rows[@]} >= max)) && break
        IFS=$'\t' read -r -a col <<<"$line"
        for ((i = 0; i < n && i < ${#col[@]}; i++)); do
            ((${#col[i]} > widths[i])) && widths[i]=${#col[i]}
        done
    done
    print_row() {
        local -a f=("$@") j
        for ((j = 0; j < n; j++)); do
            printf '%-*s  ' "${widths[j]}" "${f[j]-}"
        done
        printf '\n'
    }
    print_row "${header[@]}"
    local sep=''
    for ((i = 0; i < n; i++)); do
        local dashes=''
        printf -v dashes '%*s' "${widths[i]}" ''
        sep+="${dashes// /-}  "
    done
    printf '%s%s\n' "$C_DIM" "${sep%  }$C_RESET"
    for line in ${rows[@]+"${rows[@]}"}; do
        IFS=$'\t' read -r -a col <<<"$line"
        print_row "${col[@]}"
    done
    unset -f print_row
    return 0
}

# A minimal JSON array reader for the flat objects WP-CLI emits. It is not a
# JSON parser and it does not pretend to be one: it understands
# `[{"k":"v",...},...]` with string/number/bool/null values and \" escapes,
# which is exactly the shape of `wp plugin list --format=json`.
# json_to_tsv KEYS... < JSON  -> TSV (header line first)
json_to_tsv() {
    local data obj val esc rest ch two
    local BSLASH="\\"   # double quotes: a lone backslash in single quotes reads like an escape
    local LBRACK='[' RBRACK=']'
    local -a keys=("$@") fields=()
    data="$(cat)"
    data="${data#"${data%%[![:space:]]*}"}"
    data="${data%"${data##*[![:space:]]}"}"
    [ -n "$data" ] || return 0
    case "$data" in '['*']') ;; *) return 1 ;; esac
    data="${data#"$LBRACK"}"
    data="${data%"$RBRACK"}"
    # header
    local out='' k
    for k in "${keys[@]}"; do out+="${out:+$'\t'}${k}"; done
    printf '%s\n' "$out"
    while [ -n "$data" ]; do
        data="${data#"${data%%[![:space:]]*}"}"
        [ -n "$data" ] || break
        case "$data" in ,*) data="${data#,}"; continue ;; esac
        [ "${data:0:1}" = '{' ] || return 1
        rest="${data#\{}"
        obj=''
        while :; do
            case "$rest" in
                '' | \}*) break ;;
                '\\"'*) obj+='\"'; rest="${rest#\\\"}" ;;
                '"'*)
                    # a quoted string: everything up to the next bare quote
                    esc="${rest#\"}"
                    val=''
                    while :; do
                        ch="${esc:0:1}"
                        two="${esc:0:2}"
                        if [ -z "$ch" ] || [ "$ch" = '"' ]; then
                            break
                        elif [ "$two" = '\"' ]; then
                            # an escaped quote inside the JSON string
                            val+='\"'
                            esc="${esc:2}"
                        elif [ "$ch" = "$BSLASH" ]; then
                            # any other escape: keep both characters verbatim
                            val+="$two"
                            esc="${esc:2}"
                        else
                            val+="$ch"
                            esc="${esc:1}"
                        fi
                    done
                    obj+="\"${val}\""
                    rest="${esc#\"}"
                    ;;
                *) obj+="${rest:0:1}"; rest="${rest:1}" ;;
            esac
        done
        data="$rest"
        data="${data#\}}"
        # extract the requested keys from this object
        out=''
        for k in "${keys[@]}"; do
            val=''
            if [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                val="${BASH_REMATCH[1]}"
                val="${val//\\\"/\"}"
            elif [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*(true|false|null|-?[0-9.]+) ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            out+="${out:+$'\t'}${val}"
        done
        printf '%s\n' "$out"
    done
    return 0
}

# tsv_to_csv < TSV : quote fields that need it, double the inner quotes
tsv_to_csv() {
    local line field out first
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        out=''
        first=1
        local -a f=()
        IFS=$'\t' read -r -a f <<<"$line"
        for field in "${f[@]}"; do
            ((first)) || out+=','
            first=0
            case "$field" in
                *[,\"$'\n'$'\r']*) out+="\"${field//\"/\"\"}\"" ;;
                *) out+="$field" ;;
            esac
        done
        printf '%s\n' "$out"
    done
}

# plugin_filter TSV -> TSV, keeping the rows whose first column or whose `name`
# column matches --name as a case-insensitive *substring*. A substring match is
# deliberate: it is what an operator means by "the woo one", and it can never be
# interpreted as a pattern, so no metacharacter escaping is needed.
plugin_filter() {
    local needle="${FILTER_NAME,,}" line first=1 lower
    while IFS= read -r line || [ -n "$line" ]; do
        if ((first)); then printf '%s\n' "$line"; first=0; continue; fi
        [ -n "$needle" ] || { printf '%s\n' "$line"; continue; }
        lower="${line,,}"
        case "$lower" in *"$needle"*) printf '%s\n' "$line" ;; esac
    done
}

###############################################################################
# 12b. Backups
###############################################################################

# A maintenance tool that changes 200 databases and cannot undo any of them is a
# tool nobody will schedule. Two modes are offered and the difference matters:
#
#   db    `wp db export` -- seconds, and it covers everything the modes in this
#         script actually change;
#   full  a tar.gz of the whole installation -- complete, and on a site with a
#         large wp-content/uploads it can be tens of gigabytes and many minutes.
#
# `full` is opt-in and the script says out loud how big the tree is before
# archiving it. Backups are off by default: silently writing a database dump per
# site per run fills disks that nobody monitors.

backup_dir_of() {
    if [ -n "$BACKUP_DIR" ]; then
        printf '%s' "$BACKUP_DIR"
    else
        printf '%s' "${SCRIPT_DIR}/backups"
    fi
    return 0
}

# One directory per site, named after the site directory with everything outside
# a safe set replaced. Two sites whose directories are both called `www` share a
# folder; the file names carry a timestamp, the kind and the PID of the worker,
# so nothing is lost -- a one-second timestamp alone collides when parallel
# workers (or two dumps inside one run) write into the same directory.
site_backup_dir() { # SITE
    local name
    name="$(basename -- "$1")"
    name="${name//[^A-Za-z0-9._-]/_}"
    [ -n "$name" ] || name='site'
    printf '%s/%s' "$(backup_dir_of)" "$name"
}

# The manager creates this directory and it stays root-only: a database dump is a
# complete copy of a customer's data, and a multi-tenant host has no business letting
# any uid write into the backup tree. That was the earlier design (0777 + sticky, like
# /tmp) and it failed in the field the moment the backup root itself was 0700 -- the
# site owner could not traverse into its own subdirectory, `wp db export` died with
# "Permission denied", and every site was then skipped as "backup failed". The export
# now happens in a private directory owned by the site owner and the dump is moved into
# place as root, so the permissions of the backup tree stop mattering.
backup_ensure_dir() { # DIR
    local dir="${1:-}"
    [ -n "$dir" ] || return 1
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        [ -d "$dir" ] && [ -w "$dir" ] && return 0
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null
    return 0
}

# Free space in MiB on the filesystem holding DIR. Empty when it cannot be
# determined -- a guard that cannot judge must not invent a failure.
disk_free_mb() { # DIR
    local dir="${1:-.}" avail
    avail="$(df -Pk -- "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ "$avail" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$((avail / 1024))"
}

# A dump that fills the disk it writes to takes the database server down with it.
# The guard runs *before* the export, not after it failed.
require_free_space() { # DIR PURPOSE
    ((MIN_FREE_MB > 0)) || return 0
    local free
    free="$(disk_free_mb "$1")"
    [ -n "$free" ] || return 0
    if ((free < MIN_FREE_MB)); then
        log_error "${1}: ${free} MiB free, MIN_FREE_MB=${MIN_FREE_MB}; refusing to ${2}"
        return 1
    fi
    log_debug "${1}: ${free} MiB free (guard ${MIN_FREE_MB} MiB)"
    return 0
}

# Keep the newest $KEEP_BACKUPS of each kind and drop anything older than
# $BACKUP_AGE_DAYS. `find -printf '%T@'` plus a numeric sort is used instead of
# `ls -1t` because ls output is locale- and width-dependent and breaks on file
# names with spaces.
prune_backups() { # DIR
    local dir="${1:-}" keep="${KEEP_BACKUPS:-0}" age="${BACKUP_AGE_DAYS:-0}" f i=0
    [ -d "$dir" ] || return 0
    if ((age > 0)); then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rm -f -- "$f" 2>/dev/null && log_debug "backup expired (${age}d): ${f##*/}"
        done < <(find "$dir" -maxdepth 1 -type f -mtime "+${age}" \
                     \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
                     -print 2>/dev/null)
    fi
    ((keep > 0)) || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i + 1))
        if ((i > keep)); then
            rm -f -- "$f" 2>/dev/null
            log_debug "backup pruned: ${f##*/}"
        fi
    done < <(find "$dir" -maxdepth 1 \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    return 0
}

# The dump must not be killed by the per-command timeout: a large database takes
# longer than a plugin update, and a truncated dump is worse than no dump because
# it looks like a backup.
backup_database() { # SITE USER
    local site="$1" user="$2" dir file stamp rc=0 tmpdir tfile moved='false'
    local saved="$WP_COMMAND_TIMEOUT"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would export the database of ${site}"
        return 0
    fi
    dir="$(site_backup_dir "$site")"
    if ! backup_ensure_dir "$dir"; then
        log_warn "cannot create the backup directory ${dir}; continuing without a backup"
        return 1
    fi
    require_free_space "$dir" 'export the database' || return 1
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    file="${dir}/db-${stamp}.sql"
    # wp runs as the site owner and the backup tree is root-only, so the dump is
    # written where that owner can write and moved into place afterwards.
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.dump.XXXXXX" 2>/dev/null)" || {
        log_warn "cannot create a temporary directory for the dump of ${site}; continuing without a backup"
        return 1
    }
    chmod 700 "$tmpdir" 2>/dev/null
    if [ "$user" != "$(id -un 2>/dev/null)" ]; then
        chown "$user" "$tmpdir" 2>/dev/null
    fi
    tfile="${tmpdir}/db.sql"
    WP_COMMAND_TIMEOUT=0
    info_wp "$site" "$user" db export "$tfile"
    rc="$WP_STATUS"
    WP_COMMAND_TIMEOUT="$saved"
    if ((rc != 0)) || [ ! -s "$tfile" ]; then
        log_warn "database backup failed for ${site} (wp exit ${rc}); the site is still going to be updated"
        rm -rf -- "$tmpdir" 2>/dev/null
        return 1
    fi
    if mv -f -- "$tfile" "$file" 2>/dev/null; then
        moved='true'
        chown root:root "$file" 2>/dev/null
        chmod 640 "$file" 2>/dev/null
        rm -rf -- "$tmpdir" 2>/dev/null
    else
        # Nothing is thrown away because a directory could not be written to.
        log_warn "cannot place the dump in ${dir}; it stays at ${tfile}"
        file="$tfile"
    fi
    if [ "$BACKUP_COMPRESS" = 'true' ]; then
        if have gzip && gzip -f -- "$file" 2>/dev/null; then
            file="${file}.gz"
        else
            log_note 'gzip is not available; the database dump stays uncompressed'
        fi
    fi
    log_ok "database backup: ${file} ($(stat -c '%s' "$file" 2>/dev/null || printf '?') bytes)"
    [ "$moved" = 'true' ] && prune_backups "$dir"
    return 0
}

backup_site_tree() { # SITE USER
    local site="$1" user="$2" dir file stamp size
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would archive the whole tree of ${site}"
        return 0
    fi
    if ! have tar; then
        log_note 'tar(1) not found; --backup full degrades to a database dump'
        backup_database "$site" "$user"
        return $?
    fi
    dir="$(site_backup_dir "$site")"
    if ! backup_ensure_dir "$dir"; then
        log_warn "cannot create the backup directory ${dir}; continuing without a backup"
        return 1
    fi
    size="$(du -sk -- "$site" 2>/dev/null | cut -f1)"
    size="${size//[^0-9]/}"
    if [ -n "$size" ] && ((size > 1048576)); then
        log_warn "${site} is $((size / 1024)) MiB; --backup full will take a while and a lot of disk"
    fi
    require_free_space "$dir" 'archive the site tree' || return 1
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    file="${dir}/site-${stamp}.tar.gz"
    if tar -czf "$file" -C "$(dirname -- "$site")" "$(basename -- "$site")" 2>/dev/null; then
        chmod 640 "$file" 2>/dev/null
        log_ok "site archive: ${file}"
        prune_backups "$dir"
        return 0
    fi
    log_warn "site archive failed for ${site}"
    rm -f -- "$file" 2>/dev/null
    return 1
}

maybe_backup() { # SITE USER
    local site="$1" user="$2"
    # A read-only mode has nothing to protect against: exporting a database
    # before `--list-plugins` costs seconds per site and fills the disk for no
    # reason. Only a mode that changes something earns a backup.
    if mode_is_readonly; then
        log_debug 'read-only mode: no backup'
        return 0
    fi
    case "$BACKUP_MODE" in
        db) backup_database "$site" "$user" || return 1 ;;
        full) backup_site_tree "$site" "$user" || return 1 ;;
        off | *) return 0 ;;
    esac
    return 0
}

# Which modes are safe to run against a production database every minute: they
# read state and write nothing except log lines.
mode_is_readonly() {
    case "$MODE" in
        list-plugins | verify | health | secrets | list-backups) return 0 ;;
        check | status | doctor | completion) return 0 ;;
    esac
    return 1
}

###############################################################################
# 12b. Backup inventory and restore
###############################################################################

# Every backup this tool has written for one site, newest first, with its size.
# The listing deliberately does not consult the site list: an operator restoring
# a database at 3 a.m. has a site path in mind, not a working inventory.
backup_list_site() { # SITE
    local site="$1" dir
    dir="$(site_backup_dir "$site")"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f \
        \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
        -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' 2>/dev/null | sort -r
    return 0
}

# restore_database SITE USER FILE
#
# The other half of "we take backups". It is deliberately hard to call by
# accident: --yes is mandatory, and a fresh dump of the current database is taken
# first, because an import that stops halfway leaves the site worse than before.
restore_database() { # SITE USER FILE
    local site="$1" user="$2" file="$3" rc=0
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        log_error "${site}: no such backup or it is empty: ${file}"
        return 1
    fi
    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        log_error "${site}: --restore-db overwrites the live database; re-run with --yes to confirm"
        return 1
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] (${user}@$(basename -- "$site")) would import ${file}"
        return 0
    fi
    log_warn "${site}: restoring the database from ${file}"
    # Safety copy of what is about to be replaced. A failed dump is not fatal
    # here (the file may be damaged, which is why a restore is happening at all),
    # but the operator is told, loudly.
    if ! backup_database "$site" "$user"; then
        log_warn "${site}: could not dump the current database before the restore; continuing because the restore was explicit"
    fi
    run_wp "$site" "$user" db import "$file" || rc=1
    if ((rc == 0)); then
        info_wp "$site" "$user" db check
        if [ "$WP_STATUS" = '0' ]; then
            log_ok "${site}: database restored and db check passed"
        else
            log_warn "${site}: restore finished but db check reported a problem"
        fi
    else
        log_error "${site}: restore failed; the safety dump in $(site_backup_dir "$site") is the way back"
    fi
    return "$rc"
}

# A plugin that is about to be deleted has no other copy anywhere, so this backup
# is not optional: it happens unless the operator explicitly said --no-backup.
backup_plugin() { # SITE SLUG
    local site="$1" slug="$2" dir src file stamp
    if [ "$NO_BACKUP_EXPLICIT" = 'true' ]; then
        log_warn "deleting ${slug} on ${site} without a backup, because --no-backup was given"
        return 0
    fi
    src="${site}/wp-content/plugins/${slug}"
    if [ ! -d "$src" ]; then
        log_debug "no plugin directory to back up: ${src}"
        return 0
    fi
    if ! have tar; then
        log_note "tar(1) not found; ${slug} will be deleted without a file backup"
        return 0
    fi
    dir="$(site_backup_dir "$site")"
    if ! backup_ensure_dir "$dir"; then
        log_warn "cannot create the backup directory ${dir}; deleting without a file backup"
        return 0
    fi
    stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    file="${dir}/plugin-${slug}-${stamp}.tar.gz"
    if tar -czf "$file" -C "${site}/wp-content/plugins" "$slug" 2>/dev/null; then
        chmod 640 "$file" 2>/dev/null
        log_ok "plugin backup: ${file}"
        prune_backups "$dir"
    else
        log_warn "plugin backup failed for ${slug}; deleting anyway, because that is what was asked"
        rm -f -- "$file" 2>/dev/null
    fi
    return 0
}

###############################################################################
# 13. WP-CLI operations
###############################################################################

# info_wp: run a command for information only. It never touches the operation
# counters, because `wp core check-update` legitimately exits 1 when the site is
# already up to date, and counting that as a failure would cry wolf every run.
info_wp() { # SITE USER ARGS...
    wp_exec "$@"
    [ "$WP_SKIPPED" = 'true' ] && return 0
    if ((WP_STATUS == 0)); then
        [ -n "$WP_OUTPUT" ] && log_debug "check: ${WP_OUTPUT//$'\n'/ | }"
    else
        log_debug "check returned ${WP_STATUS}: ${WP_OUTPUT//$'\n'/ | }"
    fi
    return 0
}

core_report_available() { # SITE USER
    info_wp "$@" core check-update
    case "$WP_OUTPUT" in
        *'WordPress database upgrade required'*) ;;
        *'update_type'* | *'package'*)
            log_info "$(basename -- "$1"): a WordPress core update is available"
            ;;
        *)
            log_info "$(basename -- "$1"): WordPress core is up to date"
            ;;
    esac
    return 0
}

astra_ensure_licence() { # STRICT(true|false)
    if [ -n "$LICENCE_VALUE" ]; then return 0; fi
    local f
    for f in "${SCRIPT_DIR}/astra.key" /etc/wp-cli-update/astra.key "${HOME:-/root}/.astra.key"; do
        if [ -r "$f" ]; then
            LICENCE_VALUE="$(head -n 1 -- "$f" 2>/dev/null)"
            LICENCE_VALUE="${LICENCE_VALUE%$'\r'}"
            LICENCE_VALUE="${LICENCE_VALUE//[[:space:]]/}"
            if [ -n "$LICENCE_VALUE" ]; then
                log_debug "licence read from ${f}"
                redact_register "$LICENCE_VALUE"
                return 0
            fi
        fi
    done
    case "$LICENCE_VALUE" in
        YOUR* | *HERE* | CHANGE* | '') LICENCE_VALUE='' ;;
    esac
    if [ -z "$LICENCE_VALUE" ]; then
        if [ "${1:-false}" = 'true' ]; then
            log_error "mode --astra needs a licence: set WP_CLI_UPDATE_LICENCE, put it in the config file, pass --astra-key, or place it in ${SCRIPT_DIR}/astra.key"
            return 1
        fi
        log_warn 'no Astra licence configured; the Astra step is skipped'
        return 1
    fi
    return 0
}

# astra_step: update first (the common case), and only reach for the licence
# when the update actually failed. `rc == 2` means dry run: nothing happened and
# nothing should be retried.
astra_step() { # SITE USER STRICT(true|false)
    local site="$1" user="$2" strict="${3:-false}" rc=0
    run_wp_soft "$site" "$user" plugin update "$ASTRA_SLUG"
    rc=$?
    ((rc == 0)) && { log_ok "${site}: ${ASTRA_SLUG} updated"; return 0; }
    ((rc == 2)) && return 0

    if ! astra_ensure_licence "$strict"; then
        if [ "$strict" = 'true' ]; then return 1; fi
        return 0
    fi
    log_info "${site}: update failed, trying a licence activation"
    run_wp_soft "$site" "$user" brainstormforce license activate "$ASTRA_SLUG" "$LICENCE_MARKER"
    rc=$?
    if ((rc == 1)); then
        log_warn "${site}: licence activation did not succeed"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    ((rc == 2)) && return 0
    log_ok "${site}: licence activated"
    run_wp_soft "$site" "$user" plugin update "$ASTRA_SLUG"
    rc=$?
    if ((rc == 1)); then
        log_warn "${site}: ${ASTRA_SLUG} still did not update after activation"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    log_ok "${site}: ${ASTRA_SLUG} updated after licence activation"
    return 0
}

# One mode = one function, so a new mode is a new function plus one case branch
# and nothing else. Every function returns non-zero when the site failed.
mode_core() { # SITE USER
    local site="$1" user="$2" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user"
    run_wp "$site" "$user" core update || rc=1
    # --skip-plugins on the schema upgrade is what WordPress itself does during
    # an update: a broken plugin must not be able to block the DB migration.
    run_wp "$site" "$user" core update-db --skip-plugins || rc=1
    return "$rc"
}

# Update only the plugins that need it, minus the ones the operator excluded.
# WP-CLI has no "all except these" for `plugin update`, so the set is enumerated
# from `plugin list` and passed by slug -- which also means one broken plugin
# cannot hide behind `--all`.
plugins_update_selected() { # SITE USER
    local site="$1" user="$2"
    local -a targets=()
    plugin_select_targets "$site" "$user" || return 1
    mapfile -t targets < <(printf '%s' "$PLUGIN_SELECTION")
    if ((${#targets[@]} == 0)); then
        log_info "${site}: nothing to update among the selected plugins"
        return 0
    fi
    log_info "${site}: updating ${#targets[@]} plugin(s): ${targets[*]}"
    run_wp "$site" "$user" plugin update "${targets[@]}"
}

mode_plugins() { # SITE USER
    policies_init
    if [ "$ONLY_ACTIVE" = 'true' ] || [ -n "$EXCLUDE_PLUGINS" ] || [ -n "$HOLD_PLUGINS" ]; then
        plugins_update_selected "$1" "$2"
        return $?
    fi
    run_wp "$1" "$2" plugin update --all
}

# Excluding and holding themes is the same problem as plugins, so it is the same
# code shape: enumerate, filter, update by slug. WP-CLI has no "all except".
THEME_SELECTION=''
theme_select_targets() { # SITE USER
    local site="$1" user="$2"
    local tsv line name status update slug first=1
    THEME_SELECTION=''
    policies_init
    info_wp "$site" "$user" theme list --format=json --fields=name,slug,status,update
    [ "$WP_SKIPPED" = 'true' ] && return 0
    if ((WP_STATUS != 0)); then
        log_error "cannot enumerate themes on ${site} (wp exit ${WP_STATUS}); nothing was updated"
        return 1
    fi
    local body="$WP_OUTPUT"
    body="${body#"${body%%[![:space:]]*}"}"
    case "$body" in '['*']') ;; *) log_error "wp on ${site} did not return a JSON theme list; nothing was updated"; return 1 ;; esac
    tsv="$(printf '%s' "$body" | json_to_tsv name slug status update)" || {
        log_error "cannot parse the theme list from ${site}; nothing was updated"
        return 1
    }
    while IFS=$'\t' read -r name slug status update; do
        ((first)) && { first=0; continue; }
        [ -n "$slug" ] || continue
        if [ -n "${HOLD_THEME_MAP[${slug,,}]-}" ] || [ -n "${HOLD_THEME_MAP[${name,,}]-}" ]; then
            log_info "held by HOLD_THEMES, not updated: ${slug}"
            continue
        fi
        if [ -n "${EXCLUDED_THEME_MAP[${slug,,}]-}" ] || [ -n "${EXCLUDED_THEME_MAP[${name,,}]-}" ]; then
            log_debug "excluded by --exclude-themes: ${slug}"
            continue
        fi
        [ "$update" = 'available' ] || { log_debug "up to date, skipped: ${slug}"; continue; }
        THEME_SELECTION+="${THEME_SELECTION:+$'\n'}${slug}"
    done <<<"$tsv"
    return 0
}

themes_update_selected() { # SITE USER
    local site="$1" user="$2"
    local -a targets=()
    theme_select_targets "$site" "$user" || return 1
    mapfile -t targets < <(printf '%s' "$THEME_SELECTION")
    if ((${#targets[@]} == 0)); then
        log_info "${site}: nothing to update among the selected themes"
        return 0
    fi
    log_info "${site}: updating ${#targets[@]} theme(s): ${targets[*]}"
    run_wp "$site" "$user" theme update "${targets[@]}"
}

mode_themes() { # SITE USER
    policies_init
    if [ -n "$EXCLUDE_THEMES" ] || [ -n "$HOLD_THEMES" ]; then
        themes_update_selected "$1" "$2"
        return $?
    fi
    run_wp "$1" "$2" theme update --all
}

mode_db_optimize() { # SITE USER
    local rc=0
    run_wp "$1" "$2" db optimize || rc=1
    run_wp "$1" "$2" db repair || rc=1
    return "$rc"
}

mode_db_fix() { run_wp "$1" "$2" db repair; }

mode_cron() { run_wp "$1" "$2" cron event run --due-now; }

mode_full() { # SITE USER
    local site="$1" user="$2" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user"
    run_wp "$site" "$user" core update || rc=1
    mode_plugins "$site" "$user" || rc=1
    mode_themes "$site" "$user" || rc=1
    run_wp "$site" "$user" core update-db --skip-plugins || rc=1
    run_wp "$site" "$user" db optimize || rc=1
    run_wp "$site" "$user" db repair || rc=1
    run_wp "$site" "$user" cron event run --due-now || rc=1
    astra_step "$site" "$user" 'false' || true
    return "$rc"
}

mode_astra() { astra_step "$1" "$2" 'true'; }

# Read-only integrity check. `verify-checksums` compares every shipped file
# against the WordPress.org manifest, which is the cheapest way to find a
# half-finished update or a tampered core file before touching anything.
# A mismatch is a *finding*: it is reported and it fails the site, but nothing is
# modified, so the mode is safe to schedule hourly.
mode_verify() { # SITE USER
    local site="$1" user="$2" rc=0
    VERIFY_FINDINGS=$((VERIFY_FINDINGS + 1))
    if ! run_wp "$site" "$user" core verify-checksums; then
        log_error "${site}: core checksums do not match"
        rc=1
    fi
    if ! run_wp "$site" "$user" plugin verify-checksums --all; then
        log_error "${site}: at least one plugin failed its checksum verification"
        rc=1
    fi
    return "$rc"
}

###############################################################################
# 13b. Read-only modes: health, secrets, doctor, completion
###############################################################################

# --health: what would change if --full ran, per site, without changing it.
# Read-only on purpose: it is the mode monitoring calls every five minutes, and a
# monitoring probe that writes is not a probe.
HEALTH_HEADER='false'
health_header() {
    [ "$HEALTH_HEADER" = 'true' ] && return 0
    HEALTH_HEADER='true'
    printf '%-34s %-9s %-8s %-8s %-10s\n' 'SITE' 'CORE' 'PLUGINS' 'THEMES' 'DB MiB'
    printf -- '-------------------------------------------------------------------------------\n'
}

# pending_count SITE USER KIND -> a number on stdout.
# `--format=count` is what WP-CLI offers, but an older release (and the test stub)
# answers with a table, and "digit-strip the whole table" produces a number that
# looks plausible and is nonsense. Counting the rows of a name-only CSV works on
# every version.
pending_count() { # SITE USER KIND
    local site="$1" user="$2" kind="$3" n=0
    info_wp "$site" "$user" "$kind" list --update=available --format=csv --fields=name
    [ "$WP_STATUS" = '0' ] || { printf '0'; return 0; }
    n="$(printf '%s\n' "$WP_OUTPUT" | grep -c '[^[:space:]]')"
    n="${n//[^0-9]/}"
    n="${n:-0}"
    ((n > 0)) && n=$((n - 1))
    printf '%s' "$n"
}

mode_health() { # SITE USER
    local site="$1" user="$2" core='?' cp=0 tp=0 db='?' name
    name="$(basename -- "$site")"
    info_wp "$site" "$user" core version
    [ "$WP_STATUS" = '0' ] && core="$(printf '%s' "$WP_OUTPUT" | tr -d '\r' | head -n 1)"
    cp="$(pending_count "$site" "$user" plugin)"
    tp="$(pending_count "$site" "$user" theme)"
    info_wp "$site" "$user" db size --size_format=mb
    [ "$WP_STATUS" = '0' ] && db="$(printf '%s' "$WP_OUTPUT" | tr -dc '0-9.')"
    cp="${cp:-0}"; tp="${tp:-0}"
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        printf '{"type":"health","site":"%s","core":"%s","plugins_pending":%s,"themes_pending":%s,"db_mb":"%s"}\n' \
            "$(json_escape "$site")" "$(json_escape "$core")" "$cp" "$tp" "$(json_escape "$db")"
        return 0
    fi
    health_header
    printf '%-34s %-9s %-8s %-8s %-10s\n' "$name" "$core" "$cp" "$tp" "$db"
    return 0
}

# A wp-config.php that the world can read hands over the database password to
# every account on the host. The scan reports *names*, never values: a secret
# scanner that prints the secret has created the problem it was looking for.
file_perm_mode() { # FILE -> octal mode or empty
    local mode
    mode="$(stat -c '%a' -- "$1" 2>/dev/null)" || return 0
    printf '%s' "$mode"
}

mode_secrets() { # SITE USER
    local site="$1" cfg="${1}/wp-config.php" rc=0 n=0 line no const_name mode
    if [ ! -f "$cfg" ]; then
        log_warn "${site}: no wp-config.php to scan"
        return 0
    fi
    mode="$(file_perm_mode "$cfg")"
    if [ -n "$mode" ] && ((8#$mode & 8#004)); then
        log_error "${site}: wp-config.php is world-readable (mode ${mode}); chmod 640 it"
        rc=1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        no="${line%%:*}"
        const_name="$(printf '%s' "$line" | sed -E "s/.*define[[:space:]]*\\([[:space:]]*['\"]([^'\"]+)['\"].*/\\1/")"
        printf '  %s:%s  %s  <redacted>\n' "${cfg}" "$no" "$const_name"
        n=$((n + 1))
    done < <(grep -nE "define[[:space:]]*\\([[:space:]]*['\"][A-Z0-9_]*(PASSWORD|SECRET|KEY|SALT|TOKEN)[A-Z0-9_]*['\"]" -- "$cfg" 2>/dev/null)
    # Editor and deploy leftovers are a second copy of the same secrets, usually
    # with default permissions.
    local extra
    for extra in "${site}/wp-config.php.save" "${site}/wp-config.php.bak" "${site}/wp-config.php.old" "${site}/.env"; do
        if [ -f "$extra" ]; then
            log_error "${site}: stale secret-bearing file left behind: ${extra}"
            rc=1
        fi
    done
    log_info "${site}: ${n} secret-bearing constant(s) found (values not printed)"
    return "$rc"
}

# --doctor: the host, not the sites. Every line answers "why did the run fail
# before it started", and every failing line carries the fix.
mode_doctor() {
    local rc=0 free lbl
    printf '\n%s== host ==%s\n' "$C_BOLD" "$C_RESET"
    printf '%-22s %s\n' 'bash' "$BASH_VERSION"
    printf '%-22s %s\n' 'script' "${SCRIPT_DIR}/${PROG_NAME} ${SCRIPT_VERSION}"
    printf '%-22s %s (uid %s)\n' 'running as' "$(id -un)" "$(id -u)"
    if wp_ensure; then
        printf '%-22s %s\n' 'wp-cli' "$WP_RESOLVED"
        local wpinfo ar
        local -a wi=()
        ar="$(allow_root_flag)"
        [ -n "$ar" ] && wi+=("$ar")
        wpinfo="$("$WP_RESOLVED" ${wi[@]+"${wi[@]}"} --version 2>/dev/null | head -n 1)"
        [ -n "$wpinfo" ] && printf '%-22s %s\n' 'wp version' "$wpinfo"
    else
        printf '%-22s %sNOT FOUND%s (set WP_CLI_PATH or --wp)\n' 'wp-cli' "$C_RED" "$C_RESET"
        rc=1
    fi
    printf '%-22s %s\n' 'user switch' "$(switch_mechanism)"
    [ "$(id -u)" -eq 0 ] || printf '%-22s %snot root: user switching and lock ownership will not work%s\n' 'root' "$C_YELLOW" "$C_RESET"
    for lbl in timeout perl flock tar gzip nice ionice curl mail; do
        if have "$lbl"; then
            printf '%-22s %s\n' "$lbl" "$(command -v "$lbl")"
        else
            printf '%-22s %smissing%s\n' "$lbl" "$C_YELLOW" "$C_RESET"
        fi
    done
    printf '\n%s== paths ==%s\n' "$C_BOLD" "$C_RESET"
    for lbl in "$LOG_FILE" "$ERROR_LOG_FILE" "$(backup_dir_of)" "$SITES_FILE"; do
        [ -n "$lbl" ] || continue
        free="$(disk_free_mb "$(dirname -- "$lbl")" 2>/dev/null)"
        printf '%-22s %-52s %s\n' "$(dirname -- "$lbl")" "$([ -e "$lbl" ] && printf 'present' || printf 'absent')" \
            "${free:+${free} MiB free}"
    done
    if [ -n "$CONFIG_FILE_USED" ]; then
        printf '%-22s %s\n' 'config' "$CONFIG_FILE_USED"
        if config_perm_is_unsafe "$CONFIG_FILE_USED"; then
            printf '%-22s %sgroup- or world-writable: chmod 600 it%s\n' '' "$C_RED" "$C_RESET"
            rc=1
        fi
    fi
    printf '\n%s== policy ==%s\n' "$C_BOLD" "$C_RESET"
    printf '%-22s %s\n' 'jobs' "$JOBS"
    printf '%-22s %s (%s)\n' 'nice' "$NICE_LEVEL" "$([ "$NICE_LEVEL" = '0' ] && printf 'off' || printf 'wp runs at this niceness')"
    printf '%-22s %s\n' 'ionice' "$IONICE_CLASS"
    printf '%-22s %s MiB\n' 'min free (guard)' "$MIN_FREE_MB"
    printf '%-22s %s\n' 'retry' "${RETRY} attempt(s), ${RETRY_DELAY}s apart"
    printf '%-22s %s\n' 'max failures' "$([ "$MAX_FAILURES" = '0' ] && printf 'unlimited' || printf '%s' "$MAX_FAILURES")"
    printf '%-22s %s\n' 'run timeout' "$([ "$RUN_TIMEOUT" = '0' ] && printf 'none' || printf '%ss' "$RUN_TIMEOUT")"
    printf '%-22s %s\n' 'notify' "$([ -n "$NOTIFY_WEBHOOK" ] && printf 'webhook' || printf 'off') $([ -n "$MAIL_TO" ] && printf '+ mail' ) on ${NOTIFY_ON}"
    printf '%-22s %s\n' 'report file' "${REPORT_FILE:-<none>}"
    printf '\n'
    return "$rc"
}

# --completion: the shell contract --list-modes already exposes, spelled out.
mode_completion() { # SHELL
    local shell="${1:-bash}"
    case "$shell" in
        bash)
            cat <<'EOS'
# bash completion for Bash_WP-CLI_Update.sh
# install: Bash_WP-CLI_Update.sh --completion bash | sudo tee /etc/bash_completion.d/wp-cli-update
_wp_cli_update() {
    local cur prev modes opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    modes='full core plugins themes db-optimize db-fix cron astra list-plugins plugin-manage verify health secrets check status doctor list-sites list-backups restore-db'
    # Every mode and every option, generated from parse_args; the static suite
    # fails if this list drifts from --help.
    opts='--action --allow-root --astra --astra-key --astra-slug --backup --backup-age-days --backup-compress --backup-dir --check --color --completion --config --core --cron --db-fix --db-optimize --debug --default-user --doctor --dry-run --error-log-file --exclude-plugins --exclude-themes --fail-on --fields --force --format --full --health --help --hold-plugins --hold-themes --ionice --jobs --json --json-lines --json-log --keep-backups --kill-after --list-backups --list-modes --list-plugins --list-sites --lock-file --lock-wait --log-dir --log-file --log-level --mail-to --max-failures --max-sites --min-free-mb --name --nice --no-backup --no-color --no-discover --no-lock --no-notify --no-url-detect --no-user-switch --notify --notify-on --only-active --option --page-limit --plugin-manage --plugins --print-config --quiet --report --restore-db --retry --retry-delay --run-timeout --secrets --signal --site --sites --sites-file --skip-if-no-updates --skip-plugins --skip-plugins-for-listing --status --strict --themes --timeout --url --user --user-env --verbose --verify --version --wp --wp-bin --wp-cli --yes'
    case "$prev" in
        --format) COMPREPLY=($(compgen -W 'table json csv tsv' -- "$cur")); return ;;
        --color|--allow-root) COMPREPLY=($(compgen -W 'auto always never' -- "$cur")); return ;;
        --fail-on) COMPREPLY=($(compgen -W 'any all never' -- "$cur")); return ;;
        --ionice) COMPREPLY=($(compgen -W 'idle best-effort none' -- "$cur")); return ;;
        --notify-on) COMPREPLY=($(compgen -W 'never failure always' -- "$cur")); return ;;
        --backup) COMPREPLY=($(compgen -W 'off db full' -- "$cur")); return ;;
        --action) COMPREPLY=($(compgen -W 'activate deactivate delete' -- "$cur")); return ;;
        --completion) COMPREPLY=($(compgen -W 'bash zsh' -- "$cur")); return ;;
        --site|--sites|--sites-file|--config|--wp|--report|--restore-db|--log-file|--log-dir) COMPREPLY=($(compgen -f -- "$cur")); return ;;
    esac
    COMPREPLY=($(compgen -W "${modes} ${opts}" -- "$cur"))
}
complete -F _wp_cli_update Bash_WP-CLI_Update.sh wp-cli-update wp-update
EOS
        ;;
        zsh)
            cat <<'EOS'
#compdef Bash_WP-CLI_Update.sh
_wp_cli_update() {
    local -a modes opts
    modes=(full core plugins themes db-optimize db-fix cron astra list-plugins plugin-manage verify health secrets check status doctor list-sites list-backups restore-db)
    opts=(--action --allow-root --astra --astra-key --astra-slug --backup --backup-age-days --backup-compress --backup-dir --check --color --completion --config --core --cron --db-fix --db-optimize --debug --default-user --doctor --dry-run --error-log-file --exclude-plugins --exclude-themes --fail-on --fields --force --format --full --health --help --hold-plugins --hold-themes --ionice --jobs --json --json-lines --json-log --keep-backups --kill-after --list-backups --list-modes --list-plugins --list-sites --lock-file --lock-wait --log-dir --log-file --log-level --mail-to --max-failures --max-sites --min-free-mb --name --nice --no-backup --no-color --no-discover --no-lock --no-notify --no-url-detect --no-user-switch --notify --notify-on --only-active --option --page-limit --plugin-manage --plugins --print-config --quiet --report --restore-db --retry --retry-delay --run-timeout --secrets --signal --site --sites --sites-file --skip-if-no-updates --skip-plugins --skip-plugins-for-listing --status --strict --themes --timeout --url --user --user-env --verbose --verify --version --wp --wp-bin --wp-cli --yes)
    _arguments '*: :->args'
    compadd -- "${modes[@]}" "${opts[@]}"
}
compdef _wp_cli_update Bash_WP-CLI_Update.sh
EOS
        ;;
        *) usage_error "--completion must be bash or zsh (got '${shell}')" ;;
    esac
    return 0
}

###############################################################################
# 14. Plugin listing and management
###############################################################################

PLUGIN_FIELDS_DEFAULT='name,status,update,version'
FILTER_FIELDS=''

# Plugin and theme policy lists. A comma separated list is split here rather
# than at every use site, and the comparison is a whole token, case-insensitive
# -- never a pattern, so nothing an operator types needs escaping.
declare -A EXCLUDED_MAP=()
declare -A HOLD_MAP=()
declare -A EXCLUDED_THEME_MAP=()
declare -A HOLD_THEME_MAP=()
POLICIES_READY='false'

map_add_csv() { # CSV WHICH
    local csv="$1" which="$2" ex
    [ -n "$csv" ] || return 0
    local IFS=','
    for ex in $csv; do
        ex="${ex//[[:space:]]/}"
        [ -n "$ex" ] || continue
        case "$which" in
            excluded) EXCLUDED_MAP["${ex,,}"]=1 ;;
            hold) HOLD_MAP["${ex,,}"]=1 ;;
            excluded_theme) EXCLUDED_THEME_MAP["${ex,,}"]=1 ;;
            hold_theme) HOLD_THEME_MAP["${ex,,}"]=1 ;;
        esac
    done
    return 0
}

policies_init() {
    [ "$POLICIES_READY" = 'true' ] && return 0
    map_add_csv "$EXCLUDE_PLUGINS" excluded
    map_add_csv "$HOLD_PLUGINS" hold
    map_add_csv "$EXCLUDE_THEMES" excluded_theme
    map_add_csv "$HOLD_THEMES" hold_theme
    POLICIES_READY='true'
    return 0
}

plugin_columns() {
    local list="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    list="${list//,/ }"
    printf '%s' "$list"
}

# Fetch the plugin list as JSON, then render it in the requested format without
# any external JSON tool.
plugin_list_site() { # SITE USER
    local site="$1" user="$2"
    local -a fields=()
    read -r -a fields <<<"$(plugin_columns)"
    info_wp "$site" "$user" plugin list --format=json --fields="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        STATS_OPS_FAILED=$((STATS_OPS_FAILED + 1))
        log_error "cannot list plugins on ${site} (exit ${WP_STATUS})"
        log_error_detail 'plugin_list' "wp plugin list --format=json" "$WP_OUTPUT" "$WP_STATUS"
        return 1
    fi
    local body="$WP_OUTPUT"
    body="${body#"${body%%[![:space:]]*}"}"
    case "$body" in
        '['*']') ;;
        *)
            STATS_OPS_FAILED=$((STATS_OPS_FAILED + 1))
            log_error "wp on ${site} did not return a JSON plugin list"
            log_error_detail 'plugin_list' 'wp plugin list --format=json' "$WP_OUTPUT" 0
            return 1
            ;;
    esac
    STATS_OPS_OK=$((STATS_OPS_OK + 1))

    local tsv
    tsv="$(printf '%s' "$body" | json_to_tsv "${fields[@]}")" || {
        log_error "cannot parse the JSON plugin list from ${site}"
        return 1
    }
    tsv="$(printf '%s\n' "$tsv" | plugin_filter)"

    # In parallel mode the machine-readable payload goes to the worker's data
    # fragment: the parent emits the fragments in site order, so the stream stays
    # parseable instead of becoming three interleaved JSON documents.
    local sink='/dev/stdout'
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ] &&
       { is_machine_format || [ "$JSON_LINES" = 'true' ]; }; then
        sink="${WORKER_DIR}/data"
    fi
    case "$OUTPUT_FORMAT" in
        json) printf '%s\n' "$body" >"$sink" ;;
        csv) printf '%s\n' "$tsv" | tsv_to_csv >"$sink" ;;
        tsv) printf '%s\n' "$tsv" >"$sink" ;;
        table | *)
            {
                printf '%s%s%s\n' "$C_BOLD" "$site$C_RESET" ''
                printf '%s\n' "$tsv" | table_render "$PAGE_LIMIT"
            } >"$sink"
            ;;
    esac
    return 0
}

# plugin_select_targets SITE USER -> fills PLUGIN_SELECTION (newline separated)
# with the slugs that should be updated, honouring --only-active and
# --exclude-plugins. Uses the same JSON reader as --list-plugins, so no jq.
PLUGIN_SELECTION=''

plugin_select_targets() { # SITE USER
    local site="$1" user="$2"
    local tsv line name status update slug
    PLUGIN_SELECTION=''
    policies_init
    info_wp "$site" "$user" plugin list --format=json --fields=name,slug,status,update
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        log_error "cannot enumerate plugins on ${site} (wp exit ${WP_STATUS}); nothing was updated"
        return 1
    fi
    local body="$WP_OUTPUT"
    body="${body#"${body%%[![:space:]]*}"}"
    case "$body" in
        '['*']') ;;
        *)
            log_error "wp on ${site} did not return a JSON plugin list; nothing was updated"
            return 1
            ;;
    esac
    tsv="$(printf '%s' "$body" | json_to_tsv name slug status update)" || {
        log_error "cannot parse the plugin list from ${site}; nothing was updated"
        return 1
    }
    local first=1
    while IFS=$'\t' read -r name slug status update; do
        ((first)) && { first=0; continue; }          # header row
        [ -n "$slug" ] || continue
        if [ -n "${HOLD_MAP[${slug,,}]-}" ] || [ -n "${HOLD_MAP[${name,,}]-}" ]; then
            log_info "held by HOLD_PLUGINS, not updated: ${slug}"
            continue
        fi
        if [ -n "${EXCLUDED_MAP[${slug,,}]-}" ] || [ -n "${EXCLUDED_MAP[${name,,}]-}" ]; then
            log_debug "excluded by --exclude-plugins: ${slug}"
            continue
        fi
        if [ "$ONLY_ACTIVE" = 'true' ]; then
            [ "$status" = 'active' ] || { log_debug "not active, skipped: ${slug}"; continue; }
            [ "$update" = 'available' ] || { log_debug "up to date, skipped: ${slug}"; continue; }
        fi
        PLUGIN_SELECTION+="${PLUGIN_SELECTION:+$'\n'}${slug}"
    done <<<"$tsv"
    return 0
}

# Resolve --name to exactly one slug. Substring, case-insensitive, no patterns.
plugin_resolve_slug() { # SITE USER NAME -> slug
    local site="$1" user="$2" name="${3,,}"
    info_wp "$site" "$user" plugin list --format=json --fields=name,slug,status
    ((WP_STATUS == 0)) || return 1
    local tsv n s match='' matches=0
    tsv="$(printf '%s' "$WP_OUTPUT" | json_to_tsv name slug status)" || return 1
    while IFS=$'\t' read -r n s _status; do
        [ "$n" = 'name' ] && continue
        [ -n "$s" ] || continue
        if [ "${n,,}" = "$name" ] || [ "${s,,}" = "$name" ]; then
            match="$s"; matches=1; break
        fi
        case "${n,,}" in *"$name"*) match="$s"; matches=$((matches + 1)) ;; esac
        case "${s,,}" in *"$name"*) [ "$match" = "$s" ] || { match="$s"; matches=$((matches + 1)); } ;; esac
    done <<<"$tsv"
    if ((matches == 0)); then
        log_error "no plugin matching '${3}' on ${site}"
        return 1
    fi
    if ((matches > 1)); then
        log_error "'${3}' is ambiguous on ${site}; pass the exact slug"
        return 1
    fi
    printf '%s' "$match"
}

confirm_destructive() { # SLUG SITE
    local slug="$1" site="$2" answer
    if [ "$FORCE_DELETE" = 'true' ] || [ "$ASSUME_YES" = 'true' ]; then return 0; fi
    if [ ! -t 0 ]; then
        log_error "refusing to delete '${slug}' on ${site} without a terminal; pass --yes to confirm explicitly"
        return 1
    fi
    printf '%sDelete plugin "%s" on %s? This cannot be undone. [y/N] %s' \
        "$C_YELLOW" "$slug" "$site" "$C_RESET" >&2
    IFS= read -r answer || answer=''
    case "${answer,,}" in y | yes) return 0 ;; esac
    log_warn "deletion of '${slug}' cancelled"
    return 1
}

mode_plugin_manage() { # SITE USER
    local site="$1" user="$2" slug wp_action
    case "$PLUGIN_ACTION" in
        activate) wp_action='activate' ;;
        deactivate) wp_action='deactivate' ;;
        delete) wp_action='delete' ;;
        *) log_error "--plugin-manage needs --action activate|deactivate|delete"; return 1 ;;
    esac
    [ -n "$PLUGIN_NAME" ] || { log_error "--plugin-manage needs --name NAME"; return 1; }
    slug="$(plugin_resolve_slug "$site" "$user" "$PLUGIN_NAME")" || return 1
    if [ "$wp_action" = 'delete' ] && ! confirm_destructive "$slug" "$site"; then
        return 1
    fi
    if [ "$wp_action" = 'delete' ]; then
        # After this call there is no other copy of the plugin anywhere.
        backup_plugin "$site" "$slug"
        # Deactivate first. `plugin delete` on an active plugin leaves its
        # options, tables and cron events behind, because the deactivation hooks
        # never run; deactivating first gives the plugin the chance to clean up
        # after itself. A failure here is not fatal: the operator asked for the
        # plugin to go, and an inactive-plugin delete is still what they want.
        run_wp_soft "$site" "$user" plugin deactivate "$slug" >/dev/null
    fi
    run_wp "$site" "$user" plugin "$wp_action" "$slug"
}

mode_list_plugins() { # SITE USER
    plugin_list_site "$1" "$2"
}

###############################################################################
# 14b. Fleet report as JSON Lines
###############################################################################

# One object per site plus a final summary object. JSON Lines rather than a JSON
# array, because a fleet run is a stream: with an array the operator gets nothing
# until the last site finishes, and a run that is killed produces invalid JSON.
# With Lines, `... --json | while read -r o; do ...` sees every site as it lands
# and a killed run still leaves a parseable prefix.
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

emit_site_json() { # SITE STATUS OPS_OK OPS_FAILED WARNINGS
    local site="$1" status="$2"
    printf '{"type":"site","path":"%s","status":"%s","owner":"%s"}\n' \
        "$(json_escape "$site")" "$(json_escape "$status")" \
        "$(json_escape "${SITE_USER[$site]-}")"
}

emit_summary_json() { # EXIT_CODE
    printf '{"type":"summary","mode":"%s","version":"%s","exit":%s,"sites":%s,"sites_ok":%s,' \
        "$(json_escape "$MODE")" "$SCRIPT_VERSION" "${1:-0}" "$STATS_SITES_TOTAL" "$STATS_SITES_OK"
    printf '"sites_failed":%s,"sites_skipped":%s,"ops_ok":%s,"ops_failed":%s,"warnings":%s,' \
        "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED" "$STATS_OPS_OK" "$STATS_OPS_FAILED" "$STATS_WARNINGS"
    printf '"jobs":%s,"backup":"%s","dry_run":%s,"elapsed":%s,"results":[' \
        "$JOBS" "$(json_escape "$BACKUP_MODE")" "$DRY_RUN" "$(( $(date +%s) - START_TIME ))"
    local site first=1
    for site in ${SITES[@]+"${SITES[@]}"}; do
        ((first)) || printf ','
        first=0
        printf '{"path":"%s","status":"%s"}' \
            "$(json_escape "$site")" "$(json_escape "${SITE_STATUS[$site]-UNKNOWN}")"
    done
    printf ']}\n'
}

###############################################################################
# 15. --check, --status, summary
###############################################################################

check_report() { # SITE USER -> exit code
    local site="$1" user="${2:-}" rc=0 line
    printf '%s\n' "${C_BOLD}site            ${C_RESET}: ${site}"
    if [ ! -d "$site" ]; then
        printf '%s\n' "  ${C_RED}✗${C_RESET} not a directory"
        return 1
    fi
    if [ -f "${site}/wp-config.php" ]; then
        printf '%s\n' "  ${C_GREEN}✓${C_RESET} wp-config.php"
    else
        printf '%s\n' "  ${C_RED}✗${C_RESET} wp-config.php missing"
        rc=1
    fi
    if [ -f "${site}/wp-includes/version.php" ]; then
        printf '%s\n' "  ${C_GREEN}✓${C_RESET} wp-includes/version.php"
    else
        printf '%s\n' "  ${C_YELLOW}!${C_RESET} wp-includes/version.php missing (is this a WordPress root?)"
    fi
    if [ -f "${site}/.no_wp_cli" ]; then
        printf '%s\n' "  ${C_YELLOW}!${C_RESET} opt-out marker .no_wp_cli present -- the finder will not list this site"
    fi
    if [ -n "$user" ]; then
        printf '%s\n' "  ${C_GREEN}✓${C_RESET} owner: ${user}"
    else
        printf '%s\n' "  ${C_RED}✗${C_RESET} owner: cannot be determined"
        rc=1
    fi
    return "$rc"
}

check_environment() {
    local rc=0 site user
    printf '\n%s== environment ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'bash            : %s\n' "$BASH_VERSION"
    printf 'script          : %s %s (%s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$SCRIPT_DIR"
    printf 'running as      : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    if wp_ensure; then
        printf 'wp-cli          : %s\n' "$WP_RESOLVED"
    else
        printf 'wp-cli          : %sNOT FOUND%s\n' "$C_RED" "$C_RESET"
        rc=1
    fi
    printf 'user switch     : %s\n' "$(switch_mechanism)"
    local lock_kind='pid file'
    have flock && lock_kind='flock'
    printf 'lock            : %s (%s)\n' "$LOCK_FILE" "$lock_kind"
    local timeout_desc='disabled'
    if ((WP_COMMAND_TIMEOUT > 0)); then
        timeout_desc="${WP_COMMAND_TIMEOUT}s, signal ${TIMEOUT_SIGNAL}, kill-after ${KILL_AFTER}s"
    fi
    printf 'timeout         : %s\n' "$timeout_desc"
    printf 'log             : %s (max %s bytes, keep %s)\n' "${LOG_FILE:-<disabled>}" "$LOG_MAX_BYTES" "$LOG_KEEP"
    printf 'error log       : %s\n' "${ERROR_LOG_FILE:-<disabled>}"
    printf 'config source   : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'skip-plugins    : %s\n' "${SKIP_PLUGINS:-<none>}"
    printf 'allow-root      : %s\n' "$ALLOW_ROOT_FLAG"
    printf 'licence         : %s\n' "$([ -n "$LICENCE_VALUE" ] && printf 'configured (value redacted)' || printf '<not configured>')"
    printf 'dry-run         : %s\n' "$DRY_RUN"
    printf 'fail-on         : %s\n' "$FAIL_ON"
    printf 'strict          : %s\n' "$STRICT"
    printf 'jobs            : %s\n' "$JOBS"
    printf 'backup          : %s%s\n' "$BACKUP_MODE" \
        "$([ "$BACKUP_MODE" != 'off' ] && printf ' -> %s (keep %s)' "$(backup_dir_of)" "$KEEP_BACKUPS")"
    printf 'only-active     : %s\n' "$ONLY_ACTIVE"
    printf 'exclude-plugins : %s\n' "${EXCLUDE_PLUGINS:-<none>}"
    printf 'url             : %s\n' "${SITE_URL:-<none>}"
    printf 'user switch     : %s\n' "$([ "$NO_USER_SWITCH" = 'true' ] && printf 'disabled (--no-user-switch)' || printf 'enabled')"

    printf '\n%s== site list ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'file            : %s\n' "$SITES_FILE"
    if [ ! -f "$SITES_FILE" ]; then
        printf '%s\n' "  ${C_RED}✗${C_RESET} the file does not exist (AUTO_DISCOVER=${AUTO_DISCOVER})"
        rc=1
    else
        printf 'entries         : %s\n' "${#SITES[@]}"
        if ((${#SITES[@]} == 0)); then
            printf '%s\n' "  ${C_YELLOW}!${C_RESET} the list is empty or every entry was skipped"
        fi
        for site in ${SITES[@]+"${SITES[@]}"}; do
            user="${SITE_USER[$site]-}"
            check_report "$site" "$user" || rc=1
        done
    fi
    printf '\n'
    return "$rc"
}

switch_mechanism() {
    if [ "$(id -u)" -ne 0 ]; then
        printf 'none (not root: commands run as %s)' "$(id -un)"
        return 0
    fi
    if have runuser; then printf 'runuser'; return 0; fi
    if have sudo; then printf 'sudo -n'; return 0; fi
    if have su; then printf 'su -s /bin/sh'; return 0; fi
    printf '%snone available%s' "$C_RED" "$C_RESET"
}

status_report() {
    local f="${LOG_FILE}.state" size line
    printf '\n%s== last run ==%s\n' "$C_BOLD" "$C_RESET"
    if [ -r "$f" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && printf '%s\n' "  $line"
        done <"$f"
    else
        printf '%s\n' '  no recorded run yet'
    fi
    printf '\n%s== logs ==%s\n' "$C_BOLD" "$C_RESET"
    for f in "$LOG_FILE" "$ERROR_LOG_FILE"; do
        [ -n "$f" ] || continue
        if [ -f "$f" ]; then
            size="$(stat -c '%s' "$f" 2>/dev/null)" || size='?'
            printf '  %-40s %10s bytes\n' "$f" "$size"
        else
            printf '  %-40s %10s\n' "$f" '(absent)'
        fi
    done
    printf '\n'
}

# One JSON document per run, so a monitoring system can read what happened without
# parsing a human log. Written atomically: a half-written report is worse than none.
report_write() { # RC
    [ -n "$REPORT_FILE" ] || return 0
    local tmp="${REPORT_FILE}.tmp.$$" site kind name old new first=1
    mkdir -p -- "$(dirname -- "$REPORT_FILE")" 2>/dev/null || true
    {
        printf '{"run":{"version":"%s","mode":"%s","dry_run":%s,' \
            "$(json_escape "$SCRIPT_VERSION")" "$(json_escape "$MODE")" \
            "$([ "$DRY_RUN" = 'true' ] && printf 'true' || printf 'false')"
        printf '"host":"%s","duration_s":%s,' \
            "$(json_escape "$(hostname 2>/dev/null || id -un)")" "$(( $(date +%s) - START_TIME ))"
        printf '"sites_total":%s,"sites_ok":%s,"sites_failed":%s,"sites_skipped":%s,' \
            "$STATS_SITES_TOTAL" "$STATS_SITES_OK" "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED"
        printf '"ops_ok":%s,"ops_failed":%s,"warnings":%s,"retries":%s,"changes":%s,"exit":%s},' \
            "$STATS_OPS_OK" "$STATS_OPS_FAILED" "$STATS_WARNINGS" "$STATS_RETRIES" "$STATS_CHANGES" "$1"
        printf '"sites":['
        for site in ${SITES[@]+"${SITES[@]}"}; do
            ((first)) || printf ','
            first=0
            printf '{"path":"%s","status":"%s"}' \
                "$(json_escape "$site")" "$(json_escape "${SITE_STATUS[$site]:-UNKNOWN}")"
        done
        printf '],"changes":['
        first=1
        if [ -n "$CHANGES_FILE" ] && [ -s "$CHANGES_FILE" ]; then
            while IFS=$'\t' read -r site kind name old new; do
                [ -n "$site" ] || continue
                ((first)) || printf ','
                first=0
                printf '{"site":"%s","kind":"%s","name":"%s","from":"%s","to":"%s"}' \
                    "$(json_escape "$site")" "$(json_escape "$kind")" "$(json_escape "$name")" \
                    "$(json_escape "$old")" "$(json_escape "$new")"
            done <"$CHANGES_FILE"
        fi
        printf ']}\n'
    } >"$tmp" 2>/dev/null
    if mv -f -- "$tmp" "$REPORT_FILE" 2>/dev/null; then
        log_debug "run report written: ${REPORT_FILE}"
        return 0
    fi
    rm -f -- "$tmp" 2>/dev/null
    log_note "cannot write the run report to ${REPORT_FILE}"
    return 0
}

# A cron job that fails silently is a cron job nobody reads. The payload carries
# counters only: no site content, no licence, no paths beyond the count.
notify_send() { # RC
    [ "$NOTIFY_ON" = 'never' ] && return 0
    if [ "$NOTIFY_ON" = 'failure' ] && [ "$1" = '0' ]; then return 0; fi
    [ -n "$NOTIFY_WEBHOOK" ] || [ -n "$MAIL_TO" ] || return 0
    local payload subject
    payload="$(printf '{"version":"%s","mode":"%s","host":"%s","exit":%s,"sites_total":%s,"sites_ok":%s,"sites_failed":%s,"sites_skipped":%s,"warnings":%s,"changes":%s,"duration_s":%s}' \
        "$(json_escape "$SCRIPT_VERSION")" "$(json_escape "$MODE")" \
        "$(json_escape "$(hostname 2>/dev/null || id -un)")" "$1" \
        "$STATS_SITES_TOTAL" "$STATS_SITES_OK" "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED" \
        "$STATS_WARNINGS" "$STATS_CHANGES" "$(( $(date +%s) - START_TIME ))")"
    subject="[${PROG_NAME}] ${MODE} on $(hostname 2>/dev/null || id -un): exit $1 (${STATS_SITES_FAILED} failed)"
    if [ -n "$NOTIFY_WEBHOOK" ]; then
        if have curl; then
            printf '%s' "$payload" | curl -fsS --max-time "$NOTIFY_TIMEOUT" \
                -H 'Content-Type: application/json' --data-binary @- "$NOTIFY_WEBHOOK" >/dev/null 2>&1 ||
                log_note "the notification webhook did not accept the summary"
        else
            log_note 'curl is not available; the webhook notification was skipped'
        fi
    fi
    if [ -n "$MAIL_TO" ]; then
        if have mail; then
            printf '%s\n' "$payload" | mail -s "$subject" "$MAIL_TO" 2>/dev/null ||
                log_note 'mail(1) could not send the summary'
        else
            log_note 'mail(1) is not available; the mail notification was skipped'
        fi
    fi
    return 0
}

state_write() { # RC
    local rc="$1" f="${LOG_FILE}.state"
    [ -n "$LOG_FILE" ] || return 0
    {
        printf 'finished        : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'mode            : %s%s\n' "$MODE" "$([ "$DRY_RUN" = 'true' ] && printf ' (dry-run)')"
        printf 'version         : %s\n' "$SCRIPT_VERSION"
        printf 'exit code       : %s\n' "$rc"
        printf 'sites processed : %s\n' "$STATS_SITES_TOTAL"
        printf 'sites ok        : %s\n' "$STATS_SITES_OK"
        printf 'sites failed    : %s\n' "$STATS_SITES_FAILED"
        printf 'sites skipped   : %s\n' "$STATS_SITES_SKIPPED"
        printf 'operations ok   : %s\n' "$STATS_OPS_OK"
        printf 'operations fail : %s\n' "$STATS_OPS_FAILED"
        printf 'warnings        : %s\n' "$STATS_WARNINGS"
        printf 'retries         : %s\n' "$STATS_RETRIES"
        printf 'changes         : %s\n' "$STATS_CHANGES"
        printf 'aborted         : %s\n' "$ABORT"
        printf 'jobs            : %s\n' "$JOBS"
        printf 'backup          : %s\n' "$BACKUP_MODE"
        printf 'duration        : %ss\n' "$(( $(date +%s) - START_TIME ))"
        [ -n "$REPORT_FILE" ] && printf 'report          : %s\n' "$REPORT_FILE"
    } >"$f" 2>/dev/null
}

print_summary() { # RC
    local rc="$1" elapsed
    SUMMARY_PRINTED='true'
    elapsed="$(( $(date +%s) - START_TIME ))"
    state_write "$rc"
    report_write "$rc"
    notify_send "$rc"
    log_write_file info "summary: sites ${STATS_SITES_OK}/${STATS_SITES_TOTAL} ok, ${STATS_OPS_FAILED} failed operations, ${STATS_WARNINGS} warning(s), exit ${rc}, ${elapsed}s"
    if [ "$JSON_LINES" = 'true' ]; then
        emit_summary_json "$rc"
        return 0
    fi
    [ "$QUIET" = 'true' ] && return 0
    is_machine_format && return 0
    printf '\n%s%s%s\n' "$C_BOLD" "SUMMARY" "$C_RESET"
    printf -- '----------------------------------------------------------------------\n'
    local mode_label="$MODE"
    [ "$DRY_RUN" = 'true' ] && mode_label="${MODE} (dry-run)"
    printf '  %-22s %s\n' 'mode:' "$mode_label"
    printf '  %-22s %s\n' 'sites processed:' "$STATS_SITES_TOTAL"
    printf '  %-22s %s%s%s\n' 'sites ok:' "$C_GREEN" "$STATS_SITES_OK" "$C_RESET"
    printf '  %-22s %s%s%s\n' 'sites failed:' "$([ "$STATS_SITES_FAILED" -gt 0 ] && printf '%s' "$C_RED")" "$STATS_SITES_FAILED" "$C_RESET"
    printf '  %-22s %s\n' 'sites skipped:' "$STATS_SITES_SKIPPED"
    printf '  %-22s %s\n' 'operations ok:' "$STATS_OPS_OK"
    printf '  %-22s %s\n' 'operations failed:' "$STATS_OPS_FAILED"
    printf '  %-22s %s\n' 'warnings:' "$STATS_WARNINGS"
    ((STATS_RETRIES > 0)) && printf '  %-22s %s\n' 'retries:' "$STATS_RETRIES"
    ((STATS_CHANGES > 0)) && printf '  %-22s %s\n' 'changes applied:' "$STATS_CHANGES"
    [ "$ABORT" = 'true' ] && printf '  %-22s %srun aborted, remaining sites skipped%s\n' 'aborted:' "$C_YELLOW" "$C_RESET"
    [ -n "$REPORT_FILE" ] && printf '  %-22s %s\n' 'report:' "$REPORT_FILE"
    if ((JOBS > 1)); then
        printf '  %-22s %s\n' 'parallelism:' "${JOBS} sites per batch"
    fi
    if [ "$BACKUP_MODE" != 'off' ]; then
        printf '  %-22s %s\n' 'backup:' "${BACKUP_MODE} -> $(backup_dir_of) (keep ${KEEP_BACKUPS})"
    fi
    printf '  %-22s %s (%ss)\n' 'duration:' "$(human_duration "$elapsed")" "$elapsed"
    [ -n "$LOG_FILE" ] && printf '  %-22s %s\n' 'log:' "$LOG_FILE"
    [ -n "$ERROR_LOG_FILE" ] && printf '  %-22s %s\n' 'error log:' "$ERROR_LOG_FILE"
    printf -- '----------------------------------------------------------------------\n'
    if ((rc == 0)); then
        printf '%s✓ run finished without errors%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%s✗ run finished with errors (exit %s)%s\n' "$C_RED" "$rc" "$C_RESET"
    fi
}

# Decide the exit code from the counters, honouring --fail-on.
final_exit_code() {
    # --strict turns "it ran, but something smelled" into a non-zero exit, which
    # is what a pipeline needs: a warning about a stale lock or a skipped site is
    # invisible to cron otherwise. It is checked before the --fail-on policy,
    # because `--fail-on never --strict` has to mean "ignore site failures, but
    # not warnings" and not "ignore everything".
    if [ "$STRICT" = 'true' ] && ((STATS_WARNINGS > 0)); then
        log_warn "--strict: ${STATS_WARNINGS} warning(s) make this run a failure"
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

###############################################################################
# 16. Help
###############################################################################

usage() { # [EXIT_CODE]
    local rc="${1:-$EXIT_USAGE}"
    cat <<EOF
${C_BOLD}${PROG_NAME} ${SCRIPT_VERSION}${C_RESET} - WordPress maintenance automation via WP-CLI

Usage:
  ${PROG_NAME} <MODE> [options]
  ${PROG_NAME} --check [--site PATH]
  ${PROG_NAME} --status
  ${PROG_NAME} --list-modes

${C_BOLD}Modes (exactly one):${C_RESET}
  -f, --full             core + plugins + themes + database + cron (+ Astra if licensed)
  -c, --core             core update and database schema update
  -p, --plugins          update all plugins
  -t, --themes           update all themes
  -d, --db-optimize      db optimize and db repair
  -x, --db-fix           db repair only
  -r, --cron             run due cron events
  -s, --astra            update ${DEFAULT_ASTRA_SLUG}, activating the licence if needed
  -l, --list-plugins     list plugins (table, json, csv or tsv)
  -m, --plugin-manage    activate, deactivate or delete one plugin
      --verify           read-only checksum verification of core and plugins
      --health           read-only inventory: core version, pending plugin and theme
                         updates, database size (safe for monitoring)
      --secrets          read-only scan of wp-config.php: secret constant names are
                         listed, the values never are; world-readable files fail
      --list-backups     list the backups this tool has written for each site
      --restore-db FILE  import FILE into the database of each site; --yes is
                         mandatory and a fresh dump is taken first
      --check            validate the environment and every site, change nothing
      --status           print the last run summary and the log sizes
      --doctor           diagnose the host (tools, paths, permissions) and exit
      --completion SH    print a completion script for bash or zsh
      --list-sites       print the resolved site list and exit
      --list-modes       print the mode names, one per line (for shell completion)

${C_BOLD}Selection:${C_RESET}
  -S, --site PATH        operate on one site only (overrides the site list)
      --sites FILE       site list, one absolute path per line (default: ${DEFAULT_SITES_FILE})
      --max-sites N      process at most N sites (0 = all, default ${DEFAULT_MAX_SITES})
  -u, --user NAME        force the system user for every site (skips owner detection)
      --default-user NAME
                         fall back to NAME when ownership cannot be determined
      --skip-if-no-updates
                         ask first, act second: skip a site whose core, plugins and
                         themes are already current (--core/--plugins/--themes/--full)
  -j, --jobs N           process N sites in parallel batches (default ${DEFAULT_JOBS} = sequential)
  -U, --url URL          pass --url to WP-CLI on every call (multisite)

${C_BOLD}Plugin management:${C_RESET}
  -A, --action ACTION    activate | deactivate | delete   (for --plugin-manage)
  -N, --name NAME        plugin name or slug; case-insensitive substring, never a pattern
  -F, --force            skip the delete confirmation
  -y, --yes              same as --force, for scripted use
      --only-active      with --plugins/--full: update only active plugins that
                         have an update available (enumerated, not --all)
  -e, --exclude-plugins LIST
                         comma separated slugs or names to leave out of
                         --plugins/--full; implies enumeration
      --exclude-themes LIST
                         comma separated themes to leave out of --themes/--full
      --hold-plugins LIST
                         plugins that are never updated (a pin, not a filter:
                         the log says so)
      --hold-themes LIST themes that are never updated

${C_BOLD}Output:${C_RESET}
      --format FMT       table | json | csv | tsv   (default: ${DEFAULT_OUTPUT_FORMAT})
      --json-lines       fleet report as JSON Lines: one object per site plus a
                         summary object (implied by -J outside --list-plugins)
      --report FILE      write a JSON run report (sites, counters, what changed)
      --json-log         write one JSON object per log line (for a log shipper)
      --fields LIST      comma separated columns for --list-plugins
                         (default: ${PLUGIN_FIELDS_DEFAULT})
      --page-limit N     rows per table (0 = all, default 0)
  -J, --json             shorthand for --format json
      --color WHEN       auto | always | never (default: ${DEFAULT_COLOR})
      --no-color         same as --color never
      --quiet            console shows warnings and errors only
  -D, --debug            verbose logging; implies --log-level debug
  -v, --verbose          show the commands as they are executed

${C_BOLD}Backups:${C_RESET}
  -b, --backup MODE      off | db | full (default: ${DEFAULT_BACKUP})
                           db    'wp db export' before the site is touched
                           full  tar.gz of the whole installation -- slow and big
      --no-backup        never back up, including before a plugin delete
  -B, --backup-dir DIR   where to put backups (default: <script dir>/backups)
      --keep-backups N   backups kept per site (0 = keep everything, default ${DEFAULT_KEEP_BACKUPS})
      --backup-age-days N
                         also drop backups older than N days (0 = never, default 0)
      --backup-compress  gzip a database dump after the export
      --min-free-mb N    refuse to write a dump when the filesystem has less than N
                         MiB free (0 = no guard, default 0; 200 is a good production value)

${C_BOLD}Safety:${C_RESET}
  -n, --dry-run          show what would run, execute nothing
      --no-user-switch   run WP-CLI as the invoking user instead of switching
                         into the site owner (single-site hosts, and test suites)
      --strict           exit non-zero when anything was warned about
      --timeout SEC      per-command timeout, 0 disables (default ${DEFAULT_TIMEOUT})
      --signal SIG       timeout signal: HUP INT QUIT TERM USR1 USR2 KILL (default ${DEFAULT_TIMEOUT_SIGNAL})
      --kill-after SEC   escalate to KILL after SEC (default ${DEFAULT_KILL_AFTER})
      --allow-root WHEN  auto | always | never (default: ${DEFAULT_ALLOW_ROOT})
      --skip-plugins L   plugins to skip on plugin/theme operations ('' disables)
      --skip-plugins-for-listing on|off
                         also pass --skip-plugins to list commands (default off)
      --fail-on WHEN     any | all | never - when to exit non-zero (default ${DEFAULT_FAIL_ON})
      --no-lock          do not take the lock (only for nested or manual runs)
      --no-discover      do not run the finder when the site list is missing

${C_BOLD}Fleet control:${C_RESET}
      --retry N          re-run a failed site up to N extra times (default ${DEFAULT_RETRY})
      --retry-delay SEC  wait SEC seconds between attempts (default ${DEFAULT_RETRY_DELAY})
      --max-failures N   stop the run after N failed sites (0 = never, default ${DEFAULT_MAX_FAILURES})
      --run-timeout SEC  total time budget for the whole run (0 = none, default ${DEFAULT_RUN_TIMEOUT})
      --lock-wait SEC    wait up to SEC seconds for another run's lock (default ${DEFAULT_LOCK_WAIT})
      --nice N           run wp at this niceness, 0 = off (default ${DEFAULT_NICE_LEVEL})
      --ionice CLASS     idle | best-effort | none (default ${DEFAULT_IONICE_CLASS})
      --no-url-detect    never derive --url from wp-config.php

${C_BOLD}Notifications:${C_RESET}
      --notify URL       POST a JSON summary to URL (needs curl)
      --notify-on WHEN   never | failure | always (default ${DEFAULT_NOTIFY_ON})
      --mail-to ADDR     also mail the summary (needs a working mail(1))
      --no-notify        disable every notification for this run

${C_BOLD}Configuration:${C_RESET}
  -C, --config FILE      read settings from FILE (default: ${CONFIG_LOCAL} or ${CONFIG_GLOBAL})
      --print-config     show the effective settings and where each came from, then exit
      --astra-key KEY    Astra licence; prefer WP_CLI_UPDATE_LICENCE or a key file
      --astra-slug SLUG  Astra add-on slug (default: ${DEFAULT_ASTRA_SLUG})
      --log-file FILE    main log (default: ${DEFAULT_LOG_FILE})
      --error-log-file FILE
  -L, --log-dir DIR      put manager.log and errors.log in DIR
      --lock-file FILE   (default: ${DEFAULT_LOCK_FILE})
      --log-level LVL    debug | info | warn | error (default: ${DEFAULT_LOG_LEVEL})
      --wp PATH          path to the wp binary (default: ${DEFAULT_WP_CLI_PATH})
      --wp-bin, --wp-cli accepted aliases of --wp
      --user-env LIST    space separated variables to pass through to the site user
      --sites-file FILE  accepted alias of --sites

${C_BOLD}Other:${C_RESET}
  -h, --help             this help, exit 0
  -V, --version          print the version, exit 0

${C_BOLD}Values:${C_RESET}
  Every option that takes a value accepts both spellings: --timeout 600 and
  --timeout=600. The two-argument form is what the examples use because it reads
  well in a runbook; the equals form is what people type from memory.

${C_BOLD}Exit codes:${C_RESET}
  0 success   1 operational error   2 usage error   3 environment error   4 config error
  130 interrupted (SIGINT)   143 terminated (SIGTERM)   131 hangup (SIGHUP)

${C_BOLD}Configuration precedence:${C_RESET}
  built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf
                    < WP_CLI_UPDATE_* environment < command line

${C_BOLD}Licence handling:${C_RESET}
  The Astra licence is never passed as an argument. It is written to a temporary
  file and read by the child shell at run time, so it appears neither in ps output
  nor in a log line nor in the report. The value comes from WP_CLI_UPDATE_LICENCE,
  ASTRA_KEY or ASTRA_LICENSE_KEY, or from the first readable file among ./astra.key,
  /etc/wp-cli-update/astra.key and \$HOME/.astra.key.

${C_BOLD}Parallelism:${C_RESET}
  -j N runs the fleet in batches of N. Bash 4.2 has no 'wait -n', so this is a
  batch barrier, not a continuous pool: the next batch starts when the slowest
  site of the current one finishes. Per-site console output and log lines are
  buffered and replayed in site order after each barrier, so neither interleaves.
  The consequence worth remembering: during a parallel run the log file grows at
  the barrier, not while the work happens, so 'tail -f' looks stalled until the
  batch lands.

${C_BOLD}Examples:${C_RESET}
  ${PROG_NAME} --full
  ${PROG_NAME} --full -j 4 --backup db --keep-backups 2
  ${PROG_NAME} -p --only-active -e 'jetpack,woocommerce' -j 8
  ${PROG_NAME} --verify --strict --json-lines
  ${PROG_NAME} --list-sites
  ${PROG_NAME} -p --site /var/www/example.com
  ${PROG_NAME} -l --name woo --format csv
  ${PROG_NAME} -l --format json --fields name,slug,update,version
  ${PROG_NAME} -m -A deactivate -N jetpack -S /var/www/example.com -y
  ${PROG_NAME} -d --dry-run --timeout 120
  ${PROG_NAME} --check
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

list_modes() {
    printf '%s\n' full core plugins themes db-optimize db-fix cron astra \
        list-plugins plugin-manage verify check status health secrets doctor \
        list-sites list-backups restore-db completion
}

# effective_source KEY: which layer actually decided the value. Without this the
# FROM column would name the config file even when the command line won.
effective_source() { # KEY
    local key="$1" src
    if [ -n "${CLI_SET[$key]-}" ]; then
        printf 'command line'
        return 0
    fi
    src="${CONF_SRC[$key]-default}"
    case "$src" in
        env) printf 'environment' ;;
        *) printf '%s' "$src" ;;
    esac
}

print_config() {
    # Show the *effective* value next to the layer that produced it. Printing
    # only the config-layer table (the first attempt) reads like a precedence bug
    # even when the effective value is correct, and nobody wants that ambiguity
    # at 3 a.m. on a production host.
    local -a names=(
        WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE
        LOG_MAX_BYTES LOG_KEEP LOG_LEVEL ERROR_OUTPUT_LINES COLOR SKIP_PLUGINS
        SKIP_PLUGINS_FOR_LISTING ALLOW_ROOT TIMEOUT KILL_AFTER TIMEOUT_SIGNAL
        FAIL_ON ASTRA_SLUG MAX_SITES AUTO_DISCOVER USER_ENV
        JOBS BACKUP KEEP_BACKUPS BACKUP_DIR EXCLUDE_PLUGINS ONLY_ACTIVE STRICT
        NO_USER_SWITCH URL
        EXCLUDE_THEMES HOLD_PLUGINS HOLD_THEMES NICE_LEVEL IONICE_CLASS MIN_FREE_MB
        RETRY RETRY_DELAY MAX_FAILURES RUN_TIMEOUT LOCK_WAIT BACKUP_AGE_DAYS
        BACKUP_COMPRESS DEFAULT_USER NOTIFY_WEBHOOK NOTIFY_ON NOTIFY_TIMEOUT MAIL_TO
        REPORT_FILE LOG_JSON SKIP_IF_NO_UPDATES URL_DETECT WP_GLOBAL_ARGS
    )
    local -a vars=(
        WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE
        LOG_MAX_BYTES LOG_KEEP LOG_LEVEL ERROR_OUTPUT_LINES COLOR_MODE SKIP_PLUGINS
        SKIP_PLUGINS_FOR_LISTING ALLOW_ROOT_FLAG WP_COMMAND_TIMEOUT KILL_AFTER
        TIMEOUT_SIGNAL FAIL_ON ASTRA_SLUG MAX_SITES AUTO_DISCOVER USER_ENV_LIST
        JOBS BACKUP_MODE KEEP_BACKUPS BACKUP_DIR EXCLUDE_PLUGINS ONLY_ACTIVE STRICT
        NO_USER_SWITCH SITE_URL
        EXCLUDE_THEMES HOLD_PLUGINS HOLD_THEMES NICE_LEVEL IONICE_CLASS MIN_FREE_MB
        RETRY RETRY_DELAY MAX_FAILURES RUN_TIMEOUT LOCK_WAIT BACKUP_AGE_DAYS
        BACKUP_COMPRESS DEFAULT_USER NOTIFY_WEBHOOK NOTIFY_ON NOTIFY_TIMEOUT MAIL_TO
        REPORT_FILE LOG_JSON SKIP_IF_NO_UPDATES URL_DETECT WP_GLOBAL_ARGS
    )
    local i value
    printf '\n%-24s %-34s %-14s %s\n' 'SETTING' 'EFFECTIVE VALUE' 'FROM' 'CLI OVERRIDE'
    printf -- '--------------------------------------------------------------------------------\n'
    for ((i = 0; i < ${#names[@]}; i++)); do
        value="${!vars[i]}"
        [ -n "$value" ] || value='<empty>'
        printf '%-24s %-34s %-14s %s\n' "${names[i]}" "$value" \
            "$(effective_source "${names[i]}")" \
            "$([ -n "${CLI_SET[${names[i]}]-}" ] && printf 'yes' || printf '-')"
    done
    printf '%-24s %-34s %-14s %s\n' 'LICENCE' \
        "$([ -n "$LICENCE_VALUE" ] && printf '<set, %s characters>' "${#LICENCE_VALUE}" || printf '<unset>')" \
        "$(effective_source LICENCE)" \
        "$([ -n "${CLI_SET[LICENCE]-}" ] && printf 'yes' || printf '-')"
    printf -- '--------------------------------------------------------------------------------\n'
    printf 'config file used  : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'precedence        : defaults < file < environment (WP_CLI_UPDATE_*) < command line\n'
    printf 'mode              : %s\n' "${MODE:-<none>}"
    printf 'dry-run           : %s\n' "$DRY_RUN"
    local lock_desc="$LOCK_FILE"
    [ "$NO_LOCK" = 'true' ] && lock_desc='disabled by --no-lock'
    printf 'lock              : %s\n' "$lock_desc"
    printf '\n'
}

###############################################################################
# 17. Argument parsing
###############################################################################

MODES_SEEN=0

set_mode() { # NAME
    if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        usage_error "conflicting modes: --${MODE} and --${1}; pass exactly one"
    fi
    MODE="$1"
    MODES_SEEN=$((MODES_SEEN + 1))
}

# need_value OPTION [VALUE] -> sets OPT_VALUE.
#
# It does not print the value for `$(...)` capture on purpose: usage_error exits,
# and an exit inside a command substitution only leaves the subshell, so the
# caller would continue with an empty value. That single detail turned
# "--sites" with no argument into a run against the default paths.
OPT_VALUE=''
need_value() { # OPTION [VALUE]
    if [ -z "${2:-}" ]; then
        usage_error "${1} requires a value"
    fi
    OPT_VALUE="$2"
    return 0
}

USER_OVERRIDE=''
NO_LOCK='false'

parse_args() {
    local arg
    while (($# > 0)); do
        arg="$1"
        # GNU spelling: --option=value is accepted exactly like --option value.
        # The value is inserted as the next positional parameter and the option's own
        # `shift` consumes it, so every option behaves the same in both spellings.
        case "$arg" in
            --?*=*)
                local opt="${arg%%=*}" val="${arg#*=}"
                set -- "$opt" "$val" "${@:2}"
                arg="$1"
                ;;
        esac
        case "$arg" in
            # ---- modes -------------------------------------------------
            -f | --full) set_mode full; CLI_SET[MODE]=1 ;;
            -c | --core) set_mode core; CLI_SET[MODE]=1 ;;
            -p | --plugins) set_mode plugins; CLI_SET[MODE]=1 ;;
            -t | --themes) set_mode themes; CLI_SET[MODE]=1 ;;
            -d | --db-optimize) set_mode db-optimize; CLI_SET[MODE]=1 ;;
            -x | --db-fix) set_mode db-fix; CLI_SET[MODE]=1 ;;
            -r | --cron) set_mode cron; CLI_SET[MODE]=1 ;;
            -s | --astra) set_mode astra; CLI_SET[MODE]=1 ;;
            -l | --list-plugins) set_mode list-plugins; CLI_SET[MODE]=1 ;;
            -m | --plugin-manage) set_mode plugin-manage; CLI_SET[MODE]=1 ;;
            --verify) set_mode verify; CLI_SET[MODE]=1 ;;
            --health) set_mode health; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --secrets) set_mode secrets; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --list-backups) set_mode list-backups; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --restore-db)
                set_mode restore-db
                need_value "$arg" "${2:-}"
                RESTORE_SOURCE="$OPT_VALUE"
                shift
                CLI_SET[MODE]=1
                ;;
            --check) set_mode check; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --status) set_mode status; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --list-modes) LIST_MODES='true' ;;
            --doctor) DOCTOR='true' ;;
            --completion)
                need_value "$arg" "${2:-}"
                COMPLETION_SHELL="${OPT_VALUE,,}"
                shift
                ;;
            # ---- selection ---------------------------------------------
            -S | --site) need_value "$arg" "${2:-}"; TARGET_SITE="$OPT_VALUE"; shift; CLI_SET[SITES_FILE]=1 ;;
            --sites | --sites-file)
                need_value "$arg" "${2:-}"; SITES_FILE="$OPT_VALUE"; shift; CLI_SET[SITES_FILE]=1 ;;
            --max-sites) need_value "$arg" "${2:-}"; MAX_SITES="$OPT_VALUE"; shift; CLI_SET[MAX_SITES]=1 ;;
            -j | --jobs) need_value "$arg" "${2:-}"; JOBS="$OPT_VALUE"; shift; CLI_SET[JOBS]=1 ;;
            -U | --url) need_value "$arg" "${2:-}"; SITE_URL="$OPT_VALUE"; shift; CLI_SET[URL]=1 ;;
            --user | -u) need_value "$arg" "${2:-}"; USER_OVERRIDE="$OPT_VALUE"; shift ;;
            --default-user) need_value "$arg" "${2:-}"; DEFAULT_USER="$OPT_VALUE"; shift; CLI_SET[DEFAULT_USER]=1 ;;
            # ---- plugin management -------------------------------------
            -A | --action) need_value "$arg" "${2:-}"; PLUGIN_ACTION="${OPT_VALUE,,}"; shift ;;
            -N | --name) need_value "$arg" "${2:-}"; PLUGIN_NAME="$OPT_VALUE"; FILTER_NAME="$OPT_VALUE"; shift ;;
            -F | --force) FORCE_DELETE='true' ;;
            -y | --yes) ASSUME_YES='true' ;;
            # ---- output ------------------------------------------------
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift ;;
            --fields) need_value "$arg" "${2:-}"; FILTER_FIELDS="$OPT_VALUE"; shift ;;
            --page-limit) need_value "$arg" "${2:-}"; PAGE_LIMIT="$OPT_VALUE"; shift ;;
            -J | --json)
                # Two meanings, both wanted: with --list-plugins this selects the
                # plugin-list format, in a fleet mode it switches the report to
                # JSON Lines (one object per site plus a summary). The mode may
                # not have been parsed yet -- `--json -l` is as legal as `-l
                # --json` -- so the decision is deferred to validate_args.
                JSON_REQUESTED='true'
                ;;
            --json-lines) JSON_LINES='true' ;;
            --color) need_value "$arg" "${2:-}"; COLOR_MODE="${OPT_VALUE,,}"; shift; CLI_SET[COLOR]=1 ;;
            --no-color) COLOR_MODE='never'; CLI_SET[COLOR]=1 ;;
            --quiet | -q) QUIET='true' ;;
            -D | --debug) VERBOSE='true'; LOG_LEVEL='debug'; CLI_SET[LOG_LEVEL]=1 ;;
            -v | --verbose) VERBOSE='true' ;;
            # ---- safety ------------------------------------------------
            -n | --dry-run) DRY_RUN='true' ;;
            --timeout | -T) need_value "$arg" "${2:-}"; WP_COMMAND_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[TIMEOUT]=1 ;;
            --signal) need_value "$arg" "${2:-}"; TIMEOUT_SIGNAL="${OPT_VALUE^^}"; shift; CLI_SET[TIMEOUT_SIGNAL]=1 ;;
            --kill-after) need_value "$arg" "${2:-}"; KILL_AFTER="$OPT_VALUE"; shift; CLI_SET[KILL_AFTER]=1 ;;
            --allow-root) need_value "$arg" "${2:-}"; ALLOW_ROOT_FLAG="${OPT_VALUE,,}"; shift; CLI_SET[ALLOW_ROOT]=1 ;;
            --skip-plugins | -k) SKIP_PLUGINS="${2-}"; shift; CLI_SET[SKIP_PLUGINS]=1 ;;
            --skip-plugins-for-listing)
                need_value "$arg" "${2:-}"
                SKIP_PLUGINS_FOR_LISTING="${OPT_VALUE,,}"
                shift; CLI_SET[SKIP_PLUGINS_FOR_LISTING]=1 ;;
            --fail-on) need_value "$arg" "${2:-}"; FAIL_ON="${OPT_VALUE,,}"; shift; CLI_SET[FAIL_ON]=1 ;;
            -b | --backup) need_value "$arg" "${2:-}"; BACKUP_MODE="${OPT_VALUE,,}"; shift; CLI_SET[BACKUP]=1 ;;
            --no-backup) BACKUP_MODE='off'; NO_BACKUP_EXPLICIT='true'; CLI_SET[BACKUP]=1 ;;
            -B | --backup-dir) need_value "$arg" "${2:-}"; BACKUP_DIR="$OPT_VALUE"; shift; CLI_SET[BACKUP_DIR]=1 ;;
            --keep-backups) need_value "$arg" "${2:-}"; KEEP_BACKUPS="$OPT_VALUE"; shift; CLI_SET[KEEP_BACKUPS]=1 ;;
            -e | --exclude-plugins) need_value "$arg" "${2:-}"; EXCLUDE_PLUGINS="$OPT_VALUE"; shift; CLI_SET[EXCLUDE_PLUGINS]=1 ;;
            --exclude-themes) need_value "$arg" "${2:-}"; EXCLUDE_THEMES="$OPT_VALUE"; shift; CLI_SET[EXCLUDE_THEMES]=1 ;;
            --hold-plugins) need_value "$arg" "${2:-}"; HOLD_PLUGINS="$OPT_VALUE"; shift; CLI_SET[HOLD_PLUGINS]=1 ;;
            --hold-themes) need_value "$arg" "${2:-}"; HOLD_THEMES="$OPT_VALUE"; shift; CLI_SET[HOLD_THEMES]=1 ;;
            --skip-if-no-updates) SKIP_IF_NO_UPDATES='true'; CLI_SET[SKIP_IF_NO_UPDATES]=1 ;;
            # ---- fleet controls -----------------------------------------
            --retry) need_value "$arg" "${2:-}"; RETRY="$OPT_VALUE"; shift; CLI_SET[RETRY]=1 ;;
            --retry-delay) need_value "$arg" "${2:-}"; RETRY_DELAY="$OPT_VALUE"; shift; CLI_SET[RETRY_DELAY]=1 ;;
            --max-failures) need_value "$arg" "${2:-}"; MAX_FAILURES="$OPT_VALUE"; shift; CLI_SET[MAX_FAILURES]=1 ;;
            --run-timeout) need_value "$arg" "${2:-}"; RUN_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[RUN_TIMEOUT]=1 ;;
            --lock-wait) need_value "$arg" "${2:-}"; LOCK_WAIT="$OPT_VALUE"; shift; CLI_SET[LOCK_WAIT]=1 ;;
            --min-free-mb) need_value "$arg" "${2:-}"; MIN_FREE_MB="$OPT_VALUE"; shift; CLI_SET[MIN_FREE_MB]=1 ;;
            --nice) need_value "$arg" "${2:-}"; NICE_LEVEL="$OPT_VALUE"; shift; CLI_SET[NICE_LEVEL]=1 ;;
            --ionice) need_value "$arg" "${2:-}"; IONICE_CLASS="${OPT_VALUE,,}"; shift; CLI_SET[IONICE_CLASS]=1 ;;
            --backup-age-days) need_value "$arg" "${2:-}"; BACKUP_AGE_DAYS="$OPT_VALUE"; shift; CLI_SET[BACKUP_AGE_DAYS]=1 ;;
            --backup-compress) BACKUP_COMPRESS='true'; CLI_SET[BACKUP_COMPRESS]=1 ;;
            --report) need_value "$arg" "${2:-}"; REPORT_FILE="$OPT_VALUE"; shift; CLI_SET[REPORT_FILE]=1 ;;
            --json-log) LOG_JSON='true'; CLI_SET[LOG_JSON]=1 ;;
            --no-url-detect) URL_DETECT='false'; CLI_SET[URL_DETECT]=1 ;;
            --notify) need_value "$arg" "${2:-}"; NOTIFY_WEBHOOK="$OPT_VALUE"; shift; CLI_SET[NOTIFY_WEBHOOK]=1 ;;
            --notify-on) need_value "$arg" "${2:-}"; NOTIFY_ON="${OPT_VALUE,,}"; shift; CLI_SET[NOTIFY_ON]=1 ;;
            --mail-to) need_value "$arg" "${2:-}"; MAIL_TO="$OPT_VALUE"; shift; CLI_SET[MAIL_TO]=1 ;;
            --no-notify) NOTIFY_WEBHOOK=''; MAIL_TO=''; NOTIFY_ON='never'; CLI_SET[NOTIFY_ON]=1 ;;
            --only-active) ONLY_ACTIVE='true'; CLI_SET[ONLY_ACTIVE]=1 ;;
            --strict) STRICT='true'; CLI_SET[STRICT]=1 ;;
            --no-user-switch) NO_USER_SWITCH='true'; CLI_SET[NO_USER_SWITCH]=1 ;;
            --list-sites) LIST_SITES='true' ;;
            --no-lock) NO_LOCK='true' ;;
            --no-discover) AUTO_DISCOVER='false'; CLI_SET[AUTO_DISCOVER]=1 ;;
            # ---- configuration -----------------------------------------
            --config | -C) need_value "$arg" "${2:-}"; CONFIG_REQUESTED="$OPT_VALUE"; shift ;;
            --print-config) PRINT_CONFIG='true' ;;
            --astra-key) need_value "$arg" "${2:-}"; LICENCE_VALUE="$OPT_VALUE"; CLI_SET[LICENCE]=1; shift ;;
            --astra-slug) need_value "$arg" "${2:-}"; ASTRA_SLUG="$OPT_VALUE"; shift; CLI_SET[ASTRA_SLUG]=1 ;;
            --wp | --wp-cli | --wp-bin) need_value "$arg" "${2:-}"; WP_CLI_PATH="$OPT_VALUE"; shift; CLI_SET[WP_CLI_PATH]=1 ;;
            --log-dir | -L)
                need_value "$arg" "${2:-}"
                if [ -z "${CLI_SET[LOG_FILE]-}" ]; then
                    LOG_FILE="${OPT_VALUE%/}/manager.log"
                    CLI_SET[LOG_FILE]=1
                fi
                if [ -z "${CLI_SET[ERROR_LOG_FILE]-}" ]; then
                    ERROR_LOG_FILE="${OPT_VALUE%/}/errors.log"
                    CLI_SET[ERROR_LOG_FILE]=1
                fi
                shift
                ;;
            --log-file) need_value "$arg" "${2:-}"; LOG_FILE="$OPT_VALUE"; shift; CLI_SET[LOG_FILE]=1 ;;
            --error-log-file) need_value "$arg" "${2:-}"; ERROR_LOG_FILE="$OPT_VALUE"; shift; CLI_SET[ERROR_LOG_FILE]=1 ;;
            --lock-file) need_value "$arg" "${2:-}"; LOCK_FILE="$OPT_VALUE"; shift; CLI_SET[LOCK_FILE]=1 ;;
            --log-level) need_value "$arg" "${2:-}"; LOG_LEVEL="${OPT_VALUE,,}"; shift; CLI_SET[LOG_LEVEL]=1 ;;
            --user-env) need_value "$arg" "${2:-}"; USER_ENV_LIST="$OPT_VALUE"; shift; CLI_SET[USER_ENV]=1 ;;
            # ---- misc ---------------------------------------------------
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) version_info; exit "$EXIT_OK" ;;
            --) shift; break ;;
            -*) usage_error "unknown option: ${arg} (try --help)" ;;
            *) usage_error "unexpected argument: ${arg} (a mode is required, try --help)" ;;
        esac
        shift
    done
    if (($# > 0)); then
        usage_error "unexpected trailing arguments: $*"
    fi
}

PRINT_CONFIG='false'
LIST_SITES='false'
JSON_REQUESTED='false'
DOCTOR='false'
WORKER_DIR=''
NO_BACKUP_EXPLICIT='false'

validate_args() {
    case "$OUTPUT_FORMAT" in
        table | json | csv | tsv) ;;
        *) usage_error "--format must be one of: table, json, csv, tsv (got '${OUTPUT_FORMAT}')" ;;
    esac
    [[ "$PAGE_LIMIT" =~ ^[0-9]+$ ]] || usage_error "--page-limit must be a non-negative integer"
    [[ "$MAX_SITES" =~ ^[0-9]+$ ]] || usage_error "--max-sites must be a non-negative integer (got '${MAX_SITES}')"
    [[ "$WP_COMMAND_TIMEOUT" =~ ^[0-9]+$ ]] || usage_error "--timeout must be a non-negative integer (got '${WP_COMMAND_TIMEOUT}')"
    if ! [[ "$KILL_AFTER" =~ ^[0-9]+$ ]] || ((KILL_AFTER == 0)); then
        usage_error "--kill-after must be a positive integer (got '${KILL_AFTER}')"
    fi
    require_choice LOG_LEVEL "$LOG_LEVEL" debug info warn error
    require_choice COLOR "$COLOR_MODE" auto always never
    require_choice ALLOW_ROOT "$ALLOW_ROOT_FLAG" auto always never
    require_choice FAIL_ON "$FAIL_ON" any all never
    require_choice TIMEOUT_SIGNAL "$TIMEOUT_SIGNAL" HUP INT QUIT TERM USR1 USR2 KILL
    SKIP_PLUGINS_FOR_LISTING="$(require_bool SKIP_PLUGINS_FOR_LISTING "$SKIP_PLUGINS_FOR_LISTING")"
    AUTO_DISCOVER="$(require_bool AUTO_DISCOVER "$AUTO_DISCOVER")"
    if [ -n "$PLUGIN_ACTION" ]; then
        case "$PLUGIN_ACTION" in
            activate | deactivate | delete) ;;
            *) usage_error "--action must be one of: activate, deactivate, delete (got '${PLUGIN_ACTION}')" ;;
        esac
    fi
    case "$BACKUP_MODE" in
        off | db | full) ;;
        *) usage_error "--backup must be one of: off, db, full (got '${BACKUP_MODE}')" ;;
    esac
    if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || ((JOBS < 1)); then
        usage_error "--jobs must be an integer >= 1 (got '${JOBS}')"
    fi
    if ! [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]]; then
        usage_error "--keep-backups must be a non-negative integer (got '${KEEP_BACKUPS}')"
    fi
    if [ -n "$DEFAULT_USER" ] && ! id -u "$DEFAULT_USER" >/dev/null 2>&1; then
        usage_error "--default-user ${DEFAULT_USER}: no such system user"
    fi
    # Mode-restricted options. An explicit flag with the wrong mode is a mistake in the
    # command line and is reported; the same value arriving from a configuration file is
    # inert for this mode and is ignored. The distinction matters: the recommended
    # production profile sets SKIP_IF_NO_UPDATES=1, and validating it unconditionally
    # made --doctor, --check, --health and --status fail with a usage error on a host
    # that was configured exactly as the documentation says.
    if [ "${CLI_SET[ONLY_ACTIVE]-}" = 1 ] || [ "${CLI_SET[EXCLUDE_PLUGINS]-}" = 1 ] || [ "${CLI_SET[HOLD_PLUGINS]-}" = 1 ]; then
        case "$MODE" in
            plugins | full) ;;
            *) usage_error '--only-active, --exclude-plugins and --hold-plugins only apply to --plugins and --full' ;;
        esac
    fi
    if [ "${CLI_SET[EXCLUDE_THEMES]-}" = 1 ] || [ "${CLI_SET[HOLD_THEMES]-}" = 1 ]; then
        case "$MODE" in
            themes | full) ;;
            *) usage_error '--exclude-themes and --hold-themes only apply to --themes and --full' ;;
        esac
    fi
    if [ "${CLI_SET[SKIP_IF_NO_UPDATES]-}" = 1 ]; then
        case "$MODE" in
            core | plugins | themes | full) ;;
            *) usage_error '--skip-if-no-updates only applies to --core, --plugins, --themes and --full' ;;
        esac
    fi
    if [ -n "$COMPLETION_SHELL" ]; then
        case "$COMPLETION_SHELL" in
            bash | zsh) ;;
            *) usage_error "--completion must be bash or zsh (got '${COMPLETION_SHELL}')" ;;
        esac
    fi
    # Resolve the dual meaning of -J now that every mode flag has been seen.
    if [ "$JSON_REQUESTED" = 'true' ]; then
        if [ "$MODE" = 'list-plugins' ]; then
            OUTPUT_FORMAT='json'
        else
            JSON_LINES='true'
        fi
    fi
    if [ "$LIST_MODES" = 'true' ] || [ "$LIST_SITES" = 'true' ] || [ "$DOCTOR" = 'true' ] ||
       [ -n "$COMPLETION_SHELL" ]; then return 0; fi
    if [ -z "$MODE" ]; then
        usage_error 'no mode given; pass one of --full, --core, --plugins, --themes, --db-optimize, --db-fix, --cron, --astra, --list-plugins, --plugin-manage, --verify, --health, --secrets, --list-backups, --restore-db, --check, --status, --doctor (try --help)'
    fi
    if [ "$MODE" = 'restore-db' ]; then
        [ -n "$RESTORE_SOURCE" ] || usage_error '--restore-db requires a file (for example --restore-db /var/backups/db-20261021-030000.sql)'
        if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
            log_warn '--restore-db overwrites the live database: every site will be refused until you add --yes'
        fi
    fi
    if [ "$MODE" = 'plugin-manage' ]; then
        [ -n "$PLUGIN_ACTION" ] || usage_error '--plugin-manage requires --action activate|deactivate|delete'
        [ -n "$PLUGIN_NAME" ] || usage_error '--plugin-manage requires --name NAME'
        if [ "$PLUGIN_ACTION" = 'delete' ] && [ "$FORCE_DELETE" != 'true' ] &&
           [ "$ASSUME_YES" != 'true' ] && [ ! -t 0 ]; then
            log_warn 'delete without --yes in a non-interactive shell will be refused per site'
        fi
    fi
    if [ "$MODE" = 'list-plugins' ] && [ -n "$PLUGIN_ACTION" ]; then
        usage_error '--action is meaningless for --list-plugins'
    fi
    return 0
}

###############################################################################
# 18. Fleet execution: sequential and parallel
###############################################################################

# Parallelism is batched, not a continuous pool: bash 4.2 has no `wait -n`, so a
# pool would need a job server and a fifo. A batch barrier is one `wait`, and on
# a fleet of similar sites the difference is a few seconds. This is the same
# trade-off SagaAI made and it is the right one for the stated bash floor.
#
# Four things have to survive the fork, and none of them survives by itself:
#
#   1. Counters. A subshell cannot increment a parent variable, so every worker
#      writes its own numbers to files and the parent folds them in. Reading a
#      counter inside the subshell -- what an earlier draft did -- reports the
#      value from before the site started.
#   2. Console output. Interleaved lines from concurrent sites are unreadable,
#      so a worker writes to its own fragment and the parent replays the
#      fragments in site order after the barrier.
#   3. Log lines. The same problem, worse: the log file is shared. In parallel
#      mode log() writes to the worker fragment instead of appending to the file,
#      and the parent appends the fragments in order after the barrier. The log
#      therefore stays grouped per site -- but it is written after the batch
#      finishes, which is why `tail -f` shows nothing during a parallel run.
#   4. Data output. `--list-plugins --format json` must stay parseable, so in
#      parallel mode it is emitted by the parent during the ordered replay, not
#      by the workers.
WORK_DIR=''
PARALLEL='false'
declare -A SITE_STATUS=()

worker_dir() { printf '%s/w%s' "$WORK_DIR" "$1"; }

worker_init() { # SITE_INDEX
    local d
    d="$(worker_dir "$1")"
    mkdir -p -- "$d" || return 1
    : >"${d}/out"
    : >"${d}/log"
    return 0
}

read_counter() { # FILE
    local v=''
    if [ -r "${1:-}" ]; then
        v="$(head -n 1 -- "$1" 2>/dev/null)"
    fi
    v="${v//[^0-9]/}"
    printf '%s' "${v:-0}"
}

# worker_run SITE USER INDEX — the body of one parallel worker. Everything it
# produces goes into its own directory; it touches no shared state except
# WP_OUTPUT / WP_STATUS, which are process-local after the fork anyway.
worker_run() { # SITE USER INDEX
    local site="$1" user="$2" idx="$3"
    local d rc=0
    d="$(worker_dir "$idx")"
    WORKER_DIR="$d"
    PARALLEL='true'
    # A forked worker inherits the parent's counters, and the parent has already
    # folded in the previous batches by the time this one starts. Zeroing them
    # here makes the numbers this worker writes to its result file exactly its
    # own contribution, which is the only thing the parent can safely add up.
    # Without this, every batch after the first reports the running total and the
    # fleet summary double-counts.
    STATS_OPS_OK=0
    STATS_OPS_FAILED=0
    STATS_SITES_TOTAL=0
    STATS_SITES_OK=0
    STATS_SITES_FAILED=0
    STATS_WARNINGS=0
    process_site "$site" "$user" >"${d}/out" 2>&1
    rc=$?
    PARALLEL='false'
    WORKER_DIR=''
    {
        printf 'rc=%s\n' "$rc"
        printf 'ops_ok=%s\n' "$STATS_OPS_OK"
        printf 'ops_failed=%s\n' "$STATS_OPS_FAILED"
        printf 'sites_total=%s\n' "$STATS_SITES_TOTAL"
        printf 'sites_ok=%s\n' "$STATS_SITES_OK"
        printf 'warnings=%s\n' "$STATS_WARNINGS"
        printf 'data=%s\n' "$OUTPUT_FORMAT"
    } >"${d}/res"
    return 0
}

# fold_worker INDEX — read one worker's results back into the parent counters,
# replay its console output, append its log lines, and emit its data.
fold_worker() { # INDEX SITE
    local idx="$1" site="$2"
    local d rc ops_ok ops_failed warnings data
    d="$(worker_dir "$idx")"
    if [ ! -r "${d}/res" ]; then
        # A worker that produced no result file was killed (OOM, SIGKILL, a full
        # disk). Say so instead of silently counting it as a success.
        log_error "worker for ${site} produced no result; counting it as failed"
        STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        SITE_STATUS["$site"]='FAILED'
        return 1
    fi
    rc="$(sed -n 's/^rc=//p' "${d}/res" 2>/dev/null)"
    ops_ok="$(read_counter <(sed -n 's/^ops_ok=//p' "${d}/res" 2>/dev/null))"
    ops_failed="$(read_counter <(sed -n 's/^ops_failed=//p' "${d}/res" 2>/dev/null))"
    warnings="$(read_counter <(sed -n 's/^warnings=//p' "${d}/res" 2>/dev/null))"
    data="$(sed -n 's/^data=//p' "${d}/res" 2>/dev/null)"

    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    STATS_OPS_OK=$((STATS_OPS_OK + ops_ok))
    STATS_OPS_FAILED=$((STATS_OPS_FAILED + ops_failed))
    STATS_WARNINGS=$((STATS_WARNINGS + warnings))

    # Console first, then the log: the operator watching the terminal and the
    # operator reading the file tomorrow must see the same story in the same order.
    if [ -s "${d}/out" ]; then
        cat -- "${d}/out" >&2
    fi
    if [ -s "${d}/log" ]; then
        if [ -n "$LOG_FILE" ]; then
            cat -- "${d}/log" >>"$LOG_FILE" 2>/dev/null
        fi
    fi
    if [ -s "${d}/data" ]; then
        # The fragment carries either a machine-readable listing (--format
        # json/csv/tsv) or this site's JSON Lines record; both belong on stdout
        # and both must appear in site order, not in completion order.
        cat -- "${d}/data"
    fi

    if [ "${rc:-1}" = '0' ]; then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        SITE_STATUS["$site"]='OK'
        return 0
    fi
    STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
    SITE_STATUS["$site"]='FAILED'
    return 1
}

# run_fleet — walk SITES[], either one by one or in batches of $JOBS.
run_fleet() {
    local n=${#SITES[@]}
    if ((JOBS <= 1)) || ((n <= 1)); then
        if ((JOBS > 1)) && ((n <= 1)); then
            log_debug "one site to process; --jobs ${JOBS} makes no difference"
        fi
        run_sequential
        return $?
    fi
    run_batched "$n"
    return $?
}

run_sequential() {
    local site rc=0
    for site in "${SITES[@]}"; do
        if [ "$ABORT" = 'true' ]; then
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            log_warn "${site}: skipped, the run was aborted"
            rc=1
            continue
        fi
        process_site "$site" "${SITE_USER[$site]}" || rc=1
    done
    return "$rc"
}

run_batched() { # N
    local n="$1" i=0 j=0 idx rc=0
    local -a batch=()
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.workers.XXXXXX")" || {
        log_note "cannot create a working directory for ${JOBS} parallel workers; falling back to sequential processing"
        run_sequential
        return $?
    }
    chmod 700 "$WORK_DIR" 2>/dev/null
    tmp_register "$WORK_DIR"
    log_info "processing ${n} sites in batches of ${JOBS}"

    while ((i < n)); do
        if [ "$ABORT" = 'true' ]; then
            while ((i < n)); do
                STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
                log_warn "${SITES[i]}: skipped, the run was aborted"
                i=$((i + 1))
            done
            rc=1
            break
        fi
        batch=()
        while ((i < n && ${#batch[@]} < JOBS)); do
            idx="$i"
            if worker_init "$idx"; then
                worker_run "${SITES[idx]}" "${SITE_USER[${SITES[idx]}]}" "$idx" &
                batch+=("$idx")
            else
                log_error "cannot prepare a worker for ${SITES[idx]}; running it in the parent"
                process_site "${SITES[idx]}" "${SITE_USER[${SITES[idx]}]}" || rc=1
            fi
            i=$((i + 1))
        done
        # The barrier. `wait` without arguments also reaps anything else that may
        # have been backgrounded, which is fine: nothing else is.
        wait
        # Replay in site order, so the report reads like the site list and not
        # like a race.
        for j in ${batch[@]+"${batch[@]}"}; do
            fold_worker "$j" "${SITES[j]}" || rc=1
            rm -rf -- "$(worker_dir "$j")" 2>/dev/null
        done
    done
    return "$rc"
}

###############################################################################
# 19. Per-site processing
###############################################################################

# In parallel mode process_site runs inside a worker whose stdout is a file, so
# anything meant for the operator's stream has to be routed to the data fragment
# and replayed by the parent. Everything else can just be printed.
# One place that maps a mode name to its function, so the retry loop and the
# dispatch cannot drift apart.
run_mode() { # SITE USER
    local site="$1" user="$2" rc=0
    case "$MODE" in
        full) mode_full "$site" "$user" || rc=1 ;;
        core) mode_core "$site" "$user" || rc=1 ;;
        plugins) mode_plugins "$site" "$user" || rc=1 ;;
        themes) mode_themes "$site" "$user" || rc=1 ;;
        db-optimize) mode_db_optimize "$site" "$user" || rc=1 ;;
        db-fix) mode_db_fix "$site" "$user" || rc=1 ;;
        cron) mode_cron "$site" "$user" || rc=1 ;;
        astra) mode_astra "$site" "$user" || rc=1 ;;
        list-plugins) mode_list_plugins "$site" "$user" || rc=1 ;;
        plugin-manage) mode_plugin_manage "$site" "$user" || rc=1 ;;
        verify) mode_verify "$site" "$user" || rc=1 ;;
        health) mode_health "$site" "$user" || rc=1 ;;
        secrets) mode_secrets "$site" "$user" || rc=1 ;;
        list-backups) mode_list_backups "$site" "$user" || rc=1 ;;
        restore-db) restore_database "$site" "$user" "$RESTORE_SOURCE" || rc=1 ;;
        *) log_error "internal: unknown mode '${MODE}'"; rc=1 ;;
    esac
    return "$rc"
}

mode_list_backups() { # SITE USER
    local site="$1" rows
    rows="$(backup_list_site "$site")"
    if [ -z "$rows" ]; then
        log_info "${site}: no backups in $(site_backup_dir "$site")"
        return 0
    fi
    printf '%s%s%s\n' "$C_BOLD" "$site" "$C_RESET"
    printf '%s\n' "$rows"
    return 0
}

# Would a write mode find anything to do? Only the modes that have a cheap
# read-only question are asked; the rest always run. The point is to let a
# nightly fleet run skip 180 of 200 sites without opening their databases.
site_has_pending_updates() { # SITE USER
    local site="$1" user="$2" n='' pending=0
    [ "$DRY_RUN" = 'true' ] && return 0
    case "$MODE" in
        core | full)
            info_wp "$site" "$user" core check-update
            [ "$WP_STATUS" = '0' ] && pending=1
            ;;
    esac
    case "$MODE" in
        plugins | full)
            n="$(pending_count "$site" "$user" plugin)"
            [ -n "$n" ] && ((n > 0)) && pending=1
            ;;
    esac
    case "$MODE" in
        themes | full)
            n="$(pending_count "$site" "$user" theme)"
            [ -n "$n" ] && ((n > 0)) && pending=1
            ;;
    esac
    case "$MODE" in
        db-optimize | db-fix | cron | astra | plugin-manage | restore-db) pending=1 ;;
    esac
    ((pending > 0))
}

# Version snapshots for the change log. `list --format=csv` is used rather than
# JSON because the output is already one line per item and the tool has no jq.
snapshot_versions() { # SITE USER KIND(plugin|theme|core) OUTFILE
    local site="$1" user="$2" kind="$3" out="$4" body=''
    : >"$out" 2>/dev/null || return 0
    case "$kind" in
        core)
            info_wp "$site" "$user" core version
            if [ "$WP_STATUS" = '0' ]; then
                printf 'core\t%s\n' "$(printf '%s' "$WP_OUTPUT" | tr -d '\r' | head -n 1)" >>"$out"
            fi
            ;;
        plugin | theme)
            info_wp "$site" "$user" "$kind" list --format=csv --fields=name,version
            [ "$WP_STATUS" = '0' ] || return 0
            body="$WP_OUTPUT"
            printf '%s\n' "$body" | awk -F, 'NR>1 && $1 != "" {print $1 "\t" $2}' >>"$out"
            ;;
    esac
    return 0
}

record_changes() { # SITE KIND BEFORE AFTER
    local site="$1" kind="$2" before="$3" after="$4" name old new
    [ -s "$before" ] || return 0
    [ -s "$after" ] || return 0
    while IFS=$'\t' read -r name old new; do
        [ -n "$name" ] || continue
        [ "$old" = "$new" ] && continue
        STATS_CHANGES=$((STATS_CHANGES + 1))
        log_ok "changed (${kind}): ${name} ${old} -> ${new}"
        [ -n "$CHANGES_FILE" ] &&
            printf '%s\t%s\t%s\t%s\t%s\n' "$site" "$kind" "$name" "$old" "$new" >>"$CHANGES_FILE"
    done < <(awk -F'\t' '
        NR==FNR { old[$1] = $2; next }
        {
            if ($1 in old) { if (old[$1] != $2) print $1 "\t" old[$1] "\t" $2; delete old[$1] }
            else print $1 "\t" "-" "\t" $2
        }' "$before" "$after")
    return 0
}

emit_site_record() { # SITE STATUS
    [ "$JSON_LINES" = 'true' ] || return 0
    # --health emits its own, richer object per site; a second generic record for
    # the same site would just make the stream ambiguous.
    [ "$MODE" = 'health' ] && return 0
    local sink='/dev/stdout'
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        sink="${WORKER_DIR}/data"
    fi
    emit_site_json "$1" "$2" >>"$sink"
}

process_site() { # SITE USER
    local site="$1" user="$2" rc=1 attempt=0
    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    if [ "$ABORT" = 'true' ]; then
        STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
        SITE_STATUS["$site"]='SKIPPED'
        log_warn "${site}: skipped, the run was aborted"
        return 1
    fi
    if ((RUN_TIMEOUT > 0)) && (($(date +%s) - START_TIME > RUN_TIMEOUT)); then
        ABORT='true'
                STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
        log_error "--run-timeout ${RUN_TIMEOUT}s reached; ${site} and the rest of the fleet are skipped"
        return 1
    fi
    log_info "site ${site} (as ${user})"
    # Cheap read-only question first: if nothing is pending, a nightly fleet run
    # touches the database only to ask, not to change it.
    if [ "$SKIP_IF_NO_UPDATES" = 'true' ] && ! mode_is_readonly; then
        if ! site_has_pending_updates "$site" "$user"; then
            log_info "${site}: nothing pending, skipped"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            SITE_STATUS["$site"]='SKIPPED'
            emit_site_record "$site" 'SKIPPED'
            return 0
        fi
    fi
    # The backup happens before anything is modified, and a failed backup does
    # not silently become "no backup": it is reported and, unless the operator
    # asked for --fail-on never, it stops this site.
    if ! maybe_backup "$site" "$user"; then
        if [ "$FAIL_ON" != 'never' ] && [ "$BACKUP_MODE" != 'off' ]; then
            log_error "${site}: backup failed; skipping the site rather than updating it unprotected"
            SITE_STATUS["$site"]='BACKUP_FAILED'
            STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
            return 1
        fi
    fi
    local before_p='' after_p='' before_t='' after_t='' before_c='' after_c=''
    if [ "$TRACK_CHANGES" = 'true' ] && [ "$DRY_RUN" != 'true' ]; then
        before_p="$(mktemp "${TMPDIR:-/tmp}/wpu-before-p.XXXXXX" 2>/dev/null)" || before_p=''
        after_p="$(mktemp "${TMPDIR:-/tmp}/wpu-after-p.XXXXXX" 2>/dev/null)" || after_p=''
        before_t="$(mktemp "${TMPDIR:-/tmp}/wpu-before-t.XXXXXX" 2>/dev/null)" || before_t=''
        after_t="$(mktemp "${TMPDIR:-/tmp}/wpu-after-t.XXXXXX" 2>/dev/null)" || after_t=''
        before_c="$(mktemp "${TMPDIR:-/tmp}/wpu-before-c.XXXXXX" 2>/dev/null)" || before_c=''
        after_c="$(mktemp "${TMPDIR:-/tmp}/wpu-after-c.XXXXXX" 2>/dev/null)" || after_c=''
        for f in "$before_p" "$after_p" "$before_t" "$after_t" "$before_c" "$after_c"; do
            [ -n "$f" ] && [ -e "$f" ] && tmp_register "$f"
        done
        case "$MODE" in
            plugins | full) snapshot_versions "$site" "$user" plugin "$before_p" ;;
        esac
        case "$MODE" in
            themes | full) snapshot_versions "$site" "$user" theme "$before_t" ;;
        esac
        case "$MODE" in
            core | full) snapshot_versions "$site" "$user" core "$before_c" ;;
        esac
    fi
    while :; do
        attempt=$((attempt + 1))
        rc=0
        run_mode "$site" "$user" || rc=1
        ((rc == 0)) && break
        if ((attempt > RETRY)); then break; fi
        STATS_RETRIES=$((STATS_RETRIES + 1))
        # A retry is worth it for a timed-out download or a busy database lock;
        # it is not worth it for a wrong --url. The operator decides with
        # --retry, and the attempt number is in the log either way.
        log_warn "${site}: attempt ${attempt} failed; retrying in ${RETRY_DELAY}s (${attempt} of $((RETRY + 1)) attempts)"
        sleep "$RETRY_DELAY"
    done
    if ((rc == 0)) && [ "$TRACK_CHANGES" = 'true' ] && [ "$DRY_RUN" != 'true' ]; then
        case "$MODE" in
            plugins | full)
                snapshot_versions "$site" "$user" plugin "$after_p"
                record_changes "$site" plugin "$before_p" "$after_p"
                ;;
        esac
        case "$MODE" in
            themes | full)
                snapshot_versions "$site" "$user" theme "$after_t"
                record_changes "$site" theme "$before_t" "$after_t"
                ;;
        esac
        case "$MODE" in
            core | full)
                snapshot_versions "$site" "$user" core "$after_c"
                record_changes "$site" core "$before_c" "$after_c"
                ;;
        esac
    fi
    if ((rc == 0)); then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        SITE_STATUS["$site"]='OK'
    else
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        SITE_STATUS["$site"]='FAILED'
        log_error "site failed: ${site}"
        if ((MAX_FAILURES > 0)) && ((STATS_SITES_FAILED >= MAX_FAILURES)) && [ "$ABORT" != 'true' ]; then
            ABORT='true'
            log_error "aborting after ${STATS_SITES_FAILED} failed site(s) (--max-failures ${MAX_FAILURES}); the remaining sites are skipped"
        fi
    fi
    emit_site_record "$site" "${SITE_STATUS[$site]}"
    return "$rc"
}

run_check_mode() {
    local rc=0 site user
    NO_ACTION='true'
    check_environment || rc=1
    if [ -n "$TARGET_SITE" ]; then
        user="$(site_user_resolve "$TARGET_SITE" 2>/dev/null)" || user=''
        printf '\n%s== requested site ==%s\n' "$C_BOLD" "$C_RESET"
        check_report "$TARGET_SITE" "$user" || rc=1
    fi
    return "$rc"
}

###############################################################################
# 18b. --list-sites: what would be processed, without processing it
###############################################################################

# Resolving the list is the half of a fleet run that can go wrong quietly: an
# owner that cannot be determined, a directory that vanished, an opt-out marker.
# This prints the resolved result -- including what was skipped and why -- and
# exits, so it can be diffed before a change and after it.
print_site_list() {
    local site user
    if [ -z "$TARGET_SITE" ]; then
        if ! ensure_site_list; then
            if [ ! -f "$SITES_FILE" ]; then
                log_error "no site list to work from: ${SITES_FILE}"
                return 1
            fi
        fi
        load_site_list "$SITES_FILE"
    else
        SITES=("$TARGET_SITE")
        user="$(site_user_resolve "$TARGET_SITE")" || user='<unknown>'
        SITE_USER["$TARGET_SITE"]="$user"
    fi
    printf '%s\n' "${C_BOLD}resolved site list${C_RESET} (${#SITES[@]} site(s), source: $([ -n "$TARGET_SITE" ] && printf -- '--site' || printf '%s' "$SITES_FILE"))" >&2
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        for site in ${SITES[@]+"${SITES[@]}"}; do
            printf '{"path":"%s","owner":"%s"}\n' \
                "$(json_escape "$site")" "$(json_escape "${SITE_USER[$site]-}")"
        done
        return 0
    fi
    # The table is the data, so it goes to stdout and can be piped; only the
    # heading and the skip count are prose.
    printf '%-52s %s\n' 'PATH' 'OWNER'
    for site in ${SITES[@]+"${SITES[@]}"}; do
        printf '%-52s %s\n' "$site" "${SITE_USER[$site]-<unknown>}"
    done
    if ((STATS_SITES_SKIPPED > 0)); then
        printf '%s\n' "skipped: ${STATS_SITES_SKIPPED} (see the warnings above)" >&2
    fi
    return 0
}

###############################################################################
# 19. Startup
###############################################################################

startup_checks() {
    if [ "$(id -u)" -ne 0 ] && [ -z "$USER_OVERRIDE" ] && [ "$DRY_RUN" != 'true' ] &&
       [ "$NO_ACTION" != 'true' ] && [ "$NO_USER_SWITCH" != 'true' ]; then
        log_error "this script must run as root: it switches into the owner of each site"
        log_error "re-run with sudo, or pass --user NAME, or use --dry-run / --check"
        exit "$EXIT_ENV"
    fi
    if ! wp_ensure; then
        exit "$EXIT_ENV"
    fi
    if [ -n "$USER_OVERRIDE" ]; then
        id -u "$USER_OVERRIDE" >/dev/null 2>&1 ||
            env_error "--user ${USER_OVERRIDE}: no such system user"
    fi
    if [ -n "$USER_ENV_LIST" ]; then
        local v
        for v in $USER_ENV_LIST; do
            if ! is_set "$v"; then
                log_warn "--user-env: '${v}' is not set in this environment; it will not be passed on"
            fi
        done
    fi
}

banner() {
    [ "$QUIET" = 'true' ] && return 0
    # The banner is prose, not data: it goes to stderr so that stdout carries
    # only what a machine would want to parse, in every format.
    local line
    line="$(printf '%*s' 70 '')"
    {
        printf '\n%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf ' %s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
        printf ' %s\n' "$MODE"
        printf '%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf '  %-16s %s\n' 'sites:' \
            "$([ -n "$TARGET_SITE" ] && printf '%s' "$TARGET_SITE" || printf 'all from %s' "$SITES_FILE")"
        printf '  %-16s %s\n' 'wp-cli:' "$WP_RESOLVED"
        printf '  %-16s %s\n' 'user switch:' "$(switch_mechanism)"
        printf '  %-16s %s\n' 'log level:' "$LOG_LEVEL"
        if ((JOBS > 1)); then
            printf '  %-16s %s\n' 'parallelism:' "${JOBS} sites per batch"
        fi
        if [ "$BACKUP_MODE" != 'off' ]; then
            printf '  %-16s %s\n' 'backup:' "${BACKUP_MODE} -> $(backup_dir_of)"
        fi
        if [ -n "$SITE_URL" ]; then
            printf '  %-16s %s\n' 'url:' "$SITE_URL"
        fi
        if [ "$NO_USER_SWITCH" = 'true' ]; then
            printf '  %-16s %srunning as %s, no user switch%s\n' 'user switch:' "$C_YELLOW" "$(id -un)" "$C_RESET"
        fi
        if [ "$DRY_RUN" = 'true' ]; then
            printf '  %-16s %sDRY RUN - nothing will be executed%s\n' 'mode:' "$C_YELLOW" "$C_RESET"
        fi
        printf '\n'
    } >&2
}

###############################################################################
# 20. main
###############################################################################

# colour_pre_scan: look at the command line for a colour preference before any
# output happens. --help and --version are printed from inside parse_args, so by
# the time the real parse finishes it is too late to colour them.
colour_pre_scan() {
    local prev=''
    for a in "$@"; do
        case "$prev" in
            --color) COLOR_MODE="${a,,}"; CLI_SET[COLOR]=1 ;;
        esac
        case "$a" in
            --no-color) COLOR_MODE='never'; CLI_SET[COLOR]=1 ;;
            --color=*) COLOR_MODE="${a#--color=}"; COLOR_MODE="${COLOR_MODE,,}"; CLI_SET[COLOR]=1 ;;
        esac
        prev="$a"
    done
    color_init
}

main() {
    colour_pre_scan "$@"
    parse_args "$@"

    if [ "$LIST_MODES" = 'true' ]; then
        list_modes
        exit "$EXIT_OK"
    fi

    # Order matters: the command line is parsed first so that config_load can
    # see which settings the operator fixed explicitly, and validate_args then
    # checks the *effective* value no matter which layer produced it.
    config_load
    config_validate_layer
    config_apply_all

    if [ "$PRINT_CONFIG" = 'true' ]; then
        color_init
        print_config
        exit "$EXIT_OK"
    fi

    # --report and --json-lines ask for the change log: what version of what
    # actually changed. It costs two extra read-only WP-CLI calls per site, which
    # is why it is not the default.
    if [ -n "$REPORT_FILE" ] || [ "$JSON_LINES" = 'true' ]; then
        TRACK_CHANGES='true'
    fi
    if [ -n "$REPORT_FILE" ]; then
        CHANGES_FILE="$(mktemp "${TMPDIR:-/tmp}/wpu-changes.XXXXXX" 2>/dev/null)" || CHANGES_FILE=''
        [ -n "$CHANGES_FILE" ] && tmp_register "$CHANGES_FILE"
    fi

    validate_args
    color_init          # re-resolved: a config layer may have changed COLOR

    # --doctor and --completion are about the host, not the fleet: they never
    # touch the site list, the lock or a database.
    if [ "$DOCTOR" = 'true' ]; then
        log_init
        mode_doctor
        local drc=$?
        SUMMARY_PRINTED='true'
        exit "$drc"
    fi
    if [ -n "$COMPLETION_SHELL" ]; then
        mode_completion "$COMPLETION_SHELL"
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    # --list-sites is an inspection command: it resolves the inventory and stops.
    # It runs *after* validate_args, because that is where the dual meaning of -J
    # is resolved -- before it, `--list-sites --json` would print the table.
    # Still before log_init and before the environment checks, so it works
    # without a wp binary, without a lock and without root.
    if [ "$LIST_SITES" = 'true' ]; then
        print_site_list
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    log_init
    START_TIME="$(date +%s)"

    log_info "${PROG_NAME} ${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"
    log_debug "script directory: ${SCRIPT_DIR}"
    log_debug "config file used: ${CONFIG_FILE_USED:-<none>}"

    if [ "$SHOW_STATUS" = 'true' ] || [ "$MODE" = 'status' ]; then
        status_report
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    startup_checks

    if [ "$MODE" = 'check' ]; then
        # --check reads the list if it exists but never fails because of it
        [ -f "$SITES_FILE" ] && load_site_list "$SITES_FILE"
        run_check_mode
        local crc=$?
        SUMMARY_PRINTED='true'
        exit "$crc"
    fi

    if [ "$NO_LOCK" = 'true' ]; then
        log_debug 'lock disabled by --no-lock'
    elif mode_is_readonly; then
        # A read-only mode changes nothing, so it neither waits for nor blocks a
        # real run: --health must answer while --full is halfway through the fleet.
        log_debug 'read-only mode: no lock'
    else
        lock_acquire
    fi

    banner

    if [ -n "$TARGET_SITE" ]; then
        if [ ! -d "$TARGET_SITE" ]; then
            log_error "--site is not a directory: ${TARGET_SITE}"
            print_summary "$EXIT_ERROR"
            exit "$EXIT_ERROR"
        fi
        SITES=("$TARGET_SITE")
        local u
        if ! u="$(site_user_resolve "$TARGET_SITE")"; then
            log_error "cannot determine the owner of ${TARGET_SITE}; pass --user NAME"
            print_summary "$EXIT_ENV"
            exit "$EXIT_ENV"
        fi
        SITE_USER["$TARGET_SITE"]="$u"
    else
        if ! ensure_site_list; then
            # A missing list is an environment problem; an empty one is not an
            # error at all, it just means there is nothing to do.
            if [ ! -f "$SITES_FILE" ]; then
                log_error "no site list to work from: ${SITES_FILE}"
                print_summary "$EXIT_ENV"
                exit "$EXIT_ENV"
            fi
        fi
        load_site_list "$SITES_FILE"
    fi

    if ((${#SITES[@]} == 0)); then
        log_warn 'no site to process; nothing to do'
        local empty_code="$EXIT_OK"
        # "Nothing to do" is a warning, and --strict exists precisely so that a
        # cron job can be told to treat one as a failure: a maintenance run that
        # silently processed zero sites is the failure mode nobody notices.
        final_exit_code || empty_code="$EXIT_ERROR"
        print_summary "$empty_code"
        exit "$empty_code"
    fi

    log_info "processing ${#SITES[@]} site(s) in mode '${MODE}'"

    local rc=0
    run_fleet || rc=1

    local code=0
    final_exit_code || code="$EXIT_ERROR"
    if ((code == 0)) && [ "$FAIL_ON" = 'any' ] && ((STATS_OPS_FAILED > 0)) &&
       ((STATS_SITES_FAILED == 0)); then
        # operations failed but no site was marked failed (soft failures only)
        code=0
    fi
    print_summary "$code"
    log_info "finished with exit ${code}"
    exit "$code"
}

main "$@"
