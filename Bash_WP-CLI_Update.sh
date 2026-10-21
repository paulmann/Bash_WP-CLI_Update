#!/usr/bin/env bash
###############################################################################
# WordPress Maintenance Automation
# File:      Bash_WP-CLI_Update.sh
# Version:   6.0.0
# License:   MIT (see LICENSE)
# Repository: https://github.com/paulmann/Bash_WP-CLI_Update
#
# Purpose:
#   Run WP-CLI maintenance operations (core/plugins/themes/database/cron) over
#   many WordPress installations as their owning system users, with structured
#   logging, a lock against parallel runs and one final summary.
#
# Usage:
#   ./Bash_WP-CLI_Update.sh MODE [OPTIONS]
#
# Modes:
#   -f, --full          core + plugins + Astra + themes + core update-db +
#                       db optimize + db repair + due cron events
#   -c, --core          core update, core update-db
#   -p, --plugins       plugin update --all
#   -t, --themes        theme update --all
#   -d, --db-optimize   db optimize, db repair
#   -x, --db-fix        db repair
#   -r, --cron          cron event run --due-now
#   -s, --astra         update astra-addon, activating the license when needed
#   -l, --list-plugins  list plugins (table, or JSON with --json)
#   -m, --plugin-manage manage one plugin: --action activate|deactivate|delete
#
# Options:
#   -D, --debug            verbose diagnostics on stderr
#   -S, --site PATH        process only this installation
#   -U, --user USER        force the system user (default: auto-detected)
#       --wp-cli PATH      WP-CLI binary (default: PATH lookup, then
#                          /usr/local/bin/wp)
#       --sites-file FILE  site list (default: <script dir>/wp-found.txt)
#       --config FILE      config file (default: <script dir>/wp-cli-update.conf)
#   -A, --action ACTION    plugin action for --plugin-manage
#   -N, --name NAME        plugin name/slug (filter or target)
#   -F, --force            skip the interactive confirmation for delete
#   -J, --json             JSON output for --list-plugins and the summary
#   -n, --dry-run          print the WP-CLI commands, change nothing
#   -q, --quiet            suppress informational console output
#       --no-color         disable colored console output
#       --no-lock          do not take the run lock
#   -V, --version          print the version and exit
#   -h, --help             print this help and exit
#
# Exit status:
#   0  every planned operation succeeded
#   1  usage, configuration or environment error (nothing was executed)
#   2  the run finished but at least one operation failed
#   3  no site could be processed
#
# Output contract:
#   stdout  data only: plugin tables, --json documents, the final summary
#   stderr  logs, progress, warnings, errors
#
# Configuration file (default <script dir>/wp-cli-update.conf):
#   Shell variable assignments sourced before the defaults are finalised.
#   Recognised keys: WP_CLI_PATH, SITES_FILE, SKIP_PLUGINS, ASTRA_PLUGIN,
#   ASTRA_KEY, LOG_DIR, LOG_MAX_BYTES, LOG_KEEP, ERROR_OUTPUT_LINES, COLOR,
#   LOCK_ENABLED, AUTO_DISCOVER. Environment variables of the same names
#   override the file,
#   command-line options override both.
#   The file may hold the Astra license key: keep it root-readable only
#   (chmod 600) and out of version control.
#
# Requirements: Bash 4.2+, GNU coreutils, root, WP-CLI, su or runuser.
###############################################################################

set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true

###############################################################################
# Identity
###############################################################################

# $0 may carry Windows-style separators when launched from Git Bash / MSYS.
_self_ref="${0//\\//}"
readonly SCRIPT_NAME="${_self_ref##*/}"
unset _self_ref
readonly SCRIPT_VERSION="6.0.0"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
	printf 'ERROR: %s requires Bash 4.2 or newer (found %s)\n' \
		"${SCRIPT_NAME}" "${BASH_VERSION:-unknown}" >&2
	exit 1
fi

