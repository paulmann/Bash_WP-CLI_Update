#!/usr/bin/env bash
###############################################################################
# Build the distributable scripts from src/.
#
#   tools/build.sh              build both scripts
#   tools/build.sh manager      build only Bash_WP-CLI_Update.sh
#   tools/build.sh finder       build only Find_WP_Senior.sh
#   tools/build.sh --check      rebuild, then fail when the committed file differs
#
# Environment:
#   WPU_BUILD_ID=NAME        stamp a specific build id into the artifacts
#   WPU_SYNTAX_FORK=1        additionally run `bash -n` on the result
#
# The repository ships single-file scripts on purpose: "copy one file to the
# host" is the entire installation procedure for a fleet, and a tool that needs a
# build step on the target host is a tool that does not get installed on the
# target host. The modules under src/ exist so the code can be reviewed, linted
# and tested in pieces of a few hundred lines instead of one file of nine
# thousand.
#
# The build itself creates no processes at all: no cat, awk, sed, mktemp, wc,
# chmod, not even a subshell. That is not asceticism. A build that forks cannot
# run in a container that has hit its process limit, in a locked-down CI runner,
# or in an emergency shell on a host that is already out of resources -- which is
# precisely when somebody needs to rebuild a maintenance tool. It also makes the
# build deterministic, so --check can prove that the committed artifact matches
# the sources byte for byte.
###############################################################################
set -euo pipefail

BUILD_SELF="${BASH_SOURCE[0]}"
here="${BUILD_SELF%/*}"
[ "$here" = "$BUILD_SELF" ] && here='.'
repo="${here%/*}"
[ "$repo" = "$here" ] && repo='.'
case "$repo" in */) repo="${repo%/}" ;; esac

# A UTC stamp without forking `date`: printf -v with the %(...)T format is a
# builtin in bash 4.2 and later.
BUILD_DATE=''
printf -v BUILD_DATE '%(%Y-%m-%dT%H:%M:%SZ)T' -1
BUILD_ID="${WPU_BUILD_ID:-dev-${BUILD_DATE//[!0-9]/}}"

MANAGER_OUT="${repo}/Bash_WP-CLI_Update.sh"
FINDER_OUT="${repo}/Find_WP_Senior.sh"

# count_lines_of FILE -> COUNT_LINES (no fork, no wc)
COUNT_LINES=0
count_lines_of() {
    local text line
    COUNT_LINES=0
    text="$(<"$1")"
    while IFS= read -r line; do COUNT_LINES=$((COUNT_LINES + 1)); done <<<"$text"
    return 0
}

emit() { # OUT SRCDIR
    local out="$1" srcdir="$2" part body='' notice='' shebang='' content='' i
    local -a parts=()
    for part in "$srcdir"/*.sh; do
        [ -f "$part" ] || continue
        parts+=("$part")
    done
    if ((${#parts[@]} == 0)); then
        printf 'FATAL: no modules found in %s\n' "$srcdir" >&2
        exit 1
    fi

    notice="# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT.
#
# Built by tools/build.sh from the modules in src/${srcdir##*/}/ (build ${BUILD_ID}).
# Edit the modules and rebuild; a change made here is overwritten, and
# \`tools/build.sh --check\` reports the drift. The single-file form is kept
# because copying one file to a host is the whole installation procedure.
# ---------------------------------------------------------------------------
"
    # Module one carries the shebang and the shell guards. The shebang has to end
    # up as byte one of the artifact or the kernel will not exec the file, so it
    # is lifted out and the notice is inserted below it.
    content="$(<"${parts[0]}")"
    case "$content" in
        '#!'*)
            shebang="${content%%$'\n'*}"
            content="${content#*$'\n'}"
            ;;
        *) shebang='#!/usr/bin/env bash' ;;
    esac
    body="${shebang}"$'\n'"${notice}${content}"

    for ((i = 1; i < ${#parts[@]}; i++)); do
        content="$(<"${parts[i]}")"
        case "$content" in
            '#!'*) content="${content#*$'\n'}" ;;
        esac
        body+=$'\n'"${content}"$'\n'
    done

    # Stamp the build. The placeholders are literal in the source, so an unbuilt
    # checkout reports "source" instead of carrying a stale stamp.
    body="${body//\$\{BUILD_ID\}/$BUILD_ID}"
    body="${body//\$\{BUILD_DATE\}/$BUILD_DATE}"

    printf '%s\n' "$body" >"$out"
    count_lines_of "$out"
    printf 'built %s from %s (%s modules, %s lines)\n' \
        "${out##*/}" "${srcdir##*/}" "${#parts[@]}" "$COUNT_LINES"
}

syntax_check() { # FILE
    # Parse the file without executing it and without creating a process.
    #
    # Wrapping the whole script in a function definition makes bash parse every
    # line; a syntax error is reported and nothing runs. `bash -n` would be the
    # obvious tool, but it needs a fork. The check is marginally more permissive
    # than `bash -n` -- a stray top-level `local` becomes legal inside a function
    # body -- and that is the right side to err on: a check that never reports a
    # false failure is a check people keep trusting.
    local f="$1" content probe rc=0
    content="$(<"$f")"
    probe="__wpu_syntax_probe() { ${content}"$'\n'" }"
    eval "$probe" || rc=1
    unset -f __wpu_syntax_probe 2>/dev/null || true
    if ((rc != 0)); then
        printf 'FATAL: %s does not parse\n' "${f##*/}" >&2
        return 1
    fi
    if [ "${WPU_SYNTAX_FORK:-0}" = '1' ]; then
        if bash -n "$f"; then
            printf 'syntax ok (bash -n): %s\n' "${f##*/}"
            return 0
        fi
        printf 'FATAL: %s does not parse\n' "${f##*/}" >&2
        return 1
    fi
    printf 'syntax ok (parsed in-shell): %s\n' "${f##*/}"
    return 0
}

# _strip_stamp TEXT -> TEXT without the generated-notice build line, so that
# --check compares content instead of the timestamp of the last build. The
# stamp is the only part of an artifact that legitimately differs between two
# builds of identical sources.
_strip_stamp() {
    local out='' line
    while IFS= read -r line; do
        case "$line" in
            '# Built by tools/build.sh'*) continue ;;
        esac
        out+="${line}"$'\n'
    done <<<"${1-}"
    printf '%s' "$out"
}

