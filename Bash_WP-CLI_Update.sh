#!/usr/bin/env bash
# ==============================================================================
# File:        Bash_WP-CLI_Update.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Version:     5.0.0
# License:     MIT
#
# Description:
#   WordPress maintenance automation for multiple sites.
#   Runs WP-CLI commands (core/plugins/themes/db/cron/astra) for every site
#   listed in the sites file, as the system user that owns each WordPress
#   installation. Safe, strict mode (set -euo pipefail), argv-based command
#   execution (no shell string concatenation), atomic lock, rotating logs.
#
# Usage:
#   ./Bash_WP-CLI_Update.sh MODE [OPTIONS]
#
# Modes:
#   -f, --full        Full maintenance (core, plugins, themes, DB, cron)
#   -c, --core        Update WordPress core only
#   -p, --plugins     Update all plugins
#   -t, --themes      Update all themes
#   -d, --db-optimize Optimize and repair the database
#   -x, --db-fix      Repair the database only
#   -r, --cron        Run due cron events
#   -s, --astra       Update Astra Pro plugin (license activation if needed)
#
# Options:
#   -D, --debug             Enable debug logging
#   -q, --quiet             Suppress non-error console output
#   -n, --dry-run           Print what would execute without executing it
#       --sites-file FILE   Sites file (default: <script_dir>/wp-found.txt)
#       --wp-cli PATH       WP-CLI binary (default: wp from PATH or /usr/local/bin/wp)
#       --astra-key KEY     Astra Pro license key
#       --skip-plugins LIST Comma-separated plugins to skip during plugin/theme ops
#   -h, --help              Show this help
#   -V, --version           Show version
#
# Configuration:
#   Optional config file <script_dir>/Bash_WP-CLI_Update.conf may override
#   SITES_FILE, LOG_FILE, ERROR_LOG_FILE, WP_CLI_PATH, ASTRA_KEY,
#   SKIP_PLUGINS and MAX_LOG_SIZE. Keep it trusted (chmod 600).
#
# Requirements:
#   - Linux with Bash 4.2+
#   - root privileges (user switching); or su fallback when runuser is absent
#   - WP-CLI 2.0+ and standard GNU core utilities
#
# Test hooks (CI only):
#   WPCLI_UPDATE_SKIP_ROOT_CHECK=1  bypass the mandatory root check
#   WPCLI_UPDATE_FORCE_RUNUSER=1    use runuser even when not EUID 0
#   WPCLI_UPDATE_LOCK_TIMEOUT=N     lock acquisition timeout in seconds
# ==============================================================================

set -euo pipefail
if shopt -s inherit_errexit 2>/dev/null; then :; fi

# ------------------------------------------------------------------------------
# Constants and defaults
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly VERSION="5.0.0"

# Operation modes
readonly MODE_FULL="full"
readonly MODE_CORE="core"
readonly MODE_PLUGINS="plugins"
readonly MODE_THEMES="themes"
readonly MODE_DB_OPTIMIZE="db-optimize"
readonly MODE_DB_FIX="db-fix"
readonly MODE_CRON="cron"
readonly MODE_ASTRA="astra"

# Overridable via conf file / CLI
SITES_FILE="${SCRIPT_DIR}/wp-found.txt"
DISCOVER_SCRIPT="${SCRIPT_DIR}/Find_WP_Senior.sh"
LOG_FILE="${SCRIPT_DIR}/wp_cli_manager.log"
ERROR_LOG_FILE="${SCRIPT_DIR}/wp_cli_errors.log"
WP_CLI_PATH=""
ASTRA_KEY="YOUR_KEY"
SKIP_PLUGINS="saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer"
MAX_LOG_SIZE=5242880 # bytes (5 MiB) before rotation

NO_ASTRA_KEY="YOUR_KEY"

# Runtime state
MODE=""
DEBUG_MODE=false
QUIET=false
DRY_RUN=false

TOTAL_SITES=0
SUCCESS_OPS=0
ERROR_OPS=0
FAILED_SITES=0

LOCK_DIR=""

