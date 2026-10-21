#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# Secret guard
#
# File:        tools/scan-secrets.sh
# Project:     Bash WP-CLI Update
# License:     MIT
# Version:     1.0.0
#
# Purpose
#   Answer one question quickly and verifiably: is a credential literal present
#   in this repository? It exists because answering that question by hand once
#   produced a false alarm: a search pattern with an escaped quantifier matched a
#   placeholder word, and a placeholder was reported as a live key.
#
# What it is
#   A warning tool, not a gate. Findings are set beside the known-benign places
#   listed in tools/secret-allowlist.txt so that a reader can tell a placeholder
#   from a value at a glance. With --strict it exits non-zero when a value looks
#   like a real credential, which is what the test suite uses.
#
# What it is not
#   It does not prove the absence of every secret. It recognises the documented
#   KEY=VALUE shapes; a credential split across lines or built from fragments
#   would not be matched. Absence of findings is evidence, not proof.
#
# Exit codes:
#   0  nothing suspicious (warnings may have been printed)
#   1  --strict and a value looks like a real credential
#   2  usage error
#   3  environment error (not a git work tree, git missing)
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash.\n' >&2
    exit 3
fi

set -uo pipefail

# Credential names appear in every case in the wild: lower, upper and mixed.
# With nocasematch the same pattern catches all three forms, while BASH_REMATCH
# still holds the original text, so the reported value is never case-folded.
# Without it the guard silently missed names written in upper case, which was
# discovered by planting such a line and watching the guard pass it.
shopt -s nocasematch

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    printf 'ERROR: bash 4.2 or newer is required, found %s\n' "${BASH_VERSION}" >&2
    exit 3
fi

readonly PROG_NAME="${0##*/}"
readonly SCRIPT_VERSION='1.0.0'
readonly EXIT_OK=0
readonly EXIT_FOUND=1
readonly EXIT_USAGE=2
readonly EXIT_ENV=3

_resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
script_dir="$(_resolve_script_dir)" || { printf 'ERROR: cannot resolve the script directory\n' >&2; exit "$EXIT_ENV"; }
readonly script_dir
readonly repo_root="$(cd "${script_dir}/.." && pwd)"
readonly allowlist_file="${script_dir}/secret-allowlist.txt"
unset -f _resolve_script_dir

# ---------------------------------------------------------------------------
# Names whose value could be a credential. Assembled from parts so that this
# file itself contains no assignment-shaped literal to trip a scanner.
# ---------------------------------------------------------------------------
_name_parts=(
    'token'
    'secret'
    'passwd'
    'password'
    'api'
    'authorization'
    'credential'
    'private'
    'access'
    'session'
    'licence'
    'license'
    'astra'
)
NAME_ALT=''
for p in "${_name_parts[@]}"; do
    NAME_ALT+="${NAME_ALT:+|}_?${p}_?"
done
unset -p 2>/dev/null || true
readonly NAME_ALT

# The searched shape: a credential-ish name, an equals sign or a colon, and a
# non-empty value that is not a variable expansion.
readonly ASSIGN_ERE="(^|[^A-Za-z0-9_])(${NAME_ALT})[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*([^[:space:]]+)"

# Values that are obviously not a secret.
readonly PLACEHOLDER_ERE='YOUR|HERE|REPLACE|CHANGEME|EXAMPLE|example|placeholder|<key>|<KEY>|xxx|XXX|@MASKED@'
# Names that describe a setting rather than hold a value.
readonly SETTING_NAME_ERE='_[Ss]lug=|_COMMAND=|^[[:space:]]*(readonly[[:space:]]+)?MODE_'

strict='false'
history='false'
verbose='false'
show_values='false'
quiet='false'

usage() { # EXIT_CODE
    local rc="${1:-$EXIT_USAGE}"
    cat <<EOF
${PROG_NAME} v${SCRIPT_VERSION} - look for credential literals in this repository

Usage:
  ${PROG_NAME} [options]

Options:
  --history        also scan every reachable commit (slower)
  --strict         exit 1 when a value looks like a real credential
  --show-values    print the matched value (off by default: findings stay masked)
  --verbose        list benign hits too, with their classification
  --quiet          print only findings and the summary line
  -h, --help       show this help and exit with status 0
  -V, --version    print the version and exit

Classification, in order:
  commented      the line is a comment or documentation
  setting        the name is a setting such as a plugin slug or a command name
  expansion      the value is a shell expansion, not a literal
  placeholder    the value is a documented stand-in
  path           the value is a path or a command with spaces
  real-candidate the value is long, alphanumeric only, and not a known stand-in

Only real-candidate is a finding. The known-benign places are listed in
tools/secret-allowlist.txt, one path|line-regex|reason per line.

Exit codes: 0 clean (warnings possible), 1 finding with --strict, 2 usage, 3 environment
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

usage_error() {
    printf '%s: %s\n' "$PROG_NAME" "$1" >&2
    printf 'Try "%s --help".\n' "$PROG_NAME" >&2
    exit "$EXIT_USAGE"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --history)      history='true' ;;
            --strict)       strict='true' ;;
            --show-values)  show_values='true' ;;
            --verbose)      verbose='true' ;;
            --quiet)        quiet='true' ;;
            -h|--help)      usage "$EXIT_OK" ;;
            -V|--version)   version_info; exit "$EXIT_OK" ;;
            *)              usage_error "unknown option: $1" ;;
        esac
        shift
    done
}