resolve_script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [[ -L "${src}" ]]; do
		dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir='.'
		src="$(readlink -- "${src}")" || { src="${dir}"; break; }
		[[ "${src}" == /* ]] || src="${dir}/${src}"
	done
	dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir='.'
	printf '%s' "${dir}"
}
readonly SCRIPT_DIR="$(resolve_script_dir)"

###############################################################################
# Defaults (overridable by config file, environment and command line)
###############################################################################

: "${WP_CLI_PATH:=}"
: "${SITES_FILE:=${SCRIPT_DIR}/wp-found.txt}"
: "${SKIP_PLUGINS:=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer}"
: "${ASTRA_PLUGIN:=astra-addon}"
: "${ASTRA_KEY:=}"
: "${LOG_DIR:=${SCRIPT_DIR}}"
: "${LOG_MAX_BYTES:=5242880}"
: "${LOG_KEEP:=5}"
: "${ERROR_OUTPUT_LINES:=20}"
: "${COLOR:=auto}"
: "${LOCK_ENABLED:=1}"
: "${AUTO_DISCOVER:=1}"          # run Find_WP_Senior.sh when the site list is missing

readonly CONF_FILE_DEFAULT="${SCRIPT_DIR}/wp-cli-update.conf"
readonly DISCOVER_SCRIPT="${SCRIPT_DIR}/Find_WP_Senior.sh"
readonly WP_CLI_FALLBACK='/usr/local/bin/wp'

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

readonly ACTION_ACTIVATE='activate'
readonly ACTION_DEACTIVATE='deactivate'
readonly ACTION_DELETE='delete'

readonly EXIT_OK=0
readonly EXIT_USAGE=1
readonly EXIT_ERRORS=2
readonly EXIT_NOTHING=3

###############################################################################
# Runtime state
###############################################################################

MODE=''
DEBUG_MODE=false
QUIET_MODE=false
JSON_OUTPUT=false
DRY_RUN=false
FORCE_MODE=false
COLOR_MODE='auto'
TARGET_SITE=''
TARGET_USER=''
PLUGIN_NAME=''
PLUGIN_ACTION=''
CONF_FILE="${CONF_FILE_DEFAULT}"

STATS_SITES=0
STATS_OK=0
STATS_FAILED=0

# Filled by wp_exec
WP_OUTPUT=''
WP_RC=0
WP_SKIPPED=false
PLUGIN_LIST_ERROR=''

# Filled by init_logging / take_lock
LOG_FILE=''
ERROR_LOG_FILE=''
LOCK_FILE=''
LOCK_TOKEN=''
LOG_READY=false

SITES=()
declare -A SEEN_SITES=()

# Colors, assigned by setup_colors
C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM='' C_BOLD=''

###############################################################################
# Small helpers
###############################################################################

trim() {
	local s="$1"
	s="${s//$'\r'/}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
}

json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\n'/\\n}"
	printf '%s' "${s}"
}

# Replace known secrets so they never reach a log line or the console.
redact() {
	local text="$1"
	if [[ -n "${ASTRA_KEY}" ]]; then
		text="${text//"${ASTRA_KEY}"/<redacted>}"
	fi
	printf '%s' "${text}"
}

###############################################################################
# Colors and logging
###############################################################################

setup_colors() {
	case "${COLOR_MODE}" in
		never) return 0 ;;
		always) : ;;
		*)
			[[ -t 2 ]] || return 0
			[[ "${TERM:-dumb}" != 'dumb' ]] || return 0
			[[ -z "${NO_COLOR:-}" ]] || return 0
			;;
	esac
	C_RESET=$'\033[0m'
	C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
	C_BLUE=$'\033[34m' C_CYAN=$'\033[36m' C_DIM=$'\033[2m' C_BOLD=$'\033[1m'
}

rotate_log() { # file
	local file="$1" size=0 i
	[[ -f "${file}" ]] || return 0
	size=$(wc -c < "${file}" 2>/dev/null | tr -d '[:space:]') || size=0
	size="${size:-0}"
	(( size > LOG_MAX_BYTES )) || return 0
	for ((i = LOG_KEEP - 1; i >= 1; i--)); do
		if [[ -f "${file}.${i}" ]]; then
			mv -f -- "${file}.${i}" "${file}.$((i + 1))" 2>/dev/null || true
		fi
	done
	mv -f -- "${file}" "${file}.1" 2>/dev/null || true
	return 0
}

init_logging() {
	local fallback="${TMPDIR:-/tmp}"
	fallback="${fallback//\\//}"
	if ! mkdir -p -- "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
		printf 'WARN: log directory %s is unusable, falling back to %s\n' \
			"${LOG_DIR}" "${fallback}" >&2
		LOG_DIR="${fallback}"
	fi
	LOG_FILE="${LOG_DIR}/wp_cli_manager.log"
	ERROR_LOG_FILE="${LOG_DIR}/wp_cli_errors.log"
	LOCK_FILE="${LOG_DIR}/wp-cli-update.lock"

	rotate_log "${LOG_FILE}"
	rotate_log "${ERROR_LOG_FILE}"
	: >> "${LOG_FILE}" 2>/dev/null || true
	: >> "${ERROR_LOG_FILE}" 2>/dev/null || true
	LOG_READY=true
}

_log_write() { # level, message
	local level="$1" msg="$2" line
	[[ "${LOG_READY}" == true ]] || return 0
	printf -v line '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "${level}" "$(redact "${msg}")"
	printf '%s' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
	return 0
}

log_debug() {
	if [[ "${DEBUG_MODE}" == true ]]; then
		[[ "${QUIET_MODE}" == true ]] || printf '%sDEBUG:%s %s\n' "${C_DIM}" "${C_RESET}" "$(redact "$*")" >&2
		_log_write DEBUG "$*"
	fi
	return 0
}

log_info() {
	[[ "${QUIET_MODE}" == true ]] || printf '%sINFO:%s %s\n' "${C_BLUE}" "${C_RESET}" "$(redact "$*")" >&2
	_log_write INFO "$*"
	return 0
}

log_success() {
	[[ "${QUIET_MODE}" == true ]] || printf '%s OK :%s %s\n' "${C_GREEN}" "${C_RESET}" "$(redact "$*")" >&2
	_log_write SUCCESS "$*"
	return 0
}

log_warning() {
	printf '%sWARN:%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(redact "$*")" >&2
	_log_write WARNING "$*"
	return 0
}

log_error() {
	printf '%sERR :%s %s\n' "${C_RED}" "${C_RESET}" "$(redact "$*")" >&2
	_log_write ERROR "$*"
	STATS_FAILED=$((STATS_FAILED + 1))
	return 0
}

log_error_detail() { # context, command, output, exit code
	local context="$1" cmd="$2" output="$3" rc="$4" ts
	[[ "${LOG_READY}" == true ]] || return 0
	printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
	{
		printf '[%s] [ERROR DETAIL]\n' "${ts}"
		printf 'Context: %s\n' "$(redact "${context}")"
		printf 'Command: %s\n' "$(redact "${cmd}")"
		printf 'Exit code: %s\n' "${rc}"
		printf 'Output:\n%s\n' "$(redact "${output}")"
		printf -- '---\n'
	} >> "${ERROR_LOG_FILE}" 2>/dev/null || true
	return 0
}

# Print the captured failing output on the console, capped and indented.
print_error_output() {
	local output="$1" total=0 shown=0 line
	[[ -n "${output}" ]] || return 0
	total=$(printf '%s\n' "${output}" | wc -l | tr -d '[:space:]') || total=0
	total="${total:-0}"
	printf '%s--- command output -------------------------------------------%s\n' "${C_RED}" "${C_RESET}" >&2
	while IFS= read -r line; do
		(( shown < ERROR_OUTPUT_LINES )) || break
		printf '%s| %s%s\n' "${C_RED}" "${line}" "${C_RESET}" >&2
		shown=$((shown + 1))
	done <<< "${output}"
	if (( total > ERROR_OUTPUT_LINES )); then
		printf '%s| ... %d more line(s); full output in %s%s\n' \
			"${C_RED}" "$((total - ERROR_OUTPUT_LINES))" "${ERROR_LOG_FILE}" "${C_RESET}" >&2
	fi
	printf '%s--------------------------------------------------------------%s\n' "${C_RED}" "${C_RESET}" >&2
	return 0
}

progress() { # counter, message
	[[ "${QUIET_MODE}" == true || "${JSON_OUTPUT}" == true ]] && return 0
	[[ -t 2 ]] || return 0
	printf '\r%s[%s]%s %s' "${C_DIM}" "$1" "${C_RESET}" "$2" >&2
	return 0
}

progress_done() {
	[[ "${QUIET_MODE}" == true || "${JSON_OUTPUT}" == true ]] && return 0
	[[ -t 2 ]] || return 0
	printf '\r\033[K' >&2
	return 0
}

###############################################################################
# Lock against parallel runs
###############################################################################

take_lock() {
	[[ "${LOCK_ENABLED}" == 1 ]] || return 0
	if command -v flock >/dev/null 2>&1; then
		exec 9>"${LOCK_FILE}" || { log_error "cannot open the lock file ${LOCK_FILE}"; return 1; }
		if ! flock -n 9; then
			log_error "another run holds the lock ${LOCK_FILE}; use --no-lock to override"
			return 1
		fi
		LOCK_TOKEN='flock'
		return 0
	fi
	# Portable fallback: an atomically created directory.
	if mkdir -- "${LOCK_FILE}.d" 2>/dev/null; then
		LOCK_TOKEN='mkdir'
		printf '%s\n' "$$" > "${LOCK_FILE}.d/pid" 2>/dev/null || true
		return 0
	fi
	log_error "another run holds the lock ${LOCK_FILE}.d; use --no-lock to override"
	return 1
}

release_lock() {
	case "${LOCK_TOKEN:-}" in
		mkdir) rm -rf -- "${LOCK_FILE}.d" 2>/dev/null || true ;;
	esac
	LOCK_TOKEN=''
	return 0
}

###############################################################################
# Usage
###############################################################################

usage() {
	cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: ${SCRIPT_NAME} MODE [OPTIONS]

Modes:
  -f, --full           Full update: core, plugins, Astra, themes, core update-db,
                       database optimize/repair, due cron events
  -c, --core           Update WordPress core only
  -p, --plugins        Update all plugins
  -t, --themes         Update all themes
  -d, --db-optimize    Optimize and repair the database
  -x, --db-fix         Repair the database only
  -r, --cron           Run due cron events
  -s, --astra          Update Astra with license activation when required
  -l, --list-plugins   List plugins (table, or JSON with --json)
  -m, --plugin-manage  Manage one plugin (see --action and --name)

Options:
  -D, --debug            Verbose diagnostics on stderr
  -S, --site PATH        Process one installation only
  -U, --user USER        Force the system user instead of auto-detection
      --wp-cli PATH      WP-CLI binary (default: PATH lookup, then /usr/local/bin/wp)
      --sites-file FILE  Site list (default: ${SITES_FILE})
      --config FILE      Config file (default: ${CONF_FILE_DEFAULT})
  -A, --action ACTION    Plugin action: activate|deactivate|delete
  -N, --name NAME        Plugin name, slug or a distinguishing fragment
  -F, --force            Skip the interactive delete confirmation
  -J, --json             JSON output for --list-plugins and the summary
  -n, --dry-run          Show the WP-CLI commands without executing them
  -q, --quiet            Suppress informational console output
      --no-color         Disable colored console output
      --no-lock          Do not take the run lock
  -V, --version          Print the version and exit
  -h, --help             Print this help and exit

Notes:
  Root is required for real runs; --dry-run only previews the commands.
  A missing site list triggers Find_WP_Senior.sh unless AUTO_DISCOVER=0.
  Logs: ${LOG_DIR}/wp_cli_manager.log and wp_cli_errors.log (rotated).

Examples:
  ${SCRIPT_NAME} --full --debug
  ${SCRIPT_NAME} -p -S /var/www/example.com
  ${SCRIPT_NAME} --list-plugins -N woocommerce --json
  ${SCRIPT_NAME} -m -A deactivate -N jetpack -S /var/www/example.com
  ${SCRIPT_NAME} -m -A delete -N old-plugin -S /var/www/example.com --force
EOF
}

usage_error() {
	printf '%sERR :%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
	printf 'Run %s --help for the full description.\n' "${SCRIPT_NAME}" >&2
	exit "${EXIT_USAGE}"
}

###############################################################################
# Configuration
###############################################################################

load_config_file() {
	local file="$1"
	[[ -n "${file}" ]] || return 0
	if [[ ! -f "${file}" ]]; then
		if [[ "${file}" != "${CONF_FILE_DEFAULT}" ]]; then
			log_error "config file not found: ${file}"
			exit "${EXIT_USAGE}"
		fi
		log_debug "no config file at ${file}, using defaults"
		return 0
	fi
	# The config file is trusted local configuration (like /etc/sysconfig/*),
	# therefore it is sourced and may set any of the documented variables.
	# shellcheck source=/dev/null
	source "${file}"
	log_debug "config file loaded: ${file}"
	return 0
}

apply_environment() {
	# Values exported by the caller or set in the config file win over the
	# defaults assigned with := at the top of the script.
	WP_CLI_PATH="${WP_CLI_PATH:-}"
	SITES_FILE="${SITES_FILE:-${SCRIPT_DIR}/wp-found.txt}"
	ASTRA_PLUGIN="${ASTRA_PLUGIN:-astra-addon}"
	LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
	LOG_KEEP="${LOG_KEEP:-5}"
	ERROR_OUTPUT_LINES="${ERROR_OUTPUT_LINES:-20}"
	COLOR_MODE="${COLOR_MODE:-${COLOR:-auto}}"
	case "${LOCK_ENABLED}" in
		1|true|yes) LOCK_ENABLED=1 ;;
		*)          LOCK_ENABLED=0 ;;
	esac
	case "${AUTO_DISCOVER}" in
		1|true|yes) AUTO_DISCOVER=1 ;;
		*)          AUTO_DISCOVER=0 ;;
	esac
	return 0
}

resolve_wp_cli() {
	if [[ -n "${WP_CLI_PATH}" ]]; then
		if [[ ! -x "${WP_CLI_PATH}" ]]; then
			log_error "WP-CLI is not executable: ${WP_CLI_PATH}"
			exit "${EXIT_USAGE}"
		fi
		return 0
	fi
	if command -v wp >/dev/null 2>&1; then
		WP_CLI_PATH="$(command -v wp)"
		return 0
	fi
	if [[ -x "${WP_CLI_FALLBACK}" ]]; then
		WP_CLI_PATH="${WP_CLI_FALLBACK}"
		return 0
	fi
	if [[ "${DRY_RUN}" == true ]]; then
		WP_CLI_PATH='wp'
		log_warning 'WP-CLI not found; --dry-run continues with the placeholder "wp"'
		return 0
	fi
	log_error "WP-CLI not found (checked PATH and ${WP_CLI_FALLBACK}); install it or pass --wp-cli"
	exit "${EXIT_USAGE}"
}

###############################################################################
# Argument parsing
###############################################################################

need_value() { # option, value
	if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
		usage_error "option $1 requires a value"
	fi
	return 0
}

# Locate --config before the parser runs, so the config file is sourced
# before the defaults are finalised.
extract_conf_file() {
	local prev='' arg
	for arg in "$@"; do
		if [[ "${prev}" == '--config' ]]; then
			CONF_FILE="${arg}"
		fi
		case "${arg}" in
			--config=*) CONF_FILE="${arg#*=}" ;;
		esac
		prev="${arg}"
	done
	return 0
}

set_mode() {
	if [[ -n "${MODE}" && "${MODE}" != "$1" ]]; then
		usage_error "conflicting modes: '${MODE}' and '$1'"
	fi
	MODE="$1"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-D|--debug)          DEBUG_MODE=true; shift ;;
			-f|--full)           set_mode "${MODE_FULL}"; shift ;;
			-c|--core)           set_mode "${MODE_CORE}"; shift ;;
			-p|--plugins)        set_mode "${MODE_PLUGINS}"; shift ;;
			-t|--themes)         set_mode "${MODE_THEMES}"; shift ;;
			-d|--db-optimize)    set_mode "${MODE_DB_OPTIMIZE}"; shift ;;
			-x|--db-fix)         set_mode "${MODE_DB_FIX}"; shift ;;
			-r|--cron)           set_mode "${MODE_CRON}"; shift ;;
			-s|--astra)          set_mode "${MODE_ASTRA}"; shift ;;
			-l|--list-plugins)   set_mode "${MODE_LIST_PLUGINS}"; shift ;;
			-m|--plugin-manage)  set_mode "${MODE_PLUGIN_MANAGE}"; shift ;;
			-S|--site)
				need_value "$1" "${2:-}"; TARGET_SITE="$2"; shift 2 ;;
			--site=*)
				TARGET_SITE="${1#*=}"; [[ -n "${TARGET_SITE}" ]] || usage_error '--site requires a value'; shift ;;
			-U|--user)
				need_value "$1" "${2:-}"; TARGET_USER="$2"; shift 2 ;;
			--user=*)
				TARGET_USER="${1#*=}"; shift ;;
			--wp-cli)
				need_value "$1" "${2:-}"; WP_CLI_PATH="$2"; shift 2 ;;
			--wp-cli=*)
				WP_CLI_PATH="${1#*=}"; shift ;;
			--sites-file)
				need_value "$1" "${2:-}"; SITES_FILE="$2"; shift 2 ;;
			--sites-file=*)
				SITES_FILE="${1#*=}"; shift ;;
			--config)
				need_value "$1" "${2:-}"; CONF_FILE="$2"; shift 2 ;;
			--config=*)
				CONF_FILE="${1#*=}"; shift ;;
			-A|--action)
				need_value "$1" "${2:-}"; PLUGIN_ACTION="$2"; shift 2 ;;
			--action=*)
				PLUGIN_ACTION="${1#*=}"; shift ;;
			-N|--name)
				need_value "$1" "${2:-}"; PLUGIN_NAME="$2"; shift 2 ;;
			--name=*)
				PLUGIN_NAME="${1#*=}"; shift ;;
			-F|--force)          FORCE_MODE=true; shift ;;
			-J|--json)           JSON_OUTPUT=true; QUIET_MODE=true; shift ;;
			-n|--dry-run)        DRY_RUN=true; shift ;;
			-q|--quiet)          QUIET_MODE=true; shift ;;
			--no-color)          COLOR_MODE=never; shift ;;
			--color)             COLOR_MODE=always; shift ;;
			--no-lock)           LOCK_ENABLED=0; shift ;;
			-V|--version)        printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit "${EXIT_OK}" ;;
			-h|--help)           usage; exit "${EXIT_OK}" ;;
			--)
				shift
				if [[ $# -gt 0 ]]; then
					usage_error "unexpected positional argument: $1"
				fi
				;;
			*)
				usage_error "unknown argument: $1"
				;;
		esac
	done
	return 0
}

validate_options() {
	[[ -n "${MODE}" ]] || usage_error 'no mode specified'

	if [[ -n "${PLUGIN_ACTION}" && "${MODE}" != "${MODE_PLUGIN_MANAGE}" ]]; then
		usage_error "--action is only valid with --plugin-manage (mode: ${MODE})"
	fi
	if [[ -n "${PLUGIN_NAME}" && "${MODE}" != "${MODE_PLUGIN_MANAGE}" && "${MODE}" != "${MODE_LIST_PLUGINS}" ]]; then
		usage_error "--name is only valid with --list-plugins or --plugin-manage (mode: ${MODE})"
	fi

	case "${MODE}" in
		"${MODE_PLUGIN_MANAGE}")
			[[ -n "${PLUGIN_ACTION}" ]] || usage_error '--plugin-manage requires --action'
			[[ -n "${PLUGIN_NAME}" ]] || usage_error '--plugin-manage requires --name'
			case "${PLUGIN_ACTION}" in
				"${ACTION_ACTIVATE}"|"${ACTION_DEACTIVATE}"|"${ACTION_DELETE}") ;;
				*) usage_error "invalid --action '${PLUGIN_ACTION}' (activate|deactivate|delete)" ;;
			esac
			;;
		"${MODE_ASTRA}")
			if [[ -z "${ASTRA_KEY}" ]]; then
				usage_error "mode 'astra' requires ASTRA_KEY (config file or environment)"
			fi
			;;
	esac

	if [[ -n "${TARGET_SITE}" && ! -d "${TARGET_SITE}" ]]; then
		usage_error "--site directory does not exist: ${TARGET_SITE}"
	fi
	if [[ ! "${LOG_MAX_BYTES}" =~ ^[0-9]+$ ]]; then
		usage_error 'LOG_MAX_BYTES must be a number'
	fi
	if [[ ! "${LOG_KEEP}" =~ ^[0-9]+$ ]] || (( LOG_KEEP < 1 )); then
		usage_error 'LOG_KEEP must be a positive integer'
	fi
	if [[ ! "${ERROR_OUTPUT_LINES}" =~ ^[0-9]+$ ]]; then
		usage_error 'ERROR_OUTPUT_LINES must be a number'
	fi
	return 0
}

###############################################################################
# User resolution
###############################################################################

get_wp_user() { # site -> prints the user name
	local wp_root="$1" wp_config="${1}/wp-config.php"
	local candidate first rel

	# 1. Owner of wp-config.php
	if [[ -f "${wp_config}" ]]; then
		candidate="$(stat -c '%U' -- "${wp_config}" 2>/dev/null || true)"
		log_debug "owner of wp-config.php: '${candidate:-none}'"
		if [[ -n "${candidate}" && "${candidate}" != 'root' && "${candidate}" != 'UNKNOWN' ]] \
		   && id -u -- "${candidate}" >/dev/null 2>&1; then
			printf '%s' "${candidate}"
			return 0
		fi
	fi

	# 2. Owner of the installation directory
	candidate="$(stat -c '%U' -- "${wp_root}" 2>/dev/null || true)"
	log_debug "owner of the site directory: '${candidate:-none}'"
	if [[ -n "${candidate}" && "${candidate}" != 'root' && "${candidate}" != 'UNKNOWN' ]] \
	   && id -u -- "${candidate}" >/dev/null 2>&1; then
		printf '%s' "${candidate}"
		return 0
	fi

	# 3. Layouts such as /home/<user>/... or /var/www/<user>/...
	rel="${wp_root#/}"
	first="${rel%%/*}"
	if [[ "${first}" == 'home' ]]; then
		rel="${rel#home/}"
		first="${rel%%/*}"
	fi
	if [[ -n "${first}" && "${first}" != 'www' ]] && id -u -- "${first}" >/dev/null 2>&1; then
		log_debug "user inferred from the path: ${first}"
		printf '%s' "${first}"
		return 0
	fi

	# 4. DB_USER from wp-config.php
	if [[ -f "${wp_config}" ]]; then
		local db_user
		db_user=$(sed -nE "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*'DB_USER'[[:space:]]*,[[:space:]]*'([^']+)'.*/\\1/p" \
			"${wp_config}" 2>/dev/null | tail -n1)
		log_debug "DB_USER from wp-config.php: '${db_user:-none}'"
		if [[ -n "${db_user}" ]] && id -u -- "${db_user}" >/dev/null 2>&1; then
			printf '%s' "${db_user}"
			return 0
		fi
	fi

	log_debug "all user detection methods failed for ${wp_root}"
	return 1
}

resolve_site_user() { # site -> prints the user name
	local site="$1" user
	if [[ -n "${TARGET_USER}" ]]; then
		if ! id -u -- "${TARGET_USER}" >/dev/null 2>&1; then
			log_error "user '${TARGET_USER}' does not exist"
			return 1
		fi
		printf '%s' "${TARGET_USER}"
		return 0
	fi
	if user="$(get_wp_user "${site}")"; then
		printf '%s' "${user}"
		return 0
	fi
	return 1
}

###############################################################################
# WP-CLI execution
###############################################################################

# Run a program as the site user with the site directory as working directory.
# All values are passed positionally: no shell command is assembled from data.
run_as_user() { # workdir, user, program, args...
	local workdir="$1" user="$2"
	shift 2
	local runner='cd -- "$1" && shift && exec "$@"'

	if [[ "${user}" == "$(id -un)" ]]; then
		sh -c "${runner}" sh "${workdir}" "$@"
		return $?
	fi
	if command -v runuser >/dev/null 2>&1; then
		runuser -u "${user}" -- sh -c "${runner}" sh "${workdir}" "$@"
		return $?
	fi
	# su passes everything after the user name to the shell as positional
	# parameters, so the command never needs quoting.
	su -s /bin/sh -c "${runner}" "${user}" sh "${workdir}" "$@"
	return $?
}

# Execute WP-CLI and store stdout+stderr in WP_OUTPUT, the status in WP_RC.
# Returns 0 for the caller: the status is reported through the variables.
wp_exec() { # site, user, args...
	local site="$1" user="$2"
	shift 2
	local parent2 domain home
	parent2="$(dirname -- "$(dirname -- "${site}")")"
	domain="$(basename -- "${site}")"

	# WP-CLI keeps its configuration in HOME, so pass the target user's home
	# directory instead of root's.
	home=''
	if command -v getent >/dev/null 2>&1; then
		home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
	fi
	if [[ -z "${home}" || ! -d "${home}" ]]; then
		home="${parent2}"
	fi

	local -a argv=( env
		"DOCUMENT_URI=${domain}"
		"DOCUMENT_ROOT=${site}"
		"HOMEDIR=${parent2}"
		"HTTP_HOST=${domain}"
		"HOME=${home}"
		"USER=${user}"
		"LOGNAME=${user}"
		"PATH=${PATH}"
		"${WP_CLI_PATH}" "--path=${site}" '--allow-root' )

	if [[ -n "${SKIP_PLUGINS}" ]]; then
		argv+=( "--skip-plugins=${SKIP_PLUGINS}" )
	fi
	argv+=( "$@" )

	WP_OUTPUT=''
	WP_RC=0
	WP_SKIPPED=false

	if [[ "${DRY_RUN}" == true ]]; then
		printf 'DRY-RUN: su %s -> %s\n' "${user}" "$(redact "$(printf '%q ' "${argv[@]}")")" >&2
		WP_SKIPPED=true
		return 0
	fi

	WP_OUTPUT="$(run_as_user "${site}" "${user}" "${argv[@]}" 2>&1)" || WP_RC=$?
	return 0
}

# Execute one maintenance command: log the outcome and feed the failure counter.
run_wp_cli() { # site, user, args...
	local site="$1" user="$2"
	shift 2
	wp_exec "${site}" "${user}" "$@"

	if [[ "${WP_SKIPPED}" == true ]]; then
		return 0
	fi
	if (( WP_RC == 0 )); then
		STATS_OK=$((STATS_OK + 1))
		log_debug "ok: wp $* (site ${site})"
		if [[ -n "${WP_OUTPUT}" && "${JSON_OUTPUT}" != true && "${QUIET_MODE}" != true ]]; then
			printf '%s\n' "${WP_OUTPUT}"
		fi
		return 0
	fi

	log_error "wp $* failed (site ${site}, exit ${WP_RC})"
	log_error_detail 'run_wp_cli' "wp --path=${site} $*" "${WP_OUTPUT}" "${WP_RC}"
	print_error_output "${WP_OUTPUT}"
	return 1
}

###############################################################################
# Plugin helpers (no jq required)
###############################################################################

# wp-cli emits RFC4180 CSV; this parser keeps quoted commas and titles intact
# and prints TAB-separated rows: slug, status, version, update, title.
readonly AWK_CSV_ROWS='
function split_csv(line, f,    i, c, inq, n) {
	delete f
	n = 1; f[1] = ""; inq = 0
	for (i = 1; i <= length(line); i++) {
		c = substr(line, i, 1)
		if (inq) {
			if (c == "\"") {
				if (substr(line, i + 1, 1) == "\"") { f[n] = f[n] "\""; i++ } else { inq = 0 }
			} else { f[n] = f[n] c }
		} else {
			if (c == "\"") { inq = 1 }
			else if (c == ",") { n++; f[n] = "" }
			else { f[n] = f[n] c }
		}
	}
	return n
}
NR == 1 { next }
{
	split_csv($0, F)
	name = F[1]; title = F[2]; status = F[3]; version = F[4]; update = F[5]
	if (filter != "" && index(tolower(name), tolower(filter)) == 0 \
		&& index(tolower(title), tolower(filter)) == 0) { next }
	printf "%s\t%s\t%s\t%s\t%s\n", name, status, version, update, title
}'

# Print plugin rows for a site; on failure PLUGIN_LIST_ERROR holds the output.
list_plugins_rows() { # site, user, filter
	local site="$1" user="$2" filter="${3:-}"
	PLUGIN_LIST_ERROR=''
	wp_exec "${site}" "${user}" plugin list --format=csv --fields=name,title,status,version,update
	if (( WP_RC != 0 )); then
		PLUGIN_LIST_ERROR="${WP_OUTPUT}"
		return 1
	fi
	[[ -n "${WP_OUTPUT}" ]] || return 0
	printf '%s\n' "${WP_OUTPUT}" | awk -v filter="${filter}" "${AWK_CSV_ROWS}"
	return 0
}

# Print the wp-cli JSON array (filtered with jq when available and requested).
list_plugins_json() { # site, user, filter
	local site="$1" user="$2" filter="${3:-}"
	PLUGIN_LIST_ERROR=''
	wp_exec "${site}" "${user}" plugin list --format=json --fields=name,title,status,version,update
	if (( WP_RC != 0 )); then
		PLUGIN_LIST_ERROR="${WP_OUTPUT}"
		return 1
	fi
	local json="${WP_OUTPUT:-[]}"
	[[ "${json:0:1}" == '[' ]] || json='[]'
	if [[ -n "${filter}" ]]; then
		if command -v jq >/dev/null 2>&1; then
			json="$(printf '%s' "${json}" | jq -c --arg f "${filter}" \
				'[ .[] | select((.name | ascii_downcase | contains($f | ascii_downcase)) or ((.title // "") | ascii_downcase | contains($f | ascii_downcase))) ]' 2>/dev/null)" || json='[]'
		else
			log_error '--json with --name needs jq; install jq or drop --name'
			return 1
		fi
	fi
	printf '%s' "${json}"
	return 0
}

show_plugin_table() { # site, user, filter
	local site="$1" user="$2" filter="${3:-}"
	local rows count=0 name status version update title color symbol upd upd_color sep

	if ! rows="$(list_plugins_rows "${site}" "${user}" "${filter}")"; then
		log_error "cannot list plugins for ${site}"
		print_error_output "${PLUGIN_LIST_ERROR}"
		return 1
	fi

	sep="$(printf '%.0s-' {1..110})"
	printf '\n%sPlugins on %s%s\n' "${C_BOLD}${C_CYAN}" "${site}" "${C_RESET}"
	printf '%-42s %-12s %-12s %-9s %s\n' 'PLUGIN' 'STATUS' 'VERSION' 'UPDATE' 'TITLE'
	printf '%s%s%s\n' "${C_DIM}" "${sep}" "${C_RESET}"

	while IFS=$'\t' read -r name status version update title; do
		[[ -n "${name}" ]] || continue
		count=$((count + 1))
		color="${C_YELLOW}"; symbol='o'
		case "${status}" in
			active)   color="${C_GREEN}";  symbol='+' ;;
			inactive) color="${C_YELLOW}"; symbol='-' ;;
			dropin)   color="${C_CYAN}";   symbol='~' ;;
			*)        color="${C_RED}";    symbol='!' ;;
		esac
		upd='-'; upd_color="${C_GREEN}"
		if [[ "${update}" == 'available' ]]; then
			upd='UPDATE'; upd_color="${C_RED}"
		fi
		printf '%-42s %s%-12s%s %-12s %s%-9s%s %s\n' \
			"${name:0:42}" "${color}" "${symbol} ${status}" "${C_RESET}" \
			"${version:0:12}" "${upd_color}" "${upd}" "${C_RESET}" "${title:0:40}"
	done <<< "${rows}"

	printf '%s%s%s\n' "${C_DIM}" "${sep}" "${C_RESET}"
	printf 'Total: %d plugin(s)\n' "${count}"
	return 0
}

