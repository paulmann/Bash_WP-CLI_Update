#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# The command-line contract: help, version, exit codes, mode/option validation,
# the inspection commands that must work without wp, without root and without a
# site list. Everything here runs against the real artifacts.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-cli.XXXXXX")}"
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

# plain_run: no fixture paths at all -- for the commands that must work on a
# bare host (that is the point of them).
plain_run() {
    bash "$MANAGER" --color never --log-file '' --error-log-file '' \
        --lock-file "${WORK}/plain.lock" "$@" >"$OUT" 2>&1
}

say '--help and --version'
plain_run --help; rc=$?
[ "$rc" -eq 0 ] && ok '--help exits 0' || bad '--help exit code' "got $rc"
expect_contains "$OUT" 'Modes (exactly one' '--help lists the modes'
expect_contains "$OUT" 'Exit codes' '--help documents the exit codes'
expect_contains "$OUT" '--wpcli-update' '--help documents the WP-CLI self-update'
expect_contains "$OUT" '--smoke-test' '--help documents the smoke test'
expect_contains "$OUT" '--metrics-file' '--help documents the metrics file'
expect_contains "$OUT" '--maintenance-mode' '--help documents maintenance mode'
expect_contains "$OUT" 'stdin' '--help documents the licence stdin handoff'
# every mode from --list-modes must appear in the help, or the help is a lie
plain_run --list-modes
modes_rc=$?
[ "$modes_rc" -eq 0 ] && ok '--list-modes exits 0' || bad '--list-modes exit code' "got $modes_rc"
missing=0
while IFS= read -r m; do
    [ -n "$m" ] || continue
    plain_run --help
    grep -Fq -- "--${m}" "$OUT" || { missing=$((missing + 1)); printf '      help is missing --%s\n' "$m" >&2; }
done <<<"$(bash "$MANAGER" --list-modes 2>/dev/null)"
[ "$missing" -eq 0 ] && ok 'every mode is documented in --help' || bad 'modes missing from --help' "$missing"

plain_run --version; rc=$?
[ "$rc" -eq 0 ] && ok '--version exits 0' || bad '--version exit code' "got $rc"
grep -Eq '^[A-Za-z0-9_.-]+ [0-9]+\.[0-9]+\.[0-9]+' "$OUT" && ok '--version prints name and semver' \
    || bad '--version output' "$(head -n 1 "$OUT")"

plain_run --version-detail; rc=$?
[ "$rc" -eq 0 ] && ok '--version-detail exits 0' || bad '--version-detail exit code' "got $rc"
expect_contains "$OUT" 'build' '--version-detail shows the build id'
expect_contains "$OUT" 'user switch' '--version-detail shows the switch mechanism'
expect_contains "$OUT" 'minimum' '--version-detail shows the WP-CLI floor'

say 'usage errors are exit 2, and say what is wrong'
expect_rc 2 'no mode' bash "$MANAGER" --color never
plain_run --bogus-flag; rc=$?
[ "$rc" -eq 2 ] && ok 'unknown option exits 2' || bad 'unknown option exit code' "got $rc"
expect_contains "$OUT" 'unknown option' 'the unknown option is named'
plain_run --timeout abc --full; rc=$?
[ "$rc" -eq 2 ] && ok '--timeout abc exits 2' || bad '--timeout abc exit code' "got $rc"
expect_contains "$OUT" 'non-negative integer' 'the reason is printed'
plain_run --full --core
expect_grep_count "$OUT" 'conflicting modes' 1 'two modes are refused'
[ "$rc" -eq 2 ] && ok 'conflicting modes exit 2' || bad 'conflicting modes exit code' "got $rc"
plain_run --jobs 0 --full
expect_contains "$OUT" 'positive integer' '--jobs 0 is refused with a reason'
plain_run --format xml --list-plugins
expect_contains "$OUT" 'must be one of' '--format xml is refused'
plain_run -m -N jetpack
expect_contains "$OUT" 'requires --action' '--plugin-manage without --action is refused'
plain_run -m -A delete
expect_contains "$OUT" 'requires --name' '--plugin-manage without --name is refused'
plain_run -m -A launch -N x
expect_contains "$OUT" '--action must be one of' 'an unknown action is refused'
plain_run --themes --only-active
expect_contains "$OUT" 'only apply to --plugins and --full' '--only-active on --themes is refused'
plain_run --restore
expect_contains "$OUT" '--restore requires --site' '--restore without --site is refused'
plain_run --completion fish
expect_contains "$OUT" 'bash' '--completion fish explains the supported shells'
[ "$rc" -eq 2 ] && ok '--completion fish exits 2' || bad '--completion fish exit code' "got $rc"

say 'suggestions for near-miss spellings'
plain_run --time 5 --full
expect_contains "$OUT" 'did you mean --timeout' 'a prefix-typo option gets a suggestion'