# ANSI colors (stderr terminal only)
if [[ -t 2 ]]; then
	readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m'
	readonly YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m'
	readonly CYAN=$'\033[0;36m' NC=$'\033[0m'
else
	readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ------------------------------------------------------------------------------
# Misc helpers
# ------------------------------------------------------------------------------
trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

now() { date '+%Y-%m-%d %H:%M:%S'; }

die() {
	printf "${RED}ERROR:${NC} %s\n" "$*" >&2
	write_log "ERROR" "$*"
	exit 1
}

cmd_skips_plugins() { case "$1" in plugin | theme | brainstormforce) return 0 ;; *) return 1 ;; esac }

# ------------------------------------------------------------------------------
# Logging (file always; console per level/quiet)
# ------------------------------------------------------------------------------
rotate_log() {
	local f="${LOG_FILE}"
	[[ -f "${f}" ]] || return 0
	local size
	size="$(stat -c '%s' "${f}" 2>/dev/null || printf '0')"
	if [[ "${size}" -gt "${MAX_LOG_SIZE}" ]]; then
		mv -f "${f}" "${f}.1" 2>/dev/null || true
	fi
}

write_log() {
	local level="$1" msg="$2"
	rotate_log
	printf '[%s] [%s] %s\n' "$(now)" "${level}" "${msg}" >>"${LOG_FILE}" 2>/dev/null || true
}

write_error_detail() {
	local context="$1" command="$2" output="$3" exit_code="$4"
	{
		printf '[%s] [ERROR DETAIL]\n' "$(now)"
		printf 'Context: %s\n' "${context}"
		printf 'Command: %s\n' "${command}"
		printf 'Exit Code: %s\n' "${exit_code}"
		printf 'Output: %s\n' "${output}"
		printf '%s\n' '---'
	} >>"${ERROR_LOG_FILE}" 2>/dev/null || true
}

console_log() {
	local level="$1" msg="$2"
	case "${level}" in
	ERROR) printf "${RED}ERROR: %s${NC}\n" "${msg}" >&2 ;;
	WARNING) [[ "${QUIET}" == false ]] && printf "${YELLOW}WARNING: %s${NC}\n" "${msg}" >&2 ;;
	SUCCESS) [[ "${QUIET}" == false ]] && printf "${GREEN}SUCCESS: %s${NC}\n" "${msg}" >&2 ;;
	INFO) [[ "${QUIET}" == false ]] && printf '%s\n' "${msg}" ;;
	DEBUG) [[ "${QUIET}" == false && "${DEBUG_MODE}" == true ]] && printf "${CYAN}DEBUG: %s${NC}\n" "${msg}" >&2 ;;
	esac
}

log_info() {
	write_log "INFO" "$1"
	console_log "INFO" "$1"
}
log_success() {
	write_log "SUCCESS" "$1"
	console_log "SUCCESS" "$1"
}
log_warning() {
	write_log "WARNING" "$1"
	console_log "WARNING" "$1"
}
log_error() {
	write_log "ERROR" "$1"
	console_log "ERROR" "$1"
}
log_debug() {
	if [[ "${DEBUG_MODE}" == true ]]; then
		write_log "DEBUG" "$1"
		console_log "DEBUG" "$1"
	fi
}

# ------------------------------------------------------------------------------
# Usage / version
# ------------------------------------------------------------------------------
usage() {
	cat <<EOF
WordPress Maintenance Automation v${VERSION}
Usage: ${SCRIPT_NAME} MODE [OPTIONS]

Modes:
  -f, --full           Full maintenance (core, plugins, themes, DB, cron)
  -c, --core           Update WordPress core only
  -p, --plugins        Update all plugins
  -t, --themes         Update all themes
  -d, --db-optimize    Optimize and repair the database
  -x, --db-fix         Repair the database only
  -r, --cron           Run due cron events
  -s, --astra          Update Astra Pro plugin (with license activation)

Options:
  -D, --debug              Enable debug logging
  -q, --quiet              Suppress non-error console output
  -n, --dry-run            Print what would execute without executing
      --sites-file FILE    Sites file (default: <script_dir>/wp-found.txt)
      --wp-cli PATH        WP-CLI binary path
      --astra-key KEY      Astra Pro license key
      --skip-plugins LIST  Comma-separated plugin list to skip (plugin/theme ops)
  -h, --help               Show this help and exit
  -V, --version            Show version and exit

Examples:
  ${SCRIPT_NAME} --plugins
  ${SCRIPT_NAME} -f --dry-run
  ${SCRIPT_NAME} --core --sites-file /etc/wp-sites.txt
  ${SCRIPT_NAME} --astra --astra-key 1234-5678-9abc

Sites are read from: ${SITES_FILE}
Each line: an absolute WordPress root path; '#' starts a comment.
EOF
}

