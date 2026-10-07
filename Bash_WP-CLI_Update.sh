#!/usr/bin/env bash
# ==============================================================================
# WordPress Maintenance Automation
# ==============================================================================
# File:        Bash_WP-CLI_Update.sh
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Version:     6.0.0
# License:     MIT — see LICENSE file in project root.
#
# Description:
#   Multi-site WP-CLI maintenance: core / plugin / theme updates, database
#   optimize + repair, WP-Cron, Astra Pro licence handling, plugin inventory and
#   plugin management (activate / deactivate / delete). Every WP-CLI call runs as
#   the correct system user for that installation.
#
#   Security model: WP-CLI is executed through an argument ARRAY. No shell string
#   is ever assembled from site paths, plugin names or command output, so shell
#   metacharacters can never be interpreted. (v5.0 interpolated data into
#   'su - user -c "..."' strings, which allowed arbitrary command execution as
#   root via a crafted plugin title, plugin name or site path.)
#
# Usage:
#   ./Bash_WP-CLI_Update.sh [MODE] [OPTIONS]
#
# Modes:
#   -f, --full            Core + plugins + themes + DB optimize/repair + cron
#   -c, --core            WordPress core update (+ update-db + cache flush)
#   -p, --plugins         Update all plugins
#   -t, --themes          Update all themes
#   -d, --db-optimize     Optimize and repair the database
#   -x, --db-fix          Repair the database only
#   -r, --cron            Run due WP-Cron events
#   -s, --astra           Update Astra Pro (licence activation on failure)
#   -l, --list-plugins    Inventory plugins (table or --json)
#   -m, --plugin-manage   activate | deactivate | delete a plugin
#       --status          Read-only health report (core, updates, DB size)
#       --verify          Read-only checksum verification (core + plugins)
#
# Targeting / behaviour:
#   -S, --site PATH        Target a single site (default: all sites in sites file)
#       --sites-file FILE  Site list to process (default <script dir>/wp-found.txt)
#   -A, --action ACTION    activate|deactivate|delete        (--plugin-manage)
#   -N, --name NAME        Plugin slug or partial name
#   -u, --user USER        Force the system user used for WP-CLI
#   -U, --url URL          Force --url (multisite / domain mapping)
#   -n, --dry-run          Show what would run; mutations are skipped
#   -j, --jobs N           Process N sites in parallel batches (default: 1)
#   -F, --force            No prompts; continue on errors
#   -y, --yes              Same as --force, for confirmations
#   -b, --backup MODE      db | full — back up before changes (off by default)
#       --no-backup        Never back up (also disables the delete backup)
#   -B, --backup-dir DIR   Backup directory (default: <script dir>/backups)
#       --keep-backups N   Backup files kept per site (default: 3)
#   -k, --skip-plugins L   Value for --skip-plugins (bootstrap safety)
#   -e, --exclude-plugins L Plugins excluded from "plugin update --all"
#       --only-active      Update only active plugins that have updates
#   -T, --timeout SEC      Per-command timeout (default 600, 0 = disabled)
#   -L, --log-dir DIR      Log directory (default: <script dir>)
#   -J, --json             Machine-readable output on stdout (JSON Lines)
#       --strict           Warnings/findings cause a non-zero exit
#       --no-discover      Never run the discovery script automatically
#       --no-user-switch   Run WP-CLI as the current user (Docker, per-user cron)
#       --list-sites       Print the resolved site list and exit
#       --wp-bin PATH      WP-CLI binary (default: $WP_CLI_BIN, then $PATH)
#   -D, --debug            Debug logging
#   -q, --quiet            Warnings and errors only
#   -v, --verbose          Stream WP-CLI output to the console
#       --no-color         Disable ANSI colours
#   -C, --config FILE      Configuration file (default: <script dir>/wp-maintenance.conf)
#   -V, --version          Print version and exit
#   -h, --help             Print this help and exit
#
# Configuration:
#   Precedence: command line > environment > config file > built-in defaults.
#   The config file is a bash snippet; use ": ${VAR:=default}" inside it so that
#   environment variables keep priority. Supported variables:
#     WP_CLI_BIN, SITES_FILE, LOG_DIR, LOG_FILE, ERROR_LOG_FILE, LOG_MAX_BYTES,
#     BACKUP_DIR, KEEP_BACKUPS, SKIP_PLUGINS, EXCLUDE_PLUGINS, DEFAULT_USER,
#     SITE_URL, WP_TIMEOUT, JOBS, DISCOVER_SCRIPT, ASTRA_KEY, ASTRA_KEY_FILE
#   The config file is sourced, therefore group/world writable files are refused.
#   Secrets: prefer ASTRA_KEY_FILE (root-owned, 0600) over ASTRA_KEY, and never
#   pass the licence key on the command line — it is visible in "ps".
#
# Exit codes:
#   0  success
#   1  one or more operations failed (or warnings with --strict)
#   2  usage error
#   3  preflight error (not root, WP-CLI missing, unreadable config, ...)
#   4  nothing to do (no sites)
#   130 interrupted (SIGINT/SIGTERM)
#
# Requirements:
#   • Bash 4.2+
#   • WP-CLI 2.x; root, or --no-user-switch; GNU coreutils (or BSD userland)
#   • jq recommended (plugin inventory falls back to WP-CLI CSV output)
#
# Author & Support:
#   Mikhail Deynekin — https://github.com/paulmann
# ==============================================================================

set -Eeuo pipefail

# Bash 4.2+ is required (associative arrays, printf -v, array slicing).
# Keeping this check before any 4.x-only declaration makes old shells fail with
# a readable message instead of "declare: -A: invalid option".
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
	printf 'ERROR: %s requires Bash 4.2 or newer (running: %s)\n' "${0##*/}" "${BASH_VERSION}" >&2
	printf '       On macOS install a current bash (e.g. "brew install bash") and run it explicitly.\n' >&2
	exit 3
fi

readonly SCRIPT_VERSION="6.0.0"
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=""

readonly EX_OK=0
readonly EX_FAIL=1
readonly EX_USAGE=2
readonly EX_PREFLIGHT=3
readonly EX_EMPTY=4
readonly EX_INTERRUPT=130

