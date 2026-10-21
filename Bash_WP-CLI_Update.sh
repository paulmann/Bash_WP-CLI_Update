#!/usr/bin/env bash
###############################################################################
# WordPress Maintenance Automation
# Description: Secure, fast, and modular WP-CLI manager for multiple sites.
# Author: Mikhail Deynekin <mid1977@gmail.com>
# Repository: https://github.com/paulmann/Bash_WP-CLI_Update
# License: MIT
# Version: 6.0.0
###############################################################################
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2 ) )); then
    printf 'ERROR: %s requires Bash 4.2 or newer (found %s).\n' \
        "${0##*/}" "${BASH_VERSION:-unknown}" >&2
    exit 2
fi

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${SCRIPT_DIR}" ]] || { printf 'ERROR: cannot resolve script directory\n' >&2; exit 1; }
readonly SCRIPT_DIR
readonly SCRIPT_VERSION="6.0.0"

#########################################
###           CONSTANTS               ###
#########################################

readonly DEFAULT_WP_CLI="/usr/local/bin/wp"
readonly SITES_FILE="${WP_SITES_FILE:-${SCRIPT_DIR}/wp-found.txt}"
readonly DISCOVER_SCRIPT="${SCRIPT_DIR}/Find_WP_Senior.sh"
readonly LOG_FILE="${SCRIPT_DIR}/wp_cli_manager.log"
readonly ERROR_LOG_FILE="${SCRIPT_DIR}/wp_cli_errors.log"
readonly ASTRA_KEY_FILE="${SCRIPT_DIR}/astra.key"
readonly DEFAULT_SKIP_PLUGINS="saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer"
readonly MAX_LOG_SIZE=10485760   # 10 MiB, rotated before every run

readonly MODE_FULL="full"
readonly MODE_CORE="core"
readonly MODE_PLUGINS="plugins"
readonly MODE_THEMES="themes"
readonly MODE_DB_OPTIMIZE="db-optimize"
readonly MODE_DB_FIX="db-fix"
readonly MODE_CRON="cron"
readonly MODE_ASTRA="astra"
readonly MODE_LIST_PLUGINS="list-plugins"
readonly MODE_PLUGIN_MANAGE="plugin-manage"

readonly ACTION_ACTIVATE="activate"
readonly ACTION_DEACTIVATE="deactivate"
readonly ACTION_DELETE="delete"

readonly TABLE_WIDTH=90
readonly PROGRESS_CHAR="█"

# ANSI colors (only when writing to a terminal; NO_COLOR is honoured)
if [[ -t 2 && "${NO_COLOR:-0}" != "1" && "${TERM:-}" != "dumb" ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m' MAGENTA=$'\033[0;35m' BOLD=$'\033[1m' DIM=$'\033[2m'
    RESET=$'\033[0m' WHITE=$'\033[0;37m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' RESET='' WHITE=''
fi
readonly RED GREEN YELLOW BLUE CYAN MAGENTA BOLD DIM RESET WHITE

#########################################
###        RUNTIME CONFIG             ###
#########################################

# Resolve the WP-CLI executable once. Called from main() AFTER argument
# parsing, so --help/--version work even without wp installed.
resolve_wp_cli() {
    if [[ -n "${WP_CLI_PATH:-}" ]]; then
        return 0
    fi
    if [[ -x "${DEFAULT_WP_CLI}" ]]; then
        WP_CLI_PATH="${DEFAULT_WP_CLI}"
    elif command -v wp >/dev/null 2>&1; then
        WP_CLI_PATH="$(command -v wp)"
    else
        printf 'ERROR: WP-CLI not found (%s or anywhere in PATH).\n' "${DEFAULT_WP_CLI}" >&2
        printf 'Install it first: https://wp-cli.org/#installing\n' >&2
        exit 1
    fi
    readonly WP_CLI_PATH
    return 0
}

# Astra Pro license key: ASTRA_KEY env > ASTRA_LICENSE_KEY env > astra.key file
# (never hard-code the key in the script - it would leak into the log file)
if [[ -z "${ASTRA_KEY:-}" && -n "${ASTRA_LICENSE_KEY:-}" ]]; then
    ASTRA_KEY="${ASTRA_LICENSE_KEY}"
fi
if [[ -z "${ASTRA_KEY:-}" && -f "${ASTRA_KEY_FILE}" ]]; then
    ASTRA_KEY="$(head -n1 "${ASTRA_KEY_FILE}" 2>/dev/null | tr -d '\r\n')"
fi
readonly ASTRA_KEY

is_astra_key_set() {
    [[ -n "${ASTRA_KEY}" && "${ASTRA_KEY}" != YOUR* && "${ASTRA_KEY}" != *HERE* ]]
}

#########################################
###        GLOBAL VARIABLES           ###
#########################################

# Semantics: total_sites = sites attempted, success_ops = sites with every
# requested operation succeeding, error_ops = sites with at least one failure.
declare -A STATS=(
    [total_sites]=0
    [success_ops]=0
    [error_ops]=0
)

DEBUG_MODE=false
MODE=""
TARGET_SITE=""
PLUGIN_NAME=""
PLUGIN_ACTION=""
FORCE_MODE=false
JSON_OUTPUT=false

#########################################
###           FUNCTIONS               ###
#########################################

# Replace the license key with '***' so it never lands in logs or on screen.
_redact() {
    local s="$1" k="${ASTRA_KEY:-}"
    if [[ -n "${k}" && "${k}" != YOUR* ]]; then
        s="${s//${k}/***}"
    fi
    printf '%s' "${s}"
}

log() {
    local level="$1" msg="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${msg}" >> "${LOG_FILE}"

    case "${level}" in
        "ERROR")   printf '%s✗ %s%s\n' "${RED}" "${msg}" "${RESET}" >&2 ;;
        "WARNING") printf '%s⚠ %s%s\n' "${YELLOW}" "${msg}" "${RESET}" >&2 ;;
        "SUCCESS") printf '%s✓ %s%s\n' "${GREEN}" "${msg}" "${RESET}" >&2 ;;
        "DEBUG")   printf '%s🐞 %s%s\n' "${CYAN}" "${msg}" "${RESET}" >&2 ;;
        "INFO")    printf '%sℹ %s%s\n' "${BLUE}" "${msg}" "${RESET}" >&2 ;;
        *)         printf '%s\n' "${msg}" >&2 ;;
    esac
}