version_info() { printf '%s %s\n' "${SCRIPT_NAME}" "v${VERSION}"; }

# ------------------------------------------------------------------------------
# Optional configuration file
# ------------------------------------------------------------------------------
DEFAULT_SITES_FILE="${SITES_FILE}"
DEFAULT_LOG_FILE="${LOG_FILE}"
DEFAULT_ERROR_LOG_FILE="${ERROR_LOG_FILE}"
DEFAULT_WP_CLI_PATH="${WP_CLI_PATH}"
DEFAULT_ASTRA_KEY="${ASTRA_KEY}"
DEFAULT_SKIP_PLUGINS="${SKIP_PLUGINS}"
DEFAULT_MAX_LOG_SIZE="${MAX_LOG_SIZE}"

load_config_file() {
	local conf="${SCRIPT_DIR}/Bash_WP-CLI_Update.conf"
	[[ -f "${conf}" ]] || return 0
	# shellcheck disable=SC1091
	source "${conf}"
	log_debug "Loaded config file: ${conf}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_args() {
	local opt
	while [[ $# -gt 0 ]]; do
		opt="$1"
		case "${opt}" in
		--full | -f) MODE="${MODE_FULL}" ;;
		--core | -c) MODE="${MODE_CORE}" ;;
		--plugins | -p) MODE="${MODE_PLUGINS}" ;;
		--themes | -t) MODE="${MODE_THEMES}" ;;
		--db-optimize | -d) MODE="${MODE_DB_OPTIMIZE}" ;;
		--db-fix | -x) MODE="${MODE_DB_FIX}" ;;
		--cron | -r) MODE="${MODE_CRON}" ;;
		--astra | -s) MODE="${MODE_ASTRA}" ;;
		--debug | -D) DEBUG_MODE=true ;;
		--quiet | -q) QUIET=true ;;
		--dry-run | -n) DRY_RUN=true ;;
		--sites-file)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			SITES_FILE="$2"
			shift
			;;
		--sites-file=*) SITES_FILE="${opt#*=}" ;;
		--wp-cli)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			WP_CLI_PATH="$2"
			shift
			;;
		--wp-cli=*) WP_CLI_PATH="${opt#*=}" ;;
		--astra-key)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			ASTRA_KEY="$2"
			shift
			;;
		--astra-key=*) ASTRA_KEY="${opt#*=}" ;;
		--skip-plugins)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			SKIP_PLUGINS="$2"
			shift
			;;
		--skip-plugins=*) SKIP_PLUGINS="${opt#*=}" ;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			version_info
			exit 0
			;;
		*) die "Unknown option: ${opt} (see --help)" ;;
		esac
		shift
	done

	[[ -n "${MODE}" ]] || {
		usage >&2
		die "No mode specified. Use one of: --full --core --plugins --themes --db-optimize --db-fix --cron --astra"
	}
}

