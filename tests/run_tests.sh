#!/usr/bin/env bash
# shellcheck shell=bash
# Run every check that needs no root, no WordPress, no WP-CLI and no network.
#
# Usage:
#   bash tests/run_tests.sh                 # everything
#   bash tests/run_tests.sh manager cli     # selected suites (test_<name>.sh)
#   TEST_SITE_USER=www-data bash tests/run_tests.sh
#
# Environment:
#   TEST_SITE_USER   account to switch into for the user-switch tests. When it is
#                    missing or has no real shell, those checks report SKIP
#                    instead of FAIL, so the suite stays usable on a laptop.
#   TEST_WORK        reuse a working directory instead of a fresh mktemp one
#   SHELLCHECK_BIN   shellcheck binary to use for the lint check
#   VERBOSE=1        keep the working directories for inspection
#   WPU_BUILD_ID     build id stamped into the artifacts before checking drift
#
# Exit status is 0 only when every suite passed. A suite that skips checks still
# passes, but the skip count is printed: a suite that skips everything is a suite
# that proved nothing, and the number is there so that cannot hide.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
rc=0

# Rebuild the artifacts from src/ first, so the suites always test what the
# modules say. A committed artifact that drifted from its sources is exactly the
# bug a single-file-plus-modules layout can have, and the build is cheap.
if [ -f "${repo}/tools/build.sh" ] && [ -d "${repo}/src/manager" ]; then
    printf 'building artifacts from src/ ...\n'
    if ! WPU_BUILD_ID="${WPU_BUILD_ID:-test}" bash "${repo}/tools/build.sh" >&2; then
        printf 'FATAL: the build failed; refusing to test stale artifacts\n' >&2
        exit 3
    fi
fi

printf 'repository : %s\n' "$repo"
printf 'bash       : %s\n' "${BASH_VERSION:-unknown}"
printf 'kernel     : %s\n' "$(uname -sr 2>/dev/null)"
printf 'id         : %s (uid %s)\n' "$(id -un 2>/dev/null)" "$(id -u 2>/dev/null)"
printf '/bin/sh    : %s\n' "$(readlink -f /bin/sh 2>/dev/null || printf 'absent')"
printf 'shellcheck : %s\n' "$(command -v "${SHELLCHECK_BIN:-shellcheck}" 2>/dev/null || printf 'not installed')"
for t in flock timeout runuser perl jq curl wget gpg tar logger; do
    printf '%-11s: %s\n' "$t" "$(command -v "$t" 2>/dev/null || printf 'absent')"
done
printf 'site user  : %s\n' "${TEST_SITE_USER:-<auto-detect>}"
printf '\n'

SUITES=(
    test_static.sh
    test_pure.sh
    test_cli_contract.sh
    test_config.sh
    test_manager.sh
    test_fleet.sh
    test_wpcli_policy.sh
    test_finder.sh
    test_secretguard.sh
)
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
    export FAIL_FILE="${work}/fail" PASS_FILE="${work}/pass" SKIP_FILE="${work}/skip"
    : >"$FAIL_FILE"; : >"$PASS_FILE"; : >"$SKIP_FILE"
    if [ "${VERBOSE:-0}" = '1' ]; then
        export TEST_WORK="${work}/keep"
        mkdir -p "$TEST_WORK"
        chmod 755 "$TEST_WORK"
    fi
    suite_rc=0
    bash "$path" >"$log" 2>&1 || suite_rc=$?
    cat "$log"
    p="$(grep -c '' "$PASS_FILE" 2>/dev/null)"; p="${p//[^0-9]/}"; p="${p:-0}"
    f="$(grep -c '' "$FAIL_FILE" 2>/dev/null)"; f="${f//[^0-9]/}"; f="${f:-0}"
    s="$(grep -c '' "$SKIP_FILE" 2>/dev/null)"; s="${s//[^0-9]/}"; s="${s:-0}"
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
