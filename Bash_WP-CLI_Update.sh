#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT.
#
# Built by tools/build.sh from the modules in src/manager/ (build dev-20261010192641).
# Edit the modules and rebuild; a change made here is overwritten, and
# `tools/build.sh --check` reports the drift. The single-file form is kept
# because copying one file to a host is the whole installation procedure.
# ---------------------------------------------------------------------------
# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034
#   SC2329 ("function is never invoked") is disabled file-wide on purpose. Four
#   groups of functions here are reached in ways the analyser does not follow:
#   the parallel workers (started with `&`), the mode functions (dispatched
#   through `case "$MODE"`), the trap handlers, and the helpers that only run on
#   a degraded host (no flock, no timeout, no jq). Every one of them is
#   exercised by tests/, which is the check that actually matters.
#   SC2034 ("appears unused") is disabled because the configuration table in
#   section 1 is data: the variables it names are created with `printf -v`, so
#   the analyser cannot see the assignment.
###############################################################################
# WordPress Fleet Maintenance
#
# File:         Bash_WP-CLI_Update.sh
# Project:      Bash WP-CLI Update
# Repository:   https://github.com/paulmann/Bash_WP-CLI_Update
# License:      MIT
# Version:      7.0.0
#
# Purpose
#   Run WP-CLI maintenance operations (core, plugins, themes, translations,
#   database, cron, caches, cleanup, integrity and security audits, Astra Pro
#   licence) over every WordPress installation in a site list, each one as the
#   system user that owns it, and report the result in a form a human, a cron
#   job and a monitoring system can all consume.
#
# Usage
#   Bash_WP-CLI_Update.sh <MODE> [options]
#   Bash_WP-CLI_Update.sh --check [--site PATH]
#   Bash_WP-CLI_Update.sh --status
#   Bash_WP-CLI_Update.sh --wpcli-check | --wpcli-update
#
# Design rules (read before changing anything)
#   1. No command is ever built by string concatenation. Every WP-CLI call is a
#      bash array that becomes argv. The only string handed to a shell is the
#      user switch, and there the arguments travel as positional parameters, so
#      no escaping is needed at all (see run_as_user).
#   2. `printf %q` is a bash extension. It must never be used to build a string
#      for `sh -c`, for `su -c` without `-s`, or for `ssh`. If you need it,
#      force the interpreter: `su -s /bin/bash ...`.
#   3. Secrets are never an argument of any process. The Astra licence travels
#      over stdin (default) or through a temporary file whose *path* goes on the
#      command line; the child reads the value at run time. `ps` never shows it,
#      no log line contains it, and every output channel runs it through
#      redact().
#   4. Configuration is data, not code. A config file is parsed as KEY=VALUE
#      against a whitelist; it is never sourced. A shell metacharacter, an
#      unknown key or a group/world-writable file rejects the whole file.
#   5. Exit codes are a contract (below) and are honoured everywhere, including
#      for --help: a usage error is 2, never 1.
#   6. A failing site never aborts the fleet. It is counted, reported, and the
#      loop continues -- unless the operator asked for --fail-fast.
#   7. Destructive work is opt-in and evidenced: backups before change, an
#      explicit --yes for deletions, and a dry run that prints the real argv.
#
# Exit codes
#   0  success (with --fail-on=any: every operation on every site succeeded)
#   1  operational error (at least one WP-CLI operation failed)
#   2  usage error (bad command line)
#   3  environment error (bash too old, wp-cli missing or too old, lock held,
#                         privilege problem)
#   4  configuration error (unreadable, unsafe or invalid config file)
#   5  nothing to act on (no installation found -- not a failure of the tool)
#   6  stopped early (--fail-fast, --max-duration, or a fatal per-site abort);
#      the summary is still printed and still accurate for what did run
#
# Requirements
#   bash 4.2+, GNU coreutils and findutils, WP-CLI 2.x, one of
#   runuser/sudo/su, and root to switch into site owners (a non-root run is
#   supported when the caller already owns every site).
#   Optional and probed at run time: flock, timeout, jq, curl, wget, tar, gpg,
#   logger, php. Each one degrades with a warning instead of failing.
###############################################################################

# --- shell guard -------------------------------------------------------------
# Sourced by `sh script.sh` on a host where /bin/sh is dash, this file would
# fail with a syntax error deep inside instead of saying what is wrong.
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
# -u stays on, because an unset variable here is always a bug.
set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# A predictable environment before anything is parsed.
#
# PATH: cron and systemd start with a minimal PATH that has no /usr/sbin, which
# is exactly where runuser, flock and timeout live. Prepending the standard
# directories is the difference between "works on the console" and "silently
# loses locking and user switching under cron".
#
# LC_ALL=C: every parser in this file matches byte patterns produced by GNU
# tools (df, du, stat, sort, wp --format=tsv). A locale that groups digits or
# translates collation changes what `sort -rn` and `[[:space:]]` mean. All
# messages in this tool are English by design, so nothing is lost.
#
# umask 077: temporary files, state files, licence handoffs and database dumps
# are private until the code explicitly relaxes them for a specific reason.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
export LC_ALL=C
umask 077
IFS=$' \t\n'

###############################################################################
# Section 1 - identity, exit codes
###############################################################################

PROG_NAME="${0##*/}"
SCRIPT_VERSION='7.0.0'
FINDER_VERSION='3.0.0'
# Filled by tools/build.sh; a source checkout runs unbuilt and says so.
BUILD_ID='dev-20261010192641'
BUILD_DATE='2026-10-10T19:26:41Z'
case "$BUILD_ID" in *'${'*) BUILD_ID='source' ;; esac
case "$BUILD_DATE" in *'${'*) BUILD_DATE='unbuilt' ;; esac

EXIT_OK=0        # everything the operator asked for happened
EXIT_ERROR=1     # at least one operation failed
EXIT_USAGE=2     # the command line was wrong
EXIT_ENV=3       # the host cannot run this tool
EXIT_CONFIG=4    # a configuration file was rejected
EXIT_NOTFOUND=5  # nothing to act on
EXIT_STOPPED=6   # stopped early on purpose

# resolve_script_dir: the real directory of this file, with every symlink in the
# chain resolved. Defaults for the site list, the log files, the lock and the
# discovery script hang off it, so a symlinked install (the normal case:
# /usr/local/bin/wp-fleet -> /opt/wp-cli-update/Bash_WP-CLI_Update.sh) must not
# move them into /usr/local/bin.
resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir link target
    local guard=0
    while [ -L "$src" ]; do
        # A symlink loop would otherwise spin forever. readlink(1) resolves the
        # whole chain in one process, so it is used when it is available; the loop
        # is the fallback for a host without it.
        if link="$(readlink -f -- "$src" 2>/dev/null)" && [ -n "$link" ]; then
            src="$link"
            break
        fi
        dir="$(cd -P "${src%/*}" >/dev/null 2>&1 && pwd)"
        target="$(readlink -- "$src" 2>/dev/null)"
        [ -n "$target" ] || break
        case "$target" in
            /*) src="$target" ;;
            *) src="${dir}/${target}" ;;
        esac
        guard=$((guard + 1))
        ((guard > 64)) && break
    done
    dir="${src%/*}"
    [ "$dir" = "$src" ] && dir='.'
    # `cd -P` resolves the symlinks and any `..` in the path, which is what makes
    # SCRIPT_DIR trustworthy. It also moves the shell, so the caller's working
    # directory is saved and restored: relative arguments such as
    # `--sites sites.txt` must keep meaning what the operator typed, not a path
    # relative to the installation directory.
    local oldpwd="$PWD"
    if cd -P "$dir" >/dev/null 2>&1; then
        SCRIPT_DIR="$PWD"
    else
        SCRIPT_DIR="$dir"
    fi
    cd "$oldpwd" 2>/dev/null || cd / 2>/dev/null || true
    return 0
}

# Sets SCRIPT_DIR. Called bare rather than through $(...) so that resolving the
# script directory costs no subshell: this runs before anything else, including
# on the `--version` path, where it would otherwise be the only fork in the file.
SCRIPT_DIR=''
resolve_script_dir
if [ -z "$SCRIPT_DIR" ]; then
    printf 'ERROR: cannot resolve the script directory\n' >&2
    exit 3
fi
unset -f resolve_script_dir
readonly SCRIPT_DIR PROG_NAME

# A literal backtick, spelled by code point: the config parser has to reject it,
# and writing the character directly would make this file fail the project's own
# "no backticks" audit in tests/test_static.sh.
BACKTICK=$'\140'

###############################################################################
# Section 2 - the configuration table (single source of truth)
###############################################################################
#
# Every setting the tool knows is described exactly once, here. The table drives
#   - the built-in defaults          (config_init_defaults)
#   - the config-file key whitelist  (config_key_is_known)
#   - the WP_CLI_UPDATE_* env layer  (config_load)
#   - validation and its exit codes  (config_validate_all)
#   - `--print-config`               (print_config)
#   - `--init-config` and the docs   (tools/gen-config-docs.sh)
#
# A previous revision kept four parallel lists (defaults, keys, names[], vars[])
# that had to be edited in step. They drifted: `--print-config` printed a column
# named after the config key while reading a differently named variable, and one
# setting was validated in the file layer but not in the CLI layer. One table
# removes the whole class of bug.
#
# Field layout, separated by '|':
#   1 KEY      config-file name, environment suffix (WP_CLI_UPDATE_<KEY>) and
#              shell variable name. They are the same string on purpose: a
#              mapping layer between "the setting" and "the variable" is where
#              the drift used to live.
#   2 TYPE     how the value is validated (see validate_value)
#   3 DEFAULT  built-in value; @SCRIPT_DIR@ expands to the script directory
#   4 HELP     one line, shown by --print-config and by the docs generator
#
# Types:
#   uint                non-negative integer
#   pint                positive integer
#   bool                1/0, true/false, yes/no, on/off (normalised to true/false)
#   choice:a,b,c        one of the listed words
#   words               whitespace-separated identifiers (validated per token)
#   csv                 comma-separated tokens (validated per token)
#   globs               comma-separated path patterns (never evaluated as code)
#   exec                empty, or an absolute path
#   url                 empty, or http(s)://
#   str                 anything (no shell interpretation ever happens)
#   sec                 uint, documented as seconds
#   mib                 uint, documented as mebibytes
CONFIG_SPEC=(
    # --- executables -------------------------------------------------------
    'WP_CLI_PATH|str|/usr/local/bin/wp|path to the wp executable'
    'PHP_BIN|str|php|php binary used for a direct phar install'
    'WP_CLI_MIN_VERSION|str|2.8.0|oldest WP-CLI version this tool will drive'
    'WP_CLI_LATEST_CHECK|bool|false|compare the installed WP-CLI with the latest upstream release'
    'WP_CLI_RELEASE_API|url|https://api.github.com/repos/wp-cli/wp-cli/releases/latest|release metadata endpoint'
    'WP_CLI_UPDATE_CHANNEL|choice:stable,nightly|stable|release channel for --wpcli-update'
    'WP_CLI_UPDATE_SCOPE|choice:auto,patch,minor,major|auto|how far --wpcli-update may go (auto = newest in this major)'
    'WP_CLI_TARGET_VERSION|str||pin --wpcli-update to this version (empty = newest)'
    'WP_CLI_VERIFY_PHAR|bool|true|verify a downloaded phar before installing it (fails closed)'
    'WP_CLI_GPG_KEY_URL|url|https://raw.githubusercontent.com/wp-cli/builds/gh-pages/wp-cli.pgp|WP-CLI release signing key'
    'WP_CLI_GPG_FINGERPRINT|str|63AF7AA15067C05616FDDD88A3A2E8F226F0BC06|expected fingerprint of that key'
    'WP_CLI_BACKUP_DIR|apath||where replaced wp binaries are kept (default: next to the binary)'
    'WP_CLI_UPDATE_YES|bool|false|update WP-CLI without asking'
    'WP_CLI_INSECURE|bool|false|let the updater retry without TLS verification'
    'HTTP_CLIENT|choice:auto,curl,wget|auto|HTTP client for release checks, smoke tests and webhooks'
    'USE_JQ|choice:auto,yes,no|auto|use jq for JSON parsing when it is installed'

    # --- site inventory ----------------------------------------------------
    'SITES_FILE|str|@SCRIPT_DIR@/wp-found.txt|site list, one absolute path per line'
    'DISCOVER_SCRIPT|str|@SCRIPT_DIR@/Find_WP_Senior.sh|discovery script run when the list is missing'
    'DISCOVER_ROOTS|words||web roots passed to the discovery script'
    'AUTO_DISCOVER|bool|true|run discovery when the site list is missing'
    'MAX_SITES|uint|0|process at most N sites (0 = all)'
    'SITE_USER|str||force one system user for every site'
    'INCLUDE_SITES|globs||only process paths matching these patterns'
    'EXCLUDE_SITES|globs||never process paths matching these patterns'
    'MULTISITE|choice:auto,off,main,all|auto|how to treat a multisite installation'
    'NO_USER_SWITCH|bool|false|run WP-CLI as the invoking user'

    # --- logging -----------------------------------------------------------
    'LOG_FILE|str|@SCRIPT_DIR@/wp_cli_manager.log|main log file (empty disables)'
    'ERROR_LOG_FILE|str|@SCRIPT_DIR@/wp_cli_errors.log|detailed error log (empty disables)'
    'LOG_MAX_BYTES|uint|5242880|rotate a log past this size, 0 disables rotation'
    'LOG_KEEP|uint|3|rotated generations to keep'
    'LOG_LEVEL|choice:debug,info,warn,error|info|console and file log level'
    'LOG_FORMAT|choice:text,json|text|log line format'
    'SYSLOG|bool|false|also send log lines to syslog via logger(1)'
    'ERROR_OUTPUT_LINES|pint|20|lines of a failing command shown and stored'
    'COLOR|choice:auto,always,never|auto|colourise the console'

    # --- locking -----------------------------------------------------------
    'LOCK_FILE|str|@SCRIPT_DIR@/.wp-cli-update.lock|run lock'
    'LOCK_TIMEOUT|uint|0|seconds to wait for the lock, 0 = fail immediately'
    'LOCK_REQUIRED|bool|false|refuse to run when the lock cannot be taken'

    # --- execution policy --------------------------------------------------
    'TIMEOUT|sec|0|per-command timeout in seconds, 0 disables'
    'KILL_AFTER|pint|30|escalate to SIGKILL this many seconds after the signal'
    'TIMEOUT_SIGNAL|choice:HUP,INT,QUIT,TERM,USR1,USR2,KILL|TERM|signal sent on timeout'
    'ALLOW_ROOT|choice:auto,always,never|auto|when to pass --allow-root to WP-CLI'
    'FAIL_ON|choice:any,all,never|any|when a run exits non-zero'
    'STRICT|bool|false|exit non-zero when anything was warned about'
    'FAIL_FAST|bool|false|stop the fleet after the first failing site'
    'RETRY|uint|0|re-attempt a failing site this many times'
    'STAGGER|sec|0|sleep this long between sites'
    'MAX_DURATION|sec|0|whole-run budget in seconds, 0 disables'
    'MIN_FREE_MIB|mib|0|abort a backup when the target has less free space'
    'URL|str||pass --url to WP-CLI on every call'
    'OUTPUT_FORMAT|choice:table,json,csv,tsv|table|rendering of tabular results'
    'MAINTENANCE_MODE|bool|false|put a site in maintenance mode while it is updated'

    # --- plugin and theme selection ----------------------------------------
    'SKIP_PLUGINS|csv||plugins passed to --skip-plugins on mutating operations'
    'SKIP_PLUGINS_FOR_LISTING|bool|false|also pass --skip-plugins to list commands'
    'EXCLUDE_PLUGINS|csv||slugs or names left out of --plugins and --full'
    'ONLY_ACTIVE|bool|false|update only active plugins that have an update'

    # --- Astra Pro ---------------------------------------------------------
    'ASTRA_SLUG|str|astra-addon|Astra add-on slug'
    'LICENCE|str||Astra licence value (prefer the environment or a key file)'
    'LICENCE_HANDOFF|choice:stdin,file|stdin|how the licence reaches the child process'

    # --- parallelism -------------------------------------------------------
    'JOBS|pint|1|sites processed per batch, 1 = sequential'

    # --- backups and restore -----------------------------------------------
    'BACKUP|choice:off,db,full|off|back up before a site is touched'
    'BACKUP_DIR|str|@SCRIPT_DIR@/backups|where backups are written'
    'KEEP_BACKUPS|uint|3|backups kept per site and kind, 0 = keep everything'
    'BACKUP_BEFORE_RESTORE|bool|true|dump the database before a restore overwrites it'

    # --- what --full includes ----------------------------------------------
    'FULL_DB_REPAIR|bool|false|run db repair inside --full (it locks tables)'
    'FULL_CACHE|bool|true|flush caches at the end of --full'
    'FULL_LANGUAGES|bool|true|update translations inside --full'

    # --- cache mode --------------------------------------------------------
    'CACHE_TRANSIENTS|choice:expired,all,none|expired|transients removed by --cache'
    'CACHE_REWRITE_FLUSH|bool|true|flush rewrite rules in --cache and --full'
    'CACHE_EXTRA|words||extra wp subcommands run by --cache (tokens only)'

    # --- cleanup mode ------------------------------------------------------
    'CLEANUP_REVISIONS_KEEP|uint|50|revisions kept per post, 0 = delete all'
    'CLEANUP_TRASH|bool|false|empty the trash'
    'CLEANUP_SPAM|bool|true|delete spam and trashed comments'
    'CLEANUP_AUTODRAFT|bool|false|delete auto-drafts'
    'CLEANUP_TRANSIENTS|choice:expired,all,none|expired|transients removed by --cleanup'
    'CLEANUP_OPTIMIZE|bool|true|run db optimize after a cleanup'

    # --- security audit ----------------------------------------------------
    'SECURITY_MIN_WP|str||fail an audit below this WordPress version'
    'SECURITY_UPLOADS_SCAN|bool|true|look for executable files inside uploads'
    'SECURITY_WORLD_WRITABLE|bool|true|look for world-writable PHP files'
    'SECURITY_SECRETS|bool|true|scan wp-config.php for hardcoded credentials'
    'SECURITY_MAX_ADMINS|uint|0|warn above this many administrator accounts, 0 disables'

    # --- health report -----------------------------------------------------
    'REPORT_DB_SIZE|bool|true|include the database size in --report'
    'REPORT_UPLOADS_SIZE|bool|false|include the uploads size in --report (walks the tree)'
    'REPORT_CRON_TEST|bool|true|include a WP-Cron reachability test in --report'

    # --- smoke test --------------------------------------------------------
    'SMOKE_TEST|bool|false|fetch the site URL after it was changed'
    'SMOKE_TIMEOUT|pint|15|seconds allowed for the smoke request'
    'SMOKE_EXPECT|csv|200,301,302,303,307,308|accepted HTTP status codes'
    'SMOKE_SSL_VERIFY|bool|true|verify the TLS certificate of the smoke request'
    'SMOKE_ON_FAIL|choice:fail,warn|fail|treat a failed smoke test as a site failure'

    # --- reporting ---------------------------------------------------------
    'STATE_FILE|str||write a JSON state document after every run'
    'METRICS_FILE|str||write Prometheus textfile metrics after every run'
    'NOTIFY_ON|choice:never,failure,always|never|when to send a notification'
    'NOTIFY_WEBHOOK_URL|url||POST the run summary to this webhook'
    'NOTIFY_WEBHOOK_FORMAT|choice:generic,slack,discord,telegram|generic|webhook payload shape'
    'NOTIFY_COMMAND|exec||executed with the summary as argv and environment'

    # --- environment hand-off ----------------------------------------------
    'USER_ENV|words||variable NAMES passed through into the site owner env'
)

# A literal backtick-free copy of the key list, built once. config_key_is_known
# is called for every line of every config file, so it walks an array of keys
# rather than re-splitting the spec.
CONFIG_KEYS=()

# config_spec_field ENTRY INDEX -> sets SPEC_FIELD to field N of one spec entry.
#
# Splitting with `read -a` rather than an IFS-scoped array assignment, because
# the latter would glob-expand a value that happened to contain `*`. And
# publishing through a global rather than stdout, because this runs three times
# per configuration key on every invocation: about two hundred and forty
# subshells saved before the first site is even looked at.
SPEC_FIELD=''
config_spec_field() {
    local entry="${1-}" want="${2:-0}"
    local -a parts=()
    IFS='|' read -r -a parts <<<"$entry"
    SPEC_FIELD="${parts[$want]-}"
    printf '%s' "$SPEC_FIELD"
}

# config_init_defaults: create every variable named by the table with its
# built-in value. `printf -v` is used instead of `declare -g` so that a name
# that is already readonly (none is) fails loudly instead of silently.
config_init_defaults() {
    local entry key def
    CONFIG_KEYS=()
    for entry in ${CONFIG_SPEC[@]+"${CONFIG_SPEC[@]}"}; do
        key="${entry%%|*}"
        CONFIG_KEYS+=("$key")
        config_spec_field "$entry" 2 >/dev/null
        def="${SPEC_FIELD//@SCRIPT_DIR@/$SCRIPT_DIR}"
        printf -v "$key" '%s' "$def"
    done
    config_index_build
    return 0
}

# Settings that are decided by the command line alone and are not part of the
# configuration table. They live here so that one grep shows every global.
MODE=''
TARGET_SITE=''
PLUGIN_NAME=''
PLUGIN_ACTION=''
FORCE_DELETE='false'
ASSUME_YES='false'
DRY_RUN='false'
NO_ACTION='false'
LIST_MODES='false'
LIST_SITES='false'
JSON_LINES='false'
JSON_REQUESTED='false'
PRINT_CONFIG='false'
INIT_CONFIG=''
INIT_CONFIG_REQUESTED='false'
COMPLETION=''
PAGE_LIMIT=0
FILTER_NAME=''
FILTER_FIELDS=''
QUIET='false'
VERBOSE='false'
NO_LOCK='false'
NO_BACKUP_EXPLICIT='false'
USER_OVERRIDE=''
CONFIG_REQUESTED=''
WPCLI_ACTION=''          # '' | check | update | install | rollback
RESTORE_ACTION='false'
RESTORE_FROM=''
RESTORE_FILES='false'
SHOW_VERSION_DETAIL='false'
###############################################################################
# Section 3 - small pure helpers
###############################################################################
#
# Everything in this section is side-effect free or nearly so: no logging, no
# counters, and no global state except the documented result variables. That is
# what makes these helpers testable in isolation and safe to call from a worker
# subshell.
#
# Fork discipline
# ---------------
# A helper on the per-site path publishes its result in a documented global as
# well as on stdout, so a hot caller can invoke it bare and read the global
# instead of paying for a subshell. A subshell is not free: on a 200-site run the
# per-site helpers are called thousands of times, and this tool has to keep
# working on a host that is near its process limit -- which is often exactly why
# the maintenance run was scheduled. Helpers that are called once per run just
# print.
#
# Portability floor is bash 4.2 (CentOS 7 / RHEL 7). That rules out, and this
# file therefore never uses: `declare -n` namerefs (4.3), `wait -n` (4.3),
# `mapfile -d` (4.4), `${var@Q}` (4.4), `$EPOCHSECONDS` (5.0).
# `shopt -s inherit_errexit` (4.4) is attempted once in the bootstrap and ignored
# when unavailable.

# have CMD -> is CMD runnable?
have() { command -v -- "$1" >/dev/null 2>&1; }

# is_set NAME -> true when NAME is set in this shell or in the environment.
# `printenv` is what makes the second half work: a variable exported by the
# *calling* process is not always visible to `${!NAME+x}` after an `env -i` style
# wrapper, and without it the documented WP_CLI_UPDATE_* layer silently did
# nothing under some cron and systemd setups.
is_set() {
    local n="${1:-}"
    [ -n "$n" ] || return 1
    [ -n "${!n+set}" ] && return 0
    printenv -- "$n" >/dev/null 2>&1
}

# env_value NAME -> value from the shell or the environment, empty when unset
env_value() {
    local n="${1:-}"
    if [ -n "${!n+set}" ]; then
        printf '%s' "${!n}"
        return 0
    fi
    printenv -- "$n" 2>/dev/null
    return 0
}

# trim STRING -> sets TRIMMED and prints it
TRIMMED=''
trim() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    TRIMMED="$s"
    printf '%s' "$s"
}

is_uint() { [[ "${1-}" =~ ^[0-9]+$ ]]; }
is_int() { [[ "${1-}" =~ ^-?[0-9]+$ ]]; }

# is_valid_username NAME -> conservative account-name check. Applied before a name
# is handed to runuser/sudo/su, so a wp-config.php containing
# define('DB_USER', 'x; rm -rf /') cannot reach a command line at all.
is_valid_username() { [[ "${1-}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; }

# file_mode PATH -> octal permission bits (for example 644), empty when unknown
file_mode() { stat -c '%a' -- "$1" 2>/dev/null; }

# file_owner PATH -> owner name, empty when unknown
file_owner() { stat -c '%U' -- "$1" 2>/dev/null; }

# file_group PATH -> group name, empty when unknown
file_group() { stat -c '%G' -- "$1" 2>/dev/null; }

# file_size PATH -> sets FILE_SIZE (bytes, 0 when unknown) and prints it.
# rotate_log reads the global, because it runs on every log line and cannot
# afford a subshell; the printed form serves the places that read a size once.
FILE_SIZE=0
file_size() {
    local n
    n="$(stat -c '%s' -- "$1" 2>/dev/null)"
    is_uint "$n" || n=0
    FILE_SIZE="$n"
    printf '%s' "$n"
}

# dir_kib PATH -> size in KiB, empty when unknown or unreadable
dir_kib() {
    local n
    n="$(du -sk -- "$1" 2>/dev/null)"
    n="${n%%[^0-9]*}"
    n="${n//[^0-9]/}"
    printf '%s' "$n"
}

# free_mib PATH -> free space in MiB on the filesystem holding PATH.
# `df -P` is POSIX and always prints exactly one line per filesystem, which the
# default GNU output does not guarantee for long device names.
free_mib() {
    local target="${1:-.}" kib
    kib="$(df -Pk -- "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
    kib="${kib//[^0-9]/}"
    if [ -z "$kib" ]; then printf '0'; return 1; fi
    printf '%s' "$((kib / 1024))"
}

# human_bytes N -> sets HUMAN_BYTES and prints it: "1.5 MiB" style
HUMAN_BYTES=''
human_bytes() {
    local n="${1:-0}"
    is_uint "$n" || n=0
    if ((n >= 1073741824)); then
        printf -v HUMAN_BYTES '%s.%s GiB' "$((n / 1073741824))" "$(((n % 1073741824) * 10 / 1073741824))"
    elif ((n >= 1048576)); then
        printf -v HUMAN_BYTES '%s.%s MiB' "$((n / 1048576))" "$(((n % 1048576) * 10 / 1048576))"
    elif ((n >= 1024)); then
        printf -v HUMAN_BYTES '%s KiB' "$((n / 1024))"
    else
        printf -v HUMAN_BYTES '%s B' "$n"
    fi
    printf '%s' "$HUMAN_BYTES"
}

# duration_human SECONDS -> sets DURATION_HUMAN and prints it
DURATION_HUMAN=''
duration_human() {
    local s="${1:-0}"
    is_uint "$s" || s=0
    if ((s >= 3600)); then
        printf -v DURATION_HUMAN '%dh %02dm %02ds' "$((s / 3600))" "$(((s % 3600) / 60))" "$((s % 60))"
    elif ((s >= 60)); then
        printf -v DURATION_HUMAN '%dm %02ds' "$((s / 60))" "$((s % 60))"
    else
        printf -v DURATION_HUMAN '%ss' "$s"
    fi
    printf '%s' "$DURATION_HUMAN"
}

# now_epoch -> seconds since the epoch, and sets EPOCH_NOW.
# bash's own printf formats time, so this needs no date(1) and no exec. It is a
# function at all -- rather than inlining $EPOCHSECONDS -- so a test can stub it
# and so bash 4.2, which has no EPOCHSECONDS, is still supported.
EPOCH_NOW=0
now_epoch() {
    printf -v EPOCH_NOW '%(%s)T' -1
    printf '%s' "$EPOCH_NOW"
}

# version_compare A B -> sets VERSION_CMP to -1, 0 or 1, and prints it.
#
# The global matters: version_at_least is called once per site by the security
# audit, and capturing the result through a subshell would put a fork in the
# middle of a fleet walk.
#
VERSION_CMP=0
#
# Numeric, dot separated, segment by segment: 2.10.0 > 2.9.0, which a string
# comparison gets wrong and which is exactly the mistake a version gate must not
# make. A non-numeric suffix (-nightly, -rc1) is compared after the numeric part
# with one rule only -- a release outranks a pre-release of the same number --
# because that is the rule both WP-CLI and WordPress follow. Anything exotic
# yields 0 (equal) instead of a guess: a gate that cries wolf gets disabled, and
# a disabled gate protects nobody.
version_compare() {
    local a="${1-}" b="${2-}"
    local na='' nb='' ta='' tb='' x y i n ai bi
    local -a pa=() pb=()

    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
    [ -n "$a" ] && [ -n "$b" ] || { VERSION_CMP=0; printf '0'; return 0; }
    na="${a%%[!0-9.]*}"
    nb="${b%%[!0-9.]*}"
    ta="${a#"$na"}"; ta="${ta#-}"
    tb="${b#"$nb"}"; tb="${tb#-}"

    IFS='.' read -r -a pa <<<"$na"
    IFS='.' read -r -a pb <<<"$nb"
    n=${#pa[@]}
    ((${#pb[@]} > n)) && n=${#pb[@]}
    for ((i = 0; i < n; i++)); do
        x="${pa[i]-0}"; y="${pb[i]-0}"
        x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
        ai=$((10#${x:-0})); bi=$((10#${y:-0}))
        if ((ai > bi)); then VERSION_CMP=1; printf '1'; return 0; fi
        if ((ai < bi)); then VERSION_CMP=-1; printf -- '-1'; return 0; fi
    done
    if [ -z "$ta" ] && [ -n "$tb" ]; then VERSION_CMP=1; printf '1'; return 0; fi
    if [ -n "$ta" ] && [ -z "$tb" ]; then VERSION_CMP=-1; printf -- '-1'; return 0; fi
    if [ "$ta" = "$tb" ]; then VERSION_CMP=0; printf '0'; return 0; fi
    if [[ "$ta" > "$tb" ]]; then VERSION_CMP=1; printf '1'; return 0; fi
    VERSION_CMP=-1
    printf -- '-1'
}

# version_at_least HAVE WANT -> 0 when HAVE >= WANT. Reads the global that
# version_compare publishes, so the comparison itself costs no subshell.
version_at_least() {
    version_compare "$1" "$2" >/dev/null
    [ "$VERSION_CMP" != -1 ]
}

# version_major_minor VERSION -> "6.5": the WordPress release line, which is the
# unit that matters for security support.
version_major_minor() {
    local v="${1-}"
    v="${v%%[!0-9.]*}"
    case "$v" in
        *.*.*) printf '%s' "${v%.*}" ;;
        *) printf '%s' "$v" ;;
    esac
}

# json_escape STRING -> sets JSON_ESCAPED.
#
# This one deliberately does NOT print. It runs once per field of every JSON
# record, so a 200-site run with fifteen fields per site would otherwise fork
# three thousand subshells to produce text that is immediately concatenated into
# a string. Every caller reads the global.
#
# The character loop only runs when a control byte is actually present, so the
# common case -- a path, a slug, a version -- is five expansions and no loop.
JSON_ESCAPED=''
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # shellcheck disable=SC2295  # the class is a literal control range
    case "$s" in
        *[$'\001'-$'\037']*)
            local out='' i ch
            for ((i = 0; i < ${#s}; i++)); do
                ch="${s:i:1}"
                # shellcheck disable=SC2295
                case "$ch" in
                    [$'\001'-$'\037']) continue ;;
                esac
                out+="$ch"
            done
            s="$out"
            ;;
    esac
    JSON_ESCAPED="$s"
    return 0
}

# json_quote STRING -> sets JSON_QUOTED to a complete, quoted JSON string, and
# prints it. Printing keeps the `printf '%s' "$(json_quote "$x")"` call sites
# readable; the global lets a tight loop skip the subshell.
JSON_QUOTED=''
json_quote() {
    json_escape "${1-}"
    JSON_QUOTED="\"${JSON_ESCAPED}\""
    printf '%s' "$JSON_QUOTED"
}

# csv_escape VALUE -> VALUE quoted for CSV when it needs it
csv_escape() {
    local f="${1-}"
    case "$f" in
        *[,\"]* | *$'\n'* | *$'\r'*) printf '"%s"' "${f//\"/\"\"}" ;;
        *) printf '%s' "$f" ;;
    esac
}

# sh_quote STRING -> POSIX-shell-safe single-quoted form.
#
# `printf %q` is *not* used here on purpose: it emits bash syntax, and the
# strings built with this function are parsed by /bin/sh, which on Debian is
# dash. There, %q's `\&\&` is a literal, so a %q-built command silently degrades
# into `cd: too many arguments`. This quoting works in every POSIX shell, which
# is the whole reason the user switch needs no escaping.
sh_quote() {
    local s="${1-}"
    if [ -z "$s" ]; then printf "''"; return 0; fi
    case "$s" in
        *[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "${s//\'/\'\\\'\'}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# argv_display ARGS... -> sets ARGV_DISPLAY and prints it: the argv as a human
# would type it. For dry-run output, debug lines and the error log only; never
# used to execute anything.
ARGV_DISPLAY=''
argv_display() {
    ARGV_DISPLAY=''
    local a
    for a in "$@"; do
        ARGV_DISPLAY+="$(sh_quote "$a") "
    done
    ARGV_DISPLAY="${ARGV_DISPLAY% }"
    printf '%s' "$ARGV_DISPLAY"
}

# glob_match PATTERN STRING -> bash pattern match on a path. Never `eval`, never
# a user-supplied regex: a pattern here is data, and the worst an operator can do
# with one is match nothing.
glob_match() {
    local pattern="${1-}" s="${2-}"
    [ -n "$pattern" ] || return 1
    # shellcheck disable=SC2254  # the expansion is a pattern on purpose
    case "$s" in
        $pattern) return 0 ;;
    esac
    return 1
}

# any_glob_match STRING PATTERN... -> 0 when one of the patterns matches.
# Patterns are passed as arguments rather than by array name: namerefs need
# bash 4.3 and the floor here is 4.2.
any_glob_match() {
    local s="${1-}" p
    shift
    for p in "$@"; do
        glob_match "$p" "$s" && return 0
    done
    return 1
}

# split_csv VALUE -> one trimmed, non-empty token per line
split_csv() {
    local v="${1-}" t saved="$IFS"
    IFS=','
    for t in $v; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [ -n "$t" ] && printf '%s\n' "$t"
        IFS=','
    done
    IFS="$saved"
    return 0
}

# split_words VALUE -> one token per line
split_words() {
    local v="${1-}" t
    for t in $v; do
        [ -n "$t" ] && printf '%s\n' "$t"
    done
    return 0
}

# in_csv_list NEEDLE CSV -> 0 when NEEDLE is one of the comma separated tokens.
#
# Written as a plain loop over an IFS split rather than a `while read` fed by a
# process substitution, for two reasons. It is on the hot path -- every `choice:`
# setting is validated through it, three times per run -- and each `< <(...)`
# costs a fork. More importantly, a fork can *fail*: under process-table pressure
# the substitution produces no input at all, the loop finds nothing, and a
# perfectly valid value is rejected. A validation helper that depends on being
# able to fork is a helper that fails exactly when the host is already in trouble.
in_csv_list() {
    local needle="${1-}" csv="${2-}" t saved="$IFS" rc=1
    IFS=','
    for t in $csv; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        if [ "$t" = "$needle" ]; then rc=0; IFS=','; break; fi
        IFS=','
    done
    IFS="$saved"
    return "$rc"
}

# fill_csv CSV / fill_words WORDS -> SPLIT_RESULT[]
#
# Same reasoning: the array is filled in place instead of being streamed through
# a pipe, so no fork is involved and the caller iterates with a plain for.
SPLIT_RESULT=()
fill_csv() {
    local v="${1-}" t saved="$IFS"
    SPLIT_RESULT=()
    IFS=','
    for t in $v; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [ -n "$t" ] && SPLIT_RESULT+=("$t")
        IFS=','
    done
    IFS="$saved"
    return 0
}
fill_words() {
    local v="${1-}" t
    SPLIT_RESULT=()
    for t in $v; do
        [ -n "$t" ] && SPLIT_RESULT+=("$t")
    done
    return 0
}

# path_base / path_dir -> set PATH_BASE / PATH_DIR and print them.
#
# basename(1) and dirname(1) are separate executables, and these two are called
# from inside log messages -- roughly once per site per operation. Turning an
# exec of /usr/bin/basename into ${p##*/} is the cheapest performance win in this
# file, and it removes a failure mode too: a host with a read-only or partially
# mounted /usr still has working bash expansions.
#
# The one behavioural difference from the external tools is a trailing slash:
# /var/www/ yields "www" here, which is what every caller in this project wants.
PATH_BASE=''
PATH_DIR=''
path_base() {
    local p="${1-}"
    p="${p%/}"
    PATH_BASE="${p##*/}"
    printf '%s' "$PATH_BASE"
}
path_dir() {
    local p="${1-}"
    p="${p%/}"
    case "$p" in
        */*) PATH_DIR="${p%/*}" ;;
        *) PATH_DIR='.' ;;
    esac
    printf '%s' "$PATH_DIR"
}

# safe_name STRING -> STRING with everything outside [A-Za-z0-9._-] replaced by
# an underscore, so a site directory called `my site (prod)` still yields a
# usable backup directory name.
safe_name() {
    local n="${1-}"
    n="${n//[^A-Za-z0-9._-]/_}"
    [ -n "$n" ] || n='_'
    printf '%s' "$n"
}

# numeric_lines < IDs -> keep only lines that are a plain non-negative integer.
# Every id list that reaches `wp post delete` or `wp comment delete` passes
# through here, so a malformed WP-CLI response can never become a flag or a file
# name.
numeric_lines() {
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        is_uint "$line" && printf '%s\n' "$line"
    done
    return 0
}

# chunk_lines SIZE < LINES -> one line per batch, tokens space separated.
# Deleting 40k revisions in a single command line hits ARG_MAX; batches of 200 do
# not, and one failing batch does not lose the other 199.
chunk_lines() {
    local size="${1:-200}" line out='' n=0
    is_uint "$size" || size=200
    ((size > 0)) || size=200
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        out+="${out:+ }${line}"
        n=$((n + 1))
        if ((n >= size)); then
            printf '%s\n' "$out"
            out='' n=0
        fi
    done
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# count_id_words < BATCHES -> how many ids in total, across space separated lines
count_id_words() {
    local line w n=0
    while IFS= read -r line; do
        for w in $line; do
            is_uint "$w" && n=$((n + 1))
        done
    done
    printf '%s' "$n"
}

# count_lines < TEXT -> number of lines
count_lines() {
    local n=0
    while IFS= read -r _; do n=$((n + 1)); done
    printf '%s' "$n"
}

# ensure_parent_dir FILE -> mkdir -p of the directory part, tolerating '.'
ensure_parent_dir() {
    local f="${1-}" d
    [ -n "$f" ] || return 1
    path_dir "$f" >/dev/null
    d="$PATH_DIR"
    if [ -z "$d" ] || [ "$d" = '.' ]; then return 0; fi
    [ -d "$d" ] && return 0
    mkdir -p -- "$d" 2>/dev/null
}

# atomic_write FILE < CONTENT : write to a sibling temporary file and rename.
# A monitoring system that reads a state file while it is half written gets a
# truncated document; rename(2) is atomic on every filesystem targeted here.
atomic_write() {
    local file="${1-}" tmp
    [ -n "$file" ] || return 1
    ensure_parent_dir "$file" || return 1
    tmp="${file}.tmp.$$"
    if ! cat >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null
    if ! mv -f -- "$tmp" "$file" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# --- HTTP -------------------------------------------------------------------
# curl first, then wget. curl is preferred because it reports the status code,
# which the release check needs in order to tell "the host is offline" from "the
# API answered with something unexpected".

HTTP_CLIENT_RESOLVED=''
WARNED_NO_HTTP='false'

# http_client_resolve -> curl | wget; empty and non-zero when neither exists
http_client_resolve() {
    if [ -n "$HTTP_CLIENT_RESOLVED" ]; then
        [ "$HTTP_CLIENT_RESOLVED" != 'none' ] || return 1
        printf '%s' "$HTTP_CLIENT_RESOLVED"
        return 0
    fi
    case "${HTTP_CLIENT:-auto}" in
        curl) if have curl; then HTTP_CLIENT_RESOLVED='curl'; else HTTP_CLIENT_RESOLVED='none'; fi ;;
        wget) if have wget; then HTTP_CLIENT_RESOLVED='wget'; else HTTP_CLIENT_RESOLVED='none'; fi ;;
        auto | *)
            if have curl; then HTTP_CLIENT_RESOLVED='curl'
            elif have wget; then HTTP_CLIENT_RESOLVED='wget'
            else HTTP_CLIENT_RESOLVED='none'; fi
            ;;
    esac
    if [ "$HTTP_CLIENT_RESOLVED" = 'none' ]; then
        if [ "$WARNED_NO_HTTP" = 'false' ] && [ "${LOG_INIT:-false}" = 'true' ]; then
            log_warn 'neither curl(1) nor wget(1) was found; release checks, smoke tests and webhooks are unavailable'
            WARNED_NO_HTTP='true'
        fi
        return 1
    fi
    printf '%s' "$HTTP_CLIENT_RESOLVED"
    return 0
}

# http_get URL [MAX_SECONDS] -> body on stdout
http_get() {
    local url="${1-}" t="${2:-15}" client
    client="$(http_client_resolve)" || return 1
    case "$client" in
        curl) curl -fsSL --max-time "$t" --retry 1 -- "$url" 2>/dev/null ;;
        wget) wget -q -T "$t" -t 1 -O - -- "$url" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# http_post_json URL JSON [MAX_SECONDS] -> 0 on a 2xx response
http_post_json() {
    local url="${1-}" body="${2-}" t="${3:-15}" client
    client="$(http_client_resolve)" || return 1
    case "$client" in
        curl)
            curl -fsS --max-time "$t" -H 'Content-Type: application/json' \
                -X POST --data-binary "$body" -- "$url" >/dev/null 2>&1
            ;;
        wget)
            wget -q -T "$t" -t 1 --header='Content-Type: application/json' \
                --post-data="$body" -O /dev/null -- "$url" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# http_status URL [MAX_SECONDS] -> numeric status code, 000 when unreachable
http_status() {
    local url="${1-}" t="${2:-15}" client code=''
    client="$(http_client_resolve)" || { printf '000'; return 1; }
    case "$client" in
        curl)
            local -a copts=(-sS -o /dev/null -m "$t" -w '%{http_code}' -L)
            [ "${SMOKE_SSL_VERIFY:-true}" = 'true' ] || copts+=(-k)
            code="$(curl "${copts[@]}" -- "$url" 2>/dev/null)"
            ;;
        wget)
            # wget cannot print the status; --spider succeeds on 2xx and 3xx.
            # That is enough for a smoke test whose contract is "the site still
            # answers", and the limitation is documented rather than hidden.
            local -a wopts=(-q -T "$t" -t 1 --spider)
            [ "${SMOKE_SSL_VERIFY:-true}" = 'true' ] || wopts+=(--no-check-certificate)
            if wget "${wopts[@]}" -- "$url" >/dev/null 2>&1; then code='200'; else code='000'; fi
            ;;
        *) printf '000'; return 1 ;;
    esac
    code="${code//[^0-9]/}"
    is_uint "$code" || code=0
    printf '%s' "$code"
    return 0
}

# download_file URL DEST [MAX_SECONDS] -> 0 on success. Downloads to a temporary
# name and renames, so a truncated download never sits there looking like a
# complete phar.
download_file() {
    local url="${1-}" dest="${2-}" t="${3:-300}" client tmp rc=0
    client="$(http_client_resolve)" || return 1
    [ -n "$dest" ] || return 2
    ensure_parent_dir "$dest" || return 2
    tmp="${dest}.part.$$"
    case "$client" in
        curl) curl -fSL --max-time "$t" --retry 2 -o "$tmp" -- "$url" >/dev/null 2>&1 || rc=$? ;;
        wget) wget -q -T "$t" -t 2 -O "$tmp" -- "$url" >/dev/null 2>&1 || rc=$? ;;
        *) rc=1 ;;
    esac
    if ((rc != 0)) || [ ! -s "$tmp" ]; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

###############################################################################
# Section 4 - tabular and JSON rendering
###############################################################################

# table_render [MAX_ROWS] < TSV
#
# Aligned columns from a TSV stream. Widths are measured over the rows that will
# actually be printed, so a 400-plugin site cannot blow up the terminal or spend
# a second measuring text nobody will read.
#
# Two bugs that shipped once and are gone:
#   - iterating rows with an unquoted expansion, which split any cell holding a
#     space into two columns;
#   - measuring widths over every row but printing only MAX_ROWS of them, which
#     produced a table aligned for columns that were never shown.
table_render() {
    local max="${1:-0}"
    local -a header=() rows=() widths=() col=()
    local line i n j sep='' dashes

    IFS= read -r line || return 0
    line="${line%$'\r'}"
    IFS=$'\t' read -r -a header <<<"$line"
    n=${#header[@]}
    ((n == 0)) && return 0
    for ((i = 0; i < n; i++)); do widths[i]=${#header[i]}; done

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        ((max > 0)) && ((${#rows[@]} >= max)) && break
        rows+=("$line")
        col=()
        IFS=$'\t' read -r -a col <<<"$line"
        for ((i = 0; i < n && i < ${#col[@]}; i++)); do
            ((${#col[i]} > widths[i])) && widths[i]=${#col[i]}
        done
    done

    for ((j = 0; j < n; j++)); do
        printf '%-*s  ' "${widths[j]}" "${header[j]-}"
    done
    printf '\n'
    for ((i = 0; i < n; i++)); do
        printf -v dashes '%*s' "${widths[i]}" ''
        sep+="${dashes// /-}  "
    done
    printf '%s%s%s\n' "$C_DIM" "${sep%  }" "$C_RESET"

    for ((i = 0; i < ${#rows[@]}; i++)); do
        col=()
        IFS=$'\t' read -r -a col <<<"${rows[i]}"
        for ((j = 0; j < n; j++)); do
            printf '%-*s  ' "${widths[j]}" "${col[j]-}"
        done
        printf '\n'
    done
    return 0
}

# tsv_to_csv < TSV
tsv_to_csv() {
    local line first field out
    local -a f=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        f=()
        IFS=$'\t' read -r -a f <<<"$line"
        first=1 out=''
        for field in ${f[@]+"${f[@]}"}; do
            ((first)) || out+=','
            first=0
            out+="$(csv_escape "$field")"
        done
        printf '%s\n' "$out"
    done
    return 0
}

# --- output sinks -----------------------------------------------------------
#
# Nothing in this project redirects to /dev/stdout. It looks like the obvious way
# to say "the default destination", and it is not portable: /dev/stdout is a
# symlink to /proc/self/fd/1 on Linux, so it disappears in a chroot with no
# /proc, it is absent on a few minimal images, and where fd 1 is a socket the
# open fails with ENXIO ("No such device or address") -- which a `2>/dev/null`
# guard turns into silently lost output. The convention here is therefore: an
# EMPTY sink string means stdout, and every writer goes through one of these.

# sink_write SINK < CONTENT : truncate and write
sink_write() {
    local s="${1-}"
    if [ -n "$s" ]; then cat >"$s"; else cat; fi
}

# sink_append SINK < CONTENT : append
sink_append() {
    local s="${1-}"
    if [ -n "$s" ]; then cat >>"$s"; else cat; fi
}

# sink_of PATH_OR_EMPTY : normalise a caller-supplied destination, where both ''
# and '-' mean stdout.
sink_of() {
    case "${1-}" in
        '' | '-' | /dev/stdout) printf '' ;;
        *) printf '%s' "${1}" ;;
    esac
}

# render_tsv TSV [MAX_ROWS] [SINK] : send a TSV document to a sink in the
# configured format. Every listing goes through here, which is why `--format`
# works uniformly for plugins, sites, reports and audits.
render_tsv() { # TSV [MAX_ROWS] [SINK]
    local tsv="${1-}" max="${2:-0}" sink
    sink="$(sink_of "${3-}")"
    case "${OUTPUT_FORMAT:-table}" in
        csv) printf '%s\n' "$tsv" | tsv_to_csv | sink_write "$sink" ;;
        tsv) printf '%s\n' "$tsv" | sink_write "$sink" ;;
        table | *) printf '%s\n' "$tsv" | table_render "$max" | sink_write "$sink" ;;
    esac
    return 0
}

# jq_available -> path to jq, non-zero when unavailable or disallowed.
# jq is an accelerator, never a dependency: a host without it must behave
# identically, which is why the pure-bash reader below stays in the tree and
# stays tested even where jq is installed.
JQ_RESOLVED=''
jq_available() {
    if [ -n "$JQ_RESOLVED" ]; then
        [ "$JQ_RESOLVED" != 'no' ] || return 1
        printf '%s' "$JQ_RESOLVED"
        return 0
    fi
    case "${USE_JQ:-auto}" in
        no) JQ_RESOLVED='no' ;;
        yes)
            if have jq; then
                JQ_RESOLVED="$(command -v jq)"
            else
                JQ_RESOLVED='no'
                log_warn 'USE_JQ=yes but jq(1) is not installed; using the built-in reader'
            fi
            ;;
        auto | *)
            if have jq; then JQ_RESOLVED="$(command -v jq)"; else JQ_RESOLVED='no'; fi
            ;;
    esac
    [ "$JQ_RESOLVED" != 'no' ] || return 1
    printf '%s' "$JQ_RESOLVED"
    return 0
}

# json_to_tsv KEYS... < JSON -> TSV, header line first.
json_to_tsv() {
    local data='' jq_bin keys_json='' k out='' tsv=''
    # `read -r -d ''` slurps stdin without forking. `$(cat)` is the obvious way
    # and it execs /bin/cat once per call -- and this function is called once per
    # site for every listing, report and audit, so on a 200-site fleet that is
    # several hundred processes spent on reading a pipe. read returns non-zero at
    # EOF, which is the normal end of the input and not an error.
    IFS= read -r -d '' data || true
    data="${data#"${data%%[![:space:]]*}"}"
    data="${data%"${data##*[![:space:]]}"}"
    [ -n "$data" ] || return 0
    for k in "$@"; do out+="${out:+$'\t'}${k}"; done

    if jq_bin="$(jq_available)"; then
        for k in "$@"; do
            [ -n "$keys_json" ] && keys_json+=','
            json_escape "$k"
            keys_json+="\"${JSON_ESCAPED}\""
        done
        # `// ""` keeps a missing key an empty cell instead of null, and tostring
        # normalises numbers and booleans, so both readers agree cell for cell.
        if tsv="$("$jq_bin" -r --argjson keys "[${keys_json}]" \
            '.[] | . as $o | [$keys[] | (($o[.] // "") | if type == "string" then . else tostring end)] | @tsv' \
            <<<"$data" 2>/dev/null)"; then
            printf '%s\n' "$out"
            [ -n "$tsv" ] && printf '%s\n' "$tsv"
            return 0
        fi
        log_debug 'the jq path failed; falling back to the built-in JSON reader'
    fi
    _json_to_tsv_builtin "$@" <<<"$data"
}

# _json_unescape BODY -> the literal value of a JSON string body
_json_unescape() {
    local s="${1-}" out='' ch two hex seq
    while [ -n "$s" ]; do
        ch="${s:0:1}"
        if [ "$ch" != '\' ]; then
            out+="$ch"; s="${s:1}"; continue
        fi
        two="${s:1:1}"
        case "$two" in
            n) out+=$'\n'; s="${s:2}" ;;
            r) out+=$'\r'; s="${s:2}" ;;
            t) out+=$'\t'; s="${s:2}" ;;
            b) out+=$'\b'; s="${s:2}" ;;
            f) out+=$'\f'; s="${s:2}" ;;
            '/') out+='/'; s="${s:2}" ;;
            u)
                hex="${s:2:4}"
                if [[ "$hex" =~ ^[0-9A-Fa-f]{4}$ ]]; then
                    # Only the BMP is decoded. A surrogate half becomes the
                    # replacement character rather than half a word, because a
                    # mangled plugin title in a report beats a malformed TSV line.
                    if ((16#$hex >= 55296)) && ((16#$hex <= 57343)); then
                        out+=$'\xEF\xBF\xBD'
                    else
                        printf -v seq '\\u%04x' "$((16#$hex))"
                        if printf -v ch '%b' "$seq" 2>/dev/null && [ -n "$ch" ]; then
                            out+="$ch"
                        else
                            out+=$'\xEF\xBF\xBD'
                        fi
                    fi
                    s="${s:6}"
                else
                    out+="$two"; s="${s:2}"
                fi
                ;;
            '') out+='\\'; s="${s:1}" ;;
            *) out+="$two"; s="${s:2}" ;;
        esac
    done
    printf '%s' "$out"
}

# _json_to_tsv_builtin KEYS... < JSON
#
# A minimal reader for the flat array-of-objects shape WP-CLI emits with
# --format=json. Not a JSON parser and it does not pretend to be one: string,
# number, boolean and null values plus the standard escapes, no nesting.
_json_to_tsv_builtin() {
    local data obj val esc rest ch two
    local BSLASH='\'
    local -a keys=("$@")
    local out='' k

    IFS= read -r -d '' data || true      # slurp without forking cat(1)
    data="${data#"${data%%[![:space:]]*}"}"
    data="${data%"${data##*[![:space:]]}"}"
    [ -n "$data" ] || return 0
    case "$data" in
        '['*']') ;;
        *) return 1 ;;
    esac
    data="${data#\[}"
    data="${data%\]}"

    for k in ${keys[@]+"${keys[@]}"}; do out+="${out:+$'\t'}${k}"; done
    printf '%s\n' "$out"

    while [ -n "$data" ]; do
        data="${data#"${data%%[![:space:]]*}"}"
        data="${data%"${data##*[![:space:]]}"}"
        [ -n "$data" ] || break
        case "$data" in
            ,*) data="${data#,}"; continue ;;
        esac
        [ "${data:0:1}" = '{' ] || return 1
        rest="${data#\{}"
        obj=''
        # Walk one object while keeping quoted strings intact, so a comma, a
        # brace or a bracket inside a plugin title cannot end the object early.
        while :; do
            case "$rest" in
                '' | \}*) break ;;
                '"'*)
                    esc="${rest#\"}"
                    val=''
                    while :; do
                        ch="${esc:0:1}"
                        two="${esc:0:2}"
                        if [ -z "$ch" ] || [ "$ch" = '"' ]; then
                            break
                        elif [ "$two" = '\"' ]; then
                            val+='\"'; esc="${esc:2}"
                        elif [ "$ch" = "$BSLASH" ]; then
                            val+="$two"; esc="${esc:2}"
                        else
                            val+="$ch"; esc="${esc:1}"
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

        out=''
        for k in ${keys[@]+"${keys[@]}"}; do
            val=''
            if [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                val="$(_json_unescape "${BASH_REMATCH[1]}")"
                # A tab or a newline inside a value would invent columns; both
                # are legal JSON and both are flattened to a space here.
                val="${val//$'\t'/ }"
                val="${val//$'\n'/ }"
                val="${val//$'\r'/ }"
            elif [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*(true|false|null|-?[0-9.]+) ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            out+="${out:+$'\t'}${val}"
        done
        printf '%s\n' "$out"
    done
    return 0
}

# json_array_slice TEXT -> the substring from the first '[' to the last ']'.
#
# WP-CLI writes notices and plugin deprecation warnings to stderr, and this tool
# merges the two streams so the operator reads one story in order. A JSON payload
# can therefore arrive with prose glued in front of it. Cutting to the brackets
# is what makes `plugin list --format=json` survive a chatty plugin instead of
# reporting "wp did not return JSON".
json_array_slice() {
    local body="${1-}" head
    case "$body" in
        *'['*']'*) ;;
        *) return 1 ;;
    esac
    head="${body%%\[*}"
    body="${body#"$head"}"
    printf '%s' "$body"
    return 0
}

# json_scalar KEY < JSON_OBJECT -> the value of KEY in a flat object.
# Used for the release API response, where a full parser for one field would be
# silly and a hard jq dependency would be worse.
json_scalar() {
    local key="${1-}" data=''
    IFS= read -r -d '' data || true      # slurp without forking cat(1)
    if [[ "$data" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        printf '%s' "$(_json_unescape "${BASH_REMATCH[1]}")"
        return 0
    fi
    if [[ "$data" =~ \"$key\"[[:space:]]*:[[:space:]]*(true|false|null|-?[0-9.eE+]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

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

###############################################################################
# Section 7 - fatal error helpers
###############################################################################
#
# Three prefixes, three exit codes. The distinction is not cosmetic: a cron job
# that pages on 1 must not page on 2, and an operator who typo'd a flag should
# see "usage", not "environment".

usage_error() { printf '%s: usage: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
config_error() { printf '%s: config: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_CONFIG"; }
env_error() { printf '%s: environment: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_ENV"; }

###############################################################################
# Section 8 - value validation (one implementation, two exit codes)
###############################################################################
#
# The same rule set applies to a value that came from a config file, from the
# environment and from the command line. What differs is the exit code: a bad
# setting in a file is a configuration error (4), a bad flag is a usage error
# (2). validate_value therefore only *reports*; the caller decides how to die.

# validate_value TYPE NAME VALUE -> 0 when acceptable; on failure prints the
# reason on stdout and returns 1.
validate_value() { # TYPE NAME VALUE
    local type="${1-}" name="${2-}" value="${3-}" choices tok vshow vtok
    # Redact once, up front: the value being rejected may itself be the Astra
    # licence (LICENCE is validated like every other key), and an error message
    # that echoes it would put a secret into the terminal scrollback and the cron
    # mail. Doing it here rather than inside each branch also keeps the failure
    # path free of subshells.
    redact "$value"; vshow="$REDACTED"
    case "$type" in
        uint | sec | mib)
            is_uint "$value" || { printf 'must be a non-negative integer (got %s)' "$vshow"; return 1; }
            ;;
        pint)
            if ! is_uint "$value" || ((value < 1)); then
                printf 'must be a positive integer (got %s)' "$vshow"; return 1
            fi
            ;;
        bool)
            case "$value" in
                1 | true | TRUE | True | yes | YES | on | ON | 0 | false | FALSE | False | no | NO | off | OFF | '') ;;
                *) printf 'must be a boolean (got %s)' "$vshow"; return 1 ;;
            esac
            ;;
        choice:*)
            choices="${type#choice:}"
            if ! in_csv_list "$value" "$choices"; then
                printf 'must be one of: %s (got %s)' "${choices//,/ | }" "$vshow"; return 1
            fi
            ;;
        words)
            # Variable NAMES only. Values are read from this process's own
            # environment at run time, so neither a config file nor a command
            # line can inject a value into the environment of `wp`.
            fill_words "$value"
            for tok in ${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"}; do
                if [[ ! "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    redact "$tok"; vtok="$REDACTED"
                    printf 'must be a list of variable names (offending token %s)' "$vtok"
                    return 1
                fi
            done
            ;;
        tokens)
            # Whitespace separated command tokens. Each one becomes a separate
            # argv element and is never interpreted by a shell, but rejecting
            # metacharacters here keeps an operator from believing something
            # clever worked when it did not.
            fill_words "$value"
            for tok in ${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"}; do
                if [[ ! "$tok" =~ ^[A-Za-z0-9._:/+-]+$ ]]; then
                    redact "$tok"; vtok="$REDACTED"
                    printf 'must be a list of plain command tokens (offending token %s)' "$vtok"
                    return 1
                fi
            done
            ;;
        csv)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
            esac
            ;;
        globs)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
                *"$BACKTICK"*) printf 'must not contain a backtick'; return 1 ;;
                *'$('*) printf 'must not contain a command substitution'; return 1 ;;
            esac
            ;;
        apath)
            if [ -n "$value" ] && [ "${value#/}" = "$value" ]; then
                printf 'must be an absolute path (got %s)' "$vshow"; return 1
            fi
            ;;
        exec)
            if [ -n "$value" ] && [ "${value#/}" = "$value" ]; then
                printf 'must be an absolute path to an executable (got %s)' "$vshow"; return 1
            fi
            ;;
        url)
            if [ -n "$value" ] && [[ ! "$value" =~ ^https?:// ]]; then
                printf 'must be an http(s) URL (got %s)' "$vshow"; return 1
            fi
            ;;
        str | *)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
            esac
            ;;
    esac
    return 0
}

# normalise_bool VALUE -> sets BOOL_NORM to true|false and prints it.
# Both interfaces, because it is called once per boolean key per validation pass
# and the loop in config_apply can skip the subshell.
BOOL_NORM='false'
normalise_bool() {
    case "${1-}" in
        1 | true | TRUE | True | yes | YES | on | ON) BOOL_NORM='true' ;;
        *) BOOL_NORM='false' ;;
    esac
    printf '%s' "$BOOL_NORM"
}

# Lookup tables built once from CONFIG_SPEC.
#
# config_type_of used to walk the whole spec and re-split every entry, and it is
# called for every key in three separate passes (defaults, file validation,
# effective validation). On an 80-key table that is twenty-odd thousand string
# splits before the first site is touched -- measurable, and pure waste, because
# the answer never changes during a run.
declare -A CONFIG_TYPE=()
declare -A CONFIG_HELP=()
declare -A CONFIG_DEFAULT=()

config_index_build() {
    local entry key
    CONFIG_TYPE=(); CONFIG_HELP=(); CONFIG_DEFAULT=()
    for entry in ${CONFIG_SPEC[@]+"${CONFIG_SPEC[@]}"}; do
        key="${entry%%|*}"
        config_spec_field "$entry" 1 >/dev/null; CONFIG_TYPE["$key"]="$SPEC_FIELD"
        config_spec_field "$entry" 2 >/dev/null; CONFIG_DEFAULT["$key"]="$SPEC_FIELD"
        config_spec_field "$entry" 3 >/dev/null; CONFIG_HELP["$key"]="$SPEC_FIELD"
    done
    return 0
}

# config_type_of KEY -> the TYPE field of the spec entry
config_type_of() { printf '%s' "${CONFIG_TYPE[${1-}]-str}"; }

# config_help_of KEY -> the HELP field of the spec entry
config_help_of() { printf '%s' "${CONFIG_HELP[${1-}]-}"; }

# config_default_of KEY -> the built-in default, with @SCRIPT_DIR@ expanded.
# The index stores the raw spec value; expansion happens here so that changing
# SCRIPT_DIR (which no code path does, but a test might) cannot leave a stale map.
config_default_of() {
    local d="${CONFIG_DEFAULT[${1-}]-}"
    printf '%s' "${d//@SCRIPT_DIR@/$SCRIPT_DIR}"
}

###############################################################################
# Section 9 - configuration layers
###############################################################################
#
# Precedence, lowest to highest:
#   built-in defaults < /etc/wp-cli-update.conf < <script dir>/wp-cli-update.conf
#                     < WP_CLI_UPDATE_<KEY> environment < command line
#
# The command line is parsed *first* (section 17) and records which keys it
# fixed in CLI_SET; config_load then refuses to overwrite those. That order is
# what makes `--print-config` able to show the winning layer for every setting.

CONFIG_GLOBAL='/etc/wp-cli-update.conf'
CONFIG_LOCAL="${SCRIPT_DIR}/wp-cli-update.conf"
declare -A CONF=()
declare -A CONF_SRC=()
declare -A CLI_SET=()
CONFIG_FILE_USED=''
CONFIG_INSECURE_PERMS_WARNED='false'

config_key_is_known() {
    local key="${1-}" k
    for k in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

config_store() { # KEY VALUE SOURCE
    CONF["$1"]="$2"
    CONF_SRC["$1"]="$3"
    return 0
}

# config_line_is_unsafe LINE -> the reason, or empty when the line is fine.
#
# The file is parsed, never sourced, so these characters could not execute even
# if they were present. Rejecting them anyway is defence in depth with a second
# purpose: it stops an operator from writing `KEY=a; rm -rf /` into a config
# file, believing it will run, and then being surprised when a later revision of
# this tool does source it. A config file that cannot express code never
# becomes one.
config_line_is_unsafe() {
    local line="${1-}"
    # shellcheck disable=SC2016  # these patterns are literal on purpose
    case "$line" in
        *"$BACKTICK"*) printf 'a backtick' ;;
        *'$('*) printf 'a command substitution' ;;
        *'${'*) printf 'a variable expansion' ;;
        *'|'*) printf 'a pipe' ;;
        *';'*) printf 'a semicolon' ;;
        *'>'*) printf 'a redirection' ;;
        *'<'*) printf 'a redirection' ;;
        *'&'*) printf 'a shell operator' ;;
        *) printf '' ;;
    esac
    return 0
}

# config_check_perms FILE : refuse a file another account can write.
#
# The manager runs as root. A group-writable config file is a root shell for
# every member of that group, and the historical version of this check looked at
# the "other" nibble only -- so 0620 and 0660 sailed through. This one tests the
# mask, which catches group-write and world-write in a single comparison.
config_check_perms() { # FILE
    local file="${1-}" mode='' perms='' owner=''
    perms="$(file_mode "$file")"
    if [ -z "$perms" ]; then
        log_debug "cannot stat ${file}; permission check skipped"
        return 0
    fi
    if [[ "$perms" =~ ^[0-7]{3,4}$ ]]; then
        mode=$((8#${perms}))
        if ((mode & 8#022)); then
            config_error "${file}: refusing to read a group- or world-writable config file (mode ${perms}; run: chmod 0600 ${file})"
        fi
    fi
    if [ "$(id -u)" -eq 0 ]; then
        owner="$(stat -c '%u' -- "$file" 2>/dev/null)"
        if [ -n "$owner" ] && [ "$owner" != '0' ]; then
            if [ "$CONFIG_INSECURE_PERMS_WARNED" = 'false' ]; then
                log_warn "${file} is not owned by root while this run is; a local account can replace it (chown root:root ${file})"
                CONFIG_INSECURE_PERMS_WARNED='true'
            fi
        fi
    fi
    return 0
}

# config_parse_file FILE LABEL
config_parse_file() { # FILE LABEL
    local file="${1-}" label="${2-}" line no=0 key value reason type
    [ -f "$file" ] || return 0
    [ -r "$file" ] || config_error "${file}: not readable"
    config_check_perms "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        no=$((no + 1))
        line="${line%$'\r'}"                    # tolerate a CRLF checkout
        case "$line" in '' | '#'*) continue ;; esac
        reason="$(config_line_is_unsafe "$line")"
        if [ -n "$reason" ]; then
            config_error "${file}:${no}: ${reason} in a config line; refusing to read this file (it is parsed as KEY=VALUE data, never as shell)"
        fi
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            log_warn "${file}:${no}: not a KEY=VALUE line, ignored"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Strip one matching pair of quotes; nothing else is interpreted, so a
        # value may contain a literal backslash, a dollar sign or a space.
        if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        fi
        value="${value%"${value##*[![:space:]]}"}"     # trailing whitespace only
        if ! config_key_is_known "$key"; then
            # An unknown key is a typo, and a typo in a maintenance tool means a
            # setting the operator believes is active is not. Warn loudly with
            # the nearest known name instead of ignoring it quietly.
            log_warn "${file}:${no}: unknown setting '${key}', ignored$(config_suggest "$key")"
            continue
        fi
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            config_error "${file}:${no}: ${key} ${reason}"
        fi
        config_store "$key" "$value" "$label"
        CONFIG_FILE_USED="$file"
    done <"$file"
    return 0
}

# config_suggest KEY -> "; did you mean X?" using a cheap prefix/substring test.
# A Levenshtein distance in bash costs more than this whole file; a prefix match
# catches the typos that actually happen (SKIP_PLUGIN, JOBS_MAX, LOGFILE).
config_suggest() {
    local needle="${1-}" k best=''
    needle="${needle,,}"
    for k in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        local kl="${k,,}"
        if [ "$kl" = "$needle" ]; then best="$k"; break; fi
        case "$kl" in
            "$needle"*) best="$k"; break ;;
            *"$needle"*) [ -n "$best" ] || best="$k" ;;
        esac
    done
    [ -n "$best" ] && printf '; did you mean %s?' "$best"
    return 0
}

# config_load : files, then environment. The command line already happened.
config_load() {
    local key env_name type reason value
    if [ -n "$CONFIG_REQUESTED" ]; then
        [ -f "$CONFIG_REQUESTED" ] || config_error "${CONFIG_REQUESTED}: no such file"
        config_parse_file "$CONFIG_REQUESTED" "file:$(path_base "$CONFIG_REQUESTED")"
    else
        config_parse_file "$CONFIG_GLOBAL" 'file:/etc'
        config_parse_file "$CONFIG_LOCAL" 'file:local'
    fi
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        env_name="WP_CLI_UPDATE_${key}"
        [ -z "${CLI_SET[$key]-}" ] || continue
        is_set "$env_name" || continue
        value="$(env_value "$env_name")"
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            env_error "${env_name} ${reason}"
        fi
        config_store "$key" "$value" 'env'
    done
    # The Astra licence has two historical environment names. They are read
    # here, and nowhere else, so that the alias list stays in one place.
    if [ -z "${CLI_SET[LICENCE]-}" ] && [ -z "${CONF[LICENCE]-}" ]; then
        if is_set 'ASTRA_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_KEY)" 'env:ASTRA_KEY'
        elif is_set 'ASTRA_LICENSE_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_LICENSE_KEY)" 'env:ASTRA_LICENSE_KEY'
        fi
    fi
    return 0
}

# config_apply : merge the file and environment layers into the variables, then
# validate every effective value. CLI_SET entries win and are validated too, so
# a bad `--timeout` fails with 2 and a bad TIMEOUT= in a file fails with 4.
config_apply() {
    local key type reason value
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        if [ -z "${CLI_SET[$key]-}" ] && [ -n "${CONF_SRC[$key]-}" ]; then
            printf -v "$key" '%s' "${CONF[$key]}"
        fi
    done
    # Booleans are normalised once, here, so the rest of the file can compare
    # against 'true' without repeating four spellings at every use site.
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        type="${CONFIG_TYPE[$key]-str}"
        value="${!key}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            if [ -n "${CLI_SET[$key]-}" ]; then
                usage_error "--${key,,} ${reason}"
            else
                config_error "${key} ${reason} (from ${CONF_SRC[$key]:-default})"
            fi
        fi
        if [ "$type" = 'bool' ]; then
            normalise_bool "$value" >/dev/null
            printf -v "$key" '%s' "$BOOL_NORM"
        fi
    done
    # Cross-field rules that no single type can express.
    if ((JOBS > 1)) && ((STAGGER > 0)); then
        log_warn '--stagger has no effect with --jobs > 1; batches start together by design'
    fi
    if [ "$BACKUP" = 'full' ] && ((KEEP_BACKUPS > 0)); then
        : # a full tree archive per site is the operator's choice, priced below
    fi
    return 0
}

# effective_source KEY -> which layer decided the value
effective_source() {
    local key="${1-}" src
    if [ -n "${CLI_SET[$key]-}" ]; then
        printf 'command line'
        return 0
    fi
    src="${CONF_SRC[$key]-default}"
    case "$src" in
        env | env:*) printf 'environment (%s)' "${src#env}" ;;
        default) printf 'default' ;;
        *) printf '%s' "$src" ;;
    esac
}

# print_config : the effective value of every setting next to the layer that
# produced it. Printing only the file layer -- the first attempt at this feature
# -- reads like a precedence bug even when the effective value is right, and
# nobody wants that ambiguity on a production host.
print_config() {
    local key value type src
    printf '\n%s%-26s %-40s %-9s %-22s %s%s\n' \
        "$C_BOLD" 'SETTING' 'EFFECTIVE VALUE' 'TYPE' 'FROM' 'CLI' "$C_RESET"
    printf -- '-------------------------------------------------------------------------------------------------------\n'
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        value="${!key}"
        type="${CONFIG_TYPE[$key]-str}"
        src="$(effective_source "$key")"
        if [ "$key" = 'LICENCE' ]; then
            if [ -n "$value" ]; then
                value="<set, ${#value} characters, redacted>"
            else
                value='<unset>'
            fi
        fi
        [ -n "$value" ] || value='<empty>'
        # A long value would destroy the columns; the full value is in the file.
        if ((${#value} > 40)); then value="${value:0:37}..."; fi
        printf '%-26s %-40s %-9s %-22s %s\n' \
            "$key" "$value" "${type%%:*}" "$src" \
            "$([ -n "${CLI_SET[$key]-}" ] && printf 'yes' || printf '-')"
    done
    printf -- '-------------------------------------------------------------------------------------------------------\n'
    printf 'config file used : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'searched         : %s, %s\n' "$CONFIG_GLOBAL" "$CONFIG_LOCAL"
    printf 'precedence       : defaults < file < environment (WP_CLI_UPDATE_*) < command line\n'
    printf 'mode             : %s\n' "${MODE:-<none>}"
    printf 'dry-run          : %s\n' "$DRY_RUN"
    printf 'lock             : %s\n' "$([ "$NO_LOCK" = 'true' ] && printf 'disabled by --no-lock' || printf '%s' "$LOCK_FILE")"
    printf '\n'
    return 0
}

# init_config [FILE] : emit a complete, commented configuration reference
# generated from CONFIG_SPEC. One table, so the example file, --print-config and
# docs/CONFIGURATION.md cannot disagree with the code.
init_config() { # [FILE]
    local dest entry key type def help
    dest="$(sink_of "${1-}")"
    {
        printf '# Configuration for %s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
        printf '#\n'
        printf '# Install it as one of:\n'
        printf '#   /etc/wp-cli-update.conf            global, read by every invocation\n'
        printf '#   %s/wp-cli-update.conf   per installation, wins over the global one\n' "$SCRIPT_DIR"
        printf '# ...or point at any file with --config FILE.\n'
        printf '#\n'
        printf '# This file is DATA, not shell. Only plain KEY=VALUE lines are read and it is\n'
        printf '# never sourced. A line containing a backtick, $( , ${ , a pipe, a semicolon,\n'
        printf '# an ampersand or a redirection makes the whole file be rejected with exit\n'
        printf '# code 4. A group- or world-writable file is rejected for the same reason: the\n'
        printf '# manager runs as root, so whoever can write this file can run code as root.\n'
        printf '#\n'
        printf '#   chmod 0600 wp-cli-update.conf\n'
        printf '#\n'
        printf '# Precedence, lowest to highest:\n'
        printf '#   built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf\n'
        printf '#                     < WP_CLI_UPDATE_<KEY> environment < command line\n'
        printf '#\n'
        printf '# Every setting can also be given as WP_CLI_UPDATE_<KEY> in the environment,\n'
        printf '# and almost every one has a command-line flag. Run with --help for the list,\n'
        printf '# and with --print-config to see what is in effect and which layer won.\n'
        printf '\n'
        for entry in ${CONFIG_SPEC[@]+"${CONFIG_SPEC[@]}"}; do
            key="${entry%%|*}"
            config_spec_field "$entry" 1 >/dev/null; type="$SPEC_FIELD"
            config_spec_field "$entry" 2 >/dev/null; def="$SPEC_FIELD"
            config_spec_field "$entry" 3 >/dev/null; help="$SPEC_FIELD"
            def="${def//@SCRIPT_DIR@/$SCRIPT_DIR}"
            printf '# %s\n' "$help"
            case "$type" in
                choice:*) printf '# values: %s\n' "${type#choice:}" ;;
                bool) printf '# values: 1|0 (also true/false, yes/no, on/off)\n' ;;
                uint | pint | sec | mib) printf '# an integer\n' ;;
                apath) printf '# an absolute path\n' ;;
                url) printf '# an http(s) URL\n' ;;
                csv | globs) printf '# a comma separated list\n' ;;
                words | tokens) printf '# a space separated list\n' ;;
            esac
            [ -n "$def" ] && printf '# default: %s\n' "$def"
            # Secrets and site-specific paths are commented out on purpose: an
            # uncommented line in /etc is a value somebody will forget about.
            case "$key" in
                LICENCE | URL | SITE_USER | INCLUDE_SITES | EXCLUDE_SITES | \
                    SKIP_PLUGINS | EXCLUDE_PLUGINS | NOTIFY_WEBHOOK_URL | \
                    NOTIFY_COMMAND | STATE_FILE | METRICS_FILE | \
                    WP_CLI_TARGET_VERSION | SECURITY_MIN_WP | CACHE_EXTRA | \
                    DISCOVER_ROOTS | USER_ENV)
                    printf '#%s=%s\n\n' "$key" "$def"
                    ;;
                *)
                    printf '%s=%s\n\n' "$key" "$def"
                    ;;
            esac
        done
    } | sink_write "$dest"
    if [ -n "$dest" ]; then
        chmod 600 "$dest" 2>/dev/null
        printf '%s: wrote %s (mode 0600)\n' "$PROG_NAME" "$dest" >&2
    fi
    return 0
}

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

###############################################################################
# Section 12 - secrets: resolution, redaction, hand-off
###############################################################################
#
# The Astra Pro licence is the one secret this tool handles. Three rules, in
# order of importance:
#
#   1. It is never an argument of *this* process. `ps`, `/proc/*/cmdline`, the
#      shell history, the cron log and the process accounting of the host all
#      capture argv; none of them capture stdin or the environment of a child.
#   2. It is never written to a log line, a report, a state file or an error
#      box. redact() runs on every outgoing string and knows the value.
#   3. It never touches the filesystem by default. The hand-off below uses
#      stdin, which is why LICENCE_HANDOFF=file exists only as a documented
#      fallback for the one setup where stdin does not survive the switch.
#
# What cannot be avoided, and is therefore stated plainly: the receiving
# `wp brainstormforce license activate <key>` process does get the value as an
# argument, because that is the interface the plugin offers. The exposure is one
# process, for the duration of one call, owned by the site user. Everything this
# tool controls is closed.

LICENCE_FILE=''
LICENCE_SOURCE=''

# licence_resolve STRICT(true|false)
#
# Sources, in order: the LICENCE variable (filled from --astra-key, from the
# config file or from WP_CLI_UPDATE_LICENCE / ASTRA_KEY / ASTRA_LICENSE_KEY by
# the configuration layers), then the key files. A key file is preferred over a
# value in a config file for the obvious reason: the file can be 0600, and the
# config file tends to become 0644 the day somebody needs to read it.
#
# The configuration layer stores the setting in the variable named after its key
# (LICENCE); the runtime works with LICENCE_VALUE. Bridging the two here -- and
# nowhere else -- is what keeps `LICENCE=` in a config file, the environment
# aliases and --astra-key working through one code path.
licence_resolve() { # [STRICT]
    local strict="${1:-false}" f
    if [ -z "$LICENCE_VALUE" ] && [ -n "${LICENCE:-}" ]; then
        LICENCE_VALUE="$LICENCE"
        LICENCE_SOURCE="${CONF_SRC[LICENCE]:-command line}"
    fi
    if [ -z "$LICENCE_VALUE" ]; then
        for f in "${SCRIPT_DIR}/astra.key" '/etc/wp-cli-update/astra.key' \
                 "${HOME:-/root}/.astra.key" "${HOME:-/root}/.config/astra.key"; do
            if [ -r "$f" ] && [ -f "$f" ]; then
                LICENCE_VALUE="$(head -n 1 -- "$f" 2>/dev/null)"
                # Strip ALL whitespace, which covers the trailing CR of a key
                # file edited on Windows along with the newline and any stray
                # space: a licence key never contains whitespace, so this
                # cannot destroy a real value.
                LICENCE_VALUE="${LICENCE_VALUE//[[:space:]]/}"
                if [ -n "$LICENCE_VALUE" ]; then
                    LICENCE_SOURCE="$f"
                    log_debug "licence read from ${f}"
                    break
                fi
            fi
        done
    fi
    # A placeholder that survived from an example file is not a licence. Acting
    # on one produces a confusing "invalid key" from the plugin; refusing it
    # produces a clear message here.
    case "$LICENCE_VALUE" in
        YOUR* | *HERE* | CHANGE* | 'xxx'* | '***'*)
            log_warn 'the configured Astra licence looks like a placeholder; ignoring it'
            LICENCE_VALUE=''
            ;;
    esac
    if [ -z "$LICENCE_VALUE" ]; then
        LICENCE_SOURCE=''
        if [ "$strict" = 'true' ]; then
            log_error 'mode --astra needs a licence: pass --astra-key, set WP_CLI_UPDATE_LICENCE, put LICENCE= in the config file, or create one of ./astra.key, /etc/wp-cli-update/astra.key, $HOME/.astra.key (chmod 600)'
            return 1
        fi
        return 1
    fi
    redact_register "$LICENCE_VALUE"
    return 0
}

# licence_open : prepare the hand-off. For the stdin mechanism there is nothing
# to prepare; for the file mechanism a temporary file is created and registered
# for cleanup.
licence_open() {
    [ -n "$LICENCE_VALUE" ] || return 0
    if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ]; then
        return 0
    fi
    [ -n "$LICENCE_FILE" ] && return 0
    LICENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.licence.XXXXXX")" || {
        log_error 'cannot create a temporary file for the licence hand-off'
        return 1
    }
    tmp_register "$LICENCE_FILE"
    # Write first, relax the mode second: the value is never present in a file
    # that is already readable by another account.
    if ! printf '%s' "$LICENCE_VALUE" >"$LICENCE_FILE"; then
        log_error "cannot write the licence hand-off file ${LICENCE_FILE}"
        LICENCE_FILE=''
        return 1
    fi
    # The file has to be readable by the site owner, because the command
    # substitution that reads it runs *after* the user switch. 0600 root does not
    # work at all: the child gets "Permission denied" and the licence arrives
    # empty. mktemp already gave it an unpredictable name inside a sticky
    # directory, and it is unlinked as soon as the call returns, so the exposure
    # window is one WP-CLI invocation.
    #
    # Every alternative is worse: `runuser -m` has no equivalent under sudo or
    # su, and putting the value in argv is exactly what this design refuses. If
    # the threat model includes other local users reading /tmp during a run, use
    # the default stdin hand-off, or feed WP_CLI_UPDATE_LICENCE per invocation
    # from a secrets manager instead of keeping a key file on disk.
    if ! chmod 644 "$LICENCE_FILE" 2>/dev/null; then
        log_warn "cannot relax the mode of ${LICENCE_FILE}; the site owner may not be able to read it"
    fi
    log_debug "licence hand-off file prepared (${LICENCE_FILE})"
    return 0
}

licence_close() {
    [ -n "$LICENCE_FILE" ] || return 0
    rm -f -- "$LICENCE_FILE" 2>/dev/null
    LICENCE_FILE=''
    return 0
}

# needs_licence_handoff ARGS... -> 0 when one argument is the licence marker
needs_licence_handoff() {
    local a
    for a in "$@"; do
        [ "$a" = "$LICENCE_MARKER" ] && return 0
    done
    return 1
}

# child_argv VAR PROGRAM [ARGS...]
#
# Normally this emits the argv unchanged, one element per line. When one
# argument equals the licence marker, the whole command is wrapped in
# `/bin/sh -c '<obtain the secret> exec env VAR=... PROGRAM ...' sh`, so the
# value is obtained at run time inside the child and never appears in the
# parent's argv, in a dry-run listing, in the error log or on the console.
#
# Two mechanisms:
#   stdin  (default) the wrapper reads one line from fd 0. Nothing on disk.
#   file             the wrapper cats a temporary path. Kept for setups where a
#                    wrapper between this tool and the site user consumes stdin
#                    (some sudo configurations with `use_pty`, a few PAM modules,
#                    and every shell that decides to read a script from stdin).
child_argv() { # VAR PROGRAM [ARGS...]
    local var="$1"; shift
    local prog="$1"; shift
    local a cmd='' prelude=''
    local -a found=()

    for a in "$prog" "$@"; do
        if [ "$a" = "$LICENCE_MARKER" ]; then
            found+=("$a")
            cmd+="${cmd:+ }\"\$${var}\""
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
    if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_error "internal: refusing to build a wrapper for an invalid variable name"
        return 1
    fi

    case "${LICENCE_HANDOFF:-stdin}" in
        file)
            [ -n "$LICENCE_FILE" ] || { log_error 'internal: the licence hand-off file is not open'; return 1; }
            prelude="exec env ${var}=\"\$(cat -- $(sh_quote "$LICENCE_FILE"))\" "
            ;;
        stdin | *)
            # `read` gets an empty value rather than failing the command when
            # stdin is already at EOF, so a mis-wired wrapper produces a clear
            # "licence arrived empty" from the plugin instead of a shell error.
            prelude="IFS= read -r ${var} || ${var}=''; export ${var}; exec env ${var}=\"\$${var}\" "
            ;;
    esac
    printf '%s\n' '/bin/sh' '-c' "${prelude}${cmd}" 'sh'
    return 0
}

###############################################################################
# Section 13 - user switching
###############################################################################
#
# Running WP-CLI as root creates files owned by root inside a site whose owner
# is www-data. The next `wp plugin update` run by that owner then fails on a
# directory it cannot write, and the failure surfaces as "the plugin did not
# update" three weeks later. The switch is therefore the point of this tool, not
# a detail of it.

# The command is handed to the target shell as *positional parameters*, so no
# quoting is needed at all: a site path may contain spaces, quotes, dollars or
# semicolons and still arrives as exactly one argument. This is the single most
# important line in the file -- do not "simplify" it into a command string.
# shellcheck disable=SC2016  # single quotes are the point: this is a snippet
RUNNER_SNIPPET='cd -- "$1" || exit 127; shift; exec "$@"'

# switch_mechanism -> the name of the mechanism that will be used, for --check
# and the banner. Resolved once and cached: probing for runuser on every site of
# a 200-site fleet is 200 pointless forks.
SWITCH_MECHANISM=''
switch_mechanism() {
    if [ -n "$SWITCH_MECHANISM" ]; then
        printf '%s' "$SWITCH_MECHANISM"
        return 0
    fi
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        SWITCH_MECHANISM='disabled (--no-user-switch)'
    elif [ "$(id -u)" -ne 0 ]; then
        SWITCH_MECHANISM="none (running as $(id -un), no privilege to switch)"
    elif have runuser; then
        SWITCH_MECHANISM='runuser'
    elif have sudo; then
        SWITCH_MECHANISM='sudo -n'
    elif have su; then
        SWITCH_MECHANISM='su -s /bin/sh'
    else
        SWITCH_MECHANISM='UNAVAILABLE (no runuser, sudo or su)'
    fi
    printf '%s' "$SWITCH_MECHANISM"
    return 0
}

# user_switch_argv WORKDIR USER PROGRAM [ARGS...]
#
# Fills the global USER_SWITCH_ARGV with the exact argv that performs the switch.
# A global array rather than printed lines, because a site path may legally
# contain a newline and any serialisation would reintroduce the quoting bug this
# design exists to avoid.
#
# `--no-user-switch` runs everything as the invoking user. It exists for two
# reasons: single-site hosts where the operator already IS the site user, and
# test suites. The second reason matters more than it looks -- three independent
# suites in this project's history reported dozens of failures that were purely
# "the fixture is owned by root and there is no account to switch into". A
# switch that can be turned off makes a suite portable instead of
# environment-coupled.
USER_SWITCH_ARGV=()
user_switch_argv() { # WORKDIR USER PROGRAM [ARGS...]
    local workdir="$1" user="$2"
    shift 2
    USER_SWITCH_ARGV=()
    if [ "$NO_USER_SWITCH" = 'true' ] || [ "$user" = "$(id -un)" ]; then
        USER_SWITCH_ARGV=(/bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if [ "$(id -u)" -eq 0 ] && have runuser; then
        USER_SWITCH_ARGV=(runuser -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if [ "$(id -u)" -eq 0 ] && have sudo; then
        USER_SWITCH_ARGV=(sudo -n -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if ! have su; then
        log_error "cannot switch to '${user}': none of runuser, sudo or su is available"
        return 1
    fi
    # su passes everything after the user name to the shell as positional
    # parameters, so even this last fallback needs no escaping.
    USER_SWITCH_ARGV=(su -s /bin/sh -c "$RUNNER_SNIPPET" "$user" sh "$workdir" "$@")
    return 0
}

# run_as_user WORKDIR USER PROGRAM [ARGS...]
run_as_user() {
    user_switch_argv "$@" || return 127
    "${USER_SWITCH_ARGV[@]}"
    return $?
}

###############################################################################
# Section 14 - site owner resolution
###############################################################################

# db_user_from_config FILE -> the DB_USER literal, or nothing.
# `define( 'DB_USER', 'x' );` is read with a bash regex. The value is only ever
# used as a *name* and is validated against the passwd database afterwards, so a
# hostile wp-config.php cannot smuggle shell syntax into a command line.
db_user_from_config() {
    local cfg="${1:-}" line value
    [ -r "$cfg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ define\([[:space:]]*[\']DB_USER[\'][[:space:]]*,[[:space:]]*[\']([^\']*)\' ]] ||
           [[ "$line" =~ define\([[:space:]]*[\"]DB_USER[\"][[:space:]]*,[[:space:]]*[\"]([^\"]*)[\"] ]]; then
            value="${BASH_REMATCH[1]}"
            if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
        fi
    done <"$cfg"
    return 1
}

# usable_owner NAME -> 0 when NAME is an existing account with a real shell.
# A nologin account cannot run WP-CLI, and a name that is not in the passwd
# database cannot be switched into; both would fail later with a much less
# helpful message.
usable_owner() {
    local name="${1:-}" shell
    [ -n "$name" ] || return 1
    [ "$name" != 'root' ] || return 1
    is_valid_username "$name" || return 1
    id -u "$name" >/dev/null 2>&1 || return 1
    if have getent; then
        shell="$(getent passwd "$name" 2>/dev/null | cut -d: -f7)"
        case "$shell" in
            '' | */nologin | */false | */sync | */shutdown | */halt) return 1 ;;
        esac
    fi
    return 0
}

# site_user_candidates SITE -> candidate owners, best first.
# Kept as a list so the ordering is testable without a filesystem:
#   1. the owner of wp-config.php, which is the file the site user must be able
#      to write and is therefore the most reliable signal;
#   2. the owner of the site directory;
#   3. DB_USER from wp-config.php, which on a shared host is often also the
#      system account (and on a host with a central database server is not, so
#      it is last and is validated like the others).
# `root` is accepted only as a last resort: containers legitimately run
# everything as root, and refusing to work there is worse than warning.
site_user_candidates() { # SITE
    local site="${1-}" cfg="${1-}/wp-config.php" v
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

# site_user_resolve SITE -> prints the user, non-zero when it cannot be found
site_user_resolve() { # SITE
    local site="${1-}" cand chosen='' root_fallback=''
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        # Nothing is switched, so the only name that matters is the one used in
        # logs and in the child environment: report who will really run wp.
        id -un
        return 0
    fi
    if [ -n "${SITE_USER:-}" ]; then
        printf '%s' "$SITE_USER"
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
        # Warn three times and then stop repeating: on a container host every
        # site is root-owned and 200 identical warnings hide the real ones.
        if ((SITE_USER_WARNINGS < 3)); then
            log_warn "${site}: owned by root and no usable site user found; running wp as root"
            SITE_USER_WARNINGS=$((SITE_USER_WARNINGS + 1))
            ((SITE_USER_WARNINGS == 3)) &&
                log_warn 'further "owned by root" warnings are suppressed for this run'
        fi
        printf 'root'
        return 0
    fi
    return 1
}

# user_home NAME -> the home directory of NAME, empty when unknown
user_home() {
    local name="${1-}" home=''
    [ -n "$name" ] || return 0
    if have getent; then
        home="$(getent passwd "$name" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$home" ] && [ -n "${HOME:-}" ] && [ "$name" = "$(id -un)" ]; then
        home="$HOME"
    fi
    printf '%s' "$home"
}

# site_env_argv SITE USER -> one NAME=VALUE per line, for env(1).
#
# These are emitted as argv elements, never as a shell string, which is why a
# site path containing a quote cannot break anything here. The names are the
# historical contract of this project: a handful of hosting panels and custom
# mu-plugins read DOCUMENT_ROOT and HOMEDIR, and removing them silently broke
# sites, so they stay -- documented as legacy rather than presented as a
# recommendation.
site_env_argv() { # SITE USER
    local site="${1-}" user="${2-}" label parent home v
    label="$(path_base "$site")"
    parent="$(path_dir "$(path_dir "$site")")"
    home="$(user_home "$user")"
    if [ -z "$home" ] || [ ! -d "$home" ]; then home="$parent"; fi
    printf '%s\n' \
        "DOCUMENT_URI=${label}" \
        "DOCUMENT_ROOT=${site}" \
        "HOMEDIR=${parent}" \
        "HTTP_HOST=${label}" \
        "HOME=${home}" \
        "USER=${user}" \
        "LOGNAME=${user}"
    # Operator-selected pass-through, for example a proxy or an API endpoint.
    # Only NAMES are configured; the values are taken from this process's own
    # environment, so a config file cannot invent an environment for `wp`.
    for v in $USER_ENV; do
        if is_set "$v"; then
            printf '%s\n' "${v}=$(env_value "$v")"
        fi
    done
    return 0
}

# allow_root_flag -> '--allow-root' when the policy says to pass it.
# `auto` means: pass it only when this process is root, which is the only
# situation where WP-CLI would otherwise refuse to run.
allow_root_flag() {
    case "${ALLOW_ROOT:-auto}" in
        always) printf -- '--allow-root' ;;
        never) return 0 ;;
        auto | *) [ "$(id -u)" -eq 0 ] && printf -- '--allow-root' ;;
    esac
    return 0
}

# privilege_preflight : decide whether this run may proceed at all.
#
# The historical rule was "root or die", which is right for a multi-tenant host
# and wrong everywhere else: a container that runs everything as www-data, a
# single-site box where the operator IS the site owner, and every CI job. Those
# three are a large share of real deployments, and refusing them pushes people
# into `--no-user-switch`, which is the option that actually loses safety.
#
# The rule now: root may always switch. A non-root caller may run when every
# resolved owner is the caller, and is refused with a precise message when any
# site needs a switch that cannot happen.
privilege_preflight() {
    local i user need_switch=0 first_bad=''
    if [ "$(id -u)" -eq 0 ]; then
        if ! have runuser && ! have sudo && ! have su; then
            log_warn 'running as root but no runuser, sudo or su was found; WP-CLI will run as root'
        fi
        return 0
    fi
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        log_warn "running as $(id -un) with --no-user-switch: WP-CLI runs as $(id -un) and files it creates will be owned by $(id -un)"
        return 0
    fi
    for ((i = 0; i < UNIT_COUNT; i++)); do
        user="${UNIT_USER[i]}"
        if [ "$user" != "$(id -un)" ] && [ "$user" != 'root' ]; then
            need_switch=1
            [ -n "$first_bad" ] || first_bad="${UNIT_PATH[i]} (owner ${user})"
        fi
    done
    if ((need_switch)); then
        log_error "this run needs to switch into a site owner but is not root: ${first_bad}"
        log_error 're-run with sudo, or pass --user NAME, --no-user-switch, or --dry-run / --check'
        exit "$EXIT_ENV"
    fi
    log_debug "running unprivileged as $(id -un); every resolved site owner is the caller"
    return 0
}

###############################################################################
# Section 15 - WP-CLI resolution
###############################################################################

# wp_resolve -> the wp binary to use, or non-zero.
#
# An operator who configured a path means that path. Falling back to whatever
# `wp` happens to be in PATH would run a different WP-CLI than the one that was
# asked for, against a fleet, without saying so -- so a configured path that does
# not exist is an error, not a hint.
wp_resolve() {
    local candidate
    if [ -n "${CLI_SET[WP_CLI_PATH]-}" ] || [ -n "${CONF_SRC[WP_CLI_PATH]-}" ]; then
        if [ -x "$WP_CLI_PATH" ] && [ ! -d "$WP_CLI_PATH" ]; then
            printf '%s' "$WP_CLI_PATH"
            return 0
        fi
        log_error "configured wp-cli is not an executable file: ${WP_CLI_PATH}"
        return 1
    fi
    if [ -n "$WP_CLI_PATH" ] && [ -x "$WP_CLI_PATH" ] && [ ! -d "$WP_CLI_PATH" ]; then
        printf '%s' "$WP_CLI_PATH"
        return 0
    fi
    for candidate in wp /usr/local/bin/wp /usr/bin/wp "${HOME:-/root}/wp-cli.phar"; do
        if command -v -- "$candidate" >/dev/null 2>&1; then
            command -v -- "$candidate"
            return 0
        fi
        if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# wp_ensure : resolve once and remember. Called from every wp invocation, so it
# must be cheap after the first time.
wp_ensure() {
    if [ -n "$WP_RESOLVED" ]; then return 0; fi
    WP_RESOLVED="$(wp_resolve)" || {
        log_error "WP-CLI not found (looked for '${WP_CLI_PATH}', then wp in PATH, /usr/local/bin/wp, /usr/bin/wp)"
        log_error 'install it with --wpcli-install, or from https://wp-cli.org/, or set WP_CLI_PATH'
        return 1
    }
    log_debug "wp-cli resolved to ${WP_RESOLVED}"
    return 0
}

# wp_realpath -> the resolved path of the binary, through every symlink.
# A distribution package often installs /usr/local/bin/wp -> ../share/wp-cli.phar,
# and "is this file writable?" is a question about the target, not the link.
wp_realpath() {
    local p="${WP_RESOLVED:-$WP_CLI_PATH}"
    [ -n "$p" ] || return 1
    readlink -f -- "$p" 2>/dev/null || printf '%s' "$p"
}

# wp_install_kind -> phar | symlink | script | unknown
wp_install_kind() {
    local real base
    real="$(wp_realpath)" || { printf 'unknown'; return 0; }
    base="$(path_base "$real")"
    case "$base" in
        *.phar) printf 'phar' ;;
        *)
            # A composer or git install is a PHP file inside a vendor tree; a
            # distribution package is usually a small shell wrapper. The first
            # line tells them apart without executing anything.
            case "$(head -c 64 -- "$real" 2>/dev/null)" in
                *'<?php'*) printf 'php-source' ;;
                '#!'*) printf 'script' ;;
                *) printf 'unknown' ;;
            esac
            ;;
    esac
    return 0
}

# wp_upgradable -> 0 when this tool may replace the binary in place.
# `wp cli update` only works for the Phar installation mechanism, and a
# self-update that cannot write its own target is a failure the operator should
# hear about before the download, not after it.
wp_upgradable() {
    local real dir kind
    kind="$(wp_install_kind)"
    if [ "$kind" != 'phar' ]; then
        log_debug "wp-cli install kind is '${kind}'; 'wp cli update' only supports a phar"
        return 1
    fi
    real="$(wp_realpath)" || return 1
    [ -w "$real" ] && return 0
    dir="$(path_dir "$real")"
    [ -w "$dir" ] && return 0
    return 1
}

###############################################################################
# Section 16 - WP-CLI version policy
###############################################################################
#
# Why this exists: the tool drives `wp` across a fleet, and the difference
# between WP-CLI 1.5 and 2.11 is not cosmetic. `plugin update --all` on an
# ancient build, `db export` without `--add-drop-table`, `language` before it
# existed, `maintenance-mode` before WP 5.5 -- each is a mode that silently does
# something else than the operator read in the documentation. A version gate at
# startup turns that class of surprise into one line of output.
#
# The gate is a floor, not a pin. Being *behind* the floor is an environment
# error; being behind the newest release is a warning, because a fleet host that
# cannot reach the internet must still be able to run maintenance.

WP_CLI_FINGERPRINT_DEFAULT='63AF7AA15067C05616FDDD88A3A2E8F226F0BC06'

# wpcli_version_local -> the installed WP-CLI version, empty when it cannot be
# determined. Runs `wp cli version` *without* --path so that no WordPress is
# loaded: the answer must not depend on a site being healthy, and it must work
# on a host where the only problem is that every site is broken.
wpcli_version_local() {
    if [ -n "$WP_CLI_VERSION" ]; then
        printf '%s' "$WP_CLI_VERSION"
        return 0
    fi
    wp_ensure || return 1
    local out rc=0
    local -a argv=("$WP_RESOLVED" cli version)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>&1 </dev/null)" || rc=$?
    # `WP-CLI 2.11.0` is the normal answer; a nightly adds a suffix, and a broken
    # PHP install prints a fatal instead. Take the first thing that looks like a
    # version and ignore the rest.
    local line token
    while IFS= read -r line; do
        for token in $line; do
            token="${token%,}"
            if [[ "$token" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?$ ]]; then
                WP_CLI_VERSION="$token"
                printf '%s' "$WP_CLI_VERSION"
                return 0
            fi
        done
    done <<<"$out"
    log_debug "could not parse a version from 'wp cli version' (rc=${rc}): ${out}"
    return 1
}

# wpcli_latest_from_wp -> version + update_type from `wp cli check-update`.
# Preferred over the GitHub API because it is WP-CLI's own answer, it knows the
# channel, and it needs no JSON scraping of a third-party response.
WP_LATEST_UPDATE_TYPE=''
wpcli_latest_from_wp() {
    wp_ensure || return 1
    local out tsv rc=0
    local -a argv=("$WP_RESOLVED" cli check-update --format=json)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>/dev/null </dev/null)" || rc=$?
    # Exit 1 means "already the latest", which is an answer, not a failure.
    local body
    body="$(json_array_slice "$out" 2>/dev/null)" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv version update_type 2>/dev/null)" || return 1
    local ver type
    while IFS=$'\t' read -r ver type; do
        [ "$ver" = 'version' ] && continue
        [ -n "$ver" ] || continue
        WP_LATEST_VERSION="$ver"
        WP_LATEST_UPDATE_TYPE="${type:-unknown}"
        WP_LATEST_CHECKED='true'
        return 0
    done <<<"$tsv"
    return 1
}

# wpcli_latest_from_api -> version from the GitHub releases endpoint.
# Used when WP-CLI is absent or too old to have `cli check-update`, and when the
# operator pinned HTTP_CLIENT. Unauthenticated GitHub API requests are limited to
# 60 per hour per address; GITHUB_TOKEN raises that to 5000 and is honoured by
# passing it through when it is already in the environment.
wpcli_latest_from_api() {
    local body tag
    if ! body="$(http_get "$WP_CLI_RELEASE_API" 20)"; then
        log_debug "the release API did not answer: ${WP_CLI_RELEASE_API}"
        return 1
    fi
    tag="$(json_scalar tag_name <<<"$body")" || tag=''
    if [ -z "$tag" ]; then
        log_debug 'the release API answered without a tag_name'
        return 1
    fi
    WP_LATEST_VERSION="${tag#v}"
    WP_LATEST_CHECKED='true'
    return 0
}

# wpcli_latest [FORCE] -> the newest release, empty when it cannot be determined.
# Cached for the whole run: a fleet walk asks once, not once per site.
wpcli_latest() {
    local force="${1:-false}"
    if [ "$force" != 'true' ] && [ -n "$WP_LATEST_VERSION" ]; then
        printf '%s' "$WP_LATEST_VERSION"
        return 0
    fi
    WP_LATEST_VERSION=''
    WP_LATEST_UPDATE_TYPE=''
    if wpcli_latest_from_wp; then :
    elif wpcli_latest_from_api; then :
    else
        return 1
    fi
    printf '%s' "$WP_LATEST_VERSION"
    return 0
}

# wpcli_version_gate : the startup floor check.
#   - no wp at all              -> environment error (3), unless the mode does
#                                  not need one
#   - below WP_CLI_MIN_VERSION  -> environment error (3)
#   - unparsable version        -> warning, run continues (a gate that cannot
#                                    read the answer must not brick the host)
#   - older than the latest     -> warning, run continues
wpcli_version_gate() {
    local installed='' latest='' cmp=''
    # Called bare, not through $(...): the function caches its answer in the
    # WP_CLI_VERSION global, and a command substitution would cache it in a
    # subshell that disappears. The symptom was a run summary that reported an
    # empty wpcli_version even though the gate had just read it successfully.
    if ! wpcli_version_local >/dev/null; then
        if [ -n "$WP_RESOLVED" ]; then
            log_warn "wp-cli at ${WP_RESOLVED} did not report a version; the minimum-version check was skipped"
            return 0
        fi
        return 1
    fi
    installed="$WP_CLI_VERSION"
    log_debug "wp-cli installed version: ${installed} (minimum ${WP_CLI_MIN_VERSION})"
    if [ -n "$WP_CLI_MIN_VERSION" ]; then
        version_compare "$installed" "$WP_CLI_MIN_VERSION" >/dev/null
        if [ "$VERSION_CMP" = '-1' ]; then
            log_error "WP-CLI ${installed} is older than the required minimum ${WP_CLI_MIN_VERSION}"
            log_error "run '${PROG_NAME} --wpcli-update' to bring it up to date, or lower WP_CLI_MIN_VERSION if you know why"
            return 1
        fi
    fi
    if [ "$WP_CLI_LATEST_CHECK" != 'true' ]; then
        return 0
    fi
    if ! latest="$(wpcli_latest)"; then
        log_debug 'the newest WP-CLI release could not be determined (offline, rate limited, or no HTTP client); continuing'
        return 0
    fi
    version_compare "$installed" "$latest" >/dev/null
    if [ "$VERSION_CMP" = '-1' ]; then
        log_warn "WP-CLI ${installed} is behind the current release ${latest}${WP_LATEST_UPDATE_TYPE:+ (${WP_LATEST_UPDATE_TYPE} update)}; run '${PROG_NAME} --wpcli-update'"
    else
        log_debug "WP-CLI ${installed} is current"
    fi
    return 0
}

###############################################################################
# Section 17 - WP-CLI self-update
###############################################################################
#
# Two mechanisms, chosen by what the operator asked for:
#
#   wp cli update        WP-CLI's own updater. It downloads, smoke-tests the new
#                        phar, keeps the previous one as *.old and swaps it in.
#                        Used for channel updates (stable/nightly) and for
#                        patch/minor/major scope. Cannot install a pinned
#                        version, and only works for a phar install.
#
#   direct download      A specific release phar from the wp-cli GitHub release
#                        assets, verified with GPG (preferred) or SHA-512 before
#                        it replaces anything. Used for WP_CLI_TARGET_VERSION,
#                        for --wpcli-install, and as the fallback when the
#                        installed wp is not a phar.
#
# Both keep a timestamped copy of the binary they replaced, and --wpcli-rollback
# puts it back. A self-update with no way back is how a fleet loses its
# maintenance tool at the worst possible moment.

WPCLI_BUILDS_BASE='https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar'
WPCLI_RELEASE_BASE='https://github.com/wp-cli/wp-cli/releases/download'

# wpcli_download_urls VERSION -> phar|asc|sha512 URLs, one per line.
# An empty VERSION means "the moving latest build", which lives in the wp-cli
# builds repository; a pinned version is a GitHub release asset.
wpcli_download_urls() { # VERSION
    local ver="${1-}" name
    if [ -z "$ver" ]; then
        if [ "$WP_CLI_UPDATE_CHANNEL" = 'nightly' ]; then
            name='wp-cli-nightly.phar'
        else
            name='wp-cli.phar'
        fi
        printf 'phar|%s/%s\n' "$WPCLI_BUILDS_BASE" "$name"
        printf 'asc|%s/%s.asc\n' "$WPCLI_BUILDS_BASE" "$name"
        printf 'sha512|%s/%s.sha512\n' "$WPCLI_BUILDS_BASE" "$name"
    else
        name="wp-cli-${ver}.phar"
        printf 'phar|%s/v%s/%s\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
        printf 'asc|%s/v%s/%s.asc\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
        printf 'sha512|%s/v%s/%s.sha512\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
    fi
    return 0
}

# wpcli_verify PHAR WORKDIR -> 0 when the download is authentic.
#
# Fail-closed by design: when WP_CLI_VERIFY_PHAR is on and no verification method
# is available, the answer is "not verified", and the caller refuses to install.
# An unverifiable binary about to be executed as root on every site of a fleet is
# exactly the thing a maintenance tool must not shrug about.
wpcli_verify() { # PHAR WORKDIR
    local phar="${1-}" work="${2-}" kind url asc='' sum='' expected='' got=''
    if [ "$WP_CLI_VERIFY_PHAR" != 'true' ]; then
        log_warn 'phar verification is disabled (WP_CLI_VERIFY_PHAR=false); installing an unverified download'
        return 0
    fi
    while IFS='|' read -r kind url; do
        case "$kind" in
            asc) asc="${work}/phar.asc"
                 download_file "$url" "$asc" 60 || asc='' ;;
            sha512) sum="${work}/phar.sha512"
                    download_file "$url" "$sum" 60 || sum='' ;;
        esac
    done < <(wpcli_download_urls "$WP_CLI_TARGET_VERSION")

    # --- GPG ---------------------------------------------------------------
    if [ -n "$asc" ] && have gpg; then
        local gnupghome="${work}/gnupg"
        mkdir -p -- "$gnupghome" && chmod 700 "$gnupghome"
        local keyfile="${work}/wp-cli.pgp"
        if download_file "${WP_CLI_GPG_KEY_URL}" "$keyfile" 60; then
            if GNUPGHOME="$gnupghome" gpg --batch --quiet --import "$keyfile" >/dev/null 2>&1; then
                local fp=''
                fp="$(GNUPGHOME="$gnupghome" gpg --batch --with-colons --list-keys 2>/dev/null \
                      | awk -F: '/^fpr:/ {print $10; exit}')"
                if [ -n "$WP_CLI_GPG_FINGERPRINT" ] && [ "${fp^^}" != "${WP_CLI_GPG_FINGERPRINT^^//:/}" ]; then
                    log_error "the imported WP-CLI signing key has fingerprint ${fp}, expected ${WP_CLI_GPG_FINGERPRINT}"
                    log_error 'refusing to install: the key that would verify this download is not the published one'
                    return 1
                fi
                if GNUPGHOME="$gnupghome" gpg --batch --quiet --verify "$asc" "$phar" >/dev/null 2>&1; then
                    log_ok "GPG signature verified (fingerprint ${fp:-unknown})"
                    return 0
                fi
                log_error 'the GPG signature does not verify against the downloaded phar'
                return 1
            fi
            log_warn 'the WP-CLI signing key could not be imported; falling back to the checksum'
        else
            log_warn 'the WP-CLI signing key could not be downloaded; falling back to the checksum'
        fi
    elif [ -n "$asc" ]; then
        log_debug 'gpg(1) is not installed; falling back to the checksum'
    fi

    # --- SHA-512 / SHA-256 -------------------------------------------------
    if [ -n "$sum" ] && [ -s "$sum" ]; then
        local tool=''
        if have sha512sum; then tool='sha512sum'
        elif have shasum; then tool='shasum -a 512'
        elif have sha256sum; then tool='sha256sum'; fi
        if [ -n "$tool" ]; then
            # shellcheck disable=SC2086  # $tool is at most two fixed words
            got="$($tool "$phar" 2>/dev/null | awk '{print $1}')"
            expected="$(awk '{print $1; exit}' "$sum" 2>/dev/null)"
            if [ -n "$got" ] && [ "${got,,}" = "${expected,,}" ]; then
                log_ok "checksum verified with ${tool%% *}"
                return 0
            fi
            log_error "checksum mismatch: computed ${got:-<none>}, published ${expected:-<none>}"
            return 1
        fi
    fi

    log_error 'WP_CLI_VERIFY_PHAR is set but neither a GPG signature nor a checksum could be checked'
    log_error 'refusing to install an unverified phar; install gpg(1) or coreutils, or set WP_CLI_VERIFY_PHAR=false'
    return 1
}

# wpcli_backup PHAR -> the path of the timestamped copy, empty when it failed
wpcli_backup() { # PHAR
    local phar="${1-}" stamp dest dir
    [ -n "$phar" ] && [ -f "$phar" ] || return 0
    dir="$(path_dir "$phar")"
    if [ -n "$WP_CLI_BACKUP_DIR" ]; then
        dir="$WP_CLI_BACKUP_DIR"
        mkdir -p -- "$dir" 2>/dev/null || dir="$(path_dir "$phar")"
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    dest="${dir}/$(path_base "$phar").bak-${stamp}"
    if cp -p -- "$phar" "$dest" 2>/dev/null; then
        printf '%s' "$dest"
        return 0
    fi
    return 1
}

# wpcli_smoke_test PHAR -> 0 when the file is a working WP-CLI
wpcli_smoke_test() { # PHAR
    local phar="${1-}" out rc=0 php
    php="${PHP_BIN:-php}"
    if ! have "$php"; then
        log_debug "php binary '${php}' not found; skipping the pre-install smoke test"
        return 0
    fi
    local -a argv=("$phar" cli version)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>&1 </dev/null)" || rc=$?
    if ((rc != 0)); then
        log_error "the downloaded phar does not run: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
        return 1
    fi
    log_debug "downloaded phar reports: $(trim "$out")"
    return 0
}

# wpcli_install_phar DEST WORKDIR : verified, smoke-tested, atomic, reversible.
wpcli_install_phar() { # DEST WORKDIR
    local dest="${1-}" work="${2-}" tmp url kind backup new_version=''
    tmp="${work}/wp-cli.phar"
    while IFS='|' read -r kind url; do
        [ "$kind" = 'phar' ] || continue
        log_info "downloading ${url}"
        if ! download_file "$url" "$tmp" 300; then
            log_error "the download failed: ${url}"
            return 1
        fi
        break
    done < <(wpcli_download_urls "$WP_CLI_TARGET_VERSION")
    [ -s "$tmp" ] || { log_error 'the downloaded phar is empty'; return 1; }

    wpcli_verify "$tmp" "$work" || return 1
    wpcli_smoke_test "$tmp" || return 1

    if [ -f "$dest" ]; then
        if backup="$(wpcli_backup "$dest")"; then
            log_ok "previous binary kept as ${backup}"
        else
            log_warn "could not back up ${dest}; continuing, but there will be no rollback"
        fi
    fi
    # Same filesystem, so the rename is atomic: a reader never sees a half-written
    # wp, and a concurrent run either gets the old binary or the new one.
    local staged="${dest}.new.$$"
    if ! cp -- "$tmp" "$staged" 2>/dev/null; then
        # A different filesystem or an unwritable directory: fall back to writing
        # straight to a temporary name inside the target directory.
        staged="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || {
            log_error "cannot stage the new phar next to ${dest} (permission or filesystem problem)"
            return 1
        }
        cp -- "$tmp" "$staged" 2>/dev/null || { rm -f -- "$staged"; return 1; }
    fi
    chmod 0755 "$staged" 2>/dev/null
    if [ -f "$dest" ]; then
        chown --reference="$dest" -- "$staged" 2>/dev/null ||
            log_debug "could not copy the ownership of ${dest} onto the new phar"
    fi
    if ! mv -f -- "$staged" "$dest" 2>/dev/null; then
        rm -f -- "$staged" 2>/dev/null
        log_error "cannot replace ${dest}; check the permissions of $(path_dir "$dest")"
        return 1
    fi
    WP_RESOLVED='' WP_CLI_VERSION=''
    if new_version="$(wpcli_version_local)"; then
        log_ok "WP-CLI installed: ${new_version} at ${dest}"
    else
        log_warn "installed ${dest} but it does not report a version; check it with --wpcli-check"
    fi
    return 0
}

# wpcli_update_via_wp : let WP-CLI update itself.
wpcli_update_via_wp() {
    local -a argv=() out rc=0 before='' after=''
    before="$(wpcli_version_local)"
    argv=("$WP_RESOLVED" cli update)
    case "$WP_CLI_UPDATE_CHANNEL" in
        nightly) argv+=(--nightly) ;;
        stable) argv+=(--stable) ;;
    esac
    case "$WP_CLI_UPDATE_SCOPE" in
        patch) argv+=(--patch) ;;
        minor) argv+=(--minor) ;;
        major) argv+=(--major) ;;
        auto | *) : ;;   # WP-CLI's own default: newest within the current major
    esac
    [ "$WP_CLI_INSECURE" = 'true' ] && argv+=(--insecure)
    if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ] || [ "$WP_CLI_UPDATE_YES" = 'true' ] || [ ! -t 0 ]; then
        argv+=(--yes)
    fi
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)

    log_info "running: $(argv_display "${argv[@]}")"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info '[dry-run] nothing was changed'
        return 0
    fi
    # GITHUB_TOKEN lifts the unauthenticated 60-requests-per-hour limit on the
    # releases API. It is forwarded when the operator already has it, and never
    # stored, logged or asked for.
    if is_set GITHUB_TOKEN; then
        out="$(GITHUB_TOKEN="$(env_value GITHUB_TOKEN)" "${argv[@]}" 2>&1)" || rc=$?
    else
        out="$("${argv[@]}" 2>&1)" || rc=$?
    fi
    printf '%s\n' "$out" | while IFS= read -r line; do
        [ -n "$line" ] && log_info "  ${line}"
    done
    WP_RESOLVED='' WP_CLI_VERSION=''
    after="$(wpcli_version_local || printf '')"
    if ((rc != 0)); then
        # "already the latest" is reported as a failure by some versions.
        case "$out" in
            *'latest version'* | *'up to date'*)
                log_ok "WP-CLI ${after:-$before} is already the latest release"
                return 0
                ;;
            *'Phar'* | *'phar'*)
                log_warn "'wp cli update' only supports a phar install; falling back to a verified direct download"
                return 2
                ;;
        esac
        log_error "'wp cli update' failed with exit ${rc}"
        log_error_detail 'wpcli-update' "$(argv_display "${argv[@]}")" "$out" "$rc"
        return 1
    fi
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
        log_ok "WP-CLI updated: ${before:-unknown} -> ${after}"
    elif [ -n "$after" ]; then
        log_ok "WP-CLI ${after} is already the latest release"
    else
        log_warn 'the update reported success but the version could not be read back'
    fi
    return 0
}

# mode_wpcli_check : the version report. Read-only, no site list, no lock.
mode_wpcli_check() {
    local installed='' latest='' cmp='' kind='' real='' rc=0 writable='no' phpver=''
    printf '\n%s== wp-cli ==%s\n' "$C_BOLD" "$C_RESET"
    if ! wp_ensure; then
        printf '  %-18s %sNOT FOUND%s\n' 'installed:' "$C_RED" "$C_RESET"
        printf '  %-18s %s\n' 'install with:' "${PROG_NAME} --wpcli-install"
        printf '\n'
        return "$EXIT_ENV"
    fi
    real="$(wp_realpath)"
    kind="$(wp_install_kind)"
    installed="$(wpcli_version_local)" || installed=''
    [ -w "$real" ] && writable='yes'
    if have "${PHP_BIN:-php}"; then
        phpver="$("${PHP_BIN:-php}" -r 'echo PHP_VERSION;' 2>/dev/null | head -n 1)"
    fi

    printf '  %-18s %s\n' 'binary:' "$WP_RESOLVED"
    printf '  %-18s %s\n' 'resolved:' "${real}"
    printf '  %-18s %s\n' 'install kind:' "$kind"
    printf '  %-18s %s\n' 'version:' "${installed:-<unknown>}"
    printf '  %-18s %s\n' 'php:' "${phpver:-<not found>}"
    printf '  %-18s %s\n' 'writable:' "$writable"
    printf '  %-18s %s\n' 'minimum:' "${WP_CLI_MIN_VERSION:-<none>}"

    if [ -z "$installed" ]; then
        printf '  %-18s %s?%s the version could not be read; the floor check was skipped\n' \
            'gate:' "$C_YELLOW" "$C_RESET"
    elif [ -n "$WP_CLI_MIN_VERSION" ]; then
        version_compare "$installed" "$WP_CLI_MIN_VERSION" >/dev/null
        if [ "$VERSION_CMP" = '-1' ]; then
            printf '  %-18s %sFAIL%s %s is below the required %s\n' 'gate:' "$C_RED" "$C_RESET" \
                "$installed" "$WP_CLI_MIN_VERSION"
            rc="$EXIT_ENV"
        else
            printf '  %-18s %sPASS%s %s satisfies %s\n' 'gate:' "$C_GREEN" "$C_RESET" \
                "$installed" "$WP_CLI_MIN_VERSION"
        fi
    else
        printf '  %-18s %sPASS%s no minimum configured\n' 'gate:' "$C_GREEN" "$C_RESET"
    fi

    if [ "$WP_CLI_LATEST_CHECK" = 'true' ] || [ "$WPCLI_ACTION" = 'check' ]; then
        if latest="$(wpcli_latest true)"; then
            printf '  %-18s %s\n' 'newest release:' "$latest"
            version_compare "${installed:-0}" "$latest" >/dev/null
            cmp="$VERSION_CMP"
            if [ -z "$installed" ]; then
                printf '  %-18s %s?%s unknown\n' 'currency:' "$C_YELLOW" "$C_RESET"
            elif [ "$cmp" = '-1' ]; then
                printf '  %-18s %sOUTDATED%s run: %s --wpcli-update\n' 'currency:' "$C_YELLOW" "$C_RESET" "$PROG_NAME"
                [ "$STRICT" = 'true' ] && rc="$EXIT_ERROR"
            else
                printf '  %-18s %sCURRENT%s\n' 'currency:' "$C_GREEN" "$C_RESET"
            fi
            [ -n "$WP_LATEST_UPDATE_TYPE" ] &&
                printf '  %-18s %s\n' 'update type:' "$WP_LATEST_UPDATE_TYPE"
        else
            printf '  %-18s %s\n' 'newest release:' '<could not be determined (offline or rate limited)>'
        fi
    fi

    if [ "$kind" != 'phar' ]; then
        printf '  %-18s %s!%s "wp cli update" only supports a phar; use --wpcli-install to replace it\n' \
            'self-update:' "$C_YELLOW" "$C_RESET"
    elif [ "$writable" != 'yes' ]; then
        printf '  %-18s %s!%s %s is not writable by %s\n' 'self-update:' "$C_YELLOW" "$C_RESET" \
            "$real" "$(id -un)"
    else
        printf '  %-18s %sok%s\n' 'self-update:' "$C_GREEN" "$C_RESET"
    fi
    printf '\n'
    return "$rc"
}

# mode_wpcli_update : bring the wp binary up to date.
mode_wpcli_update() {
    local work rc=0 kind='' before='' after=''
    if [ -n "$WP_CLI_TARGET_VERSION" ] && ! [[ "$WP_CLI_TARGET_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
        usage_error "--wpcli-target-version must look like 2.11.0 (got '${WP_CLI_TARGET_VERSION}')"
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.wpcli.XXXXXX")" || {
        log_error 'cannot create a working directory for the WP-CLI update'
        return "$EXIT_ENV"
    }
    chmod 700 "$work" 2>/dev/null
    tmp_register "$work"

    if ! wp_ensure; then
        if [ "$WPCLI_ACTION" = 'install' ]; then
            log_info "WP-CLI is not installed; installing to ${WP_CLI_PATH}"
            mkdir -p -- "$(path_dir "$WP_CLI_PATH")" 2>/dev/null
            WP_RESOLVED="$WP_CLI_PATH"
            if wpcli_install_phar "$WP_CLI_PATH" "$work"; then return 0; fi
            return "$EXIT_ERROR"
        fi
        log_error 'WP-CLI is not installed; nothing to update'
        log_error "run '${PROG_NAME} --wpcli-install' to install it to ${WP_CLI_PATH}"
        return "$EXIT_ENV"
    fi

    before="$(wpcli_version_local)"
    kind="$(wp_install_kind)"
    log_info "WP-CLI ${before:-<unknown version>} at $(wp_realpath) (install kind: ${kind})"

    if [ -n "$WP_CLI_TARGET_VERSION" ]; then
        if [ "$WP_CLI_TARGET_VERSION" = "$before" ]; then
            log_ok "WP-CLI is already at the requested version ${before}; nothing to do"
            return 0
        fi
        log_info "installing the pinned version ${WP_CLI_TARGET_VERSION} by verified direct download"
        if ! wp_upgradable && [ ! -w "$(path_dir "$(wp_realpath)")" ]; then
            log_error "$(wp_realpath) and its directory are not writable by $(id -un); cannot replace the binary"
            return "$EXIT_ENV"
        fi
        if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
        return "$EXIT_ERROR"
    fi

    if [ "$kind" = 'phar' ] && wp_upgradable; then
        wpcli_update_via_wp
        rc=$?
        if ((rc == 2)); then
            # The updater itself said this is not a phar it can handle.
            if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
            return "$EXIT_ERROR"
        fi
        ((rc == 0)) && return 0
        log_warn "falling back to a verified direct download"
        if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
        return "$EXIT_ERROR"
    fi

    if [ "$kind" != 'phar' ]; then
        log_warn "the installed WP-CLI is a ${kind} install, which 'wp cli update' cannot upgrade"
    else
        log_warn "$(wp_realpath) is not writable by $(id -un); trying a direct download anyway"
    fi
    log_info "installing the newest ${WP_CLI_UPDATE_CHANNEL} build by verified direct download"
    if wpcli_install_phar "$WP_CLI_PATH" "$work"; then return 0; fi
    return "$EXIT_ERROR"
}

# mode_wpcli_rollback : put the previous binary back.
#
# `wp cli update` keeps its own copy as <phar>.old; this tool keeps a
# timestamped one. Both are offered, newest first, because the operator who is
# rolling back is doing it under pressure and should not have to remember which
# mechanism produced the file.
mode_wpcli_rollback() {
    local real target='' f best='' best_ts=0 ts
    local -a candidates=()
    wp_ensure || real="${WP_CLI_PATH}"
    real="$(wp_realpath)"
    while IFS= read -r f; do
        [ -n "$f" ] && candidates+=("$f")
    done < <(
        {
            [ -f "${real}.old" ] && printf '%s\n' "${real}.old"
            find "$(path_dir "$real")" -maxdepth 1 -name "$(path_base "$real").bak-*" -print 2>/dev/null
            [ -n "$WP_CLI_BACKUP_DIR" ] && [ -d "$WP_CLI_BACKUP_DIR" ] &&
                find "$WP_CLI_BACKUP_DIR" -maxdepth 1 -name '*.bak-*' -print 2>/dev/null
        } | sort -r
    )
    if ((${#candidates[@]} == 0)); then
        log_error "no previous WP-CLI binary was found next to ${real}"
        log_error 'looked for <binary>.old and <binary>.bak-<timestamp>'
        return "$EXIT_ERROR"
    fi
    printf '\n%s== rollback candidates ==%s\n' "$C_BOLD" "$C_RESET"
    local i=0
    for f in ${candidates[@]+"${candidates[@]}"}; do
        i=$((i + 1))
        printf '  %2d) %-56s %s\n' "$i" "$f" "$(human_bytes "$(file_size "$f")")"
    done
    printf '\n'
    target="${candidates[0]}"
    if [ -n "$RESTORE_FROM" ]; then
        if is_uint "$RESTORE_FROM" && ((RESTORE_FROM >= 1)) && ((RESTORE_FROM <= ${#candidates[@]})); then
            target="${candidates[$((RESTORE_FROM - 1))]}"
        elif [ -f "$RESTORE_FROM" ]; then
            target="$RESTORE_FROM"
        else
            log_error "--from '${RESTORE_FROM}' is neither a listed number nor an existing file"
            return "$EXIT_USAGE"
        fi
    fi
    log_info "rolling back to ${target}"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: install -m 0755 $(sh_quote "$target") $(sh_quote "$real")"
        return 0
    fi
    if ! wpcli_smoke_test "$target"; then
        log_error "the rollback candidate does not run; refusing to install it"
        return "$EXIT_ERROR"
    fi
    local backup
    if backup="$(wpcli_backup "$real")"; then
        log_debug "the current binary was kept as ${backup}"
    fi
    if ! install -m 0755 -- "$target" "$real" 2>/dev/null; then
        if ! cp -p -- "$target" "$real" 2>/dev/null; then
            log_error "cannot write ${real}"
            return "$EXIT_ERROR"
        fi
        chmod 0755 "$real" 2>/dev/null
    fi
    WP_RESOLVED='' WP_CLI_VERSION=''
    log_ok "WP-CLI rolled back to $(wpcli_version_local || printf '<unknown version>')"
    return 0
}

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

###############################################################################
# Section 19 - site inventory
###############################################################################
#
# The site list is the most dangerous input this tool accepts: everything in it
# will be modified, as root's delegate, on a schedule. The rules below all come
# from that fact.
#
#   - One absolute path per line. Blank lines and `#` comments are ignored, a
#     trailing CR is tolerated, leading and trailing whitespace is trimmed.
#   - An owner may be forced per line by appending a TAB and the user name. TAB,
#     not space: a directory whose name contains a space is unusual but legal,
#     and splitting on whitespace would silently rewrite the path -- which turns
#     "site updated" into "site skipped, not a directory" with nothing in the log
#     to explain why.
#   - An entry that is not a directory is skipped with a warning, never
#     silently: "site updated" and "site vanished" must not look the same.
#   - An existing but EMPTY list is a statement, not an accident. Discovery is
#     not run over it. Scanning the default web roots and then updating whatever
#     turns up is the one surprise a maintenance tool must never produce.

SITES=()
declare -A SITE_FORCED_USER=()

# A single tab character, named once at load time. `printf -v` is a builtin, so
# this costs no process; writing the byte literally in the source is how the
# previous revision lost the owner column, because a raw tab is invisible in a
# diff and some editors and tools silently normalise it away.
TAB=''
printf -v TAB '\t'

# parse_site_line LINE -> fills PARSED_PATH / PARSED_USER, non-zero for lines
# that carry no entry (blank or comment).
PARSED_PATH=''
PARSED_USER=''
parse_site_line() {
    local line="${1-}"
    line="${line%$'\r'}"
    # trim leading and trailing whitespace, but never inside the path
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    PARSED_PATH='' PARSED_USER=''
    [ -n "$line" ] || return 1
    case "$line" in
        '#'*) return 1 ;;
    esac
    if [[ "$line" == *"$TAB"* ]]; then
        PARSED_PATH="${line%%"$TAB"*}"
        PARSED_USER="${line#*"$TAB"}"
        # trim sets TRIMMED as well as printing, so this costs no subshell per
        # field; the site list can hold a few hundred lines.
        trim "$PARSED_PATH"; PARSED_PATH="$TRIMMED"
        # Anything after a second TAB is a comment in the operator's own format.
        PARSED_USER="${PARSED_USER%%"$TAB"*}"
        trim "$PARSED_USER"; PARSED_USER="$TRIMMED"
    else
        PARSED_PATH="$line"
    fi
    [ -n "$PARSED_PATH" ] || return 1
    return 0
}

INCLUDE_GLOBS=()
EXCLUDE_GLOBS=()

# site_filter_verdict PATH -> 0 process, 1 skip (reason at debug level).
# Exclude wins over include: an operator who whitelists a tree and then
# blacklists one site inside it means the blacklist.
site_filter_verdict() {
    local site="${1-}"
    if ((${#EXCLUDE_GLOBS[@]} > 0)) && any_glob_match "$site" "${EXCLUDE_GLOBS[@]}"; then
        log_debug "excluded by --exclude: ${site}"
        return 1
    fi
    if ((${#INCLUDE_GLOBS[@]} > 0)) && ! any_glob_match "$site" "${INCLUDE_GLOBS[@]}"; then
        log_debug "not matched by --include: ${site}"
        return 1
    fi
    return 0
}

# load_site_list FILE : fill SITES[] and SITE_FORCED_USER[].
# Reading the file and resolving owners are separate steps: the list can be read
# and printed (--list-sites) on a host with no wp binary and no root.
# FILE may be '-', which reads the list from stdin.
load_site_list() { # FILE
    local file="${1-}" line
    SITES=()
    SITE_FORCED_USER=()
    if [ "$file" = '-' ]; then
        SITES_FROM_STDIN='true'
        while IFS= read -r line || [ -n "$line" ]; do
            parse_site_line "$line" || continue
            SITES+=("$PARSED_PATH")
            [ -n "$PARSED_USER" ] && SITE_FORCED_USER["$PARSED_PATH"]="$PARSED_USER"
        done
        log_debug "site list read from stdin (${#SITES[@]} entries)"
        SITES_FILE_RESOLVED='<stdin>'
        return 0
    fi
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
        parse_site_line "$line" || continue
        SITES+=("$PARSED_PATH")
        [ -n "$PARSED_USER" ] && SITE_FORCED_USER["$PARSED_PATH"]="$PARSED_USER"
    done <"$file"
    SITES_FILE_RESOLVED="$file"
    log_debug "site list ${file}: ${#SITES[@]} entries"
    return 0
}

# ensure_site_list : create the list by discovery when it is genuinely missing.
ensure_site_list() {
    [ "$SITES_FILE" = '-' ] && return 0
    if [ -f "$SITES_FILE" ] && [ -s "$SITES_FILE" ]; then return 0; fi
    if [ -f "$SITES_FILE" ]; then
        log_warn "site list ${SITES_FILE} exists but is empty; not running discovery"
        return 1
    fi
    if [ "$AUTO_DISCOVER" != 'true' ]; then
        log_error "site list ${SITES_FILE} is missing and AUTO_DISCOVER is off"
        return 1
    fi
    if [ ! -f "$DISCOVER_SCRIPT" ]; then
        log_error "site list ${SITES_FILE} is missing, and the discovery script ${DISCOVER_SCRIPT} is not there"
        return 1
    fi
    path_base "$DISCOVER_SCRIPT" >/dev/null
    log_info "site list missing; running discovery: ${PATH_BASE}"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: bash ${DISCOVER_SCRIPT} --output ${SITES_FILE} ${DISCOVER_ROOTS}"
        return 1
    fi
    local rc=0 root
    local -a argv=(bash "$DISCOVER_SCRIPT" --output "$SITES_FILE" --color "$COLOR")
    [ "$VERBOSE" = 'true' ] || argv+=(--quiet)
    for root in $DISCOVER_ROOTS; do
        [ -d "$root" ] && argv+=("$root")
    done
    # The finder is started with an explicit `bash`, never through its shebang: a
    # host whose `bash` in PATH is older than the one running this script would
    # otherwise make auto-discovery fail with a confusing syntax error.
    "${argv[@]}" || rc=$?
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
# Section 20 - work units (path, user, url) and multisite expansion
###############################################################################
#
# A work unit is one (path, user, url) triple. The fleet is a list of units, not
# a list of paths: a multisite installation expands into one unit per subsite,
# and `--url` becomes a property of the unit instead of a global that every mode
# has to remember to pass on. Every mode function takes (SITE USER URL) for the
# same reason.

units_reset() {
    UNIT_PATH=() UNIT_USER=() UNIT_URL=() UNIT_LABEL=()
    UNIT_COUNT=0
    SITE_USER=()
    return 0
}

# units_add PATH USER URL LABEL
units_add() {
    UNIT_PATH+=("$1")
    UNIT_USER+=("$2")
    UNIT_URL+=("$3")
    UNIT_LABEL+=("${4:-$1}")
    SITE_USER["$1"]="$2"
    UNIT_COUNT=$((UNIT_COUNT + 1))
    return 0
}

# site_subsite_urls SITE USER -> one URL per line for a multisite installation.
# Non-zero when the installation is not a multisite, when WP-CLI is too old for
# `site list`, or when the query failed. Nothing here may ever abort a run: a
# site that cannot answer "how many subsites do you have?" is still a site worth
# updating, as the main site.
site_subsite_urls() { # SITE USER
    local site="$1" user="$2" body tsv id url found=0
    wp_data "$site" "$user" '' site list --fields=blog_id,url --format=json 2>/dev/null
    [ "$WP_SKIPPED" = 'true' ] && return 1
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT" 2>/dev/null)" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv blog_id url 2>/dev/null)" || return 1
    while IFS="$TAB" read -r id url; do
        [ "$id" = 'blog_id' ] && continue
        [ -n "$url" ] || continue
        case "$url" in
            http://* | https://*) ;;
            *) continue ;;
        esac
        printf '%s\n' "${url%/}"
        found=1
    done <<<"$tsv"
    ((found)) || return 1
    return 0
}

# units_build : turn SITES[] into the unit list.
#
# Three separate concerns meet here, and keeping them in one function in this
# order is what makes it auditable: the include/exclude filters (free, run
# first), owner resolution (one stat per site, run second), and multisite
# expansion (a WP-CLI call per site, run last and only when asked for).
units_build() {
    local site user url expanded skipped=0
    units_reset
    for site in ${SITES[@]+"${SITES[@]}"}; do
        if ((MAX_SITES > 0)) && ((UNIT_COUNT >= MAX_SITES)); then
            log_warn "--max-sites=${MAX_SITES} reached; the remaining entries are not processed"
            break
        fi
        if ! site_filter_verdict "$site"; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ ! -d "$site" ]; then
            log_warn "skipping, not a directory: ${site}"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        if ! is_wordpress_root "$site"; then
            log_warn "skipping, not a WordPress root (no wp-config.php, wp-load.php or wp-includes/version.php): ${site}"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        user="${SITE_FORCED_USER[$site]-}"
        if [ -n "$user" ]; then
            if ! is_valid_username "$user" || ! id -u "$user" >/dev/null 2>&1; then
                log_error "skipping ${site}: the owner named in the site list is not a valid account: ${user}"
                STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
                continue
            fi
            log_debug "${site}: owner ${user} taken from the site list"
        elif ! user="$(site_user_resolve "$site")"; then
            log_error "skipping ${site}: cannot determine the site owner (fix the ownership, name it in the list after a TAB, or pass --user NAME)"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        if [ "$MULTISITE" = 'all' ]; then
            expanded=0
            while IFS= read -r url; do
                [ -n "$url" ] || continue
                path_base "$site" >/dev/null
                units_add "$site" "$user" "$url" "${PATH_BASE} ${url}"
                expanded=1
            done < <(site_subsite_urls "$site" "$user")
            if ((expanded)); then
                log_debug "${site}: expanded into subsites (MULTISITE=all)"
                continue
            fi
            log_debug "${site}: MULTISITE=all but no subsite list came back; treating it as a single site"
        fi
        path_base "$site" >/dev/null
        units_add "$site" "$user" "$URL" "$PATH_BASE"
    done
    if ((skipped > 0)); then
        log_debug "${skipped} entr(y/ies) filtered out by --include / --exclude"
    fi
    return 0
}

# is_wordpress_root DIR -> 0 when DIR looks like a WordPress installation.
# Accepting wp-config.php, wp-load.php or wp-includes/version.php is deliberate:
# a Bedrock-style layout has no wp-load.php in the root, and a half-extracted
# archive may have no wp-config.php yet. The check exists to stop the tool from
# running `wp --path=/var/www` against a directory that merely contains one site
# somewhere below it.
is_wordpress_root() {
    local dir="${1-}"
    [ -d "$dir" ] || return 1
    [ -f "${dir}/wp-load.php" ] && return 0
    [ -f "${dir}/wp-config.php" ] && return 0
    [ -f "${dir}/wp-includes/version.php" ] && return 0
    return 1
}

# wp_config_path SITE -> the wp-config.php that belongs to this site.
# WordPress allows it one level up, and Bedrock puts it somewhere else again;
# both are handled, because a security audit that reports "no wp-config" for a
# correctly configured site teaches the operator to ignore the audit.
wp_config_path() {
    local site="${1-}" up
    if [ -f "${site}/wp-config.php" ]; then
        printf '%s' "${site}/wp-config.php"
        return 0
    fi
    up="${site%/}"
    up="${up%/*}"
    if [ -n "$up" ] && [ -f "${up}/wp-config.php" ]; then
        printf '%s' "${up}/wp-config.php"
        return 0
    fi
    return 1
}

# wp_config_constant FILE NAME -> the literal value of a define(), or empty.
# Read with a bash regex; the result is only ever compared or logged, never
# executed, never passed to a shell.
wp_config_constant() { # FILE NAME
    local cfg="${1-}" name="${2-}" line value
    [ -r "$cfg" ] || return 1
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *"$name"*) ;;
            *) continue ;;
        esac
        if [[ "$line" =~ define\([[:space:]]*[\'\"]${name}[\'\"][[:space:]]*,[[:space:]]*[\'\"]([^\'\"]*)[\'\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
        if [[ "$line" =~ define\([[:space:]]*[\'\"]${name}[\'\"][[:space:]]*,[[:space:]]*(true|false|TRUE|FALSE|null|NULL|[0-9]+)[[:space:]]*\) ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$cfg"
    return 1
}

# site_home SITE USER -> the site's home URL, cached per site.
# The smoke test and the report both need it, and asking twice per site doubles
# the number of WordPress boots for no reason.
SITE_HOME_CACHE=''
SITE_HOME_CACHE_FOR=''
site_home() { # SITE USER
    local site="$1" user="$2"
    if [ "$SITE_HOME_CACHE_FOR" = "$site" ]; then
        printf '%s' "$SITE_HOME_CACHE"
        return 0
    fi
    SITE_HOME_CACHE=''
    SITE_HOME_CACHE_FOR="$site"
    if wp_probe "$site" "$user" '' option get home; then
        case "$WP_PROBE" in
            http://* | https://*) SITE_HOME_CACHE="$WP_PROBE" ;;
        esac
    fi
    printf '%s' "$SITE_HOME_CACHE"
    return 0
}

# print_site_list : what would be processed, without processing it.
#
# Resolving the list is the half of a fleet run that can go wrong quietly: an
# owner that cannot be determined, a directory that vanished, a filter that
# matched nothing. This prints the resolved result -- including the units a
# multisite expands into -- and exits, so it can be diffed before a change and
# after it.
print_site_list() {
    local i sink tsv=''
    if [ -z "$TARGET_SITE" ]; then
        if ! ensure_site_list; then
            if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
                log_error "no site list to work from: ${SITES_FILE}"
                return 1
            fi
        fi
        load_site_list "$SITES_FILE" || return 1
    else
        SITES=("$TARGET_SITE")
        SITE_FORCED_USER=()
        [ -n "$SITE_USER" ] && SITE_FORCED_USER["$TARGET_SITE"]="$SITE_USER"
    fi
    units_build
    printf '%s (%s unit(s), source: %s)\n' \
        "${C_BOLD}resolved work list${C_RESET}" "$UNIT_COUNT" \
        "$([ -n "$TARGET_SITE" ] && printf -- '--site' || printf '%s' "$SITES_FILE")" >&2

    data_sink
    sink="$DATA_SINK"
    case "$OUTPUT_FORMAT" in
        json)
            local jp jo ju jk
            for ((i = 0; i < UNIT_COUNT; i++)); do
                json_escape "${UNIT_PATH[i]}"; jp="$JSON_ESCAPED"
                json_escape "${UNIT_USER[i]}"; jo="$JSON_ESCAPED"
                json_escape "${UNIT_URL[i]}"; ju="$JSON_ESCAPED"
                if [ -n "${UNIT_URL[i]}" ]; then jk='subsite'; else jk='site'; fi
                printf '{"path":"%s","owner":"%s","url":"%s","kind":"%s"}\n' \
                    "$jp" "$jo" "$ju" "$jk" | sink_write "$sink"
            done
            ;;
        *)
            tsv="PATH${TAB}OWNER${TAB}URL${TAB}KIND"
            for ((i = 0; i < UNIT_COUNT; i++)); do
                if [ -n "${UNIT_URL[i]}" ]; then
                    tsv+=$'\n'"${UNIT_PATH[i]}${TAB}${UNIT_USER[i]}${TAB}${UNIT_URL[i]}${TAB}subsite"
                else
                    tsv+=$'\n'"${UNIT_PATH[i]}${TAB}${UNIT_USER[i]}${TAB}<main>${TAB}site"
                fi
            done
            render_tsv "$tsv" "$PAGE_LIMIT" "$sink"
            ;;
    esac
    if ((STATS_SITES_SKIPPED > 0)); then
        printf 'skipped: %s (see the warnings above)\n' "$STATS_SITES_SKIPPED" >&2
    fi
    return 0
}

###############################################################################
# Section 21 - backups
###############################################################################
#
# A maintenance tool that changes 200 databases and cannot undo any of them is a
# tool nobody will schedule. Two modes are offered and the difference matters:
#
#   db    `wp db export` -- seconds, and it covers everything the modes in this
#         script actually change;
#   full  a tar.gz of the whole installation -- complete, and on a site with a
#         large wp-content/uploads it can be tens of gigabytes and many minutes.
#
# `full` is opt-in and the tool says out loud how big the tree is before
# archiving it. Backups are off by default: silently writing a database dump per
# site per run fills disks that nobody monitors, and a full disk takes down the
# sites the run was supposed to protect.
#
# The rule that follows from all of it: a failed backup skips the site. Updating
# unprotected after being asked to take a backup is the one outcome worse than
# not updating.

# backup_dir_of -> sets BACKUP_ROOT and prints it: the configured root, or
# <script dir>/backups.
BACKUP_ROOT=''
backup_dir_of() {
    if [ -n "$BACKUP_DIR" ]; then
        BACKUP_ROOT="$BACKUP_DIR"
    else
        BACKUP_ROOT="${SCRIPT_DIR}/backups"
    fi
    printf '%s' "$BACKUP_ROOT"
    return 0
}

# site_backup_dir SITE -> one directory per site.
# Named after the site directory with everything outside a safe set replaced, so
# two sites both called `www` share a folder; the file names carry a timestamp
# and the kind, so nothing is lost and nothing is overwritten.
# site_backup_dir SITE -> sets SITE_BACKUP_DIR and prints it. Fork-free: it is
# consulted per site by every backup, prune and restore path.
SITE_BACKUP_DIR=''
site_backup_dir() { # SITE
    local name
    path_base "${1-}" >/dev/null
    name="${PATH_BASE//[^A-Za-z0-9._-]/_}"
    [ -n "$name" ] || name='_'
    backup_dir_of >/dev/null
    SITE_BACKUP_DIR="${BACKUP_ROOT}/${name}"
    printf '%s' "$SITE_BACKUP_DIR"
    return 0
}

# backup_ensure_dir DIR [USER]
#
# The manager creates this directory, but `wp db export` writes into it as the
# site owner after the user switch. A plain mkdir gives it the manager's umask --
# 0750 root, after the umask 077 at the top of this file -- and the export then
# dies with "Permission denied", which reads as "the database backup failed" and
# hides the real cause.
#
# The right answer is a directory owned by the site user, which is what happens
# when this runs as root: 0750 and chown, so a dump containing every password
# hash on the site is not readable by the neighbours. When chown is not
# available, the fallback is 1777 with the sticky bit -- exactly like /tmp: any
# local user may create a file inside, and the sticky bit stops one user from
# deleting or renaming another user's dump. The fallback is a compromise and the
# log says so.
backup_ensure_dir() { # DIR [USER]
    local dir="${1-}" user="${2-}"
    [ -n "$dir" ] || return 1
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        return 1
    fi
    if [ -n "$user" ] && [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        if chown -- "$user" "$dir" 2>/dev/null; then
            chmod 0750 "$dir" 2>/dev/null
            return 0
        fi
        log_debug "cannot chown ${dir} to ${user}; falling back to a sticky shared directory"
    fi
    chmod 1777 "$dir" 2>/dev/null
    return 0
}

# prune_backups DIR
#
# Keep the newest KEEP_BACKUPS of each kind. Sorting is done with stat(1) and
# `sort -rn` rather than `find -printf`, because -printf is a GNU extension and
# the fallback has to work on the hosts where the rest of this tool already
# degrades. `ls -1t` is not used either: its output is locale- and
# width-dependent and breaks on names with spaces.
prune_backups() { # DIR
    local dir="${1-}" keep="${KEEP_BACKUPS:-0}" f ts i=0
    ((keep > 0)) || return 0
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i + 1))
        if ((i > keep)); then
            if rm -f -- "$f" 2>/dev/null; then
                log_debug "backup pruned: $(path_base "$f")"
            fi
        fi
    done < <(
        find "$dir" -maxdepth 1 -type f \
            \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
            -print0 2>/dev/null |
            while IFS= read -r -d '' ts; do
                printf '%s %s\n' "$(stat -c '%Y' -- "$ts" 2>/dev/null || printf 0)" "$ts"
            done | sort -rn | cut -d' ' -f2-
    )
    return 0
}

# backup_space_ok DIR SITE -> 0 when there is room for the dump.
# A dump written onto a full filesystem is truncated, and a truncated dump looks
# exactly like a backup until the moment it is needed. Estimating "the database
# is at most as big as the site tree" is crude and deliberately so: the point is
# to catch "the volume has 40 MiB left", not to be precise.
backup_space_ok() { # DIR SITE
    local dir="${1-}" site="${2-}" need have
    ((MIN_FREE_MIB > 0)) || return 0
    ensure_parent_dir "${dir}/.probe" 2>/dev/null
    have="$(free_mib "$dir")" || have=0
    need="$MIN_FREE_MIB"
    if ((have < need)); then
        log_error "only ${have} MiB free on $(df -P -- "$dir" 2>/dev/null | awk 'NR==2 {print $1}'); MIN_FREE_MIB asks for ${need}"
        return 1
    fi
    log_debug "free space check: ${have} MiB available, ${need} MiB required"
    return 0
}

# backup_database SITE USER -> 0 when a usable dump exists.
backup_database() { # SITE USER
    local site="$1" user="$2" dir file stamp rc=0 size=0
    local saved="$TIMEOUT"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would export the database of ${site}"
        return 0
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$user"; then
        log_error "cannot create the backup directory ${dir}"
        return 1
    fi
    if ! backup_space_ok "$dir" "$site"; then
        return 1
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/db-${stamp}.sql"
    # The dump must not be killed by the per-command timeout: a large database
    # takes longer than a plugin update, and a truncated dump is worse than no
    # dump because it looks like a backup.
    TIMEOUT=0
    info_wp "$site" "$user" '' db export "$file"
    rc="$WP_STATUS"
    TIMEOUT="$saved"
    if ((rc != 0)) || [ ! -s "$file" ]; then
        log_error "database backup failed for ${site} (wp exit ${rc})"
        [ -n "$WP_OUTPUT" ] && log_error_detail 'backup_database' 'wp db export' "$WP_OUTPUT" "$rc"
        rm -f -- "$file" 2>/dev/null
        return 1
    fi
    # A dump that mysqld finished carries its own marker. Checking for it is the
    # difference between "a file appeared" and "the database was exported", and
    # it costs one tail.
    if have tail && ! tail -c 4096 -- "$file" 2>/dev/null | grep -q 'Dump completed'; then
        log_warn "${file} has no 'Dump completed' marker; the export may be truncated"
    fi
    chmod 0640 "$file" 2>/dev/null
    if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        chown -- "$user" "$file" 2>/dev/null
    fi
    size="$(file_size "$file")"
    LAST_BACKUP_DB="$file"
    STATS_BACKUPS=$((STATS_BACKUPS + 1))
    log_ok "database backup: ${file} ($(human_bytes "$size"))"
    prune_backups "$dir"
    return 0
}

# backup_site_tree SITE USER -> 0 when an archive exists
backup_site_tree() { # SITE USER
    local site="$1" user="$2" dir file stamp size rc=0
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would archive the whole tree of ${site}"
        return 0
    fi
    if ! have tar; then
        if [ "$WARNED_NO_TAR" = 'false' ]; then
            log_warn 'tar(1) not found; --backup full degrades to a database dump'
            WARNED_NO_TAR='true'
        fi
        backup_database "$site" "$user"
        return $?
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$user"; then
        log_error "cannot create the backup directory ${dir}"
        return 1
    fi
    if ! backup_space_ok "$dir" "$site"; then
        return 1
    fi
    size="$(dir_kib "$site")"
    if [ -n "$size" ] && ((size > 1048576)); then
        log_warn "${site} is $((size / 1024)) MiB; --backup full will take a while and a lot of disk"
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/site-${stamp}.tar.gz"
    # --warning=no-file-changed: a live uploads directory changes while it is
    # archived, and tar reports that as an error. It is not one; the archive is
    # still a valid recovery point for everything that was stable.
    if tar --warning=no-file-changed -czf "$file" \
            -C "$(path_dir "$site")" "$(path_base "$site")" 2>/dev/null; then
        :
    else
        rc=$?
        # 1 = "some files differ/vanished", which for a live site is normal.
        if ((rc != 1)) || [ ! -s "$file" ]; then
            log_error "site archive failed for ${site} (tar exit ${rc})"
            rm -f -- "$file" 2>/dev/null
            return 1
        fi
        log_debug "tar reported changed files while archiving ${site} (exit 1); the archive is usable"
    fi
    chmod 0640 "$file" 2>/dev/null
    if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        chown -- "$user" "$file" 2>/dev/null
    fi
    STATS_BACKUPS=$((STATS_BACKUPS + 1))
    log_ok "site archive: ${file} ($(human_bytes "$(file_size "$file")"))"
    prune_backups "$dir"
    return 0
}

# maybe_backup SITE USER : the pre-flight step of process_site.
maybe_backup() { # SITE USER
    local site="$1" user="$2"
    LAST_BACKUP_DB=''
    case "$BACKUP" in
        db) backup_database "$site" "$user" || return 1 ;;
        full) backup_site_tree "$site" "$user" || return 1 ;;
        off | *) return 0 ;;
    esac
    return 0
}

# backup_plugin SITE SLUG
#
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
        log_warn "tar(1) not found; ${slug} will be deleted without a file backup"
        return 0
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$CURRENT_USER"; then
        log_warn "cannot create the backup directory; deleting without a file backup"
        return 0
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would archive ${src} into ${dir}"
        return 0
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/plugin-${slug//[^A-Za-z0-9._-]/_}-${stamp}.tar.gz"
    if tar --warning=no-file-changed -czf "$file" -C "${site}/wp-content/plugins" "$slug" 2>/dev/null; then
        chmod 0640 "$file" 2>/dev/null
        log_ok "plugin backup: ${file}"
        prune_backups "$dir"
    else
        log_warn "plugin backup failed for ${slug}; deleting anyway, because that is what was asked"
        rm -f -- "$file" 2>/dev/null
    fi
    return 0
}

###############################################################################
# Section 22 - restore
###############################################################################
#
# Recovery is a manual decision, so this is a manual tool: it lists what exists,
# takes a fresh dump before it overwrites anything, and refuses to run without an
# explicit --yes. There is deliberately no automatic rollback after a failed
# update -- restoring a database whose core files were already replaced leaves a
# site in a state that never existed, which is worse than the failure it was
# meant to fix.

# backups_list SITE -> one path per line, newest first
backups_list() { # SITE
    local dir f
    site_backup_dir "${1-}" >/dev/null; dir="$SITE_BACKUP_DIR"
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && printf '%s\n' "$f"
    done < <(
        find "$dir" -maxdepth 1 -type f \
            \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
            -print0 2>/dev/null |
            while IFS= read -r -d '' f; do
                printf '%s %s\n' "$(stat -c '%Y' -- "$f" 2>/dev/null || printf 0)" "$f"
            done | sort -rn | cut -d' ' -f2-
    )
    return 0
}

# looks_like_sql_dump FILE -> 0 when the file is plausibly a mysqldump.
# Importing the wrong file into a production database is unrecoverable, so the
# check is deliberately shallow and cheap: read the head, look for what mysqldump
# always writes, and refuse anything else.
looks_like_sql_dump() { # FILE
    local f="${1-}" head
    [ -s "$f" ] || return 1
    case "$f" in
        *.gz)
            have zcat || return 1
            head="$(zcat -- "$f" 2>/dev/null | head -c 2048)"
            ;;
        *) head="$(head -c 2048 -- "$f" 2>/dev/null)" ;;
    esac
    case "$head" in
        *'MySQL dump'* | *'MariaDB dump'* | *'phpMyAdmin SQL Dump'*) return 0 ;;
        *'CREATE TABLE'* | *'INSERT INTO'* | *'DROP TABLE IF EXISTS'*) return 0 ;;
    esac
    return 1
}

# mode_restore SITE USER : list or restore.
mode_restore() { # SITE USER
    local site="$1" user="$2" target='' i=0
    local -a found=()
    while IFS= read -r target; do
        [ -n "$target" ] && found+=("$target")
    done < <(backups_list "$site")

    if ((${#found[@]} == 0)); then
        site_backup_dir "$site" >/dev/null
        log_error "no backups were found for ${site} in ${SITE_BACKUP_DIR}"
        log_error "run with --backup db (or full) first, or point --from at an existing file"
        return 1
    fi
    if [ -z "$RESTORE_FROM" ]; then
        printf '\n%s== backups for %s ==%s\n' "$C_BOLD" "$site" "$C_RESET"
        for target in ${found[@]+"${found[@]}"}; do
            i=$((i + 1))
            printf '  %2d) %-46s %10s  %s\n' "$i" "$(path_base "$target")" \
                "$(human_bytes "$(file_size "$target")")" \
                "$(date -r "$target" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
        done
        printf '\n  newest: %s\n\n' "${found[0]}"
        printf 'restore with: %s --restore -S %s --from <number|path> --yes\n' \
            "$PROG_NAME" "$(sh_quote "$site")"
        return 0
    fi

    target="$RESTORE_FROM"
    if is_uint "$target" && ((target >= 1)) && ((target <= ${#found[@]})); then
        target="${found[$((target - 1))]}"
    elif [ ! -f "$target" ]; then
        log_error "--from '${RESTORE_FROM}' is neither a listed number nor an existing file"
        return 1
    fi
    if [ ! -r "$target" ]; then
        log_error "the backup is not readable by $(id -un): ${target}"
        return 1
    fi

    case "$target" in
        *'site-'*.tar.gz)
            if [ "$RESTORE_FILES" != 'true' ]; then
                log_error "${target##*/} is a whole-tree archive; restoring it needs --restore-files"
                log_error 'it overwrites wp-content, so the site should be offline while it runs'
                return 1
            fi
            restore_tree "$site" "$user" "$target"
            return $?
            ;;
        *'plugin-'*.tar.gz)
            if [ "$RESTORE_FILES" != 'true' ]; then
                log_error "${target##*/} is a plugin archive; restoring it needs --restore-files"
                return 1
            fi
            restore_tree "$site" "$user" "$target" "${site}/wp-content/plugins"
            return $?
            ;;
    esac

    if ! looks_like_sql_dump "$target"; then
        log_error "${target##*/} does not look like a SQL dump; refusing to import it"
        log_error 'a database import cannot be undone, so the file has to be recognisable'
        return 1
    fi
    restore_database "$site" "$user" "$target"
    return $?
}

# confirm_destructive PROMPT : the one interactive gate for irreversible work.
# A fleet run is normally unattended, so the rule is: with --yes the operator has
# already answered; without it a terminal is required, and a cron job with no
# terminal is refused rather than left hanging on a prompt nobody will see.
confirm_destructive() { # PROMPT
    local prompt="$1" answer
    if [ "$FORCE_DELETE" = 'true' ] || [ "$ASSUME_YES" = 'true' ]; then return 0; fi
    if [ ! -t 0 ]; then
        log_error "refusing to run '${prompt}' without a terminal; pass --yes to confirm explicitly"
        return 1
    fi
    printf '%s%s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RESET" >&2
    IFS= read -r answer || answer=''
    case "${answer,,}" in
        y | yes) return 0 ;;
    esac
    log_warn 'cancelled by the operator'
    return 1
}

restore_database() { # SITE USER FILE
    local site="$1" user="$2" file="$3"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would import ${file} into ${site}"
        return 0
    fi
    if ! confirm_destructive "import ${file##*/} into the database of ${site}? This overwrites every table."; then
        return 1
    fi
    if [ "$BACKUP_BEFORE_RESTORE" = 'true' ]; then
        log_info 'taking a dump of the current database before the restore'
        if ! backup_database "$site" "$user"; then
            log_error 'the pre-restore dump failed; refusing to overwrite a database with no way back'
            log_error 'pass --no-backup to override, once you understand what that means'
            return 1
        fi
    fi
    # The dump is readable by root; the import runs as the site user, so the file
    # has to be readable by that account for the duration of one call.
    local restore_as_root='false'
    if [ "$(id -u)" -eq 0 ] && [ ! -r "$file" ]; then
        restore_as_root='true'
    fi
    if [ -n "$user" ] && [ "$(id -u)" -eq 0 ] && [ "$(file_owner "$file")" != "$user" ]; then
        chmod 0644 "$file" 2>/dev/null
    fi
    if run_wp "$site" "$user" '' db import "$file"; then
        log_ok "database restored on ${site} from ${file}"
        run_wp_soft "$site" "$user" '' cache flush >/dev/null
        return 0
    fi
    log_error "the import failed on ${site}"
    return 1
}

restore_tree() { # SITE USER ARCHIVE [DEST_DIR]
    local site="$1" user="$2" file="$3" dest="${4:-$(path_dir "$site")}"
    if ! have tar; then
        log_error 'tar(1) is required to restore an archive and was not found'
        return 1
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would extract ${file} into ${dest}"
        return 0
    fi
    if ! confirm_destructive "extract ${file##*/} over ${dest}? Existing files with the same names are overwritten."; then
        return 1
    fi
    mkdir -p -- "$dest" 2>/dev/null
    if tar -xzf "$file" -C "$dest" 2>/dev/null; then
        if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
            chown -R -- "$user" "$dest" 2>/dev/null
        fi
        log_ok "archive restored into ${dest}"
        return 0
    fi
    log_error "extracting ${file} into ${dest} failed"
    return 1
}

###############################################################################
# Section 23 - maintenance operations
###############################################################################
#
# One mode = one function, so a new mode is a new function plus one case branch
# in process_site and nothing else. Every function returns non-zero when the site
# failed. Every function takes (SITE USER URL), because a multisite expands into
# several units that share a path and an owner and differ only in the URL.

# mode_core SITE USER URL
#
# Order matters: files first, then the database schema. WordPress itself updates
# in that order, and `core update-db` before `core update` would run the old
# schema upgrade against the new files.
#
# --skip-plugins on the schema upgrade is what WordPress does during an update: a
# broken plugin must not be able to block a database migration.
mode_core() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user" "$url"
    run_wp "$site" "$user" "$url" core update || rc=1
    run_wp "$site" "$user" "$url" core update-db --skip-plugins || rc=1
    return "$rc"
}

# core_report_available SITE USER URL
core_report_available() { # SITE USER URL
    local label
    label="$(path_base "$1")"
    info_wp "$1" "$2" "$3" core check-update
    case "$WP_OUTPUT" in
        *'WordPress database upgrade required'*)
            log_info "${label}: a WordPress database upgrade is pending"
            ;;
        *'update_type'* | *'package'*)
            log_info "${label}: a WordPress core update is available"
            ;;
        *)
            log_info "${label}: WordPress core is up to date"
            ;;
    esac
    return 0
}

# plugins_update_selected SITE USER URL
#
# Update only the plugins that need it, minus the ones the operator excluded.
# WP-CLI has no "all except these" for `plugin update`, so the set is enumerated
# from `plugin list` and passed by slug. That also means one broken plugin cannot
# hide behind `--all`: the enumeration is per slug, and a slug that fails is
# reported by name.
plugins_update_selected() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local -a targets=()
    plugin_select_targets "$site" "$user" "$url" || return 1
    mapfile -t targets <<<"$PLUGIN_SELECTION"
    if ((${#targets[@]} == 0)) || { ((${#targets[@]} == 1)) && [ -z "${targets[0]}" ]; }; then
        log_info "$(path_base "$site"): nothing to update among the selected plugins"
        return 0
    fi
    log_info "$(path_base "$site"): updating ${#targets[@]} plugin(s): ${targets[*]}"
    run_wp "$site" "$user" "$url" plugin update "${targets[@]}"
}

mode_plugins() { # SITE USER URL
    if [ "$ONLY_ACTIVE" = 'true' ] || [ -n "$EXCLUDE_PLUGINS" ]; then
        plugins_update_selected "$1" "$2" "$3"
        return $?
    fi
    run_wp "$1" "$2" "$3" plugin update --all
}

mode_themes() { # SITE USER URL
    run_wp "$1" "$2" "$3" theme update --all
}

# mode_languages SITE USER URL
#
# Translations are the update everybody forgets, which is why a site can be
# running a current core with a year-old German language pack. `language` needs
# WP-CLI 2.2+, so it is probed rather than assumed: on an older build the mode
# says so instead of failing with a confusing "not a registered command".
mode_languages() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    if ! wp_supported "$site" "$user" language; then
        log_warn "$(path_base "$site"): this WP-CLI has no 'language' command (2.2+ needed); translations were not updated"
        return 0
    fi
    run_wp_soft "$site" "$user" "$url" language core update || true
    run_wp_soft "$site" "$user" "$url" language plugin update --all || true
    run_wp_soft "$site" "$user" "$url" language theme update --all || true
    return "$rc"
}

mode_db_optimize() { # SITE USER URL
    local rc=0
    run_wp "$1" "$2" "$3" db optimize || rc=1
    run_wp "$1" "$2" "$3" db repair || rc=1
    return "$rc"
}

mode_db_fix() { # SITE USER URL
    run_wp "$1" "$2" "$3" db repair
}

mode_cron() { # SITE USER URL
    run_wp "$1" "$2" "$3" cron event run --due-now
}

# mode_cache SITE USER URL
#
# The repository this tool grew out of advertised "cache flush" for years and did
# not have it, so a site that was updated correctly kept serving stale pages
# until somebody logged in and clicked a button. This mode is the fix.
#
# Three layers, because they are three different caches:
#   object cache   `wp cache flush`          -- the in-process/drop-in cache
#   transients     `wp transient delete`     -- the options-table cache
#   rewrite rules  `wp rewrite flush`        -- needed after a core update
#                                              changed the permalink handling
#
# Page caches owned by a plugin (WP Rocket, LiteSpeed, W3 Total Cache, WP Fastest
# Cache) are not guessed at: CACHE_EXTRA takes their wp subcommands as plain
# tokens, each of which becomes one argv element and is never interpreted by a
# shell. Tokens are validated to a conservative character set, so the worst a
# config file can do is name a wp subcommand -- which is exactly what this tool
# does for a living anyway, and the config file is root-owned and mode-checked.
mode_cache() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 tok
    run_wp "$site" "$user" "$url" cache flush || rc=1
    case "$CACHE_TRANSIENTS" in
        all)
            run_wp_soft "$site" "$user" "$url" transient delete --all || true
            ;;
        expired)
            run_wp_soft "$site" "$user" "$url" transient delete --expired || true
            ;;
        none) log_debug 'CACHE_TRANSIENTS=none; transients left alone' ;;
    esac
    if [ "$CACHE_REWRITE_FLUSH" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" rewrite flush || true
    fi
    for tok in $CACHE_EXTRA; do
        # shellcheck disable=SC2206  # the token list is validated by 'tokens'
        local -a extra=($tok)
        log_info "$(path_base "$site"): extra cache command: wp ${tok}"
        run_wp_soft "$site" "$user" "$url" ${extra[@]+"${extra[@]}"} || true
    done
    return "$rc"
}

###############################################################################
# Section 24 - cleanup
###############################################################################
#
# Revisions, trash, spam and expired transients are the four things that make a
# WordPress database grow without anybody adding content. Deleting them is safe
# when the ids come from WP-CLI and are validated as integers before they become
# arguments; it is destructive when a count is guessed. Everything below therefore
# enumerates first, reports the count, and only then deletes.
#
# Without --yes and without a terminal, this mode reports what it would delete and
# changes nothing. A cron job that quietly deleted 40k revisions on the first run
# would be a tool nobody trusts twice.

CLEANUP_BATCH=200

# ids_from_wp SITE USER URL ARGS... -> validated integer ids, one per line
ids_from_wp() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    wp_data "$site" "$user" "$url" "$@" --format=ids
    [ "$WP_SKIPPED" = 'true' ] && return 0
    ((WP_STATUS == 0)) || return 1
    # --format=ids prints a space separated list on one line for posts and one id
    # per line for comments, depending on the version. Normalise both.
    printf '%s\n' "$WP_OUTPUT" | tr ' ' '\n' | numeric_lines
    return 0
}

# delete_in_batches SITE USER URL KIND ID_ARGS... : delete validated ids in
# ARG_MAX-sized batches, counting what actually went away.
delete_in_batches() { # SITE USER URL DELETE_CMD... < IDS
    local site="$1" user="$2" url="$3"
    shift 3
    local -a cmd=("$@") batch=() ids=()
    local line total=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2206  # the batch is a list of validated integers
        batch=($line)
        if run_wp "$site" "$user" "$url" "${cmd[@]}" "${batch[@]}"; then
            total=$((total + ${#batch[@]}))
        fi
    done
    STATS_CLEANED=$((STATS_CLEANED + total))
    printf '%s' "$total"
    return 0
}

# revisions_to_delete SITE USER URL -> ids of the revisions beyond the keep limit
#
# Keeping "the newest N per post" rather than "the newest N overall" is the
# difference between a cleanup and a data loss event: a blog with one very active
# post would otherwise have every other post's history wiped. WP-CLI returns
# revisions newest first, so the first N rows of each post_parent group are the
# keepers and the rest are the targets.
revisions_to_delete() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local body tsv id parent date
    local -A kept=()
    wp_data "$site" "$user" "$url" post list --post_type=revision \
        --fields=ID,post_parent,post_date --format=json
    [ "$WP_SKIPPED" = 'true' ] && return 0
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT" 2>/dev/null)" || return 0
    tsv="$(printf '%s' "$body" | json_to_tsv ID post_parent post_date 2>/dev/null)" || return 0
    while IFS=$'\t' read -r id parent date; do
        [ "$id" = 'ID' ] && continue
        is_uint "$id" || continue
        parent="${parent:-0}"
        is_uint "$parent" || parent=0
        local n="${kept[$parent]-0}"
        if ((n < CLEANUP_REVISIONS_KEEP)); then
            kept[$parent]=$((n + 1))
            continue
        fi
        printf '%s\n' "$id"
    done <<<"$tsv"
    return 0
}

# count_id_words < BATCHES -> how many ids in total, across space separated lines
count_id_words() {
    local line w n=0
    while IFS= read -r line; do
        for w in $line; do
            is_uint "$w" && n=$((n + 1))
        done
    done
    printf '%s' "$n"
}

# cleanup_step SITE USER URL LABEL IDS DELETE_CMD...
#
# One enumerated object class, handled identically everywhere: count it, report
# it, and delete it only when the operator said --yes. Keeping this in one
# function is what stops the four cleanup kinds from drifting apart, which is how
# a tool ends up deleting trash but only reporting spam.
cleanup_step() { # SITE USER URL KIND IDS CMD...
    local site="$1" user="$2" url="$3" kind="$4" ids="$5"
    shift 5
    local -a cmd=("$@")
    local n=0 label
    label="$(path_base "$site")"
    n="$(printf '%s\n' "$ids" | count_id_words)"
    if ((n == 0)); then
        log_debug "${label}: no ${kind} to remove"
        return 0
    fi
    log_info "${label}: ${n} ${kind}"
    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        return 0
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: wp ${cmd[*]} <${n} ids>"
        STATS_CLEANED=$((STATS_CLEANED + n))
        return 0
    fi
    # A here-string, not a pipe: the counters have to survive in this shell.
    delete_in_batches "$site" "$user" "$url" "${cmd[@]}" <<<"$ids" >/dev/null
    return $?
}

mode_cleanup() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 ids='' label status
    label="$(path_base "$site")"
    local before="$STATS_CLEANED"

    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        if [ "$DRY_RUN" = 'true' ]; then
            log_info "${label}: cleanup dry run; reporting what would be deleted"
        elif [ ! -t 0 ]; then
            log_warn "${label}: --cleanup deletes content; pass --yes to allow it in a non-interactive run"
            log_info "${label}: reporting what would be deleted"
        fi
    fi

    # Revisions: the newest CLEANUP_REVISIONS_KEEP per post survive.
    ids="$(revisions_to_delete "$site" "$user" "$url" 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
    cleanup_step "$site" "$user" "$url" 'revision(s) beyond the keep limit' "$ids" \
        post delete --force || rc=1

    if [ "$CLEANUP_AUTODRAFT" = 'true' ]; then
        ids="$(ids_from_wp "$site" "$user" "$url" post list --post_status=auto-draft 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
        cleanup_step "$site" "$user" "$url" 'auto-draft(s)' "$ids" post delete --force || rc=1
    fi

    if [ "$CLEANUP_TRASH" = 'true' ]; then
        ids="$(ids_from_wp "$site" "$user" "$url" post list --post_status=trash 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
        cleanup_step "$site" "$user" "$url" 'trashed post(s)' "$ids" post delete --force || rc=1
    fi

    if [ "$CLEANUP_SPAM" = 'true' ]; then
        for status in spam trash; do
            ids="$(ids_from_wp "$site" "$user" "$url" comment list --status="$status" 2>/dev/null | chunk_lines "$CLEANUP_BATCH")"
            cleanup_step "$site" "$user" "$url" "${status} comment(s)" "$ids" comment delete --force || rc=1
        done
    fi

    case "$CLEANUP_TRANSIENTS" in
        all)
            log_info "${label}: all transients"
            if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ]; then
                if [ "$DRY_RUN" = 'true' ]; then
                    log_info '[dry-run] would run: wp transient delete --all'
                else
                    run_wp_soft "$site" "$user" "$url" transient delete --all || true
                fi
            fi
            ;;
        expired)
            log_info "${label}: expired transients"
            if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ]; then
                if [ "$DRY_RUN" = 'true' ]; then
                    log_info '[dry-run] would run: wp transient delete --expired'
                else
                    run_wp_soft "$site" "$user" "$url" transient delete --expired || true
                fi
            fi
            ;;
        none) log_debug "${label}: transients left alone" ;;
    esac

    if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ]; then
        log_info "${label}: nothing was deleted (add --yes to apply)"
        return 0
    fi
    if [ "$CLEANUP_OPTIMIZE" = 'true' ] && ((STATS_CLEANED > before)) && [ "$DRY_RUN" != 'true' ]; then
        log_info "${label}: optimizing the database after the cleanup"
        run_wp_soft "$site" "$user" "$url" db optimize || true
    fi
    return "$rc"
}

###############################################################################
# Section 25 - Astra Pro licence
###############################################################################

# astra_step SITE USER URL STRICT
#
# Update first, because that is the common case and it needs no licence. Only
# reach for the licence when the update actually failed, which is what "the
# licence expired" looks like from the outside.
# rc == 2 means dry run: nothing happened and nothing should be retried.
astra_step() { # SITE USER URL STRICT
    local site="$1" user="$2" url="$3" strict="${4:-false}" rc=0 label
    label="$(path_base "$site")"
    run_wp_soft "$site" "$user" "$url" plugin update "$ASTRA_SLUG"
    rc=$?
    ((rc == 0)) && { log_ok "${label}: ${ASTRA_SLUG} updated"; return 0; }
    ((rc == 2)) && return 0

    if ! licence_resolve "$strict"; then
        if [ "$strict" = 'true' ]; then return 1; fi
        log_warn "${label}: no Astra licence configured; the licence step is skipped"
        return 0
    fi
    log_info "${label}: the update failed, trying a licence activation"
    run_wp_soft "$site" "$user" "$url" brainstormforce license activate "$ASTRA_SLUG" "$LICENCE_MARKER"
    rc=$?
    if ((rc == 1)); then
        log_warn "${label}: licence activation did not succeed"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    ((rc == 2)) && return 0
    log_ok "${label}: licence activated"
    run_wp_soft "$site" "$user" "$url" plugin update "$ASTRA_SLUG"
    rc=$?
    if ((rc == 1)); then
        log_warn "${label}: ${ASTRA_SLUG} still did not update after activation"
        [ "$strict" = 'true' ] && return 1
        return 0
    fi
    log_ok "${label}: ${ASTRA_SLUG} updated after licence activation"
    return 0
}

mode_astra() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    if ! licence_resolve 'false' && [ -z "$LICENCE_VALUE" ]; then
        # Resolve strictly only when the mode is the point of the run: --astra
        # with no licence is a configuration error, while --full without one is
        # a normal host that does not use Astra Pro.
        licence_resolve 'true' || return 1
    fi
    astra_step "$site" "$user" "$url" 'true'
}

###############################################################################
# Section 26 - integrity verification
###############################################################################

# mode_verify SITE USER URL
#
# Read-only. `verify-checksums` compares every shipped file against the
# WordPress.org manifest, which is the cheapest way to find a half-finished
# update or a tampered core file before touching anything. A mismatch is a
# *finding*: it is reported and it fails the site, but nothing is modified, so
# the mode is safe to schedule hourly.
mode_verify() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0 label
    label="$(path_base "$site")"
    if ! run_wp "$site" "$user" "$url" core verify-checksums; then
        log_error "${label}: core checksums do not match"
        STATS_FINDINGS=$((STATS_FINDINGS + 1))
        rc=1
    fi
    if ! run_wp "$site" "$user" "$url" plugin verify-checksums --all; then
        log_error "${label}: at least one plugin failed its checksum verification"
        STATS_FINDINGS=$((STATS_FINDINGS + 1))
        rc=1
    fi
    return "$rc"
}

###############################################################################
# Section 27 - --full
###############################################################################
#
# The order is the order WordPress itself uses, with the caches at the end:
#   1. core files, 2. core schema, 3. plugins, 4. themes, 5. translations,
#   6. cron, 7. caches and rewrite rules, 8. database optimize, 9. Astra.
#
# `db repair` is deliberately NOT part of --full by default. It runs
# `mysqlcheck --repair`, which on InnoDB is a no-op that still walks every table,
# and on MyISAM takes a lock. Running it on every site of every nightly update is
# a self-inflicted outage window for no benefit; a repair belongs in --db-fix,
# after something has actually been reported as broken. FULL_DB_REPAIR=true puts
# it back for hosts that want the old behaviour.
mode_full() { # SITE USER URL
    local site="$1" user="$2" url="$3" rc=0
    [ "$VERBOSE" = 'true' ] && core_report_available "$site" "$user" "$url"
    run_wp "$site" "$user" "$url" core update || rc=1
    run_wp "$site" "$user" "$url" core update-db --skip-plugins || rc=1
    mode_plugins "$site" "$user" "$url" || rc=1
    run_wp "$site" "$user" "$url" theme update --all || rc=1
    if [ "$FULL_LANGUAGES" = 'true' ]; then
        mode_languages "$site" "$user" "$url" || true
    fi
    run_wp_soft "$site" "$user" "$url" cron event run --due-now || true
    if [ "$FULL_CACHE" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" cache flush || true
        case "$CACHE_TRANSIENTS" in
            expired) run_wp_soft "$site" "$user" "$url" transient delete --expired || true ;;
            all) run_wp_soft "$site" "$user" "$url" transient delete --all || true ;;
        esac
        [ "$CACHE_REWRITE_FLUSH" = 'true' ] &&
            run_wp_soft "$site" "$user" "$url" rewrite flush || true
    fi
    run_wp_soft "$site" "$user" "$url" db optimize || true
    if [ "$FULL_DB_REPAIR" = 'true' ]; then
        run_wp_soft "$site" "$user" "$url" db repair || true
    fi
    if [ -n "$LICENCE_VALUE" ] || licence_resolve 'false'; then
        astra_step "$site" "$user" "$url" 'false' || true
    fi
    return "$rc"
}

###############################################################################
# Section 28 - plugin inventory and management
###############################################################################

PLUGIN_FIELDS_DEFAULT='name,status,update,version'

plugin_columns() {
    local list="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    printf '%s' "${list//,/ }"
}

# data_sink -> where a machine-readable or tabular payload must go.
#
# In parallel mode a worker's stdout is a file that the parent replays into the
# *right* stream after the barrier, so everything the operator or a parser wants
# has to be routed to the data fragment. An empty result means "the caller's own
# stdout", which is what sink_write turns into no redirection at all -- see the
# note on /dev/stdout in section 3.
#
# Sets DATA_SINK and prints it, so a hot caller can skip the subshell.
DATA_SINK=''
data_sink() {
    if [ "${PARALLEL:-false}" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        DATA_SINK="${WORKER_DIR}/data"
    else
        DATA_SINK=''
    fi
    printf '%s' "$DATA_SINK"
    return 0
}

# plugin_list_site SITE USER URL
plugin_list_site() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local -a fields=()
    local body tsv sink
    read -r -a fields <<<"$(plugin_columns)"

    wp_data "$site" "$user" "$url" plugin list --format=json \
        --fields="${FILTER_FIELDS:-$PLUGIN_FIELDS_DEFAULT}"
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        count_op_failed
        log_error "cannot list plugins on ${site} (exit ${WP_STATUS})"
        log_error_detail 'plugin_list' 'wp plugin list --format=json' \
            "${WP_OUTPUT}${WP_STDERR:+$'\n'"$WP_STDERR"}" "$WP_STATUS"
        return 1
    fi
    if ! body="$(json_array_slice "$WP_OUTPUT")"; then
        count_op_failed
        log_error "wp on ${site} did not return a JSON plugin list"
        log_error_detail 'plugin_list' 'wp plugin list --format=json' "$WP_OUTPUT" 0
        return 1
    fi
    count_op_ok

    if ! tsv="$(printf '%s' "$body" | json_to_tsv "${fields[@]}")"; then
        log_error "cannot parse the JSON plugin list from ${site}"
        return 1
    fi
    tsv="$(printf '%s\n' "$tsv" | plugin_filter)"

    sink="$(data_sink)"
    case "$OUTPUT_FORMAT" in
        json) printf '%s\n' "$body" | sink_write "$sink" ;;
        csv) printf '%s\n' "$tsv" | tsv_to_csv | sink_write "$sink" ;;
        tsv) printf '%s\n' "$tsv" | sink_write "$sink" ;;
        table | *)
            {
                printf '%s%s%s\n' "$C_BOLD" "$site" "$C_RESET"
                printf '%s\n' "$tsv" | table_render "$PAGE_LIMIT"
            } | sink_write "$sink"
            ;;
    esac
    return 0
}

# plugin_filter < TSV -> TSV, keeping the rows whose first column matches --name
# as a case-insensitive *substring*. A substring match is deliberate: it is what
# an operator means by "the woo one", and it can never be interpreted as a
# pattern, so nothing needs escaping.
plugin_filter() {
    local needle="${FILTER_NAME,,}" line first=1 lower
    while IFS= read -r line || [ -n "$line" ]; do
        if ((first)); then printf '%s\n' "$line"; first=0; continue; fi
        [ -n "$needle" ] || { printf '%s\n' "$line"; continue; }
        lower="${line,,}"
        case "$lower" in
            *"$needle"*) printf '%s\n' "$line" ;;
        esac
    done
    return 0
}

# plugin_select_targets SITE USER URL -> fills PLUGIN_SELECTION (newline
# separated slugs) honouring --only-active and --exclude-plugins.
PLUGIN_SELECTION=''
plugin_select_targets() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local body tsv line name slug status update
    local -A excluded=()
    local ex
    PLUGIN_SELECTION=''

    while IFS= read -r ex; do
        [ -n "$ex" ] && excluded["${ex,,}"]=1
    done < <(split_csv "$EXCLUDE_PLUGINS")

    wp_data "$site" "$user" "$url" plugin list --format=json --fields=name,slug,status,update
    if [ "$WP_SKIPPED" = 'true' ]; then return 0; fi
    if ((WP_STATUS != 0)); then
        log_error "cannot enumerate plugins on ${site} (wp exit ${WP_STATUS}); nothing was updated"
        return 1
    fi
    if ! body="$(json_array_slice "$WP_OUTPUT")"; then
        log_error "wp on ${site} did not return a JSON plugin list; nothing was updated"
        return 1
    fi
    if ! tsv="$(printf '%s' "$body" | json_to_tsv name slug status update)"; then
        log_error "cannot parse the plugin list from ${site}; nothing was updated"
        return 1
    fi
    while IFS=$'\t' read -r name slug status update; do
        [ "$slug" = 'slug' ] && continue
        [ -n "$slug" ] || continue
        if [ -n "${excluded[${slug,,}]-}" ] || [ -n "${excluded[${name,,}]-}" ]; then
            log_debug "excluded by --exclude-plugins: ${slug}"
            continue
        fi
        if [ "$ONLY_ACTIVE" = 'true' ]; then
            if [ "$status" != 'active' ]; then
                log_debug "not active, skipped: ${slug}"
                continue
            fi
            if [ "$update" != 'available' ]; then
                log_debug "up to date, skipped: ${slug}"
                continue
            fi
        fi
        PLUGIN_SELECTION+="${PLUGIN_SELECTION:+$'\n'}${slug}"
    done <<<"$tsv"
    return 0
}

# plugin_resolve_slug SITE USER URL NAME -> exactly one slug.
#
# Exact match on slug or display name wins outright; otherwise a case-insensitive
# substring match, and ambiguity is an error rather than a coin toss. Deleting
# "the seo one" on a site that has two of them is not a decision a maintenance
# tool should make quietly.
plugin_resolve_slug() { # SITE USER URL NAME
    local site="$1" user="$2" url="$3" needle="${4,,}"
    local body tsv n s st exact='' match='' matches=0
    wp_data "$site" "$user" "$url" plugin list --format=json --fields=name,slug,status
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT")" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv name slug status)" || return 1
    while IFS=$'\t' read -r n s st; do
        [ "$s" = 'slug' ] && continue
        [ -n "$s" ] || continue
        if [ "${n,,}" = "$needle" ] || [ "${s,,}" = "$needle" ]; then
            exact="$s"
            break
        fi
        case "${n,,}" in *"$needle"*) match="$s"; matches=$((matches + 1)) ;; esac
        case "${s,,}" in
            *"$needle"*)
                # A slug that equals an already-counted name match is the same
                # plugin, not a second candidate. Counting it twice turned
                # "jetpack" into an ambiguity error on every site that had it.
                [ "$match" = "$s" ] || { match="$s"; matches=$((matches + 1)); }
                ;;
        esac
    done <<<"$tsv"
    if [ -n "$exact" ]; then
        printf '%s' "$exact"
        return 0
    fi
    if ((matches == 0)); then
        log_error "no plugin matching '${4}' on ${site}"
        return 1
    fi
    if ((matches > 1)); then
        log_error "'${4}' is ambiguous on ${site}; pass the exact slug"
        return 1
    fi
    printf '%s' "$match"
    return 0
}

# mode_plugin_manage SITE USER URL
mode_plugin_manage() { # SITE USER URL
    local site="$1" user="$2" url="$3" slug='' wp_action=''
    case "$PLUGIN_ACTION" in
        activate | deactivate | delete | install | update | status)
            wp_action="$PLUGIN_ACTION"
            ;;
        *)
            log_error "--plugin-manage needs --action activate|deactivate|delete|install|update|status"
            return 1
            ;;
    esac
    [ -n "$PLUGIN_NAME" ] || { log_error "--plugin-manage needs --name NAME"; return 1; }

    # `install` takes a wordpress.org slug, which by definition is not installed
    # yet, so there is nothing to resolve and no local list to consult.
    if [ "$wp_action" = 'install' ]; then
        if [[ ! "$PLUGIN_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
            log_error "--name for --action install must be a wordpress.org slug (lowercase letters, digits, dots, dashes)"
            return 1
        fi
        if [ "$DRY_RUN" != 'true' ] && ! confirm_destructive "install plugin '${PLUGIN_NAME}' on ${site}?"; then
            return 1
        fi
        run_wp "$site" "$user" "$url" plugin install "$PLUGIN_NAME"
        return $?
    fi

    slug="$(plugin_resolve_slug "$site" "$user" "$url" "$PLUGIN_NAME")" || return 1
    log_debug "resolved '${PLUGIN_NAME}' to '${slug}' on ${site}"

    case "$wp_action" in
        status)
            run_wp "$site" "$user" "$url" plugin status "$slug"
            return $?
            ;;
        update)
            run_wp "$site" "$user" "$url" plugin update "$slug"
            return $?
            ;;
        delete)
            if ! confirm_destructive "delete plugin '${slug}' on ${site}? This cannot be undone."; then
                return 1
            fi
            # After this call there is no other copy of the plugin anywhere.
            backup_plugin "$site" "$slug"
            # Deactivate first. `plugin delete` on an active plugin leaves its
            # options, tables and cron events behind, because the deactivation
            # hooks never run; deactivating first gives the plugin the chance to
            # clean up after itself. A failure here is not fatal: the operator
            # asked for the plugin to go, and deleting an inactive plugin is
            # still what they want.
            run_wp_soft "$site" "$user" "$url" plugin deactivate "$slug" >/dev/null
            run_wp "$site" "$user" "$url" plugin delete "$slug"
            return $?
            ;;
    esac
    run_wp "$site" "$user" "$url" plugin "$wp_action" "$slug"
}

mode_list_plugins() { # SITE USER URL
    plugin_list_site "$1" "$2" "$3"
}

###############################################################################
# Section 29 - health report (--report)
###############################################################################
#
# The question a fleet operator actually asks on Monday morning is not "did the
# update run" but "what state is everything in, and what needs attention". Every
# field below is read-only: no counter moves, nothing is written, and the mode is
# safe to schedule more often than the updates themselves.
#
# All of it is collected with `--format=count`, `--format=json` or `config get`
# rather than by parsing human-readable tables, because a table's column order is
# not part of WP-CLI's contract and changes between releases.

# report_php_info SITE USER -> "php|phpversion|wpcliversion"
report_php_info() { # SITE USER
    local site="$1" user="$2" body phpv='' cliv='' phpbin=''
    if wp_data "$site" "$user" '' cli info 2>/dev/null && ((WP_STATUS == 0)); then
        body="$WP_OUTPUT"
        phpv="$(awk -F': *' '/^PHP version/ {print $2; exit}' <<<"$body")"
        phpbin="$(awk -F': *' '/^PHP binary/ {print $2; exit}' <<<"$body")"
        cliv="$(awk -F': *' '/^WP-CLI version/ {print $2; exit}' <<<"$body")"
    fi
    printf '%s\t%s\t%s\t%s' "$(trim "$phpbin")" "$(trim "$phpv")" "$(trim "$cliv")" ''
    return 0
}

# report_db_bytes SITE USER URL -> database size in bytes, empty when unknown.
# information_schema first, because the answer is a single integer and does not
# depend on how `db size` decides to render its table this release.
report_db_bytes() { # SITE USER URL
    local site="$1" user="$2" url="$3" out=''
    if wp_probe "$site" "$user" "$url" db query \
        'SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()' \
        --skip-column-names 2>/dev/null; then
        out="${WP_PROBE//[^0-9]/}"
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    if wp_data "$site" "$user" "$url" db size --size_format=bytes 2>/dev/null && ((WP_STATUS == 0)); then
        out="$(grep -o '[0-9]\+' <<<"$WP_OUTPUT" | tail -n 1)"
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    printf ''
    return 1
}

# report_count SITE USER URL ARGS... -> an integer, 0 when unavailable
report_count() { # SITE USER URL ARGS...
    local site="$1" user="$2" url="$3"
    shift 3
    if wp_probe "$site" "$user" "$url" "$@" --format=count 2>/dev/null; then
        local n="${WP_PROBE//[^0-9]/}"
        printf '%s' "${n:-0}"
        return 0
    fi
    printf '0'
    return 0
}

REPORT_HEADERS='SITE	OWNER	WP	PHP	HOME	MULTISITE	PLUGINS	PLUGIN_UPDATES	THEMES	THEME_UPDATES	USERS	ADMINS	DB_SIZE	UPLOADS	CRON	DISK_FREE_MIB	CORE_UPDATE'

# report_unit INDEX -> one TSV row for one work unit
report_unit() { # INDEX
    local i="$1" site="${UNIT_PATH[i]}" user="${UNIT_USER[i]}" url="${UNIT_URL[i]}"
    local wpver='' home='' multi='no' dbb='' upl='' cron='?' coreupd='no'
    local plugins=0 pupd=0 themes=0 tupd=0 users=0 admins=0 phpv='' phpbin='' cliv=''

    if wp_probe "$site" "$user" "$url" core version; then wpver="$WP_PROBE"; fi
    home="$(site_home "$site" "$user")"

    # `cli info` once, because PHP and WP-CLI versions come from the same answer.
    local info
    info="$(report_php_info "$site" "$user")"
    phpbin="${info%%$'\t'*}"; info="${info#*$'\t'}"
    phpv="${info%%$'\t'*}"; info="${info#*$'\t'}"
    cliv="${info%%$'\t'*}"

    if [ "$MULTISITE" != 'off' ]; then
        local subs
        subs="$(report_count "$site" "$user" "$url" site list)"
        if ((${subs:-0} > 0)); then multi="yes(${subs})"; fi
    fi

    plugins="$(report_count "$site" "$user" "$url" plugin list)"
    pupd="$(report_count "$site" "$user" "$url" plugin list --update=available)"
    themes="$(report_count "$site" "$user" "$url" theme list)"
    tupd="$(report_count "$site" "$user" "$url" theme list --update=available)"
    users="$(report_count "$site" "$user" "$url" user list)"
    admins="$(report_count "$site" "$user" "$url" user list --role=administrator)"

    if [ "$REPORT_DB_SIZE" = 'true' ]; then
        dbb="$(report_db_bytes "$site" "$user" "$url")"
    fi
    if [ "$REPORT_UPLOADS_SIZE" = 'true' ] && [ -d "${site}/wp-content/uploads" ]; then
        local kib
        kib="$(dir_kib "${site}/wp-content/uploads")"
        [ -n "$kib" ] && upl="$((kib * 1024))"
    fi
    if [ "$REPORT_CRON_TEST" = 'true' ]; then
        if wp_data "$site" "$user" "$url" cron test >/dev/null 2>&1 && ((WP_STATUS == 0)); then
            cron='ok'
        else
            cron='BROKEN'
        fi
    fi
    # A pending core update is the single most actionable field in the report.
    wp_data "$site" "$user" "$url" core check-update --format=json >/dev/null 2>&1
    if ((WP_STATUS == 0)) && json_array_slice "$WP_OUTPUT" >/dev/null 2>&1; then
        local slice
        if slice="$(json_array_slice "$WP_OUTPUT")" && [ -n "$slice" ] && [ "$slice" != '[]' ]; then
            coreupd='yes'
        fi
    fi

    REPORT_ROW="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "${UNIT_LABEL[i]}" "$user" "${wpver:-?}" "${phpv:-?}" "${home:-?}" "$multi" \
        "$plugins" "$pupd" "$themes" "$tupd" "$users" "$admins" \
        "$([ -n "$dbb" ] && human_bytes "$dbb" || printf -- '-')" \
        "$([ -n "$upl" ] && human_bytes "$upl" || printf -- '-')" \
        "$cron" "$(free_mib "$site" 2>/dev/null || printf '?')" "$coreupd")"

    # The machine-readable form carries the raw numbers, because a monitoring
    # system cannot do anything useful with "1.5 MiB".
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        local jv
        if [ "$coreupd" = 'yes' ]; then jv='true'; else jv='false'; fi
        printf '{"type":"report","path":%s,"owner":%s,"url":%s,"wp_version":%s,"php_version":%s,"wpcli_version":%s,"home":%s,"multisite":%s,"plugins":%s,"plugin_updates":%s,"themes":%s,"theme_updates":%s,"users":%s,"administrators":%s,"db_bytes":%s,"uploads_bytes":%s,"cron":%s,"core_update":%s}\n' \
            "$(json_quote "$site")" "$(json_quote "$user")" "$(json_quote "$url")" \
            "$(json_quote "${wpver:-}")" "$(json_quote "${phpv:-}")" "$(json_quote "${cliv:-}")" \
            "$(json_quote "${home:-}")" "$(json_quote "$multi")" \
            "$plugins" "$pupd" "$themes" "$tupd" "$users" "$admins" \
            "$(json_quote "${dbb:-}")" "$(json_quote "${upl:-}")" \
            "$(json_quote "$cron")" "$jv" | sink_append "$(data_sink)"
    fi
    if [ -n "$wpver" ]; then
        UNIT_WP_VERSION["$site"]="$wpver"
    fi
    return 0
}

# mode_report SITE USER URL : one row of the fleet report.
#
# The row goes to report_row_sink, which is a per-worker file in a parallel run
# and the shared buffer in a sequential one (section 41). Streaming a table
# straight to stdout would force a guess at the column widths, and streaming it
# from four workers at once would produce an unreadable interleave.
mode_report() { # SITE USER URL
    local sink dsink
    report_unit "$CURRENT_UNIT"
    sink="$(report_row_sink)"
    dsink="$(data_sink)"
    case "$OUTPUT_FORMAT" in
        json)
            : # report_unit already emitted the JSON object to the data sink
            ;;
        table)
            printf '%s\n' "$REPORT_ROW" | sink_append "$sink"
            ;;
        tsv)
            if [ "$REPORT_HEADER_PRINTED" != 'true' ]; then
                printf '%s\n' "$REPORT_HEADERS" | sink_append "$dsink"
                REPORT_HEADER_PRINTED='true'
            fi
            printf '%s\n' "$REPORT_ROW" | sink_append "$dsink"
            ;;
        csv)
            if [ "$REPORT_HEADER_PRINTED" != 'true' ]; then
                printf '%s\n' "$REPORT_HEADERS" | tsv_to_csv | sink_append "$dsink"
                REPORT_HEADER_PRINTED='true'
            fi
            printf '%s\n' "$REPORT_ROW" | tsv_to_csv | sink_append "$dsink"
            ;;
    esac
    return 0
}
REPORT_HEADER_PRINTED='false'
REPORT_ROW=''

###############################################################################
# Section 30 - security and integrity audit (--security)
###############################################################################
#
# A read-only audit that answers "which of my sites is a problem?" in one pass.
# Every check produces a finding with a severity, and the severities drive both
# the score and the exit code, so this mode can be the thing a monitoring system
# alerts on instead of a report somebody has to read.
#
#   crit   the site is very likely compromised or exposed right now
#   warn   a configuration that should not ship to production
#   info   worth knowing, not worth a page
#
# Scoring is deliberately simple and documented: start at 100, minus 25 per crit,
# minus 8 per warn, minus 1 per info, floor at 0. A number that cannot be
# explained is a number nobody trusts.

FIND_SEV=()
FIND_CHECK=()
FIND_MSG=()
SITE_SCORE=100

# finding SEVERITY CHECK MESSAGE
finding() { # SEVERITY CHECK MESSAGE
    local sev="${1:-info}"
    FIND_SEV+=("$sev")
    FIND_CHECK+=("${2:-check}")
    FIND_MSG+=("${3:-}")
    STATS_FINDINGS=$((STATS_FINDINGS + 1))
    case "$sev" in
        crit)
            STATS_CRITICAL=$((STATS_CRITICAL + 1))
            SITE_SCORE=$((SITE_SCORE - 25))
            log_error "CRIT ${2:-check}: ${3:-}"
            ;;
        warn)
            SITE_SCORE=$((SITE_SCORE - 8))
            log_warn "${2:-check}: ${3:-}"
            ;;
        *)
            SITE_SCORE=$((SITE_SCORE - 1))
            log_info "info ${2:-check}: ${3:-}"
            ;;
    esac
    return 0
}

finding_ok() { # CHECK MESSAGE
    log_debug "ok   ${1:-check}: ${2:-}"
    return 0
}

# audit_permissions SITE : file mode checks that need no WordPress at all.
audit_permissions() { # SITE
    local site="$1" cfg mode='' uploads
    if cfg="$(wp_config_path "$site")"; then
        mode="$(file_mode "$cfg")"
        path_base "$cfg" >/dev/null
        local cfg_name="$PATH_BASE" m=0
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
            # Bit arithmetic, not digit eyeballing. The severity ladder is the
            # one an incident responder would draw: other-write means any local
            # account can own the site (crit); group-write means the same for a
            # whole group (warn, because on a shared host that group is often
            # "every customer"); other-read leaks the database credentials
            # (warn); 0640 and stricter is the recommended shape and passes.
            m=$((8#${mode}))
            if ((m & 8#002)); then
                finding crit 'wp-config perms' \
                    "${cfg_name} is writable by any local account (mode ${mode}). chmod 0640"
            elif ((m & 8#020)); then
                finding warn 'wp-config perms' \
                    "${cfg_name} is writable by its group (mode ${mode}); check who is in that group. chmod 0640"
            elif ((m & 8#004)); then
                finding warn 'wp-config perms' \
                    "${cfg_name} is world-readable (mode ${mode}); it holds the database credentials. chmod 0640"
            else
                finding_ok 'wp-config perms' "mode ${mode}"
            fi
        elif [ -n "$mode" ]; then
            finding warn 'wp-config perms' "unparsable mode '${mode}' on ${cfg_name}"
        fi
    else
        finding warn 'wp-config' "no wp-config.php found for ${site}"
    fi

    if [ "$SECURITY_WORLD_WRITABLE" = 'true' ] && [ -d "${site}/wp-content" ]; then
        local n=0
        n="$(find "${site}/wp-content" -maxdepth 4 -type f -name '*.php' -perm -o+w -print 2>/dev/null | head -n 20 | count_lines)"
        if ((n > 0)); then
            finding crit 'world-writable php' \
                "${n} world-writable PHP file(s) under wp-content (showing at most 20); any local account can edit them"
        else
            finding_ok 'world-writable php' 'none found'
        fi
    fi

    if [ "$SECURITY_UPLOADS_SCAN" = 'true' ]; then
        uploads="${site}/wp-content/uploads"
        if [ -d "$uploads" ]; then
            # Executable code in uploads is the single most common WordPress
            # backdoor location, because uploads is the one directory an
            # unauthenticated user can write to.
            local php_n=0 sus=''
            php_n="$(find "$uploads" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' -o -name '*.phar' \) -print 2>/dev/null | head -n 20 | count_lines)"
            if ((php_n > 0)); then
                sus="$(find "$uploads" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' -o -name '*.phar' \) -print 2>/dev/null | head -n 5 | tr '\n' ' ')"
                finding crit 'php in uploads' \
                    "${php_n} PHP file(s) inside wp-content/uploads, e.g. ${sus}; this is how backdoors are planted"
            else
                finding_ok 'php in uploads' 'none found'
            fi
            # Dumps and archives left in the web root are a data leak, not a
            # tidiness problem: they are served by the web server.
            local dump_n=0
            dump_n="$(find "$uploads" -maxdepth 3 -type f \
                \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.bak' -o -name '*.old' -o -name '*~' -o -name '*.tar.gz' -o -name '*.zip' \) \
                -print 2>/dev/null | head -n 20 | count_lines)"
            if ((dump_n > 0)); then
                finding warn 'backups in webroot' \
                    "${dump_n} dump/archive file(s) inside wp-content/uploads are reachable over HTTP"
            fi
        fi
    fi
    return 0
}

# audit_wp_config SITE : the constants that decide how much damage a compromise does.
audit_wp_config() { # SITE
    local site="$1" cfg v
    cfg="$(wp_config_path "$site")" || return 0

    v="$(wp_config_constant "$cfg" WP_DEBUG)"
    case "${v,,}" in
        true | 1)
            finding warn 'WP_DEBUG' 'debugging is enabled; stack traces and SQL are written where a visitor can trigger them'
            ;;
        *) finding_ok 'WP_DEBUG' 'off' ;;
    esac

    v="$(wp_config_constant "$cfg" DISALLOW_FILE_EDIT)"
    case "${v,,}" in
        true | 1) finding_ok 'DISALLOW_FILE_EDIT' 'the plugin/theme editor is disabled' ;;
        *)
            finding warn 'DISALLOW_FILE_EDIT' \
                'not set; any administrator can edit plugin PHP from the dashboard, which is the shortest path from a stolen admin account to a webshell'
            ;;
    esac

    v="$(wp_config_constant "$cfg" DISALLOW_FILE_MODS)"
    case "${v,,}" in
        true | 1) finding_ok 'DISALLOW_FILE_MODS' 'plugin/theme installation is disabled' ;;
        *) log_debug 'DISALLOW_FILE_MODS is not set (normal for most hosts)' ;;
    esac

    v="$(wp_config_constant "$cfg" WP_AUTO_UPDATE_CORE)"
    case "${v,,}" in
        false | 0)
            finding info 'WP_AUTO_UPDATE_CORE' 'core auto-updates are disabled; security releases will not apply themselves'
            ;;
        minor) finding_ok 'WP_AUTO_UPDATE_CORE' 'minor (security) releases apply automatically' ;;
        true | 1) finding_ok 'WP_AUTO_UPDATE_CORE' 'all core releases apply automatically' ;;
        *) : ;;
    esac

    # The table prefix is not a vulnerability, and calling it one trains people to
    # ignore the audit. It is reported as information, nothing more.
    v="$(wp_config_constant "$cfg" table_prefix)"
    [ -z "$v" ] && v="$(grep -o "\$table_prefix *= *'[^']*'" "$cfg" 2>/dev/null | head -n1 | sed "s/.*'\\(.*\\)'.*/\\1/")"
    if [ "$v" = 'wp_' ]; then
        finding info 'table prefix' 'the default wp_ prefix is in use'
    fi
    return 0
}

# audit_wp SITE USER URL : everything that needs a running WordPress.
audit_wp() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    local ver='' home='' n=0 body=''

    if wp_probe "$site" "$user" "$url" core version; then
        ver="$WP_PROBE"
        UNIT_WP_VERSION["$site"]="$ver"
        if [ -n "$SECURITY_MIN_WP" ] && ! version_at_least "$ver" "$SECURITY_MIN_WP"; then
            finding crit 'core version' \
                "WordPress ${ver} is below the required ${SECURITY_MIN_WP}; it no longer receives security releases"
        else
            finding_ok 'core version' "$ver"
        fi
    else
        finding crit 'core version' 'the WordPress version could not be read; the site may be broken'
    fi

    # A pending *minor* core update is an unapplied security release. That is a
    # different thing from "a new feature version is out", and it is the only
    # update finding that deserves crit.
    wp_data "$site" "$user" "$url" core check-update --format=json >/dev/null 2>&1
    if ((WP_STATUS == 0)); then
        if body="$(json_array_slice "$WP_OUTPUT")" && [ -n "$body" ] && [ "$body" != '[]' ]; then
            local tsv upver='' uptype=''
            tsv="$(printf '%s' "$body" | json_to_tsv version update_type 2>/dev/null)"
            while IFS=$'\t' read -r upver uptype; do
                [ "$upver" = 'version' ] && continue
                [ -n "$upver" ] || continue
                break
            done <<<"$tsv"
            if [ "$uptype" = 'minor' ]; then
                finding crit 'core update' \
                    "security release ${upver} is pending; minor updates are the ones that fix exploited vulnerabilities"
            else
                finding warn 'core update' "WordPress ${upver:-a newer version} is available (${uptype:-major})"
            fi
        else
            finding_ok 'core update' 'core is current'
        fi
    fi

    if home="$(site_home "$site" "$user")"; then
        case "$home" in
            https://*) finding_ok 'https' "$home" ;;
            http://*)
                finding warn 'https' "the site URL is plain HTTP (${home}); credentials and sessions travel in the clear"
                ;;
        esac
    fi

    # Checksums. `core verify-checksums` needs network access to wordpress.org;
    # when it cannot reach it, that is a warning about the audit, not a finding
    # about the site, and the difference has to be visible.
    if wp_supported "$site" "$user" core verify-checksums; then
        wp_data "$site" "$user" "$url" core verify-checksums >/dev/null 2>&1
        case "$WP_STATUS" in
            0) finding_ok 'core checksums' 'all core files match the published manifest' ;;
            255 | 1)
                finding crit 'core checksums' \
                    "core files do not match the WordPress.org manifest: $(printf '%s' "$WP_OUTPUT" | head -n 3 | tr '\n' '; ')"
                ;;
            *) finding warn 'core checksums' "verification returned ${WP_STATUS}; it may need network access" ;;
        esac
        wp_data "$site" "$user" "$url" plugin verify-checksums --all >/dev/null 2>&1
        case "$WP_STATUS" in
            0) finding_ok 'plugin checksums' 'all wordpress.org plugins match' ;;
            1)
                finding crit 'plugin checksums' \
                    "at least one plugin does not match its published files: $(printf '%s' "$WP_OUTPUT" | head -n 3 | tr '\n' '; ')"
                ;;
            *) log_debug "plugin checksum verification returned ${WP_STATUS}" ;;
        esac
    fi

    # Pending plugin updates, split by whether the plugin is active: an active
    # plugin with a pending update is exposed surface, an inactive one is clutter.
    n="$(report_count "$site" "$user" "$url" plugin list --update=available --status=active)"
    if ((n > 0)); then
        finding warn 'plugin updates' "${n} active plugin(s) have an update available"
    else
        finding_ok 'plugin updates' 'no active plugin is behind'
    fi
    n="$(report_count "$site" "$user" "$url" plugin list --update=available --status=inactive)"
    if ((n > 0)); then
        finding info 'inactive plugins' "${n} inactive plugin(s) are behind; an inactive plugin is still code on disk"
    fi

    n="$(report_count "$site" "$user" "$url" user list --role=administrator)"
    if ((SECURITY_MAX_ADMINS > 0)) && ((n > SECURITY_MAX_ADMINS)); then
        finding warn 'administrators' "${n} administrator accounts, more than the configured ${SECURITY_MAX_ADMINS}"
    else
        finding_ok 'administrators' "${n} account(s)"
    fi
    # A login literally named `admin` is the first credential a brute-force
    # attack tries, and the check costs one query. It is `info`, not `warn`:
    # on a site with a strong password and 2FA it is a style choice, and an
    # audit that shouts about style gets switched off.
    if wp_data "$site" "$user" "$url" user list --fields=user_login --format=csv >/dev/null 2>&1 \
       && ((WP_STATUS == 0)); then
        if grep -qix 'admin' <<<"$WP_OUTPUT"; then
            finding info 'admin login' 'an account with the login name "admin" exists; rename it or make sure it is 2FA-protected'
        fi
    fi
    return 0
}

# audit_secrets SITE : run the repository's own scanner over the site config.
audit_secrets() { # SITE
    local site="$1" scanner cfg
    [ "$SECURITY_SECRETS" = 'true' ] || return 0
    scanner="${SCRIPT_DIR}/tools/scan-secrets.sh"
    if [ ! -f "$scanner" ]; then
        log_debug "the secret scanner is not installed at ${scanner}; the check is skipped"
        return 0
    fi
    cfg="$(wp_config_path "$site")" || return 0
    local out='' rc=0
    out="$(bash "$scanner" --quiet "$cfg" 2>/dev/null)" || rc=$?
    if ((rc == 0)); then
        finding_ok 'hardcoded secrets' "nothing suspicious in $(path_base "$cfg")"
        return 0
    fi
    # A database password in wp-config.php is *expected*; the scanner's allowlist
    # knows that. Anything it still reports is worth a look and not a crit, so it
    # is a warning with the first findings quoted.
    finding warn 'hardcoded secrets' \
        "the scanner reported value(s) in $(path_base "$cfg"): $(printf '%s' "$out" | head -n 3 | tr '\n' '; ')"
    return 0
}

# mode_security SITE USER URL
mode_security() { # SITE USER URL
    local site="$1" user="$2" url="$3" i
    FIND_SEV=() FIND_CHECK=() FIND_MSG=()
    SITE_SCORE=100
    audit_permissions "$site"
    audit_wp_config "$site"
    audit_wp "$site" "$user" "$url"
    audit_secrets "$site"
    ((SITE_SCORE < 0)) && SITE_SCORE=0

    local crit=0 warn=0 info=0
    for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
        case "${FIND_SEV[i]}" in
            crit) crit=$((crit + 1)) ;;
            warn) warn=$((warn + 1)) ;;
            *) info=$((info + 1)) ;;
        esac
    done

    local sink
    data_sink
    sink="$DATA_SINK"
    if [ "$JSON_LINES" = 'true' ] || [ "$OUTPUT_FORMAT" = 'json' ]; then
        {
            printf '{"type":"security","path":%s,"owner":%s,"score":%s,"critical":%s,"warn":%s,"info":%s,"findings":[' \
                "$(json_quote "$site")" "$(json_quote "$user")" "$SITE_SCORE" "$crit" "$warn" "$info"
            for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
                ((i > 0)) && printf ','
                printf '{"severity":%s,"check":%s,"message":%s}' \
                    "$(json_quote "${FIND_SEV[i]}")" "$(json_quote "${FIND_CHECK[i]}")" \
                    "$(json_quote "${FIND_MSG[i]}")"
            done
            printf ']}\n'
        } | sink_append "$sink"
    elif [ "$OUTPUT_FORMAT" = 'table' ]; then
        {
            printf '%s%s%s  score %s/100  (%s crit, %s warn, %s info)\n' \
                "$C_BOLD" "$site" "$C_RESET" "$SITE_SCORE" "$crit" "$warn" "$info"
            for ((i = 0; i < ${#FIND_SEV[@]}; i++)); do
                printf '  %-5s %-22s %s\n' "${FIND_SEV[i]^^}" "${FIND_CHECK[i]}" "${FIND_MSG[i]}"
            done
            printf '\n'
        } | sink_append "$sink"
    fi

    log_info "$(path_base "$site"): security score ${SITE_SCORE}/100 (${crit} critical, ${warn} warning, ${info} info)"
    UNIT_STATUS["${site}|score"]="$SITE_SCORE"
    if ((crit > 0)); then
        return 1
    fi
    if [ "$STRICT" = 'true' ] && ((warn > 0)); then
        return 1
    fi
    return 0
}

# mode_secrets SITE USER URL : the standalone scanner run over a whole site tree.
mode_secrets() { # SITE USER URL
    local site="$1" scanner="${SCRIPT_DIR}/tools/scan-secrets.sh" out='' rc=0
    if [ ! -f "$scanner" ]; then
        log_error "the secret scanner is not installed at ${scanner}"
        return 1
    fi
    log_info "scanning ${site} for credential-looking values"
    out="$(bash "$scanner" --strict "$site" 2>&1)" || rc=$?
    if ((rc == 0)); then
        log_ok "no credential-looking values found in ${site}"
        return 0
    fi
    printf '%s\n' "$out" | head -n 40 >&2
    log_warn "the scanner reported findings in ${site} (exit ${rc})"
    STATS_FINDINGS=$((STATS_FINDINGS + 1))
    return 1
}

###############################################################################
# Section 31 - --check and --status
###############################################################################

CHECK_OK=$'\xe2\x9c\x93'
CHECK_NO=$'\xe2\x9c\x97'
CHECK_WARN='!'

# check_report SITE USER : the per-site half of --check
check_report() { # SITE USER
    local site="${1-}" user="${2:-}" rc=0 cfg='' mode=''
    printf '%s\n' "${C_BOLD}site            ${C_RESET}: ${site}"
    if [ ! -d "$site" ]; then
        printf '  %s%s%s not a directory\n' "$C_RED" "$CHECK_NO" "$C_RESET"
        return 1
    fi
    if cfg="$(wp_config_path "$site")"; then
        mode="$(file_mode "$cfg")"
        path_base "$cfg" >/dev/null
        local cfg_name="$PATH_BASE" m=0
        printf '  %s%s%s %s (mode %s)\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" \
            "$cfg_name" "${mode:-?}"
        if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
            # Bit arithmetic, not digit eyeballing: 0640 is the recommended mode
            # (the web server group can read it), and a check that flags it
            # trains operators to ignore --check. What matters is any group or
            # other write (mask 022) and other-read (the 4-bit of the last
            # digit), which exposes the database credentials to every account.
            m=$((8#${mode}))
            if ((m & 8#022)); then
                printf '  %s%s%s %s is writable by group or others; whoever is in that group owns the site\n' \
                    "$C_RED" "$CHECK_NO" "$C_RESET" "$cfg_name"
                rc=1
            elif ((m & 8#004)); then
                printf '  %s%s%s %s is world-readable (mode %s); chmod 0640 is the usual answer\n' \
                    "$C_YELLOW" "$CHECK_WARN" "$C_RESET" "$cfg_name" "$mode"
            fi
        fi
    else
        printf '  %s%s%s no wp-config.php (looked in the site root and one level up)\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET"
        rc=1
    fi
    if [ -f "${site}/wp-load.php" ]; then
        printf '  %s%s%s wp-load.php\n' "$C_GREEN" "$CHECK_OK" "$C_RESET"
    elif [ -f "${site}/wp-includes/version.php" ]; then
        printf '  %s%s%s wp-includes/version.php (no wp-load.php: a Bedrock-style layout?)\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    else
        printf '  %s%s%s not a WordPress root (no wp-load.php, no wp-includes/version.php)\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    fi
    if [ -f "${site}/.no_wp_cli" ]; then
        printf '  %s%s%s opt-out marker .no_wp_cli is present; the finder will not list this site\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
    fi
    if [ -n "$user" ]; then
        printf '  %s%s%s owner: %s\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" "$user"
    else
        printf '  %s%s%s owner: cannot be determined\n' "$C_RED" "$CHECK_NO" "$C_RESET"
        rc=1
    fi
    if [ -d "${site}/wp-content/uploads" ]; then
        if [ -w "${site}/wp-content/uploads" ] || { [ -n "$user" ] && [ "$(file_owner "${site}/wp-content/uploads")" = "$user" ]; }; then
            printf '  %s%s%s wp-content/uploads is writable by the site owner\n' \
                "$C_GREEN" "$CHECK_OK" "$C_RESET"
        else
            printf '  %s%s%s wp-content/uploads may not be writable by %s\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET" "${user:-the owner}"
        fi
    fi
    local free
    free="$(free_mib "$site" 2>/dev/null || printf 0)"
    if is_uint "$free" && ((free > 0)) && ((free < 200)); then
        printf '  %s%s%s only %s MiB free on the filesystem holding this site\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET" "$free"
        rc=1
    elif is_uint "$free" && ((free > 0)); then
        printf '  %s%s%s %s MiB free on this filesystem\n' "$C_GREEN" "$CHECK_OK" "$C_RESET" "$free"
    fi
    return "$rc"
}

# check_environment : the host half of --check
check_environment() {
    local rc=0 i user installed='' latest='' lock_kind='pid file' timeout_desc='disabled'
    printf '\n%s== environment ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'bash            : %s\n' "$BASH_VERSION"
    printf 'script          : %s %s (%s, build %s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$SCRIPT_DIR" "$BUILD_ID"
    printf 'running as      : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'hostname        : %s\n' "$(uname -n 2>/dev/null || printf '?')"
    if wp_ensure; then
        printf 'wp-cli          : %s\n' "$WP_RESOLVED"
        printf 'wp-cli resolved : %s (%s install)\n' "$(wp_realpath)" "$(wp_install_kind)"
        if installed="$(wpcli_version_local)"; then
            printf 'wp-cli version  : %s' "$installed"
            if [ -n "$WP_CLI_MIN_VERSION" ]; then
                if version_at_least "$installed" "$WP_CLI_MIN_VERSION"; then
                    printf ' %s(satisfies the %s minimum)%s\n' "$C_GREEN" "$WP_CLI_MIN_VERSION" "$C_RESET"
                else
                    printf ' %s(BELOW the %s minimum)%s\n' "$C_RED" "$WP_CLI_MIN_VERSION" "$C_RESET"
                    rc=1
                fi
            else
                printf '\n'
            fi
        else
            printf 'wp-cli version  : %scould not be determined%s\n' "$C_YELLOW" "$C_RESET"
        fi
        if [ "$WP_CLI_LATEST_CHECK" = 'true' ] && latest="$(wpcli_latest)"; then
            printf 'wp-cli newest   : %s%s\n' "$latest" \
                "$([ "$(version_compare "$installed" "$latest")" = '-1' ] && printf ' (an update is available)')"
        fi
    else
        printf 'wp-cli          : %sNOT FOUND%s (install with --wpcli-install)\n' "$C_RED" "$C_RESET"
        rc=1
    fi
    printf 'php             : %s\n' "$(command -v "${PHP_BIN:-php}" 2>/dev/null || printf 'not found')"
    printf 'user switch     : %s\n' "$(switch_mechanism)"
    have flock && lock_kind='flock'
    printf 'lock            : %s (%s, timeout %ss)\n' "$LOCK_FILE" "$lock_kind" "$LOCK_TIMEOUT"
    if ((TIMEOUT > 0)); then
        timeout_desc="${TIMEOUT}s, signal ${TIMEOUT_SIGNAL}, kill-after ${KILL_AFTER}s"
        if ! have timeout && ! portable_timeout_available; then
            timeout_desc="${timeout_desc} (NOT ENFORCEABLE: no timeout(1) and no perl(1))"
            rc=1
        fi
    fi
    printf 'timeout         : %s\n' "$timeout_desc"
    printf 'log             : %s (max %s bytes, keep %s, format %s)\n' \
        "${LOG_FILE:-<disabled>}" "$LOG_MAX_BYTES" "$LOG_KEEP" "$LOG_FORMAT"
    printf 'error log       : %s\n' "${ERROR_LOG_FILE:-<disabled>}"
    printf 'syslog          : %s\n' "$([ "$SYSLOG" = 'true' ] && printf 'on' || printf 'off')"
    printf 'config file     : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'http client     : %s\n' "$(http_client_resolve 2>/dev/null || printf 'none (release checks, smoke tests and webhooks disabled)')"
    printf 'jq              : %s\n' "$(jq_available 2>/dev/null || printf 'not used; the built-in JSON reader is active')"
    printf 'skip-plugins    : %s\n' "${SKIP_PLUGINS:-<none>}"
    printf 'allow-root      : %s\n' "$ALLOW_ROOT"
    printf 'licence         : %s\n' \
        "$([ -n "$LICENCE_VALUE" ] && printf 'configured (value redacted, handoff %s)' "$LICENCE_HANDOFF" || printf '<not configured>')"
    printf 'dry-run         : %s\n' "$DRY_RUN"
    printf 'fail-on         : %s\n' "$FAIL_ON"
    printf 'strict          : %s\n' "$STRICT"
    printf 'fail-fast       : %s\n' "$FAIL_FAST"
    printf 'jobs            : %s\n' "$JOBS"
    printf 'retry           : %s\n' "$RETRY"
    printf 'stagger         : %ss\n' "$STAGGER"
    printf 'run budget      : %s\n' "$(((MAX_DURATION > 0)) && duration_human "$MAX_DURATION" || printf 'unlimited')"
    printf 'backup          : %s%s\n' "$BACKUP" \
        "$([ "$BACKUP" != 'off' ] && printf ' -> %s (keep %s)' "$(backup_dir_of)" "$KEEP_BACKUPS")"
    printf 'maintenance mode: %s\n' "$MAINTENANCE_MODE"
    printf 'smoke test      : %s\n' "$([ "$SMOKE_TEST" = 'true' ] && printf 'on (expect %s, %ss timeout)' "$SMOKE_EXPECT" "$SMOKE_TIMEOUT" || printf 'off')"
    printf 'multisite       : %s\n' "$MULTISITE"
    printf 'only-active     : %s\n' "$ONLY_ACTIVE"
    printf 'exclude-plugins : %s\n' "${EXCLUDE_PLUGINS:-<none>}"
    printf 'include-sites   : %s\n' "${INCLUDE_SITES:-<none>}"
    printf 'exclude-sites   : %s\n' "${EXCLUDE_SITES:-<none>}"
    printf 'url             : %s\n' "${URL:-<none>}"
    printf 'state file      : %s\n' "${STATE_FILE:-<disabled>}"
    printf 'metrics file    : %s\n' "${METRICS_FILE:-<disabled>}"
    printf 'notification    : %s\n' "$(describe_notify)"

    printf '\n%s== work list ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'file            : %s\n' "$SITES_FILE"
    if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
        printf '  %s%s%s the file does not exist (AUTO_DISCOVER=%s)\n' \
            "$C_RED" "$CHECK_NO" "$C_RESET" "$AUTO_DISCOVER"
        rc=1
    else
        printf 'units           : %s\n' "$UNIT_COUNT"
        if ((UNIT_COUNT == 0)); then
            printf '  %s%s%s the list is empty, or every entry was skipped or filtered out\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        fi
        for ((i = 0; i < UNIT_COUNT; i++)); do
            user="${UNIT_USER[i]}"
            check_report "${UNIT_PATH[i]}" "$user" || rc=1
        done
    fi
    printf '\n'
    return "$rc"
}

describe_notify() {
    local parts=''
    [ "$NOTIFY_ON" = 'never' ] && { printf 'off'; return 0; }
    parts="on ${NOTIFY_ON}"
    [ -n "$NOTIFY_WEBHOOK_URL" ] && parts="${parts}, webhook (${NOTIFY_WEBHOOK_FORMAT})"
    [ -n "$NOTIFY_COMMAND" ] && parts="${parts}, command"
    printf '%s' "$parts"
}

# status_report : what the last run did, without running anything.
#
# The state file is the primary source, because it is structured and complete.
# The log is the fallback, because a host upgraded from an older release has
# logs and no state file, and "your monitoring just went blind" is not an
# acceptable answer to --status.
status_report() {
    local rc=0
    printf '\n%s== last run ==%s\n' "$C_BOLD" "$C_RESET"
    if [ -n "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; then
        printf 'state file      : %s\n' "$STATE_FILE"
        printf '%s\n' "$(head -c 8192 -- "$STATE_FILE" 2>/dev/null)"
    elif [ -n "$LOG_FILE" ] && [ -r "$LOG_FILE" ]; then
        printf 'state file      : %s\n' '<none; falling back to the log>'
        printf '\n%s-- last run headers --%s\n' "$C_BOLD" "$C_RESET"
        grep -a '=== .* started at' "$LOG_FILE" 2>/dev/null | tail -n 5
        printf '\n%s-- last 20 lines --%s\n' "$C_BOLD" "$C_RESET"
        tail -n 20 -- "$LOG_FILE" 2>/dev/null
    else
        printf '%s%s%s no state file and no readable log; nothing has been recorded yet\n' \
            "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        rc=1
    fi

    printf '\n%s== log sizes ==%s\n' "$C_BOLD" "$C_RESET"
    local f
    for f in "$LOG_FILE" "$ERROR_LOG_FILE"; do
        [ -n "$f" ] || continue
        if [ -f "$f" ]; then
            printf '%-40s %10s  %s\n' "$f" "$(human_bytes "$(file_size "$f")")" \
                "$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
        else
            printf '%-40s %10s\n' "$f" '<absent>'
        fi
        local g
        for g in "$f".1 "$f".2 "$f".3; do
            [ -f "$g" ] && printf '%-40s %10s\n' "$g" "$(human_bytes "$(file_size "$g")")"
        done
    done

    printf '\n%s== backups ==%s\n' "$C_BOLD" "$C_RESET"
    local bdir n=0 total=0
    bdir="$(backup_dir_of)"
    if [ -d "$bdir" ]; then
        printf 'directory       : %s\n' "$bdir"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$((n + 1))
            total=$((total + $(file_size "$f")))
        done < <(find "$bdir" -type f \( -name 'db-*.sql' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) -print 2>/dev/null)
        printf 'archives        : %s (%s)\n' "$n" "$(human_bytes "$total")"
        local free
        free="$(free_mib "$bdir" 2>/dev/null || printf '?')"
        printf 'free space      : %s MiB\n' "$free"
        if ((n == 0)); then
            printf '%s%s%s no archive yet; run with --backup db to create one\n' \
                "$C_YELLOW" "$CHECK_WARN" "$C_RESET"
        fi
    else
        printf 'directory       : %s (does not exist)\n' "$bdir"
    fi
    printf '\n'
    return "$rc"
}

###############################################################################
# Section 32 - fleet report streams
###############################################################################
#
# One object per unit plus a final summary object, as JSON Lines rather than a
# JSON array. A fleet run is a stream: with an array the operator gets nothing
# until the last site finishes, and a run that is killed produces invalid JSON.
# With Lines, `... --json | while read -r o; do ...` sees every site as it lands,
# and a killed run still leaves a parseable prefix.

# emit_unit_json INDEX STATUS
emit_unit_json() { # INDEX STATUS
    local i="$1" status="$2" sink
    sink="$(data_sink)"
    printf '{"type":"site","path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s}\n' \
        "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
        "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
        "$(json_quote "$status")" \
        "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" | sink_append "$sink"
    return 0
}

# run_document EXIT_CODE : the full machine-readable record of this run.
# Printed once, used by --json (as the summary line), by the state file and by
# the webhook payload, so that all three consumers see exactly the same document.
run_document() { # EXIT_CODE
    local rc="${1:-0}" i elapsed=0
    now_epoch >/dev/null
    elapsed=$((EPOCH_NOW - START_TIME))
    printf '{"type":"summary","tool":%s,"version":"%s","build":%s,"host":%s,"mode":%s,"exit":%s,' \
        "$(json_quote "$PROG_NAME")" "$SCRIPT_VERSION" "$(json_quote "$BUILD_ID")" \
        "$(json_quote "$(uname -n 2>/dev/null)")" "$(json_quote "$MODE")" "$rc"
    printf '"started_at":%s,"finished_at":%s,"duration_seconds":%s,"dry_run":%s,"jobs":%s,' \
        "$START_TIME" "$EPOCH_NOW" "$elapsed" "$DRY_RUN" "$JOBS"
    printf '"backup":%s,"sites_total":%s,"sites_ok":%s,"sites_failed":%s,"sites_skipped":%s,' \
        "$(json_quote "$BACKUP")" "$STATS_SITES_TOTAL" "$STATS_SITES_OK" \
        "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED"
    printf '"ops_ok":%s,"ops_failed":%s,"warnings":%s,"retries":%s,"backups":%s,' \
        "$STATS_OPS_OK" "$STATS_OPS_FAILED" "$STATS_WARNINGS" "$STATS_RETRIES" "$STATS_BACKUPS"
    printf '"smoke_ok":%s,"smoke_failed":%s,"findings":%s,"critical":%s,"cleaned":%s,' \
        "$STATS_SMOKE_OK" "$STATS_SMOKE_FAILED" "$STATS_FINDINGS" "$STATS_CRITICAL" "$STATS_CLEANED"
    printf '"stopped_early":%s,"stop_reason":%s,"wpcli_version":%s,"results":[' \
        "$([ "$STOPPED_EARLY" = 'true' ] && printf 'true' || printf 'false')" \
        "$(json_quote "$STOP_REASON")" "$(json_quote "$WP_CLI_VERSION")"
    local first=1
    for ((i = 0; i < UNIT_COUNT; i++)); do
        ((first)) || printf ','
        first=0
        printf '{"path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s,"wp_version":%s}' \
            "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
            "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
            "$(json_quote "${UNIT_STATUS[${UNIT_LABEL[i]}]-UNKNOWN}")" \
            "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" \
            "$(json_quote "${UNIT_WP_VERSION[${UNIT_PATH[i]}]-}")"
    done
    printf ']}\n'
    return 0
}

emit_summary_json() { # EXIT_CODE
    run_document "$1" | sink_append "$(data_sink)"
    return 0
}

###############################################################################
# Section 33 - state file and Prometheus metrics
###############################################################################
#
# Both are written atomically, after the summary and even after an interrupt, so
# a monitoring system never reads a half-written document and never misses the
# run that crashed. Both are optional: a host with no monitoring should not have
# to disable anything to use this tool.

write_state_file() { # EXIT_CODE
    [ -n "$STATE_FILE" ] || return 0
    if ! ensure_parent_dir "$STATE_FILE"; then
        log_warn "cannot create the directory for the state file ${STATE_FILE}"
        return 0
    fi
    if ! run_document "$1" | atomic_write "$STATE_FILE"; then
        log_warn "cannot write the state file ${STATE_FILE}"
        return 0
    fi
    log_debug "state written to ${STATE_FILE}"
    return 0
}

# write_metrics_file EXIT_CODE
#
# Prometheus textfile-collector format. Gauges only, one label set per unit, and
# a `wpu_up` series so that "the exporter stopped" is distinguishable from
# "everything is fine". A label value carries the site path, which is why the
# path is escaped for Prometheus rather than for JSON: the two languages differ
# in exactly the characters that appear in real paths.
prom_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

write_metrics_file() { # EXIT_CODE
    local rc="${1:-0}" i status elapsed
    [ -n "$METRICS_FILE" ] || return 0
    if ! ensure_parent_dir "$METRICS_FILE"; then
        log_warn "cannot create the directory for the metrics file ${METRICS_FILE}"
        return 0
    fi
    {
        printf '# HELP wpu_up The last maintenance run completed and wrote these metrics.\n'
        printf '# TYPE wpu_up gauge\n'
        printf 'wpu_up 1\n'
        printf '# HELP wpu_info Build and mode of the last run.\n'
        printf '# TYPE wpu_info gauge\n'
        printf 'wpu_info{version="%s",build="%s",mode="%s",host="%s"} 1\n' \
            "$(prom_escape "$SCRIPT_VERSION")" "$(prom_escape "$BUILD_ID")" \
            "$(prom_escape "$MODE")" "$(prom_escape "$(uname -n 2>/dev/null)")"
        printf '# HELP wpu_exit_code Exit code of the last run.\n'
        printf '# TYPE wpu_exit_code gauge\n'
        printf 'wpu_exit_code %s\n' "$rc"
        printf '# HELP wpu_run_timestamp_seconds Unix time of the last run.\n'
        printf '# TYPE wpu_run_timestamp_seconds gauge\n'
        now_epoch >/dev/null
        printf 'wpu_run_timestamp_seconds %s\n' "$EPOCH_NOW"
        printf '# HELP wpu_duration_seconds Wall-clock duration of the last run.\n'
        printf '# TYPE wpu_duration_seconds gauge\n'
        printf 'wpu_duration_seconds %s\n' "$((EPOCH_NOW - START_TIME))"
        printf '# HELP wpu_sites_total Work units processed in the last run.\n'
        printf '# TYPE wpu_sites_total gauge\n'
        printf 'wpu_sites_total %s\n' "$STATS_SITES_TOTAL"
        printf '# HELP wpu_sites_ok Work units that finished without error.\n'
        printf '# TYPE wpu_sites_ok gauge\n'
        printf 'wpu_sites_ok %s\n' "$STATS_SITES_OK"
        printf '# HELP wpu_sites_failed Work units with at least one failed operation.\n'
        printf '# TYPE wpu_sites_failed gauge\n'
        printf 'wpu_sites_failed %s\n' "$STATS_SITES_FAILED"
        printf '# HELP wpu_sites_skipped Entries skipped before processing.\n'
        printf '# TYPE wpu_sites_skipped gauge\n'
        printf 'wpu_sites_skipped %s\n' "$STATS_SITES_SKIPPED"
        printf '# HELP wpu_ops_ok WP-CLI operations that succeeded.\n'
        printf '# TYPE wpu_ops_ok gauge\n'
        printf 'wpu_ops_ok %s\n' "$STATS_OPS_OK"
        printf '# HELP wpu_ops_failed WP-CLI operations that failed.\n'
        printf '# TYPE wpu_ops_failed gauge\n'
        printf 'wpu_ops_failed %s\n' "$STATS_OPS_FAILED"
        printf '# HELP wpu_warnings Warnings logged during the last run.\n'
        printf '# TYPE wpu_warnings gauge\n'
        printf 'wpu_warnings %s\n' "$STATS_WARNINGS"
        printf '# HELP wpu_findings Audit findings from --security and --verify.\n'
        printf '# TYPE wpu_findings gauge\n'
        printf 'wpu_findings %s\n' "$STATS_FINDINGS"
        printf '# HELP wpu_findings_critical Critical audit findings.\n'
        printf '# TYPE wpu_findings_critical gauge\n'
        printf 'wpu_findings_critical %s\n' "$STATS_CRITICAL"
        printf '# HELP wpu_backups Archives written during the last run.\n'
        printf '# TYPE wpu_backups gauge\n'
        printf 'wpu_backups %s\n' "$STATS_BACKUPS"
        printf '# HELP wpu_smoke_failed Post-update smoke tests that failed.\n'
        printf '# TYPE wpu_smoke_failed gauge\n'
        printf 'wpu_smoke_failed %s\n' "$STATS_SMOKE_FAILED"
        printf '# HELP wpu_stopped_early The run stopped before the end of the site list.\n'
        printf '# TYPE wpu_stopped_early gauge\n'
        printf 'wpu_stopped_early %s\n' "$([ "$STOPPED_EARLY" = 'true' ] && printf 1 || printf 0)"
        printf '# HELP wpu_unit_status Per-unit outcome: 1 ok, 0 failed, -1 skipped.\n'
        printf '# TYPE wpu_unit_status gauge\n'
        for ((i = 0; i < UNIT_COUNT; i++)); do
            status="${UNIT_STATUS[${UNIT_LABEL[i]}]-UNKNOWN}"
            case "$status" in
                OK) status=1 ;;
                SKIPPED) status=-1 ;;
                *) status=0 ;;
            esac
            printf 'wpu_unit_status{path="%s",label="%s",owner="%s",url="%s"} %s\n' \
                "$(prom_escape "${UNIT_PATH[i]}")" "$(prom_escape "${UNIT_LABEL[i]}")" \
                "$(prom_escape "${UNIT_USER[i]}")" "$(prom_escape "${UNIT_URL[i]}")" "$status"
        done
        printf '# HELP wpu_unit_elapsed_seconds Per-unit wall-clock duration.\n'
        printf '# TYPE wpu_unit_elapsed_seconds gauge\n'
        for ((i = 0; i < UNIT_COUNT; i++)); do
            printf 'wpu_unit_elapsed_seconds{path="%s",label="%s"} %s\n' \
                "$(prom_escape "${UNIT_PATH[i]}")" "$(prom_escape "${UNIT_LABEL[i]}")" \
                "${UNIT_ELAPSED[i]-0}"
        done
    } | atomic_write "$METRICS_FILE" || {
        log_warn "cannot write the metrics file ${METRICS_FILE}"
        return 0
    }
    log_debug "metrics written to ${METRICS_FILE}"
    return 0
}

emit_state_and_metrics() { # EXIT_CODE
    write_state_file "$1"
    write_metrics_file "$1"
    return 0
}

###############################################################################
# Section 34 - notifications
###############################################################################
#
# A maintenance run that finishes at 03:12 and tells nobody is a run whose
# failure is discovered by a customer. Two channels are supported and both are
# deliberately dumb:
#
#   webhook  a JSON POST. Slack, Discord, Telegram, Mattermost, an n8n hook and
#            a hundred internal gateways all accept one; the payload shape is
#            configurable because their field names differ and nothing else does.
#   command  an executable, invoked with the summary in argv and in the
#            environment. It is never passed through a shell, so a config file
#            cannot turn a notification into arbitrary code -- it can name an
#            executable, which is a strictly smaller grant than a shell would be.
#
# A notification failure is a warning, never a run failure: the maintenance work
# happened, and paging somebody because the pager is down hides that fact.

# notify_summary_text -> one short human-readable line for a chat channel
notify_summary_text() { # EXIT_CODE
    local rc="${1:-0}" dry=
    now_epoch >/dev/null
    duration_human "$((EPOCH_NOW - START_TIME))" >/dev/null
    [ "$DRY_RUN" = 'true' ] && dry=' [dry-run]'
    printf '%s %s %s on %s: %s site(s), %s ok, %s failed, %s skipped, %s operation(s) failed, %s warning(s), %s%s' \
        "$PROG_NAME" "$SCRIPT_VERSION" "$MODE" "$(uname -n 2>/dev/null || printf '?')" \
        "$STATS_SITES_TOTAL" "$STATS_SITES_OK" "$STATS_SITES_FAILED" "$STATS_SITES_SKIPPED" \
        "$STATS_OPS_FAILED" "$STATS_WARNINGS" "$DURATION_HUMAN" "$dry"
    return 0
}

notify_webhook() { # EXIT_CODE
    local rc="${1:-0}" text body=''
    [ -n "$NOTIFY_WEBHOOK_URL" ] || return 0
    if ! http_client_resolve >/dev/null 2>&1; then
        log_warn 'a webhook is configured but no HTTP client is installed; the notification was not sent'
        return 0
    fi
    text="$(notify_summary_text "$rc")"
    case "$NOTIFY_WEBHOOK_FORMAT" in
        slack) body="$(printf '{"text":%s}' "$(json_quote "$text")")" ;;
        discord) body="$(printf '{"content":%s}' "$(json_quote "$text")")" ;;
        telegram) body="$(printf '{"text":%s,"disable_web_page_preview":true}' "$(json_quote "$text")")" ;;
        generic | *) body="$(run_document "$rc")" ;;
    esac
    if http_post_json "$NOTIFY_WEBHOOK_URL" "$body" 20; then
        log_ok "notification posted to the ${NOTIFY_WEBHOOK_FORMAT} webhook"
    else
        log_warn "the webhook at ${NOTIFY_WEBHOOK_URL} did not accept the notification"
    fi
    return 0
}

notify_command() { # EXIT_CODE
    local rc="${1:-0}" summary=
    [ -n "$NOTIFY_COMMAND" ] || return 0
    now_epoch >/dev/null
    summary="$(notify_summary_text "$rc")"
    if [ ! -x "$NOTIFY_COMMAND" ]; then
        log_warn "NOTIFY_COMMAND is not an executable file: ${NOTIFY_COMMAND}"
        return 0
    fi
    local out='' nrc=0
    # The summary travels in both argv and the environment: argv is convenient
    # for a one-liner script, the environment is convenient for anything that
    # wants to branch on a number. Neither goes through a shell.
    out="$(
        WPU_EXIT="$rc" \
        WPU_MODE="$MODE" \
        WPU_VERSION="$SCRIPT_VERSION" \
        WPU_HOST="$(uname -n 2>/dev/null)" \
        WPU_SITES_TOTAL="$STATS_SITES_TOTAL" \
        WPU_SITES_OK="$STATS_SITES_OK" \
        WPU_SITES_FAILED="$STATS_SITES_FAILED" \
        WPU_SITES_SKIPPED="$STATS_SITES_SKIPPED" \
        WPU_OPS_OK="$STATS_OPS_OK" \
        WPU_OPS_FAILED="$STATS_OPS_FAILED" \
        WPU_WARNINGS="$STATS_WARNINGS" \
        WPU_FINDINGS="$STATS_FINDINGS" \
        WPU_CRITICAL="$STATS_CRITICAL" \
        WPU_DURATION="$((EPOCH_NOW - START_TIME))" \
        WPU_DRY_RUN="$DRY_RUN" \
        WPU_STATE_FILE="$STATE_FILE" \
        WPU_LOG_FILE="$LOG_FILE" \
        WPU_ERROR_LOG_FILE="$ERROR_LOG_FILE" \
        WPU_SUMMARY="$summary" \
            "$NOTIFY_COMMAND" \
            --exit "$rc" --mode "$MODE" \
            --sites "$STATS_SITES_TOTAL" --ok "$STATS_SITES_OK" \
            --failed "$STATS_SITES_FAILED" --skipped "$STATS_SITES_SKIPPED" \
            --warnings "$STATS_WARNINGS" --duration "$((EPOCH_NOW - START_TIME))" \
            --state-file "$STATE_FILE" --log-file "$LOG_FILE" 2>&1 </dev/null
    )" || nrc=$?
    if ((nrc != 0)); then
        log_warn "the notification command exited ${nrc}: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
    else
        log_debug "notification command ran: ${NOTIFY_COMMAND}"
    fi
    return 0
}

notify_run() { # EXIT_CODE
    local rc="${1:-0}"
    case "$NOTIFY_ON" in
        always) : ;;
        failure) ((rc == 0)) && return 0 ;;
        never | *) return 0 ;;
    esac
    if [ "$DRY_RUN" = 'true' ]; then
        log_debug 'a dry run does not notify'
        return 0
    fi
    notify_webhook "$rc"
    notify_command "$rc"
    return 0
}

###############################################################################
# Section 35 - summary and exit code
###############################################################################

# print_summary EXIT_CODE
print_summary() { # EXIT_CODE
    local rc="${1:-0}" elapsed=0 line
    now_epoch >/dev/null
    elapsed=$((EPOCH_NOW - START_TIME))
    SUMMARY_PRINTED='true'
    line="$(printf '%*s' 70 '')"
    {
        printf -- '----------------------------------------------------------------------\n'
        printf '%s summary\n' "$PROG_NAME"
        printf -- '----------------------------------------------------------------------\n'
        printf '  %-22s %s\n' 'mode:' "$MODE"
        printf '  %-22s %s\n' 'sites processed:' "$STATS_SITES_TOTAL"
        printf '  %-22s %s\n' 'sites ok:' "$STATS_SITES_OK"
        printf '  %-22s %s\n' 'sites failed:' "$STATS_SITES_FAILED"
        printf '  %-22s %s\n' 'sites skipped:' "$STATS_SITES_SKIPPED"
        printf '  %-22s %s\n' 'operations ok:' "$STATS_OPS_OK"
        printf '  %-22s %s\n' 'operations failed:' "$STATS_OPS_FAILED"
        printf '  %-22s %s\n' 'warnings:' "$STATS_WARNINGS"
        if ((STATS_RETRIES > 0)); then
            printf '  %-22s %s\n' 'retries:' "$STATS_RETRIES"
        fi
        if ((STATS_BACKUPS > 0)); then
            printf '  %-22s %s\n' 'backups written:' "$STATS_BACKUPS"
        fi
        if ((STATS_SMOKE_OK + STATS_SMOKE_FAILED > 0)); then
            printf '  %-22s %s ok, %s failed\n' 'smoke tests:' "$STATS_SMOKE_OK" "$STATS_SMOKE_FAILED"
        fi
        if ((STATS_FINDINGS > 0)); then
            printf '  %-22s %s (%s critical)\n' 'audit findings:' "$STATS_FINDINGS" "$STATS_CRITICAL"
        fi
        if ((STATS_CLEANED > 0)); then
            printf '  %-22s %s\n' 'objects removed:' "$STATS_CLEANED"
        fi
        if [ "$STOPPED_EARLY" = 'true' ]; then
            printf '  %-22s %s%s%s (%s)\n' 'stopped early:' "$C_YELLOW" 'yes' "$C_RESET" "$STOP_REASON"
        fi
        if ((JOBS > 1)); then
            printf '  %-22s %s\n' 'parallelism:' "${JOBS} units per batch"
        fi
        if [ "$BACKUP" != 'off' ]; then
            printf '  %-22s %s\n' 'backup:' "${BACKUP} -> $(backup_dir_of) (keep ${KEEP_BACKUPS})"
        fi
        printf '  %-22s %s (%ss)\n' 'duration:' "$(duration_human "$elapsed")" "$elapsed"
        [ -n "$LOG_FILE" ] && printf '  %-22s %s\n' 'log:' "$LOG_FILE"
        [ -n "$ERROR_LOG_FILE" ] && printf '  %-22s %s\n' 'error log:' "$ERROR_LOG_FILE"
        [ -n "$STATE_FILE" ] && printf '  %-22s %s\n' 'state file:' "$STATE_FILE"
        [ -n "$METRICS_FILE" ] && printf '  %-22s %s\n' 'metrics file:' "$METRICS_FILE"
        printf -- '----------------------------------------------------------------------\n'
        if ((rc == 0)); then
            printf '%s%s run finished without errors%s\n' "$C_GREEN" "$CHECK_OK" "$C_RESET"
        else
            printf '%s%s run finished with errors (exit %s)%s\n' "$C_RED" "$CHECK_NO" "$rc" "$C_RESET"
        fi
    } >&2

    if [ "$JSON_LINES" = 'true' ]; then
        emit_summary_json "$rc"
    fi
    return 0
}

# final_exit_code -> 0 or 1, before the special codes are applied.
#
# --strict turns "it ran, but something smelled" into a non-zero exit, which is
# what a pipeline needs: a warning about a stale lock or a skipped site is
# invisible to cron otherwise. It is checked before the --fail-on policy, because
# `--fail-on never --strict` has to mean "ignore site failures, but not
# warnings", not "ignore everything".
final_exit_code() {
    if [ "$STRICT" = 'true' ] && ((STATS_WARNINGS > 0)); then
        log_warn "--strict: ${STATS_WARNINGS} warning(s) make this run a failure"
        return 1
    fi
    if [ "$STRICT" = 'true' ] && ((STATS_CRITICAL > 0)); then
        log_warn "--strict: ${STATS_CRITICAL} critical finding(s) make this run a failure"
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

# finish_run EXIT_HINT : the single exit path of a fleet run.
#
# Every terminal branch of main() used to repeat "compute the code, print the
# summary, write the state, notify, exit" in a slightly different order, and the
# differences were bugs: an interrupted run printed a summary but wrote no state
# file, so the dashboard showed the previous night's numbers. One function, one
# order, no drift.
finish_run() { # EXIT_HINT
    local hint="${1:-0}" code=0
    final_exit_code || code="$EXIT_ERROR"
    if [ "$STOPPED_EARLY" = 'true' ] && ((code == 0)); then
        code="$EXIT_STOPPED"
    fi
    if ((hint != 0)) && ((code == 0)); then
        code="$hint"
    fi
    print_summary "$code"
    emit_state_and_metrics "$code"
    notify_run "$code"
    log_info "finished with exit ${code}"
    SUMMARY_PRINTED='true'
    exit "$code"
}

###############################################################################
# Section 36 - the mode table
###############################################################################
#
# One row per mode: name, short flag, one-line description, and whether it
# changes anything. The table drives --help, --list-modes, the shell completion
# and the "exactly one mode" check, which is why adding a mode means adding a row
# here, a function in section 23-31, and a case branch in process_site -- and
# nothing else.
#
# Fields: NAME|SHORT|READONLY|DESCRIPTION
MODE_TABLE=(
    'full|-f|no|core, schema, plugins, themes, translations, cron, caches, db optimize (+ Astra when licensed)'
    'core|-c|no|core update and database schema update'
    'plugins|-p|no|update all plugins (or the selected set with --only-active / --exclude-plugins)'
    'themes|-t|no|update all themes'
    'languages|-L|no|update core, plugin and theme translations'
    'cache|-C|no|flush the object cache, delete transients, flush rewrite rules'
    'cleanup|-X|no|delete revisions, trash, spam and expired transients (needs --yes)'
    'db-optimize|-d|no|db optimize and db repair'
    'db-fix|-x|no|db repair only'
    'cron|-r|no|run cron events that are due'
    'astra|-s|no|update the Astra add-on, activating the licence when needed'
    'verify|--verify|yes|read-only checksum verification of core and plugins'
    'report|--report|yes|read-only fleet health inventory (versions, updates, sizes, cron)'
    'security|--security|yes|read-only hardening and integrity audit with a 0-100 score'
    'secrets|--secrets|yes|scan a site tree for credential-looking values'
    'list-plugins|-l|yes|list plugins as table, json, csv or tsv'
    'plugin-manage|-m|no|install, activate, deactivate, update, delete or inspect one plugin'
    'restore|--restore|no|list the backups of a site, or restore one (needs --yes)'
    'check|--check|yes|validate the host and every site, change nothing'
    'status|--status|yes|print the last run, the log sizes and the backup inventory'
    'list-sites|--list-sites|yes|print the resolved work list and exit'
    'wpcli-check|--wpcli-check|yes|report the WP-CLI version against the minimum and the newest release'
    'wpcli-update|--wpcli-update|no|update the wp binary (verified download, timestamped backup)'
    'wpcli-install|--wpcli-install|no|install WP-CLI when it is missing'
    'wpcli-rollback|--wpcli-rollback|no|put a previous wp binary back'
    'list-modes|--list-modes|yes|print the mode names, one per line (for shell completion)'
    'print-config|--print-config|yes|show every effective setting and the layer that produced it'
    'init-config|--init-config|yes|write a commented configuration file and exit'
    'completion|--completion|yes|print a bash or zsh completion script and exit'
)

# mode_field NAME INDEX
mode_field() {
    local row name
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        name="${row%%|*}"
        if [ "$name" = "${1-}" ]; then
            config_spec_field "$row" "${2:-1}"
            return 0
        fi
    done
    return 1
}

# mode_is_readonly NAME
#
# Reads SPEC_FIELD instead of capturing stdout: this is asked once per work unit
# (the smoke test needs to know whether the mode changed anything), so a subshell
# here would be one fork per site for a yes/no answer.
mode_is_readonly() {
    mode_field "${1-}" 2 >/dev/null
    [ "$SPEC_FIELD" = 'yes' ]
}

# mode_exists NAME
mode_exists() {
    mode_field "${1-}" 0 >/dev/null
}

list_modes() {
    local row
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        printf '%s\n' "${row%%|*}"
    done
    return 0
}

###############################################################################
# Section 37 - help
###############################################################################

usage() { # [EXIT_CODE]
    local rc="${1:-$EXIT_USAGE}" row name short ro desc
    cat <<EOF
${C_BOLD}${PROG_NAME} ${SCRIPT_VERSION}${C_RESET} - WordPress fleet maintenance via WP-CLI

${C_BOLD}Usage${C_RESET}
  ${PROG_NAME} <MODE> [options]
  ${PROG_NAME} --check [--site PATH]
  ${PROG_NAME} --status
  ${PROG_NAME} --wpcli-check | --wpcli-update | --wpcli-install | --wpcli-rollback

${C_BOLD}Modes (exactly one; read-only modes are marked ro)${C_RESET}
EOF
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        name="${row%%|*}"
        config_spec_field "$row" 1 >/dev/null; short="$SPEC_FIELD"
        config_spec_field "$row" 2 >/dev/null; ro="$SPEC_FIELD"
        config_spec_field "$row" 3 >/dev/null; desc="$SPEC_FIELD"
        # Both forms line up on the same column so the descriptions read as one
        # list instead of two: 6 spaces + 18 for a long-only mode, or a 3-character
        # short flag plus a space plus 18 for a mode that has one.
        if [ "${short#--}" != "$short" ]; then
            printf '      %-18s %s%s\n' "$short" "$desc" "$([ "$ro" = yes ] && printf '  %s[ro]%s' "$C_DIM" "$C_RESET")"
        else
            printf '  %-3s %-18s %s%s\n' "${short}," "--${name}" "$desc" "$([ "$ro" = yes ] && printf '  %s[ro]%s' "$C_DIM" "$C_RESET")"
        fi
    done
    cat <<EOF

${C_BOLD}Selection${C_RESET}
  -S, --site PATH        operate on one site only (overrides the site list)
      --sites FILE       site list, one absolute path per line; '-' reads stdin
                         (a TAB after the path forces the owner for that entry)
      --include GLOB     only process paths matching GLOB (repeatable)
      --exclude GLOB     never process paths matching GLOB (repeatable)
      --max-sites N      process at most N units (0 = all, default ${MAX_SITES})
      --user NAME        force the system user for every site (skips detection)
      --multisite MODE   auto | off | main | all - expand a multisite into its
                         subsites and operate on each one with --url
  -U, --url URL          pass --url to WP-CLI on every call
  -j, --jobs N           process N units in parallel batches (default ${JOBS})
      --stagger SEC      sleep SEC between sites (sequential runs)
      --retry N          re-attempt a failing site N times (default ${RETRY})
      --fail-fast        stop the fleet after the first failing site
      --max-duration SEC whole-run budget; stop between sites when it is used up

${C_BOLD}Plugin management${C_RESET}
  -A, --action ACTION    install | activate | deactivate | update | delete | status
  -N, --name NAME        plugin name or slug; case-insensitive substring, never a pattern
  -F, --force            skip the confirmation prompt
  -y, --yes              same as --force, for scripted use; also applies --cleanup
      --only-active      with --plugins/--full: update only active plugins that
                         have an update available (enumerated, not --all)
  -e, --exclude-plugins LIST
                         comma separated slugs or names to leave out of
                         --plugins/--full; implies enumeration

${C_BOLD}Restore and rollback${C_RESET}
      --from WHAT        backup number or path (--restore), or wp binary backup
                         number (--wpcli-rollback); default: the newest
      --restore-files    allow a whole-tree or plugin archive to be extracted

${C_BOLD}Output${C_RESET}
      --format FMT       table | json | csv | tsv   (default: ${OUTPUT_FORMAT})
  -J, --json             with --list-plugins/--report: --format json;
                         in a fleet mode: the JSON Lines fleet report
      --json-lines       one JSON object per unit plus a summary object
      --fields LIST      columns for --list-plugins (default: ${PLUGIN_FIELDS_DEFAULT})
      --page-limit N     rows per table (0 = all, default ${PAGE_LIMIT})
      --color WHEN       auto | always | never (default: ${COLOR})
      --no-color         same as --color never; NO_COLOR is also honoured
  -q, --quiet            console shows warnings and errors only
  -v, --verbose          show the commands as they are executed
  -D, --debug            verbose logging; implies --log-level debug

${C_BOLD}Backups${C_RESET}
  -b, --backup MODE      off | db | full (default: ${BACKUP})
                           db    'wp db export' before the site is touched
                           full  tar.gz of the whole installation - slow and big
      --no-backup        never back up, including before a plugin delete
  -B, --backup-dir DIR   where to put backups (default: <script dir>/backups)
      --keep-backups N   backups kept per site and kind (0 = all, default ${KEEP_BACKUPS})
      --min-free-space N abort a backup when fewer than N MiB are free

${C_BOLD}Safety${C_RESET}
  -n, --dry-run          print the real argv, execute nothing
      --no-user-switch   run WP-CLI as the invoking user instead of switching
                         into the site owner (single-site hosts, and test suites)
      --maintenance-mode put each site in maintenance mode while it is updated
      --strict           exit non-zero when anything was warned about
      --timeout SEC      per-command timeout, 0 disables (default ${TIMEOUT})
      --signal SIG       timeout signal: HUP INT QUIT TERM USR1 USR2 KILL
      --kill-after SEC   escalate to KILL after SEC (default ${KILL_AFTER})
      --allow-root WHEN  auto | always | never (default: ${ALLOW_ROOT})
      --skip-plugins L   plugins to skip on mutating plugin/theme operations
      --skip-plugins-for-listing true|false
                         also pass --skip-plugins to list commands (default false)
      --fail-on WHEN     any | all | never - when to exit non-zero (default ${FAIL_ON})
      --no-lock          do not take the run lock (nested or manual runs only)
      --lock-timeout SEC wait this long for the lock instead of failing
      --lock-required    refuse to run when the lock cannot be taken
      --no-discover      do not run the finder when the site list is missing

${C_BOLD}WP-CLI itself${C_RESET}
      --wp PATH          path to the wp binary (default: ${WP_CLI_PATH})
      --wpcli-min-version V
                         refuse to run on an older WP-CLI (default ${WP_CLI_MIN_VERSION})
      --wpcli-latest-check true|false
                         compare with the newest upstream release (default ${WP_CLI_LATEST_CHECK})
      --wpcli-channel C  stable | nightly (default ${WP_CLI_UPDATE_CHANNEL})
      --wpcli-scope S    auto | patch | minor | major (default ${WP_CLI_UPDATE_SCOPE})
      --wpcli-version V  pin the update to one version (verified direct download)
      --wpcli-no-verify  install a downloaded phar without GPG/checksum verification
      --wpcli-insecure   let the updater retry without TLS verification
      --php PATH         php binary used for a direct phar install (default ${PHP_BIN})

${C_BOLD}Reporting and notification${C_RESET}
      --state-file FILE  write a JSON document describing the run
      --metrics-file FILE
                         write Prometheus textfile-collector metrics
      --notify WHEN      never | failure | always (default ${NOTIFY_ON})
      --webhook URL      POST the summary to this webhook
      --webhook-format F generic | slack | discord | telegram
      --notify-command P executable given the summary as argv and environment
      --smoke-test       fetch each site URL after it was changed
      --smoke-timeout S  seconds allowed for the smoke request (default ${SMOKE_TIMEOUT})
      --smoke-expect L   accepted HTTP status codes (default ${SMOKE_EXPECT})

${C_BOLD}Configuration${C_RESET}
      --config FILE      read settings from FILE instead of the default two
      --print-config     show every effective setting and its layer, then exit
      --init-config [F]  write a fully commented configuration file (or stdout)
      --completion SHELL print a bash or zsh completion script
      --log-file FILE    main log (default: ${LOG_FILE})
      --error-log-file FILE
      --log-level LVL    debug | info | warn | error (default ${LOG_LEVEL})
      --log-format FMT   text | json (default ${LOG_FORMAT})
      --syslog           mirror log lines to syslog via logger(1)
      --lock-file FILE   run lock (default: ${LOCK_FILE})
      --user-env LIST    variable NAMES passed through to the site owner env
      --astra-key KEY    Astra licence; prefer WP_CLI_UPDATE_LICENCE or a key file
      --astra-slug SLUG  Astra add-on slug (default ${ASTRA_SLUG})

${C_BOLD}Other${C_RESET}
  -h, --help             this help, exit 0
  -V, --version          print the version, exit 0
      --version-detail   version, build id, feature probes and the licence

${C_BOLD}Exit codes${C_RESET}
  0  success                  1  at least one operation failed
  2  usage error               3  environment error (no wp, too old, lock, privileges)
  4  configuration error       5  nothing to act on
  6  stopped early (--fail-fast, --max-duration)

${C_BOLD}Configuration precedence${C_RESET}
  built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf
                    < WP_CLI_UPDATE_* environment < command line

${C_BOLD}Secrets${C_RESET}
  The Astra licence is never an argument of this process. By default it is piped
  to the child over stdin and read there at run time; LICENCE_HANDOFF=file uses a
  temporary file instead. Either way it appears in no log line, no dry-run
  listing, no report and no error box, because every outgoing string is passed
  through a redactor that knows the value. Sources, in order: --astra-key, the
  LICENCE setting, WP_CLI_UPDATE_LICENCE, ASTRA_KEY, ASTRA_LICENSE_KEY, then the
  first readable file among ./astra.key, /etc/wp-cli-update/astra.key,
  \$HOME/.astra.key, \$HOME/.config/astra.key.

${C_BOLD}Parallelism${C_RESET}
  -j N runs the fleet in batches of N. Bash 4.2 has no 'wait -n', so this is a
  batch barrier, not a continuous pool: the next batch starts when the slowest
  unit of the current one finishes. Per-unit console output, log lines and data
  are buffered and replayed in site order after each barrier, so nothing
  interleaves. During a parallel run the log therefore grows at the barrier, not
  while the work happens, and 'tail -f' looks stalled until the batch lands.

${C_BOLD}Examples${C_RESET}
  ${PROG_NAME} --check
  ${PROG_NAME} --report --format table
  ${PROG_NAME} --security --json-lines
  ${PROG_NAME} --full
  ${PROG_NAME} --full -j 4 --backup db --keep-backups 2 --smoke-test
  ${PROG_NAME} -p --only-active -e 'jetpack,woocommerce' -j 8
  ${PROG_NAME} --cleanup -S /var/www/example.com --yes
  ${PROG_NAME} --cache
  ${PROG_NAME} --verify --strict --json-lines
  ${PROG_NAME} --wpcli-check
  ${PROG_NAME} --wpcli-update --wpcli-scope minor --yes
  ${PROG_NAME} --wpcli-update --wpcli-version 2.11.0
  ${PROG_NAME} -l --name woo --format csv
  ${PROG_NAME} -m -A deactivate -N jetpack -S /var/www/example.com -y
  ${PROG_NAME} -d --dry-run --timeout 120
  ${PROG_NAME} --restore -S /var/www/example.com
  ${PROG_NAME} --init-config /etc/wp-cli-update.conf
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

version_detail() {
    local installed=''
    printf '%s %s (build %s, %s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$BUILD_ID" "$BUILD_DATE"
    printf 'finder version   : %s\n' "$FINDER_VERSION"
    printf 'script directory : %s\n' "$SCRIPT_DIR"
    printf 'bash             : %s\n' "$BASH_VERSION"
    printf 'running as       : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'user switch      : %s\n' "$(switch_mechanism)"
    if wp_ensure 2>/dev/null; then
        printf 'wp-cli           : %s\n' "$WP_RESOLVED"
        installed="$(wpcli_version_local 2>/dev/null)" || installed='<unknown>'
        printf 'wp-cli version   : %s (minimum %s)\n' "$installed" "${WP_CLI_MIN_VERSION:-none}"
    else
        printf 'wp-cli           : not found\n'
    fi
    printf 'php              : %s\n' "$(command -v "${PHP_BIN:-php}" 2>/dev/null || printf 'not found')"
    printf 'flock            : %s\n' "$(have flock && printf yes || printf 'no (pid-file locking)')"
    printf 'timeout          : %s\n' "$(have timeout && printf yes || printf 'no (perl supervisor or none)')"
    printf 'perl             : %s\n' "$(have perl && printf yes || printf no)"
    printf 'jq               : %s\n' "$(jq_available >/dev/null 2>&1 && printf 'yes (used)' || printf 'no (built-in reader)')"
    printf 'http client      : %s\n' "$(http_client_resolve 2>/dev/null || printf none)"
    printf 'tar              : %s\n' "$(have tar && printf yes || printf 'no (--backup full degrades to db)')"
    printf 'gpg              : %s\n' "$(have gpg && printf yes || printf 'no (checksum verification only)')"
    printf 'logger           : %s\n' "$(have logger && printf yes || printf 'no (--syslog unavailable)')"
    printf 'modes            : %s\n' "$(list_modes | tr '\n' ' ')"
    return 0
}

# completion_script SHELL
#
# Generated from MODE_TABLE and the option table, so completion cannot drift from
# the parser the way a hand-written list does. Emitted to stdout; installing it is
# a documented one-liner in README.md.
completion_script() { # SHELL
    local shell="${1:-bash}" modes='' opts=''
    modes="$(list_modes | tr '\n' ' ')"
    opts="$(printf '%s ' ${LONG_OPTIONS[@]+"${LONG_OPTIONS[@]}"})"
    case "$shell" in
        bash)
            cat <<EOF
# bash completion for ${PROG_NAME} - install with:
#   install -D -m 644 <(./${PROG_NAME} --completion bash) \\
#       /usr/share/bash-completion/completions/${PROG_NAME}
_${PROG_NAME//[^A-Za-z0-9_]/_}_complete() {
    local cur prev modes opts
    COMPREPLY=()
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    modes='${modes}'
    opts='${opts}'
    case "\$prev" in
        --sites|--site|-S|--config|--log-file|--error-log-file|--lock-file|--state-file|--metrics-file|--wp|--php|-B|--backup-dir|--notify-command)
            COMPREPLY=( \$(compgen -f -- "\$cur") ); return 0 ;;
        --format|--color|--allow-root|--fail-on|--log-level|--log-format|--backup|--multisite|--notify|--webhook-format|--wpcli-channel|--wpcli-scope|--signal|-A|--action)
            COMPREPLY=( \$(compgen -W "\$(_${PROG_NAME//[^A-Za-z0-9_]/_}_values "\$prev")" -- "\$cur") ); return 0 ;;
        --completion)
            COMPREPLY=( \$(compgen -W 'bash zsh' -- "\$cur") ); return 0 ;;
    esac
    if [[ "\$cur" == -* ]]; then
        COMPREPLY=( \$(compgen -W "\$opts" -- "\$cur") )
    else
        COMPREPLY=( \$(compgen -W "\$modes" -- "\$cur") )
        [[ "\$cur" == / ]] && COMPREPLY+=( \$(compgen -d -- "\$cur") )
    fi
    return 0
}
_${PROG_NAME//[^A-Za-z0-9_]/_}_values() {
    case "\$1" in
        --format) echo 'table json csv tsv' ;;
        --color) echo 'auto always never' ;;
        --allow-root) echo 'auto always never' ;;
        --fail-on) echo 'any all never' ;;
        --log-level) echo 'debug info warn error' ;;
        --log-format) echo 'text json' ;;
        --backup) echo 'off db full' ;;
        --multisite) echo 'auto off main all' ;;
        --notify) echo 'never failure always' ;;
        --webhook-format) echo 'generic slack discord telegram' ;;
        --wpcli-channel) echo 'stable nightly' ;;
        --wpcli-scope) echo 'auto patch minor major' ;;
        --signal) echo 'HUP INT QUIT TERM USR1 USR2 KILL' ;;
        -A|--action) echo 'install activate deactivate update delete status' ;;
    esac
}
complete -F _${PROG_NAME//[^A-Za-z0-9_]/_}_complete ${PROG_NAME}
complete -F _${PROG_NAME//[^A-Za-z0-9_]/_}_complete wp-fleet
EOF
            ;;
        zsh)
            cat <<EOF
#compdef ${PROG_NAME} wp-fleet
# zsh completion for ${PROG_NAME} - install with:
#   ./${PROG_NAME} --completion zsh > "\${fpath[1]}/_${PROG_NAME}"
local -a modes opts
modes=(${modes})
opts=(${opts})
_arguments \\
    '*::argument:_files' \\
    '1:mode:('"${modes// /\'} \'}"')' \\
    '*:option:('"${opts// /\'} \'}"')'
EOF
            ;;
        *)
            usage_error "--completion takes 'bash' or 'zsh' (got '${shell}')"
            ;;
    esac
    return 0
}

###############################################################################
# Section 38 - long option names, used by help and completion
###############################################################################
LONG_OPTIONS=(
    --full --core --plugins --themes --languages --cache --cleanup
    --db-optimize --db-fix --cron --astra --verify --report --security --secrets
    --list-plugins --plugin-manage --restore
    --check --status --list-sites
    --wpcli-check --wpcli-update --wpcli-install --wpcli-rollback
    --list-modes --print-config --init-config --completion
    --site --sites --include --exclude --max-sites --user --multisite --url
    --jobs --stagger --retry --fail-fast --max-duration
    --action --name --force --yes --only-active --exclude-plugins
    --from --restore-files
    --format --json --json-lines --fields --page-limit --color --no-color
    --quiet --verbose --debug
    --backup --no-backup --backup-dir --keep-backups --min-free-space
    --dry-run --no-user-switch --maintenance-mode --strict --timeout --signal
    --kill-after --allow-root --skip-plugins --skip-plugins-for-listing
    --fail-on --no-lock --lock-timeout --lock-required --no-discover
    --wp --wpcli-min-version --wpcli-latest-check --wpcli-channel --wpcli-scope
    --wpcli-version --wpcli-no-verify --wpcli-insecure --php
    --state-file --metrics-file --notify --webhook --webhook-format
    --notify-command --smoke-test --smoke-timeout --smoke-expect
    --config --log-file --error-log-file --log-level --log-format --syslog
    --lock-file --user-env --astra-key --astra-slug
    --help --version --version-detail
)

###############################################################################
# Section 39 - argument parsing
###############################################################################

MODES_SEEN=0

set_mode() { # NAME
    if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        usage_error "conflicting modes: --${MODE} and --${1}; pass exactly one"
    fi
    MODE="$1"
    MODES_SEEN=$((MODES_SEEN + 1))
    CLI_SET[MODE]=1
    return 0
}

# need_value OPTION [VALUE] -> sets OPT_VALUE.
#
# It does not print the value for `$(...)` capture on purpose: usage_error exits,
# and an exit inside a command substitution only leaves the subshell, so the
# caller would continue with an empty value. That single detail once turned
# "--sites" with no argument into a run against the default paths.
OPT_VALUE=''
need_value() { # OPTION [VALUE]
    if [ -z "${2:-}" ]; then
        usage_error "${1} requires a value"
    fi
    OPT_VALUE="$2"
    return 0
}

parse_args() {
    local arg
    while (($# > 0)); do
        arg="$1"
        case "$arg" in
            # ---- modes ---------------------------------------------------
            -f | --full) set_mode full ;;
            -c | --core) set_mode core ;;
            -p | --plugins) set_mode plugins ;;
            -t | --themes) set_mode themes ;;
            -L | --languages) set_mode languages ;;
            -C | --cache) set_mode cache ;;
            -X | --cleanup) set_mode cleanup ;;
            -d | --db-optimize) set_mode db-optimize ;;
            -x | --db-fix) set_mode db-fix ;;
            -r | --cron) set_mode cron ;;
            -s | --astra) set_mode astra ;;
            --verify) set_mode verify ;;
            --report | --health) set_mode report ;;
            --security | --audit) set_mode security ;;
            --secrets) set_mode secrets ;;
            -l | --list-plugins) set_mode list-plugins ;;
            -m | --plugin-manage) set_mode plugin-manage ;;
            --restore) set_mode restore; RESTORE_ACTION='true' ;;
            --check) set_mode check; NO_ACTION='true' ;;
            --status) set_mode status; NO_ACTION='true' ;;
            --list-sites) set_mode list-sites; LIST_SITES='true'; NO_ACTION='true' ;;
            --wpcli-check) set_mode wpcli-check; WPCLI_ACTION='check'; NO_ACTION='true' ;;
            --wpcli-update) set_mode wpcli-update; WPCLI_ACTION='update'; NO_ACTION='true' ;;
            --wpcli-install) set_mode wpcli-install; WPCLI_ACTION='install'; NO_ACTION='true' ;;
            --wpcli-rollback) set_mode wpcli-rollback; WPCLI_ACTION='rollback'; NO_ACTION='true' ;;
            --list-modes) LIST_MODES='true'; NO_ACTION='true' ;;
            --print-config) PRINT_CONFIG='true'; NO_ACTION='true' ;;
            --init-config)
                # The file argument is optional here and only here: `--init-config`
                # alone means stdout. A following token that looks like an option
                # is therefore not consumed. The separate REQUESTED flag is what
                # distinguishes "no destination given" from "not asked for",
                # which an empty INIT_CONFIG cannot do on its own.
                INIT_CONFIG_REQUESTED='true'
                INIT_CONFIG="${2-}"
                if [ -n "$INIT_CONFIG" ] && [ "${INIT_CONFIG#-}" = "$INIT_CONFIG" ]; then
                    shift
                else
                    INIT_CONFIG=''
                fi
                NO_ACTION='true'
                ;;
            --completion)
                need_value "$arg" "${2:-}"
                COMPLETION="$OPT_VALUE"
                shift
                NO_ACTION='true'
                ;;
            # ---- selection ------------------------------------------------
            -S | --site)
                need_value "$arg" "${2:-}"; TARGET_SITE="$OPT_VALUE"; shift
                CLI_SET[SITES_FILE]=1
                ;;
            --sites | --sites-file)
                need_value "$arg" "${2:-}"; SITES_FILE="$OPT_VALUE"; shift
                CLI_SET[SITES_FILE]=1
                ;;
            --include | --include-sites)
                need_value "$arg" "${2:-}"; INCLUDE_GLOBS+=("$OPT_VALUE")
                INCLUDE_SITES="${INCLUDE_SITES:+${INCLUDE_SITES},}${OPT_VALUE}"; shift
                CLI_SET[INCLUDE_SITES]=1
                ;;
            --exclude | --exclude-sites)
                need_value "$arg" "${2:-}"; EXCLUDE_GLOBS+=("$OPT_VALUE")
                EXCLUDE_SITES="${EXCLUDE_SITES:+${EXCLUDE_SITES},}${OPT_VALUE}"; shift
                CLI_SET[EXCLUDE_SITES]=1
                ;;
            --max-sites) need_value "$arg" "${2:-}"; MAX_SITES="$OPT_VALUE"; shift; CLI_SET[MAX_SITES]=1 ;;
            --user) need_value "$arg" "${2:-}"; SITE_USER="$OPT_VALUE"; USER_OVERRIDE="$OPT_VALUE"; shift; CLI_SET[SITE_USER]=1 ;;
            --multisite) need_value "$arg" "${2:-}"; MULTISITE="${OPT_VALUE,,}"; shift; CLI_SET[MULTISITE]=1 ;;
            -j | --jobs) need_value "$arg" "${2:-}"; JOBS="$OPT_VALUE"; shift; CLI_SET[JOBS]=1 ;;
            -U | --url) need_value "$arg" "${2:-}"; URL="$OPT_VALUE"; shift; CLI_SET[URL]=1 ;;
            --stagger) need_value "$arg" "${2:-}"; STAGGER="$OPT_VALUE"; shift; CLI_SET[STAGGER]=1 ;;
            --retry) need_value "$arg" "${2:-}"; RETRY="$OPT_VALUE"; shift; CLI_SET[RETRY]=1 ;;
            --fail-fast) FAIL_FAST='true'; CLI_SET[FAIL_FAST]=1 ;;
            --max-duration) need_value "$arg" "${2:-}"; MAX_DURATION="$OPT_VALUE"; shift; CLI_SET[MAX_DURATION]=1 ;;
            # ---- plugin management ---------------------------------------
            -A | --action) need_value "$arg" "${2:-}"; PLUGIN_ACTION="${OPT_VALUE,,}"; shift ;;
            -N | --name)
                need_value "$arg" "${2:-}"
                PLUGIN_NAME="$OPT_VALUE"; FILTER_NAME="$OPT_VALUE"; shift
                ;;
            -F | --force) FORCE_DELETE='true' ;;
            -y | --yes) ASSUME_YES='true' ;;
            --only-active) ONLY_ACTIVE='true'; CLI_SET[ONLY_ACTIVE]=1 ;;
            -e | --exclude-plugins) need_value "$arg" "${2:-}"; EXCLUDE_PLUGINS="$OPT_VALUE"; shift; CLI_SET[EXCLUDE_PLUGINS]=1 ;;
            # ---- restore / rollback ---------------------------------------
            --from) need_value "$arg" "${2:-}"; RESTORE_FROM="$OPT_VALUE"; shift ;;
            --restore-files) RESTORE_FILES='true' ;;
            # ---- output ---------------------------------------------------
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[OUTPUT_FORMAT]=1 ;;
            --fields) need_value "$arg" "${2:-}"; FILTER_FIELDS="$OPT_VALUE"; shift ;;
            --page-limit) need_value "$arg" "${2:-}"; PAGE_LIMIT="$OPT_VALUE"; shift ;;
            -J | --json)
                # Two meanings, both wanted: with --list-plugins, --report or
                # --security it selects the record format; in a mutating fleet
                # mode it switches the fleet report to JSON Lines. The mode may
                # not have been parsed yet -- `--json -l` is as legal as
                # `-l --json` -- so the decision is deferred to validate_args.
                JSON_REQUESTED='true'
                ;;
            --json-lines) JSON_LINES='true' ;;
            --color) need_value "$arg" "${2:-}"; COLOR="${OPT_VALUE,,}"; shift; CLI_SET[COLOR]=1 ;;
            --no-color) COLOR='never'; CLI_SET[COLOR]=1 ;;
            -q | --quiet) QUIET='true' ;;
            -D | --debug) VERBOSE='true'; LOG_LEVEL='debug'; CLI_SET[LOG_LEVEL]=1 ;;
            -v | --verbose) VERBOSE='true' ;;
            # ---- safety ---------------------------------------------------
            -n | --dry-run) DRY_RUN='true' ;;
            --no-user-switch) NO_USER_SWITCH='true'; CLI_SET[NO_USER_SWITCH]=1 ;;
            --maintenance-mode) MAINTENANCE_MODE='true'; CLI_SET[MAINTENANCE_MODE]=1 ;;
            --strict) STRICT='true'; CLI_SET[STRICT]=1 ;;
            --timeout) need_value "$arg" "${2:-}"; TIMEOUT="$OPT_VALUE"; shift; CLI_SET[TIMEOUT]=1 ;;
            --signal) need_value "$arg" "${2:-}"; TIMEOUT_SIGNAL="${OPT_VALUE^^}"; shift; CLI_SET[TIMEOUT_SIGNAL]=1 ;;
            --kill-after) need_value "$arg" "${2:-}"; KILL_AFTER="$OPT_VALUE"; shift; CLI_SET[KILL_AFTER]=1 ;;
            --allow-root) need_value "$arg" "${2:-}"; ALLOW_ROOT="${OPT_VALUE,,}"; shift; CLI_SET[ALLOW_ROOT]=1 ;;
            --skip-plugins)
                need_value "$arg" "${2-}"
                SKIP_PLUGINS="$OPT_VALUE"; shift; CLI_SET[SKIP_PLUGINS]=1
                ;;
            --skip-plugins-for-listing)
                need_value "$arg" "${2:-}"; SKIP_PLUGINS_FOR_LISTING="${OPT_VALUE,,}"; shift
                CLI_SET[SKIP_PLUGINS_FOR_LISTING]=1
                ;;
            --fail-on) need_value "$arg" "${2:-}"; FAIL_ON="${OPT_VALUE,,}"; shift; CLI_SET[FAIL_ON]=1 ;;
            --no-lock) NO_LOCK='true' ;;
            --lock-timeout) need_value "$arg" "${2:-}"; LOCK_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[LOCK_TIMEOUT]=1 ;;
            --lock-required) LOCK_REQUIRED='true'; CLI_SET[LOCK_REQUIRED]=1 ;;
            --no-discover) AUTO_DISCOVER='false'; CLI_SET[AUTO_DISCOVER]=1 ;;
            # ---- backups ---------------------------------------------------
            -b | --backup) need_value "$arg" "${2:-}"; BACKUP="${OPT_VALUE,,}"; shift; CLI_SET[BACKUP]=1 ;;
            --no-backup) BACKUP='off'; NO_BACKUP_EXPLICIT='true'; CLI_SET[BACKUP]=1 ;;
            -B | --backup-dir) need_value "$arg" "${2:-}"; BACKUP_DIR="$OPT_VALUE"; shift; CLI_SET[BACKUP_DIR]=1 ;;
            --keep-backups) need_value "$arg" "${2:-}"; KEEP_BACKUPS="$OPT_VALUE"; shift; CLI_SET[KEEP_BACKUPS]=1 ;;
            --min-free-space) need_value "$arg" "${2:-}"; MIN_FREE_MIB="$OPT_VALUE"; shift; CLI_SET[MIN_FREE_MIB]=1 ;;
            # ---- WP-CLI itself ---------------------------------------------
            --wp | --wp-cli) need_value "$arg" "${2:-}"; WP_CLI_PATH="$OPT_VALUE"; shift; CLI_SET[WP_CLI_PATH]=1 ;;
            --php) need_value "$arg" "${2:-}"; PHP_BIN="$OPT_VALUE"; shift; CLI_SET[PHP_BIN]=1 ;;
            --wpcli-min-version) need_value "$arg" "${2:-}"; WP_CLI_MIN_VERSION="$OPT_VALUE"; shift; CLI_SET[WP_CLI_MIN_VERSION]=1 ;;
            --wpcli-latest-check) need_value "$arg" "${2:-}"; WP_CLI_LATEST_CHECK="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_LATEST_CHECK]=1 ;;
            --wpcli-channel) need_value "$arg" "${2:-}"; WP_CLI_UPDATE_CHANNEL="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_UPDATE_CHANNEL]=1 ;;
            --wpcli-scope) need_value "$arg" "${2:-}"; WP_CLI_UPDATE_SCOPE="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_UPDATE_SCOPE]=1 ;;
            --wpcli-version) need_value "$arg" "${2:-}"; WP_CLI_TARGET_VERSION="$OPT_VALUE"; shift; CLI_SET[WP_CLI_TARGET_VERSION]=1 ;;
            --wpcli-no-verify) WP_CLI_VERIFY_PHAR='false'; CLI_SET[WP_CLI_VERIFY_PHAR]=1 ;;
            --wpcli-insecure) WP_CLI_INSECURE='true'; CLI_SET[WP_CLI_INSECURE]=1 ;;
            # ---- reporting --------------------------------------------------
            --state-file) need_value "$arg" "${2:-}"; STATE_FILE="$OPT_VALUE"; shift; CLI_SET[STATE_FILE]=1 ;;
            --metrics-file) need_value "$arg" "${2:-}"; METRICS_FILE="$OPT_VALUE"; shift; CLI_SET[METRICS_FILE]=1 ;;
            --notify) need_value "$arg" "${2:-}"; NOTIFY_ON="${OPT_VALUE,,}"; shift; CLI_SET[NOTIFY_ON]=1 ;;
            --webhook) need_value "$arg" "${2:-}"; NOTIFY_WEBHOOK_URL="$OPT_VALUE"; shift; CLI_SET[NOTIFY_WEBHOOK_URL]=1 ;;
            --webhook-format) need_value "$arg" "${2:-}"; NOTIFY_WEBHOOK_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[NOTIFY_WEBHOOK_FORMAT]=1 ;;
            --notify-command) need_value "$arg" "${2:-}"; NOTIFY_COMMAND="$OPT_VALUE"; shift; CLI_SET[NOTIFY_COMMAND]=1 ;;
            --smoke-test) SMOKE_TEST='true'; CLI_SET[SMOKE_TEST]=1 ;;
            --no-smoke-test) SMOKE_TEST='false'; CLI_SET[SMOKE_TEST]=1 ;;
            --smoke-timeout) need_value "$arg" "${2:-}"; SMOKE_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[SMOKE_TIMEOUT]=1 ;;
            --smoke-expect) need_value "$arg" "${2:-}"; SMOKE_EXPECT="$OPT_VALUE"; shift; CLI_SET[SMOKE_EXPECT]=1 ;;
            # ---- configuration ----------------------------------------------
            --config) need_value "$arg" "${2:-}"; CONFIG_REQUESTED="$OPT_VALUE"; shift ;;
            --log-file) need_value "$arg" "${2:-}"; LOG_FILE="$OPT_VALUE"; shift; CLI_SET[LOG_FILE]=1 ;;
            --error-log-file) need_value "$arg" "${2:-}"; ERROR_LOG_FILE="$OPT_VALUE"; shift; CLI_SET[ERROR_LOG_FILE]=1 ;;
            --log-level) need_value "$arg" "${2:-}"; LOG_LEVEL="${OPT_VALUE,,}"; shift; CLI_SET[LOG_LEVEL]=1 ;;
            --log-format) need_value "$arg" "${2:-}"; LOG_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[LOG_FORMAT]=1 ;;
            --syslog) SYSLOG='true'; CLI_SET[SYSLOG]=1 ;;
            --lock-file) need_value "$arg" "${2:-}"; LOCK_FILE="$OPT_VALUE"; shift; CLI_SET[LOCK_FILE]=1 ;;
            --user-env) need_value "$arg" "${2:-}"; USER_ENV="$OPT_VALUE"; shift; CLI_SET[USER_ENV]=1 ;;
            --astra-key) need_value "$arg" "${2:-}"; LICENCE="$OPT_VALUE"; LICENCE_VALUE="$OPT_VALUE"; shift; CLI_SET[LICENCE]=1 ;;
            --astra-slug) need_value "$arg" "${2:-}"; ASTRA_SLUG="$OPT_VALUE"; shift; CLI_SET[ASTRA_SLUG]=1 ;;
            # ---- other --------------------------------------------------------
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) version_info; SUMMARY_PRINTED='true'; exit "$EXIT_OK" ;;
            --version-detail) SHOW_VERSION_DETAIL='true'; NO_ACTION='true' ;;
            --)
                shift
                # Everything after -- is a positional. This tool takes none, but
                # accepting and reporting them is friendlier than silently
                # treating `-- --full` as "no mode given".
                if (($# > 0)); then
                    usage_error "unexpected positional argument '${1}'; modes and options are all named"
                fi
                break
                ;;
            -*)
                usage_error "unknown option '${arg}'$(option_suggest "$arg"); run with --help for the list"
                ;;
            *)
                usage_error "unexpected argument '${arg}'; modes and options are all named (did you mean --site '${arg}'?)"
                ;;
        esac
        shift
    done
    return 0
}

# option_suggest OPTION -> " (did you mean --x?)" using a prefix match over the
# long option table. Same reasoning as config_suggest: a typo should say what it
# probably meant, because --help is 200 lines long.
option_suggest() {
    local needle="${1#-}" o best=''
    needle="${needle#-}"
    for o in ${LONG_OPTIONS[@]+"${LONG_OPTIONS[@]}"}; do
        local ol="${o#--}"
        case "$ol" in
            "$needle") best="$o"; break ;;
            "$needle"*) best="$o"; break ;;
            *"$needle"*) [ -n "$best" ] || best="$o" ;;
        esac
    done
    [ -n "$best" ] && printf ' (did you mean %s?)' "$best"
    return 0
}

###############################################################################
# Section 40 - argument validation
###############################################################################

validate_args() {
    local key type reason

    # Every effective value is validated by the same table that validated the
    # config layers, so a bad flag and a bad config line produce the same
    # message and differ only in the exit code.
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "${!key}")"; then
            if [ -n "${CLI_SET[$key]-}" ]; then
                usage_error "--$(config_flag_of "$key") ${reason}"
            else
                config_error "${key} ${reason} (from ${CONF_SRC[$key]:-default})"
            fi
        fi
        if [ "$type" = 'bool' ]; then
            normalise_bool "${!key}" >/dev/null
            printf -v "$key" '%s' "$BOOL_NORM"
        fi
    done

    # The include/exclude globs came from either layer; rebuild the arrays so a
    # config-file value is honoured exactly like a repeated flag.
    INCLUDE_GLOBS=()
    EXCLUDE_GLOBS=()
    local g
    while IFS= read -r g; do
        [ -n "$g" ] && INCLUDE_GLOBS+=("$g")
    done < <(split_csv "$INCLUDE_SITES")
    while IFS= read -r g; do
        [ -n "$g" ] && EXCLUDE_GLOBS+=("$g")
    done < <(split_csv "$EXCLUDE_SITES")

    if [ -n "$SITE_USER" ]; then
        is_valid_username "$SITE_USER" ||
            usage_error "--user must be a plain account name (got '${SITE_USER}')"
        USER_OVERRIDE="$SITE_USER"
    fi

    if [ -n "$PLUGIN_ACTION" ]; then
        case "$PLUGIN_ACTION" in
            install | activate | deactivate | update | delete | status) ;;
            *) usage_error "--action must be one of: install, activate, deactivate, update, delete, status (got '${PLUGIN_ACTION}')" ;;
        esac
    fi

    # -J resolves here, because both of its meanings depend on the mode and the
    # mode may have been parsed after the flag.
    if [ "$JSON_REQUESTED" = 'true' ]; then
        case "$MODE" in
            list-plugins | report | security)
                OUTPUT_FORMAT='json'
                CLI_SET[OUTPUT_FORMAT]=1
                ;;
            *)
                JSON_LINES='true'
                ;;
        esac
    fi

    if [ "$LIST_MODES" = 'true' ] || [ "$LIST_SITES" = 'true' ] ||
       [ -n "$COMPLETION" ] || [ "$INIT_CONFIG_REQUESTED" = 'true' ] ||
       [ "$PRINT_CONFIG" = 'true' ] || [ "$SHOW_VERSION_DETAIL" = 'true' ]; then
        return 0
    fi

    if [ -z "$MODE" ]; then
        usage_error 'no mode given; pass one of --full, --core, --plugins, --themes, --cache, --cleanup, --report, --security, --verify, --check, --status (see --help)'
    fi

    case "$MODE" in
        plugin-manage)
            [ -n "$PLUGIN_ACTION" ] || usage_error '--plugin-manage requires --action install|activate|deactivate|update|delete|status'
            [ -n "$PLUGIN_NAME" ] || usage_error '--plugin-manage requires --name NAME'
            if [ "$PLUGIN_ACTION" = 'delete' ] && [ "$FORCE_DELETE" != 'true' ] &&
               [ "$ASSUME_YES" != 'true' ] && [ ! -t 0 ]; then
                log_warn 'a delete without --yes in a non-interactive shell will be refused per site'
            fi
            ;;
        list-plugins)
            [ -n "$PLUGIN_ACTION" ] && usage_error '--action is meaningless for --list-plugins'
            ;;
        cleanup)
            if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ] && [ ! -t 0 ]; then
                log_warn '--cleanup without --yes reports what it would delete and changes nothing'
            fi
            ;;
        restore)
            [ -n "$TARGET_SITE" ] || usage_error '--restore requires --site PATH (which site should be restored?)'
            ;;
        astra)
            : # the licence is resolved per site, so an absent key is reported there
            ;;
    esac

    if [ "$ONLY_ACTIVE" = 'true' ] || [ -n "$EXCLUDE_PLUGINS" ]; then
        case "$MODE" in
            plugins | full) ;;
            *) usage_error '--only-active and --exclude-plugins only apply to --plugins and --full' ;;
        esac
    fi
    if [ -n "$FILTER_FIELDS" ] && [ "$MODE" != 'list-plugins' ]; then
        log_warn '--fields only affects --list-plugins; it is ignored here'
    fi
    if ((JOBS > 1)) && [ "$MODE" = 'plugin-manage' ] && [ "$PLUGIN_ACTION" = 'delete' ]; then
        log_warn 'deleting a plugin across a fleet in parallel batches: the per-site confirmation is answered by --yes, not by a prompt'
    fi
    if [ "$BACKUP" = 'full' ] && ((KEEP_BACKUPS == 0)); then
        log_warn '--backup full with --keep-backups 0 keeps every whole-tree archive forever; check the free space on the backup volume'
    fi
    if [ "$SMOKE_TEST" = 'true' ] && mode_is_readonly "$MODE"; then
        log_warn "--smoke-test changes nothing in a read-only mode; the sites are still probed"
    fi
    return 0
}

# config_flag_of KEY -> the long flag that sets this key, for error messages.
# A table-driven message that says "--timeout must be a positive integer" is
# actionable; one that says "TIMEOUT must be a positive integer" when the operator
# typed a flag is not.
config_flag_of() {
    case "${1-}" in
        WP_CLI_PATH) printf 'wp' ;;
        WP_CLI_MIN_VERSION) printf 'wpcli-min-version' ;;
        WP_CLI_LATEST_CHECK) printf 'wpcli-latest-check' ;;
        WP_CLI_UPDATE_CHANNEL) printf 'wpcli-channel' ;;
        WP_CLI_UPDATE_SCOPE) printf 'wpcli-scope' ;;
        WP_CLI_TARGET_VERSION) printf 'wpcli-version' ;;
        WP_CLI_VERIFY_PHAR) printf 'wpcli-no-verify' ;;
        WP_CLI_INSECURE) printf 'wpcli-insecure' ;;
        PHP_BIN) printf 'php' ;;
        SITES_FILE) printf 'sites' ;;
        MAX_SITES) printf 'max-sites' ;;
        SITE_USER) printf 'user' ;;
        INCLUDE_SITES) printf 'include' ;;
        EXCLUDE_SITES) printf 'exclude' ;;
        TIMEOUT) printf 'timeout' ;;
        KILL_AFTER) printf 'kill-after' ;;
        TIMEOUT_SIGNAL) printf 'signal' ;;
        ALLOW_ROOT) printf 'allow-root' ;;
        FAIL_ON) printf 'fail-on' ;;
        BACKUP) printf 'backup' ;;
        BACKUP_DIR) printf 'backup-dir' ;;
        KEEP_BACKUPS) printf 'keep-backups' ;;
        MIN_FREE_MIB) printf 'min-free-space' ;;
        JOBS) printf 'jobs' ;;
        STAGGER) printf 'stagger' ;;
        RETRY) printf 'retry' ;;
        MAX_DURATION) printf 'max-duration' ;;
        URL) printf 'url' ;;
        LOG_FILE) printf 'log-file' ;;
        ERROR_LOG_FILE) printf 'error-log-file' ;;
        LOG_LEVEL) printf 'log-level' ;;
        LOG_FORMAT) printf 'log-format' ;;
        LOCK_FILE) printf 'lock-file' ;;
        LOCK_TIMEOUT) printf 'lock-timeout' ;;
        OUTPUT_FORMAT) printf 'format' ;;
        COLOR) printf 'color' ;;
        USER_ENV) printf 'user-env' ;;
        ASTRA_SLUG) printf 'astra-slug' ;;
        LICENCE) printf 'astra-key' ;;
        EXCLUDE_PLUGINS) printf 'exclude-plugins' ;;
        SKIP_PLUGINS) printf 'skip-plugins' ;;
        SKIP_PLUGINS_FOR_LISTING) printf 'skip-plugins-for-listing' ;;
        STATE_FILE) printf 'state-file' ;;
        METRICS_FILE) printf 'metrics-file' ;;
        NOTIFY_ON) printf 'notify' ;;
        NOTIFY_WEBHOOK_URL) printf 'webhook' ;;
        NOTIFY_WEBHOOK_FORMAT) printf 'webhook-format' ;;
        NOTIFY_COMMAND) printf 'notify-command' ;;
        SMOKE_TIMEOUT) printf 'smoke-timeout' ;;
        SMOKE_EXPECT) printf 'smoke-expect' ;;
        WP_CLI_GPG_KEY_URL) printf 'config WP_CLI_GPG_KEY_URL' ;;
        *) printf '%s' "${1,,}" ;;
    esac
    return 0
}

###############################################################################
# Section 41 - the report buffer
###############################################################################
#
# A table cannot be aligned until its widest row is known, and a fleet report
# does not know its widest row until the last site has answered. The rows are
# therefore buffered: in a sequential run in one file, in a parallel run in one
# file per worker that the parent appends in site order after each barrier. The
# buffering is file-based rather than array-based for one reason only: an array
# filled inside a worker subshell disappears when the worker exits, and that is a
# bug that shows up exclusively under -j, which is the worst possible time for a
# bug to be exclusive.

REPORT_BUFFER=''
REPORT_TABLE_FILE=''

# report_init : create the buffer for a --report run.
report_init() {
    [ "$MODE" = 'report' ] || return 0
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.report.XXXXXX" 2>/dev/null)" || return 0
        chmod 700 "$WORK_DIR" 2>/dev/null
        tmp_register "$WORK_DIR"
    fi
    REPORT_TABLE_FILE="${WORK_DIR}/report-rows.tsv"
    : >"$REPORT_TABLE_FILE" 2>/dev/null
    REPORT_BUFFER="$REPORT_TABLE_FILE"
    return 0
}

# report_row_sink -> where one TSV row goes
report_row_sink() {
    if [ "$PARALLEL" = 'true' ] && [ -n "${WORKER_DIR:-}" ]; then
        printf '%s/rows' "$WORKER_DIR"
        return 0
    fi
    if [ -n "$REPORT_BUFFER" ]; then
        printf '%s' "$REPORT_BUFFER"
        return 0
    fi
    printf ''
    return 0
}

# report_finish : render the buffered table once every unit has reported.
report_finish() {
    [ -n "$REPORT_TABLE_FILE" ] || return 0
    [ -s "$REPORT_TABLE_FILE" ] || { log_debug 'the report collected no rows'; return 0; }
    local i rows=0
    while IFS= read -r _; do rows=$((rows + 1)); done <"$REPORT_TABLE_FILE"
    case "$OUTPUT_FORMAT" in
        table)
            {
                printf '%s\n' "$REPORT_HEADERS"
                cat -- "$REPORT_TABLE_FILE"
            } | table_render "$PAGE_LIMIT"
            ;;
        tsv)
            printf '%s\n' "$REPORT_HEADERS"
            cat -- "$REPORT_TABLE_FILE"
            ;;
        csv)
            {
                printf '%s\n' "$REPORT_HEADERS"
                cat -- "$REPORT_TABLE_FILE"
            } | tsv_to_csv
            ;;
    esac
    log_debug "report rendered ${rows} row(s) in ${OUTPUT_FORMAT} format"
    return 0
}

###############################################################################
# Section 42 - maintenance mode
###############################################################################
#
# WordPress 5.5 ships a maintenance mode and WP-CLI 2.4 exposes it. Turning it on
# for the duration of an update is the difference between "the shop was down for
# forty seconds" and "a customer bought a product at half price because the cart
# was rebuilt mid-request". It is off by default because a fleet of 200 sites
# going into maintenance mode at 03:00 is a decision the operator has to make,
# not one the tool makes for them.

MAINTENANCE_SUPPORTED=''
MAINTENANCE_ACTIVE='false'

maintenance_start() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    [ "$MAINTENANCE_MODE" = 'true' ] || return 0
    [ "$DRY_RUN" = 'true' ] && return 0
    if [ -z "$MAINTENANCE_SUPPORTED" ]; then
        if wp_supported "$site" "$user" maintenance-mode; then
            MAINTENANCE_SUPPORTED='yes'
        else
            MAINTENANCE_SUPPORTED='no'
            log_warn 'this WP-CLI has no maintenance-mode command (2.4+ and WordPress 5.5+ needed); --maintenance-mode is ignored'
        fi
    fi
    [ "$MAINTENANCE_SUPPORTED" = 'yes' ] || return 0
    if run_wp_soft "$site" "$user" "$url" maintenance-mode activate >/dev/null; then
        MAINTENANCE_ACTIVE='true'
        log_debug "$(path_base "$site"): maintenance mode on"
    else
        log_warn "$(path_base "$site"): maintenance mode could not be activated; continuing without it"
    fi
    return 0
}

# maintenance_stop : always called, including after a failure. Leaving a site in
# maintenance mode because an update failed is a second outage caused by the tool
# that was supposed to prevent one.
maintenance_stop() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    [ "$MAINTENANCE_ACTIVE" = 'true' ] || return 0
    MAINTENANCE_ACTIVE='false'
    [ "$DRY_RUN" = 'true' ] && return 0
    if run_wp_soft "$site" "$user" "$url" maintenance-mode deactivate >/dev/null; then
        log_debug "$(path_base "$site"): maintenance mode off"
    else
        # This is the one warning in the tool worth reading twice: a site left in
        # maintenance mode is offline to its visitors and online to wp.
        log_warn "$(path_base "$site"): MAINTENANCE MODE COULD NOT BE DEACTIVATED; run 'wp maintenance-mode deactivate' in ${site} now"
    fi
    return 0
}

###############################################################################
# Section 43 - smoke test
###############################################################################
#
# "The update succeeded" and "the site still works" are different claims, and
# only the second one is interesting. A white screen after a plugin update is the
# most common fleet incident there is, and it is invisible to every exit code
# WP-CLI returns. Probing the site URL after the change costs one HTTP request
# and turns that incident into a line in the report at 03:12 instead of a phone
# call at 08:00.

SMOKE_PROBED=0

# smoke_test SITE USER URL -> 0 healthy, 1 unhealthy, 2 not probed
smoke_test() { # SITE USER URL
    local site="$1" user="$2" url="$3" target='' code=''
    [ "$SMOKE_TEST" = 'true' ] || return 2
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would probe the site URL after the change"
        return 2
    fi
    if ! http_client_resolve >/dev/null 2>&1; then
        return 2
    fi
    target="$url"
    if [ -z "$target" ]; then
        target="$(site_home "$site" "$user")"
    fi
    case "$target" in
        http://* | https://*) ;;
        *)
            log_debug "$(path_base "$site"): no usable site URL for the smoke test"
            return 2
            ;;
    esac
    SMOKE_PROBED=$((SMOKE_PROBED + 1))
    code="$(http_status "$target" "$SMOKE_TIMEOUT")"
    if [ "$code" = '000' ]; then
        log_warn "$(path_base "$site"): the smoke test could not reach ${target} (no answer within ${SMOKE_TIMEOUT}s)"
    elif in_csv_list "$code" "$SMOKE_EXPECT"; then
        log_ok "$(path_base "$site"): smoke test passed (HTTP ${code} from ${target})"
        STATS_SMOKE_OK=$((STATS_SMOKE_OK + 1))
        return 0
    else
        log_warn "$(path_base "$site"): the smoke test got HTTP ${code} from ${target}, expected one of ${SMOKE_EXPECT}"
    fi
    STATS_SMOKE_FAILED=$((STATS_SMOKE_FAILED + 1))
    if [ "$SMOKE_ON_FAIL" = 'warn' ]; then
        return 0
    fi
    return 1
}

###############################################################################
# Section 44 - per-unit processing
###############################################################################

# dispatch_mode SITE USER URL -> the mode function's status
dispatch_mode() { # SITE USER URL
    local site="$1" user="$2" url="$3"
    case "$MODE" in
        full) mode_full "$site" "$user" "$url" ;;
        core) mode_core "$site" "$user" "$url" ;;
        plugins) mode_plugins "$site" "$user" "$url" ;;
        themes) mode_themes "$site" "$user" "$url" ;;
        languages) mode_languages "$site" "$user" "$url" ;;
        cache) mode_cache "$site" "$user" "$url" ;;
        cleanup) mode_cleanup "$site" "$user" "$url" ;;
        db-optimize) mode_db_optimize "$site" "$user" "$url" ;;
        db-fix) mode_db_fix "$site" "$user" "$url" ;;
        cron) mode_cron "$site" "$user" "$url" ;;
        astra) mode_astra "$site" "$user" "$url" ;;
        verify) mode_verify "$site" "$user" "$url" ;;
        report) mode_report "$site" "$user" "$url" ;;
        security) mode_security "$site" "$user" "$url" ;;
        secrets) mode_secrets "$site" "$user" "$url" ;;
        list-plugins) mode_list_plugins "$site" "$user" "$url" ;;
        plugin-manage) mode_plugin_manage "$site" "$user" "$url" ;;
        restore) mode_restore "$site" "$user" ;;
        *)
            log_error "internal: unknown mode '${MODE}'"
            return 1
            ;;
    esac
}

CURRENT_UNIT=0

# process_unit INDEX : everything that happens to one work unit, in order.
#
# The order is the contract, and each step is there for a reason that somebody
# learned the hard way:
#   1. backup, before anything is touched, and a failed backup skips the site;
#   2. maintenance mode on, so visitors do not see a half-updated site;
#   3. the mode itself;
#   4. maintenance mode off, unconditionally, even after a failure;
#   5. the smoke test, because "wp exited 0" is not "the site works";
#   6. the record, so a JSON consumer sees this unit as soon as it lands.
process_unit() { # INDEX
    local i="$1"
    local site="${UNIT_PATH[i]}" user="${UNIT_USER[i]}" url="${UNIT_URL[i]}"
    local rc=0 attempt=0 tries=1
    CURRENT_UNIT="$i"
    CURRENT_SITE="$site" CURRENT_USER="$user" CURRENT_URL="$url"
    CURRENT_LABEL="${UNIT_LABEL[i]}"
    now_epoch >/dev/null; CURRENT_START="$EPOCH_NOW"
    MAINTENANCE_ACTIVE='false'
    SITE_HOME_CACHE='' SITE_HOME_CACHE_FOR=''
    WP_ERR_FILE=''

    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    if [ -n "$url" ]; then
        log_info "site ${site} [${url}] (as ${user})"
    else
        log_info "site ${site} (as ${user})"
    fi

    if ! maybe_backup "$site" "$user"; then
        if [ "$FAIL_ON" != 'never' ]; then
            log_error "${site}: the backup failed; skipping this site rather than updating it unprotected"
            UNIT_STATUS["${UNIT_LABEL[i]}"]='BACKUP_FAILED'
            STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
            now_epoch >/dev/null
            UNIT_ELAPSED[i]=$((EPOCH_NOW - CURRENT_START))
            emit_unit_record "$i" "${UNIT_STATUS[${UNIT_LABEL[i]}]}"
            return 1
        fi
        log_warn "${site}: the backup failed and --fail-on never says to continue unprotected"
    fi

    is_uint "$RETRY" || RETRY=0
    tries=$((RETRY + 1))
    local ops_before="$STATS_OPS_OK" fails_before="$STATS_OPS_FAILED"
    while :; do
        attempt=$((attempt + 1))
        maintenance_start "$site" "$user" "$url"
        dispatch_mode "$site" "$user" "$url"
        rc=$?
        maintenance_stop "$site" "$user" "$url"
        if ((rc == 0)) || ((attempt >= tries)); then
            break
        fi
        STATS_RETRIES=$((STATS_RETRIES + 1))
        log_warn "${site}: attempt ${attempt} of ${tries} failed; retrying"
        sleep 1
    done
    # Per-unit counters, so the JSON report and the metrics file can say which
    # site was expensive and which one produced the failures. The deltas are
    # taken from the run-wide counters because a worker owns them exclusively.
    UNIT_OPS_OK[i]=$((STATS_OPS_OK - ops_before))
    UNIT_OPS_FAILED[i]=$((STATS_OPS_FAILED - fails_before))

    if ((rc == 0)) && [ "$SMOKE_TEST" = 'true' ] && ! mode_is_readonly "$MODE"; then
        if ! smoke_test "$site" "$user" "$url"; then
            log_error "${site}: the update reported success but the site did not answer correctly"
            rc=1
        fi
    fi

    now_epoch >/dev/null
    UNIT_ELAPSED[i]=$((EPOCH_NOW - CURRENT_START))
    if ((rc == 0)); then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        UNIT_STATUS["${UNIT_LABEL[i]}"]='OK'
        log_ok "$(path_base "$site"): finished in $(duration_human "${UNIT_ELAPSED[i]}")"
    else
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        UNIT_STATUS["${UNIT_LABEL[i]}"]='FAILED'
        log_error "unit failed: ${UNIT_LABEL[i]} ($(duration_human "${UNIT_ELAPSED[i]}"))"
    fi
    emit_unit_record "$i" "${UNIT_STATUS[${UNIT_LABEL[i]}]}"
    return "$rc"
}

# emit_unit_record INDEX STATUS : the JSON Lines record for one unit.
emit_unit_record() { # INDEX STATUS
    [ "$JSON_LINES" = 'true' ] || return 0
    local i="$1" sink
    data_sink
    sink="$DATA_SINK"
    printf '{"type":"site","path":%s,"label":%s,"owner":%s,"url":%s,"status":%s,"ops_ok":%s,"ops_failed":%s,"elapsed":%s}\n' \
        "$(json_quote "${UNIT_PATH[i]}")" "$(json_quote "${UNIT_LABEL[i]}")" \
        "$(json_quote "${UNIT_USER[i]}")" "$(json_quote "${UNIT_URL[i]}")" \
        "$(json_quote "$2")" \
        "${UNIT_OPS_OK[i]-0}" "${UNIT_OPS_FAILED[i]-0}" "${UNIT_ELAPSED[i]-0}" | sink_append "$sink"
    return 0
}

###############################################################################
# Section 45 - fleet execution
###############################################################################
#
# Parallelism is batched, not a continuous pool: bash 4.2 has no `wait -n`, so a
# pool would need a job server and a fifo. A batch barrier is one `wait`, and on a
# fleet of similar sites the difference is seconds.
#
# Four things have to survive the fork, and none of them survives by itself:
#
#   1. Counters. A subshell cannot increment a parent variable, so every worker
#      writes its numbers to a result file and the parent folds them in. Reading a
#      counter inside the subshell -- what an early draft did -- reports the value
#      from before the site started.
#   2. Console output. Interleaved lines from concurrent sites are unreadable, so
#      a worker writes to its own fragment and the parent replays the fragments
#      in site order after the barrier.
#   3. Log lines. The same problem, worse, because the log file is shared. In
#      parallel mode log() writes to the worker fragment, and the parent appends
#      the fragments in order.
#   4. Data. `--format json` must stay parseable, so machine-readable output is
#      emitted by the parent during the ordered replay, never by the workers.

worker_dir() { printf '%s/w%s' "$WORK_DIR" "$1"; }

worker_init() { # INDEX
    local d
    d="$(worker_dir "$1")"
    mkdir -p -- "$d" || return 1
    : >"${d}/out"
    : >"${d}/log"
    : >"${d}/data"
    : >"${d}/rows"
    return 0
}

# worker_run INDEX : the body of one parallel worker.
worker_run() { # INDEX
    local idx="$1" d rc=0
    local site="${UNIT_PATH[idx]}" user="${UNIT_USER[idx]}"
    d="$(worker_dir "$idx")"
    WORKER_DIR="$d"
    PARALLEL='true'
    # A forked worker inherits the parent's counters, and the parent has already
    # folded in the previous batches by the time this one starts. Zeroing them
    # here makes the numbers this worker writes exactly its own contribution,
    # which is the only thing the parent can safely add up. Without this, every
    # batch after the first reports a running total and the summary
    # double-counts.
    STATS_OPS_OK=0
    STATS_OPS_FAILED=0
    STATS_SITES_TOTAL=0
    STATS_SITES_OK=0
    STATS_SITES_FAILED=0
    STATS_WARNINGS=0
    STATS_FINDINGS=0
    STATS_CRITICAL=0
    STATS_CLEANED=0
    STATS_RETRIES=0
    STATS_SMOKE_OK=0
    STATS_SMOKE_FAILED=0
    STATS_BACKUPS=0
    WP_ERR_FILE=''
    process_unit "$idx" >"${d}/out" 2>&1
    rc=$?
    PARALLEL='false'
    WORKER_DIR=''
    {
        printf 'rc=%s\n' "$rc"
        printf 'ops_ok=%s\n' "$STATS_OPS_OK"
        printf 'ops_failed=%s\n' "$STATS_OPS_FAILED"
        printf 'sites_total=%s\n' "$STATS_SITES_TOTAL"
        printf 'sites_ok=%s\n' "$STATS_SITES_OK"
        printf 'sites_failed=%s\n' "$STATS_SITES_FAILED"
        printf 'warnings=%s\n' "$STATS_WARNINGS"
        printf 'findings=%s\n' "$STATS_FINDINGS"
        printf 'critical=%s\n' "$STATS_CRITICAL"
        printf 'cleaned=%s\n' "$STATS_CLEANED"
        printf 'retries=%s\n' "$STATS_RETRIES"
        printf 'smoke_ok=%s\n' "$STATS_SMOKE_OK"
        printf 'smoke_failed=%s\n' "$STATS_SMOKE_FAILED"
        printf 'backups=%s\n' "$STATS_BACKUPS"
        printf 'elapsed=%s\n' "${UNIT_ELAPSED[idx]-0}"
        printf 'status=%s\n' "${UNIT_STATUS[${UNIT_LABEL[idx]}]-UNKNOWN}"
        printf 'wp_version=%s\n' "${UNIT_WP_VERSION[${UNIT_PATH[idx]}]-}"
    } >"${d}/res"
    return 0
}

# read_counter KEY FILE -> an integer from a result file, 0 when absent
read_counter() { # KEY FILE
    local key="$1" file="$2" v=''
    [ -r "$file" ] || { printf '0'; return 0; }
    v="$(sed -n "s/^${key}=//p" -- "$file" 2>/dev/null | head -n 1)"
    v="${v//[^0-9]/}"
    printf '%s' "${v:-0}"
    return 0
}

# read_field KEY FILE -> a raw string from a result file
read_field() { # KEY FILE
    local key="$1" file="$2"
    [ -r "$file" ] || return 0
    sed -n "s/^${key}=//p" -- "$file" 2>/dev/null | head -n 1
}

# fold_worker INDEX : read one worker's results back into the parent, replay its
# console output, append its log lines, emit its data.
fold_worker() { # INDEX
    local idx="$1" d rc ops_ok ops_failed warnings findings critical
    local cleaned retries smoke_ok smoke_failed backups elapsed status wpver
    d="$(worker_dir "$idx")"
    if [ ! -r "${d}/res" ]; then
        # A worker that produced no result file was killed: OOM, SIGKILL, a full
        # disk. Say so instead of silently counting it as a success, which is what
        # the first version did and which made a memory-starved host look healthy.
        log_error "the worker for ${UNIT_LABEL[idx]} produced no result; counting it as failed"
        STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
        STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
        UNIT_STATUS["${UNIT_LABEL[idx]}"]='FAILED'
        [ -s "${d}/out" ] && cat -- "${d}/out" >&2
        return 1
    fi
    rc="$(read_field rc "${d}/res")"
    ops_ok="$(read_counter ops_ok "${d}/res")"
    ops_failed="$(read_counter ops_failed "${d}/res")"
    warnings="$(read_counter warnings "${d}/res")"
    findings="$(read_counter findings "${d}/res")"
    critical="$(read_counter critical "${d}/res")"
    cleaned="$(read_counter cleaned "${d}/res")"
    retries="$(read_counter retries "${d}/res")"
    smoke_ok="$(read_counter smoke_ok "${d}/res")"
    smoke_failed="$(read_counter smoke_failed "${d}/res")"
    backups="$(read_counter backups "${d}/res")"
    elapsed="$(read_counter elapsed "${d}/res")"
    status="$(read_field status "${d}/res")"
    wpver="$(read_field wp_version "${d}/res")"

    STATS_SITES_TOTAL=$((STATS_SITES_TOTAL + 1))
    STATS_OPS_OK=$((STATS_OPS_OK + ops_ok))
    STATS_OPS_FAILED=$((STATS_OPS_FAILED + ops_failed))
    STATS_WARNINGS=$((STATS_WARNINGS + warnings))
    STATS_FINDINGS=$((STATS_FINDINGS + findings))
    STATS_CRITICAL=$((STATS_CRITICAL + critical))
    STATS_CLEANED=$((STATS_CLEANED + cleaned))
    STATS_RETRIES=$((STATS_RETRIES + retries))
    STATS_SMOKE_OK=$((STATS_SMOKE_OK + smoke_ok))
    STATS_SMOKE_FAILED=$((STATS_SMOKE_FAILED + smoke_failed))
    STATS_BACKUPS=$((STATS_BACKUPS + backups))
    UNIT_ELAPSED[idx]="$elapsed"
    UNIT_OPS_OK[idx]="$ops_ok"
    UNIT_OPS_FAILED[idx]="$ops_failed"
    [ -n "$wpver" ] && UNIT_WP_VERSION["${UNIT_PATH[idx]}"]="$wpver"

    # Console first, then the log: the operator watching the terminal and the
    # operator reading the file tomorrow must see the same story in the same order.
    [ -s "${d}/out" ] && cat -- "${d}/out" >&2
    if [ -s "${d}/log" ] && [ -n "$LOG_FILE" ]; then
        cat -- "${d}/log" >>"$LOG_FILE" 2>/dev/null
        rotate_log "$LOG_FILE"
    fi
    # Machine-readable payload, in site order rather than completion order.
    [ -s "${d}/data" ] && cat -- "${d}/data"
    # Report rows go to the parent's buffer so the table can be aligned at the end.
    if [ "$MODE" = 'report' ] && [ "$OUTPUT_FORMAT" = 'table' ] && [ -s "${d}/rows" ]; then
        cat -- "${d}/rows" >>"$REPORT_TABLE_FILE" 2>/dev/null
    fi

    if [ "${rc:-1}" = '0' ]; then
        STATS_SITES_OK=$((STATS_SITES_OK + 1))
        [ -n "$status" ] || status='OK'
        UNIT_STATUS["${UNIT_LABEL[idx]}"]="$status"
        return 0
    fi
    STATS_SITES_FAILED=$((STATS_SITES_FAILED + 1))
    [ -n "$status" ] || status='FAILED'
    UNIT_STATUS["${UNIT_LABEL[idx]}"]="$status"
    return 1
}

run_sequential() {
    local i rc=0 first=1
    for ((i = 0; i < UNIT_COUNT; i++)); do
        if budget_exceeded; then
            STOPPED_EARLY='true'
            STOP_REASON="--max-duration ${MAX_DURATION}s used up after ${i} of ${UNIT_COUNT} unit(s)"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            rc=1
            break
        fi
        if ((first == 0)) && ((STAGGER > 0)); then
            log_debug "staggering ${STAGGER}s before the next site"
            sleep "$STAGGER"
        fi
        first=0
        process_unit "$i"
        local urc=$?
        UNIT_OPS_OK[i]="$((UNIT_OPS_OK[i] + 0))"
        if ((urc != 0)); then
            rc=1
            if [ "$FAIL_FAST" = 'true' ]; then
                STOPPED_EARLY='true'
                STOP_REASON="--fail-fast after ${UNIT_LABEL[i]}"
                log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i - 1)) unit(s) were not processed"
                break
            fi
        fi
    done
    return "$rc"
}

run_batched() {
    local i=0 j=0 rc=0
    local -a batch=()
    WORK_DIR="${WORK_DIR:-}"
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.workers.XXXXXX")" || {
            log_warn "cannot create a working directory for ${JOBS} parallel workers; falling back to sequential processing"
            run_sequential
            return $?
        }
        chmod 700 "$WORK_DIR" 2>/dev/null
        tmp_register "$WORK_DIR"
    fi
    log_info "processing ${UNIT_COUNT} unit(s) in batches of ${JOBS}"

    while ((i < UNIT_COUNT)); do
        if budget_exceeded; then
            STOPPED_EARLY='true'
            STOP_REASON="--max-duration ${MAX_DURATION}s used up after ${i} of ${UNIT_COUNT} unit(s)"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            rc=1
            break
        fi
        batch=()
        while ((i < UNIT_COUNT && ${#batch[@]} < JOBS)); do
            if worker_init "$i"; then
                worker_run "$i" &
                batch+=("$i")
            else
                log_error "cannot prepare a worker for ${UNIT_LABEL[i]}; running it in the parent"
                process_unit "$i" || rc=1
            fi
            i=$((i + 1))
        done
        # The barrier. `wait` without arguments also reaps anything else that may
        # have been backgrounded, which is fine: nothing else is.
        wait
        # Replay in site order, so the report reads like the site list and not
        # like a race.
        for j in ${batch[@]+"${batch[@]}"}; do
            fold_worker "$j" || rc=1
            rm -rf -- "$(worker_dir "$j")" 2>/dev/null
        done
        if [ "$FAIL_FAST" = 'true' ] && ((STATS_SITES_FAILED > 0)); then
            STOPPED_EARLY='true'
            STOP_REASON="--fail-fast after a batch failure"
            log_warn "${STOP_REASON}; the remaining $((UNIT_COUNT - i)) unit(s) were not processed"
            break
        fi
        if ((STAGGER > 0)) && ((i < UNIT_COUNT)); then
            log_debug "staggering ${STAGGER}s before the next batch"
            sleep "$STAGGER"
        fi
    done
    return "$rc"
}

run_fleet() {
    if ((UNIT_COUNT == 0)); then
        return 0
    fi
    if ((JOBS <= 1)) || ((UNIT_COUNT <= 1)); then
        if ((JOBS > 1)) && ((UNIT_COUNT <= 1)); then
            log_debug "one unit to process; --jobs ${JOBS} makes no difference"
        fi
        run_sequential
        return $?
    fi
    run_batched
    return $?
}

# run_check_mode : --check reads the list if it exists but never fails because
# of it, and it changes nothing.
run_check_mode() {
    local rc=0
    NO_ACTION='true'
    check_environment || rc=1
    if [ -n "$TARGET_SITE" ]; then
        local user=''
        user="$(site_user_resolve "$TARGET_SITE" 2>/dev/null)" || user=''
        printf '\n%s== requested site ==%s\n' "$C_BOLD" "$C_RESET"
        check_report "$TARGET_SITE" "$user" || rc=1
    fi
    return "$rc"
}

###############################################################################
# Section 46 - startup checks
###############################################################################

# startup_checks : everything that must be true before a single site is touched.
#
# Each check either fixes something quietly (resolving the wp binary), warns once
# about a degraded capability (no HTTP client, so no smoke test), or refuses to
# run (no WP-CLI, or a version below the floor). A degraded capability is not a
# reason to stop a maintenance run; a missing tool it depends on is.
startup_checks() {
    local v
    if ! wp_ensure; then
        exit "$EXIT_ENV"
    fi
    if ! wpcli_version_gate; then
        exit "$EXIT_ENV"
    fi
    if [ -n "$USER_OVERRIDE" ]; then
        if ! is_valid_username "$USER_OVERRIDE"; then
            env_error "--user '${USER_OVERRIDE}' is not a valid account name"
        fi
        id -u "$USER_OVERRIDE" >/dev/null 2>&1 ||
            env_error "--user ${USER_OVERRIDE}: no such system user"
    fi
    for v in $USER_ENV; do
        if ! is_set "$v"; then
            log_warn "--user-env: '${v}' is not set in this environment; it will not be passed on"
        fi
    done
    if [ "$SMOKE_TEST" = 'true' ] && ! http_client_resolve >/dev/null 2>&1; then
        log_warn '--smoke-test needs curl(1) or wget(1); the smoke test is disabled for this run'
    fi
    if [ -n "$NOTIFY_WEBHOOK_URL" ] && [ "$NOTIFY_ON" != 'never' ] &&
       ! http_client_resolve >/dev/null 2>&1; then
        log_warn 'a webhook is configured but no HTTP client is installed; notifications will not be sent'
    fi
    if [ -n "$NOTIFY_COMMAND" ] && [ "$NOTIFY_ON" != 'never' ] && [ ! -x "$NOTIFY_COMMAND" ]; then
        log_warn "NOTIFY_COMMAND is not an executable file: ${NOTIFY_COMMAND}"
    fi
    if ((TIMEOUT > 0)) && ! have timeout && ! portable_timeout_available; then
        log_warn "--timeout ${TIMEOUT} cannot be enforced: neither timeout(1) nor perl(1) is installed"
    fi
    if [ "$BACKUP" != 'off' ] && [ -n "$BACKUP_DIR" ]; then
        if ! ensure_parent_dir "${BACKUP_DIR}/.probe"; then
            log_warn "the backup directory ${BACKUP_DIR} cannot be created; backups will fail and skip their sites"
        fi
    fi
    if [ -n "$LICENCE_VALUE" ]; then
        redact_register "$LICENCE_VALUE"
    fi
    # The config-layer spelling of the same secret gets registered too, so it is
    # masked from the first log line onwards and not only from the moment the
    # Astra step happens to resolve it.
    if [ -n "${LICENCE:-}" ]; then
        redact_register "$LICENCE"
    fi
    return 0
}

banner() {
    [ "$QUIET" = 'true' ] && return 0
    # The banner is prose, not data: it goes to stderr so that stdout carries
    # only what a machine would want to parse, in every format.
    local line
    line="$(printf '%*s' 72 '')"
    {
        printf '\n%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf ' %s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
        printf ' mode: %s%s%s\n' "$C_BOLD" "$MODE" "$C_RESET"
        printf '%s%s%s\n' "$C_BOLD" "${line// /=}" "$C_RESET"
        printf '  %-18s %s\n' 'units:' \
            "$([ -n "$TARGET_SITE" ] && printf '%s' "$TARGET_SITE" || printf '%s from %s' "$UNIT_COUNT" "$SITES_FILE")"
        printf '  %-18s %s\n' 'wp-cli:' "${WP_RESOLVED}${WP_CLI_VERSION:+ (${WP_CLI_VERSION})}"
        printf '  %-18s %s\n' 'user switch:' "$(switch_mechanism)"
        printf '  %-18s %s\n' 'log level:' "$LOG_LEVEL"
        if ((JOBS > 1)); then
            printf '  %-18s %s\n' 'parallelism:' "${JOBS} units per batch"
        fi
        if [ "$BACKUP" != 'off' ]; then
            printf '  %-18s %s\n' 'backup:' "${BACKUP} -> $(backup_dir_of) (keep ${KEEP_BACKUPS})"
        fi
        if [ -n "$URL" ]; then
            printf '  %-18s %s\n' 'url:' "$URL"
        fi
        if [ "$MULTISITE" = 'all' ]; then
            printf '  %-18s %s\n' 'multisite:' 'every subsite is a separate unit'
        fi
        if [ "$MAINTENANCE_MODE" = 'true' ]; then
            printf '  %-18s %s\n' 'maintenance:' 'sites go offline while they are updated'
        fi
        if [ "$SMOKE_TEST" = 'true' ]; then
            printf '  %-18s %s\n' 'smoke test:' "expect HTTP ${SMOKE_EXPECT}"
        fi
        if [ "$NO_USER_SWITCH" = 'true' ]; then
            printf '  %-18s %sfiles created by this run will be owned by %s%s\n' 'warning:' "$C_YELLOW" "$(id -un)" "$C_RESET"
        fi
        if ((MAX_DURATION > 0)); then
            printf '  %-18s %s\n' 'run budget:' "$(duration_human "$MAX_DURATION")"
        fi
        if [ "$DRY_RUN" = 'true' ]; then
            printf '  %-18s %sDRY RUN - nothing will be executed%s\n' 'mode:' "$C_YELLOW" "$C_RESET"
        fi
        printf '\n'
    } >&2
    return 0
}

# units_build_raw : the loose variant used by --check.
#
# --check exists to explain why a fleet is broken, so it cannot apply the filters
# that a run applies: a site that is not a directory, a directory that is not a
# WordPress root, and an owner that cannot be determined are precisely the three
# findings the operator is looking for. Skipping them would make --check report
# "all good" about a list of holes.
units_build_raw() {
    local site user
    units_reset
    for site in ${SITES[@]+"${SITES[@]}"}; do
        user="${SITE_FORCED_USER[$site]-}"
        if [ -z "$user" ]; then
            user="$(site_user_resolve "$site" 2>/dev/null)" || user=''
        fi
        units_add "$site" "$user" "$URL" "$(path_base "$site")"
    done
    return 0
}

###############################################################################
# Section 47 - main
###############################################################################

# colour_pre_scan : look at the command line for a colour preference before any
# output happens. --help and --version are printed from inside parse_args, so by
# the time the real parse finishes it is too late to colour them.
colour_pre_scan() {
    local prev='' a
    for a in "$@"; do
        case "$prev" in
            --color) COLOR="${a,,}"; CLI_SET[COLOR]=1 ;;
        esac
        case "$a" in
            --no-color) COLOR='never'; CLI_SET[COLOR]=1 ;;
            --color=*) COLOR="${a#--color=}"; COLOR="${COLOR,,}"; CLI_SET[COLOR]=1 ;;
        esac
        prev="$a"
    done
    color_init
    return 0
}

# run_wpcli_mode : the WP-CLI self-management path.
#
# These four modes do not need a site list, do not need root, and must work on a
# host where every WordPress installation is broken -- which is exactly when an
# operator reaches for them. They therefore run before the site list is read and
# before the environment checks that assume one.
run_wpcli_mode() {
    local rc=0
    log_init
    now_epoch >/dev/null; START_TIME="$EPOCH_NOW"
    log_info "${PROG_NAME} ${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"
    if [ "$NO_LOCK" != 'true' ]; then
        lock_acquire
    fi
    case "$MODE" in
        wpcli-check) mode_wpcli_check || rc=$? ;;
        wpcli-update | wpcli-install) mode_wpcli_update || rc=$? ;;
        wpcli-rollback) mode_wpcli_rollback || rc=$? ;;
    esac
    SUMMARY_PRINTED='true'
    exit "$rc"
}

main() {
    # Defaults first, then the command line, then the file and environment
    # layers. Reversing any two of these silently loses a setting: parse_args
    # writes into the same variables config_init_defaults fills, so a defaults
    # pass that runs afterwards would erase every flag the operator typed.
    config_init_defaults
    colour_pre_scan "$@"
    parse_args "$@"

    # --- commands that need no configuration at all -------------------------
    if [ "$LIST_MODES" = 'true' ]; then
        list_modes
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ -n "$COMPLETION" ]; then
        completion_script "$COMPLETION"
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ "$SHOW_VERSION_DETAIL" = 'true' ]; then
        version_detail
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    # config_load refuses to overwrite a key the command line already fixed, and
    # validate_args then checks the *effective* value no matter which layer
    # produced it, so a bad flag exits 2 and a bad file exits 4.
    config_load
    config_apply

    if [ "$INIT_CONFIG_REQUESTED" = 'true' ]; then
        init_config "$INIT_CONFIG"
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi
    if [ "$PRINT_CONFIG" = 'true' ]; then
        color_init
        print_config
        SUMMARY_PRINTED='true'
        exit "$EXIT_OK"
    fi

    validate_args
    color_init          # re-resolved: a config layer may have changed COLOR

    # --- inspection commands that work without wp, without root, without a lock
    if [ "$LIST_SITES" = 'true' ]; then
        # Runs after validate_args, because that is where the dual meaning of -J
        # is resolved; before it, `--list-sites --json` would print the table.
        print_site_list
        SUMMARY_PRINTED='true'
        if ((UNIT_COUNT == 0)); then exit "$EXIT_NOTFOUND"; fi
        exit "$EXIT_OK"
    fi

    case "$MODE" in
        wpcli-check | wpcli-update | wpcli-install | wpcli-rollback)
            run_wpcli_mode
            ;;
    esac

    log_init
    now_epoch >/dev/null; START_TIME="$EPOCH_NOW"
    log_info "${PROG_NAME} ${SCRIPT_VERSION} starting (mode=${MODE}, dry_run=${DRY_RUN})"
    log_debug "script directory: ${SCRIPT_DIR}"
    log_debug "config file used: ${CONFIG_FILE_USED:-<none>}"
    log_debug "build: dev-20261010192641 (2026-10-10T19:26:41Z)"

    if [ "$MODE" = 'status' ]; then
        local src=0
        status_report || src=$?
        SUMMARY_PRINTED='true'
        exit "$src"
    fi

    # --- the fleet path ----------------------------------------------------
    if [ -n "$TARGET_SITE" ]; then
        if [ ! -d "$TARGET_SITE" ]; then
            if [ "$MODE" = 'check' ]; then
                SITES=("$TARGET_SITE")
                SITE_FORCED_USER=()
            else
                log_error "--site is not a directory: ${TARGET_SITE}"
                print_summary "$EXIT_ERROR"
                SUMMARY_PRINTED='true'
                exit "$EXIT_ERROR"
            fi
        else
            SITES=("$TARGET_SITE")
            SITE_FORCED_USER=()
            if [ -n "$SITE_USER" ]; then
                SITE_FORCED_USER["$TARGET_SITE"]="$SITE_USER"
            fi
        fi
    else
        if [ "$MODE" = 'check' ]; then
            # --check is read-only, so it must not run discovery: writing a site
            # list is a change, and "check what would happen" that changes
            # something is not a check. It reports the version gate instead of
            # enforcing it, for the same reason.
            if wp_ensure 2>/dev/null; then
                wpcli_version_gate || log_warn 'the WP-CLI version gate failed; --check reports it and changes nothing'
            fi
            load_site_list "$SITES_FILE" || SITES=()
        else
            if ! ensure_site_list; then
                # A missing list is an environment problem; an empty one is not an
                # error at all, it just means there is nothing to do.
                if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
                    log_error "no site list to work from: ${SITES_FILE}"
                    print_summary "$EXIT_ENV"
                    SUMMARY_PRINTED='true'
                    exit "$EXIT_ENV"
                fi
            fi
            if ! load_site_list "$SITES_FILE"; then
                print_summary "$EXIT_ENV"
                SUMMARY_PRINTED='true'
                exit "$EXIT_ENV"
            fi
        fi
    fi

    if [ "$MODE" = 'check' ]; then
        units_build_raw
        run_check_mode
        local crc=$?
        SUMMARY_PRINTED='true'
        exit "$crc"
    fi

    startup_checks
    units_build
    privilege_preflight

    if ((UNIT_COUNT == 0)); then
        # "Nothing to do" is a warning, and --strict exists precisely so that a
        # cron job can be told to treat one as a failure: a maintenance run that
        # silently processed zero sites is the failure mode nobody notices.
        log_warn 'no work unit to process; nothing to do'
        print_summary "$EXIT_NOTFOUND"
        emit_state_and_metrics "$EXIT_NOTFOUND"
        notify_run "$EXIT_NOTFOUND"
        SUMMARY_PRINTED='true'
        if [ "$STRICT" = 'true' ] || [ "$FAIL_ON" != 'never' ]; then
            exit "$EXIT_NOTFOUND"
        fi
        exit "$EXIT_OK"
    fi

    if [ "$NO_LOCK" != 'true' ]; then
        lock_acquire
    else
        log_debug 'the lock is disabled by --no-lock'
    fi

    banner
    report_init
    log_info "processing ${UNIT_COUNT} unit(s) in mode '${MODE}'"

    run_fleet || true
    report_finish
    finish_run 0
}

main "$@"
