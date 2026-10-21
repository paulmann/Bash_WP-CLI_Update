#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# Secret guard
#
# File:        tools/scan-secrets.sh
# Project:     Bash WP-CLI Update
# License:     MIT
# Version:     1.1.0
#
# Purpose
#   Answer one question quickly and verifiably: is a credential literal present
#   in this repository? It exists because the same question, asked by hand once,
#   produced both a false alarm (a search pattern with an escaped quantifier
#   matched a placeholder) and a false negative (an upper-case name was missed).
#
# What it is
#   A warning tool with an optional gate. Findings are classified against the
#   known-benign places listed in tools/secret-allowlist.txt so that a reader can
#   tell a placeholder from a value at a glance. With --strict it exits non-zero
#   when a value still looks like a real credential, which is what CI uses.
#
# What it is not
#   It does not prove the absence of every secret. It recognises the documented
#   NAME=VALUE shapes in text files; a credential split across lines, assembled
#   from fragments, base64-encoded or stored in a binary would not be matched.
#   Absence of findings is evidence, not proof. Use a dedicated scanner
#   (gitleaks, trufflehog) in addition, not instead.
#
# Rules
#   A line is a finding when all of these hold:
#     1. a name part matches (token, secret, password, passwd, pwd, key, api,
#        auth, credential, private, access, session, licence, license, astra);
#     2. it is followed by `=` or `:` and a non-empty value;
#     3. the value is not a variable expansion, a documented placeholder, a
#        setting name, a path, or shorter than --min-length;
#     4. the line is not listed in the allowlist.
#
# Exit codes
#   0  nothing suspicious (benign hits may have been reported)
#   1  --strict and at least one value looks like a real credential
#   2  usage error
#   3  environment error (not inside a work tree, git missing)
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
TOOL_VERSION='1.1.0'

EXIT_OK=0
EXIT_FINDING=1
EXIT_USAGE=2
EXIT_ENV=3

resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [ "${src#/}" = "$src" ] && src="${dir}/${src}"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
script_dir="$(resolve_script_dir)" || {
    printf 'ERROR: cannot resolve the script directory\n' >&2; exit "$EXIT_ENV"; }
unset -f resolve_script_dir
repo_root="$(cd "${script_dir}/.." && pwd)" || {
    printf 'ERROR: cannot resolve the repository root\n' >&2; exit "$EXIT_ENV"; }
readonly script_dir repo_root
allowlist_file="${script_dir}/secret-allowlist.txt"
readonly allowlist_file

usage_error() { printf '%s: %s\n' "$PROG_NAME" "$*" >&2; printf 'Try "%s --help".\n' "$PROG_NAME" >&2; exit "$EXIT_USAGE"; }

###############################################################################
# 1. Patterns
###############################################################################

# Name parts are assembled from pieces so that *this file* contains no
# NAME=VALUE literal that would trip the scanner it implements.
name_parts=(
    token secret passwd password pwd
    api auth credential private access
    session licence license astra key
)
NAME_ALT=''
for part in "${name_parts[@]}"; do
    NAME_ALT+="${NAME_ALT:+|}_?${part}_?"
done
readonly NAME_ALT

# The shape we look for: a name, `=` or `:`, then a non-empty value. The name is
# filtered afterwards by name_is_credentialish, which carries both cases, so a
# configuration written in any case is seen and a reported value is never
# case-folded.
# Deliberately NOT `shopt -s nocasematch`: it is a global option and it turns
# every [A-Z] class in the rules below into "any letter", which once made the
# placeholder rule match a UUID and an AWS key. Case is handled per pattern.
readonly ASSIGN_ERE="(^|[^A-Za-z0-9_])?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[:=][[:space:]]*([^[:space:]]+)"

# Does the name carry a credential-ish part? Without this filter every
# KEY=VALUE line in the repository would be a candidate.
CREDENTIAL_NAME_ERE="(${NAME_ALT})"
# The name is folded to lower case before matching, so one rule covers
# SESSION_SECRET, session_secret, SessionSecret and sessionSecret. A camel-case
# name additionally gets a separator inserted at each case boundary, because the
# alternation is written as `_?part_?` and `sessionsecret` would not match it.
name_is_credentialish() { # NAME
    local n="${1,,}"
    [[ "$n" =~ $CREDENTIAL_NAME_ERE ]] && return 0
    local split
    split="$(printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g')"
    split="${split,,}"
    [[ "$split" =~ $CREDENTIAL_NAME_ERE ]]
}