log_error_detail() {
    local context="$1" command="$2" output="$3" exit_code="$4"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    cat >> "${ERROR_LOG_FILE}" <<EOF
[${timestamp}] [ERROR DETAIL]
Context: ${context}
Command: $(_redact "${command}")
Exit Code: ${exit_code}
Output: $(_redact "${output}")
---
EOF
}

log_info()    { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_error()   { log "ERROR" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_debug() {
    [[ "${DEBUG_MODE}" == true ]] && log "DEBUG" "$1"
    return 0
}

debug_echo() {
    [[ "${DEBUG_MODE}" == true ]] && printf '%s🐞 DEBUG: %s%s\n' "${CYAN}" "$1" "${RESET}" >&2
    return 0
}

# ---------------------------------------------------------------------
# Log rotation (LOG_FILE is append-only and grows forever otherwise)
# ---------------------------------------------------------------------
_rotate_log_if_needed() {
    local f="$1" sz
    [[ -f "${f}" ]] || return 0
    sz="$(stat -c %s "${f}" 2>/dev/null || printf '0')"
    if (( sz > MAX_LOG_SIZE )); then
        mv -f "${f}" "${f}.1"
    fi
    return 0
}

# ---------------------------------------------------------------------
# Progress indicator (terminal only, stderr, no trailing newline spam)
# ---------------------------------------------------------------------
show_progress() {
    local current="$1" total="$2" message="${3:-Processing}"
    (( total <= 0 )) && total=1
    (( current < 0 )) && current=0
    (( current > total )) && current=total

    local percent=$(( current * 100 / total ))
    local filled=$(( percent * 40 / 100 ))
    local empty=$(( 40 - filled ))
    local bar='' empty_bar=''
    printf -v bar '%*s' "${filled}" ''
    bar="${bar// /${PROGRESS_CHAR}}"
    printf -v empty_bar '%*s' "${empty}" ''
    empty_bar="${empty_bar// /░}"
    printf '\r\033[K%s[%s%s%s%s%s]%s %s' "${DIM}" "${GREEN}" "${bar}" "${RESET}" "${DIM}" "${empty_bar}" "${RESET}" "${message}" >&2
}

usage() {
    cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: ${SCRIPT_NAME} [MODE] [OPTIONS]

Modes:
  --full, -f           : Full update (core, plugins, themes, DB optimize/repair, cron)
  --core, -c           : Update WordPress core only
  --plugins, -p        : Update all plugins
  --themes, -t         : Update all themes
  --db-optimize, -d    : Optimize and repair database
  --db-fix, -x         : Repair database only
  --cron, -r           : Run due cron events
  --astra, -s          : Update Astra plugin with license activation if needed
  --list-plugins, -l   : List all plugins for site(s) with modern table view
  --plugin-manage, -m  : Manage plugin (activate/deactivate/delete)

Options:
  --DEBUG, -D                  : Enable debug mode with detailed logging
  --site, -S <path>            : Target a specific site path (optional, overrides wp-found.txt)
  --action, -A <action>        : Plugin action: activate|deactivate|delete (for --plugin-manage)
  --name, -N <plugin_name>     : Plugin slug or partial name for matching
  --force, -F                  : Skip confirmation for destructive actions (delete)
  --json, -J                   : Output in JSON format (for --list-plugins)
  --version, -V                : Print version and exit
  --help, -h                   : Show this help message

Environment:
  ASTRA_KEY | ASTRA_LICENSE_KEY  Astra Pro license key (preferred over config file)
  WP_SKIP_PLUGINS                Comma-separated plugins skipped during updates
                                 (default: ${DEFAULT_SKIP_PLUGINS})
  WP_SITES_FILE                  Alternative path to the sites list file
  NO_COLOR=1                     Disable colored output

  The Astra key may also be stored in the file: ${ASTRA_KEY_FILE}
  (first line, no trailing spaces). Never hard-code the key in the script -
  it would be written to ${LOG_FILE}.

Examples:
  ${SCRIPT_NAME} --plugins
  ${SCRIPT_NAME} -p
  ${SCRIPT_NAME} --full --DEBUG
  ${SCRIPT_NAME} --list-plugins --site /var/www/example.com
  ${SCRIPT_NAME} --list-plugins -N "woocommerce" --json
  ${SCRIPT_NAME} --plugin-manage --action deactivate --name "jetpack" --site /var/www/example.com
  ${SCRIPT_NAME} -m -A delete -N "old-plugin" -S /var/www/example.com --force

Sites are read from: ${SITES_FILE}
EOF
    exit "${1:-1}"
}

trim() {
    local str="$1"
    str="${str#"${str%%[![:space:]]*}"}"
    str="${str%"${str##*[![:space:]]}"}"
    printf '%s' "${str}"
}

# ---------------------------------------------------------------------
# User detection: wp-config owner > directory owner > path/DB_USER hints
# ---------------------------------------------------------------------
get_wp_user() {
    local wp_root="$1"
    local wp_config="${wp_root}/wp-config.php"
    local candidate

    # Method 1: owner of wp-config.php
    if [[ -f "${wp_config}" ]]; then
        candidate="$(stat -c '%U' "${wp_config}" 2>/dev/null || true)"
        if [[ -n "${candidate}" && "${candidate}" != "root" ]] && id -u "${candidate}" >/dev/null 2>&1; then
            debug_echo "User resolution: wp-config.php owner '${candidate}'"
            printf '%s' "${candidate}"
            return 0
        fi
    fi

    # Method 2: owner of the site directory
    candidate="$(stat -c '%U' "${wp_root}" 2>/dev/null || true)"
    if [[ -n "${candidate}" && "${candidate}" != "root" ]] && id -u "${candidate}" >/dev/null 2>&1; then
        debug_echo "User resolution: directory owner '${candidate}'"
        printf '%s' "${candidate}"
        return 0
    fi

    # Method 3: path component, e.g. /var/www/USER/site/...
    local -a path_parts=()
    local old_ifs="${IFS}"
    IFS='/' read -r -a path_parts <<< "${wp_root}"
    IFS="${old_ifs}"
    if [[ ${#path_parts[@]} -ge 4 ]]; then
        candidate="${path_parts[3]}"
        if [[ -n "${candidate}" ]] && id -u "${candidate}" >/dev/null 2>&1; then
            debug_echo "User resolution: path component '${candidate}'"
            printf '%s' "${candidate}"
            return 0
        fi
    fi

    # Method 4: DB_USER from wp-config.php (may coincide with the system user)
    if [[ -f "${wp_config}" ]]; then
        candidate="$(grep -E "define\s*\(\s*'DB_USER'" "${wp_config}" 2>/dev/null | \
                     sed -E "s/.*'DB_USER'\s*,\s*'([^']+)'.*/\1/" | tail -n1 || true)"
        if [[ -n "${candidate}" ]] && id -u "${candidate}" >/dev/null 2>&1; then
            debug_echo "User resolution: DB_USER '${candidate}'"
            printf '%s' "${candidate}"
            return 0
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------
# Resolve the user's real home directory (fallback: path heuristic)
# ---------------------------------------------------------------------
_user_home() {
    local user="$1" site_path="$2" home=""
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -n "${home}" && -d "${home}" ]]; then
        printf '%s' "${home}"
    else
        dirname "$(dirname "${site_path}")"
    fi
}

# ---------------------------------------------------------------------
# Low-level runner: executes WP-CLI as $user in $site_path.
# Prints combined stdout+stderr. Returns 0 (ok), 1 (failed), 2 (preconditions).
# The su command is assembled from an array and %q-escaped, so paths with
# spaces or quotes are passed through correctly.
# ---------------------------------------------------------------------
_wp_exec() {
    local site_path="$1" user="$2"
    shift 2
    local -a cmd=("$@")

    [[ -d "${site_path}" ]] || return 2
    id -u "${user}" >/dev/null 2>&1 || return 2

    local domain home_dir
    domain="$(basename "${site_path}")"
    home_dir="$(_user_home "${user}" "${site_path}")"

    local -a words=()
    words+=( cd -- "${site_path}" '&&' env
             "DOCUMENT_URI=${domain}" "DOCUMENT_ROOT=${site_path}"
             "HOMEDIR=${home_dir}" "HTTP_HOST=${domain}" )
    words+=( "${WP_CLI_PATH}" "--path=${site_path}" "${cmd[@]}" )
    [[ -n "${WP_SKIP_PLUGINS:-${DEFAULT_SKIP_PLUGINS}}" ]] && \
        words+=( "--skip-plugins=${WP_SKIP_PLUGINS:-${DEFAULT_SKIP_PLUGINS}}" )
    words+=( --quiet --allow-root )

    local su_cmd="" w
    for w in "${words[@]}"; do
        su_cmd+="$(printf '%q ' "${w}")"
    done

    debug_echo "Executing as '${user}': $(_redact "${su_cmd}")"

    local rc=0
    su - "${user}" -c "${su_cmd}" 2>&1 || rc=$?
    (( rc == 0 )) && return 0
    return 1
}

# ---------------------------------------------------------------------
# Display a compact error box (first 20 lines) on stderr
# ---------------------------------------------------------------------
_show_error_box() {
    local site_path="$1" command="$2" output="$3" total_lines shown line

    printf '\n%s┌─ WP-CLI Error Detail ──────────────────────────────────────%s\n' "${RED}" "${RESET}" >&2
    printf '%s│ Site: %s%s\n' "${RED}" "${site_path}" "${RESET}" >&2
    printf '%s│ Command: %s%s\n' "${RED}" "${command}" "${RESET}" >&2

    if [[ -n "${output}" ]]; then
        shown="$(printf '%s\n' "${output}" | head -n 20)"
        while IFS= read -r line; do
            printf '%s│ %s%s\n' "${RED}" "${line}" "${RESET}" >&2
        done <<< "${shown}"
        total_lines="$(printf '%s\n' "${output}" | wc -l)"
        if (( total_lines > 20 )); then
            printf '%s│ [... %s total lines, see log for full output]%s\n' "${RED}" "${total_lines}" "${RESET}" >&2
        fi
    else
        printf '%s│ No error output captured (command failed silently)%s\n' "${RED}" "${RESET}" >&2
    fi

    printf '%s│ Full error log: %s%s\n' "${RED}" "${ERROR_LOG_FILE}" "${RESET}" >&2
    printf '%s└─────────────────────────────────────────────────────────────%s\n' "${RED}" "${RESET}" >&2
    printf '\n' >&2
}

# ---------------------------------------------------------------------
# Run a WP-CLI command for a site; log result; print output on success.
# ---------------------------------------------------------------------
run_wp_cli() {
    local site_path="$1" user="$2"
    shift 2
    local -a cmd=("$@")
    local cmdline
    cmdline="$(_cmdline "${cmd[@]}")"

    if ! id -u "${user}" >/dev/null 2>&1; then
        log_error "User '${user}' does not exist. Cannot run WP-CLI command."
        return 1
    fi
    if [[ ! -d "${site_path}" ]]; then
        log_error "Directory '${site_path}' does not exist."
        return 1
    fi

    log_info "Running: $(_redact "${cmdline}") on ${site_path} as ${user}"

    local output rc=0
    output="$(_wp_exec "${site_path}" "${user}" "${cmd[@]}")" || rc=1

    if (( rc == 0 )); then
        log_success "Success: $(_redact "${cmdline}")"
        if [[ -n "${output}" ]]; then
            printf '%s\n' "${output}"
        fi
        return 0
    fi

    log_error "Failed: $(_redact "${cmdline}")"
    log_error_detail "run_wp_cli" "${cmdline}" "${output}" "${rc}"
    _show_error_box "${site_path}" "$(_redact "${cmdline}")" "${output}"
    return 1
}

_cmdline() {
    local -a a=("$@")
    printf 'wp'
    if [[ ${#a[@]} -gt 0 ]]; then
        printf ' %s' "${a[@]}"
    fi
}

# ---------------------------------------------------------------------
# Get the plugin list as clean JSON (strips PHP warnings/notices).
# ---------------------------------------------------------------------
_plugin_list_json() {
    local site_path="$1" wp_user="$2" raw cleaned
    raw="$(_wp_exec "${site_path}" "${wp_user}" plugin list --format=json 2>/dev/null)" || return 1
    cleaned="$(sed -n '/^\[/,$p' <<< "${raw}")"
    [[ -n "${cleaned}" && "${cleaned:0:1}" == "[" ]] || return 1
    printf '%s' "${cleaned}"
    return 0
}

# ---------------------------------------------------------------------
# Get the plugin list as TSV: name, status, version, update, slug.
# Prefers jq over the JSON API; falls back to wp-cli CSV output.
# ---------------------------------------------------------------------
_plugin_rows() {
    local site_path="$1" wp_user="$2" json csv

    if json="$(_plugin_list_json "${site_path}" "${wp_user}")" && command -v jq &>/dev/null; then
        echo "${json}" | jq -r '.[] | [
            (.name // "N/A"),
            (.status // "unknown"),
            (.version // "N/A"),
            (.update // "none"),
            (.slug // "N/A")
        ] | @tsv' 2>/dev/null
        return 0
    fi

    csv="$(_wp_exec "${site_path}" "${wp_user}" plugin list \
        --fields=name,status,version,update,slug --format=csv 2>/dev/null)" || return 1
    [[ -n "${csv}" ]] || return 1
    echo "${csv}" | tail -n +2 | sed 's/,/\t/g'
    return 0
}

# ---------------------------------------------------------------------
# List plugins for a site (modern table, or JSON when requested)
# ---------------------------------------------------------------------
list_plugins_for_site() {
    local site_path="$1" wp_user="$2" plugin_filter="${3:-}" json_mode="${4:-false}"

    if [[ -z "${site_path}" || ! -d "${site_path}" ]]; then
        log_error "Invalid or missing site path: ${site_path}"
        return 1
    fi
    if [[ -z "${wp_user}" ]]; then
        log_error "wp_user is empty"
        return 1
    fi

    # JSON mode: requires jq for a valid array
    if [[ "${json_mode}" == "true" ]]; then
        if ! command -v jq &>/dev/null; then
            log_error "jq is required for --json output (yum install jq | apt install jq)"
            return 1
        fi
        local json
        if ! json="$(_plugin_list_json "${site_path}" "${wp_user}")"; then
            log_error "Failed to retrieve plugin list for ${site_path}"
            return 1
        fi
        echo "${json}" | jq --arg f "${plugin_filter:-}" \
            '[.[] | select((($f | length) == 0) or (.name | test($f; "i")))]'
        return 0
    fi

    local rows
    if ! rows="$(_plugin_rows "${site_path}" "${wp_user}")"; then
        log_error "Failed to retrieve plugin list for ${site_path}"
        return 1
    fi

    printf '\n'
    printf '%s%s📦 Plugins for: %s%s%s%s\n' "${BOLD}" "${CYAN}" "${BOLD}" "${WHITE}" "${site_path}" "${RESET}"
    printf '%s%s%s\n' "${DIM}" "$(printf '─%.0s' $(seq 1 ${TABLE_WIDTH}))" "${RESET}"
    printf '%s%s%s\n' "${BOLD}" "$(printf '%-40s %-12s %-10s %-8s %-15s' 'Plugin Name' 'Status' 'Version' 'Update' 'Slug')" "${RESET}"

    local count=0 name status version update slug
    while IFS=$'\t' read -r name status version update slug; do
        [[ -n "${name}" ]] || continue
        if [[ -n "${plugin_filter}" ]] && ! grep -qiE -- "${plugin_filter}" <<< "${name}"; then
            continue
        fi

        local status_color="${GREEN}" status_symbol="●"
        case "${status}" in
            "active")   status_color="${GREEN}"; status_symbol="✓" ;;
            "inactive") status_color="${YELLOW}"; status_symbol="○" ;;
            *)          status_color="${RED}";   status_symbol="✗" ;;
        esac

        local update_ind="${GREEN}✓" update_txt="none"
        [[ "${update}" == "available" ]] && { update_ind="${RED}✗"; update_txt="update"; }

        local disp_name="${name:0:39}"
        [[ ${#name} -gt 39 ]] && disp_name="${name:0:36}..."

        printf '%-40s %s%s %-8s%s %-10s %s %-6s %s%s%s\n' \
            "${disp_name}" "${status_color}" "${status_symbol}" "${status}" "${RESET}" \
            "${version}" "${update_ind}" "${update_txt}" "${DIM}" "${slug:0:14}" "${RESET}"
        count=$(( count + 1 ))
    done <<< "${rows}"

    printf '%s%s%s\n' "${DIM}" "$(printf '─%.0s' $(seq 1 ${TABLE_WIDTH}))" "${RESET}"
    printf '%sTotal: %d plugin(s)%s\n' "${DIM}" "${count}" "${RESET}"
    return 0
}

# ---------------------------------------------------------------------
# Manage a plugin (activate / deactivate / delete) with safety checks
# ---------------------------------------------------------------------
manage_plugin_for_site() {
    local site_path="$1" wp_user="$2" plugin_name="$3" action="$4" force="${5:-false}"

    case "${action}" in
        "${ACTION_ACTIVATE}"|"${ACTION_DEACTIVATE}"|"${ACTION_DELETE}") ;;
        *)
            log_error "Invalid action: ${action}. Must be: activate|deactivate|delete"
            return 1
            ;;
    esac

    local json="" rows=""
    if ! json="$(_plugin_list_json "${site_path}" "${wp_user}")"; then
        log_error "Failed to retrieve plugin list for ${site_path}"
        return 1
    fi

    # Find matching plugins by partial name (case-insensitive). The name is
    # passed via jq --arg / awk -v so it can never break the query syntax.
    local matching_plugins=""
    if command -v jq &>/dev/null; then
        matching_plugins="$(echo "${json}" | jq -r --arg f "${plugin_name}" \
            '.[] | select(.name | test($f; "i")) | .name' 2>/dev/null || true)"
    else
        rows="$(_plugin_rows "${site_path}" "${wp_user}")" || {
            log_error "Cannot list plugins without jq for ${site_path}"
            return 1
        }
        matching_plugins="$(awk -F$'\t' -v p="${plugin_name}" \
            'index(tolower($1), tolower(p)) > 0 { print $1 }' <<< "${rows}")"
    fi

    if [[ -z "${matching_plugins}" ]]; then
        log_error "No plugin found matching '${plugin_name}' on ${site_path}"
        log_info "Available plugins (use --list-plugins to see all):"
        if command -v jq &>/dev/null; then
            echo "${json}" | jq -r '.[].name' | head -10 | while IFS= read -r p; do
                printf '  %s\n' "${p}"
            done
        else
            printf '%s\n' "${rows}" | cut -f1 | head -10 | while IFS= read -r p; do
                printf '  %s\n' "${p}"
            done
        fi
        return 1
    fi

    local plugin_count exact_plugin_name
    plugin_count="$(printf '%s\n' "${matching_plugins}" | grep -c . || true)"
    if (( plugin_count > 1 )); then
        log_warning "Multiple plugins match '${plugin_name}':"
        while IFS= read -r p; do
            printf '  %s• %s%s\n' "${CYAN}" "${p}" "${RESET}"
        done <<< "${matching_plugins}"
        log_info "Please specify a more exact plugin name or the full slug"
        return 1
    fi
    exact_plugin_name="${matching_plugins}"
    debug_echo "Found exact plugin: ${exact_plugin_name}"

    # Current status for smart handling
    local current_status="unknown"
    if command -v jq &>/dev/null; then
        current_status="$(echo "${json}" | jq -r --arg n "${exact_plugin_name}" \
            '.[] | select(.name == $n) | .status' 2>/dev/null || true)"
    else
        [[ -n "${rows}" ]] || rows="$(_plugin_rows "${site_path}" "${wp_user}")" || true
        current_status="$(awk -F$'\t' -v n="${exact_plugin_name}" '$1 == n { print $2 }' <<< "${rows:-}")"
    fi
    debug_echo "Current plugin status: ${current_status}"

    # Confirmation for destructive actions (unless --force)
    if [[ "${action}" == "${ACTION_DELETE}" && "${force}" != "true" ]]; then
        local confirm=""
        printf '\n'
        printf '%s%s⚠️  DESTRUCTIVE ACTION WARNING%s\n' "${BOLD}" "${RED}" "${RESET}"
        printf '%s─────────────────────────────────────────%s\n' "${DIM}" "${RESET}"
        printf 'Site:     %s%s%s\n' "${BOLD}" "${site_path}" "${RESET}"
        printf 'Plugin:   %s%s%s\n' "${BOLD}" "${exact_plugin_name}" "${RESET}"
        printf 'Action:   %sDELETE%s (permanent removal)\n' "${BOLD}" "${RESET}"
        printf '%s─────────────────────────────────────────%s\n' "${DIM}" "${RESET}"
        printf '%sThis will permanently delete all plugin files and data.%s\n' "${YELLOW}" "${RESET}"
        printf '%sThis action CANNOT be undone.%s\n' "${YELLOW}" "${RESET}"
        printf '\n'
        read -r -p "Type 'DELETE' to confirm or any other key to cancel: " confirm
        if [[ "${confirm}" != "DELETE" ]]; then
            log_info "Plugin deletion cancelled by user"
            return 0
        fi
        printf '%s✓ Confirmed%s\n' "${GREEN}" "${RESET}"
    fi

    local -a wp_cmd=()
    local action_text=""
    case "${action}" in
        "${ACTION_ACTIVATE}")
            if [[ "${current_status}" == "active" ]]; then
                log_info "Plugin '${exact_plugin_name}' is already active"
                return 0
            fi
            wp_cmd=( plugin activate "${exact_plugin_name}" )
            action_text="Activating"
            ;;
        "${ACTION_DEACTIVATE}")
            if [[ "${current_status}" == "inactive" ]]; then
                log_info "Plugin '${exact_plugin_name}' is already inactive"
                return 0
            fi
            wp_cmd=( plugin deactivate "${exact_plugin_name}" )
            action_text="Deactivating"
            ;;
        "${ACTION_DELETE}")
            if [[ "${current_status}" == "active" ]]; then
                log_info "Deactivating plugin before deletion: ${exact_plugin_name}"
                run_wp_cli "${site_path}" "${wp_user}" plugin deactivate "${exact_plugin_name}" || true
            fi
            wp_cmd=( plugin delete "${exact_plugin_name}" )
            action_text="Deleting"
            ;;
    esac

    log_info "${action_text} plugin: ${exact_plugin_name}"
    if run_wp_cli "${site_path}" "${wp_user}" "${wp_cmd[@]}"; then
        log_success "Plugin '${exact_plugin_name}' ${action}d successfully on ${site_path}"
        return 0
    fi
    log_error "Failed to ${action} plugin '${exact_plugin_name}' on ${site_path}"
    return 1
}

# ---------------------------------------------------------------------
# Astra Pro handling: update the add-on, activate the license on failure
# and retry once. tolerate_missing=true is used in FULL mode where the
# plugin may legitimately be absent.
# ---------------------------------------------------------------------
handle_astra() {
    local site_path="$1" wp_user="$2" tolerate_missing="${3:-false}"

    if ! is_astra_key_set; then
        if [[ "${tolerate_missing}" == "true" ]]; then
            log_info "Astra license key not configured - attempting update without license"
        else
            log_error "Astra license key is not configured."
            log_error "Set ASTRA_KEY env var or place the key in: ${ASTRA_KEY_FILE}"
            return 1
        fi
    fi

    if ! run_wp_cli "${site_path}" "${wp_user}" plugin status astra-addon >/dev/null 2>&1; then
        if [[ "${tolerate_missing}" == "true" ]]; then
            log_info "Astra plugin not installed/active here - skipping"
            return 0
        fi
        log_warning "Astra plugin not found or not active for: ${site_path}"
        return 1
    fi

    if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
        log_success "Astra plugin updated successfully"
        return 0
    fi

    log_warning "Astra update failed - activating license and retrying once"
    if ! is_astra_key_set; then
        log_error "Cannot retry with license: no Astra license key configured"
        return 1
    fi
    if ! run_wp_cli "${site_path}" "${wp_user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
        log_error "Failed to activate Astra license"
        return 1
    fi
    if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
        log_success "Astra plugin updated successfully after license activation"
        return 0
    fi
    log_error "Astra plugin update failed even after license activation"
    return 1
}

# ---------------------------------------------------------------------
# Ensure the sites file exists; try the discovery script, else ask.
# ---------------------------------------------------------------------
ensure_sites_file() {
    if [[ -f "${SITES_FILE}" ]]; then
        log_info "Sites file found: ${SITES_FILE}"
        return 0
    fi

    log_warning "Sites file NOT found: ${SITES_FILE}"

    if [[ -f "${DISCOVER_SCRIPT}" && -x "${DISCOVER_SCRIPT}" ]]; then
        log_info "Running discovery script: ${DISCOVER_SCRIPT}"
        if "${DISCOVER_SCRIPT}" --output "${SITES_FILE}"; then
            log_success "Discovery script completed."
        else
            log_warning "Discovery script exited with non-zero status."
        fi
    else
        log_warning "Discovery script not found or not executable: ${DISCOVER_SCRIPT}"
    fi

    if [[ -f "${SITES_FILE}" ]]; then
        log_success "Sites file created by discovery script: ${SITES_FILE}"
        return 0
    fi

    # Fallback: manual input
    local user_path=""
    log_warning "No sites file found. Please provide the absolute path to a WordPress installation."
    read -r -p "Enter full path to WordPress root (e.g. /var/www/site.com): " user_path
    [[ -n "${user_path}" ]] || { log_error "No path provided. Exiting."; exit 1; }

    user_path="$(trim "${user_path}")"
    if [[ ! -d "${user_path}" ]]; then
        log_error "Directory does not exist: ${user_path}"
        exit 1
    fi
    if [[ ! -f "${user_path}/wp-config.php" && ! -f "${user_path}/wp-settings.php" ]]; then
        log_error "Not a valid WordPress installation: ${user_path}"
        exit 1
    fi

    printf '%s\n' "${user_path}" > "${SITES_FILE}"
    log_success "Path saved to ${SITES_FILE}. Continuing..."
}

# ---------------------------------------------------------------------
# Process a single site; update per-site statistics.
# ---------------------------------------------------------------------
process_site() {
    local site_path="$1"

    if [[ ! -d "${site_path}" ]]; then
        log_warning "Skipping (not a directory): ${site_path}"
        STATS[error_ops]=$(( STATS[error_ops] + 1 ))
        return 0
    fi

    log_info "Processing site: ${site_path}"
    STATS[total_sites]=$(( STATS[total_sites] + 1 ))

    local wp_user=""
    if ! wp_user="$(get_wp_user "${site_path}")"; then
        log_error "Skipping site: cannot resolve WordPress user for ${site_path}"
        STATS[error_ops]=$(( STATS[error_ops] + 1 ))
        return 0
    fi
    debug_echo "Resolved WordPress user '${wp_user}' for ${site_path}"

    if execute_mode "${MODE}" "${site_path}" "${wp_user}"; then
        STATS[success_ops]=$(( STATS[success_ops] + 1 ))
    else
        log_error "Operations failed for site: ${site_path}"
        STATS[error_ops]=$(( STATS[error_ops] + 1 ))
    fi
    return 0
}

# ---------------------------------------------------------------------
# Execute the operations of the selected mode for one site.
# All steps run even if an earlier one fails; the overall status is the
# OR of every step.
# ---------------------------------------------------------------------
execute_mode() {
    local mode="$1" site_path="$2" wp_user="$3"
    local rc=0

    case "${mode}" in
        "${MODE_FULL}")
            run_wp_cli "${site_path}" "${wp_user}" core update               || rc=1
            run_wp_cli "${site_path}" "${wp_user}" plugin update --all        || rc=1
            handle_astra "${site_path}" "${wp_user}" true                     || rc=1
            run_wp_cli "${site_path}" "${wp_user}" theme update --all         || rc=1
            run_wp_cli "${site_path}" "${wp_user}" core update-db             || rc=1
            run_wp_cli "${site_path}" "${wp_user}" db optimize                || rc=1
            run_wp_cli "${site_path}" "${wp_user}" db repair                  || rc=1
            run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now   || rc=1
            ;;
        "${MODE_CORE}")
            run_wp_cli "${site_path}" "${wp_user}" core update       || rc=1
            run_wp_cli "${site_path}" "${wp_user}" core update-db    || rc=1
            ;;
        "${MODE_PLUGINS}")
            run_wp_cli "${site_path}" "${wp_user}" plugin update --all || rc=1
            ;;
        "${MODE_THEMES}")
            run_wp_cli "${site_path}" "${wp_user}" theme update --all || rc=1
            ;;
        "${MODE_DB_OPTIMIZE}")
            run_wp_cli "${site_path}" "${wp_user}" db optimize || rc=1
            run_wp_cli "${site_path}" "${wp_user}" db repair   || rc=1
            ;;
        "${MODE_DB_FIX}")
            run_wp_cli "${site_path}" "${wp_user}" db repair || rc=1
            ;;
        "${MODE_CRON}")
            run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now || rc=1
            ;;
        "${MODE_ASTRA}")
            handle_astra "${site_path}" "${wp_user}" false || rc=1
            ;;
        "${MODE_LIST_PLUGINS}")
            list_plugins_for_site "${site_path}" "${wp_user}" "${PLUGIN_NAME}" "${JSON_OUTPUT}" || rc=1
            ;;
        "${MODE_PLUGIN_MANAGE}")
            if [[ -z "${PLUGIN_ACTION}" || -z "${PLUGIN_NAME}" ]]; then
                log_error "Plugin management requires --action and --name options"
                return 1
            fi
            manage_plugin_for_site "${site_path}" "${wp_user}" "${PLUGIN_NAME}" "${PLUGIN_ACTION}" "${FORCE_MODE}" || rc=1
            ;;
        *)
            log_error "Unknown mode: ${mode}"
            return 1
            ;;
    esac

    return ${rc}
}