###############################################################################
# Plugin management
###############################################################################

# Resolve a user-supplied value to exactly one plugin slug.
match_plugin_slug() { # site, user, needle -> prints the slug
	local site="$1" user="$2" needle="${3:-}"
	local rows matches count

	if ! rows="$(list_plugins_rows "${site}" "${user}" '')"; then
		log_error "cannot retrieve the plugin list for ${site}"
		print_error_output "${PLUGIN_LIST_ERROR}"
		return 1
	fi

	# Priority: exact slug, exact title, then substring matches.
	matches="$(printf '%s\n' "${rows}" | awk -F'\t' -v needle="${needle}" '
		BEGIN { n = tolower(needle) }
		{
			slug = tolower($1); title = tolower($5)
			if (slug == n || title == n) { exact[++e] = $1; next }
			if (index(slug, n) > 0 || index(title, n) > 0) { loose[++l] = $1 }
		}
		END {
			if (e > 0)      { for (i = 1; i <= e; i++) print exact[i] }
			else if (l > 0) { for (i = 1; i <= l; i++) print loose[i] }
		}')"

	if [[ -z "${rows}" && "${DRY_RUN}" == true ]]; then
		# Nothing is executed in dry-run, so no list can be matched against;
		# preview the planned commands with the requested name as the slug.
		log_debug "dry-run: using '${needle}' as the plugin slug"
		printf '%s' "${needle}"
		return 0
	fi

	if [[ -z "${matches}" ]]; then
		log_error "no plugin matches '${needle}' on ${site}"
		log_info 'the first available slugs:'
		printf '%s\n' "${rows}" | awk -F'\t' 'NR <= 10 { printf "  %s\n", $1 }' >&2
		return 1
	fi

	count=$(printf '%s\n' "${matches}" | grep -c . || true)
	count="${count:-0}"
	if (( count > 1 )); then
		log_error "'${needle}' matches ${count} plugins on ${site}; use the exact slug:"
		printf '%s\n' "${matches}" | sed 's/^/  /' >&2
		return 1
	fi

	printf '%s' "${matches}"
	return 0
}