# Values that are obviously not a secret.
# A placeholder is recognised by SHAPE, not by vocabulary, and the shape is
# deliberately narrow: an all-upper-case word (optionally joined by - or _),
# an angle-bracket token, the masked marker, or a run of filler characters.
#
# Two earlier revisions of this rule were wrong in the expensive direction.
# Matching the words anywhere inside the value classified the canonical AWS
# documentation key (it ends in EXAMPLEKEY) as a placeholder. Restricting the
# words to a prefix but allowing mixed case then classified `astra-addon` (via
# `AN?`) and `Example123-ChangeMe-now` as placeholders. A false negative is the
# worst thing a secret scanner can do, so the rule stays narrow and a real
# value that happens to contain a template word is reported.
readonly PLACEHOLDER_ERE='^([A-Z0-9]+[-_]?)+[A-Z0-9]+$|^[<\[]?[A-Z_]+[>\]]?$|^@MASKED@$|^[xX*#.=_-]{3,}$'
# Names that describe a setting rather than hold a value.
readonly SETTING_NAME_ERE='^[[:space:]]*([Rr][Ee][Aa][Dd][Oo][Nn][Ll][Yy][[:space:]]+|[Ll][Oo][Cc][Aa][Ll][[:space:]]+|[Ee][Xx][Pp][Oo][Rr][Tt][[:space:]]+|[Dd][Ee][Cc][Ll][Aa][Rr][Ee][[:space:]]+-[A-Za-z]+[[:space:]]+)?[A-Za-z0-9_]*(SLUG|COMMAND|PATH|FILE|DIR|MODE|FORMAT|LEVEL|SIGNAL)[[:space:]]*='
# A value that is a shell expansion is not a literal.
readonly EXPANSION_ERE='^[$]|\$\{|^\$\('
# A value that is a path or a command with spaces is not a credential.
readonly PATH_ERE='^/?[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)+/?$'

###############################################################################
# 2. Options
###############################################################################

strict='false'
history='false'
verbose='false'
show_values='false'
quiet='false'
min_length=8
target=''

usage() { # EXIT_CODE
    local rc="${1:-$EXIT_USAGE}"
    cat <<EOF
${PROG_NAME} ${TOOL_VERSION} - look for credential literals in this repository

Usage:
  ${PROG_NAME} [options]

Options:
      --history        also scan every reachable commit (slower, needs git)
      --strict         exit 1 when a value looks like a real credential
      --show-values    print the matched value (off by default: findings stay masked)
      --min-length N   ignore values shorter than N characters (default: ${min_length})
      --allowlist FILE use FILE instead of ${allowlist_file##*/}
      --verbose        list benign hits too, with their classification
      --quiet          print only findings and the summary line
  -h, --help           this help, exit 0
  -V, --version        print the version, exit 0

Classification, checked in this order:
  allowlisted    the line matches an entry of the allowlist
  commented      the line is a comment or documentation
  expansion      the value is a shell expansion, not a literal
  setting        the name describes a setting, not a credential
  placeholder    the value is a documented stand-in
  path           the value looks like a path or a command
  short          the value is shorter than --min-length

Limits:
  A finding is a shape, not a verdict, and the absence of findings is evidence,
  not proof. Split values, base64 blobs and binary files are not covered.

Exit codes:
  0 clean (benign hits possible)   1 finding with --strict   2 usage   3 environment

Examples:
  ${PROG_NAME}                     # warn only
  ${PROG_NAME} --strict            # gate: non-zero when something looks real
  ${PROG_NAME} --history --strict  # also scan what was committed and later removed
EOF
    exit "$rc"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --history) history='true' ;;
            --strict) strict='true' ;;
            --show-values) show_values='true' ;;
            --verbose) verbose='true' ;;
            --quiet) quiet='true' ;;
            --min-length)
                [ -n "${2:-}" ] || usage_error '--min-length requires a value'
                [[ "$2" =~ ^[0-9]+$ ]] || usage_error "--min-length must be a non-negative integer (got '$2')"
                min_length="$2"; shift ;;
            --allowlist)
                [ -n "${2:-}" ] || usage_error '--allowlist requires a value'
                ALLOWLIST_FILE="$2"; shift ;;
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) printf '%s %s\n' "$PROG_NAME" "$TOOL_VERSION"; exit "$EXIT_OK" ;;
            -*) usage_error "unknown option: $1" ;;
            *)
                if [ -n "$target" ]; then usage_error "unexpected argument: $1"; fi
                target="$1" ;;
        esac
        shift
    done
}

ALLOWLIST_FILE="$allowlist_file"

###############################################################################
# 3. Allowlist
###############################################################################

# Format: path-glob|line-substring|reason   (one entry per line, '#' comments)
# Both fields are matched case-insensitively, because names in code are upper
# case while the prose around them is not. Every entry must have been added
# after reading the line with its value masked -- never guessed from the name.
ALLOW_GLOBS=()
ALLOW_SUBSTRINGS=()