# ---------------------------------------------------------------------
# Startup banner: configuration and planned operations overview
# ---------------------------------------------------------------------
show_startup_info() {
    printf '\n'
    printf '%s%s╔═══════════════════════════════════════════════════════════════╗%s\n' "${BOLD}" "${CYAN}" "${RESET}"
    printf '%s%s║%s     %sWordPress Maintenance Automation v%s%s                     %s%s║%s\n' "${BOLD}" "${CYAN}" "${RESET}" "${BOLD}" "${SCRIPT_VERSION}" "${RESET}" "${BOLD}" "${CYAN}" "${RESET}"
    printf '%s%s║%s     %sSecure, fast, and modular WP-CLI manager%s                    %s%s║%s\n' "${BOLD}" "${CYAN}" "${RESET}" "${DIM}" "${RESET}" "${BOLD}" "${CYAN}" "${RESET}"
    printf '%s%s╚═══════════════════════════════════════════════════════════════╝%s\n' "${BOLD}" "${CYAN}" "${RESET}"
    printf '\n'

    local mode_desc="Unknown mode"
    case "${MODE}" in
        "${MODE_FULL}")          mode_desc="Full update (core + plugins + themes + DB + cron)" ;;
        "${MODE_CORE}")          mode_desc="WordPress core update only" ;;
        "${MODE_PLUGINS}")       mode_desc="Update all plugins" ;;
        "${MODE_THEMES}")        mode_desc="Update all themes" ;;
        "${MODE_DB_OPTIMIZE}")   mode_desc="Database optimization and repair" ;;
        "${MODE_DB_FIX}")        mode_desc="Database repair only" ;;
        "${MODE_CRON}")          mode_desc="Run due cron events" ;;
        "${MODE_ASTRA}")         mode_desc="Astra plugin update with license activation" ;;
        "${MODE_LIST_PLUGINS}")  mode_desc="List plugins with table/JSON view" ;;
        "${MODE_PLUGIN_MANAGE}") mode_desc="Plugin management (activate/deactivate/delete)" ;;
    esac
    printf '%s🎯 Operation Mode:%s   %s\n' "${BOLD}" "${RESET}" "${mode_desc}"
    printf '%s🔧 Mode Flag:%s        %s\n' "${BOLD}" "${RESET}" "${MODE}"

    if [[ -n "${TARGET_SITE}" ]]; then
        printf '%s📍 Target Site:%s      %s\n' "${BOLD}" "${RESET}" "${TARGET_SITE}"
    else
        printf '%s📍 Target Sites:%s     %s\n' "${BOLD}" "${RESET}" "All sites from ${SITES_FILE}"
    fi

    if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" || "${MODE}" == "${MODE_LIST_PLUGINS}" ]]; then
        [[ -n "${PLUGIN_NAME}" ]] && printf '%s🔌 Plugin Filter:%s    %s\n' "${BOLD}" "${RESET}" "${PLUGIN_NAME}"
        if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
            local action_desc=""
            case "${PLUGIN_ACTION}" in
                "${ACTION_ACTIVATE}")   action_desc="Activate plugin" ;;
                "${ACTION_DEACTIVATE}") action_desc="Deactivate plugin" ;;
                "${ACTION_DELETE}")     action_desc="Delete plugin (DESTRUCTIVE)" ;;
            esac
            printf '%s⚡ Plugin Action:%s   %s\n' "${BOLD}" "${RESET}" "${action_desc}"
            printf '%s🚀 Force Mode:%s      %s\n' "${BOLD}" "${RESET}" "$([[ "${FORCE_MODE}" == true ]] && printf 'ENABLED' || printf 'DISABLED')"
        fi
        printf '%s📄 Output Format:%s    %s\n' "${BOLD}" "${RESET}" "$([[ "${JSON_OUTPUT}" == true ]] && printf 'JSON' || printf 'Table')"
    fi

    printf '%s🐞 Debug Mode:%s        %s\n' "${BOLD}" "${RESET}" "$([[ "${DEBUG_MODE}" == true ]] && printf 'ENABLED' || printf 'DISABLED')"
    printf '%s%s%s\n' "${DIM}" "$(printf '─%.0s' $(seq 1 65))" "${RESET}"

    # Warnings
    local has_warnings=false
    printf '%s⚠️  WARNINGS & NOTES:%s\n' "${BOLD}" "${RESET}"
    if [[ "${PLUGIN_ACTION}" == "${ACTION_DELETE}" && "${FORCE_MODE}" != "true" ]]; then
        printf '  %s⚠ Deletion requires manual confirmation (type DELETE)%s\n' "${YELLOW}" "${RESET}"
        has_warnings=true
    fi
    if [[ "${MODE}" == "${MODE_FULL}" ]]; then
        printf '  %s⚠ Full mode may take several minutes per site%s\n' "${YELLOW}" "${RESET}"
        has_warnings=true
    fi
    if [[ "${MODE}" == "${MODE_ASTRA}" || "${MODE}" == "${MODE_FULL}" ]] && ! is_astra_key_set; then
        printf '  %s⚠ Astra license key is not configured%s\n' "${YELLOW}" "${RESET}"
        has_warnings=true
    fi
    if [[ -n "${TARGET_SITE}" && ! -d "${TARGET_SITE}" ]]; then
        printf '  %s✗ Target site directory does not exist: %s%s\n' "${RED}" "${TARGET_SITE}" "${RESET}"
        has_warnings=true
    fi
    if [[ "${has_warnings}" == false ]]; then
        printf '  %s✓ No warnings - ready to proceed%s\n' "${GREEN}" "${RESET}"
    fi
    printf '\n'
}

