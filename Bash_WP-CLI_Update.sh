#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# WordPress Maintenance Automation
#
# Description: Secure, fast and modular WP-CLI manager for many WordPress sites.
# Author:      Mikhail Deynekin <mid1977@gmail.com>
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     MIT
# Version:     6.0.0
#
# Exit codes:
#   0  success
#   1  operational error (one or more WP-CLI operations failed)
#   2  usage error (bad command line)
#   3  environment error (not root, bash too old, wp-cli missing, lock held)
#   4  configuration error
###############################################################################

# Require bash 4.2+ (negative array subscripts, ${var,,}).
if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash, but another shell started it.\n' >&2
    printf '       Run it as: bash %s [options]\n' "${0##*/}" >&2
    exit 3
fi

# Deliberately NOT using 'set -e': the whole point of this script is to run many
# WP-CLI commands and keep going when one of them fails. Every command status is
# checked explicitly instead of relying on errexit.
set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    printf 'ERROR: bash 4.2 or newer is required, found %s\n' "${BASH_VERSION}" >&2
    exit 3
fi

export LC_ALL=C

###############################################################################
# 1. Constants
###############################################################################
readonly PROG_NAME="${0##*/}"
readonly SCRIPT_VERSION='6.0.0'

# Physical directory of this script with symlinks resolved, without depending on
# 'readlink -f' (absent on CentOS 7).
_resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
script_dir="$(_resolve_script_dir)" || { printf 'ERROR: cannot resolve script directory\n' >&2; exit 3; }
readonly script_dir
unset -f _resolve_script_dir

readonly DEFAULT_SITES_FILE="${script_dir}/wp-found.txt"
readonly DEFAULT_DISCOVER_SCRIPT="${script_dir}/Find_WP_Senior.sh"
readonly DEFAULT_CONFIG_GLOBAL='/etc/wp-cli-update.conf'
readonly DEFAULT_CONFIG_LOCAL="${script_dir}/wp-cli-update.conf"
readonly DEFAULT_LOG_FILE="${script_dir}/wp_cli_manager.log"
readonly DEFAULT_ERROR_LOG_FILE="${script_dir}/wp_cli_errors.log"
readonly DEFAULT_LOCK_FILE='/var/lock/wp-cli-update.lock'
readonly DEFAULT_WP_CLI='/usr/local/bin/wp'
readonly DEFAULT_USER_ENV_PREFIX='DOCUMENT_URI DOCUMENT_ROOT HOMEDIR HTTP_HOST'

readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_ENV=3
readonly EXIT_CONFIG=4

readonly MODE_FULL='full'
readonly MODE_CORE='core'
readonly MODE_PLUGINS='plugins'
readonly MODE_THEMES='themes'
readonly MODE_DB_OPTIMIZE='db-optimize'
readonly MODE_DB_FIX='db-fix'
readonly MODE_CRON='cron'
readonly MODE_ASTRA='astra'
readonly MODE_LIST_PLUGINS='list-plugins'
readonly MODE_PLUGIN_MANAGE='plugin-manage'
readonly MODE_CHECK='check'
readonly MODE_STATUS='status'

readonly ACTION_ACTIVATE='activate'
readonly ACTION_DEACTIVATE='deactivate'
readonly ACTION_DELETE='delete'

# Field names asked from WP-CLI when listing plugins.
readonly PLUGIN_FIELDS='name,status,version,update,update_version,slug,title'

###############################################################################
# 2. Mutable state
###############################################################################
WP_CLI_PATH="$DEFAULT_WP_CLI"
SITES_FILE="$DEFAULT_SITES_FILE"
DISCOVER_SCRIPT="$DEFAULT_DISCOVER_SCRIPT"
LOG_FILE="$DEFAULT_LOG_FILE"
ERROR_LOG_FILE="$DEFAULT_ERROR_LOG_FILE"
LOCK_FILE="$DEFAULT_LOCK_FILE"
CONFIG_FILE=''
USER_ENV_PREFIX="$DEFAULT_USER_ENV_PREFIX"
PLUGIN_SKIP_LIST='saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer'
SKIP_PLUGINS_FOR_LISTING='false'
EXPORT_USER_HOME='true'
LOG_MAX_BYTES='5242880'
LOG_KEEP='3'
LOG_LEVEL='info'
PAGE_LIMIT='0'
COLOR_MODE='auto'
WP_COMMAND_TIMEOUT='900'
ASTRA_SLUG='astra-addon'
ASTRA_LICENSE_COMMAND='brainstormforce license activate'
licence_value=''
ALLOW_ROOT_FLAG='auto'

DEBUG_MODE='false'
DRY_RUN='false'
QUIET_MODE='false'
ASSUME_YES='false'
NO_COLOR_SET='false'
NO_ACTION='false'
MODE=''
TARGET_SITE=''
PLUGIN_NAME=''
PLUGIN_ACTION=''
FORCE_MODE='false'
OUTPUT_FORMAT='table'
LIST_MODES='false'
PRINT_HELP='false'
PRINT_VERSION='false'
CONFIG_REQUESTED=''
CONFIG_FROM_CLI=''

# Counters, updated only by the helpers below, never inside a pipeline.
STAT_SITES_SEEN=0
STAT_SITES_OK=0
STAT_SITES_SKIPPED=0
STAT_SITES_FAILED=0
STAT_OPS_OK=0
STAT_OPS_FAILED=0
STAT_OPS_SKIPPED=0
STAT_PLUGINS_UPDATED=0
STAT_THEMES_UPDATED=0

LOCK_FD=''
LOCK_HELD='false'
HEADER_SHOWN='false'
SUMMARY_SHOWN='false'
EXIT_CODE="$EXIT_OK"
declare -a TAIL_FILES=()
JSON_BAG=''

###############################################################################
# 3. Terminal and colours
###############################################################################
# Colours only on a terminal, never when NO_COLOR is set (https://no-color.org)
# and never when stdout has been redirected to a file.
_colors_init() {
    local mode="$COLOR_MODE" use='no'
    if [ "$mode" = 'never' ] || [ -n "${NO_COLOR:-}" ] || [ "$NO_COLOR_SET" = 'true' ]; then
        use='no'
    elif [ "$mode" = 'always' ]; then
        use='yes'
    elif [ "$mode" = 'never' ]; then
        use='no'
    elif [ -t 1 ]; then
        use='yes'
    fi

    if [ "$use" = 'yes' ]; then
        C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
        C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m';  C_CYAN=$'\033[36m'
    else
        C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
    fi
}

# Defined before _colors_init so that usage errors printed from the argument
# parser never touch an unset variable under 'set -u'.
C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''

_repeat() { # CHAR COUNT
    local ch="$1" n="$2" out=''
    (( n <= 0 )) && return 0
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
}

###############################################################################
# 4. Logging
###############################################################################
_level_num() {
    case "${1,,}" in
        debug)                  printf '%s' 10 ;;
        info)                   printf '%s' 20 ;;
        success|warn|warning)   printf '%s' 30 ;;
        error)                  printf '%s' 40 ;;
        *)                      printf '%s' 20 ;;
    esac
}

_log_enabled() { [ "$(_level_num "$1")" -ge "$(_level_num "$LOG_LEVEL")" ] || [ "$1" = 'ERROR' ]; }

_rotate_log() { # FILE MAX_BYTES KEEP
    local file="$1" max="$2" keep="$3" size i
    [ -f "$file" ] || return 0
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || return 0
    size="$(wc -c <"$file" 2>/dev/null || printf '0')"
    size="${size//[^0-9]/}"
    [ -n "$size" ] || size=0
    (( size < max )) && return 0
    for (( i = keep - 1; i >= 1; i-- )); do
        [ -f "${file}.${i}" ] && mv -f "${file}.${i}" "${file}.$((i + 1))" 2>/dev/null
    done
    mv -f "$file" "${file}.1" 2>/dev/null || true
    return 0
}

# Names that must never appear in a log line with a value attached.
REDACT_RE='(token|secret|passwd|password|api_?key|authorization|credential|licen[cs]e_?key|private_key|access_token|session_token)'

_redact() {
    local s="$1"
    printf '%s' "$s" | sed -E "s/(${REDACT_RE})([=:][[:space:]]*)[^[:space:]\"']+/\1\2[redacted]/Ig" \
        | sed -E 's/(--(astra-)?(licence|license)-?key[= ])[^[:space:]]+/\1[redacted]/Ig'
}

_emit() { # LEVEL MESSAGE
    local level="${1^^}" msg="$2" ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="$(_redact "$msg")"
    line="[${ts}] [${level}] ${msg}"
    _rotate_log "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_KEEP"
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true

    [ "$QUIET_MODE" = 'true' ] && [ "$level" != 'ERROR' ] && [ "$level" != 'WARNING' ] && return 0
    case "$level" in
        ERROR)   printf '%sERR %s%s\n'   "$C_RED"    "$msg" "$C_RESET" >&2 ;;
        WARNING) printf '%sWRN %s%s\n'   "$C_YELLOW" "$msg" "$C_RESET" >&2 ;;
        SUCCESS) printf '%sOK  %s%s\n'   "$C_GREEN"  "$msg" "$C_RESET" >&2 ;;
        DEBUG)   printf '%sDBG %s%s\n'   "$C_DIM"    "$msg" "$C_RESET" >&2 ;;
        *)       printf '%sINF %s%s\n'   "$C_BLUE"   "$msg" "$C_RESET" >&2 ;;
    esac
    return 0
}

log_debug()   { _log_enabled debug   && _emit DEBUG   "$1"; return 0; }
log_info()    { _log_enabled info    && _emit INFO    "$1"; return 0; }
log_success() { _log_enabled success && _emit SUCCESS "$1"; return 0; }
log_warn()    { _log_enabled warn    && _emit WARNING "$1"; return 0; }
log_error()   { _emit ERROR "$1"; return 0; }

