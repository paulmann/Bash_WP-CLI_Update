#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# WordPress Maintenance Automation
#
# File:        Bash_WP-CLI_Update.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     MIT
# Version:     6.1.0
#
# Purpose
#   Run WP-CLI maintenance operations (core, plugins, themes, database, cron,
#   Astra Pro licence) over every WordPress installation listed in a site file,
#   each one as the system user that owns it.
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
SCRIPT_VERSION='6.1.0'

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

# Environment variables that may carry configuration. The list is explicit: an
# arbitrary variable is never read, so a hostile environment cannot inject a
# setting that the operator did not publish.
CONFIG_KEYS=(
    WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE
    LOG_MAX_BYTES LOG_KEEP LOG_LEVEL ERROR_OUTPUT_LINES COLOR
    SKIP_PLUGINS SKIP_PLUGINS_FOR_LISTING ALLOW_ROOT TIMEOUT KILL_AFTER
    TIMEOUT_SIGNAL FAIL_ON ASTRA_SLUG MAX_SITES AUTO_DISCOVER USER_ENV LICENCE
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

# is_set NAME -> true when the variable is present in the environment.
# `${!NAME+x}` on an *array* element is a bash 4.2 trap, so this stays scalar.
is_set() { [ -n "${!1+x}" ]; }

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
    [ -n "$LOG_FILE" ] || return 0
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
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
    printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$(redact "$msg")" >&"$fd"
}

log_debug() { log debug "${1:-}"; }
log_info() { log info "${1:-}"; }
log_ok() { log ok "${1:-}"; }
log_warn() { log warn "${1:-}"; }
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
        *'`'* | *'$('* | *'|'* | *';'* | *'>'* | *'<'* | *'&'*) return 0 ;;
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

config_store() { # KEY VALUE SOURCE
    local key="$1" value="$2" src="$3"
    CONF["$key"]="$value"
    CONF_SRC["$key"]="$src"
}

config_parse_file() { # FILE LABEL
    local file="$1" label="$2" line no=0 key value
    [ -f "$file" ] || return 0
    [ -r "$file" ] || config_error "${file}: not readable"
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
            log_warn "${file}:${no}: unknown setting '${key}', ignored"
            continue
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
        if is_set "$env_name" && [ -z "${CLI_SET[$key]-}" ]; then
            config_store "$key" "${!env_name}" "env"
        fi
    done
    # Astra licence: two historical names are accepted, plus a key file that is
    # resolved later (licence_resolve), because it must never be in argv.
    if [ -z "${CLI_SET[LICENCE]-}" ]; then
        if is_set 'WP_CLI_UPDATE_LICENCE'; then
            config_store 'LICENCE' "$WP_CLI_UPDATE_LICENCE" 'env'
        elif is_set 'ASTRA_KEY'; then
            config_store 'LICENCE' "$ASTRA_KEY" 'env'
        elif is_set 'ASTRA_LICENSE_KEY'; then
            config_store 'LICENCE' "$ASTRA_LICENSE_KEY" 'env'
        fi
    fi
}


require_positive_int_conf() { # NAME VALUE
    if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 < 1 )); then
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
            SKIP_PLUGINS_FOR_LISTING | AUTO_DISCOVER)
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
    if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 < 1 )); then
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
PLUGIN_NAME=''
PLUGIN_ACTION=''
FORCE_DELETE='false'
ASSUME_YES='false'
DRY_RUN='false'
NO_ACTION='false'
LIST_MODES='false'
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
LOCK_FD=''
LOCK_HELD='false'
TMP_FILES=()
WARNED_NO_TIMEOUT='false'
WARNED_NO_FLOCK='false'
START_TIME=0

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
        if ! flock -n "$LOCK_FD"; then
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
                log_warn 'flock(1) not found; using a pid file, which does not protect against a crash mid-run'
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
    tmp_cleanup
    if [ "$SUMMARY_PRINTED" = 'false' ] && [ "$START_TIME" -gt 0 ] &&
       [ "$NO_ACTION" != 'true' ] && [ "$LIST_MODES" != 'true' ]; then
        printf '\n' >&2
        log_warn "interrupted or aborted (exit ${rc}); partial summary follows"
        print_summary "$rc"
    fi
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
# The alternatives are all worse: 0600 does not work at all (the child gets
# "Permission denied" and the licence arrives empty); `runuser -m` has no
# equivalent under sudo/su; and putting the value in argv is precisely what this
# design refuses to do. If your threat model includes other local users reading
# /tmp during a run, feed WP_CLI_UPDATE_LICENCE per invocation from a secrets
# manager rather than keeping a key file on disk.