confirm_delete() { # site, slug, status
	local site="$1" slug="$2" status="$3" answer

	if [[ "${FORCE_MODE}" == true ]]; then
		return 0
	fi
	if [[ ! -t 0 ]]; then
		log_error 'refusing to delete without a terminal; pass --force to confirm non-interactively'
		return 1
	fi

	printf '\n%s DESTRUCTIVE ACTION %s\n' "${C_BOLD}${C_RED}" "${C_RESET}" >&2
	printf '  site   : %s\n' "${site}" >&2
	printf '  plugin : %s (status: %s)\n' "${slug}" "${status}" >&2
	printf '  the plugin files and its data will be removed permanently\n' >&2
	printf 'Type the plugin slug "%s" to confirm: ' "${slug}" >&2
	read -r answer || answer=''
	if [[ "${answer}" != "${slug}" ]]; then
		log_info 'deletion cancelled'
		return 1
	fi
	return 0
}

manage_plugin() { # site, user
	local site="$1" user="$2" slug status rows is_active=false

	if ! slug="$(match_plugin_slug "${site}" "${user}" "${PLUGIN_NAME}")"; then
		return 1
	fi

	rows="$(list_plugins_rows "${site}" "${user}" "${slug}")" || true
	status="$(printf '%s\n' "${rows}" | awk -F'\t' -v s="${slug}" '$1 == s { print $2; exit }')"
	if [[ "${status}" =~ ^[Aa][Cc][Tt][Ii][Vv][Ee]$ ]]; then
		is_active=true
	fi
	log_debug "resolved '${slug}' (status: ${status:-unknown}) on ${site}"

	case "${PLUGIN_ACTION}" in
		"${ACTION_ACTIVATE}")
			if [[ "${is_active}" == true ]]; then
				log_info "plugin '${slug}' is already active on ${site}"
				return 0
			fi
			run_wp_cli "${site}" "${user}" plugin activate "${slug}" || return 1
			;;
		"${ACTION_DEACTIVATE}")
			if [[ "${is_active}" == false ]]; then
				log_info "plugin '${slug}' is already inactive on ${site}"
				return 0
			fi
			run_wp_cli "${site}" "${user}" plugin deactivate "${slug}" || return 1
			;;
		"${ACTION_DELETE}")
			confirm_delete "${site}" "${slug}" "${status:-unknown}" || return 1
			if [[ "${is_active}" == true ]]; then
				log_info "deactivating '${slug}' before deletion"
				run_wp_cli "${site}" "${user}" plugin deactivate "${slug}" || true
			fi
			run_wp_cli "${site}" "${user}" plugin delete "${slug}" || return 1
			;;
	esac

	log_success "${PLUGIN_ACTION} '${slug}' on ${site}"
	return 0
}

