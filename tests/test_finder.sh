#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# Discovery script behaviour: what it finds, what it refuses to find, the output
# formats, the manifest, the audit, and the list verifier.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-find.XXXXXX")}"
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
LIST="${WORK}/found.txt"

frun() {
    finder_run "$@" >"$OUT" 2>"$ERR"
}

say 'discovery finds the real installations and nothing else'
frun -o "$LIST" "$SITE_ROOT"
rc=$?
[ "$rc" -eq 0 ] && ok 'a successful scan exits 0' || bad 'scan exit code' "got $rc; $(tail -n 3 "$ERR")"
expect_lines "$LIST" 3 'three installations are found (opt-out and non-WP are not)'
grep -Fxq "$SITES" "$LIST" && ok 'example.com is listed' || bad 'example.com missing' ''
grep -Fxq "$SITES_SPACE" "$LIST" && ok 'a path with spaces is one whole line' \
    || bad 'spaced path' "$(cat "$LIST")"
grep -Fq "$SITES_OPTOUT" "$LIST" && bad 'the opt-out marker was ignored' '' \
    || ok '.no_wp_cli removes the site from the list'
grep -Fq "$SITES_NOTWP" "$LIST" && bad 'a non-WordPress directory was listed' '' \
    || ok 'a directory without WordPress markers is not listed'
expect_contains "$ERR" 'opt-out' 'the opt-out skip is counted in the log'

say '-o - writes the list to stdout'
frun -o - "$SITE_ROOT"
lines="$(grep -c '' "$OUT")"
[ "$lines" -eq 3 ] && ok 'three paths on stdout' || bad 'stdout path count' "got $lines"
grep -Fq "$SITES" "$ERR" && bad 'a path leaked into the prose stream' '' \
    || ok 'stdout carries data only'

say '--print0 survives any filename'
frun -o - --print0 "$SITE_ROOT"
nuls="$(tr -cd '\0' <"$OUT" | wc -c)"
nuls="${nuls//[^0-9]/}"
[ "${nuls:-0}" -eq 3 ] && ok 'three NUL-terminated records' || bad 'NUL count' "got ${nuls:-0}"

say 'output formats'
frun -o - --format tsv "$SITE_ROOT"
head -n 1 "$OUT" | grep -q 'path' && ok 'tsv has a header row' || bad 'tsv header' "$(head -n 1 "$OUT")"
grep -q '6.6.2' "$OUT" && ok 'tsv carries the WordPress version from version.php' \
    || bad 'tsv wp_version' "$(sed -n 2p "$OUT")"
frun -o - --format json "$SITE_ROOT"
first="$(head -c 1 "$OUT")"
[ "$first" = '[' ] && ok 'json output is an array' || bad 'json first byte' "got [$first]"
grep -q '"wp_version":"6.6.2"' "$OUT" && ok 'json carries the version' || bad 'json wp_version' ''
grep -q '"owner"' "$OUT" && ok 'json carries the owner' || bad 'json owner' ''
frun -o - --format csv "$SITE_ROOT"
head -n 1 "$OUT" | grep -q ',' && ok 'csv is delimited' || bad 'csv header' "$(head -n 1 "$OUT")"
frun -o - --format xml "$SITE_ROOT"
rc=$?
[ "$rc" -eq 2 ] && ok 'an unknown format exits 2' || bad 'bad format exit' "got $rc"

say 'the manifest is a separate, richer document'
frun -o "$LIST" --manifest "${WORK}/manifest.tsv" "$SITE_ROOT"
if [ -s "${WORK}/manifest.tsv" ]; then
    ok 'the manifest was written next to the list'
    grep -q 'config_mode' "${WORK}/manifest.tsv" && ok 'the manifest has the config_mode column' \
        || bad 'manifest columns' "$(head -n 1 "${WORK}/manifest.tsv")"
    grep -q '6.6.2' "${WORK}/manifest.tsv" && ok 'the manifest carries the version' \
        || bad 'manifest version' ''
else
    bad 'no manifest was written' ''
fi
frun -o "$LIST" --manifest - --manifest-format json --fields path,owner,wp_version "$SITE_ROOT"
grep -q '"wp_version":"6.6.2"' "$OUT" && ok 'a json manifest on stdout honours --fields' \
    || bad 'json manifest' "$(head -c 200 "$OUT")"
frun -o "$LIST" --manifest "${WORK}/m2" --fields path,bogus "$SITE_ROOT"
rc=$?
[ "$rc" -eq 2 ] && ok 'an unknown --fields column exits 2' || bad 'bad --fields exit' "got $rc"
frun -o "$LIST" --manifest "${WORK}/m3" --manifest-format xml "$SITE_ROOT"
rc=$?
[ "$rc" -eq 2 ] && ok 'an unknown --manifest-format exits 2' || bad 'bad manifest format exit' "got $rc"

