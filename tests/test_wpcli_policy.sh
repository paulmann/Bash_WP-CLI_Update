#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# The WP-CLI version policy and the self-update machinery: the floor gate, the
# --wpcli-check report, an update through a stub phar, and the rollback.
# No network access is used or required anywhere in this suite.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-wpcli.XXXXXX")}"
chmod 755 "$WORK" 2>/dev/null
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
REPO="$repo"
export REPO
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
build_fixture
trap 'cleanup_work' EXIT

OUT="${WORK}/out.txt"
ERR="${WORK}/err.txt"
PHAR="${WORK}/bin/wp-cli.phar"

# A phar-shaped stub: `wp cli update` only works on a phar install, and the
# manager detects the install kind from the resolved file name, so the update
# path needs a binary that looks like one.
mkdir -p "${WORK}/bin"
cp "$STUB_WP" "$PHAR"
chmod 755 "$PHAR"
printf '2.11.0\n' >"$WPCLI_VER_FILE"

# wpcli_run: hermetic invocation for the WP-CLI modes. These modes need no site
# list, no root and no lock contention, which is exactly the point of them.
wpcli_run() {
    FAKE_WP_LOG="$ARGV_LOG" \
    WP_STUB_VERSION_FILE="$WPCLI_VER_FILE" \
    WP_STUB_SELF="$PHAR" \
        bash "$MANAGER" --color never --log-file '' --error-log-file '' \
        --lock-file "${WORK}/wpcli.lock" --wp "$PHAR" "$@" >"$OUT" 2>"$ERR"
}

say '--wpcli-check reports the installation'
wpcli_run --wpcli-check; rc=$?
[ "$rc" -eq 0 ] && ok '--wpcli-check exits 0 for a satisfying version' || bad '--wpcli-check rc' "got $rc; $(tail -n 3 "$OUT" "$ERR")"
expect_contains "$OUT" 'install kind:' 'the report names the install kind'
expect_contains "$OUT" 'phar' 'the stub phar is recognised as a phar'
expect_contains "$OUT" '2.11.0' 'the installed version is reported'
expect_contains "$OUT" 'PASS' 'the minimum-version gate passes'
expect_contains "$OUT" 'self-update:' 'the report says whether a self-update is possible'

say 'the floor gate refuses an ancient WP-CLI'
wpcli_run --wpcli-check --wpcli-min-version 99.0.0; rc=$?
[ "$rc" -eq 3 ] && ok 'a version below the floor exits 3' || bad 'floor gate rc' "got $rc, want 3"
expect_contains "$OUT" 'FAIL' 'the gate reports FAIL'
expect_contains "$OUT" '99.0.0' 'the required minimum is named'

say 'the fleet run itself is gated at startup'
WP_CLI_STUB_VER=1.5.0 manager_run --no-user-switch --cron >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 3 ] && ok 'a fleet run on WP-CLI 1.5.0 refuses with exit 3' || bad 'startup gate rc' "got $rc"
expect_contains "$ERR" 'older than the required minimum' 'the refusal explains itself'
expect_contains "$ERR" '--wpcli-update' 'the refusal points at the fix'
WP_CLI_STUB_VER=2.5.0 manager_run --no-user-switch --cron --wpcli-min-version 2.4.0 >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 0 ] && ok 'a lowered floor lets the same version run' || bad 'lowered floor rc' "got $rc"

say 'a newer upstream release is reported as OUTDATED'
WP_CLI_NEWER=2.12.0 wpcli_run --wpcli-check; rc=$?
expect_contains "$OUT" '2.12.0' 'the newest release is named'
expect_contains "$OUT" 'OUTDATED' 'the installed version is marked outdated'
expect_contains "$OUT" '--wpcli-update' 'the report tells the operator what to run'
[ "$rc" -eq 0 ] && ok 'outdated alone does not fail the check' || bad 'outdated rc' "got $rc"
WP_CLI_NEWER=2.12.0 wpcli_run --wpcli-check --strict; rc=$?
[ "$rc" -eq 1 ] && ok '--strict turns OUTDATED into exit 1' || bad 'strict outdated rc' "got $rc"