# ------------------------------------------------------------------------------
# Atomic lock (mkdir + pid; portable, no flock dependency)
# ------------------------------------------------------------------------------
acquire_lock() {
	LOCK_DIR="${SCRIPT_DIR}/.${SCRIPT_NAME}.lock"
	local lock_timeout="${WPCLI_UPDATE_LOCK_TIMEOUT:-30}"
	[[ "${lock_timeout}" =~ ^[0-9]+$ ]] || lock_timeout=30
	local deadline=$(($(date +%s) + lock_timeout))
	while :; do
		if mkdir "${LOCK_DIR}" 2>/dev/null; then
			printf '%s\n' "$$" >"${LOCK_DIR}/pid"
			log_debug "Acquired lock: ${LOCK_DIR}"
			return 0
		fi
		# Stale lock handling: read pid, check liveness.
		local pid
		if [[ -f "${LOCK_DIR}/pid" ]] && read -r pid <"${LOCK_DIR}/pid" 2>/dev/null &&
			[[ "${pid}" =~ ^[0-9]+$ ]] && ! kill -0 "${pid}" 2>/dev/null; then
			log_warning "Removing stale lock (pid ${pid} is dead)"
			rm -rf "${LOCK_DIR}" 2>/dev/null || true
			continue
		fi
		if [[ "$(date +%s)" -ge "${deadline}" ]]; then
			die "Another instance is running (lock: ${LOCK_DIR}). Exiting."
		fi
		sleep 1
	done
}

release_lock() {
	[[ -n "${LOCK_DIR}" ]] || return 0
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		local pid
		read -r pid <"${LOCK_DIR}/pid" 2>/dev/null || pid=""
		[[ "${pid}" == "$$" ]] && rm -rf "${LOCK_DIR}" 2>/dev/null || true
	fi
	LOCK_DIR=""
}

exit_handler() {
	local rc=$?
	release_lock
	exit "${rc}"
}
trap exit_handler EXIT

# ------------------------------------------------------------------------------
# WordPress user resolution
#   Order: wp-config.php owner -> site dir owner -> /var/www path heuristic
#          -> DB_USER from wp-config.php
# ------------------------------------------------------------------------------
user_exists() { id -u "$1" >/dev/null 2>&1; }

stat_owner() { stat -c '%U' "$1" 2>/dev/null || true; }

db_user_from_config() {
	local config="$1"
	[[ -f "${config}" ]] || return 1
	local db_user
	db_user="$(grep -E "define[[:space:]]*\([[:space:]]*'DB_USER'" "${config}" 2>/dev/null |
		sed -E "s/.*'DB_USER'[[:space:]]*,[[:space:]]*'([^']+)'.*/\\1/" | tail -n 1 || true)"
	[[ -n "${db_user}" ]] && printf '%s' "${db_user}"
}

get_wp_user() {
	local wp_root="$1"
	local wp_config="${wp_root}/wp-config.php"
	local candidate

	log_debug "Resolving WordPress user for: ${wp_root}"

	# 1) Owner of wp-config.php
	if [[ -f "${wp_config}" ]]; then
		candidate="$(stat_owner "${wp_config}")"
		if [[ -n "${candidate}" && "${candidate}" != root ]] && user_exists "${candidate}"; then
			log_debug "Using wp-config.php owner: ${candidate}"
			printf '%s' "${candidate}"
			return 0
		fi
	fi

	# 2) Owner of the site directory
	candidate="$(stat_owner "${wp_root}")"
	if [[ -n "${candidate}" && "${candidate}" != root ]] && user_exists "${candidate}"; then
		log_debug "Using directory owner: ${candidate}"
		printf '%s' "${candidate}"
		return 0
	fi

	# 3) /var/www/<user>/... path heuristic
	if [[ "${wp_root}" == /var/www/* ]]; then
		local path_parts
		IFS='/' read -r -a path_parts <<<"${wp_root}"
		if [[ ${#path_parts[@]} -ge 4 ]]; then
			candidate="${path_parts[3]}"
			if [[ -n "${candidate}" ]] && user_exists "${candidate}"; then
				log_debug "Using user from path: ${candidate}"
				printf '%s' "${candidate}"
				return 0
			fi
		fi
	fi

	# 4) DB_USER from wp-config.php
	if [[ -f "${wp_config}" ]]; then
		candidate="$(db_user_from_config "${wp_config}")"
		if [[ -n "${candidate}" ]] && user_exists "${candidate}"; then
			log_debug "Using DB_USER from wp-config.php: ${candidate}"
			printf '%s' "${candidate}"
			return 0
		fi
	fi

	log_debug "All user resolution methods failed for: ${wp_root}"
	return 1
}

# ------------------------------------------------------------------------------
# WP-CLI execution
#   argv-safe: commands are bash arrays, never shell strings.
#   Preferred switch: runuser -u USER -- env K=V ... wp ...
#   Fallback:         su -s /bin/bash USER -c "$(printf %q each token)"
# ------------------------------------------------------------------------------
resolve_wp_cli() {
	local wp="${WP_CLI_PATH}"
	if [[ -z "${wp}" ]]; then
		wp="$(command -v wp 2>/dev/null || true)"
		[[ -n "${wp}" ]] || wp="/usr/local/bin/wp"
	fi
	if [[ "${wp}" == */* ]]; then
		[[ -x "${wp}" ]] || return 1
	else
		wp="$(command -v "${wp}" 2>/dev/null || true)"
		[[ -n "${wp}" && -x "${wp}" ]] || return 1
	fi
	printf '%s' "${wp}"
}

