#!/usr/bin/env bash
###############################################################################
# Build the distributable scripts from src/.
#
#   tools/build.sh              build both scripts
#   tools/build.sh manager      build only Bash_WP-CLI_Update.sh
#   tools/build.sh finder       build only Find_WP_Senior.sh
#   tools/build.sh --check      compare the committed files with a fresh
#                               in-memory build; never writes anything
#
# Environment:
#   WPU_BUILD_ID=NAME        stamp a specific build id into the artifacts
#   WPU_BUILD_DATE=STAMP     stamp a specific build date (UTC, as printed);
#                            with WPU_BUILD_ID this makes a build byte-for-byte
#                            reproducible
#   WPU_SYNTAX_FORK=1        additionally run `bash -n` on the result
#
# Idempotence: when WPU_BUILD_ID is given without WPU_BUILD_DATE and the
# existing artifact already carries that same build id, its build date is
# reused, so rebuilding the same commit twice produces the identical file
# (same md5) and `git status` stays clean. A new build id gets a fresh date.
#
# The repository ships single-file scripts on purpose: "copy one file to the
# host" is the entire installation procedure for a fleet, and a tool that needs
# a build step on the target host is a tool that does not get installed on the
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

MANAGER_OUT="${repo}/Bash_WP-CLI_Update.sh"
FINDER_OUT="${repo}/Find_WP_Senior.sh"

# A UTC stamp without forking `date`: printf -v with the %(...)T format is a
# builtin in bash 4.2 and later.
NOW_DATE=''
printf -v NOW_DATE '%(%Y-%m-%dT%H:%M:%SZ)T' -1

# artifact_stamp FILE -> sets ARTIFACT_BUILD_ID / ARTIFACT_BUILD_DATE to the
# stamp already written into an artifact ('' when absent or unparseable). Used
# for two things: reusing the date so a rebuild of the same build id is
# byte-identical, and rebuilding with the artifact's own stamp in --check so
# the comparison can be exact instead of normalized.
ARTIFACT_BUILD_ID=''
ARTIFACT_BUILD_DATE=''
artifact_stamp() { # FILE
    ARTIFACT_BUILD_ID='' ARTIFACT_BUILD_DATE=''
    local text line
    [ -f "$1" ] || return 0
    text="$(<"$1")"
    while IFS= read -r line; do
        case "$line" in
            "BUILD_ID='"*"'"*)
                if [ -z "$ARTIFACT_BUILD_ID" ]; then
                    ARTIFACT_BUILD_ID="${line#BUILD_ID=\'}"
                    ARTIFACT_BUILD_ID="${ARTIFACT_BUILD_ID%\'}"
                fi
                ;;
            "BUILD_DATE='"*"'"*)
                if [ -z "$ARTIFACT_BUILD_DATE" ]; then
                    ARTIFACT_BUILD_DATE="${line#BUILD_DATE=\'}"
                    ARTIFACT_BUILD_DATE="${ARTIFACT_BUILD_DATE%\'}"
                fi
                ;;
        esac
        [ -n "$ARTIFACT_BUILD_ID" ] && [ -n "$ARTIFACT_BUILD_DATE" ] && break
    done <<<"$text"
    return 0
}

BUILD_DATE="${WPU_BUILD_DATE:-$NOW_DATE}"
BUILD_ID="${WPU_BUILD_ID:-dev-${BUILD_DATE//[!0-9]/}}"

# Date reuse: an explicit build id without an explicit date means "this commit",
# and the artifact of this commit already knows when it was built. Rebuilding
# with a fresh clock would change bytes that carry no information.
if [ -n "${WPU_BUILD_ID:-}" ] && [ -z "${WPU_BUILD_DATE:-}" ]; then
    artifact_stamp "$MANAGER_OUT"
    if [ "$ARTIFACT_BUILD_ID" = "$BUILD_ID" ] && [ -n "$ARTIFACT_BUILD_DATE" ]; then
        BUILD_DATE="$ARTIFACT_BUILD_DATE"
    fi
fi

# count_lines_of FILE -> COUNT_LINES (no fork, no wc)
COUNT_LINES=0
count_lines_of() {
    local text line
    COUNT_LINES=0
    text="$(<"$1")"
    while IFS= read -r line; do COUNT_LINES=$((COUNT_LINES + 1)); done <<<"$text"
    return 0
}