# ---------------------------------------------------------------------
# Final summary (single block; exit code reflects errors)
# ---------------------------------------------------------------------
show_summary() {
    printf '\n'
    printf '%s%s╔═══════════════════════════════════════════════════════════════╗%s\n' "${BOLD}" "${GREEN}" "${RESET}"
    printf '%s%s║%s                       %sOPERATION SUMMARY%s                          %s%s║%s\n' "${BOLD}" "${GREEN}" "${RESET}" "${BOLD}" "${RESET}" "${BOLD}" "${GREEN}" "${RESET}"
    printf '%s%s╚═══════════════════════════════════════════════════════════════╝%s\n' "${BOLD}" "${GREEN}" "${RESET}"
    printf '\n'
    printf '%s│%s Sites processed:  %s%s%s\n' "${DIM}" "${RESET}" "${BOLD}" "${STATS[total_sites]}" "${RESET}"
    printf '%s│%s Successful sites: %s%s%s%s\n' "${DIM}" "${RESET}" "${BOLD}" "${GREEN}" "${STATS[success_ops]}" "${RESET}"
    printf '%s│%s Errors:           %s%s%s%s\n' "${DIM}" "${RESET}" "${BOLD}" "${RED}" "${STATS[error_ops]}" "${RESET}"
    printf '%s│%s Log file:         %s\n' "${DIM}" "${RESET}" "${LOG_FILE}"
    printf '%s│%s Error log:        %s\n' "${DIM}" "${RESET}" "${ERROR_LOG_FILE}"
    printf '\n'
}