run_wp_cli() {
	local site_path="$1" user="$2"
	shift 2
	local -a cmd=("$@")
	local wp

	wp="$(resolve_wp_cli)" || {
		log_error "WP-CLI not found or not executable"
		ERROR_OPS=$((ERROR_OPS + 1))
		return 1
	}

	[[ -d "${site_path}" ]] || {
		log_error "Directory does not exist: ${site_path}"
		ERROR_OPS=$((ERROR_OPS + 1))
		return 1
	}
	user_exists "${user}" || {
		log_error "User does not exist: ${user}"
		ERROR_OPS=$((ERROR_OPS + 1))
		return 1
	}

	# Environment for the WP-CLI process (same contract as the legacy script).
	local domain home_dir
	domain="$(basename "${site_path}")"
	home_dir="$(dirname "$(dirname "${site_path}")")"
	local -a envs=(
		"DOCUMENT_ROOT=${site_path}"
		"HTTP_HOST=${domain}"
		"HOMEDIR=${home_dir}"
	)

	# Plugin-skip list only for plugin/theme/astra-related subcommands.
	if cmd_skips_plugins "${cmd[0]:-}" && [[ -n "${SKIP_PLUGINS}" ]]; then
		cmd+=("--skip-plugins=${SKIP_PLUGINS}")
	fi

	local -a full=(env "${envs[@]}" "${wp}" "--path=${site_path}" "${cmd[@]}" "--quiet" "--allow-root")

	local command_repr
	command_repr="$(
		IFS=' '
		printf '%s' "${full[*]}"
	)"
	log_debug "Prepared command: ${command_repr}"

	if [[ "${DRY_RUN}" == true ]]; then
		log_info "(dry-run) [${user}@${site_path}] ${command_repr}"
		return 0
	fi

	local output exit_code=0
	set +e
	output="$(as_user_exec "${user}" "${full[@]}" 2>&1)"
	exit_code=$?
	set -e

	if [[ "${exit_code}" -eq 0 ]]; then
		log_success "OK: wp ${cmd[*]} on ${site_path} as ${user}"
		SUCCESS_OPS=$((SUCCESS_OPS + 1))
		return 0
	fi

	log_error "Failed: wp ${cmd[*]} on ${site_path} as ${user} (exit code: ${exit_code})"
	write_error_detail "run_wp_cli" "${command_repr}" "${output}" "${exit_code}"
	ERROR_OPS=$((ERROR_OPS + 1))
	return 1
}