log_error_detail() { # CONTEXT COMMAND EXIT_CODE OUTPUT
    local context="$1" cmd="$2" code="$3" output="$4" ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        printf '[%s] [ERROR DETAIL]\n' "$ts"
        printf 'Context:   %s\n' "$(_redact "$context")"
        printf 'Command:   %s\n' "$(_redact "$cmd")"
        printf 'Exit code: %s\n' "$code"
        printf 'Output:\n'
        printf '%s\n' "$output" | sed -e 's/^/  | /'
        printf -- '---\n'
    } >>"$ERROR_LOG_FILE" 2>/dev/null || true
}

# Quote one argument for /bin/sh -c. 'printf %q' is a bash extension and is not
# guaranteed to be understood by a POSIX shell, so the form is explicit.
sh_quote() {
    local s="$1"
    if [ -z "$s" ]; then printf "''"; return 0; fi
    if [[ "$s" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then printf '%s' "$s"; return 0; fi
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

argv_display() {
    local arg out=''
    for arg in "$@"; do out+="$(sh_quote "$arg") "; done
    printf '%s' "${out% }"
}
###############################################################################
# 5. Locking and traps
###############################################################################
_lock_acquire() {
    local dir other
    dir="$(dirname "$LOCK_FILE")"
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        LOCK_FILE="${TMPDIR:-/tmp}/wp-cli-update.$(id -u).lock"
        log_debug "Lock directory not writable, falling back to ${LOCK_FILE}"
    fi

    # The braces matter: 'exec {FD}>>file' makes the redirection permanent, so a
    # bare '2>/dev/null' on the same line would send the whole rest of the run's
    # stderr to /dev/null. The group redirects stderr only for the attempt.
    if ! { exec {LOCK_FD}>>"$LOCK_FILE"; } 2>/dev/null; then
        log_warn "Cannot open lock file ${LOCK_FILE}; concurrent runs are not prevented"
        LOCK_FD=''
        return 0
    fi

    if have flock; then
        if ! flock -n "$LOCK_FD" 2>/dev/null; then
            log_error "Another ${PROG_NAME} run holds ${LOCK_FILE}; refusing to run concurrently"
            exec {LOCK_FD}>&- 2>/dev/null || true
            LOCK_FD=''
            exit "$EXIT_ENV"
        fi
        LOCK_HELD='true'
        log_debug "Lock acquired: ${LOCK_FILE} (flock)"
        return 0
    fi

    # No flock available: pid file semantics. Only the first line counts, and the
    # content is truncated before writing, otherwise a file that grows across runs
    # would make the liveness check meaningless.
    other="$(head -n1 "$LOCK_FILE" 2>/dev/null | tr -cd '0-9')"
    if [ -n "$other" ] && [ "$other" != "$$" ] && [ "${#other}" -le 7 ] \
       && kill -0 "$other" 2>/dev/null; then
        log_error "Another ${PROG_NAME} run (pid ${other}) is active (lock ${LOCK_FILE})"
        exec {LOCK_FD}>&- 2>/dev/null || true
        LOCK_FD=''
        exit "$EXIT_ENV"
    fi
    if [ -n "$other" ] && [ "$other" != "$$" ]; then
        log_warn "Removing a stale lock left by pid ${other}"
    fi
    : >"$LOCK_FILE"
    printf '%s\n' "$$" >"$LOCK_FILE"
    LOCK_HELD='true'
    log_debug "Lock acquired: ${LOCK_FILE} (pid file)"
    return 0
}

_lock_release() {
    [ -n "$LOCK_FD" ] || return 0
    if [ "$LOCK_HELD" = 'true' ] && ! have flock; then
        printf '' >&"$LOCK_FD" 2>/dev/null || true
    fi
    exec {LOCK_FD}>&- 2>/dev/null || true
    LOCK_FD=''
    LOCK_HELD='false'
    return 0
}

_cleanup() {
    local rc=$?
    [ -n "$LOCK_FD" ] && _lock_release
    [ "${#TAIL_FILES[@]}" -gt 0 ] && rm -f -- "${TAIL_FILES[@]}" 2>/dev/null
    return "$rc"
}

# Summary and cleanup run even on interrupt, so a half-finished run still reports
# what it did and never prints the summary twice.
_on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    _cleanup
    print_summary
    exit "$rc"
}

###############################################################################
# 6. Helpers
###############################################################################
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

have() { command -v "$1" >/dev/null 2>&1; }
user_exists() { id -u "$1" >/dev/null 2>&1; }

file_owner() { # PATH -> owner name or empty
    stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null || true
}

# Read a single constant out of a WordPress config without executing it. Only the
# documented 'define( ... )' and '$name = ...' forms are recognised.
wp_config_value() { # FILE CONSTANT
    local file="$1" name="$2" value=''
    [ -f "$file" ] || return 1
    value="$(sed -n -E \
        -e "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]${name}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" \
        "$file" 2>/dev/null | head -n1)"
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

# 'grep -c' exits 1 on empty input, which turns '$(... || echo 0)' into two
# values and breaks later arithmetic. Always produce exactly one number.
count_lines() {
    local n
    n="$(printf '%s' "$1" | grep -c '' 2>/dev/null)" || n=0
    n="${n//[^0-9]/}"
    printf '%s' "${n:-0}"
}

# Bound the runtime of a child process without requiring GNU timeout.
run_with_timeout() { # SECONDS ARGV...
    local secs="$1"; shift
    [[ "$secs" =~ ^[0-9]+$ ]] || { "$@"; return $?; }
    (( secs == 0 )) && { "$@"; return $?; }
    if have timeout; then
        timeout --signal=TERM --kill-after=10 "$secs" "$@"
        return $?
    fi
    "$@" &
    local pid=$! waited=0 rc=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= secs )); then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
    rc=$?
    return "$rc"
}

# jq is optional. The reader below understands a JSON array of flat WP-CLI
# plugin objects and decodes the escapes jq would normally handle.
# Values are parsed, never evaluated.
_reader_prepare() {
    [ -n "$JSON_BAG" ] && return 0
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.reader.XXXXXX")" || return 1
    TAIL_FILES+=("$f")
    cat >"$f" <<'AWK'
# Print one record per plugin object, tab separated:
#   name <TAB> status <TAB> version <TAB> update <TAB> slug <TAB> title
function unescape(s) {
    gsub(/\\"/, "\001", s)
    gsub(/\\\//, "/", s)
    gsub(/\\n/, " ", s)
    gsub(/\\r/, "", s)
    gsub(/\\t/, " ", s)
    gsub(/\\u0026/, "\\&", s)
    gsub(/\001/, "\"", s)
    return s
}
function reset() { name=""; status=""; version=""; upd=""; slug=""; title="" }
function emit() {
    n = (name != "" ? name : slug)
    if (n == "") return
    if (upd == "") upd = "none"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", n, \
        (status == "" ? "unknown" : status), \
        (version == "" ? "n/a" : version), upd, slug, title
}
BEGIN { inobj = 0; reset() }
{
    line = $0
    while (length(line) > 0) {
        if (!inobj) {
            if (match(line, /\{[ \t]*"/)) { inobj = 1; reset(); line = substr(line, RSTART + 1) }
            else break
        }
        if (match(line, /^[ \t,]*"[^"]*"[ \t]*:[ \t]*/)) {
            key = substr(line, RSTART, RLENGTH)
            sub(/^[ \t,]*"/, "", key)
            sub(/"[ \t]*:[ \t]*$/, "", key)
            line = substr(line, RSTART + RLENGTH)
            if (match(line, /^"[^"]*"/)) { val = unescape(substr(line, 2, RLENGTH - 2)); line = substr(line, RLENGTH + 1) }
            else if (match(line, /^(true|false|null|-?[0-9]+(\.[0-9]+)?)/)) { val = substr(line, RSTART, RLENGTH); line = substr(line, RLENGTH + 1) }
            else { inobj = 0; break }
            if (key == "name") name = val
            else if (key == "status") status = val
            else if (key == "version") version = val
            else if (key == "update") upd = val
            else if (key == "slug") slug = val
            else if (key == "title") title = val
        }
        else if (match(line, /^[ \t,]*\}/)) { emit(); inobj = 0; line = substr(line, RSTART + RLENGTH) }
        else { line = substr(line, 2) }
    }
}
END { if (inobj) emit() }
AWK
    JSON_BAG="$f"
    return 0
}

# Find the first line that opens a JSON array and take everything from there.
# PHP warnings keep the same line layout, so line-wise filtering is enough.
json_extract_array() {
    local raw cleaned
    raw="$(cat)"
    cleaned="$(printf '%s' "$raw" | sed -n '/^[[:space:]]*\[/,$p')"
    if [ -z "$cleaned" ]; then
        printf '%s' "$raw"
        return 1
    fi
    printf '%s' "$cleaned"
    return 0
}

plugins_to_tsv() { # JSON -> TSV on stdout
    local json="$1"
    _reader_prepare || return 1
    printf '%s' "$json" | awk -f "$JSON_BAG"
}

# Case-insensitive substring filter over name and slug. The needle travels in the
# environment, so a quote in --name cannot rewrite the program.
plugins_filter() { # NEEDLE
    local needle="$1"
    [ -n "$needle" ] || { cat; return 0; }
    WP_NEEDLE="$needle" awk -F'\t' '
        BEGIN { needle = tolower(ENVIRON["WP_NEEDLE"]) }
        index(tolower($1), needle) || index(tolower($5), needle) { print }
    '
}

# Pick exactly one plugin. Ambiguity is an error, not a guess.
# exit 0 = selected on stdout, 2 = ambiguous (candidates on stderr), 1 = none
# Note: 'exit 0' inside a rule jumps to END, and the status of the last exit wins,
# so the match state is carried in a variable instead of exiting early.
plugins_select_one() { # NEEDLE FILE
    local needle="$1" file="$2"
    WP_NEEDLE="$needle" awk -F'\t' '
        BEGIN { needle = tolower(ENVIRON["WP_NEEDLE"]) }
        {
            if (hit) next
            if (tolower($5) == needle || tolower($1) == needle) { print $0; hit = 1; next }
            if (needle != "" && (index(tolower($1), needle) || index(tolower($5), needle))) cand[c++] = $0
        }
        END {
            if (hit) exit 0
            if (c == 1) { print cand[0]; exit 0 }
            if (c > 1) { for (i = 0; i < c; i++) print cand[i] > "/dev/stderr"; exit 2 }
            exit 1
        }
    ' "$file" 2>"$TMP_PICK_ERR"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

csv_escape() {
    local s="$1"
    case "$s" in
        *[\",]*|*$'\n'*) s="\"${s//\"/\"\"}\"" ;;
    esac
    printf '%s' "$s"
}

# Truncate for display only, never for data.
fit() { # STRING WIDTH
    local s="$1" w="$2"
    if (( ${#s} <= w )); then
        printf '%s' "$s"
    elif (( w > 3 )); then
        printf '%s...' "${s:0:$((w - 3))}"
    else
        printf '%s' "${s:0:w}"
    fi
}

pad() { # STRING WIDTH
    local s="$1" w="$2" n
    n=$(( w - ${#s} ))
    (( n < 0 )) && n=0
    printf '%s%*s' "$s" "$n" ''
}

TMP_PICK=''
TMP_PICK_ERR=''
init_temps() {
    local d="${TMPDIR:-/tmp}"
    TMP_PICK="$(mktemp "${d}/wp-cli-update.pick.XXXXXX")" || return 1
    TMP_PICK_ERR="$(mktemp "${d}/wp-cli-update.pickerr.XXXXXX")" || return 1
    TAIL_FILES+=("$TMP_PICK" "$TMP_PICK_ERR")
    return 0
}

###############################################################################
# 7. Configuration file, parsed and never sourced
###############################################################################
# A config file is data. Refuse anything that looks like an attempt to make it
# code: command substitution, semicolons, pipes, redirections, backticks.
_config_unsafe() { # FILE
    local owner
    [ -f "$1" ] || return 0
    owner="$(file_owner "$1")"
    if [ -n "$owner" ] && [ "$owner" != 'root' ] && [ "$owner" != "$(id -un)" ]; then
        log_warn "Config $1 is owned by '${owner}'; ignoring it"
        return 0
    fi
    if grep -Eq '[`]|[$]\(|;[[:space:]]*[A-Za-z_]|[|]|[<>]' "$1" 2>/dev/null; then
        log_error "Config $1 contains shell metacharacters; refusing to read it (use plain KEY=VALUE lines)"
        return 0
    fi
    return 1
}

_config_set() { # KEY VALUE
    local key="$1" value="$2"
    case "$key" in
        WP_CLI_PATH)              WP_CLI_PATH="$value" ;;
        SITES_FILE)               SITES_FILE="$value" ;;
        DISCOVER_SCRIPT)          DISCOVER_SCRIPT="$value" ;;
        LOG_FILE)                 LOG_FILE="$value" ;;
        ERROR_LOG_FILE)           ERROR_LOG_FILE="$value" ;;
        LOCK_FILE)                LOCK_FILE="$value" ;;
        LOG_MAX_BYTES)            LOG_MAX_BYTES="$value" ;;
        LOG_KEEP)                 LOG_KEEP="$value" ;;
        LOG_LEVEL)                LOG_LEVEL="${value,,}" ;;
        USER_ENV_PREFIX)          USER_ENV_PREFIX="$value" ;;
        PLUGIN_SKIP_LIST)         PLUGIN_SKIP_LIST="$value" ;;
        SKIP_PLUGINS_FOR_LISTING) SKIP_PLUGINS_FOR_LISTING="${value,,}" ;;
        EXPORT_USER_HOME)         EXPORT_USER_HOME="${value,,}" ;;
        ALLOW_ROOT_FLAG)          ALLOW_ROOT_FLAG="${value,,}" ;;
        WP_COMMAND_TIMEOUT)       WP_COMMAND_TIMEOUT="$value" ;;
        PAGE_LIMIT)               PAGE_LIMIT="$value" ;;
        OUTPUT_FORMAT)            OUTPUT_FORMAT="${value,,}" ;;
        ASTRA_SLUG)               ASTRA_SLUG="$value" ;;
        ASTRA_LICENSE_COMMAND)    ASTRA_LICENSE_COMMAND="$value" ;;
        licence_value)            licence_value="$value" ;;
        TMPDIR)                   TMPDIR="$value" ;;
        *) log_debug "Unknown config key '${key}' (line ${CONFIG_LINENO}), ignored" ;;
    esac
}