###############################################################################
# Astra handling
###############################################################################

astra_field() { # site, user, field -> prints the value
	wp_exec "$1" "$2" plugin list --name="${ASTRA_PLUGIN}" --field="$3"
	(( WP_RC == 0 )) || return 1
	local value
	value="$(trim "${WP_OUTPUT}")"
	if [[ -z "${value}" && "${WP_SKIPPED}" == true ]]; then
		# Dry-run: assume a healthy state so the planned license/update steps
		# are visible in the preview.
		case "$3" in
			status) value='active' ;;
			update) value='available' ;;
		esac
	fi
	printf '%s' "${value}"
	return 0
}

# Update the Astra plugin, activating the license when an update is pending.
# "quiet" only changes how a missing plugin is reported (full mode).
handle_astra() { # site, user, [quiet]
	local site="$1" user="$2" quiet="${3:-}"
	local status update

	if ! status="$(astra_field "${site}" "${user}" status)"; then
		log_warning "cannot read the ${ASTRA_PLUGIN} status on ${site}"
		return 0
	fi
	if [[ -z "${status}" ]]; then
		log_info "${ASTRA_PLUGIN} is not installed on ${site}"
		return 0
	fi
	if [[ "${status}" != 'active' ]]; then
		log_warning "${ASTRA_PLUGIN} is not active on ${site} (status: ${status})"
		return 0
	fi

	if ! update="$(astra_field "${site}" "${user}" update)"; then
		log_warning "cannot read the ${ASTRA_PLUGIN} update state on ${site}"
		return 0
	fi
	if [[ "${update}" != 'available' ]]; then
		log_info "no ${ASTRA_PLUGIN} update available on ${site}"
		return 0
	fi

	if [[ -n "${ASTRA_KEY}" ]]; then
		log_info "activating the ${ASTRA_PLUGIN} license on ${site}"
		run_wp_cli "${site}" "${user}" brainstormforce license activate "${ASTRA_PLUGIN}" "${ASTRA_KEY}" || true
	else
		log_warning "ASTRA_KEY is not set; a license-protected download may fail on ${site}"
	fi

	if run_wp_cli "${site}" "${user}" plugin update "${ASTRA_PLUGIN}"; then
		log_success "${ASTRA_PLUGIN} updated on ${site}"
		return 0
	fi
	log_error "${ASTRA_PLUGIN} update failed on ${site}"
	return 1
}