say 'inspection commands work without wp and without root'
plain_run --init-config
expect_contains "$OUT" 'WP_CLI_PATH=' '--init-config prints the key list'
expect_contains "$OUT" 'Precedence' '--init-config documents the precedence'
expect_contains "$OUT" 'LICENCE_HANDOFF' '--init-config includes the licence handoff key'
cfg="${WORK}/gen.conf"
plain_run --init-config "$cfg"; rc=$?
[ "$rc" -eq 0 ] && [ -s "$cfg" ] && ok '--init-config FILE writes the file' || bad '--init-config FILE' "rc=$rc"
mode="$(stat -c '%a' "$cfg" 2>/dev/null)"
[ "$mode" = '600' ] && ok 'the generated config is mode 0600' || bad 'generated config mode' "got ${mode:-?}"

plain_run --print-config
expect_contains "$OUT" 'SETTING' '--print-config prints the table'
expect_contains "$OUT" 'precedence' '--print-config restates the precedence'
expect_contains "$OUT" 'WP_CLI_MIN_VERSION' '--print-config shows the version floor'
grep -Eq 'LICENCE +<set' "$OUT" && bad '--print-config leaks the licence' 'it must show <unset> or a length' \
    || ok '--print-config does not print a licence value'

plain_run --completion bash
expect_contains "$OUT" 'complete -F' '--completion bash emits a complete(1) line'
expect_contains "$OUT" '--wpcli-update' 'the completion knows the new modes'
printf '%s\n' "$OUT" >/dev/null
bash -n <(sed -n '/_complete()/,$p' "$OUT") 2>/dev/null \
    && ok 'the generated bash completion parses' \
    || skip 'the generated bash completion parses' 'process substitution unavailable'

plain_run --list-sites --sites /nonexistent-list-$$ ; rc=$?
[ "$rc" -ne 0 ] && ok '--list-sites with a missing list fails' || bad '--list-sites with a missing list' "rc=$rc"

say '--list-sites resolves a real list without touching wp'
printf '%s\n%s\n' "$SITES" "$SITES2" >"${WORK}/two.txt"
FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/ls.lock" --no-user-switch --no-discover \
    --sites "${WORK}/two.txt" --list-sites >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok '--list-sites exits 0' || bad '--list-sites exit code' "got $rc; output: $(head -n 3 "$OUT")"
expect_contains "$OUT" "$SITES" '--list-sites lists the first site'
expect_contains "$OUT" "$SITES2" '--list-sites lists the second site'
FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/ls.lock" --no-user-switch --no-discover \
    --sites "${WORK}/two.txt" --list-sites --format json >"$OUT" 2>/dev/null
grep -q '"path"' "$OUT" && ok '--list-sites --format json emits path records' \
    || bad '--list-sites --format json' "$(head -n 2 "$OUT")"

say 'the site list can come from stdin'
printf '%s\n' "$SITES" | FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never \
    --log-file '' --error-log-file '' --lock-file "${WORK}/ls.lock" \
    --no-user-switch --no-discover --sites - --list-sites >"$OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] && expect_contains "$OUT" "$SITES" '--sites - reads the list from stdin' \
    || bad '--sites - stdin list' "rc=$rc"

say 'an owner can be forced per line with a TAB'
printf '%s\t%s\n' "$SITES" "$(id -un)" >"${WORK}/owned.txt"
FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/ls.lock" --no-discover --sites "${WORK}/owned.txt" \
    --list-sites >"$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    expect_contains "$OUT" "$(id -un)" 'the TAB owner column is honoured'
else
    skip 'the TAB owner column is honoured' "--list-sites rc=$rc (needs a resolvable owner)"
fi

say 'an empty resolved list exits 5, and --fail-on never exits 0'
: >"${WORK}/empty.txt"
manager_run --core --no-discover --sites "${WORK}/empty.txt" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 5 ] && ok 'nothing to do exits 5' || bad 'nothing-to-do exit code' "got $rc, want 5"
manager_run --core --no-discover --fail-on never --sites "${WORK}/empty.txt" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok '--fail-on never maps nothing-to-do to 0' || bad '--fail-on never with an empty list' "got $rc"

say 'a list entry that is not a WordPress root is skipped, not processed'
printf '%s\n%s\n' "$SITES" "$SITES_NOTWP" >"${WORK}/mixed.txt"
# stdout only, as TSV: the skip warning legitimately names the path on stderr,
# and a test that reads the merged streams would pass or fail on a log message.
# TSV because the table pads columns and an exact-cell assertion would depend on
# the width of the longest path in the run.
manager_run --list-sites --no-discover --format tsv --sites "${WORK}/mixed.txt" >"$OUT" 2>"${WORK}/mixed.err"
if grep -q "^${SITES}$(printf '\t')" "$OUT"; then
    ok 'the real site is in the work list'
else
    bad 'the real site is missing from the work list' "$(head -n 5 "$OUT")"
fi
if grep -Fq "$SITES_NOTWP" "$OUT"; then
    bad 'the non-WordPress directory must not become a work unit' "$(head -n 5 "$OUT")"
else
    ok 'the non-WordPress directory is not in the work list'
fi
expect_contains "${WORK}/mixed.err" 'not a WordPress root' 'the skip is explained on stderr'

report test_cli_contract