load_config_file() { # FILE
    local file="$1" line key value
    [ -f "$file" ] || return 0
    if _config_unsafe "$file"; then
        log_warn "Skipping unsafe config file: ${file}"
        return 0
    fi
    CONFIG_LINENO=0
    while IFS= read -r line || [ -n "$line" ]; do
        CONFIG_LINENO=$((CONFIG_LINENO + 1))
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*|[[:space:]]'#'*) continue ;;
        esac
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            log_warn "${file}:${CONFIG_LINENO}: not a KEY=VALUE line, ignored"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="$(trim "${BASH_REMATCH[2]}")"
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac
        _config_set "$key" "$value"
    done <"$file"
    CONFIG_FILE="$file"
    log_debug "Config loaded: ${file}"
    return 0
}

# Environment beats config files; the command line beats both.
apply_environment() {
    local v
    for v in WP_CLI_PATH SITES_FILE DISCOVER_SCRIPT LOG_FILE ERROR_LOG_FILE LOCK_FILE; do
        [ -n "${!v:-}" ] && printf -v "$v" '%s' "${!v}"
    done
    [ -n "${WP_CLI_UPDATE_LOG_LEVEL:-}" ] && LOG_LEVEL="${WP_CLI_UPDATE_LOG_LEVEL,,}"
    [ -n "${WP_CLI_UPDATE_PLUGIN_SKIP_LIST:-}" ] && PLUGIN_SKIP_LIST="$WP_CLI_UPDATE_PLUGIN_SKIP_LIST"
    [ -n "${WP_CLI_UPDATE_TIMEOUT:-}" ] && WP_COMMAND_TIMEOUT="$WP_CLI_UPDATE_TIMEOUT"
    [ -n "${WP_CLI_UPDATE_PAGE_LIMIT:-}" ] && PAGE_LIMIT="$WP_CLI_UPDATE_PAGE_LIMIT"
    [ -n "${WP_CLI_UPDATE_LICENCE:-}" ] && licence_value="$WP_CLI_UPDATE_LICENCE"
    [ -n "${WP_CLI_UPDATE_CONFIG:-}" ] && load_config_file "$WP_CLI_UPDATE_CONFIG"
    return 0
}
###############################################################################
# 8. Usage
###############################################################################
usage() { # EXIT_CODE
    local rc="${1:-$EXIT_USAGE}"
    cat <<EOF
${PROG_NAME} v${SCRIPT_VERSION} - WordPress maintenance automation via WP-CLI

Usage:
  ${PROG_NAME} <MODE> [options]
  ${PROG_NAME} --check [--site PATH]

Modes (exactly one, unless --status/--list-modes/--help is used):
  -f, --full             core + plugins + themes + database + cron
  -c, --core             WordPress core update and database schema update
  -p, --plugins          update all plugins
  -t, --themes           update all themes
  -d, --db-optimize      optimize and repair the database
  -x, --db-fix           repair the database only
  -r, --cron             run due cron events
  -s, --astra            update the Astra add-on, activating the licence if needed
  -l, --list-plugins     list plugins (table, json, csv or tsv)
  -m, --plugin-manage    activate, deactivate or delete one plugin
      --check            validate the environment and the site list, change nothing
      --status           print the last run summary and log sizes
      --list-modes       print mode names, one per line, and exit
  -V, --version          print the version and exit

Options:
  -S, --site PATH        operate on one site only (overrides the site list)
  -A, --action ACTION    plugin action for --plugin-manage: activate|deactivate|delete
  -N, --name NAME        plugin name or slug (substring, case-insensitive)
  -F, --force            skip the delete confirmation
  -J, --json             shorthand for --format json
      --format FMT       output format: table|json|csv|tsv (default: table)
      --page N           rows per page in the table view (0 = all, default 0)
  -n, --dry-run          show what would run, execute nothing
      --timeout SEC      per-command timeout in seconds (0 disables, default ${WP_COMMAND_TIMEOUT})
      --config FILE      read settings from FILE (default: ${DEFAULT_CONFIG_LOCAL})
      --sites FILE       site list (default: ${DEFAULT_SITES_FILE})
      --log-file FILE    main log (default: ${DEFAULT_LOG_FILE})
      --error-log-file FILE  error log (default: ${DEFAULT_ERROR_LOG_FILE})
      --lock-file FILE   lock file (default: ${DEFAULT_LOCK_FILE})
      --wp PATH          path to the wp binary (default: ${DEFAULT_WP_CLI})
      --user-env LIST    space separated list of variables to export per site
      --skip-plugins LIST  plugins to skip during updates ('' disables skipping)
      --skip-plugins-for-listing on|off  also pass --skip-plugins to list commands
      --allow-root WHEN  auto|always|never (default: auto, only when euid = 0)
      --astra-key KEY    Astra licence key (prefer the WP_CLI_UPDATE_LICENCE variable)
      --astra-slug SLUG  Astra add-on slug (default: ${ASTRA_SLUG})
      --color WHEN       auto|always|never (default: auto)
      --no-color         same as --color never
      --quiet            console shows warnings and errors only
  -D, --debug            verbose logging, implies log level debug
  -y, --yes              do not ask for the delete confirmation
  -h, --help             show this help and exit with status 0

Exit codes:
  0 success   1 operational error   2 usage error   3 environment error   4 config error

Files:
  site list          ${SITES_FILE}
  log                ${LOG_FILE}
  error log          ${ERROR_LOG_FILE}
  lock               ${LOCK_FILE}

Examples:
  ${PROG_NAME} --full
  ${PROG_NAME} -p --site /var/www/example.com
  ${PROG_NAME} -l --name woocommerce --format csv
  ${PROG_NAME} -l --format json --quiet
  ${PROG_NAME} -m -A deactivate -N jetpack -S /var/www/example.com -y
  ${PROG_NAME} -d --dry-run
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

list_modes() {
    printf '%s\n' "$MODE_FULL" "$MODE_CORE" "$MODE_PLUGINS" "$MODE_THEMES" \
        "$MODE_DB_OPTIMIZE" "$MODE_DB_FIX" "$MODE_CRON" "$MODE_ASTRA" \
        "$MODE_LIST_PLUGINS" "$MODE_PLUGIN_MANAGE" "$MODE_CHECK" "$MODE_STATUS"
}

usage_error() { # MESSAGE
    printf '%s%s: %s%s\n' "$C_RED" "$PROG_NAME" "$1" "$C_RESET" >&2
    printf 'Try "%s --help" for usage.\n' "$PROG_NAME" >&2
    exit "$EXIT_USAGE"
}

###############################################################################
# 9. Argument parsing
###############################################################################
_need_value() { # OPTION NEXT
    local opt="$1" next="${2:-}"
    if [ -z "$next" ] || [[ "$next" == -* ]]; then
        usage_error "option ${opt} requires a value"
    fi
    printf '%s' "$next"
}

_set_mode() { # MODE
    if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        usage_error "conflicting modes: --${MODE} and --${1}"
    fi
    MODE="$1"
}

parse_args() {
    local arg next
    while [ $# -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
            --debug|-D)          DEBUG_MODE='true'; LOG_LEVEL='debug' ;;
            -n|--dry-run)        DRY_RUN='true' ;;
            -y|--yes)            ASSUME_YES='true' ;;
            -F|--force)          FORCE_MODE='true' ;;
            -J|--json)           OUTPUT_FORMAT='json' ;;
            --quiet)             QUIET_MODE='true' ;;

            -f|--full)           _set_mode "$MODE_FULL" ;;
            -c|--core)           _set_mode "$MODE_CORE" ;;
            -p|--plugins)        _set_mode "$MODE_PLUGINS" ;;
            -t|--themes)         _set_mode "$MODE_THEMES" ;;
            -d|--db-optimize)    _set_mode "$MODE_DB_OPTIMIZE" ;;
            -x|--db-fix)         _set_mode "$MODE_DB_FIX" ;;
            -r|--cron)           _set_mode "$MODE_CRON" ;;
            -s|--astra)          _set_mode "$MODE_ASTRA" ;;
            -l|--list-plugins)   _set_mode "$MODE_LIST_PLUGINS" ;;
            -m|--plugin-manage)  _set_mode "$MODE_PLUGIN_MANAGE" ;;
            --check)             _set_mode "$MODE_CHECK"; NO_ACTION='true' ;;
            --status)            _set_mode "$MODE_STATUS"; NO_ACTION='true' ;;
            --list-modes)        LIST_MODES='true' ;;

            -S|--site)           next="$(_need_value "$arg" "${1:-}")"; TARGET_SITE="$next"; shift ;;
            -A|--action)         next="$(_need_value "$arg" "${1:-}")"; PLUGIN_ACTION="${next,,}"; shift ;;
            -N|--name)           next="$(_need_value "$arg" "${1:-}")"; PLUGIN_NAME="$next"; shift ;;
            --format)            next="$(_need_value "$arg" "${1:-}")"; OUTPUT_FORMAT="${next,,}"; shift ;;
            --page|--page-limit) next="$(_need_value "$arg" "${1:-}")"; PAGE_LIMIT="$next"; shift ;;
            --timeout)           next="$(_need_value "$arg" "${1:-}")"; WP_COMMAND_TIMEOUT="$next"; shift ;;
            --config)            next="$(_need_value "$arg" "${1:-}")"; CONFIG_REQUESTED="$next"; shift ;;
            --sites)             next="$(_need_value "$arg" "${1:-}")"; SITES_FILE="$next"; shift ;;
            --lock-file)         next="$(_need_value "$arg" "${1:-}")"; LOCK_FILE="$next"; shift ;;
            --log-file)          next="$(_need_value "$arg" "${1:-}")"; LOG_FILE="$next"; shift ;;
            --error-log-file)    next="$(_need_value "$arg" "${1:-}")"; ERROR_LOG_FILE="$next"; shift ;;
            --wp)                next="$(_need_value "$arg" "${1:-}")"; WP_CLI_PATH="$next"; shift ;;
            --user-env)          next="$(_need_value "$arg" "${1:-}")"; USER_ENV_PREFIX="$next"; shift ;;
            --skip-plugins)      next="${1:-}"; shift; PLUGIN_SKIP_LIST="$next" ;;
            --skip-plugins-for-listing)
                                 next="$(_need_value "$arg" "${1:-}")"; SKIP_PLUGINS_FOR_LISTING="${next,,}"; shift ;;
            --allow-root)        next="$(_need_value "$arg" "${1:-}")"; ALLOW_ROOT_FLAG="${next,,}"; shift ;;
            --astra-key)         next="$(_need_value "$arg" "${1:-}")"; licence_value="$next"; shift ;;
            --astra-slug)        next="$(_need_value "$arg" "${1:-}")"; ASTRA_SLUG="$next"; shift ;;
            --color)             next="$(_need_value "$arg" "${1:-}")"; COLOR_MODE="${next,,}"; shift ;;
            --no-color)          NO_COLOR_SET='true' ;;

            -V|--version)        PRINT_VERSION='true' ;;
            -h|--help)           PRINT_HELP='true' ;;
            --)                  break ;;
            *)                   usage_error "unknown option: ${arg}" ;;
        esac
    done
}