# build_body SRCDIR -> sets BUILD_BODY to the assembled artifact content,
# stamp placeholders resolved, and BUILD_PARTS to the number of modules.
# Writing is a separate step, so --check can build without ever touching the
# file on disk.
BUILD_BODY=''
BUILD_PARTS=0
build_body() { # SRCDIR
    local srcdir="$1" part content='' notice='' shebang='' i
    local -a parts=()
    BUILD_BODY=''
    BUILD_PARTS=0
    for part in "$srcdir"/*.sh; do
        [ -f "$part" ] || continue
        parts+=("$part")
    done
    BUILD_PARTS=${#parts[@]}
    if ((BUILD_PARTS == 0)); then
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
    BUILD_BODY="${shebang}"$'\n'"${notice}${content}"

    for ((i = 1; i < ${#parts[@]}; i++)); do
        content="$(<"${parts[i]}")"
        case "$content" in
            '#!'*) content="${content#*$'\n'}" ;;
        esac
        BUILD_BODY+=$'\n'"${content}"$'\n'
    done

    # Stamp the build. The placeholders are literal in the source, so an unbuilt
    # checkout reports "source" instead of carrying a stale stamp.
    BUILD_BODY="${BUILD_BODY//\$\{BUILD_ID\}/$BUILD_ID}"
    BUILD_BODY="${BUILD_BODY//\$\{BUILD_DATE\}/$BUILD_DATE}"
    return 0
}

# write_body OUT : put BUILD_BODY on disk. The body already ends in exactly one
# newline, so it is written as-is: a printf that appends another one leaves a
# blank line at EOF, and then every read-back comparison has to explain it.
write_body() { # OUT
    printf '%s' "$BUILD_BODY" >"$1"
    count_lines_of "$1"
    return 0
}

emit() { # OUT SRCDIR
    build_body "$2"
    write_body "$1"
    printf 'built %s from %s (%s modules, %s lines)\n' \
        "${1##*/}" "${2##*/}" "$BUILD_PARTS" "$COUNT_LINES"
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

# _strip_stamp TEXT -> TEXT without the lines that carry the build stamp, so
# that a comparison sees content instead of the moment of the last build. Four
# line shapes carry the stamp: the generated notice, the two runtime stamp
# assignments and the log_debug line that announces the build at start-up.
# This is the fallback comparison; the primary one in --check rebuilds with the
# artifact's own stamp and compares exactly.
_strip_stamp() {
    local out='' line
    while IFS= read -r line; do
        case "$line" in
            '# Built by tools/build.sh'*) continue ;;
            "BUILD_ID='"*"'"*) continue ;;
            "BUILD_DATE='"*"'"*) continue ;;
            *'log_debug "build: '*) continue ;;
        esac
        out+="${line}"$'\n'
    done <<<"${1-}"
    printf '%s' "$out"
}

# check_one NAME OUT SRCDIR : the whole --check verdict for one artifact.
# Builds in memory, never writes. Comparison is exact when the artifact's own
# stamp can be read back (the normal case), normalized otherwise.
check_one() { # NAME OUT SRCDIR
    local name="$1" out="$2" srcdir="$3" before='' body=''
    local saved_id="$BUILD_ID" saved_date="$BUILD_DATE"
    if [ ! -f "$out" ]; then
        printf 'DRIFT: %s is missing - build and commit it\n' "$name" >&2
        return 1
    fi
    before="$(<"$out")"

    # Exact path: rebuild with the stamp the artifact itself carries, so build
    # ids and dates cannot manufacture a difference.
    artifact_stamp "$out"
    if [ -n "$ARTIFACT_BUILD_ID" ] && [ -n "$ARTIFACT_BUILD_DATE" ]; then
        BUILD_ID="$ARTIFACT_BUILD_ID" BUILD_DATE="$ARTIFACT_BUILD_DATE"
        build_body "$srcdir"
        body="${BUILD_BODY%$'\n'}"
        BUILD_ID="$saved_id" BUILD_DATE="$saved_date"
        if [ "$before" = "$body" ]; then
            printf 'ok: %s matches %s\n' "$name" "${srcdir##*/}/"
            return 0
        fi
    else
        # No readable stamp (a hand-edited or foreign artifact): fall back to
        # the normalized comparison with the resolved stamp values.
        build_body "$srcdir"
        if [ "$(_strip_stamp "$before")" = "$(_strip_stamp "${BUILD_BODY%$'\n'}")" ]; then
            printf 'ok: %s matches %s (stamp-insensitive comparison)\n' "$name" "${srcdir##*/}/"
            return 0
        fi
    fi
    printf 'DRIFT: %s does not match %s/ - rebuild and commit\n' "$name" "$srcdir" >&2
    return 1
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
if [ "$do_manager" = 'true' ]; then
    if [ "$CHECK_ONLY" = 'true' ]; then
        check_one 'Bash_WP-CLI_Update.sh' "$MANAGER_OUT" "${repo}/src/manager" || rc=1
    else
        emit "$MANAGER_OUT" "${repo}/src/manager"
        if [ "$do_syntax" = 'true' ]; then syntax_check "$MANAGER_OUT" || rc=1; fi
    fi
fi
if [ "$do_finder" = 'true' ]; then
    if [ "$CHECK_ONLY" = 'true' ]; then
        check_one 'Find_WP_Senior.sh' "$FINDER_OUT" "${repo}/src/finder" || rc=1
    else
        emit "$FINDER_OUT" "${repo}/src/finder"
        if [ "$do_syntax" = 'true' ]; then syntax_check "$FINDER_OUT" || rc=1; fi
    fi
fi

printf 'build %s at %s\n' "$BUILD_ID" "$BUILD_DATE"
exit "$rc"