say '--wpcli-update updates through the phar and keeps the old binary'
printf '2.11.0\n' >"$WPCLI_VER_FILE"
WP_UPDATE_TO=2.12.0 wpcli_run --wpcli-update --yes; rc=$?
[ "$rc" -eq 0 ] && ok '--wpcli-update exits 0' || bad '--wpcli-update rc' "got $rc; $(tail -n 5 "$OUT" "$ERR")"
expect_contains "$ERR" '2.11.0' 'the old version is named in the log'
expect_contains "$ERR" 'updated' 'the update is reported'
ver="$(head -n 1 "$WPCLI_VER_FILE" 2>/dev/null)"
[ "$ver" = '2.12.0' ] && ok 'the stub recorded the new version' || bad 'stub version after update' "got ${ver:-?}"
[ -f "${PHAR}.old" ] && ok 'the previous phar was kept as .old' || bad 'no .old backup' ''
wpcli_run --wpcli-check
expect_contains "$OUT" '2.12.0' 'a second --wpcli-check sees the new version'

say '--wpcli-rollback puts the previous binary back'
sum_before="$(cksum "$PHAR" 2>/dev/null | cut -d' ' -f1)"
sum_old="$(cksum "${PHAR}.old" 2>/dev/null | cut -d' ' -f1)"
wpcli_run --wpcli-rollback --yes; rc=$?
[ "$rc" -eq 0 ] && ok '--wpcli-rollback exits 0' || bad '--wpcli-rollback rc' "got $rc; $(tail -n 4 "$OUT" "$ERR")"
expect_contains "$ERR" 'rolled back' 'the rollback is reported'
sum_after="$(cksum "$PHAR" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$sum_old" ] && [ "$sum_after" = "$sum_old" ]; then
    ok 'the phar bytes are the previous binary again'
elif [ "$sum_after" = "$sum_before" ]; then
    bad 'the rollback did not change the binary' ''
else
    ok 'the binary was replaced by the rollback candidate'
fi

say 'an already-current install is a no-op'
printf '2.12.0\n' >"$WPCLI_VER_FILE"
wpcli_run --wpcli-update --wpcli-version 2.12.0 --yes; rc=$?
[ "$rc" -eq 0 ] && ok 'a pinned update to the running version exits 0' || bad 'pinned same-version rc' "got $rc"
expect_contains "$ERR" 'already at the requested version' 'the no-op is reported'

say 'validation and missing-binary paths'
wpcli_run --wpcli-update --wpcli-version 'not a version'; rc=$?
[ "$rc" -eq 2 ] && ok 'an invalid --wpcli-version exits 2' || bad 'invalid pinned version rc' "got $rc"
FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/wpcli.lock" --wp "${WORK}/bin/does-not-exist" \
    --wpcli-update >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 3 ] && ok '--wpcli-update without an installed wp exits 3' || bad 'missing-wp update rc' "got $rc"
expect_contains "$ERR" '--wpcli-install' 'the error points at the install command'
FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/wpcli.lock" --wp "${WORK}/bin/does-not-exist" \
    --wpcli-check >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 3 ] && ok '--wpcli-check without an installed wp exits 3' || bad 'missing-wp check rc' "got $rc"
expect_contains "$OUT" 'NOT FOUND' 'the check report says NOT FOUND'

say 'a non-phar install is reported honestly'
cp "$STUB_WP" "${WORK}/bin/wp"
chmod 755 "${WORK}/bin/wp"
FAKE_WP_LOG="$ARGV_LOG" WP_STUB_VERSION_FILE="$WPCLI_VER_FILE" \
    bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/wpcli.lock" --wp "${WORK}/bin/wp" --wpcli-check >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 0 ] && ok '--wpcli-check on a script install exits 0' || bad 'script install check rc' "got $rc"
expect_contains "$OUT" 'script' 'the install kind is "script", not phar'
expect_contains "$OUT" 'only supports a phar' 'the report explains the self-update limitation'

report test_wpcli_policy