validate_options() {
    case "$OUTPUT_FORMAT" in
        table|json|csv|tsv) ;;
        *) usage_error "invalid --format value: ${OUTPUT_FORMAT}" ;;
    esac
    case "$ALLOW_ROOT_FLAG" in
        auto|always|never) ;;
        *) usage_error "invalid --allow-root value: ${ALLOW_ROOT_FLAG} (auto, always, never)" ;;
    esac
    case "$COLOR_MODE" in
        auto|always|never) ;;
        *) usage_error "invalid --color value: ${COLOR_MODE} (auto, always, never)" ;;
    esac
    case "$SKIP_PLUGINS_FOR_LISTING" in
        on)   SKIP_PLUGINS_FOR_LISTING='true' ;;
        off)  SKIP_PLUGINS_FOR_LISTING='false' ;;
        true|false) ;;
        *) usage_error "invalid --skip-plugins-for-listing value (on or off)" ;;
    esac
    [[ "$PAGE_LIMIT" =~ ^[0-9]+$ ]] || usage_error "invalid --page value: ${PAGE_LIMIT}"
    [[ "$WP_COMMAND_TIMEOUT" =~ ^[0-9]+$ ]] || usage_error "invalid --timeout value: ${WP_COMMAND_TIMEOUT}"
    [[ "$LOG_KEEP" =~ ^[0-9]+$ ]] || LOG_KEEP='3'
    [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || LOG_MAX_BYTES='5242880'
    case "$LOG_LEVEL" in
        debug|info|success|warn|warning|error) ;;
        *) LOG_LEVEL='info' ;;
    esac

    if [ -z "$MODE" ] && [ "$LIST_MODES" != 'true' ] && [ "$PRINT_HELP" != 'true' ] \
       && [ "$PRINT_VERSION" != 'true' ]; then
        usage_error "no mode specified"
    fi

    if [ "$MODE" = "$MODE_PLUGIN_MANAGE" ]; then
        [ -n "$PLUGIN_ACTION" ] || usage_error "--plugin-manage requires --action activate|deactivate|delete"
        [ -n "$PLUGIN_NAME" ] || usage_error "--plugin-manage requires --name"
        case "$PLUGIN_ACTION" in
            "$ACTION_ACTIVATE"|"$ACTION_DEACTIVATE"|"$ACTION_DELETE") ;;
            *) usage_error "invalid --action: ${PLUGIN_ACTION}" ;;
        esac
        if [ "$PLUGIN_ACTION" = "$ACTION_DELETE" ] && [ "$DRY_RUN" != 'true' ] \
           && [ "$FORCE_MODE" != 'true' ] && [ "$ASSUME_YES" != 'true' ] && [ ! -t 0 ]; then
            usage_error "delete on a non-interactive stdin needs --force or --yes"
        fi
    fi

    if [ "$MODE" = "$MODE_ASTRA" ] && [ -z "$licence_value" ]; then
        usage_error "--astra needs a licence: set WP_CLI_UPDATE_LICENCE or pass --astra-key"
    fi
    return 0
}

###############################################################################
# 10. Startup banner
###############################################################################
_mode_description() {
    case "$1" in
        "$MODE_FULL")          printf '%s' 'full maintenance: core, plugins, themes, database, cron' ;;
        "$MODE_CORE")          printf '%s' 'core update and database schema update' ;;
        "$MODE_PLUGINS")       printf '%s' 'update all plugins' ;;
        "$MODE_THEMES")        printf '%s' 'update all themes' ;;
        "$MODE_DB_OPTIMIZE")   printf '%s' 'database optimize and repair' ;;
        "$MODE_DB_FIX")        printf '%s' 'database repair' ;;
        "$MODE_CRON")          printf '%s' 'run due cron events' ;;
        "$MODE_ASTRA")         printf '%s' 'update the Astra add-on, activate the licence if needed' ;;
        "$MODE_LIST_PLUGINS")  printf '%s' 'list plugins' ;;
        "$MODE_PLUGIN_MANAGE") printf '%s' "${PLUGIN_ACTION} plugin '${PLUGIN_NAME}'" ;;
        "$MODE_CHECK")         printf '%s' 'validate the environment and the site list' ;;
        "$MODE_STATUS")        printf '%s' 'show the last run summary' ;;
        *)                     printf '%s' 'unknown mode' ;;
    esac
}