allowlist_load() {
    local file="${1:-$ALLOWLIST_FILE}" line glob sub
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in '' | '#'*) continue ;; esac
        glob="${line%%|*}"
        sub="${line#*|}"
        sub="${sub%%|*}"
        [ -n "$glob" ] || continue
        ALLOW_GLOBS+=("${glob,,}")
        ALLOW_SUBSTRINGS+=("${sub,,}")
    done <"$file"
    return 0
}

is_allowlisted() { # RELPATH LINE
    local path="${1,,}" line="${2,,}" i glob sub
    for ((i = 0; i < ${#ALLOW_GLOBS[@]}; i++)); do
        glob="${ALLOW_GLOBS[i]}"
        sub="${ALLOW_SUBSTRINGS[i]}"
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254  # the glob is the point
        case "$path" in $glob) ;; *) continue ;; esac
        [ -n "$sub" ] || return 0
        case "$line" in *"$sub"*) return 0 ;; esac
    done
    return 1
}

###############################################################################
# 4. Classification
###############################################################################

# fingerprint VALUE -> a short stable hash, so two runs can be compared and a
# finding can be referenced in an issue without publishing the value.
fingerprint() {
    local v="${1-}"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$v" | sha256sum | cut -c1-12
    elif command -v cksum >/dev/null 2>&1; then
        printf '%s' "$v" | cksum | cut -d' ' -f1
    else
        printf '%s' "${#v}"
    fi
}