licence_open() {
    [ -n "$LICENCE_VALUE" ] || return 0
    [ -n "$LICENCE_FILE" ] && return 0
    LICENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.licence.XXXXXX")" || {
        log_error 'cannot create a temporary file for the licence handoff'
        return 1
    }
    tmp_register "$LICENCE_FILE"
    # Write first, relax the mode second: the value is never present in a file
    # that is already world-readable.
    if ! printf '%s' "$LICENCE_VALUE" >"$LICENCE_FILE"; then
        log_error "cannot write the licence handoff file ${LICENCE_FILE}"
        LICENCE_FILE=''
        return 1
    fi
    if ! chmod 644 "$LICENCE_FILE" 2>/dev/null; then
        log_warn "cannot relax the mode of ${LICENCE_FILE}; the site owner may not be able to read it"
    fi
    redact_register "$LICENCE_VALUE"
    log_debug "licence handoff prepared (${LICENCE_FILE})"
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
site_env_argv() { # SITE USER -> one argv element per line
    local site="$1" user="$2" domain parent home
    domain="$(basename -- "$site")"
    parent="$(dirname -- "$(dirname -- "$site")")"
    home=''
    if [ -n "$user" ] && have getent; then
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$home" ] || [ ! -d "$home" ]; then home="$parent"; fi
    printf '%s\n' \
        "DOCUMENT_URI=${domain}" \
        "DOCUMENT_ROOT=${site}" \
        "HOMEDIR=${parent}" \
        "HTTP_HOST=${domain}" \
        "HOME=${home}" \
        "USER=${user}" \
        "LOGNAME=${user}"
    # Operator-selected pass-through, e.g. a proxy or an API endpoint.
    local v
    for v in $USER_ENV_LIST; do
        if is_set "$v"; then
            printf '%s\n' "${v}=${!v}"
        fi
    done
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

timeout_argv() { # -> zero or more argv elements on stdout
    if ((WP_COMMAND_TIMEOUT <= 0)); then return 0; fi
    if ! have timeout; then
        if [ "$WARNED_NO_TIMEOUT" = 'false' ]; then
            log_warn 'timeout(1) not found; --timeout is ignored and a hung wp will block the run'
            WARNED_NO_TIMEOUT='true'
        fi
        return 0
    fi
    if [ -z "$TIMEOUT_SUPPORTED" ]; then
        # -k is a GNU extension; probe it once instead of assuming it.
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
    printf '%s\n' "$WP_COMMAND_TIMEOUT"
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
    mapfile -t envv < <(site_env_argv "$site" "$user")
    mapfile -t pre < <(timeout_argv)
    argv=(env "${envv[@]}")
    argv+=(${pre[@]+"${pre[@]}"})
    argv+=("$WP_RESOLVED" "--path=$site")
    ar="$(allow_root_flag)"
    [ -n "$ar" ] && argv+=("$ar")
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
        licence_open || { WP_STATUS=1; WP_OUTPUT='cannot prepare the licence handoff'; return 0; }
        mapfile -t run < <(child_argv WP_CLI_LICENCE "${argv[@]}") || {
            WP_STATUS=1; WP_OUTPUT='cannot build the licence handoff command'; return 0; }
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
    if [ -n "${USER_OVERRIDE:-}" ]; then
        printf '%s' "$USER_OVERRIDE"
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

mode_plugins() { run_wp "$1" "$2" plugin update --all; }
mode_themes() { run_wp "$1" "$2" theme update --all; }

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
    run_wp "$site" "$user" plugin update --all || rc=1
    run_wp "$site" "$user" theme update --all || rc=1
    run_wp "$site" "$user" core update-db --skip-plugins || rc=1
    run_wp "$site" "$user" db optimize || rc=1
    run_wp "$site" "$user" db repair || rc=1
    run_wp "$site" "$user" cron event run --due-now || rc=1
    astra_step "$site" "$user" 'false' || true
    return "$rc"
}

mode_astra() { astra_step "$1" "$2" 'true'; }

###############################################################################
# 14. Plugin listing and management
###############################################################################

PLUGIN_FIELDS_DEFAULT='name,status,update,version'
FILTER_FIELDS=''

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

    case "$OUTPUT_FORMAT" in
        json) printf '%s\n' "$body" ;;
        csv) printf '%s\n' "$tsv" | tsv_to_csv ;;
        tsv) printf '%s\n' "$tsv" ;;
        table | *)
            printf '%s%s%s\n' "$C_BOLD" "$site$C_RESET" ''
            printf '%s\n' "$tsv" | table_render "$PAGE_LIMIT"
            ;;
    esac
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
    run_wp "$site" "$user" plugin "$wp_action" "$slug"
}