###############################################################################
# Site list
###############################################################################

load_sites() {
	local line site

	if [[ -n "${TARGET_SITE}" ]]; then
		SITES=( "${TARGET_SITE}" )
		return 0
	fi

	if [[ ! -f "${SITES_FILE}" ]]; then
		ensure_sites_file
	fi
	if [[ ! -f "${SITES_FILE}" ]]; then
		log_error "site list not found: ${SITES_FILE}"
		exit "${EXIT_NOTHING}"
	fi

	local -a raw=()
	mapfile -t raw < "${SITES_FILE}" || true
	for line in "${raw[@]:-}"; do
		site="$(trim "${line}")"
		[[ -n "${site}" ]] || continue
		[[ "${site}" == \#* ]] && continue
		if [[ -n "${SEEN_SITES[${site}]:-}" ]]; then
			log_debug "duplicate entry ignored: ${site}"
			continue
		fi
		SEEN_SITES["${site}"]=1
		SITES+=( "${site}" )
	done

	if (( ${#SITES[@]} == 0 )); then
		log_warning "no usable entries in ${SITES_FILE}"
		exit "${EXIT_NOTHING}"
	fi
	log_debug "${#SITES[@]} site(s) queued"
	return 0
}

ensure_sites_file() {
	# Auto-discovery walks the whole web root, which is undesirable in cron
	# jobs; set AUTO_DISCOVER=0 to require an explicit site list.
	if [[ "${AUTO_DISCOVER}" != 1 ]]; then
		log_warning 'site list is missing and auto-discovery is disabled (AUTO_DISCOVER=0)'
		return 0
	fi
	if [[ -x "${DISCOVER_SCRIPT}" ]]; then
		log_warning "site list missing; running ${DISCOVER_SCRIPT}"
		if ! "${DISCOVER_SCRIPT}"; then
			log_warning 'the discovery script exited with an error'
		fi
	elif [[ -e "${DISCOVER_SCRIPT}" ]]; then
		log_warning "${DISCOVER_SCRIPT} is not executable; run: chmod +x '${DISCOVER_SCRIPT}'"
	else
		log_warning "discovery script not found: ${DISCOVER_SCRIPT}"
	fi

	if [[ -f "${SITES_FILE}" ]]; then
		return 0
	fi
	if [[ ! -t 0 ]]; then
		log_error "no site list and no terminal for manual input; create ${SITES_FILE}"
		exit "${EXIT_NOTHING}"
	fi

	local answer
	printf 'Enter the absolute path of a WordPress installation: ' >&2
	read -r answer || answer=''
	answer="$(trim "${answer}")"
	if [[ -z "${answer}" ]]; then
		log_error 'no path provided'
		exit "${EXIT_NOTHING}"
	fi
	if [[ ! -d "${answer}" ]]; then
		log_error "not a directory: ${answer}"
		exit "${EXIT_NOTHING}"
	fi
	if [[ ! -f "${answer}/wp-config.php" ]]; then
		log_warning "${answer} has no wp-config.php; continuing anyway"
	fi
	printf '%s\n' "${answer}" > "${SITES_FILE}"
	log_success "path saved to ${SITES_FILE}"
	return 0
}

###############################################################################
# Modes
###############################################################################

# Dispatch the operations of one mode for one site. Returns 0 when every
# planned operation succeeded, 1 otherwise (failures are counted, not fatal).
execute_mode() { # mode, site, user
	local mode="$1" site="$2" user="$3"
	local failures=0 plugins

	run_op() {
		run_wp_cli "${site}" "${user}" "$@" || failures=$((failures + 1))
		return 0
	}

	log_debug "mode '${mode}' for ${site} as ${user}"

	case "${mode}" in
		"${MODE_FULL}")
			run_op core update
			run_op plugin update --all
			if [[ -n "${ASTRA_KEY}" ]]; then
				handle_astra "${site}" "${user}" quiet || failures=$((failures + 1))
			else
				log_debug 'ASTRA_KEY is empty, Astra is skipped in full mode'
			fi
			run_op theme update --all
			run_op core update-db
			run_op db optimize
			run_op db repair
			run_op cron event run --due-now
			;;
		"${MODE_CORE}")
			run_op core update
			run_op core update-db
			;;
		"${MODE_PLUGINS}")
			run_op plugin update --all
			;;
		"${MODE_THEMES}")
			run_op theme update --all
			;;
		"${MODE_DB_OPTIMIZE}")
			run_op db optimize
			run_op db repair
			;;
		"${MODE_DB_FIX}")
			run_op db repair
			;;
		"${MODE_CRON}")
			run_op cron event run --due-now
			;;
		"${MODE_ASTRA}")
			handle_astra "${site}" "${user}" || failures=$((failures + 1))
			;;
		"${MODE_LIST_PLUGINS}")
			if [[ "${JSON_OUTPUT}" == true ]]; then
				if plugins="$(list_plugins_json "${site}" "${user}" "${PLUGIN_NAME}")"; then
					printf '{"site": "%s", "plugins": %s}\n' "$(json_escape "${site}")" "${plugins}"
				else
					failures=$((failures + 1))
				fi
			else
				show_plugin_table "${site}" "${user}" "${PLUGIN_NAME}" || failures=$((failures + 1))
			fi
			;;
		"${MODE_PLUGIN_MANAGE}")
			manage_plugin "${site}" "${user}" || failures=$((failures + 1))
			;;
		*)
			log_error "unknown mode: ${mode}"
			return 1
			;;
	esac

	(( failures == 0 ))
}

