#!/usr/bin/env bash
# shellcheck shell=bash
# Run every check that needs no root, no WordPress, no WP-CLI and no network.
#
# Usage:
#   bash tests/run_tests.sh            # everything
#   bash tests/run_tests.sh manager    # one suite
#   TEST_SITE_USER=www-data bash tests/run_tests.sh
#
# Environment:
#   TEST_SITE_USER   account to switch into for the user-switch tests. When it is
#                    missing or has no real shell, those checks report SKIP
#                    instead of FAIL, so the suite stays usable on a laptop.
#   TEST_WORK        reuse a working directory instead of a fresh mktemp one
#   SHELLCHECK_BIN   shellcheck binary to use for the lint check
#   VERBOSE=1        keep the working directories for inspection
#
# Exit status is 0 only when every suite passed. A suite that skips checks still
# passes, but the skip count is printed: a suite that skips everything is a suite
# that proved nothing, and the number is there so that cannot hide.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
rc=0

printf 'repository : %s\n' "$repo"
printf 'bash       : %s\n' "${BASH_VERSION:-unknown}"
printf 'kernel     : %s\n' "$(uname -sr 2>/dev/null)"
printf 'id         : %s (uid %s)\n' "$(id -un 2>/dev/null)" "$(id -u 2>/dev/null)"
printf '/bin/sh    : %s\n' "$(readlink -f /bin/sh 2>/dev/null || printf 'absent')"
printf 'shellcheck : %s\n' "$(command -v "${SHELLCHECK_BIN:-shellcheck}" 2>/dev/null || printf 'not installed')"
printf 'flock      : %s\n' "$(command -v flock 2>/dev/null || printf 'absent')"
printf 'timeout    : %s\n' "$(command -v timeout 2>/dev/null || printf 'absent')"
printf 'runuser    : %s\n' "$(command -v runuser 2>/dev/null || printf 'absent')"
printf 'site user  : %s\n' "${TEST_SITE_USER:-<auto-detect>}"
printf '\n'

SUITES=(test_static.sh test_base_contract.sh test_finder.sh test_manager.sh test_secretguard.sh)
if (($# > 0)); then
    SUITES=()
    for arg in "$@"; do
        case "$arg" in
            */*) SUITES+=("$(basename -- "$arg")") ;;
            *) SUITES+=("test_${arg}.sh") ;;
        esac
    done
fi

total_pass=0
total_fail=0
total_skip=0
failed_suites=()

for suite in "${SUITES[@]}"; do
    path="${here}/${suite}"
    if [ ! -f "$path" ]; then
        printf '### %s: NO SUCH SUITE\n\n' "$suite"
        rc=1
        failed_suites+=("$suite")
        continue
    fi
    printf '### %s\n' "$suite"
    work="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-suite.XXXXXX")"
    chmod 755 "$work"
    log="${work}/out.txt"
    # The suites count in files, so a check that runs in a pipeline still counts.
    export FAIL_FILE="${work}/fail" PASS_FILE="${work}/pass" SKIP_FILE="${work}/skip"
    : >"$FAIL_FILE"; : >"$PASS_FILE"; : >"$SKIP_FILE"
    if [ "${VERBOSE:-0}" = '1' ]; then
        export TEST_WORK="${work}/keep"
        mkdir -p "$TEST_WORK"
        chmod 755 "$TEST_WORK"
    fi
    if bash "$path" >"$log" 2>&1; then
        suite_rc=0
    else
        suite_rc=$?
    fi
    cat "$log"
    p="$(grep -c '' "$PASS_FILE" 2>/dev/null)" || p=0
    f="$(grep -c '' "$FAIL_FILE" 2>/dev/null)" || f=0
    s="$(grep -c '' "$SKIP_FILE" 2>/dev/null)" || s=0
    total_pass=$((total_pass + p))
    total_fail=$((total_fail + f))
    total_skip=$((total_skip + s))
    if [ "$suite_rc" -eq 0 ] && [ "$f" -eq 0 ]; then
        printf '### %s: OK (%s passed, %s skipped)\n\n' "$suite" "$p" "$s"
    else
        printf '### %s: FAILED (%s passed, %s failed, %s skipped, exit %s)\n\n' \
            "$suite" "$p" "$f" "$s" "$suite_rc"
        rc=1
        failed_suites+=("$suite")
    fi
    if [ "${VERBOSE:-0}" != '1' ]; then
        rm -rf -- "$work"
    else
        printf '(kept %s)\n\n' "$work"
    fi
done

printf '=========================================\n'
printf 'TOTAL: %s passed, %s failed, %s skipped\n' "$total_pass" "$total_fail" "$total_skip"
if [ "$rc" -eq 0 ]; then
    printf 'RESULT: all suites passed\n'
else
    printf 'RESULT: failing suite(s): %s\n' "${failed_suites[*]}"
fi
exit "$rc"