# ---------------------------------------------------------------------
# Command-line parsing
# ---------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --DEBUG|-D) DEBUG_MODE=true; shift ;;
            --full|-f)        MODE="${MODE_FULL}"; shift ;;
            --core|-c)        MODE="${MODE_CORE}"; shift ;;
            --plugins|-p)     MODE="${MODE_PLUGINS}"; shift ;;
            --themes|-t)      MODE="${MODE_THEMES}"; shift ;;
            --db-optimize|-d) MODE="${MODE_DB_OPTIMIZE}"; shift ;;
            --db-fix|-x)      MODE="${MODE_DB_FIX}"; shift ;;
            --cron|-r)        MODE="${MODE_CRON}"; shift ;;
            --astra|-s)       MODE="${MODE_ASTRA}"; shift ;;
            --list-plugins|-l) MODE="${MODE_LIST_PLUGINS}"; shift ;;
            --plugin-manage|-m) MODE="${MODE_PLUGIN_MANAGE}"; shift ;;
            --site|-S)
                if [[ -z "${2:-}" || "${2}" == --* ]]; then
                    log_error "--site requires a path argument"
                    usage 1
                fi
                TARGET_SITE="$2"
                shift 2
                ;;
            --action|-A)
                if [[ -z "${2:-}" || "${2}" == --* ]]; then
                    log_error "--action requires: activate|deactivate|delete"
                    usage 1
                fi
                PLUGIN_ACTION="$2"
                shift 2
                ;;
            --name|-N)
                if [[ -z "${2:-}" || "${2}" == --* ]]; then
                    log_error "--name requires a plugin name argument"
                    usage 1
                fi
                PLUGIN_NAME="$2"
                shift 2
                ;;
            --force|-F) FORCE_MODE=true; shift ;;
            --json|-J)  JSON_OUTPUT=true; shift ;;
            --version|-V)
                printf '%s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
                exit 0
                ;;
            --help|-h)
                usage 0
                ;;
            *)
                log_error "Invalid argument: $1"
                usage 1
                ;;
        esac
    done

    if [[ -z "${MODE}" ]]; then
        log_error "No mode specified."
        usage 1
    fi

    # Validate plugin-manage requirements
    if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
        if [[ -z "${PLUGIN_ACTION}" ]]; then
            log_error "--plugin-manage requires --action (activate|deactivate|delete)"
            usage 1
        fi
        if [[ -z "${PLUGIN_NAME}" ]]; then
            log_error "--plugin-manage requires --name (plugin slug or partial name)"
            usage 1
        fi
        case "${PLUGIN_ACTION}" in
            "${ACTION_ACTIVATE}"|"${ACTION_DEACTIVATE}"|"${ACTION_DELETE}") ;;
            *)
                log_error "Invalid action: ${PLUGIN_ACTION}. Must be: activate|deactivate|delete"
                usage 1
                ;;
        esac
    fi

    debug_echo "Final mode: ${MODE}"
    debug_echo "TARGET_SITE: ${TARGET_SITE:-all sites}"
    debug_echo "PLUGIN_NAME: ${PLUGIN_NAME:-all plugins}"
    return 0
}

