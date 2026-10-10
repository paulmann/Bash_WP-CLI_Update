#!/usr/bin/env bash
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
BUILD_ID='${BUILD_ID}'
BUILD_DATE='${BUILD_DATE}'
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