process_site() { # site
	local site="$1" user

	if [[ ! -d "${site}" ]]; then
		log_warning "skipping, not a directory: ${site}"
		return 1
	fi
	if [[ ! -f "${site}/wp-config.php" ]]; then
		log_debug "no wp-config.php in ${site}; trying anyway"
	fi

	STATS_SITES=$((STATS_SITES + 1))
	log_info "processing ${site}"

	if ! user="$(resolve_site_user "${site}")"; then
		log_error "cannot determine the system user for ${site}; pass --user"
		return 1
	fi
	if [[ "${user}" != "$(id -un)" ]] && (( EUID != 0 )); then
		log_error "switching to user '${user}' requires root (site ${site})"
		return 1
	fi
	log_debug "running as '${user}'"

	execute_mode "${MODE}" "${site}" "${user}" || return 1
	return 0
}

###############################################################################
# Summary
###############################################################################

print_summary() { # exit code
	local exit_code="$1"

	if [[ "${JSON_OUTPUT}" == true ]]; then
		printf '{"sites": %d, "operations_ok": %d, "errors_logged": %d, "exit": %d, "log": "%s", "error_log": "%s"}\n' \
			"${STATS_SITES}" "${STATS_OK}" "${STATS_FAILED}" "${exit_code}" \
			"$(json_escape "${LOG_FILE}")" "$(json_escape "${ERROR_LOG_FILE}")"
		return 0
	fi

	printf '\n%s=== SUMMARY ===%s\n' "${C_BOLD}" "${C_RESET}"
	printf '  sites processed : %d\n' "${STATS_SITES}"
	printf '  successful ops  : %s%d%s\n' "${C_GREEN}" "${STATS_OK}" "${C_RESET}"
	printf '  failures        : %s%d%s\n' "${C_RED}" "${STATS_FAILED}" "${C_RESET}"
	printf '  mode            : %s%s\n' "${MODE}" "$([[ "${DRY_RUN}" == true ]] && printf ' (dry-run)')"
	printf '  log file        : %s\n' "${LOG_FILE}"
	printf '  error log       : %s\n' "${ERROR_LOG_FILE}"

	if (( STATS_SITES == 0 )); then
		printf '  %snothing was processed%s\n' "${C_YELLOW}" "${C_RESET}"
	elif (( STATS_FAILED == 0 )); then
		printf '  %sall operations completed successfully%s\n' "${C_GREEN}" "${C_RESET}"
	else
		printf '  %s%d failure(s); inspect %s%s\n' "${C_RED}" "${STATS_FAILED}" "${ERROR_LOG_FILE}" "${C_RESET}"
	fi
	return 0
}