#########################################
###           MAIN LOGIC              ###
#########################################

main() {
    # Parse arguments first: --help/--version must work without log files
    parse_args "$@"

    # Resolve WP-CLI now that a real run is requested
    resolve_wp_cli

    log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} started"
    log_info "WP-CLI: ${WP_CLI_PATH}"

    # Prepare log files (rotation first, then a fresh error log per run)
    _rotate_log_if_needed "${LOG_FILE}"
    _rotate_log_if_needed "${ERROR_LOG_FILE}"
    {
        printf '=== WordPress CLI Error Log - Started at: %s ===\n' "$(date)"
    } > "${ERROR_LOG_FILE}"

    # Root check: user switching via su requires root
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root (to switch users via su)."
        exit 1
    fi

    # Sites file (unless targeting a single site)
    if [[ -z "${TARGET_SITE}" ]]; then
        ensure_sites_file
    fi

    if [[ "${DEBUG_MODE}" != "true" ]]; then
        show_startup_info
    else
        debug_echo "Skipping startup banner in DEBUG mode"
    fi

    if [[ "${JSON_OUTPUT}" == "true" || "${MODE}" == "${MODE_LIST_PLUGINS}" || "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
        if ! command -v jq &>/dev/null; then
            log_warning "jq not found. JSON features require it (yum install jq | apt install jq)."
        fi
    fi

    log_info "Starting WordPress maintenance in '${MODE}' mode"

    # Process sites
    if [[ -n "${TARGET_SITE}" ]]; then
        if [[ ! -d "${TARGET_SITE}" ]]; then
            log_error "Target site directory does not exist: ${TARGET_SITE}"
            exit 1
        fi
        process_site "${TARGET_SITE}"
    else
        [[ -f "${SITES_FILE}" ]] || { log_error "Sites file not found: ${SITES_FILE}"; exit 1; }

        local -a sites=()
        local line
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="$(trim "${line}")"
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            sites+=("${line}")
        done < "${SITES_FILE}"

        log_info "Reading ${#sites[@]} site(s) from ${SITES_FILE}"

        local current=0
        for site_path in "${sites[@]}"; do
            current=$(( current + 1 ))
            if [[ -t 2 && "${DEBUG_MODE}" != true && ${#sites[@]} -gt 1 ]]; then
                show_progress "${current}" "${#sites[@]}" "Site ${current}/${#sites[@]}"
            fi
            process_site "${site_path}"
        done
        if [[ -t 2 && ${#sites[@]} -gt 1 ]]; then
            printf '\n' >&2
        fi
    fi

    show_summary

    if (( STATS[error_ops] > 0 )); then
        printf '%s✗ %s error(s) occurred - check %s%s\n' "${RED}" "${STATS[error_ops]}" "${ERROR_LOG_FILE}" "${RESET}"
        exit 1
    fi
    printf '%s✓ All operations completed successfully%s\n' "${GREEN}" "${RESET}"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