have() { command -v "$1" >/dev/null 2>&1; }

_mask() { # PATH LINE VALUE
    if [ "$show_values" = 'true' ]; then
        printf '%s' "$3"
    else
        printf 'length=%s fp=%s' "${#3}" "$(printf '%s' "$3" | sha256sum | cut -c1-12)"
    fi
}

classify() { # LINE VALUE
    local line="$1" value="$2"
    # A commented-out line is documentation, not a live assignment. Reporting it
    # as a finding was a false alarm produced by this guard's own test: the
    # pattern matched the comment marker, the name and the value on one line.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then printf 'commented'; return 0; fi
    if [[ "$line" =~ $SETTING_NAME_ERE ]]; then printf 'setting'; return 0; fi
    if [[ "$value" == *'$'* ]] || [[ "$value" == *'('* ]]; then printf 'expansion'; return 0; fi
    if [[ "$value" =~ $PLACEHOLDER_ERE ]]; then printf 'placeholder'; return 0; fi
    if [[ "$value" == */* ]] || [[ "$value" == *' '* ]]; then printf 'path'; return 0; fi
    if [[ "$value" =~ ^[A-Za-z0-9_.-]{11,}$ ]]; then printf 'real-candidate'; return 0; fi
    printf 'short'
}

# Allowlist: path-glob|line-regex|reason. A benign line that a human has already
# judged is reported as allowed instead of being classified again.
# Both the path glob and the line pattern are matched CASE-INSENSITIVELY, because
# the names in the code are upper case while the prose and the settings are not,
# and a case-sensitive list silently failed to recognise its own entries.
declare -a ALLOW_GLOB=() ALLOW_RE=() ALLOW_WHY=()
load_allowlist() {
    [ -f "$allowlist_file" ] || return 0
    local line glob re why
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        IFS='|' read -r glob re why <<<"$line"
        [ -n "$glob" ] || continue
        ALLOW_GLOB+=("${glob,,}")
        ALLOW_RE+=("${re:-.}")
        ALLOW_WHY+=("${why:-no reason given}")
    done <"$allowlist_file"
    return 0
}

# Whole-word-ish match on the lowercased line, so 'astra_slug' in the list
# matches 'ASTRA_SLUG=' in the code without matching every line that merely
# mentions astra.
allowlist_verdict() { # RELPATH LINE -> prints reason or nothing
    local rel="${1,,}" line="${2,,}" i pattern
    for i in "${!ALLOW_GLOB[@]}"; do
        if [[ "$rel" == ${ALLOW_GLOB[$i]} ]] && [[ "$line" == *"${ALLOW_RE[$i]}"* ]]; then
            printf '%s' "${ALLOW_WHY[$i]}"
            return 0
        fi
    done
    return 1
}

FINDINGS=0
SCANNED=0
BENIGN=0

report() { # RELPATH LINENO LINE VALUE CATEGORY
    local rel="$1" num="$2" line="$3" value="$4" category="$5"
    local reason=''
    if reason="$(allowlist_verdict "$rel" "$line")"; then
        BENIGN=$((BENIGN + 1))
        [ "$verbose" = 'true' ] && printf '  allowed   %s:%s  (%s)\n' "$rel" "$num" "$reason"
        return 0
    fi
    case "$category" in
        real-candidate)
            FINDINGS=$((FINDINGS + 1))
            printf '  FINDING   %s:%s  %s\n' "$rel" "$num" "$(_mask "$rel" "$num" "$value")"
            printf '            rule it out or move the value out of the repository\n'
            ;;
        *)
            [ "$verbose" = 'true' ] && printf '  %-9s %s:%s  %s\n' "$category" "$rel" "$num" "$(_mask "$rel" "$num" "$value")"
            ;;
    esac
    return 0
}

# CONTENT is the already-read file text in the working-tree mode, or a single
# line in the history mode; LINENO_OVERRIDE is used in the history mode, where the
# line number comes from git rather than from a counter.
scan_text() { # RELPATH DISPLAY_LABEL CONTENT [LINENO_OVERRIDE]
    local rel="$1" label="$2" content="$3" override="${4:-}"
    local num=0 line value category
    while IFS= read -r line || [ -n "$line" ]; do
        num=$((num + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ $ASSIGN_ERE ]] || continue
        value="${BASH_REMATCH[3]}"
        # Trim syntax that is not part of the value: a surrounding quote, and the
        # punctuation that usually follows a value in shell and config lines.
        # Written with explicit cases rather than a bracket expression, because a
        # bracket class containing a quote character once produced a report of a
        # syntax error many lines away from its real cause.
        case "$value" in
            '"'*) value="${value#\"}" ;;
            "'"*) value="${value#\'}" ;;
        esac
        while :; do
            case "$value" in
                *'"'|*"'"|*','|*';'|*')') value="${value%?}" ;;
                *) break ;;
            esac
        done
        [ -n "$value" ] || continue
        category="$(classify "$line" "$value")"
        report "$rel" "${override:-$num}" "$line" "$value" "$category"
    done <<<"$content"
    SCANNED=$((SCANNED + 1))
    return 0
}

# Only files that would actually be committed are scanned: tracked files plus
# untracked-but-not-ignored ones. Scanning the filesystem instead pulled in
# .ragraf, .dev_agent and log files, which are never published and produced
# noise that hid the lines worth reading.
scan_worktree() {
    local rel file content
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            tools/scan-secrets.sh|tools/secret-allowlist.txt) continue ;;
        esac
        file="${repo_root}/${rel}"
        [ -f "$file" ] || continue
        # Skip binaries: a NUL byte in the first kilobyte marks one.
        if [ "$(head -c 1024 "$file" 2>/dev/null | tr -cd '\0' | wc -c)" -gt 0 ]; then
            continue
        fi
        content="$(cat "$file" 2>/dev/null)" || continue
        [ -n "$content" ] || continue
        scan_text "$rel" "$rel" "$content"
    done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard 2>/dev/null | sort)
    return 0
}

# History is searched with -i and with the same path exclusions as the working
# tree, and the file path is KEPT. Three defects lived here at once: without -i,
# git grep is case-sensitive and missed names written in upper case (a planted
# API_TOKEN was reported as clean); with -h the path was discarded, so the allow
# list could never match and every already-judged line came back as a finding
# (ASTRA_SLUG in fe657ecb was reported exactly that way); and without the
# pathspec exclusions the guard read its own allowlist as findings.
scan_history() {
    local rev entry path num text
    while IFS= read -r rev; do
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            # Format from 'git grep -n': <sha>:<path>:<lineno>:<text>.
            # -n is required: without it git prints no line number, every entry
            # failed to parse, and the guard reported a clean history while
            # reading nothing. The path is matched greedily so that a colon inside
            # a path still resolves, taking the LAST '<digits>:' as the line number.
            if [[ "$entry" =~ ^([0-9a-f]{7,40}):(.*):([0-9]+):(.*)$ ]]; then
                path="${BASH_REMATCH[2]}"
                num="${BASH_REMATCH[3]}"
                text="${BASH_REMATCH[4]}"
                scan_text "$path" "$path (in ${rev:0:8})" "$text" "$num"
            fi
        done < <(git -C "$repo_root" grep -nIEi "$ASSIGN_ERE" "$rev" -- \
                    ':!tools/scan-secrets.sh' ':!tools/secret-allowlist.txt' 2>/dev/null)
    done < <(git -C "$repo_root" rev-list --all 2>/dev/null)
    return 0
}

main() {
    parse_args "$@"
    have git || { printf '%s: git is not available\n' "$PROG_NAME" >&2; exit "$EXIT_ENV"; }
    git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || {
        printf '%s: %s is not a git work tree\n' "$PROG_NAME" "$repo_root" >&2
        exit "$EXIT_ENV"
    }
    load_allowlist

    [ "$quiet" = 'true' ] || printf '%s v%s scanning %s\n' "$PROG_NAME" "$SCRIPT_VERSION" "$repo_root"

    scan_worktree
    [ "$history" = 'true' ] && scan_history

    printf '%s: %s file(s) scanned, %s finding(s), %s known-benign line(s)\n' \
        "$PROG_NAME" "$SCANNED" "$FINDINGS" "$BENIGN"

    if [ "$FINDINGS" -gt 0 ]; then
        printf 'note: a finding is a shape, not a verdict. Confirm by reading the line,\n'
        printf '      then either remove the value or record it in tools/secret-allowlist.txt.\n'
        [ "$strict" = 'true' ] && exit "$EXIT_FOUND"
    fi
    exit "$EXIT_OK"
}

main "$@"