mode_list_plugins() { # SITE USER
    plugin_list_site "$1" "$2"
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
        printf 'duration        : %ss\n' "$(( $(date +%s) - START_TIME ))"
    } >"$f" 2>/dev/null
}

print_summary() { # RC
    local rc="$1" elapsed
    SUMMARY_PRINTED='true'
    elapsed="$(( $(date +%s) - START_TIME ))"
    state_write "$rc"
    log_write_file info "summary: sites ${STATS_SITES_OK}/${STATS_SITES_TOTAL} ok, ${STATS_OPS_FAILED} failed operations, exit ${rc}, ${elapsed}s"
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
    printf '  %-22s %ss\n' 'duration:' "$elapsed"
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
      --check            validate the environment and every site, change nothing
      --status           print the last run summary and the log sizes
      --list-modes       print the mode names, one per line (for shell completion)

${C_BOLD}Selection:${C_RESET}
  -S, --site PATH        operate on one site only (overrides the site list)
      --sites FILE       site list, one absolute path per line (default: ${DEFAULT_SITES_FILE})
      --max-sites N      process at most N sites (0 = all, default ${DEFAULT_MAX_SITES})
      --user NAME        force the system user for every site (skips owner detection)

${C_BOLD}Plugin management:${C_RESET}
  -A, --action ACTION    activate | deactivate | delete   (for --plugin-manage)
  -N, --name NAME        plugin name or slug; case-insensitive substring, never a pattern
  -F, --force            skip the delete confirmation
  -y, --yes              same as --force, for scripted use

${C_BOLD}Output:${C_RESET}
      --format FMT       table | json | csv | tsv   (default: ${DEFAULT_OUTPUT_FORMAT})
      --fields LIST      comma separated columns for --list-plugins
                         (default: ${PLUGIN_FIELDS_DEFAULT})
      --page-limit N     rows per table (0 = all, default 0)
  -J, --json             shorthand for --format json
      --color WHEN       auto | always | never (default: ${DEFAULT_COLOR})
      --no-color         same as --color never
      --quiet            console shows warnings and errors only
  -D, --debug            verbose logging; implies --log-level debug
  -v, --verbose          show the commands as they are executed

${C_BOLD}Safety:${C_RESET}
  -n, --dry-run          show what would run, execute nothing
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

${C_BOLD}Configuration:${C_RESET}
      --config FILE      read settings from FILE (default: ${CONFIG_LOCAL} or ${CONFIG_GLOBAL})
      --print-config     show the effective settings and where each came from, then exit
      --astra-key KEY    Astra licence; prefer WP_CLI_UPDATE_LICENCE or a key file
      --astra-slug SLUG  Astra add-on slug (default: ${DEFAULT_ASTRA_SLUG})
      --log-file FILE    main log (default: ${DEFAULT_LOG_FILE})
      --error-log-file FILE
      --lock-file FILE   (default: ${DEFAULT_LOCK_FILE})
      --log-level LVL    debug | info | warn | error (default: ${DEFAULT_LOG_LEVEL})
      --wp PATH          path to the wp binary (default: ${DEFAULT_WP_CLI_PATH})
      --user-env LIST    space separated variables to pass through to the site user

${C_BOLD}Other:${C_RESET}
  -h, --help             this help, exit 0
  -V, --version          print the version, exit 0

${C_BOLD}Exit codes:${C_RESET}
  0 success   1 operational error   2 usage error   3 environment error   4 config error

${C_BOLD}Configuration precedence:${C_RESET}
  built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf
                    < WP_CLI_UPDATE_* environment < command line

${C_BOLD}Licence handling:${C_RESET}
  The Astra licence is never passed as an argument. It is written to a
  temporary file and read by the child shell at run time, so it appears
  WP_CLI_UPDATE_LICENCE, ASTRA_KEY, ASTRA_LICENSE_KEY, then the first readable
  file among ./astra.key, /etc/wp-cli-update/astra.key, \$HOME/.astra.key.

${C_BOLD}Examples:${C_RESET}
  ${PROG_NAME} --full
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
        list-plugins plugin-manage check status
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
    )
    local -a vars=(
        WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE
        LOG_MAX_BYTES LOG_KEEP LOG_LEVEL ERROR_OUTPUT_LINES COLOR_MODE SKIP_PLUGINS
        SKIP_PLUGINS_FOR_LISTING ALLOW_ROOT_FLAG WP_COMMAND_TIMEOUT KILL_AFTER
        TIMEOUT_SIGNAL FAIL_ON ASTRA_SLUG MAX_SITES AUTO_DISCOVER USER_ENV_LIST
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
            --check) set_mode check; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --status) set_mode status; NO_ACTION='true'; CLI_SET[MODE]=1 ;;
            --list-modes) LIST_MODES='true' ;;
            # ---- selection ---------------------------------------------
            -S | --site) need_value "$arg" "${2:-}"; TARGET_SITE="$OPT_VALUE"; shift; CLI_SET[SITES_FILE]=1 ;;
            --sites | --sites-file)
                need_value "$arg" "${2:-}"; SITES_FILE="$OPT_VALUE"; shift; CLI_SET[SITES_FILE]=1 ;;
            --max-sites) need_value "$arg" "${2:-}"; MAX_SITES="$OPT_VALUE"; shift; CLI_SET[MAX_SITES]=1 ;;
            --user) need_value "$arg" "${2:-}"; USER_OVERRIDE="$OPT_VALUE"; shift ;;
            # ---- plugin management -------------------------------------
            -A | --action) need_value "$arg" "${2:-}"; PLUGIN_ACTION="${OPT_VALUE,,}"; shift ;;
            -N | --name) need_value "$arg" "${2:-}"; PLUGIN_NAME="$OPT_VALUE"; FILTER_NAME="$OPT_VALUE"; shift ;;
            -F | --force) FORCE_DELETE='true' ;;
            -y | --yes) ASSUME_YES='true' ;;
            # ---- output ------------------------------------------------
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift ;;
            --fields) need_value "$arg" "${2:-}"; FILTER_FIELDS="$OPT_VALUE"; shift ;;
            --page-limit) need_value "$arg" "${2:-}"; PAGE_LIMIT="$OPT_VALUE"; shift ;;
            -J | --json) OUTPUT_FORMAT='json' ;;
            --color) need_value "$arg" "${2:-}"; COLOR_MODE="${OPT_VALUE,,}"; shift; CLI_SET[COLOR]=1 ;;
            --no-color) COLOR_MODE='never'; CLI_SET[COLOR]=1 ;;
            --quiet | -q) QUIET='true' ;;
            -D | --debug) VERBOSE='true'; LOG_LEVEL='debug'; CLI_SET[LOG_LEVEL]=1 ;;
            -v | --verbose) VERBOSE='true' ;;
            # ---- safety ------------------------------------------------
            -n | --dry-run) DRY_RUN='true' ;;
            --timeout) need_value "$arg" "${2:-}"; WP_COMMAND_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[TIMEOUT]=1 ;;
            --signal) need_value "$arg" "${2:-}"; TIMEOUT_SIGNAL="${OPT_VALUE^^}"; shift; CLI_SET[TIMEOUT_SIGNAL]=1 ;;
            --kill-after) need_value "$arg" "${2:-}"; KILL_AFTER="$OPT_VALUE"; shift; CLI_SET[KILL_AFTER]=1 ;;
            --allow-root) need_value "$arg" "${2:-}"; ALLOW_ROOT_FLAG="${OPT_VALUE,,}"; shift; CLI_SET[ALLOW_ROOT]=1 ;;
            --skip-plugins) SKIP_PLUGINS="${2-}"; shift; CLI_SET[SKIP_PLUGINS]=1 ;;
            --skip-plugins-for-listing)
                need_value "$arg" "${2:-}"
                SKIP_PLUGINS_FOR_LISTING="${OPT_VALUE,,}"
                shift; CLI_SET[SKIP_PLUGINS_FOR_LISTING]=1 ;;
            --fail-on) need_value "$arg" "${2:-}"; FAIL_ON="${OPT_VALUE,,}"; shift; CLI_SET[FAIL_ON]=1 ;;
            --no-lock) NO_LOCK='true' ;;
            --no-discover) AUTO_DISCOVER='false'; CLI_SET[AUTO_DISCOVER]=1 ;;
            # ---- configuration -----------------------------------------
            --config) need_value "$arg" "${2:-}"; CONFIG_REQUESTED="$OPT_VALUE"; shift ;;
            --print-config) PRINT_CONFIG='true' ;;
            --astra-key) need_value "$arg" "${2:-}"; LICENCE_VALUE="$OPT_VALUE"; CLI_SET[LICENCE]=1; shift ;;
            --astra-slug) need_value "$arg" "${2:-}"; ASTRA_SLUG="$OPT_VALUE"; shift; CLI_SET[ASTRA_SLUG]=1 ;;
            --wp | --wp-cli) need_value "$arg" "${2:-}"; WP_CLI_PATH="$OPT_VALUE"; shift; CLI_SET[WP_CLI_PATH]=1 ;;
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
    if [ "$LIST_MODES" = 'true' ]; then return 0; fi
    if [ -z "$MODE" ]; then
        usage_error 'no mode given; pass one of --full, --core, --plugins, --themes, --db-optimize, --db-fix, --cron, --astra, --list-plugins, --plugin-manage, --check, --status'
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
# 18. Per-site processing
###############################################################################

process_site() { # SITE USER
    local site="$1" user="$2" rc=0
    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    log_info "site ${site} (as ${user})"
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
        *) log_error "internal: unknown mode '${MODE}'"; rc=1 ;;
    esac
    if ((rc == 0)); then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
    else
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        log_error "site failed: ${site}"
    fi
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
# 19. Startup
###############################################################################

startup_checks() {
    if [ "$(id -u)" -ne 0 ] && [ -z "$USER_OVERRIDE" ] && [ "$DRY_RUN" != 'true' ] &&
       [ "$NO_ACTION" != 'true' ]; then
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

    validate_args
    color_init          # re-resolved: a config layer may have changed COLOR
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

    if [ "$NO_LOCK" != 'true' ]; then
        lock_acquire
    else
        log_debug 'lock disabled by --no-lock'
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
        print_summary "$EXIT_OK"
        exit "$EXIT_OK"
    fi

    log_info "processing ${#SITES[@]} site(s) in mode '${MODE}'"

    local site rc=0
    for site in "${SITES[@]}"; do
        process_site "$site" "${SITE_USER[$site]}" || rc=1
    done

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