mask_value() { # VALUE
    local v="${1-}"
    if [ "$show_values" = 'true' ]; then
        printf '%s' "$v"
        return 0
    fi
    local n=${#v}
    if ((n <= 4)); then
        printf '****'
    else
        printf '%s...%s (%s chars)' "${v:0:2}" "${v: -2}" "$n"
    fi
}

classify() { # LINE VALUE -> prints a class, empty when it is a real finding
    local line="$1" value="$2"
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    # Prefix tests, not globs: a value that merely contains an apostrophe or an
    # asterisk is not a comment, and treating it as one hides a real secret.
    if [[ "$trimmed" == '#'* ]] || [[ "$trimmed" == '//'* ]] ||
       [[ "$trimmed" == ';'* ]] || [[ "$trimmed" == '/*'* ]]; then
        printf 'commented'
        return 0
    fi
    if [[ "$value" =~ $EXPANSION_ERE ]]; then printf 'expansion'; return 0; fi
    if [[ "$line" =~ $SETTING_NAME_ERE ]]; then printf 'setting'; return 0; fi
    if [[ "$value" =~ $PLACEHOLDER_ERE ]]; then printf 'placeholder'; return 0; fi
    if [[ "$value" =~ $PATH_ERE ]]; then printf 'path'; return 0; fi
    if ((${#value} < min_length)); then printf 'short'; return 0; fi
    return 0
}

###############################################################################
# 5. Scanning
###############################################################################

FINDINGS=0
BENIGN=0
SCANNED=0
declare -A BENIGN_BY_CLASS=()

scan_text() { # LABEL RELPATH < content
    local label="$1" relpath="$2" line value name class no=0
    while IFS= read -r line || [ -n "$line" ]; do
        no=$((no + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ $ASSIGN_ERE ]] || continue
        name="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        # Only names that carry a credential-ish part are interesting; without
        # this filter every KEY=VALUE line in the repository would be a hit.
        name_is_credentialish "$name" || continue
        # Strip one layer of surrounding quotes, so that a line reading
        # KEY=<double-quote>value<double-quote> reports `value`, not the quoted form.
        # Written with string comparisons instead of case patterns: a literal
        # backslash-quote inside a case pattern is easy to get wrong, and getting
        # it wrong produces a parse error two lines below the real mistake.
        local first last
        first="${value:0:1}"
        last="${value: -1}"
        if ((${#value} >= 2)) && [ "$first" = "$last" ]; then
            if [ "$first" = '"' ] || [ "$first" = "'" ]; then
                value="${value:1:${#value} - 2}"
            fi
        fi
        # Drop one trailing list separator; a value never ends with one.
        case "$last" in
            ,) value="${value%,}" ;;
        esac
        [ -n "$value" ] || continue
        if is_allowlisted "$relpath" "$line"; then
            class='allowlisted'
        else
            class="$(classify "$line" "$value")"
        fi
        if [ -z "$class" ]; then
            FINDINGS=$((FINDINGS + 1))
            printf '  FINDING   %s:%s  %s=%s\n' "$label" "$no" "$name" "$(mask_value "$value")"
            printf '            length=%s fp=%s\n' "${#value}" "$(fingerprint "$value")"
            printf '            rule it out, remove the value, or allowlist the line\n'
            continue
        fi
        BENIGN=$((BENIGN + 1))
        BENIGN_BY_CLASS["$class"]=$(( ${BENIGN_BY_CLASS["$class"]:-0} + 1 ))
        if [ "$verbose" = 'true' ]; then
            printf '  benign    %s:%s  [%s] %s=%s\n' "$label" "$no" "$class" "$name" "$(mask_value "$value")"
        fi
    done
    return 0
}

# Files that are never scanned. The allowlist quotes the shapes it documents, so
# scanning it would report the documentation of a pattern as a finding.
scan_is_exempt() { # RELPATH
    case "${1,,}" in
        tools/secret-allowlist.txt) return 0 ;;
        .git/* | */.git/*) return 0 ;;
    esac
    return 1
}

scan_file() { # PATH RELPATH
    local path="$1" relpath="$2"
    scan_is_exempt "$relpath" && return 0
    # Text files only: a binary match is never actionable and costs a lot of time.
    if command -v file >/dev/null 2>&1; then
        case "$(file -b --mime-encoding -- "$path" 2>/dev/null)" in
            binary | application/*) return 0 ;;
        esac
    fi
    [ -r "$path" ] || return 0
    SCANNED=$((SCANNED + 1))
    scan_text "$relpath" "$relpath" <"$path"
}

scan_worktree() {
    local root="${1:-$repo_root}" path rel
    while IFS= read -r -d '' path; do
        rel="${path#"$root"/}"
        case "$rel" in
            .git/* | */.git/*) continue ;;
        esac
        scan_file "$path" "$rel"
    done < <(find "$root" -type f -print0 2>/dev/null)
}

# History mode answers the question nobody wants to ask after an incident: was
# the value ever committed, even if it is gone from the working tree now?
scan_history() {
    command -v git >/dev/null 2>&1 || { printf '  (git not available, history skipped)\n'; return 0; }
    (cd "$repo_root" && git rev-parse --git-dir >/dev/null 2>&1) || {
        printf '  (not a git work tree, history skipped)\n'
        return 0
    }
    local commits
    local seen
    seen="$(mktemp "${TMPDIR:-/tmp}/scan-secrets.seen.XXXXXX")" || return 0
    : >"$seen"
    commits="$(cd "$repo_root" && git rev-list --all 2>/dev/null | head -n "${HISTORY_LIMIT:-200}")"
    [ -n "$commits" ] || return 0
    local c f content
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            grep -Fxq "$f" "$seen" 2>/dev/null && continue
            printf '%s\n' "$f" >>"$seen"
            content="$(cd "$repo_root" && git show "${c}:${f}" 2>/dev/null)" || continue
            [ -n "$content" ] || continue
            SCANNED=$((SCANNED + 1))
            scan_text "${f}@${c:0:7}" "$f" <<<"$content"
        done < <(cd "$repo_root" && git ls-tree -r --name-only "$c" 2>/dev/null)
    done <<<"$commits"
    rm -f -- "$seen" 2>/dev/null
    return 0
}

###############################################################################
# 6. main
###############################################################################

main() {
    parse_args "$@"
    allowlist_load "$ALLOWLIST_FILE"

    local root="$repo_root"
    if [ -n "$target" ]; then
        if [ -d "$target" ]; then
            root="$(cd "$target" && pwd)"
        elif [ -f "$target" ]; then
            root="$(dirname -- "$target")"
        else
            usage_error "no such file or directory: ${target}"
        fi
    fi

    [ "$quiet" = 'true' ] || printf '%s %s scanning %s\n' "$PROG_NAME" "$TOOL_VERSION" "$root"
    if [ -n "$target" ] && [ -f "$target" ]; then
        local rel="${target#"$repo_root"/}"
        scan_file "$target" "$rel"
    else
        scan_worktree "$root"
    fi
    [ "$history" = 'true' ] && scan_history

    local class
    if [ "$verbose" = 'true' ] && ((${#BENIGN_BY_CLASS[@]} > 0)); then
        printf '\n  benign hits by class:\n'
        for class in "${!BENIGN_BY_CLASS[@]}"; do
            printf '    %-12s %s\n' "$class" "${BENIGN_BY_CLASS[$class]}"
        done
    fi
    if [ "$quiet" != 'true' ]; then
        printf '%s: %s file(s) scanned, %s finding(s), %s known-benign line(s)\n' \
            "$PROG_NAME" "$SCANNED" "$FINDINGS" "$BENIGN"
    else
        printf '%s finding(s)\n' "$FINDINGS"
    fi
    if ((FINDINGS > 0)); then
        printf 'note: a finding is a shape, not a verdict. Read the line, then remove the\n'
        printf '      value, move it to a secrets manager, or record it in %s.\n' \
            "${ALLOWLIST_FILE##*/}"
        if [ "$strict" = 'true' ]; then
            exit "$EXIT_FINDING"
        fi
    fi
    exit "$EXIT_OK"
}

main "$@"