CHECK_ONLY='false'
do_manager='true'
do_finder='true'
do_syntax='true'
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY='true' ;;
        --syntax) do_syntax='true' ;;
        --no-syntax) do_syntax='false' ;;
        manager) do_finder='false' ;;
        finder) do_manager='false' ;;
        --build-id=*) BUILD_ID="${arg#--build-id=}" ;;
        *) printf 'unknown argument: %s (use: manager | finder | --check | --syntax)\n' "$arg" >&2; exit 2 ;;
    esac
done

rc=0
before='' after=''
if [ "$do_manager" = 'true' ]; then
    if [ "$CHECK_ONLY" = 'true' ]; then
        before=''
        [ -f "$MANAGER_OUT" ] && before="$(<"$MANAGER_OUT")"
        emit "$MANAGER_OUT" "${repo}/src/manager" >/dev/null
        after="$(<"$MANAGER_OUT")"
        if [ "$(_strip_stamp "$before")" != "$(_strip_stamp "$after")" ]; then
            printf 'DRIFT: Bash_WP-CLI_Update.sh does not match src/manager/ - rebuild and commit\n' >&2
            rc=1
        else
            printf 'ok: Bash_WP-CLI_Update.sh matches src/manager/\n'
        fi
        [ -n "$before" ] && printf '%s\n' "$before" >"$MANAGER_OUT"
    else
        emit "$MANAGER_OUT" "${repo}/src/manager"
        if [ "$do_syntax" = 'true' ]; then syntax_check "$MANAGER_OUT" || rc=1; fi
    fi
fi
if [ "$do_finder" = 'true' ]; then
    if [ "$CHECK_ONLY" = 'true' ]; then
        before=''
        [ -f "$FINDER_OUT" ] && before="$(<"$FINDER_OUT")"
        emit "$FINDER_OUT" "${repo}/src/finder" >/dev/null
        after="$(<"$FINDER_OUT")"
        if [ "$(_strip_stamp "$before")" != "$(_strip_stamp "$after")" ]; then
            printf 'DRIFT: Find_WP_Senior.sh does not match src/finder/ - rebuild and commit\n' >&2
            rc=1
        else
            printf 'ok: Find_WP_Senior.sh matches src/finder/\n'
        fi
        [ -n "$before" ] && printf '%s\n' "$before" >"$FINDER_OUT"
    else
        emit "$FINDER_OUT" "${repo}/src/finder"
        if [ "$do_syntax" = 'true' ]; then syntax_check "$FINDER_OUT" || rc=1; fi
    fi
fi

printf 'build %s at %s\n' "$BUILD_ID" "$BUILD_DATE"
exit "$rc"