# run_wp_cli_soft: like run_wp_cli but performs no stats counting and logs
# failures as debug messages only. Used for preliminary/recoverable Astra steps.
run_wp_cli_soft() {
	local site_path="$1" user="$2"
	shift 2
	local -a cmd=("$@")
	local wp

	wp="$(resolve_wp_cli)" || {
		log_warning "WP-CLI not found or not executable"
		return 1
	}
	[[ -d "${site_path}" ]] || return 1
	user_exists "${user}" || return 1

	local domain home_dir
	domain="$(basename "${site_path}")"
	home_dir="$(dirname "$(dirname "${site_path}")")"
	local -a envs=(
		"DOCUMENT_ROOT=${site_path}"
		"HTTP_HOST=${domain}"
		"HOMEDIR=${home_dir}"
	)

	if cmd_skips_plugins "${cmd[0]:-}" && [[ -n "${SKIP_PLUGINS}" ]]; then
		cmd+=("--skip-plugins=${SKIP_PLUGINS}")
	fi

	local -a full=(env "${envs[@]}" "${wp}" "--path=${site_path}" "${cmd[@]}" "--quiet" "--allow-root")

	if [[ "${DRY_RUN}" == true ]]; then
		log_info "(dry-run) [${user}@${site_path}] $(
			IFS=' '
			printf '%s' "${full[*]}"
		)"
		return 0
	fi

	local output exit_code=0
	set +e
	output="$(as_user_exec "${user}" "${full[@]}" 2>&1)"
	exit_code=$?
	set -e

	if [[ "${exit_code}" -eq 0 ]]; then
		log_debug "OK (soft): wp ${cmd[*]} on ${site_path} as ${user}"
		return 0
	fi
	log_debug "Failed (soft): wp ${cmd[*]} on ${site_path} as ${user} (exit code: ${exit_code})"
	return 1
}

as_user_exec() {
	local user="$1"
	shift
	local runuser_bin
	runuser_bin="$(command -v runuser 2>/dev/null || true)"

	if [[ -n "${runuser_bin}" ]] && [[ "${EUID}" -eq 0 || "${WPCLI_UPDATE_FORCE_RUNUSER:-0}" == 1 ]]; then
		"${runuser_bin}" -u "${user}" -- "$@"
		return $?
	fi

	# su fallback: reconstruct a single POSIX-safe command string with %q.
	local escaped
	escaped="$(printf '%q ' "$@")"
	su -s /bin/bash "${user}" -c "${escaped}"
}

# ------------------------------------------------------------------------------
# Astra Pro handling (single implementation)
#   All Astra steps run through run_wp_cli_soft; only the decisive outcome
#   touches the global counters. strict=true (--astra) turns failures into
#   errors; strict=false (--full) degrades them to warnings.
# ------------------------------------------------------------------------------
_update_astra() {
	local site_path="$1" user="$2" strict="$3"

	if ! run_wp_cli_soft "${site_path}" "${user}" plugin status astra-addon; then
		if [[ "${strict}" == true ]]; then
			log_error "Astra plugin not found or not active: ${site_path}"
			ERROR_OPS=$((ERROR_OPS + 1))
			return 1
		fi
		log_warning "Astra plugin not found or not active, skipping: ${site_path}"
		return 0
	fi

	if run_wp_cli_soft "${site_path}" "${user}" plugin update astra-addon; then
		log_success "Astra plugin updated: ${site_path}"
		SUCCESS_OPS=$((SUCCESS_OPS + 1))
		return 0
	fi

	if [[ "${ASTRA_KEY}" == "${NO_ASTRA_KEY}" || -z "${ASTRA_KEY}" ]]; then
		if [[ "${strict}" == true ]]; then
			log_error "Astra update failed and no license key configured: ${site_path}"
			ERROR_OPS=$((ERROR_OPS + 1))
			return 1
		fi
		log_warning "Astra update failed and no license key configured: ${site_path}"
		return 0
	fi

	log_info "Activating Astra license and retrying update for ${site_path}"
	if ! run_wp_cli_soft "${site_path}" "${user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
		if [[ "${strict}" == true ]]; then
			log_error "Astra license activation failed: ${site_path}"
			ERROR_OPS=$((ERROR_OPS + 1))
			return 1
		fi
		log_warning "Astra license activation failed: ${site_path}"
		return 0
	fi

	if run_wp_cli_soft "${site_path}" "${user}" plugin update astra-addon; then
		log_success "Astra plugin updated after license activation: ${site_path}"
		SUCCESS_OPS=$((SUCCESS_OPS + 1))
		return 0
	fi

	if [[ "${strict}" == true ]]; then
		log_error "Astra update failed even after license activation: ${site_path}"
		ERROR_OPS=$((ERROR_OPS + 1))
		return 1
	fi
	log_warning "Astra update failed even after license activation: ${site_path}"
	return 0
}