say 'exclusions and inclusions'
frun -o - --exclude-name 'second*' "$SITE_ROOT"
lines="$(grep -c '' "$OUT")"
[ "$lines" -eq 2 ] && ok '--exclude-name drops the match' || bad '--exclude-name' "got $lines lines"
frun -o - --exclude-path "$SITES2" "$SITE_ROOT"
lines="$(grep -c '' "$OUT")"
[ "$lines" -eq 2 ] && ok '--exclude-path drops the subtree' || bad '--exclude-path' "got $lines lines"
frun -o - --include-name 'example*' "$SITE_ROOT"
lines="$(grep -c '' "$OUT")"
[ "$lines" -eq 1 ] && ok '--include-name narrows to the match' || bad '--include-name' "got $lines lines"
grep -Fxq "$SITES" "$OUT" && ok 'the included site is the right one' || bad '--include-name result' "$(cat "$OUT")"

say 'depth bounds'
frun -o - --depth 1 "$SITE_ROOT"
rc=$?
[ "$rc" -eq 5 ] && ok '--depth 1 finds nothing below the root and exits 5' || bad '--depth 1 exit' "got $rc"
frun -o - --depth 1 --fail-empty "$SITE_ROOT"
rc=$?
[ "$rc" -eq 1 ] && ok '--fail-empty turns 5 into 1' || bad '--fail-empty exit' "got $rc"
frun -o - --min-depth 3 "$SITE_ROOT"
rc=$?
[ "$rc" -eq 5 ] && ok '--min-depth 3 skips the shallow installations' || bad '--min-depth exit' "got $rc"

say 'the write is atomic and preserves the permissions of an existing list'
printf '/stale/entry\n' >"$LIST"
chmod 640 "$LIST"
frun -o "$LIST" "$SITE_ROOT"
mode="$(stat -c '%a' "$LIST" 2>/dev/null)"
[ "$mode" = '640' ] && ok 'the existing 0640 mode survived the rewrite' || bad 'list mode after rewrite' "got ${mode:-?}"
grep -Fq '/stale/entry' "$LIST" && bad 'the stale entry survived' '' || ok 'the old content was replaced'

say '--status describes the existing list without scanning'
frun --status -o "$LIST"
rc=$?
[ "$rc" -eq 0 ] && ok '--status exits 0' || bad '--status exit' "got $rc"
expect_contains "$ERR" 'entries' '--status counts the entries'
expect_contains "$ERR" '6.6.2' '--status shows the version of each site'

say '--verify-list audits a list instead of scanning'
frun --verify-list "$LIST"
rc=$?
[ "$rc" -eq 0 ] && ok 'a healthy list verifies with exit 0' || bad 'verify-list exit' "got $rc"
expect_contains "$ERR" '0 missing' 'the verification counts are printed'
printf '%s\n%s\n' "$SITES" "${SITE_ROOT}/gone.example" >"${WORK}/bad-list.txt"
frun --verify-list "${WORK}/bad-list.txt"
rc=$?
[ "$rc" -eq 1 ] && ok 'a list with a missing entry fails verification (exit 1)' || bad 'verify-list with a hole' "got $rc"
expect_contains "$ERR" 'MISSING' 'the missing entry is named'
frun --verify-list "${WORK}/no-such-list.txt"
rc=$?
[ "$rc" -eq 1 ] && ok 'verifying a nonexistent list fails' || bad 'verify-list missing file' "got $rc"

say '--audit reports a world-readable wp-config.php'
chmod 644 "${SITES2}/wp-config.php"
frun -o "$LIST" --audit "$SITE_ROOT"
expect_contains "$ERR" 'world-readable' 'the audit names the exposure'
expect_contains "$ERR" 'chmod 0640' 'the audit says how to fix it'
chmod 640 "${SITES2}/wp-config.php"
frun -o "$LIST" --audit "$SITE_ROOT"
grep -Fq 'world-readable' "$ERR" && bad 'a 0640 config is still called world-readable' '' \
    || ok 'a 0640 config passes the audit'

say 'an unreadable root is a warning, not a crash'
mkdir -p "${SITE_ROOT}/locked"
chmod 000 "${SITE_ROOT}/locked" 2>/dev/null
frun -o "$LIST" "$SITE_ROOT"
rc=$?
chmod 755 "${SITE_ROOT}/locked" 2>/dev/null
[ "$rc" -eq 0 ] && ok 'a locked directory does not fail the scan' || bad 'locked root exit' "got $rc"

report test_finder