# ------------------------------------------------------------------------------
# Script directory (symlink-safe)
# ------------------------------------------------------------------------------
resolve_script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [[ -L "${src}" ]]; do
		dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || break
		src="$(readlink -- "${src}")"
		[[ "${src}" != /* ]] && src="${dir}/${src}"
	done
	dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir="${PWD}"
	printf '%s' "${dir}"
}
SCRIPT_DIR="$(resolve_script_dir)"
readonly SCRIPT_DIR
readonly CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/wp-maintenance.conf"

# ------------------------------------------------------------------------------
# State (defaults are applied by apply_defaults() after the config file is read)
# ------------------------------------------------------------------------------
MODE=""
TARGET_SITE=""
PLUGIN_NAME=""
PLUGIN_ACTION=""
FORCE=0
DEBUG=0
QUIET=0
VERBOSE=0
JSON_OUT=0
DRY_RUN=0
ONLY_ACTIVE=0
STRICT=0
NO_DISCOVER=0
USER_SWITCH=1
NO_BACKUP=0
LIST_SITES_ONLY=0
BACKUP_MODE=""
COLOR_MODE="auto"
CONFIG_FILE=""
USER_OVERRIDE=""
URL_OVERRIDE=""
WP_BIN_OVERRIDE=""
TIMEOUT_OVERRIDE=""

declare -a SKIP_PLUGINS_ARR=()
declare -a EXCLUDE_PLUGINS_ARR=()
declare -a SITES=()
declare -a SITE_REPORT=()
declare -a CSV_ARR=()
declare -a WP_CMD=()
declare -a PLUGIN_LINES=()
declare -a PLUGIN_UPDATE_ARGS=()

declare -A STATS=(
	[sites]=0
	[sites_ok]=0
	[sites_failed]=0
	[sites_skipped]=0
	[wp_ok]=0
	[wp_failed]=0
	[wp_skipped]=0
	[warnings]=0
)
declare -A USER_CACHE=()

WP_BIN=""
WP_OUT=""
WP_ERR_FILE=""
WP_NOCOUNT=0
WP_SOFT=0
HAS_JQ=0
LOCK_DIR=""
LOCK_HELD=0
RUN_ID=""
START_TS=0
SUMMARY_PRINTED=0
DIE_CODE=0
PRIV_KIND="none"

TIMEOUT_BIN=""
ENV_BIN=""
TAR_BIN=""
CURRENT_USER=""

# Configuration values are declared empty so that error paths which run before
# apply_defaults() (config file problems, usage errors) never trip "set -u".
SITES_FILE=""
DISCOVER_SCRIPT=""
LOG_DIR=""
LOG_FILE=""
ERROR_LOG_FILE=""
LOG_MAX_BYTES=""
BACKUP_DIR=""
KEEP_BACKUPS=""
WP_TIMEOUT=""
JOBS=""
WP_CLI_BIN=""
SITE_URL=""
DEFAULT_USER=""
ASTRA_KEY=""
ASTRA_KEY_FILE=""
SKIP_PLUGINS=""
EXCLUDE_PLUGINS=""

# ------------------------------------------------------------------------------
# Colours
# ------------------------------------------------------------------------------
C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""; C_BOLD=""; C_RESET=""

setup_colors() {
	local enabled=0
	case "${COLOR_MODE}" in
		never) enabled=0 ;;
		always) enabled=1 ;;
		*) [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] && enabled=1 ;;
	esac
	if ((enabled)); then
		C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
		C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_DIM=$'\033[2m'
		C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
	fi
	return 0
}

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
redact() {
	local msg="$1"
	if [[ -n "${ASTRA_KEY:-}" && "${ASTRA_KEY}" != "YOUR_KEY" ]]; then
		msg="${msg//"${ASTRA_KEY}"/***REDACTED***}"
	fi
	printf '%s' "${msg}"
	return 0
}

_rotate_log() {
	local file="$1" max="$2" size=""
	[[ -f "${file}" ]] || return 0
	size="$(wc -c <"${file}" 2>/dev/null || printf '0')"
	size="$(trim "${size}")"
	is_uint "${size}" || return 0
	if ((size > max)); then
		rm -f -- "${file}.1" 2>/dev/null || true
		mv -f -- "${file}" "${file}.1" 2>/dev/null || true
	fi
	return 0
}

_log_file() {
	local level="$1" msg="$2" ts="" line=""
	[[ -n "${LOG_FILE}" ]] || return 0
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	while IFS= read -r line; do
		printf '[%s] [%s] %s\n' "${ts}" "${level}" "${line}" >>"${LOG_FILE}" 2>/dev/null || true
	done <<<"${msg}"
	return 0
}

_log_console() {
	local level="$1" msg="$2" color="" symbol=""
	case "${level}" in
		ERROR)   color="${C_RED}";    symbol="✗" ;;
		WARNING) color="${C_YELLOW}"; symbol="⚠" ;;
		SUCCESS) color="${C_GREEN}";  symbol="✓" ;;
		DEBUG)   color="${C_CYAN}";   symbol="•" ;;
		*)       color="${C_BLUE}";   symbol="ℹ" ;;
	esac
	printf '%s%s %s%s\n' "${color}" "${symbol}" "${msg}" "${C_RESET}" >&2
	return 0
}

log() {
	local level="$1"; shift
	local msg=""
	msg="$(redact "$*")"

	case "${level}" in
		DEBUG) ((DEBUG)) || return 0 ;;
		INFO|SUCCESS) ((QUIET)) && return 0 ;;
	esac

	_log_file "${level}" "${msg}"
	_log_console "${level}" "${msg}"
	return 0
}

log_info()  { log INFO "$@"; return 0; }
log_ok()    { log SUCCESS "$@"; return 0; }
log_warn()  { ((STATS[warnings]++)) || true; log WARNING "$@"; return 0; }
log_err()   { log ERROR "$@"; return 0; }
log_debug() { log DEBUG "$@"; return 0; }

die() {
	local msg="$1" code="${2:-${EX_FAIL}}"
	DIE_CODE="${code}"
	log ERROR "${msg}"
	print_summary
	exit "${code}"
}

log_error_detail() {
	local context="$1" command="$2" rc="$3" output="$4" ts=""
	[[ -n "${ERROR_LOG_FILE}" ]] || return 0
	ts="$(date '+%Y-%m-%d %H:%M:%S')"
	{
		printf '[%s] [RUN %s] [ERROR DETAIL]\n' "${ts}" "${RUN_ID}"
		printf 'Context : %s\n' "$(redact "${context}")"
		printf 'Command : %s\n' "$(redact "${command}")"
		printf 'Exit    : %s\n' "${rc}"
		printf 'Output  :\n%s\n---\n' "$(redact "${output}")"
	} >>"${ERROR_LOG_FILE}" 2>/dev/null || true
	return 0
}

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
	return 0
}

have() { command -v -- "$1" >/dev/null 2>&1; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

is_valid_username() { [[ "${1:-}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; }

file_perms() {
	stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null || true
}

csv_to_array() {
	# "a, b ,c" -> global CSV_ARR=(a b c)
	# NOTE: the loop condition must also accept a final line without a newline,
	# otherwise the last element of the list would be silently dropped.
	local list="$1" item=""
	CSV_ARR=()
	if [[ -n "${list}" ]]; then
		while IFS= read -r item || [[ -n "${item}" ]]; do
			item="$(trim "${item}")"
			if [[ -n "${item}" ]]; then
				CSV_ARR+=("${item}")
			fi
		done < <(printf '%s\n' "${list}" | tr ',' '\n')
	fi
	return 0
}

hline() {
	# Print N horizontal box characters to stderr (no seq/tr dependency).
	local n="$1" fill=""
	printf -v fill '%*s' "${n}" ''
	printf '%s' "${fill// /─}"
	return 0
}

json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	printf '%s' "${s}"
	return 0
}

duration_human() {
	local secs="$1"
	if ((secs >= 3600)); then
		printf '%dh %dm %ds' $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
	elif ((secs >= 60)); then
		printf '%dm %ds' $((secs / 60)) $((secs % 60))
	else
		printf '%ds' "${secs}"
	fi
	return 0
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
	cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: ${SCRIPT_NAME} [MODE] [OPTIONS]

Modes:
  -f, --full             Core + plugins + themes + DB optimize/repair + cron
  -c, --core             WordPress core update (+ update-db, cache flush)
  -p, --plugins          Update all plugins
  -t, --themes           Update all themes
  -d, --db-optimize      Optimize and repair the database
  -x, --db-fix           Repair the database only
  -r, --cron             Run due WP-Cron events
  -s, --astra            Update Astra Pro (licence activation on failure)
  -l, --list-plugins     Inventory plugins (table, or --json)
  -m, --plugin-manage    activate | deactivate | delete a plugin
      --status           Read-only health report
      --verify           Read-only checksum verification

Targeting / behaviour:
  -S, --site PATH        Single site (default: every site in ${SITES_FILE})
      --sites-file FILE  Site list to process (default ${SITES_FILE})
  -A, --action ACTION    activate|deactivate|delete        (--plugin-manage)
  -N, --name NAME        Plugin slug or partial name
  -u, --user USER        Force the system user used for WP-CLI
  -U, --url URL          Force --url (multisite)
  -n, --dry-run          Show what would run; mutations are skipped
  -j, --jobs N           Process N sites in parallel batches (default ${JOBS})
  -F, --force            No prompts; continue on errors
  -y, --yes              Same as --force, for confirmations
  -b, --backup MODE      db | full — back up before changes (off by default)
      --no-backup        Never back up (also disables the delete backup)
  -B, --backup-dir DIR   Backup directory (default ${BACKUP_DIR})
      --keep-backups N   Backup files kept per site (default ${KEEP_BACKUPS})
  -k, --skip-plugins L   Value for --skip-plugins (default: ${SKIP_PLUGINS})
  -e, --exclude-plugins L Plugins excluded from "plugin update --all"
      --only-active      Update only active plugins that have updates
  -T, --timeout SEC      Per-command timeout (default ${WP_TIMEOUT}s, 0 = off)
  -L, --log-dir DIR      Log directory (default ${LOG_DIR})
  -J, --json             JSON Lines on stdout: one object per site + summary
      --strict           Warnings/findings cause a non-zero exit
      --no-discover      Never run the discovery script automatically
      --no-user-switch   Run WP-CLI as the current user
      --list-sites       Print the resolved site list and exit
      --wp-bin PATH      WP-CLI binary
  -D, --debug            Debug logging
  -q, --quiet            Warnings and errors only
  -v, --verbose          Stream WP-CLI output
      --no-color         Disable colours
  -C, --config FILE      Configuration file (default ${CONFIG_FILE_DEFAULT})
  -V, --version          Print version
  -h, --help             This help

Exit codes: 0 ok | 1 operation failure | 2 usage | 3 preflight | 4 no sites | 130 interrupted

Examples:
  ${SCRIPT_NAME} --full --backup db
  ${SCRIPT_NAME} -p -j 4 --only-active
  ${SCRIPT_NAME} --list-plugins --site /var/www/example.com
  ${SCRIPT_NAME} --list-plugins -N woocommerce --json
  ${SCRIPT_NAME} -m -A deactivate -N jetpack -S /var/www/example.com
  ${SCRIPT_NAME} -m -A delete -N old-plugin -S /var/www/example.com --yes
  ${SCRIPT_NAME} --plugins --dry-run
EOF
	return 0
}

# ------------------------------------------------------------------------------
# Cleanup / signals / summary
# ------------------------------------------------------------------------------
cleanup() {
	local rc=$?
	if ((LOCK_HELD)); then
		rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
		LOCK_HELD=0
	fi
	if [[ -n "${WP_ERR_FILE}" && -f "${WP_ERR_FILE}" ]]; then
		rm -f -- "${WP_ERR_FILE}" 2>/dev/null || true
	fi
	return "${rc}"
}

on_signal() {
	log WARNING "interrupted — stopping"
	print_summary
	exit "${EX_INTERRUPT}"
}

json_results() {
	local out="" entry="" status="" path="" first=1
	for entry in ${SITE_REPORT[@]+"${SITE_REPORT[@]}"}; do
		status="${entry%%|*}"
		path="${entry#*|}"
		((first)) || out+=","
		first=0
		out+="{\"path\":\"$(json_escape "${path}")\",\"status\":\"${status}\"}"
	done
	printf '%s' "${out}"
	return 0
}

print_summary() {
	((SUMMARY_PRINTED)) && return 0
	SUMMARY_PRINTED=1

	local elapsed=$(( $(date +%s) - START_TS ))
	local entry="" status="" path=""

	if ((JSON_OUT)); then
		printf '{"type":"summary","mode":"%s","sites":%d,"sites_ok":%d,"sites_failed":%d,"sites_skipped":%d,"wp_ok":%d,"wp_failed":%d,"wp_skipped":%d,"warnings":%d,"elapsed":%d,"results":[%s]}\n' \
			"$(json_escape "${MODE}")" "${STATS[sites]}" "${STATS[sites_ok]}" "${STATS[sites_failed]}" \
			"${STATS[sites_skipped]}" "${STATS[wp_ok]}" "${STATS[wp_failed]}" "${STATS[wp_skipped]}" \
			"${STATS[warnings]}" "${elapsed}" "$(json_results)"
		return 0
	fi

	if ((QUIET)) && [[ "${STATS[wp_failed]}" == "0" ]]; then
		return 0
	fi

	{
		printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}"
		printf '%s║%s                  OPERATION SUMMARY                       %s║%s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "${C_RESET}"
		printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}"
		printf '  %-16s %s\n' "Mode:" "${MODE:-list-sites}"
		printf '  %-16s %s (ok %s, failed %s, skipped %s)\n' "Sites:" "${STATS[sites]}" "${STATS[sites_ok]}" "${STATS[sites_failed]}" "${STATS[sites_skipped]}"
		printf '  %-16s %s ok, %s failed, %s skipped\n' "WP operations:" "${STATS[wp_ok]}" "${STATS[wp_failed]}" "${STATS[wp_skipped]}"
		printf '  %-16s %s\n' "Warnings:" "${STATS[warnings]}"
		printf '  %-16s %s\n' "Duration:" "$(duration_human "${elapsed}")"
		printf '  %-16s %s\n' "Log:" "${LOG_FILE:-<not configured>}"
		printf '  %-16s %s\n' "Error log:" "${ERROR_LOG_FILE:-<not configured>}"

		if ((${#SITE_REPORT[@]})); then
			printf '  Results:\n'
			for entry in "${SITE_REPORT[@]}"; do
				status="${entry%%|*}"
				path="${entry#*|}"
				case "${status}" in
					OK)   printf '    %s✓ OK%s   %s\n' "${C_GREEN}" "${C_RESET}" "${path}" ;;
					FAIL) printf '    %s✗ FAIL%s %s\n' "${C_RED}" "${C_RESET}" "${path}" ;;
					SKIP) printf '    %s- SKIP%s %s\n' "${C_DIM}" "${C_RESET}" "${path}" ;;
				esac
			done
		fi

		printf '\n'
		if ((DIE_CODE != 0)); then
			printf '%s✗ aborted with exit code %s%s\n' "${C_RED}" "${DIE_CODE}" "${C_RESET}"
		elif [[ "${STATS[wp_failed]}" == "0" && "${STATS[sites_failed]}" == "0" ]] &&
			{ [[ "${STATS[warnings]}" == "0" ]] || ((!STRICT)); }; then
			printf '%s✓ Completed without errors%s\n' "${C_GREEN}" "${C_RESET}"
		else
			printf '%s✗ %s failed operation(s), %s failed site(s), %s warning(s) — see %s%s\n' \
				"${C_RED}" "${STATS[wp_failed]}" "${STATS[sites_failed]}" "${STATS[warnings]}" "${ERROR_LOG_FILE}" "${C_RESET}"
		fi
	} >&2
	return 0
}

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
apply_defaults() {
	: "${SITES_FILE:=${SCRIPT_DIR}/wp-found.txt}"
	: "${DISCOVER_SCRIPT:=${SCRIPT_DIR}/Find_WP_Senior.sh}"
	: "${LOG_DIR:=${SCRIPT_DIR}}"
	: "${LOG_FILE:=${LOG_DIR}/wp_cli_manager.log}"
	: "${ERROR_LOG_FILE:=${LOG_DIR}/wp_cli_errors.log}"
	: "${LOG_MAX_BYTES:=5242880}"
	: "${BACKUP_DIR:=${SCRIPT_DIR}/backups}"
	: "${KEEP_BACKUPS:=3}"
	: "${WP_TIMEOUT:=600}"
	: "${JOBS:=1}"
	: "${WP_CLI_BIN:=}"
	: "${SITE_URL:=}"
	: "${DEFAULT_USER:=}"
	: "${ASTRA_KEY:=}"
	: "${ASTRA_KEY_FILE:=}"
	# Kept from v5.0 for compatibility: plugins that break the WP bootstrap.
	: "${SKIP_PLUGINS:=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer}"
	: "${EXCLUDE_PLUGINS:=}"
	return 0
}

preload_cli_paths() {
	# --config and --log-dir are handled before the real parsing so that the
	# config file and the log destination are known to every error path,
	# including "usage" errors raised while parsing the remaining arguments.
	local arg=""
	while (($#)); do
		arg="$1"
		case "${arg}" in
			-C|--config)  [[ -n "${2:-}" ]] && CONFIG_FILE="$2" ;;
			--config=*)   CONFIG_FILE="${arg#*=}" ;;
			-L|--log-dir) [[ -n "${2:-}" ]] && LOG_DIR="$2" ;;
			--log-dir=*)  LOG_DIR="${arg#*=}" ;;
		esac
		shift
	done
	return 0
}

load_config() {
	local file="${CONFIG_FILE:-${CONFIG_FILE_DEFAULT}}"
	[[ -e "${file}" ]] || return 0
	[[ -f "${file}" ]] || die "config file is not a regular file: ${file}" "${EX_USAGE}"
	[[ -r "${file}" ]] || die "config file is not readable: ${file}" "${EX_USAGE}"

	# The file is sourced: refuse group/world writable permissions and syntax
	# errors (a syntax error in a sourced file would abort the shell with an
	# unrelated exit code).
	local perms=""
	perms="$(file_perms "${file}")"
	if [[ -n "${perms}" && "${perms}" =~ [2367]$ ]]; then
		die "refusing to source a group/world writable config file: ${file} (chmod 0600)" "${EX_USAGE}"
	fi
	if ! "${BASH:-bash}" -n "${file}" 2>/dev/null; then
		die "config file contains a shell syntax error: ${file}" "${EX_USAGE}"
	fi

	# shellcheck disable=SC1090
	source "${file}" || die "failed to load config file: ${file}" "${EX_USAGE}"
	log_debug "config loaded: ${file}"
	return 0
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
usage_error() {
	log ERROR "$1"
	printf 'Try "%s --help" for more information.\n' "${SCRIPT_NAME}" >&2
	exit "${EX_USAGE}"
}

need_value() {
	if (($2 >= 2)) && [[ -n "${3:-}" ]]; then
		return 0
	fi
	usage_error "option '$1' requires a value"
}

set_mode() {
	local new_mode="$1" flag="$2"
	if [[ -n "${MODE}" && "${MODE}" != "${new_mode}" ]]; then
		usage_error "conflicting modes: '${MODE}' and '${new_mode}' (${flag})"
	fi
	MODE="${new_mode}"
	return 0
}

parse_args() {
	local arg=""
	while (($#)); do
		arg="$1"
		case "${arg}" in
			-f|--full)          set_mode full "$arg"; shift ;;
			-c|--core)          set_mode core "$arg"; shift ;;
			-p|--plugins)       set_mode plugins "$arg"; shift ;;
			-t|--themes)        set_mode themes "$arg"; shift ;;
			-d|--db-optimize)   set_mode db-optimize "$arg"; shift ;;
			-x|--db-fix)        set_mode db-fix "$arg"; shift ;;
			-r|--cron)          set_mode cron "$arg"; shift ;;
			-s|--astra)         set_mode astra "$arg"; shift ;;
			-l|--list-plugins)  set_mode list-plugins "$arg"; shift ;;
			-m|--plugin-manage) set_mode plugin-manage "$arg"; shift ;;
			--status)           set_mode status "$arg"; shift ;;
			--verify)           set_mode verify "$arg"; shift ;;

			-S|--site)              need_value "${arg}" "$#" "${2:-}"; TARGET_SITE="$2"; shift 2 ;;
			--site=*)               TARGET_SITE="${arg#*=}"; shift ;;
			--sites-file)           need_value "${arg}" "$#" "${2:-}"; SITES_FILE="$2"; shift 2 ;;
			--sites-file=*)         SITES_FILE="${arg#*=}"; shift ;;
			-A|--action)            need_value "${arg}" "$#" "${2:-}"; PLUGIN_ACTION="$2"; shift 2 ;;
			--action=*)             PLUGIN_ACTION="${arg#*=}"; shift ;;
			-N|--name)              need_value "${arg}" "$#" "${2:-}"; PLUGIN_NAME="$2"; shift 2 ;;
			--name=*)               PLUGIN_NAME="${arg#*=}"; shift ;;
			-u|--user)              need_value "${arg}" "$#" "${2:-}"; USER_OVERRIDE="$2"; shift 2 ;;
			--user=*)               USER_OVERRIDE="${arg#*=}"; shift ;;
			-U|--url)               need_value "${arg}" "$#" "${2:-}"; URL_OVERRIDE="$2"; shift 2 ;;
			--url=*)                URL_OVERRIDE="${arg#*=}"; shift ;;
			-j|--jobs)              need_value "${arg}" "$#" "${2:-}"; JOBS="$2"; shift 2 ;;
			--jobs=*)               JOBS="${arg#*=}"; shift ;;
			-b|--backup)            need_value "${arg}" "$#" "${2:-}"; BACKUP_MODE="$2"; shift 2 ;;
			--backup=*)             BACKUP_MODE="${arg#*=}"; shift ;;
			-B|--backup-dir)        need_value "${arg}" "$#" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
			--backup-dir=*)         BACKUP_DIR="${arg#*=}"; shift ;;
			--keep-backups)         need_value "${arg}" "$#" "${2:-}"; KEEP_BACKUPS="$2"; shift 2 ;;
			--keep-backups=*)       KEEP_BACKUPS="${arg#*=}"; shift ;;
			-k|--skip-plugins)      need_value "${arg}" "$#" "${2:-}"; SKIP_PLUGINS="$2"; shift 2 ;;
			--skip-plugins=*)       SKIP_PLUGINS="${arg#*=}"; shift ;;
			-e|--exclude-plugins)   need_value "${arg}" "$#" "${2:-}"; EXCLUDE_PLUGINS="$2"; shift 2 ;;
			--exclude-plugins=*)    EXCLUDE_PLUGINS="${arg#*=}"; shift ;;
			-T|--timeout)           need_value "${arg}" "$#" "${2:-}"; TIMEOUT_OVERRIDE="$2"; shift 2 ;;
			--timeout=*)            TIMEOUT_OVERRIDE="${arg#*=}"; shift ;;
			-L|--log-dir)           need_value "${arg}" "$#" "${2:-}"; LOG_DIR="$2"; shift 2 ;;
			--log-dir=*)            LOG_DIR="${arg#*=}"; shift ;;
			--wp-bin)               need_value "${arg}" "$#" "${2:-}"; WP_BIN_OVERRIDE="$2"; shift 2 ;;
			--wp-bin=*)             WP_BIN_OVERRIDE="${arg#*=}"; shift ;;
			--astra-key-file)       need_value "${arg}" "$#" "${2:-}"; ASTRA_KEY_FILE="$2"; shift 2 ;;
			--astra-key-file=*)     ASTRA_KEY_FILE="${arg#*=}"; shift ;;
			-C|--config)            need_value "${arg}" "$#" "${2:-}"; CONFIG_FILE="$2"; shift 2 ;;
			--config=*)             CONFIG_FILE="${arg#*=}"; shift ;;

			-n|--dry-run)           DRY_RUN=1; shift ;;
			--only-active)          ONLY_ACTIVE=1; shift ;;
			-F|--force)             FORCE=1; shift ;;
			-y|--yes)               FORCE=1; shift ;;
			--strict)               STRICT=1; shift ;;
			--no-backup)            NO_BACKUP=1; shift ;;
			--no-discover)          NO_DISCOVER=1; shift ;;
			--no-user-switch)       USER_SWITCH=0; shift ;;
			-J|--json)              JSON_OUT=1; shift ;;
			-D|--DEBUG|--debug)     DEBUG=1; shift ;;
			-q|--quiet)             QUIET=1; shift ;;
			-v|--verbose)           VERBOSE=1; shift ;;
			--no-color)             COLOR_MODE="never"; shift ;;
			--color)                COLOR_MODE="always"; shift ;;
			--list-sites)           LIST_SITES_ONLY=1; shift ;;
			-V|--version)           printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit "${EX_OK}" ;;
			-h|--help)              usage; exit "${EX_OK}" ;;
			--)
				shift
				if (($#)); then
					usage_error "unexpected argument(s): $*"
				fi
				;;
			-*) usage_error "unknown option: ${arg}" ;;
			*)  usage_error "unexpected argument: ${arg}" ;;
		esac
	done
	return 0
}

validate_options() {
	if ((!LIST_SITES_ONLY)) && [[ -z "${MODE}" ]]; then
		usage_error "no mode specified"
	fi

	if [[ "${MODE}" == "plugin-manage" ]]; then
		[[ -n "${PLUGIN_ACTION}" ]] || usage_error "--plugin-manage requires --action activate|deactivate|delete"
		[[ -n "${PLUGIN_NAME}" ]] || usage_error "--plugin-manage requires --name <plugin>"
		case "${PLUGIN_ACTION}" in
			activate|deactivate|delete) ;;
			*) usage_error "invalid action '${PLUGIN_ACTION}' (activate|deactivate|delete)" ;;
		esac
		if [[ "${PLUGIN_ACTION}" == "delete" ]] && ((!FORCE)); then
			JOBS=1   # confirmation prompts cannot be answered inside parallel batches
		fi
	fi

	if [[ -n "${USER_OVERRIDE}" ]] && ! is_valid_username "${USER_OVERRIDE}"; then
		usage_error "invalid user name: ${USER_OVERRIDE}"
	fi
	if [[ -n "${DEFAULT_USER}" ]] && ! is_valid_username "${DEFAULT_USER}"; then
		usage_error "invalid DEFAULT_USER in config: ${DEFAULT_USER}"
	fi

	case "${BACKUP_MODE}" in
		""|db|full) ;;
		*) usage_error "--backup must be 'db' or 'full' (got: ${BACKUP_MODE})" ;;
	esac

	is_uint "${JOBS}" || usage_error "--jobs requires a positive integer"
	((JOBS >= 1)) || usage_error "--jobs must be >= 1"
	is_uint "${KEEP_BACKUPS}" || usage_error "--keep-backups requires a non-negative integer"
	if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
		is_uint "${TIMEOUT_OVERRIDE}" || usage_error "--timeout requires a non-negative integer"
		WP_TIMEOUT="${TIMEOUT_OVERRIDE}"
	fi
	is_uint "${WP_TIMEOUT}" || usage_error "WP_TIMEOUT must be a non-negative integer (got: ${WP_TIMEOUT})"
	return 0
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
init_runtime() {
	START_TS="$(date +%s)"
	RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
	CURRENT_USER="$(id -un 2>/dev/null || printf 'unknown')"
	return 0
}

resolve_log_paths() {
	[[ -n "${LOG_DIR}" ]] || LOG_DIR="${SCRIPT_DIR}"
	if [[ ! -d "${LOG_DIR}" ]]; then
		mkdir -p -- "${LOG_DIR}" 2>/dev/null || die "cannot create log directory: ${LOG_DIR}" "${EX_PREFLIGHT}"
	fi
	[[ -w "${LOG_DIR}" ]] || die "log directory is not writable: ${LOG_DIR}" "${EX_PREFLIGHT}"
	LOG_FILE="${LOG_DIR}/$(basename -- "${LOG_FILE}")"
	ERROR_LOG_FILE="${LOG_DIR}/$(basename -- "${ERROR_LOG_FILE}")"
	return 0
}

preflight() {
	_rotate_log "${LOG_FILE}" "${LOG_MAX_BYTES}"
	_rotate_log "${ERROR_LOG_FILE}" "${LOG_MAX_BYTES}"
	{
		printf '=== RUN %s | mode=%s | host=%s | user=%s | pid=%s ===\n' \
			"${RUN_ID}" "${MODE:-list-sites}" "$(hostname 2>/dev/null || printf '?')" "${CURRENT_USER}" "$$"
	} >>"${ERROR_LOG_FILE}" 2>/dev/null || true

	# Temporary file for WP-CLI stderr (keeps stdout free of PHP notices)
	WP_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/wp-cli-update.XXXXXX")" ||
		die "cannot create a temporary file in ${TMPDIR:-/tmp}" "${EX_PREFLIGHT}"

	# WP-CLI binary
	if [[ -n "${WP_BIN_OVERRIDE}" ]]; then
		WP_BIN="${WP_BIN_OVERRIDE}"
	elif [[ -n "${WP_CLI_BIN}" ]]; then
		WP_BIN="${WP_CLI_BIN}"
	elif have wp; then
		WP_BIN="$(command -v wp)"
	elif [[ -x /usr/local/bin/wp ]]; then
		WP_BIN="/usr/local/bin/wp"
	elif [[ -x /usr/bin/wp ]]; then
		WP_BIN="/usr/bin/wp"
	else
		die "WP-CLI not found — install it or pass --wp-bin PATH (https://wp-cli.org)" "${EX_PREFLIGHT}"
	fi
	[[ -x "${WP_BIN}" ]] || die "WP-CLI is not executable: ${WP_BIN}" "${EX_PREFLIGHT}"

	have jq && HAS_JQ=1
	have timeout && TIMEOUT_BIN="$(command -v timeout)"
	if [[ -z "${TIMEOUT_BIN}" ]] && have gtimeout; then TIMEOUT_BIN="$(command -v gtimeout)"; fi
	have env && ENV_BIN="$(command -v env)"
	have tar && TAR_BIN="$(command -v tar)"

	# Astra licence: file wins over environment/plain variable.
	if [[ -n "${ASTRA_KEY_FILE}" ]]; then
		[[ -r "${ASTRA_KEY_FILE}" ]] || die "Astra key file is not readable: ${ASTRA_KEY_FILE}" "${EX_PREFLIGHT}"
		ASTRA_KEY="$(trim "$(head -n 1 -- "${ASTRA_KEY_FILE}" 2>/dev/null || true)")"
	fi
	[[ -n "${ASTRA_KEY}" ]] || ASTRA_KEY="YOUR_KEY"

	# Privilege switching
	if ((USER_SWITCH)); then
		if [[ "${CURRENT_USER}" != "root" ]]; then
			die "must run as root to switch users; use --no-user-switch to run WP-CLI as ${CURRENT_USER}" "${EX_PREFLIGHT}"
		fi
		if have runuser; then
			PRIV_KIND="runuser"
		elif have sudo; then
			PRIV_KIND="sudo"
		elif have su; then
			PRIV_KIND="su"
		else
			die "no privilege switching tool found (runuser/sudo/su)" "${EX_PREFLIGHT}"
		fi
	else
		PRIV_KIND="none"
	fi

	csv_to_array "${SKIP_PLUGINS}"; SKIP_PLUGINS_ARR=(${CSV_ARR[@]+"${CSV_ARR[@]}"})
	csv_to_array "${EXCLUDE_PLUGINS}"; EXCLUDE_PLUGINS_ARR=(${CSV_ARR[@]+"${CSV_ARR[@]}"})

	((HAS_JQ)) || log_debug "jq not found — plugin inventory uses WP-CLI CSV output"
	if [[ -z "${TIMEOUT_BIN}" ]] && ((WP_TIMEOUT > 0)); then
		log_debug "timeout(1) not found — per-command timeout disabled"
	fi
	return 0
}

# ------------------------------------------------------------------------------
# Locking (single instance)
# ------------------------------------------------------------------------------
acquire_lock() {
	LOCK_DIR="${TMPDIR:-/tmp}/wp-cli-update.$(id -u).lock"
	if mkdir -- "${LOCK_DIR}" 2>/dev/null; then
		LOCK_HELD=1
		printf '%s\n' "$$" >"${LOCK_DIR}/pid" 2>/dev/null || true
		return 0
	fi
	local other=""
	if [[ -r "${LOCK_DIR}/pid" ]]; then
		other="$(cat -- "${LOCK_DIR}/pid" 2>/dev/null || true)"
	fi
	if [[ -n "${other}" ]] && kill -0 "${other}" 2>/dev/null; then
		die "another instance is already running (pid ${other}, lock ${LOCK_DIR})" "${EX_PREFLIGHT}"
	fi
	log_warn "removing stale lock: ${LOCK_DIR}"
	rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
	mkdir -- "${LOCK_DIR}" 2>/dev/null || die "cannot create lock ${LOCK_DIR}" "${EX_PREFLIGHT}"
	LOCK_HELD=1
	printf '%s\n' "$$" >"${LOCK_DIR}/pid" 2>/dev/null || true
	return 0
}

# ------------------------------------------------------------------------------
# WP-CLI execution layer
# ------------------------------------------------------------------------------
shell_join() {
	local out="" arg=""
	for arg in "$@"; do
		printf -v arg '%q' "${arg}"
		out+="${arg} "
	done
	printf '%s' "${out% }"
	return 0
}

user_home() {
	local user="$1" home=""
	if have getent; then
		home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
	fi
	if [[ -z "${home}" && -r /etc/passwd ]]; then
		home="$(awk -F: -v u="${user}" '$1 == u { print $6; exit }' /etc/passwd 2>/dev/null || true)"
	fi
	home="$(trim "${home}")"
	[[ -d "${home}" ]] || home="${TMPDIR:-/tmp}"
	printf '%s' "${home}"
	return 0
}

# Fills the global WP_CMD array: wp --path=... [global flags] <args...>
build_wp_cmd() {
	local site="$1" user="$2" url="$3"
	shift 3
	local joined=""

	WP_CMD=( "${WP_BIN}" "--path=${site}" --no-color )
	if [[ "${user}" == "root" ]]; then
		WP_CMD+=( --allow-root )
	fi
	if ((${#SKIP_PLUGINS_ARR[@]})); then
		joined="$(IFS=,; printf '%s' "${SKIP_PLUGINS_ARR[*]}")"
		WP_CMD+=( "--skip-plugins=${joined}" )
	fi
	if [[ -n "${url}" ]]; then
		WP_CMD+=( "--url=${url}" )
	fi
	WP_CMD+=( "$@" )
	return 0
}

# Read-only commands are always executed, also with --dry-run.
wp_is_readonly() {
	case "${1:-} ${2:-}" in
		"core version"|"core is-installed"|"core check-update"|"core verify-checksums"|\
		"plugin list"|"plugin status"|"plugin verify-checksums"|"theme list"|\
		"db size"|"option get"|"cron event list"|"config get"|"config list") return 0 ;;
	esac
	return 1
}

wp_supports_dry_run() {
	case "${1:-} ${2:-}" in
		"core update"|"plugin update"|"theme update") return 0 ;;
	esac
	return 1
}

# Execute WP-CLI. stdout -> WP_OUT, stderr -> WP_ERR_FILE. Returns WP-CLI status.
run_wp() {
	local site="$1" user="$2" url="$3"
	shift 3
	local -a wp_argv=() inner=() outer=()
	local rc=0 label="" line=""

	build_wp_cmd "${site}" "${user}" "${url}" "$@"
	wp_argv=( "${WP_CMD[@]}" )
	label="wp $*"
	[[ -n "${url}" ]] && label="wp $* (--url ${url})"

	if ((DRY_RUN)) && ! wp_is_readonly "$@"; then
		if wp_supports_dry_run "$@"; then
			wp_argv+=( --dry-run )
			log_info "[dry-run] $(redact "${label}") --dry-run"
		else
			log_info "[dry-run] skipped (mutating): $(redact "${label}")"
			WP_OUT=""
			((WP_NOCOUNT)) || ((STATS[wp_skipped]++)) || true
			return 0
		fi
	fi

	inner=()
	if [[ -n "${TIMEOUT_BIN}" ]] && ((WP_TIMEOUT > 0)); then
		inner+=( "${TIMEOUT_BIN}" "${WP_TIMEOUT}" )
	fi
	if [[ -n "${ENV_BIN}" ]]; then
		inner+=( "${ENV_BIN}" "HOME=$(user_home "${user}")" )
	fi
	inner+=( "${wp_argv[@]}" )

	case "${PRIV_KIND}" in
		runuser) outer=( runuser -u "${user}" -- "${inner[@]}" ) ;;
		sudo)    outer=( sudo -n -u "${user}" -- "${inner[@]}" ) ;;
		su)      outer=( su -s /bin/sh "${user}" -c "$(shell_join "${inner[@]}")" ) ;;
		*)       outer=( "${inner[@]}" ) ;;
	esac

	: >"${WP_ERR_FILE}"
	log_debug "exec[${PRIV_KIND}] ${user}@${site}: $(redact "${label}")"

	WP_OUT="$( "${outer[@]}" 2>"${WP_ERR_FILE}" </dev/null )" || rc=$?

	local err=""
	err="$(cat -- "${WP_ERR_FILE}" 2>/dev/null || true)"

	if ((rc == 0)); then
		((WP_NOCOUNT)) || ((STATS[wp_ok]++)) || true
		log_ok "$(redact "${label}")"
		if [[ -n "${err}" ]]; then
			log_debug "stderr: ${err}"
		fi
		if ((VERBOSE)) && [[ -n "${WP_OUT}" ]]; then
			while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${WP_OUT}"
		fi
		return 0
	fi

	if ((WP_SOFT)); then
		log_warn "optional step failed (rc=${rc}): $(redact "${label}")"
		[[ -n "${err}" ]] && log_debug "stderr: ${err}"
		return "${rc}"
	fi

	((WP_NOCOUNT)) || ((STATS[wp_failed]++)) || true
	log_err "$(redact "${label}") — failed with exit code ${rc}"
	[[ -n "${err}" ]] && WP_OUT+=$'\n'"${err}"
	log_error_detail "${site}" "${label}" "${rc}" "${WP_OUT}"
	print_wp_error "${site}" "${label}" "${rc}" "${WP_OUT}"
	return "${rc}"
}

print_wp_error() {
	local site="$1" label="$2" rc="$3" output="$4" count=0 line=""
	((JSON_OUT)) && return 0
	{
		printf '\n%s┌─ WP-CLI error ────────────────────────────────────────────%s\n' "${C_RED}" "${C_RESET}"
		printf '%s│%s Site    : %s\n' "${C_RED}" "${C_RESET}" "${site}"
		printf '%s│%s Command : %s\n' "${C_RED}" "${C_RESET}" "$(redact "${label}")"
		printf '%s│%s Exit    : %s\n' "${C_RED}" "${C_RESET}" "${rc}"
		printf '%s├───────────────────────────────────────────────────────────%s\n' "${C_RED}" "${C_RESET}"
		if [[ -n "${output}" ]]; then
			while IFS= read -r line; do
				if ((count < 20)); then
					printf '%s│%s %s\n' "${C_RED}" "${C_RESET}" "$(redact "${line}")"
					((count++)) || true
				fi
			done <<<"${output}"
			if ((count >= 20)); then
				printf '%s│%s [... output truncated, see error log]%s\n' "${C_RED}" "${C_RESET}" ""
			fi
		else
			printf '%s│%s (no output captured)\n' "${C_RED}" "${C_RESET}"
		fi
		printf '%s└─ full details: %s%s\n\n' "${C_RED}" "${ERROR_LOG_FILE}" "${C_RESET}"
	} >&2
	return 0
}

# Probe: never touches success/failure statistics.
wp_probe() {
	local rc=0
	WP_NOCOUNT=1
	run_wp "$@" || rc=$?
	WP_NOCOUNT=0
	return "${rc}"
}

# Optional step: counted neither as success nor as failure.
wp_soft() {
	local rc=0
	WP_NOCOUNT=1
	WP_SOFT=1
	run_wp "$@" || rc=$?
	WP_SOFT=0
	WP_NOCOUNT=0
	return "${rc}"
}

# ------------------------------------------------------------------------------
# Site metadata
# ------------------------------------------------------------------------------
detect_site_url() {
	local site="$1" cfg="${1}/wp-config.php" value=""
	if [[ -n "${URL_OVERRIDE}" ]]; then
		printf '%s' "${URL_OVERRIDE}"
		return 0
	fi
	if [[ -f "${cfg}" ]]; then
		value="$(grep -E "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"](WP_HOME|WP_SITEURL)['\"]" -- "${cfg}" 2>/dev/null |
			sed -E "s/.*['\"](WP_HOME|WP_SITEURL)['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\2/" |
			head -n 1 || true)"
	fi
	printf '%s' "$(trim "${value}")"
	return 0
}

is_multisite() {
	local cfg="$1/wp-config.php"
	[[ -f "${cfg}" ]] || return 1
	grep -qE "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]MULTISITE['\"][[:space:]]*,[[:space:]]*true" -- "${cfg}" 2>/dev/null
}

owner_of() {
	local target="$1" owner=""
	owner="$(stat -c '%U' -- "${target}" 2>/dev/null || stat -f '%Su' -- "${target}" 2>/dev/null || true)"
	printf '%s' "$(trim "${owner}")"
	return 0
}

resolve_site_user() {
	local site="$1" user="" candidate="" owner=""

	if [[ -n "${USER_CACHE[${site}]:-}" ]]; then
		printf '%s' "${USER_CACHE[${site}]}"
		return 0
	fi

	if [[ -n "${USER_OVERRIDE}" ]]; then
		user="${USER_OVERRIDE}"
	elif [[ -n "${DEFAULT_USER}" ]]; then
		user="${DEFAULT_USER}"
	elif [[ -f "${site}/.wp-cli-user" ]]; then
		user="$(trim "$(head -n 1 -- "${site}/.wp-cli-user" 2>/dev/null || true)")"
		if ! is_valid_username "${user}"; then
			log_warn "ignoring invalid user name in ${site}/.wp-cli-user"
			user=""
		else
			log_debug "user from ${site}/.wp-cli-user: ${user}"
		fi
	fi

	if [[ -z "${user}" ]]; then
		for candidate in "${site}/wp-config.php" "${site}" "${site}/wp-content"; do
			[[ -e "${candidate}" ]] || continue
			owner="$(owner_of "${candidate}")"
			if [[ -n "${owner}" && "${owner}" != "UNKNOWN" && "${owner}" != "root" ]] && id -u "${owner}" >/dev/null 2>&1; then
				user="${owner}"
				log_debug "user from owner of ${candidate}: ${user}"
				break
			fi
		done
	fi

	if [[ -z "${user}" ]] || ! id -u "${user}" >/dev/null 2>&1; then
		return 1
	fi
	if [[ "${user}" == "root" ]] && ((!FORCE)); then
		log_warn "refusing to run WP-CLI as root for ${site} (use --force to allow)"
		return 1
	fi

	USER_CACHE["${site}"]="${user}"
	printf '%s' "${user}"
	return 0
}

# ------------------------------------------------------------------------------
# Plugin inventory (TSV: name, title, status, version, update, update_version)
# ------------------------------------------------------------------------------
csv_to_tsv() {
	awk '
		function emit() {
			if (nf == 6 && f1 != "name") print f1 "\t" f2 "\t" f3 "\t" f4 "\t" f5 "\t" f6
		}
		{
			line = $0
			nf = 0; f1=f2=f3=f4=f5=f6=""; cur = ""; inq = 0
			n = length(line)
			for (i = 1; i <= n; i++) {
				c = substr(line, i, 1)
				if (inq) {
					if (c == "\"") {
						if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ }
						else inq = 0
					} else cur = cur c
				} else {
					if (c == "\"") inq = 1
					else if (c == ",") {
						nf++
						if (nf == 1) f1 = cur; else if (nf == 2) f2 = cur
						else if (nf == 3) f3 = cur; else if (nf == 4) f4 = cur
						else if (nf == 5) f5 = cur
						cur = ""
					} else cur = cur c
				}
			}
			nf++
			if (nf == 1) f1 = cur; else if (nf == 2) f2 = cur
			else if (nf == 3) f3 = cur; else if (nf == 4) f4 = cur
			else if (nf == 5) f5 = cur; else if (nf == 6) f6 = cur
			emit()
		}
	'
}

plugin_json_to_tsv() {
	if ((HAS_JQ)); then
		printf '%s' "$1" | jq -r '
			(if type == "array" then . else [] end)[]
			| [ (.name // ""), (.title // ""), (.status // ""), (.version // ""),
			    ((.update // "none") | tostring), (.update_version // "") ]
			| @tsv' 2>/dev/null
		return 0
	fi
	printf '%s' "$1" | tr -d '\n' | sed -E 's/\},[[:space:]]*\{/\}\n\{/g; s/^\[//; s/\]$//' |
		while IFS= read -r obj; do
			local name="" title="" status="" version="" update="" updver=""
			name="$(printf '%s' "${obj}" | sed -nE 's/.*"name":"([^"]*)".*/\1/p')"
			[[ -z "${name}" ]] && continue
			title="$(printf '%s' "${obj}" | sed -nE 's/.*"title":"([^"]*)".*/\1/p')"
			status="$(printf '%s' "${obj}" | sed -nE 's/.*"status":"([^"]*)".*/\1/p')"
			version="$(printf '%s' "${obj}" | sed -nE 's/.*"version":"([^"]*)".*/\1/p')"
			update="$(printf '%s' "${obj}" | sed -nE 's/.*"update":"?([^",]*)"?.*/\1/p')"
			updver="$(printf '%s' "${obj}" | sed -nE 's/.*"update_version":"([^"]*)".*/\1/p')"
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${title}" "${status}" "${version}" "${update:-none}" "${updver}"
		done
	return 0
}

load_plugins() {
	local site="$1" user="$2" url="$3" out="" line="" rc=0
	local fields="--fields=name,title,status,version,update,update_version"
	local -a clean=()

	PLUGIN_LINES=()

	if ((HAS_JQ)); then
		run_wp "${site}" "${user}" "${url}" plugin list "${fields}" --format=json || rc=$?
		out="${WP_OUT}"
		if [[ "${out}" != "["* ]]; then
			out="$(printf '%s' "${out}" | sed -n '/^\[/,$p' || true)"
		fi
		[[ -z "${out}" ]] && out="[]"
		mapfile -t PLUGIN_LINES < <(plugin_json_to_tsv "${out}")
	else
		run_wp "${site}" "${user}" "${url}" plugin list "${fields}" --format=csv || rc=$?
		out="${WP_OUT}"
		mapfile -t PLUGIN_LINES < <(printf '%s' "${out}" | csv_to_tsv)
	fi

	for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
		[[ -n "${line}" ]] && clean+=("${line}")
	done
	PLUGIN_LINES=(${clean[@]+"${clean[@]}"})
	return "${rc}"
}

plugin_slug() {
	printf '%s' "${1%.php}"
	return 0
}

# ------------------------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------------------------
confirm() {
	local prompt="$1" expected="$2" answer=""
	((FORCE)) && return 0
	if [[ ! -r /dev/tty ]]; then
		log_err "confirmation required but no TTY is available — re-run with --yes"
		return 1
	fi
	printf '%s' "${prompt}" >&2
	IFS= read -r answer </dev/tty || answer=""
	if [[ "${answer}" != "${expected}" ]]; then
		log_info "cancelled by user"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------------------
# Backups
# ------------------------------------------------------------------------------
ensure_dir_for_user() {
	local dir="$1" user="$2" group=""
	[[ -d "${dir}" ]] && return 0
	if ((USER_SWITCH)) && [[ "${CURRENT_USER}" == "root" ]]; then
		group="$(id -gn -- "${user}" 2>/dev/null || true)"
		if have install && [[ -n "${group}" ]]; then
			install -d -m 0750 -o "${user}" -g "${group}" -- "${dir}" 2>/dev/null && return 0
		fi
		mkdir -p -- "${dir}" 2>/dev/null || return 1
		chown "${user}" "${dir}" 2>/dev/null || true
		return 0
	fi
	mkdir -p -- "${dir}" 2>/dev/null || return 1
	return 0
}

prune_backups() {
	local dir="$1" keep="$2" i=0
	local -a files=()
	((keep > 0)) || return 0
	mapfile -t files < <(ls -1t -- "${dir}"/db-*.sql "${dir}"/plugin-*.tar.gz 2>/dev/null || true)
	for ((i = keep; i < ${#files[@]}; i++)); do
		rm -f -- "${files[i]}" 2>/dev/null || true
	done
	return 0
}

site_backup_dir() {
	local site="$1"
	# NOTE: "\n" must be part of the tr set, otherwise the trailing newline of
	# basename(1) is part of the complement and is replaced by "_".
	printf '%s/%s' "${BACKUP_DIR}" "$(basename -- "${site}" | tr -c 'A-Za-z0-9._-\n' '_')"
	return 0
}

backup_database() {
	local site="$1" user="$2" url="$3" dir="" file="" rc=0 saved="${WP_TIMEOUT}"
	dir="$(site_backup_dir "${site}")"
	if ! ensure_dir_for_user "${dir}" "${user}"; then
		log_warn "cannot create backup directory ${dir}"
		return 1
	fi
	file="${dir}/db-$(date '+%Y%m%d-%H%M%S').sql"
	log_info "backing up database: ${file}"
	WP_TIMEOUT=0  # a large dump must not be killed by the per-command timeout
	run_wp "${site}" "${user}" "${url}" db export "${file}" || rc=$?
	WP_TIMEOUT="${saved}"
	if ((rc != 0)) || [[ ! -s "${file}" ]]; then
		log_warn "database backup failed for ${site}"
		return 1
	fi
	log_ok "database backup: ${file}"
	prune_backups "${dir}" "${KEEP_BACKUPS}"
	return 0
}

backup_plugin_files() {
	local site="$1" user="$2" slug="$3" dir="" file="" src=""
	[[ -n "${slug}" ]] || return 0
	if [[ -z "${TAR_BIN}" ]]; then
		log_debug "tar not available — skipping plugin file backup"
		return 0
	fi
	src="${site}/wp-content/plugins/${slug}"
	[[ -d "${src}" ]] || { log_debug "plugin directory not found: ${src}"; return 0; }
	dir="$(site_backup_dir "${site}")"
	if ! ensure_dir_for_user "${dir}" "${user}"; then
		log_warn "cannot create backup directory ${dir}"
		return 1
	fi
	file="${dir}/plugin-${slug}-$(date '+%Y%m%d-%H%M%S').tar.gz"
	if "${TAR_BIN}" -czf "${file}" -C "${site}/wp-content/plugins" "${slug}" 2>/dev/null; then
		log_ok "plugin backup: ${file}"
		prune_backups "${dir}" "${KEEP_BACKUPS}"
		return 0
	fi
	log_warn "plugin backup failed: ${slug}"
	return 1
}

maybe_backup() {
	local site="$1" user="$2" url="$3" mode="$4"
	((NO_BACKUP)) && return 0
	[[ "${mode}" == "db" || "${mode}" == "full" ]] || return 0
	if ((DRY_RUN)); then
		log_info "[dry-run] would create a '${mode}' backup of ${site}"
		return 0
	fi
	backup_database "${site}" "${user}" "${url}" || true
	return 0
}

# ------------------------------------------------------------------------------
# Astra Pro
# ------------------------------------------------------------------------------
astra_update() {
	local site="$1" user="$2" url="$3"
	local line="" name="" status="" update="" found=0 need_update=0 key_ok=0

	[[ "${ASTRA_KEY}" != "YOUR_KEY" && -n "${ASTRA_KEY}" ]] && key_ok=1

	load_plugins "${site}" "${user}" "${url}"
	for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
		IFS=$'\t' read -r name _ status _ update _ <<<"${line}"
		[[ "$(plugin_slug "${name}")" == "astra-addon" ]] || continue
		found=1
		if [[ "${status}" != "active" ]]; then
			log_info "Astra Pro is installed but not active — skipping"
			return 0
		fi
		[[ "${update}" == "available" ]] && need_update=1
	done

	if ((!found)); then
		log_info "Astra Pro (astra-addon) is not installed — nothing to do"
		return 0
	fi
	if ((!need_update)) && ((!FORCE)); then
		log_info "Astra Pro is already up to date"
		return 0
	fi

	run_wp "${site}" "${user}" "${url}" plugin update astra-addon && return 0

	if ((!key_ok)); then
		log_warn "Astra Pro update failed and no licence key is configured (ASTRA_KEY_FILE)"
		return 1
	fi
	log_info "activating the Astra Pro licence and retrying"
	run_wp "${site}" "${user}" "${url}" brainstormforce license activate astra-addon "${ASTRA_KEY}" || return 1
	run_wp "${site}" "${user}" "${url}" plugin update astra-addon || return 1
	return 0
}

# ------------------------------------------------------------------------------
# Modes
# ------------------------------------------------------------------------------
update_active_plugins() {
	local site="$1" user="$2" url="$3"
	local line="" name="" status="" update=""
	local -a targets=()
	load_plugins "${site}" "${user}" "${url}" || return 1
	for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
		IFS=$'\t' read -r name _ status _ update _ <<<"${line}"
		[[ "${status}" == "active" ]] || continue
		[[ "${update}" == "available" ]] || continue
		targets+=("$(plugin_slug "${name}")")
	done
	if ((${#targets[@]} == 0)); then
		log_info "no active plugin updates available"
		((STATS[wp_skipped]++)) || true
		return 0
	fi
	log_info "updating ${#targets[@]} active plugin(s) with pending updates"
	run_wp "${site}" "${user}" "${url}" plugin update "${targets[@]}"
	return $?
}

plugin_update_args() {
	local -a args=( plugin update --all )
	if ((${#EXCLUDE_PLUGINS_ARR[@]})); then
		args+=( "--exclude=$(IFS=,; printf '%s' "${EXCLUDE_PLUGINS_ARR[*]}")" )
	fi
	PLUGIN_UPDATE_ARGS=(${args[@]+"${args[@]}"})
	return 0
}

mode_core() {
	local site="$1" user="$2" url="$3"
	run_wp "${site}" "${user}" "${url}" core update || return 1
	run_wp "${site}" "${user}" "${url}" core update-db || return 1
	wp_soft "${site}" "${user}" "${url}" cache flush
	wp_soft "${site}" "${user}" "${url}" rewrite flush --hard
	return 0
}

mode_plugins() {
	local site="$1" user="$2" url="$3"
	if ((ONLY_ACTIVE)); then
		update_active_plugins "${site}" "${user}" "${url}"
		return $?
	fi
	plugin_update_args
	run_wp "${site}" "${user}" "${url}" "${PLUGIN_UPDATE_ARGS[@]}"
	return $?
}

mode_themes() {
	local site="$1" user="$2" url="$3"
	run_wp "${site}" "${user}" "${url}" theme update --all
	return $?
}

mode_db_optimize() {
	local site="$1" user="$2" url="$3"
	run_wp "${site}" "${user}" "${url}" db optimize || return 1
	run_wp "${site}" "${user}" "${url}" db repair || return 1
	return 0
}

mode_db_fix() {
	local site="$1" user="$2" url="$3"
	run_wp "${site}" "${user}" "${url}" db repair
	return $?
}

mode_cron() {
	local site="$1" user="$2" url="$3"
	run_wp "${site}" "${user}" "${url}" cron event run --due-now
	return $?
}

mode_full() {
	local site="$1" user="$2" url="$3" rc=0
	maybe_backup "${site}" "${user}" "${url}" "${BACKUP_MODE}"
	run_wp "${site}" "${user}" "${url}" core update || rc=1
	if ((ONLY_ACTIVE)); then
		update_active_plugins "${site}" "${user}" "${url}" || rc=1
	else
		plugin_update_args
		run_wp "${site}" "${user}" "${url}" "${PLUGIN_UPDATE_ARGS[@]}" || rc=1
	fi
	if [[ "${ASTRA_KEY}" != "YOUR_KEY" && -n "${ASTRA_KEY}" ]]; then
		astra_update "${site}" "${user}" "${url}" || rc=1
	else
		log_debug "Astra licence not configured — skipping the Astra step"
	fi
	run_wp "${site}" "${user}" "${url}" theme update --all || rc=1
	run_wp "${site}" "${user}" "${url}" core update-db || rc=1
	run_wp "${site}" "${user}" "${url}" db optimize || rc=1
	run_wp "${site}" "${user}" "${url}" db repair || rc=1
	run_wp "${site}" "${user}" "${url}" cron event run --due-now || rc=1
	wp_soft "${site}" "${user}" "${url}" cache flush
	return "${rc}"
}

mode_astra() {
	local site="$1" user="$2" url="$3"
	if [[ "${ASTRA_KEY}" == "YOUR_KEY" || -z "${ASTRA_KEY}" ]]; then
		log_err "Astra licence key is not configured — set ASTRA_KEY_FILE (recommended) or ASTRA_KEY"
		return 1
	fi
	FORCE=1  # --astra is expected to be a no-op when the plugin is current
	astra_update "${site}" "${user}" "${url}"
	return $?
}

mode_verify() {
	local site="$1" user="$2" url="$3" rc=0
	run_wp "${site}" "${user}" "${url}" core verify-checksums || rc=1
	run_wp "${site}" "${user}" "${url}" plugin verify-checksums --all || rc=1
	return "${rc}"
}

mode_status() {
	local site="$1" user="$2" url="$3"
	local core_ver="" home="" db_size="" theme_updates=0 updates=0
	local line="" name="" status="" update=""

	wp_probe "${site}" "${user}" "${url}" core version; core_ver="$(trim "${WP_OUT}")"
	wp_probe "${site}" "${user}" "${url}" option get home; home="$(trim "${WP_OUT}")"
	wp_probe "${site}" "${user}" "${url}" db size --size_format=mb; db_size="$(trim "${WP_OUT}")"

	load_plugins "${site}" "${user}" "${url}" || true
	for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
		IFS=$'\t' read -r name _ status _ update _ <<<"${line}"
		if [[ "${update}" == "available" ]]; then
			((updates++)) || true
		fi
	done
	wp_probe "${site}" "${user}" "${url}" theme list --update=available --format=count
	local theme_out
	theme_out="$(trim "${WP_OUT}")"
	is_uint "${theme_out}" && theme_updates="${theme_out}"

	if ((JSON_OUT)); then
		printf '{"type":"status","site":"%s","core":"%s","home":"%s","plugin_updates":%d,"theme_updates":%d,"db_size_mb":"%s","plugins":%d}\n' \
			"$(json_escape "${site}")" "$(json_escape "${core_ver}")" "$(json_escape "${home}")" \
			"${updates}" "${theme_updates}" "$(json_escape "${db_size}")" "${#PLUGIN_LINES[@]}"
		return 0
	fi

	{
		printf '\n%s%s%s\n' "${C_BOLD}" "${site}" "${C_RESET}"
		printf '  core version   : %s\n' "${core_ver:-<unknown>}"
		printf '  site url       : %s\n' "${home:-<unknown>}"
		printf '  plugins        : %s\n' "${#PLUGIN_LINES[@]}"
		printf '  plugin updates : %s\n' "${updates}"
		printf '  theme updates  : %s\n' "${theme_updates}"
		printf '  database size  : %s MB\n' "${db_size:-<unknown>}"
		if [[ "${updates}" != "0" || "${theme_updates}" != "0" ]]; then
			printf '  %saction needed: %s plugin / %s theme update(s)%s\n' "${C_YELLOW}" "${updates}" "${theme_updates}" "${C_RESET}"
		fi
	} >&2
	return 0
}

mode_list_plugins() {
	local site="$1" user="$2" url="$3"
	local line="" name="" title="" status="" version="" update="" updver="" disp="" row=""
	local count=0 width=24 filter="${PLUGIN_NAME}"
	local -a rows=()

	load_plugins "${site}" "${user}" "${url}" || return 1

	if [[ -n "${filter}" ]]; then
		local needle="${filter,,}" lname="" ltitle=""
		for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
			IFS=$'\t' read -r name title status version update updver <<<"${line}"
			lname="${name,,}"; ltitle="${title,,}"
			if [[ "${lname}" == *"${needle}"* || "${ltitle}" == *"${needle}"* ]]; then
				rows+=("${line}")
			fi
		done
	else
		rows=(${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"})
	fi

	if ((JSON_OUT)); then
		local first=1
		printf '{"type":"plugins","site":"%s","count":%d,"plugins":[' "$(json_escape "${site}")" "${#rows[@]}"
		for row in ${rows[@]+"${rows[@]}"}; do
			IFS=$'\t' read -r name title status version update updver <<<"${row}"
			((first)) || printf ','
			first=0
			printf '{"name":"%s","slug":"%s","title":"%s","status":"%s","version":"%s","update":"%s","update_version":"%s"}' \
				"$(json_escape "${name}")" "$(json_escape "$(plugin_slug "${name}")")" "$(json_escape "${title}")" \
				"$(json_escape "${status}")" "$(json_escape "${version}")" \
				"$(json_escape "${update}")" "$(json_escape "${updver}")"
		done
		printf ']}\n'
		return 0
	fi

	for row in ${rows[@]+"${rows[@]}"}; do
		IFS=$'\t' read -r name title status version update updver <<<"${row}"
		disp="${title:-$(plugin_slug "${name}")}"
		((${#disp} > width)) && width="${#disp}"
	done
	((width > 60)) && width=60

	{
		printf '\n%sPlugins: %s%s (%d)\n' "${C_BOLD}" "${site}" "${C_RESET}" "${#rows[@]}"
		printf '%s%s%s\n' "${C_DIM}" "$(hline $((width + 36)))" "${C_RESET}"
		printf '%s%-*s  %-9s  %-10s  %-12s  %s%s\n' "${C_BOLD}" "${width}" "PLUGIN" "STATUS" "VERSION" "UPDATE" "SLUG" "${C_RESET}"
		printf '%s%s%s\n' "${C_DIM}" "$(hline $((width + 36)))" "${C_RESET}"
	} >&2

	for row in ${rows[@]+"${rows[@]}"}; do
		IFS=$'\t' read -r name title status version update updver <<<"${row}"
		disp="${title:-$(plugin_slug "${name}")}"
		((${#disp} > width)) && disp="${disp:0:$((width - 1))}…"
		local color="${C_DIM}" mark="-"
		case "${status}" in
			active)   color="${C_GREEN}";  mark="✓" ;;
			inactive) color="${C_YELLOW}"; mark="○" ;;
			must-use) color="${C_CYAN}";   mark="!" ;;
		esac
		local up_txt="up to date"
		[[ "${update}" == "available" ]] && up_txt="→ ${updver:-new}"
		printf '%-*s  %s%s %-7s%s  %-10s  %-12s  %s%s%s\n' \
			"${width}" "${disp}" "${color}" "${mark}" "${status}" "${C_RESET}" \
			"${version}" "${up_txt}" "${C_DIM}" "$(plugin_slug "${name}")" "${C_RESET}" >&2
		((count++)) || true
	done

	{
		printf '%s%s%s\n' "${C_DIM}" "$(hline $((width + 36)))" "${C_RESET}"
		printf 'Total: %d plugin(s)\n' "${count}"
	} >&2
	return 0
}

mode_plugin_manage() {
	local site="$1" user="$2" url="$3"
	local line="" name="" title="" status="" chosen="" chosen_title="" chosen_slug="" chosen_status=""
	local needle="${PLUGIN_NAME,,}"
	local -a matches=()
	local match_count=0

	case "${PLUGIN_ACTION}" in
		activate|deactivate|delete) ;;
		*) log_err "invalid action '${PLUGIN_ACTION}' (activate|deactivate|delete)"; return 1 ;;
	esac

	load_plugins "${site}" "${user}" "${url}" || {
		log_err "cannot read the plugin list for ${site} — WP-CLI failed (see the error above)"
		return 1
	}

	for line in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
		IFS=$'\t' read -r name title status _ _ _ <<<"${line}"
		if [[ "$(plugin_slug "${name}")" == "${needle}" || "${name,,}" == "${needle}" ]]; then
			matches=("${line}")   # exact slug/name wins over partial matches
			match_count=1
			break
		fi
		if [[ "${name,,}" == *"${needle}"* || "${title,,}" == *"${needle}"* ]]; then
			matches+=("${line}")
			((match_count++)) || true
		fi
	done

	if ((match_count == 0)); then
		log_err "no plugin matching '${PLUGIN_NAME}' on ${site}"
		local i=0 row=""
		for row in ${PLUGIN_LINES[@]+"${PLUGIN_LINES[@]}"}; do
			IFS=$'\t' read -r name _ _ _ _ _ <<<"${row}"
			printf '  - %s\n' "$(plugin_slug "${name}")" >&2
			((i++)) || true
			((i >= 15)) && break
		done
		return 1
	fi

	if ((match_count > 1)); then
		log_warn "'${PLUGIN_NAME}' matches ${match_count} plugins:"
		local row=""
		for row in "${matches[@]}"; do
			IFS=$'\t' read -r name title _ _ _ _ <<<"${row}"
			printf '  • %s (%s)\n' "$(plugin_slug "${name}")" "${title}" >&2
		done
		log_err "specify the exact plugin slug with --name <slug>"
		return 1
	fi

	IFS=$'\t' read -r chosen chosen_title chosen_status _ _ _ <<<"${matches[0]}"
	chosen_slug="$(plugin_slug "${chosen}")"
	log_debug "matched plugin: ${chosen_slug} (${chosen_title}) status=${chosen_status}"

	case "${PLUGIN_ACTION}" in
		activate)
			if [[ "${chosen_status}" == "active" ]]; then
				log_info "'${chosen_slug}' is already active — nothing to do"
				((STATS[wp_skipped]++)) || true
				return 0
			fi
			run_wp "${site}" "${user}" "${url}" plugin activate "${chosen_slug}"
			return $?
			;;
		deactivate)
			if [[ "${chosen_status}" == "inactive" ]]; then
				log_info "'${chosen_slug}' is already inactive — nothing to do"
				((STATS[wp_skipped]++)) || true
				return 0
			fi
			run_wp "${site}" "${user}" "${url}" plugin deactivate "${chosen_slug}"
			return $?
			;;
		delete)
			log_warn "DESTRUCTIVE: '${chosen_slug}' (${chosen_title}) will be deleted from ${site} (files, and data removed by the plugin)"
			confirm "Type DELETE to confirm deletion of '${chosen_slug}' on ${site}: " "DELETE" || return 1
			if [[ "${chosen_status}" == "active" ]]; then
				log_info "deactivating '${chosen_slug}' before deletion"
				run_wp "${site}" "${user}" "${url}" plugin deactivate "${chosen_slug}" || return 1
			fi
			if ((!NO_BACKUP)) && ((!DRY_RUN)); then
				backup_plugin_files "${site}" "${user}" "${chosen_slug}" || log_warn "continuing without a plugin file backup"
			fi
			run_wp "${site}" "${user}" "${url}" plugin delete "${chosen_slug}"
			return $?
			;;
	esac
	return 1
}

execute_mode() {
	local site="$1" user="$2" url="$3"
	case "${MODE}" in
		full)          mode_full "${site}" "${user}" "${url}"; return $? ;;
		core)          mode_core "${site}" "${user}" "${url}"; return $? ;;
		plugins)       mode_plugins "${site}" "${user}" "${url}"; return $? ;;
		themes)        mode_themes "${site}" "${user}" "${url}"; return $? ;;
		db-optimize)   mode_db_optimize "${site}" "${user}" "${url}"; return $? ;;
		db-fix)        mode_db_fix "${site}" "${user}" "${url}"; return $? ;;
		cron)          mode_cron "${site}" "${user}" "${url}"; return $? ;;
		astra)         mode_astra "${site}" "${user}" "${url}"; return $? ;;
		list-plugins)  mode_list_plugins "${site}" "${user}" "${url}"; return $? ;;
		plugin-manage) mode_plugin_manage "${site}" "${user}" "${url}"; return $? ;;
		status)        mode_status "${site}" "${user}" "${url}"; return $? ;;
		verify)        mode_verify "${site}" "${user}" "${url}"; return $? ;;
		*)             log_err "unknown mode: ${MODE}"; return 1 ;;
	esac
}

# ------------------------------------------------------------------------------
# Site processing
# ------------------------------------------------------------------------------
process_site() {
	local site="$1" rc=0
	local user="" url=""

	((STATS[sites]++)) || true

	if [[ ! -d "${site}" ]]; then
		log_warn "skipping (not a directory): ${site}"
		SITE_REPORT+=("SKIP|${site}")
		((STATS[sites_skipped]++)) || true
		return 0
	fi
	if [[ ! -f "${site}/wp-config.php" && ! -f "${site}/wp-settings.php" && ! -f "${site}/wp-load.php" ]]; then
		log_warn "skipping (not a WordPress installation): ${site}"
		SITE_REPORT+=("SKIP|${site}")
		((STATS[sites_skipped]++)) || true
		return 0
	fi

	if ! user="$(resolve_site_user "${site}")"; then
		log_err "cannot determine a system user for ${site} (use --user or create ${site}/.wp-cli-user)"
		SITE_REPORT+=("FAIL|${site}")
		((STATS[sites_failed]++)) || true
		return 1
	fi
	url="$(detect_site_url "${site}")"
	if [[ -z "${url}" ]] && is_multisite "${site}"; then
		log_debug "multisite detected without WP_HOME/WP_SITEURL — pass --url if WP-CLI needs it"
	fi

	log_info "=== ${site} (user: ${user}${url:+, url: ${url}}) ==="

	execute_mode "${site}" "${user}" "${url}" || rc=$?

	if ((rc == 0)); then
		((STATS[sites_ok]++)) || true
		log_ok "site completed: ${site}"
		SITE_REPORT+=("OK|${site}")
	else
		((STATS[sites_failed]++)) || true
		log_err "site finished with errors (rc=${rc}): ${site}"
		SITE_REPORT+=("FAIL|${site}")
	fi
	return "${rc}"
}

run_parallel() {
	local tmpdir="" i=0 j=0 n=${#SITES[@]} rc=""
	local -a batch=()
	local -a pids=()

	tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wp-cli-update.XXXXXXXX")" || {
		log_warn "cannot create a temporary directory — falling back to sequential processing"
		local site=""
		for site in "${SITES[@]}"; do process_site "${site}" || true; done
		return 0
	}

	while ((i < n)); do
		batch=()
		pids=()
		while ((i < n && ${#batch[@]} < JOBS)); do
			(
				# Each worker needs its own stderr capture file, otherwise
				# concurrent WP-CLI calls would overwrite each other's errors.
				WP_ERR_FILE="${tmpdir}/err.${i}"
				: >"${WP_ERR_FILE}"
				process_site "${SITES[i]}" >"${tmpdir}/out.${i}" 2>&1
				printf '%s' "$?" >"${tmpdir}/rc.${i}"
				printf '%s' "${STATS[warnings]}" >"${tmpdir}/warn.${i}"
			) &
			pids+=("$!")
			batch+=("${i}")
			((i++)) || true
		done
		wait || true
		# Replay each site's output in order and fold its result into the totals.
		for j in "${batch[@]}"; do
			[[ -f "${tmpdir}/out.${j}" ]] && cat -- "${tmpdir}/out.${j}" >&2
			rc="1"
			[[ -f "${tmpdir}/rc.${j}" ]] && rc="$(cat -- "${tmpdir}/rc.${j}" 2>/dev/null || printf '1')"
			local w=0
			if [[ -f "${tmpdir}/warn.${j}" ]]; then
				w="$(cat -- "${tmpdir}/warn.${j}" 2>/dev/null || printf '0')"
			fi
			if is_uint "${w}"; then
				((STATS[warnings] += w)) || true
			fi
			((STATS[sites]++)) || true
			if [[ "${rc}" == "0" ]]; then
				((STATS[sites_ok]++)) || true
				SITE_REPORT+=("OK|${SITES[j]}")
			else
				((STATS[sites_failed]++)) || true
				SITE_REPORT+=("FAIL|${SITES[j]}")
			fi
			rm -f -- "${tmpdir}/out.${j}" "${tmpdir}/rc.${j}" "${tmpdir}/warn.${j}" "${tmpdir}/err.${j}" 2>/dev/null || true
		done
	done

	rm -rf -- "${tmpdir}" 2>/dev/null || true
	return 0
}

# ------------------------------------------------------------------------------
# Site list
# ------------------------------------------------------------------------------
load_sites() {
	local line=""
	SITES=()
	if [[ -n "${TARGET_SITE}" ]]; then
		SITES=("${TARGET_SITE}")
		return 0
	fi
	[[ -f "${SITES_FILE}" ]] || return 1
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="$(trim "${line}")"
		[[ -z "${line}" || "${line}" == \#* ]] && continue
		SITES+=("${line}")
	done <"${SITES_FILE}"
	return 0
}

ensure_sites_file() {
	[[ -n "${TARGET_SITE}" ]] && return 0
	[[ -s "${SITES_FILE}" ]] && return 0

	if ((NO_DISCOVER)); then
		die "sites file is missing or empty: ${SITES_FILE} (discovery disabled with --no-discover)" "${EX_EMPTY}"
	fi

	if [[ -x "${DISCOVER_SCRIPT}" ]]; then
		log_warn "sites file is missing or empty — running ${DISCOVER_SCRIPT}"
		if "${DISCOVER_SCRIPT}" --output "${SITES_FILE}"; then
			log_ok "discovery finished: ${SITES_FILE}"
		else
			log_warn "the discovery script exited with a non-zero status"
		fi
	elif [[ -f "${DISCOVER_SCRIPT}" ]]; then
		log_warn "the discovery script is not executable: ${DISCOVER_SCRIPT} (chmod +x)"
	fi

	[[ -s "${SITES_FILE}" ]] && return 0

	if [[ -t 0 ]]; then
		local answer=""
		log_warn "no sites file — enter a WordPress root to continue (empty answer aborts)"
		printf 'WordPress root: ' >&2
		IFS= read -r answer || answer=""
		answer="$(trim "${answer}")"
		if [[ -n "${answer}" && -d "${answer}" ]]; then
			printf '%s\n' "${answer}" >"${SITES_FILE}"
			log_ok "saved ${answer} to ${SITES_FILE}"
			return 0
		fi
	fi

	die "no sites to process (${SITES_FILE}) — run Find_WP_Senior.sh or pass --site PATH" "${EX_EMPTY}"
}

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
show_banner() {
	((QUIET)) && return 0
	((JSON_OUT)) && return 0
	local mode_desc=""
	case "${MODE}" in
		full)          mode_desc="full update (core, plugins, themes, DB, cron)" ;;
		core)          mode_desc="core update + update-db" ;;
		plugins)       mode_desc="plugin updates" ;;
		themes)        mode_desc="theme updates" ;;
		db-optimize)   mode_desc="database optimize + repair" ;;
		db-fix)        mode_desc="database repair" ;;
		cron)          mode_desc="due WP-Cron events" ;;
		astra)         mode_desc="Astra Pro update" ;;
		list-plugins)  mode_desc="plugin inventory" ;;
		plugin-manage) mode_desc="plugin management (${PLUGIN_ACTION})" ;;
		status)        mode_desc="health report (read-only)" ;;
		verify)        mode_desc="checksum verification (read-only)" ;;
		*)             mode_desc="unknown" ;;
	esac

	{
		printf '\n%sWordPress Maintenance Automation v%s%s\n' "${C_BOLD}" "${SCRIPT_VERSION}" "${C_RESET}"
		printf '%s%s%s\n' "${C_DIM}" "$(hline 62)" "${C_RESET}"
		printf '  mode        : %s\n' "${mode_desc}"
		printf '  target      : %s\n' "${TARGET_SITE:-all sites from ${SITES_FILE}}"
		printf '  wp-cli      : %s\n' "${WP_BIN}"
		if ((USER_SWITCH)); then
			printf '  user switch : yes (%s)\n' "${PRIV_KIND}"
		else
			printf '  user switch : no (running as %s)\n' "${CURRENT_USER}"
		fi
		printf '  parallelism : %s\n' "${JOBS}"
		printf '  plugins     : skip-plugins='%s'\n' "${SKIP_PLUGINS:-<none>}"
		if ((DRY_RUN)); then printf '  %sdry-run     : yes — no changes will be made%s\n' "${C_YELLOW}" "${C_RESET}"; fi
		if [[ -n "${PLUGIN_NAME}" ]]; then printf '  plugin      : %s\n' "${PLUGIN_NAME}"; fi
		if [[ -n "${BACKUP_MODE}" ]]; then printf '  backup      : %s -> %s\n' "${BACKUP_MODE}" "${BACKUP_DIR}"; fi
		printf '%s%s%s\n\n' "${C_DIM}" "$(hline 62)" "${C_RESET}"
	} >&2
	return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
final_exit() {
	if [[ "${STATS[wp_failed]}" != "0" || "${STATS[sites_failed]}" != "0" ]]; then
		exit "${EX_FAIL}"
	fi
	if ((STRICT)) && [[ "${STATS[warnings]}" != "0" ]]; then
		exit "${EX_FAIL}"
	fi
	exit "${EX_OK}"
}

main() {
	init_runtime
	setup_colors
	preload_cli_paths "$@"
	load_config
	apply_defaults
	resolve_log_paths
	parse_args "$@"
	validate_options
	preflight

	log_info "run ${RUN_ID}: mode=${MODE:-list-sites} wp=${WP_BIN} user=${CURRENT_USER}"

	if ((LIST_SITES_ONLY)); then
		ensure_sites_file
		load_sites || die "cannot read ${SITES_FILE}" "${EX_PREFLIGHT}"
		printf '%s\n' ${SITES[@]+"${SITES[@]}"}
		return 0
	fi

	if [[ -n "${TARGET_SITE}" ]]; then
		acquire_lock
		process_site "${TARGET_SITE}" || true
		print_summary
		final_exit
	fi

	ensure_sites_file
	load_sites || die "cannot read ${SITES_FILE}" "${EX_PREFLIGHT}"

	if ((${#SITES[@]} == 0)); then
		log_warn "no sites to process"
		print_summary
		exit "${EX_EMPTY}"
	fi

	if [[ "${MODE}" == "plugin-manage" ]] && ((${#SITES[@]} > 1)) && ((!FORCE)); then
		die "refusing to ${PLUGIN_ACTION} '${PLUGIN_NAME}' on ${#SITES[@]} sites without --force" "${EX_USAGE}"
	fi

	acquire_lock
	show_banner

	if ((JOBS > 1)) && ((${#SITES[@]} > 1)); then
		log_info "processing ${#SITES[@]} site(s), ${JOBS} in parallel"
		run_parallel
	else
		local site=""
		for site in "${SITES[@]}"; do
			process_site "${site}" || true
		done
	fi

	print_summary
	final_exit
}

trap cleanup EXIT
trap on_signal INT TERM

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