show_banner() {
    [ "$HEADER_SHOWN" = 'true' ] && return 0
    HEADER_SHOWN='true'
    [ "$QUIET_MODE" = 'true' ] && return 0
    [ "$OUTPUT_FORMAT" != 'table' ] && return 0

    local width=70 target
    printf '\n%sthe %s%s\n' "$C_BOLD" '=' "$C_RESET" >/dev/null 2>&1 || true
    printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$(_repeat '=' "$width")" "$C_RESET" >&2
    printf '%s %s v%s%s\n' "$C_BOLD" "$PROG_NAME" "$SCRIPT_VERSION" "$C_RESET" >&2
    printf '%s %s%s\n' "$C_DIM" "$(_mode_description "$MODE")" "$C_RESET" >&2
    printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$(_repeat '=' "$width")" "$C_RESET" >&2

    if [ -n "$TARGET_SITE" ]; then target="$TARGET_SITE"; else target="all sites from $SITES_FILE"; fi
    printf '  %s%s%s\n' "$C_DIM" "$(pad 'site' 14)" "$C_RESET" >/dev/null 2>&1 || true
    printf '  %-14s %s\n' 'site:' "$(fit "$target" 52)" >&2
    printf '  %-14s %s\n' 'wp-cli:' "$WP_CLI_PATH" >&2
    printf '  %-14s %s\n' 'log level:' "$LOG_LEVEL" >&2
    [ "$DRY_RUN" = 'true' ] && printf '  %-14s %s\n' 'dry run:' 'yes, nothing will be executed' >&2
    [ -n "$CONFIG_FILE" ] && printf '  %-14s %s\n' 'config:' "$CONFIG_FILE" >&2
    if [ -n "$TARGET_SITE" ] && [ ! -d "$TARGET_SITE" ]; then
        printf '%s  warning: %s does not exist%s\n' "$C_YELLOW" "$TARGET_SITE" "$C_RESET" >&2
    fi
    printf '\n' >&2
    return 0
}

###############################################################################
# 11. Privilege handling
###############################################################################
# Export the per-site environment inside the child shell. Only the variables
# named in USER_ENV_PREFIX are considered, so no user-supplied name is exported.
_site_env_stmt() { # SITE
    local site="$1" var value out=''
    local domain home_dir
    domain="$(basename "$site")"
    home_dir="$(dirname "$(dirname "$site")")"
    for var in $USER_ENV_PREFIX; do
        case "$var" in
            DOCUMENT_URI|HTTP_HOST) value="$domain" ;;
            DOCUMENT_ROOT)          value="$site" ;;
            HOMEDIR)                value="$home_dir" ;;
            WP_CLI_USER_HOME)       value="$home_dir" ;;
            *)                      log_warn "Unknown entry '${var}' in USER_ENV_PREFIX, skipped"
                                    continue ;;
        esac
        out+="export ${var}=$(sh_quote "$value"); "
    done
    if [ "$EXPORT_USER_HOME" = 'true' ]; then
        out+="export HOME=$(sh_quote "$home_dir"); "
    fi
    printf '%s' "$out"
}

_allow_root_flag() {
    case "$ALLOW_ROOT_FLAG" in
        always) printf '%s' '--allow-root' ;;
        never)  printf '%s' '' ;;
        auto)
            if [ "$(id -u)" -eq 0 ]; then printf '%s' '--allow-root'; else printf '%s' ''; fi
            ;;
    esac
}

# Marker substituted instead of the licence inside the generated command text.
# A function is used so that no credential-shaped literal is needed anywhere in
# this file.
licence_marker() { printf '%s' 'WP_CLI_LICENCE_PLACEHOLDER'; }

# Path of the one-shot file the licence is handed over through. The secret is
# never part of a command line and never part of a log line: the child reads it
# from a mode-600 file and the file is removed right after the call.
LICENCE_FILE=''

_licence_handoff_open() {
    [ -n "$licence_value" ] || return 1
    LICENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.licence.XXXXXX")" || { LICENCE_FILE=''; return 1; }
    chmod 600 "$LICENCE_FILE" 2>/dev/null || true
    printf '%s' "$licence_value" >"$LICENCE_FILE"
}

_licence_handoff_close() {
    [ -n "$LICENCE_FILE" ] || return 0
    rm -f "$LICENCE_FILE" 2>/dev/null || true
    LICENCE_FILE=''
}

# Build the complete /bin/sh command text for one WP-CLI call. Every dynamic
# token is quoted with sh_quote, so a site path or a plugin name can never be
# parsed as shell code.
wp_child_cmd() { # SITE USER ARGV...
    local site="$1" user="$2"; shift 2
    local inner prefix arg quoted=''
    local allow_root
    allow_root="$(_allow_root_flag)"

    prefix="cd $(sh_quote "$site") && $(_site_env_stmt "$site")"

    quoted="$(sh_quote "$WP_CLI_PATH")"
    for arg in "$@"; do
        case "$arg" in
            "$(licence_marker)")
                if [ -n "$LICENCE_FILE" ]; then
                    quoted+=" \"\$(cat -- $(sh_quote "$LICENCE_FILE"))\""
                else
                    quoted+=" \"\$WP_CLI_LICENCE\""
                fi
                ;;
            *) quoted+=" $(sh_quote "$arg")" ;;
        esac
    done
    [ -n "$allow_root" ] && quoted+=" $(sh_quote "$allow_root")"

    inner="${prefix}exec ${quoted}"

    if [ "$(id -u)" -eq 0 ] && [ "$user" != 'root' ]; then
        if have runuser; then
            printf 'runuser -u %s -- /bin/sh -c %s' "$(sh_quote "$user")" "$(sh_quote "$inner")"
            return 0
        fi
        if have sudo; then
            printf 'sudo -n -u %s -- /bin/sh -c %s' "$(sh_quote "$user")" "$(sh_quote "$inner")"
            return 0
        fi
        printf 'su -s /bin/sh -c %s %s' "$(sh_quote "$inner")" "$(sh_quote "$user")"
        return 0
    fi
    printf '%s' "$inner"
}

###############################################################################
# 12. WP-CLI invocation
###############################################################################
WP_LAST_OUTPUT=''
WP_LAST_STATUS=0

# The single place where WP-CLI is executed. The command text is assembled by
# wp_child_cmd; --print-command shows it without running it.
wp_exec() { # SITE USER ARGV...
    local site="$1" user="$2"; shift 2
    [ "${1:-}" = '--' ] && shift

    local cmdtext
    cmdtext="$(wp_child_cmd "$site" "$user" "$@")"

    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] ${cmdtext}"
        WP_LAST_OUTPUT=''
        WP_LAST_STATUS=0
        return 0
    fi

    # Errors are appended to the log by reference, so the secret never has to be
    # named in a log line.
    local out_log err_log
    out_log="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.command.XXXXXX")" || out_log='/dev/null'
    err_log="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.stderr.XXXXXX")" || err_log='/dev/null'
    {
        printf 'argv:'
        for a in "$@"; do
            case "$a" in
                "$(licence_marker)") printf ' %s' "$a" ;;
                *) printf ' %s' "$(sh_quote "$a")" ;;
            esac
        done
        printf '\n'
    } >>"${out_log:-/dev/null}" 2>/dev/null || true

    _licence_handoff_open || true
    cmdtext="$(wp_child_cmd "$site" "$user" "$@")"
    log_debug "exec: ${cmdtext}"

    local out_file err_file rc
    out_file="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.out.XXXXXX")" || return 1
    err_file="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.err.XXXXXX")" || return 1

    /bin/sh -c "$cmdtext" >"$out_file" 2>"$err_file"
    rc=$?
    _licence_handoff_close
    WP_LAST_STATUS=$rc
    WP_LAST_OUTPUT="$(cat "$out_file")"
    local errtext
    errtext="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
    if [ -n "$errtext" ]; then
        WP_LAST_OUTPUT="${WP_LAST_OUTPUT:+${WP_LAST_OUTPUT}
}${errtext}"
    fi

    if [ "$rc" -ne 0 ]; then
        log_error_detail "wp ${user}@${site}" "see ${out_log}" "$rc" "$WP_LAST_OUTPUT"
    fi
    return "$rc"
}

# The argument list shared by every WP-CLI call. --skip-plugins changes the set
# of plugins WP-CLI loads, therefore it is only passed to update commands, and to
# list commands only when explicitly requested: a listing that omits plugins is a
# wrong listing, not a fast one.
_common_args_print() { # KIND list|update|plain
    local kind="$1"
    if [ "$kind" = 'update' ] || { [ "$kind" = 'list' ] && [ "$SKIP_PLUGINS_FOR_LISTING" = 'true' ]; }; then
        [ -n "$PLUGIN_SKIP_LIST" ] && printf '%s\n' "--skip-plugins=${PLUGIN_SKIP_LIST}"
    fi
    return 0
}

# Run a WP-CLI command, count the result and log the first output line. The full
# output stays in WP_LAST_OUTPUT and is deliberately NOT copied to stdout, so
# callers can use it directly; capturing run_wp output in a command substitution
# would push the counter updates into a subshell and lose them.
run_wp() { # SITE USER ARGV...
    local site="$1" user="$2"; shift 2
    local label="wp $*"

    if wp_exec "$site" "$user" "$@"; then
        STAT_OPS_OK=$((STAT_OPS_OK + 1))
        local first
        first="$(printf '%s' "$WP_LAST_OUTPUT" | sed -n '1p')"
        if [ -n "$first" ]; then
            log_success "${label}: ${first}"
        else
            log_success "${label}"
        fi
        return 0
    fi

    STAT_OPS_FAILED=$((STAT_OPS_FAILED + 1))
    log_error "${label} failed (exit ${WP_LAST_STATUS})"
    print_error_block "$site" "$label" "$WP_LAST_OUTPUT"
    return "$WP_LAST_STATUS"
}

# Update commands receive --skip-plugins so that one broken plugin cannot abort a
# maintenance run. Listing and management commands do not: the flag changes the
# set of plugins WP-CLI sees, so a filtered listing would be wrong.
run_wp_update() { # SITE USER ARGV...
    local site="$1" user="$2"; shift 2
    local -a args=("$@")
    local a
    while IFS= read -r a; do
        [ -n "$a" ] && args+=("$a")
    done < <(_common_args_print update)
    run_wp "$site" "$user" "${args[@]}"
}

