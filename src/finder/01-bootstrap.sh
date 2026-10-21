#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# WordPress installation discovery
#
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     MIT
# Version:     3.0.0
#
# Purpose
#   Scan one or more web roots for WordPress installations (a directory holding
#   wp-config.php and wp-load.php or wp-includes/version.php), honour per-site
#   opt-out markers and exclusion patterns, deduplicate, enrich with metadata
#   and write the result as the site list consumed by Bash_WP-CLI_Update.sh.
#
# Usage
#   Find_WP_Senior.sh [options] [SEARCH_ROOT ...]
#
# Design notes (read before changing anything)
#   1. Only the roots named on the command line are scanned. When none are
#      given, the built-in default roots are used -- and never "/". A previous
#      revision expanded an empty array with "${arr[@]:-}", which in bash 4.4+
#      yields one empty element; a later `[[ -n $r ]] || r='/'` turned that into
#      a full filesystem scan and silently added unrelated sites to the list.
#      Every array expansion in this file uses ${arr[@]+"${arr[@]}"} instead.
#   2. find output is read with -print0 / read -d '', so a path containing a
#      space, a quote or a newline survives.
#   3. In the prune expression `-type d` sits INSIDE the group. `-prune`
#      evaluates to true even for a plain file, so a group that ends up true
#      swallows the right-hand side of the `-o` and nothing is ever printed.
#      See build_find_args for the four variants that were measured.
#   4. Nothing is ever passed to a shell as a string. Metadata is read with
#      stat(1) and bash pattern matching; no eval, no command built by
#      concatenation.
#
# Exit codes
#   0  installations found and written
#   1  operational error (unreadable root, cannot write the output file)
#   2  usage error (bad command line)
#   3  environment error (bash too old, required tool missing)
#   5  no installation found (not a failure of the tool itself; --fail-empty
#      turns it into 1 for pipelines that must not continue)
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash, but another shell started it.\n' >&2
    exit 3
fi
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    printf 'ERROR: %s requires bash 4.2 or newer (found %s).\n' \
        "${0##*/}" "${BASH_VERSION:-unknown}" >&2
    exit 3
fi

set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

PROG_NAME="${0##*/}"
SCRIPT_VERSION='3.0.0'
# Filled by tools/build.sh; a source checkout runs unbuilt and says so.
BUILD_ID='${BUILD_ID}'
BUILD_DATE='${BUILD_DATE}'
case "$BUILD_ID" in *'${'*) BUILD_ID='source' ;; esac
case "$BUILD_DATE" in *'${'*) BUILD_DATE='unbuilt' ;; esac

EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_ENV=3
EXIT_NOT_FOUND=5

usage_error() { printf '%s: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
env_error() { printf '%s: environment: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_ENV"; }

have() { command -v "$1" >/dev/null 2>&1; }

for tool in find sort stat mktemp dirname basename cut; do
    have "$tool" || env_error "required tool not found in PATH: ${tool}"
done

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

###############################################################################
# 1. Defaults
###############################################################################

# Roots scanned when the command line names none. Deliberately a short list of
# conventional web roots: scanning "/" is never a default, because on a large
# host it costs hours of I/O and mixes unrelated sites into one list.
DEFAULT_SEARCH_ROOTS=(
    /var/www
    /srv/www
    /usr/share/nginx/html
    /srv
    /home
)

# Directory names that are never WordPress roots and are expensive to descend
# into. Matched against a single path component.
DEFAULT_EXCLUDE_NAMES=(
    .git .svn .hg node_modules vendor composer
    cache tmp temp backup backups old proc sys dev
)

DEFAULT_MAX_DEPTH=8
DEFAULT_MIN_DEPTH=1
HARD_MAX_DEPTH=32
DEFAULT_OUTPUT_FILE="${SCRIPT_DIR}/wp-found.txt"
OPT_OUT_MARKER='.no_wp_cli'

###############################################################################
# 2. Runtime state
###############################################################################

# A predictable environment: the same reasoning as in the manager. `sort -z` and
# the stat(1) format strings below are byte-oriented, and cron starts with a PATH
# that has no /usr/sbin.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
export LC_ALL=C
umask 077

OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
MANIFEST_FILE=''
MAX_DEPTH="$DEFAULT_MAX_DEPTH"
MIN_DEPTH="$DEFAULT_MIN_DEPTH"
FOLLOW_SYMLINKS='false'
PRINT_NUL='false'
AUDIT='false'
VERIFY_LIST=''
OUTPUT_FORMAT='paths'          # paths | tsv | csv | json
MANIFEST_FORMAT='tsv'          # tsv | csv | json
FIELD_LIST=''
INCLUDE_NAMES=()
AUDIT_FINDINGS=0
DELIMITER=''                   # empty = tab for tsv, comma for csv
QUIET='false'
VERBOSE='false'
STATUS_ONLY='false'
SKIP_EXISTING='false'
FAIL_EMPTY='false'
USE_DEFAULT_EXCLUDES='true'
COLOR_MODE='auto'
CLI_ROOTS=()
EXCLUDE_NAMES=()
EXCLUDE_PATHS=()
SEARCH_ROOTS=()

RESULTS_FILE=''
SORTED_FILE=''
FOUND_COUNT=0
SKIPPED_OPTOUT=0
SKIPPED_INVALID=0
SKIPPED_EXCLUDED=0
SKIPPED_DUPLICATE=0
SKIPPED_UNREADABLE=0
START_TIME=0

C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM=''