###############################################################################
# Main
###############################################################################

cleanup() {
	local rc=$?
	release_lock
	return "${rc}"
}

main() {
	local i total site rc="${EXIT_OK}"

	# Configuration precedence: defaults < config file < environment < CLI.
	extract_conf_file "$@"
	load_config_file "${CONF_FILE}"
	apply_environment

	parse_args "$@"
	validate_options
	setup_colors
	resolve_wp_cli

	if [[ "${DRY_RUN}" != true ]] && (( EUID != 0 )); then
		log_warning 'running without root: only sites owned by the current user can be processed'
	fi

	init_logging
	if ! take_lock; then
		exit "${EXIT_USAGE}"
	fi

	log_info "WordPress maintenance ${SCRIPT_VERSION}, mode '${MODE}'$([[ "${DRY_RUN}" == true ]] && printf ' (dry-run)')"
	log_debug "WP-CLI: ${WP_CLI_PATH}"
	log_debug "sites file: ${SITES_FILE}"

	load_sites
	local -a queued=( "${SITES[@]}" )
	total=${#queued[@]}

	for ((i = 0; i < total; i++)); do
		site="${queued[i]}"
		if (( total > 1 )); then
			progress "$((i + 1))/${total}" "${site}"
		fi
		if ! process_site "${site}"; then
			if [[ "${MODE}" != "${MODE_LIST_PLUGINS}" ]]; then
				log_error "site failed: ${site}"
			fi
			rc="${EXIT_ERRORS}"
		fi
	done
	progress_done

	if (( STATS_SITES == 0 )); then
		rc="${EXIT_NOTHING}"
	fi

	print_summary "${rc}"
	exit "${rc}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"