print_error_block() { # SITE LABEL OUTPUT
    local site="$1" label="$2" output="$3" total shown=0 line
    local width=68
    printf '\n%s+%s+%s\n' "$C_RED" "$(_repeat '-' $((width - 2)))" "$C_RESET" >&2
    printf '%s| %s%s\n' "$C_RED" "$(fit "$label" $((width - 4)))" "$C_RESET" >&2
    printf '%s| site: %s%s\n' "$C_RED" "$(fit "$site" $((width - 10)))" "$C_RESET" >&2
    printf '%s+%s+%s\n' "$C_RED" "$(_repeat '-' $((width - 2)))" "$C_RESET" >&2
    total="$(count_lines "$output")"
    while IFS= read -r line; do
        if (( shown < 20 )); then
            printf '%s| %s%s\n' "$C_RED" "$(fit "$line" $((width - 4)))" "$C_RESET" >&2
            shown=$((shown + 1))
        fi
    done <<<"$output"
    if (( total > shown )); then
        printf '%s| ... %d more line(s); full text in %s%s\n' \
            "$C_RED" "$((total - shown))" "$ERROR_LOG_FILE" "$C_RESET" >&2
    fi
    printf '%s+%s+%s\n\n' "$C_RED" "$(_repeat '-' $((width - 2)))" "$C_RESET" >&2
    return 0
}
###############################################################################
# 13. Site user resolution
###############################################################################
# Candidate owners of an installation, best first. Kept separate from the choice
# so that the ordering is testable without a real file system.
site_user_candidates() { # SITE
    local site="$1" config="${site}/wp-config.php" v
    if [ -f "$config" ]; then
        v="$(file_owner "$config")"
        [ -n "$v" ] && printf '%s\n' "$v"
    fi
    v="$(file_owner "$site")"
    [ -n "$v" ] && printf '%s\n' "$v"
    if [ -f "$config" ]; then
        v="$(wp_config_value "$config" DB_USER || true)"
        [ -n "$v" ] && printf '%s\n' "$v"
    fi
    # Convention on /var/www/<site>, /srv/<user>/<site> and /home/<user>/... layouts.
    local -a parts=()
    local IFS='/'
    read -r -a parts <<<"$site"
    if (( ${#parts[@]} >= 4 )) && [ -n "${parts[3]}" ]; then
        printf '%s\n' "${parts[3]}"
    fi
    return 0
}

# Resolve the WordPress owner, skipping candidates that cannot be used.
get_wp_user() { # SITE -> user name, exit 1 when nothing usable
    local site="$1" candidate tried=''
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        case "$candidate" in
            root|nobody|UNKNOWN|0) continue ;;
        esac
        case " ${tried} " in *" ${candidate} "*) continue ;; esac
        tried="${tried} ${candidate}"
        if user_exists "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
        log_debug "Candidate '${candidate}' for ${site} is not a local user"
    done < <(site_user_candidates "$site")
    return 1
}

###############################################################################
# 14. Site list handling
###############################################################################
is_wordpress_root() { # DIR
    local dir="$1"
    [ -f "${dir}/wp-config.php" ] || return 1
    [ -f "${dir}/wp-load.php" ] || [ -f "${dir}/wp-includes/version.php" ] || return 1
    return 0
}

# Read the site list, skipping blanks and comments. CRLF is tolerated so that a
# list edited on Windows still works.
load_sites() { # FILE -> one site per line on stdout
    local file="$1" line n=0
    if [ ! -f "$file" ]; then
        log_error "Site list not found: ${file}"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        n=$((n + 1))
        printf '%s\n' "$line"
    done <"$file"
    if [ "$n" -eq 0 ]; then
        log_warn "No usable entries in ${file}"
        return 1
    fi
    return 0
}

ensure_sites_file() {
    [ -f "$SITES_FILE" ] && { log_debug "Site list: ${SITES_FILE}"; return 0; }

    log_warn "Site list not found: ${SITES_FILE}"
    if [ -f "$DISCOVER_SCRIPT" ]; then
        log_info "Running discovery: ${DISCOVER_SCRIPT}"
        if [ "$DRY_RUN" = 'true' ]; then
            log_info "[dry-run] ${DISCOVER_SCRIPT} --output $(sh_quote "$SITES_FILE")"
        elif bash "$DISCOVER_SCRIPT" --output "$SITES_FILE"; then
            log_success "Discovery finished"
        else
            log_warn "Discovery exited with status $?"
        fi
    else
        log_warn "Discovery script not found: ${DISCOVER_SCRIPT}"
    fi

    [ -f "$SITES_FILE" ] && { log_success "Site list ready: ${SITES_FILE}"; return 0; }

    if [ ! -t 0 ]; then
        log_error "No site list and no interactive terminal; use --site PATH or --sites FILE"
        return 1
    fi

    local answer=''
    printf 'Absolute path to a WordPress root (empty input aborts): ' >&2
    IFS= read -r answer || answer=''
    answer="$(trim "$answer")"
    [ -n "$answer" ] || { log_error "No path provided"; return 1; }
    [ -d "$answer" ] || { log_error "Not a directory: ${answer}"; return 1; }
    if ! is_wordpress_root "$answer"; then
        log_error "Not a WordPress installation (needs wp-config.php and wp-load.php): ${answer}"
        return 1
    fi
    printf '%s\n' "$answer" >"$SITES_FILE"
    log_success "Saved to ${SITES_FILE}"
    return 0
}

###############################################################################
# 15. Plugin listing
###############################################################################
PLUGIN_TMP=''

# Ask WP-CLI for the plugin list and normalise it into TSV. Returns non-zero when
# WP-CLI failed or the output is not JSON, and reports which of the two happened.
_plugin_records() { # SITE USER FILTER
    local site="$1" user="$2" filter="${3:-}"
    local -a args=(plugin list --format=json "--fields=${PLUGIN_FIELDS}")
    local a
    while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done < <(_common_args_print list)

    if ! wp_exec "$site" "$user" -- "${args[@]}"; then
        log_error "Cannot list plugins on ${site} (exit ${WP_LAST_STATUS})"
        print_error_block "$site" 'wp plugin list' "$WP_LAST_OUTPUT"
        return 1
    fi

    local json
    if ! json="$(printf '%s' "$WP_LAST_OUTPUT" | json_extract_array)"; then
        log_error "Plugin list on ${site} is not JSON: $(fit "$(printf '%s' "$json" | sed -n 1p)" 140)"
        return 1
    fi

    : >"$PLUGIN_TMP"
    if [ "$(trim "$json")" = '[]' ]; then
        return 0
    fi
    if ! plugins_to_tsv "$json" >"$PLUGIN_TMP"; then
        log_error "Cannot parse the plugin list from ${site}"
        return 1
    fi
    if [ -n "$filter" ]; then
        local filtered
        filtered="$(plugins_filter "$filter" <"$PLUGIN_TMP")" || true
        # The trailing newline matters: 'read' returns non-zero at end of input
        # without a delimiter, so a file whose last line has no newline loses that
        # line in every 'while read' loop below.
        {
            if [ -n "$filtered" ]; then printf '%s\n' "$filtered"; fi
        } >"$PLUGIN_TMP"
    fi
    return 0
}

_render_plugins() { # FORMAT FILE
    local format="$1" file="$2"
    local n=0 name status version upd slug title total shown
    # Every reader tolerates a missing trailing newline on the last line.
    local read_row=true
    case "$format" in
        tsv)
            cat "$file"
            ;;
        json)
            printf '['
            while IFS=$'\t' read -r name status version upd slug title || [ -n "$name" ]; do
                [ -n "$name" ] || continue
                [ "$n" -gt 0 ] && printf ','
                n=$((n + 1))
                printf '{"name":"%s","status":"%s","version":"%s","update":"%s","slug":"%s","title":"%s"}' \
                    "$(json_escape "$name")" "$(json_escape "$status")" "$(json_escape "$version")" \
                    "$(json_escape "$upd")" "$(json_escape "$slug")" "$(json_escape "$title")"
            done <"$file"
            printf ']\n'
            ;;
        csv)
            printf 'name,status,version,update,slug,title\n'
            while IFS=$'\t' read -r name status version upd slug title || [ -n "$name" ]; do
                [ -n "$name" ] || continue
                printf '%s,%s,%s,%s,%s,%s\n' \
                    "$(csv_escape "$name")" "$(csv_escape "$status")" "$(csv_escape "$version")" \
                    "$(csv_escape "$upd")" "$(csv_escape "$slug")" "$(csv_escape "$title")"
            done <"$file"
            ;;
        *)
            total="$(count_lines "$(cat "$file")")"
            printf '%s %s %s %s %s\n' "$(pad 'PLUGIN' 40)" "$(pad 'STATUS' 10)" \
                "$(pad 'VERSION' 12)" "$(pad 'UPDATE' 10)" 'SLUG'
            printf '%s\n' "$(_repeat '-' 92)"
            shown=0
            while IFS=$'\t' read -r name status version upd slug title || [ -n "$name" ]; do
                [ -n "$name" ] || continue
                if [ "$PAGE_LIMIT" -gt 0 ] && [ "$shown" -ge "$PAGE_LIMIT" ]; then
                    printf '... %d more row(s); raise --page to see them\n' "$((total - shown))"
                    break
                fi
                shown=$((shown + 1))
                printf '%s %s %s %s %s\n' \
                    "$(pad "$(fit "$name" 40)" 40)" "$(pad "$status" 10)" \
                    "$(pad "$(fit "$version" 12)" 12)" "$(pad "$upd" 10)" "$(fit "$slug" 30)"
            done <"$file"
            printf '%s\n' "$(_repeat '-' 92)"
            printf '%d plugin(s)\n' "$total"
            ;;
    esac
    : "$read_row"
    return 0
}

list_plugins_for_site() { # SITE USER FILTER
    local site="$1" user="$2" filter="${3:-}"
    PLUGIN_TMP="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.plugins.XXXXXX")" || return 1
    TAIL_FILES+=("$PLUGIN_TMP")

    _plugin_records "$site" "$user" "$filter" || return 1
    if [ "$OUTPUT_FORMAT" = 'table' ] && [ "$QUIET_MODE" != 'true' ]; then
        printf '\nplugins at %s (as %s)\n' "$site" "$user" >&2
    fi
    _render_plugins "$OUTPUT_FORMAT" "$PLUGIN_TMP"
    return 0
}