# ------------------------------------------------------------------------------
# Mode execution: runs every operation, reports the first failure.
# ------------------------------------------------------------------------------
execute_mode() {
	local mode="$1" site_path="$2" wp_user="$3"
	local -a ops=()
	local -a full_tail=()
	local first_failure=0

	case "${mode}" in
	"${MODE_FULL}")
		ops=("core update" "plugin update --all" "theme update --all"
			"core update-db" "db optimize" "db repair" "cron event run --due-now")
		full_tail=(astra)
		;;
	"${MODE_CORE}")
		ops=("core update" "core update-db")
		;;
	"${MODE_PLUGINS}")
		ops=("plugin update --all")
		;;
	"${MODE_THEMES}")
		ops=("theme update --all")
		;;
	"${MODE_DB_OPTIMIZE}")
		ops=("db optimize" "db repair")
		;;
	"${MODE_DB_FIX}")
		ops=("db repair")
		;;
	"${MODE_CRON}")
		ops=("cron event run --due-now")
		;;
	"${MODE_ASTRA}")
		ops=()
		;;
	*)
		log_error "Unknown mode: ${mode}"
		return 1
		;;
	esac

	local op
	local -a args=()
	for op in "${ops[@]}"; do
		read -r -a args <<<"${op}"
		log_debug "Executing '${op}' for ${site_path}"
		if ! run_wp_cli "${site_path}" "${wp_user}" "${args[@]}"; then
			first_failure=1
		fi
	done

	# Astra handling: strict in --astra mode, tolerant in --full.
	if [[ "${mode}" == "${MODE_ASTRA}" ]]; then
		if [[ "${ASTRA_KEY}" == "${NO_ASTRA_KEY}" || -z "${ASTRA_KEY}" ]]; then
			log_error "Astra license key not configured (use --astra-key)."
			return 1
		fi
		if ! _update_astra "${site_path}" "${wp_user}" true; then
			first_failure=1
		fi
	fi

	if [[ ${#full_tail[@]} -gt 0 ]]; then
		_update_astra "${site_path}" "${wp_user}" false || true
		# Tolerant: never propagates as a hard failure for the site.
	fi

	[[ "${first_failure}" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# Sites file handling
# ------------------------------------------------------------------------------
ensure_sites_file() {
	if [[ -f "${SITES_FILE}" ]]; then
		log_debug "Sites file found: ${SITES_FILE}"
		return 0
	fi

	log_warning "Sites file not found: ${SITES_FILE}"

	if [[ -f "${DISCOVER_SCRIPT}" && -x "${DISCOVER_SCRIPT}" ]]; then
		if [[ "${DRY_RUN}" == true ]]; then
			log_info "(dry-run) Would run discovery: ${DISCOVER_SCRIPT} -o ${SITES_FILE}"
		else
			log_info "Running discovery: ${DISCOVER_SCRIPT} -o ${SITES_FILE}"
			"${DISCOVER_SCRIPT}" -o "${SITES_FILE}" || log_warning "Discovery script reported failures."
		fi
	else
		log_warning "Discovery script unavailable: ${DISCOVER_SCRIPT}"
	fi

	[[ -f "${SITES_FILE}" ]] && return 0

	if [[ ! -t 0 ]]; then
		die "No sites file and no TTY to ask for a site path. Create ${SITES_FILE} first."
	fi

	local user_path
	read -r -p "Enter full path to WordPress root (e.g. /var/www/site.com): " user_path
	user_path="$(trim "${user_path}")"
	[[ -n "${user_path}" ]] || die "No path provided."
	[[ -d "${user_path}" ]] || die "Directory does not exist: ${user_path}"
	if [[ ! -f "${user_path}/wp-config.php" && ! -f "${user_path}/wp-settings.php" ]]; then
		die "Not a valid WordPress installation: ${user_path}"
	fi
	printf '%s\n' "${user_path}" >"${SITES_FILE}"
	log_success "Path saved to ${SITES_FILE}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
	local start_time
	start_time="$(date +%s)"

	load_config_file
	parse_args "$@"

	# Stabilise the runtime configuration.
	SITES_FILE="${SITES_FILE:-${DEFAULT_SITES_FILE}}"
	LOG_FILE="${LOG_FILE:-${DEFAULT_LOG_FILE}}"
	ERROR_LOG_FILE="${ERROR_LOG_FILE:-${DEFAULT_ERROR_LOG_FILE}}"
	WP_CLI_PATH="${WP_CLI_PATH:-${DEFAULT_WP_CLI_PATH}}"
	ASTRA_KEY="${ASTRA_KEY:-${DEFAULT_ASTRA_KEY}}"
	SKIP_PLUGINS="${SKIP_PLUGINS:-${DEFAULT_SKIP_PLUGINS}}"
	MAX_LOG_SIZE="${MAX_LOG_SIZE:-${DEFAULT_MAX_LOG_SIZE}}"

	log_debug "Starting ${SCRIPT_NAME} v${VERSION} (mode=${MODE})"

	# Root check (test hook bypass for CI).
	if [[ "${EUID}" -ne 0 && "${WPCLI_UPDATE_SKIP_ROOT_CHECK:-0}" != 1 ]]; then
		die "This script must be run as root (required for user switching)."
	fi

	# WP-CLI reachability.
	local wp_path
	wp_path="$(resolve_wp_cli)" || die "WP-CLI not found or not executable (use --wp-cli PATH)."
	log_debug "Using WP-CLI: ${wp_path}"

	acquire_lock

	echo "=== WordPress CLI Error Log - Started at: $(date) ===" >>"${ERROR_LOG_FILE}"

	ensure_sites_file

	log_info "Starting WordPress maintenance in '${MODE}' mode"
	log_info "Reading sites from ${SITES_FILE}"

	local -A seen=()
	local line wp_user site_ok

	while IFS= read -r line || [[ -n "${line:-}" ]]; do
		line="$(trim "${line}")"
		[[ -z "${line}" || "${line}" == \#* ]] && continue

		if [[ ${seen["${line}"]+_} ]]; then
			log_debug "Skipping duplicate site: ${line}"
			continue
		fi
		seen["${line}"]=1

		if [[ ! -d "${line}" ]]; then
			log_warning "Skipping (not a directory): ${line}"
			continue
		fi

		TOTAL_SITES=$((TOTAL_SITES + 1))
		log_info "Processing site: ${line}"

		site_ok=1
		wp_user="$(get_wp_user "${line}")" || {
			log_error "Skipping site, user resolution failed: ${line}"
			FAILED_SITES=$((FAILED_SITES + 1))
			continue
		}

		execute_mode "${MODE}" "${line}" "${wp_user}" || site_ok=0
		[[ "${site_ok}" -eq 0 ]] && FAILED_SITES=$((FAILED_SITES + 1))
	done <"${SITES_FILE}"

	local end_time elapsed
	end_time="$(date +%s)"
	elapsed=$((end_time - start_time))

	log_info "Completed ${MODE} in ${elapsed}s"

	if [[ "${QUIET}" == false ]]; then
		printf '\n%s\n' "${GREEN}=== SUMMARY ===${NC}"
		printf 'Sites processed: %s\n' "${TOTAL_SITES}"
		printf 'Successful ops:  %s\n' "${SUCCESS_OPS}"
		printf 'Failed ops:      %s\n' "${ERROR_OPS}"
		printf 'Failed sites:    %s\n' "${FAILED_SITES}"
		printf 'Log file:        %s\n' "${LOG_FILE}"
		printf 'Error log:       %s\n' "${ERROR_LOG_FILE}"
	fi

	if [[ "${ERROR_OPS}" -gt 0 || "${FAILED_SITES}" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