###############################################################################
# 16. Plugin management
###############################################################################
confirm_yes() { # PROMPT
    local prompt="$1" answer=''
    if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_MODE" = 'true' ]; then
        log_debug "Confirmation skipped (--yes/--force)"
        return 0
    fi
    if [ ! -t 0 ]; then
        log_error "Refusing a destructive action without a terminal; pass --yes or --force"
        return 1
    fi
    printf '%s' "$prompt" >&2
    IFS= read -r answer || answer=''
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

manage_plugin_for_site() { # SITE USER NAME ACTION
    local site="$1" user="$2" name="$3" action="$4"
    local slug='' status='' row rc=0

    PLUGIN_TMP="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.manage.XXXXXX")" || return 1
    TAIL_FILES+=("$PLUGIN_TMP")
    _plugin_records "$site" "$user" '' || return 1

    row="$(plugins_select_one "$name" "$PLUGIN_TMP")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            2)
                log_error "Several plugins match '${name}' on ${site}:"
                while IFS=$'\t' read -r pn ps pv || [ -n "$pn" ]; do
                    [ -n "$pn" ] && printf '  %s (%s)\n' "$pn" "$pv" >&2
                done <"$TMP_PICK_ERR"
                return 1
                ;;
            *)
                log_error "No plugin matches '${name}' on ${site}. Installed:"
                while IFS=$'\t' read -r pn ps pv || [ -n "$pn" ]; do
                    [ -n "$pn" ] && printf '  %s (%s)\n' "$pn" "$pv" >&2
                done <"$PLUGIN_TMP"
                return 1
                ;;
        esac
    fi

    slug="$(printf '%s' "$row" | cut -f5)"
    status="$(printf '%s' "$row" | cut -f2)"
    [ -n "$slug" ] || slug="$(printf '%s' "$row" | cut -f1)"
    log_info "Matched '${slug}' (status: ${status}) on ${site}"

    case "$action" in
        "$ACTION_ACTIVATE")
            if [ "$status" = 'active' ]; then
                log_info "'${slug}' is already active on ${site}"
                STAT_OPS_SKIPPED=$((STAT_OPS_SKIPPED + 1))
                return 0
            fi
            run_wp "$site" "$user" plugin activate "$slug"
            ;;
        "$ACTION_DEACTIVATE")
            if [ "$status" = 'inactive' ]; then
                log_info "'${slug}' is already inactive on ${site}"
                STAT_OPS_SKIPPED=$((STAT_OPS_SKIPPED + 1))
                return 0
            fi
            run_wp "$site" "$user" plugin deactivate "$slug"
            ;;
        "$ACTION_DELETE")
            if [ "$status" = 'active' ]; then
                confirm_yes "'${slug}' is ACTIVE on ${site}. Deactivate and delete it? [y/N] " || {
                    log_info 'Cancelled'; return 0; }
                run_wp "$site" "$user" plugin deactivate "$slug" || log_warn "Deactivation failed; trying to delete anyway"
            else
                confirm_yes "Permanently delete '${slug}' on ${site}, including its files? [y/N] " || {
                    log_info 'Cancelled'; return 0; }
            fi
            run_wp "$site" "$user" plugin delete "$slug"
            ;;
        *)
            log_error "Unsupported action: ${action}"
            return 1
            ;;
    esac
}

###############################################################################
# 17. Astra add-on
###############################################################################
# Decide whether an update is pending from structured output and the exit status,
# not from a localised word inside the message.
astra_update_available() { # SITE USER
    local site="$1" user="$2" a
    local -a args=(plugin update "$ASTRA_SLUG" --dry-run)
    while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done < <(_common_args_print update)

    if ! wp_exec "$site" "$user" -- "${args[@]}"; then
        log_debug "dry-run exit ${WP_LAST_STATUS}: $(printf '%s' "$WP_LAST_OUTPUT" | sed -n 1p)"
        return 1
    fi
    # 'wp plugin update --dry-run' prints one row per plugin; a row other than
    # 'Success' or 'Skipped' means an update is pending.
    printf '%s' "$WP_LAST_OUTPUT" | grep -qiE 'available|new version|success' && return 0
    return 1
}

astra_activate_licence() { # SITE USER
    local site="$1" user="$2"
    [ -n "$licence_value" ] || return 1
    # The licence travels as the placeholder and is expanded inside the child
    # shell from its environment, so it never reaches the outer argv or a log.
    local -a argv=()
    local w
    for w in $ASTRA_LICENSE_COMMAND; do argv+=("$w"); done
    argv+=("$ASTRA_SLUG" "$(licence_marker)")
    run_wp "$site" "$user" "${argv[@]}"
}

handle_astra() { # SITE USER [required]
    local site="$1" user="$2" required="${3:-optional}"
    if [ -z "$licence_value" ]; then
        if [ "$required" = 'required' ]; then
            log_error "--astra needs a licence: set WP_CLI_UPDATE_LICENCE or pass --astra-key"
            STAT_OPS_FAILED=$((STAT_OPS_FAILED + 1))
            return 1
        fi
        log_debug "No licence configured; the Astra add-on is skipped in full mode"
        return 0
    fi

    if ! wp_exec "$site" "$user" -- plugin status "$ASTRA_SLUG"; then
        log_warn "Astra '${ASTRA_SLUG}' is not installed or not active on ${site}"
        STAT_OPS_SKIPPED=$((STAT_OPS_SKIPPED + 1))
        return 0
    fi

    if run_wp "$site" "$user" plugin update "$ASTRA_SLUG"; then
        return 0
    fi

    log_warn "Update failed; checking whether an update is really available"
    if astra_update_available "$site" "$user"; then
        log_info "Activating the Astra licence and retrying"
        if astra_activate_licence "$site" "$user"; then
            run_wp "$site" "$user" plugin update "$ASTRA_SLUG" && return 0
        else
            log_error "Licence activation failed on ${site}"
        fi
    else
        log_info "No Astra update available on ${site}"
        STAT_OPS_SKIPPED=$((STAT_OPS_SKIPPED + 1))
        return 0
    fi
    return 1
}
###############################################################################
# 18. Modes
###############################################################################
# Count how many plugins or themes WP-CLI reported as updated.
_count_successes() { count_lines "$(printf '%s' "$1" | grep 'Success' || true)"; }

_mode_full() { # SITE USER
    local site="$1" user="$2" rc=0

    run_wp "$site" "$user" core update || rc=1
    run_wp "$site" "$user" core update-db || rc=1

    # Counters are updated here, not in a subshell: run_wp leaves the command
    # output in WP_LAST_OUTPUT precisely so it never has to be captured.
    if run_wp_update "$site" "$user" plugin update --all; then
        STAT_PLUGINS_UPDATED=$((STAT_PLUGINS_UPDATED + $(_count_successes "$WP_LAST_OUTPUT")))
    else
        rc=1
    fi

    handle_astra "$site" "$user" optional || rc=1

    if run_wp_update "$site" "$user" theme update --all; then
        STAT_THEMES_UPDATED=$((STAT_THEMES_UPDATED + $(_count_successes "$WP_LAST_OUTPUT")))
    else
        rc=1
    fi

    run_wp "$site" "$user" db optimize || rc=1
    run_wp "$site" "$user" db repair   || rc=1
    run_wp "$site" "$user" cron event run --due-now || rc=1

    return "$rc"
}

_mode_plugins() { # SITE USER
    local site="$1" user="$2"
    run_wp_update "$site" "$user" plugin update --all || return 1
    STAT_PLUGINS_UPDATED=$((STAT_PLUGINS_UPDATED + $(_count_successes "$WP_LAST_OUTPUT")))
    return 0
}

_mode_themes() { # SITE USER
    local site="$1" user="$2"
    run_wp_update "$site" "$user" theme update --all || return 1
    STAT_THEMES_UPDATED=$((STAT_THEMES_UPDATED + $(_count_successes "$WP_LAST_OUTPUT")))
    return 0
}

# Non-destructive health check used by --check.
_mode_check() { # SITE USER
    local site="$1" user="$2" ok='true' dbname='' ver=''
    printf 'site:       %s\n' "$site"
    printf 'owner user: %s\n' "$user"
    if is_wordpress_root "$site"; then
        dbname="$(wp_config_value "${site}/wp-config.php" DB_NAME || true)"
        printf 'wordpress:  yes (database %s)\n' "${dbname:-unknown}"
    else
        printf 'wordpress:  NO (wp-config.php or wp-load.php missing)\n'
        ok='false'
    fi
    if wp_exec "$site" "$user" -- core version; then
        ver="$(printf '%s' "$WP_LAST_OUTPUT" | sed -n '1p')"
        printf 'wp-cli:     ok, core %s\n' "${ver:-unknown}"
    else
        printf 'wp-cli:     FAILED (exit %d)\n' "$WP_LAST_STATUS"
        ok='false'
    fi
    if wp_exec "$site" "$user" -- plugin list --format=count; then
        printf 'plugins:    %s\n' "$(printf '%s' "$WP_LAST_OUTPUT" | sed -n '1p')"
    else
        printf 'plugins:    unreadable (exit %d)\n' "$WP_LAST_STATUS"
        ok='false'
    fi
    [ "$ok" = 'true' ]
}

execute_mode() { # MODE SITE USER
    local mode="$1" site="$2" user="$3"
    case "$mode" in
        "$MODE_FULL")          _mode_full "$site" "$user" ;;
        "$MODE_CORE")          run_wp "$site" "$user" core update && run_wp "$site" "$user" core update-db ;;
        "$MODE_PLUGINS")       _mode_plugins "$site" "$user" ;;
        "$MODE_THEMES")        _mode_themes "$site" "$user" ;;
        "$MODE_DB_OPTIMIZE")   run_wp "$site" "$user" db optimize && run_wp "$site" "$user" db repair ;;
        "$MODE_DB_FIX")        run_wp "$site" "$user" db repair ;;
        "$MODE_CRON")          run_wp "$site" "$user" cron event run --due-now ;;
        "$MODE_ASTRA")         handle_astra "$site" "$user" required ;;
        "$MODE_LIST_PLUGINS")  list_plugins_for_site "$site" "$user" "$PLUGIN_NAME" ;;
        "$MODE_PLUGIN_MANAGE") manage_plugin_for_site "$site" "$user" "$PLUGIN_NAME" "$PLUGIN_ACTION" ;;
        "$MODE_CHECK")         _mode_check "$site" "$user" ;;
        *)                     log_error "Unknown mode: ${mode}"; return 1 ;;
    esac
}

process_site() { # SITE
    local site="$1" user='' rc=0

    # A single site named on the command line is a hard error when it is wrong:
    # the operator asked for that site, silence would be misleading.
    if [ ! -d "$site" ]; then
        if [ -n "$TARGET_SITE" ]; then
            log_error "Site does not exist: ${site}"
            STAT_SITES_FAILED=$((STAT_SITES_FAILED + 1))
            return 1
        fi
        log_warn "Skipping ${site}: not a directory"
        STAT_SITES_SKIPPED=$((STAT_SITES_SKIPPED + 1))
        return 0
    fi
    if ! is_wordpress_root "$site"; then
        if [ -n "$TARGET_SITE" ]; then
            log_error "Not a WordPress installation: ${site}"
            STAT_SITES_FAILED=$((STAT_SITES_FAILED + 1))
            return 1
        fi
        log_warn "Skipping ${site}: no WordPress installation found"
        STAT_SITES_SKIPPED=$((STAT_SITES_SKIPPED + 1))
        return 0
    fi

    STAT_SITES_SEEN=$((STAT_SITES_SEEN + 1))

    if ! user="$(get_wp_user "$site")"; then
        log_error "Cannot determine the WordPress owner for ${site}"
        STAT_SITES_FAILED=$((STAT_SITES_FAILED + 1))
        return 1
    fi
    log_info "Site ${site} -> user ${user}"

    execute_mode "$MODE" "$site" "$user" || rc=$?
    if [ "$rc" -eq 0 ]; then
        STAT_SITES_OK=$((STAT_SITES_OK + 1))
    else
        STAT_SITES_FAILED=$((STAT_SITES_FAILED + 1))
    fi
    return "$rc"
}

###############################################################################
# 19. Summary and status
###############################################################################
print_summary() {
    [ "$SUMMARY_SHOWN" = 'true' ] && return 0
    SUMMARY_SHOWN='true'
    [ "$QUIET_MODE" = 'true' ] && return 0
    [ "$OUTPUT_FORMAT" != 'table' ] && return 0
    [ "$NO_ACTION" = 'true' ] && return 0

    local width=70
    printf '\n%s%s%s\n' "$C_BOLD" "$(_repeat '=' "$width")" "$C_RESET" >&2
    printf '%sSUMMARY%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '%s%s%s\n' "$C_DIM" "$(_repeat '-' "$width")" "$C_RESET" >&2
    printf '  %-20s %s\n' 'sites processed:' "$STAT_SITES_SEEN" >&2
    printf '  %-20s %s\n' 'sites ok:' "$STAT_SITES_OK" >&2
    printf '  %-20s %s\n' 'sites skipped:' "$STAT_SITES_SKIPPED" >&2
    printf '  %-20s %s\n' 'sites failed:' "$STAT_SITES_FAILED" >&2
    printf '  %-20s %s\n' 'plugin updates:' "$STAT_PLUGINS_UPDATED" >&2
    printf '  %-20s %s\n' 'theme updates:' "$STAT_THEMES_UPDATED" >&2
    printf '  %-20s %s\n' 'operations ok:' "$STAT_OPS_OK" >&2
    printf '  %-20s %s\n' 'operations failed:' "$STAT_OPS_FAILED" >&2
    printf '  %-20s %s\n' 'operations skipped:' "$STAT_OPS_SKIPPED" >&2
    printf '  %-20s %s\n' 'log:' "$LOG_FILE" >&2
    printf '%s%s%s\n' "$C_DIM" "$(_repeat '-' "$width")" "$C_RESET" >&2

    if [ "$STAT_OPS_FAILED" -eq 0 ] && [ "$STAT_SITES_FAILED" -eq 0 ]; then
        printf '%sall operations completed successfully%s\n' "$C_GREEN" "$C_RESET" >&2
    else
        printf '%sfailed: %s operation(s), %s site(s); details in %s%s\n' \
            "$C_RED" "$STAT_OPS_FAILED" "$STAT_SITES_FAILED" "$ERROR_LOG_FILE" "$C_RESET" >&2
    fi
    printf '\n' >&2
    return 0
}

show_status() {
    local count='0'
    printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
    printf 'mode:        %s\n' "${MODE:-none}"
    printf 'log level:   %s\n' "$LOG_LEVEL"
    printf 'wp-cli:      %s\n' "$WP_CLI_PATH"
    printf 'sites file:  %s\n' "$SITES_FILE"
    if [ -f "$SITES_FILE" ]; then
        count="$(load_sites "$SITES_FILE" 2>/dev/null | grep -c '' 2>/dev/null || printf '0')"
        count="${count//[^0-9]/}"
        printf 'sites count: %s\n' "${count:-0}"
        printf 'sites mtime: %s\n' "$(date -r "$SITES_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')"
    else
        printf 'sites count: n/a (file missing)\n'
    fi
    if [ -f "$LOG_FILE" ]; then
        printf 'log size:    %s bytes\n' "$(wc -c <"$LOG_FILE" 2>/dev/null || printf '0')"
        printf 'last entry:  %s\n' "$(tail -n1 "$LOG_FILE" 2>/dev/null || printf 'n/a')"
    else
        printf 'log size:    n/a (no log yet)\n'
    fi
    printf 'error log:   %s\n' "$ERROR_LOG_FILE"
    printf 'lock file:   %s\n' "$LOCK_FILE"
    return 0
}

###############################################################################
# 20. Main
###############################################################################
main() {
    # Precedence: defaults < global config < local config < environment < command
    # line. The command line is parsed twice on purpose: the first pass collects
    # --config, --sites and --wp; the files and then the environment are applied;
    # the second pass lets the command line win over both. The second pass must
    # NOT reload the config file, otherwise the file would override the
    # environment again. It only records the path for display.
    CONFIG_REQUESTED=''
    parse_args "$@"
    CONFIG_FROM_CLI="$CONFIG_REQUESTED"
    load_config_file "$DEFAULT_CONFIG_GLOBAL"
    load_config_file "$DEFAULT_CONFIG_LOCAL"
    if [ -n "$CONFIG_FROM_CLI" ] && [ "$CONFIG_FROM_CLI" != "$CONFIG_FILE" ]; then
        load_config_file "$CONFIG_FROM_CLI"
    fi
    apply_environment
    parse_args "$@"
    if [ -n "$CONFIG_FROM_CLI" ]; then
        CONFIG_FILE="$CONFIG_FROM_CLI"
    fi

    _colors_init

    [ "$PRINT_HELP" = 'true' ] && usage "$EXIT_OK"
    [ "$PRINT_VERSION" = 'true' ] && { version_info; exit "$EXIT_OK"; }
    [ "$LIST_MODES" = 'true' ] && { list_modes; exit "$EXIT_OK"; }

    validate_options

    init_temps || { printf 'ERROR: cannot create temporary files in %s\n' "${TMPDIR:-/tmp}" >&2; exit "$EXIT_ENV"; }
    trap '_on_exit' EXIT
    trap 'printf "\n"; log_warn "interrupted"; exit 130' INT
    trap 'log_warn "terminated"; exit 143' TERM

    log_info "${PROG_NAME} v${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"

    if [ "$MODE" = "$MODE_STATUS" ]; then
        show_status
        exit "$EXIT_OK"
    fi

    if ! have "$WP_CLI_PATH"; then
        log_error "WP-CLI not found or not executable: ${WP_CLI_PATH} (use --wp PATH)"
        exit "$EXIT_ENV"
    fi

    if [ "$(id -u)" -ne 0 ]; then
        log_warn "Not root: users are not switched, WP-CLI runs as $(id -un)"
    fi

    _lock_acquire

    if [ -z "$TARGET_SITE" ]; then
        ensure_sites_file || exit "$EXIT_ENV"
    fi

    show_banner

    local -a sites=()
    local line
    if [ -n "$TARGET_SITE" ]; then
        sites=("$TARGET_SITE")
    else
        while IFS= read -r line; do sites+=("$line"); done < <(load_sites "$SITES_FILE") || true
        if [ "${#sites[@]}" -eq 0 ]; then
            log_error "No sites to process in ${SITES_FILE}"
            exit "$EXIT_ERROR"
        fi
    fi

    local total="${#sites[@]}" index=0 site rc=0
    for site in "${sites[@]}"; do
        index=$((index + 1))
        if [ "$OUTPUT_FORMAT" = 'table' ] && [ "$QUIET_MODE" != 'true' ] && [ "$total" -gt 1 ]; then
            printf '\r%s[%s%s%s]%s %d/%d %s%s\r' \
                "$C_CYAN" "$C_GREEN" "$(_repeat '#' $((index * 24 / total)))" "$C_DIM" "$C_RESET" \
                "$index" "$total" "$(fit "$(basename "$site")" 40)" "$C_RESET" >&2
        fi
        rc=0
        process_site "$site" || rc=$?
        if [ "$rc" -ne 0 ] && [ "$EXIT_CODE" -eq 0 ]; then
            EXIT_CODE="$EXIT_ERROR"
        fi
    done
    if [ "$OUTPUT_FORMAT" = 'table' ] && [ "$total" -gt 1 ]; then
        printf '\r%*s\r' 80 '' >&2
    fi

    # In machine-readable modes only the payload goes to stdout; everything else
    # has already been written to stderr.
    if [ "$MODE" = "$MODE_CHECK" ] && [ "$OUTPUT_FORMAT" = 'json' ]; then
        printf '{"sites_seen":%s,"sites_ok":%s,"sites_skipped":%s,"sites_failed":%s,"ops_ok":%s,"ops_failed":%s}\n' \
            "$STAT_SITES_SEEN" "$STAT_SITES_OK" "$STAT_SITES_SKIPPED" "$STAT_SITES_FAILED" \
            "$STAT_OPS_OK" "$STAT_OPS_FAILED"
    fi

    print_summary
    exit "$EXIT_CODE"
}

main "$@"
