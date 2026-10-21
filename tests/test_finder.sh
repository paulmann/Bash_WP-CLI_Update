#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Behavioural tests for Find_WP_Senior.sh.
# No root required for the scanning tests; the ownership tests need one and are
# skipped otherwise.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-finder.XXXXXX")"
chmod 755 "$WORK"
# Counters: honour the ones a parent runner exported (tests/run_tests.sh tallies
# every suite from them) and fall back to a private set when the suite runs alone.
# Overwriting them unconditionally is what made run_tests.sh report 0/0/0 while
# the suite itself printed a correct total.
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
trap 'rm -rf -- "$WORK"' EXIT
build_fixture

F="$FINDER"
OUT="${WORK}/out.txt"

say 'usage and validation'
expect_rc 0 '--help exits 0' bash "$F" --help
expect_rc 0 '--version exits 0' bash "$F" --version
expect_rc 2 'an unknown option exits 2' bash "$F" --nonsense
expect_rc 2 'a bad --format exits 2' bash "$F" --format yaml /srv
expect_rc 2 'a bad --depth exits 2' bash "$F" --depth 99 /srv
expect_rc 2 'a non-numeric --depth exits 2' bash "$F" --depth abc /srv
expect_rc 2 'a multi-character --delimiter exits 2' bash "$F" --delimiter xy /srv
help_txt="${WORK}/fhelp.txt"
bash "$F" --help >"$help_txt" 2>&1
for opt in --output --depth --exclude-name --exclude-path --format --status --skip-existing --fail-empty --quiet --verbose; do
    if grep -Fq -- "$opt" "$help_txt"; then ok "help documents ${opt}"; else bad "help is missing ${opt}" ''; fi
done

say 'discovery'
finder_run --output "$OUT" "$SITE_ROOT" >"${WORK}/d.log" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok "discovery exits 0"; else bad 'discovery exit code' "expected 0, got ${rc}"; fi
expect_lines "$OUT" 3 'three installations are listed'
for s in "$SITES" "$SITES2" "$SITES_SPACE"; do
    if grep -Fxq "$s" "$OUT"; then ok "listed: ${s##*/}"; else bad "missing: ${s##*/}" "$(tr '\n' ' ' <"$OUT")"; fi
done
if grep -Fxq "$SITES_OPTOUT" "$OUT"; then
    bad 'the opt-out marker was ignored' "$SITES_OPTOUT"
else
    ok 'the opt-out marker .no_wp_cli is honoured'
fi
if grep -Fxq "$SITES_NOTWP" "$OUT"; then
    bad 'a non-WordPress directory was listed' "$SITES_NOTWP"
else
    ok 'a directory without wp-config.php is rejected'
fi
expect_contains "${WORK}/d.log" 'opt-out' 'the opt-out skip is counted in the log'

say 'detection rule'
# wp-config.php alone is not enough: a stray config file must not turn an
# arbitrary directory into a "site" that the manager will run wp against.
stray="${WORK}/stray"
mkdir -p "$stray"
printf '<?php // nothing else here\n' >"${stray}/wp-config.php"
finder_run --output "$OUT" "$stray" >/dev/null 2>&1
rc=$?
if [ "$rc" = '5' ]; then ok 'a lone wp-config.php is not a site (exit 5)'; else bad 'lone wp-config.php' "expected exit 5, got ${rc}"; fi
expect_lines "$OUT" 0 'the list is empty'
# ...but wp-load.php or wp-includes/version.php each make it one
printf '<?php // load\n' >"${stray}/wp-load.php"
if finder_run --output "$OUT" "$stray" >/dev/null 2>&1; then
    ok 'wp-config.php + wp-load.php is a site'
else
    bad 'wp-config.php + wp-load.php was not detected' ''
fi

say 'exclusions'
ex="${WORK}/ex"
make_site "${ex}/keep"
make_site "${ex}/node_modules/inner"
make_site "${ex}/keepme-too"
finder_run --output "$OUT" "$ex" >/dev/null 2>&1
if grep -Fxq "${ex}/node_modules/inner" "$OUT"; then
    bad 'node_modules was not pruned' "$(tr '\n' ' ' <"$OUT")"
else
    ok 'a default name exclusion prunes node_modules'
fi
expect_contains "$OUT" "${ex}/keep" 'a normal site is kept'
finder_run --output "$OUT" --no-default-excludes "$ex" >/dev/null 2>&1
if grep -Fq 'node_modules' "$OUT"; then
    ok '--no-default-excludes really disables the defaults'
else
    bad '--no-default-excludes had no effect' "$(tr '\n' ' ' <"$OUT")"
fi
finder_run --output "$OUT" --exclude-path "${ex}/keep" "$ex" >/dev/null 2>&1
if grep -Fxq "${ex}/keep" "$OUT"; then
    bad '--exclude-path did not exclude' "$(tr '\n' ' ' <"$OUT")"
else
    ok '--exclude-path removes a subtree'
fi
finder_run --output "$OUT" --exclude-name 'keepme-*' "$ex" >/dev/null 2>&1
if grep -Fxq "${ex}/keepme-too" "$OUT"; then
    bad '--exclude-name did not exclude' "$(tr '\n' ' ' <"$OUT")"
else
    ok '--exclude-name matches a glob'
fi

say 'depth'
deep="${WORK}/deep/a/b/c/d/e/f"
make_site "${deep}/site"
finder_run --output "$OUT" --depth 3 "${WORK}/deep" >/dev/null 2>&1
expect_lines "$OUT" 0 'depth 3 does not reach the site'
finder_run --output "$OUT" --depth 9 "${WORK}/deep" >/dev/null 2>&1
expect_lines "$OUT" 1 'depth 9 reaches it'

say 'multiple roots replace the defaults instead of adding to them'
r1="${WORK}/r1"; r2="${WORK}/r2"
make_site "${r1}/a"
make_site "${r2}/b"
finder_run --output "$OUT" "$r1" "$r2" >/dev/null 2>&1
expect_lines "$OUT" 2 'both roots contributed exactly one site each'

say 'duplicate roots are deduplicated'
finder_run --output "$OUT" "$r1" "$r1" >/dev/null 2>&1
expect_lines "$OUT" 1 'the same root twice yields one entry'

say 'output formats'
finder_run --format paths --output "$OUT" "$r1" >/dev/null 2>&1
expect_lines "$OUT" 1 'paths: one bare path per line'
if grep -q $'\t' "$OUT"; then bad 'paths format contains a tab' 'the manager reads one path per line'; else ok 'paths format has no metadata columns'; fi

finder_run --format tsv --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
if head -1 "$OUT" | grep -Fq 'path'; then
    ok 'tsv: header present'
else
    bad 'tsv header missing' "$(head -1 "$OUT")"
fi
cols="$(head -1 "$OUT" | awk -F'\t' '{print NF}')"
if [ "$cols" = '6' ]; then ok 'tsv: six columns'; else bad 'tsv column count' "got ${cols}"; fi

finder_run --format csv --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import csv,sys
with open(sys.argv[1], newline='') as fh:
    rows=list(csv.reader(fh))
assert rows[0][0]=='path', rows[0]
assert len(rows)>=2, len(rows)
" "$OUT" 2>/dev/null; then
        ok 'csv: parses with a real CSV reader'
    else
        bad 'csv: does not parse' "$(head -2 "$OUT")"
    fi
    # a site whose path contains the delimiter must be quoted
    if python3 -c "
import csv,sys
rows=list(csv.reader(open(sys.argv[1], newline='')))
paths=[r[0] for r in rows[1:]]
assert any(' ' in p for p in paths), paths
" "$OUT" 2>/dev/null; then
        ok 'csv: a path with a space survives the round trip'
    else
        bad 'csv: the space path was mangled' "$(head -3 "$OUT")"
    fi
else
    skip 'csv parsing' 'python3 not installed'
fi

finder_run --format json --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
json_ok=0
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d,list) and d, d
assert 'path' in d[0] and 'owner' in d[0] and 'wp_version' in d[0], d[0]
" "$OUT" 2>/dev/null && json_ok=1
elif command -v node >/dev/null 2>&1; then
    node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));if(!Array.isArray(d)||!d.length||!d[0].path)process.exit(1)" "$OUT" 2>/dev/null && json_ok=1
fi
if [ "$json_ok" = '1' ]; then
    ok 'json: parses and carries path/owner/wp_version'
else
    if command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
        bad 'json: does not parse' "$(head -c 200 "$OUT")"
    else
        skip 'json parsing' 'neither python3 nor node installed'
    fi
fi
finder_run --format json --output - "$SITE_ROOT" 2>/dev/null >"${WORK}/stdout.json"
if [ -s "${WORK}/stdout.json" ]; then
    ok '--output - writes the result to stdout'
else
    bad '--output - produced nothing on stdout' ''
fi

say 'stdout carries data only, stderr carries prose'
finder_run --format paths --output - "$SITE_ROOT" >"${WORK}/so.txt" 2>"${WORK}/se.txt"
if grep -Eq '^(INF|OK|WRN|ERR|DBG) ' "${WORK}/so.txt"; then
    bad 'log lines leaked into stdout' "$(head -3 "${WORK}/so.txt")"
else
    ok 'stdout holds paths only'
fi
if grep -Eq '^(INF|OK) ' "${WORK}/se.txt"; then
    ok 'prose went to stderr'
else
    bad 'no prose on stderr' 'the operator gets no feedback'
fi

say 'the write is atomic and keeps the existing permissions'
printf '/stale/entry\n' >"$OUT"
chmod 640 "$OUT"
finder_run --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
if grep -Fq '/stale/entry' "$OUT"; then
    bad 'the old list was appended to instead of replaced' "$(cat "$OUT")"
else
    ok 'the list was replaced, not appended'
fi
mode="$(stat -c '%a' "$OUT" 2>/dev/null)"
if [ "$mode" = '640' ]; then
    ok "the previous mode 640 was preserved (got ${mode})"
else
    skip 'permission preservation' "stat reported ${mode:-?}; --reference may be unsupported here"
fi
tmp_left="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'Find_WP_Senior.sh.*' -newermt '-2 minutes' 2>/dev/null | wc -l)"
tmp_left="${tmp_left//[^0-9]/}"
if [ "${tmp_left:-0}" -eq 0 ]; then
    ok 'no temporary file was left behind'
else
    bad 'temporary files leaked' "${tmp_left} file(s) matching Find_WP_Senior.sh.* in ${TMPDIR:-/tmp}"
fi

say '--skip-existing'
printf '%s\n' "$SITES" >"$OUT"
finder_run --skip-existing --output "$OUT" "$SITE_ROOT" >"${WORK}/se2.log" 2>&1 || true
if grep -Fxq "$SITES" "$OUT"; then
    bad '--skip-existing kept the already listed site' "$(tr '\n' ' ' <"$OUT")"
else
    ok '--skip-existing dropped the already listed site'
fi
expect_contains "${WORK}/se2.log" 'already listed' 'the dropped entries are reported'

say '--status describes the existing list without scanning'
printf '%s\n%s\n' "$SITES" "${WORK}/vanished.example" >"$OUT"
status_out="${WORK}/status.txt"
finder_run --status --output "$OUT" >"$status_out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--status exits 0'; else bad '--status exit code' "got ${rc}"; fi
expect_contains "$status_out" "$SITES" '--status names a listed site'
expect_contains "$status_out" 'vanished.example' '--status names a missing site'
expect_contains "$status_out" 'missing' '--status flags the missing one'
if grep -Fq 'scanning:' "$status_out"; then
    bad '--status scanned the filesystem' 'it must only read the list'
else
    ok '--status did not scan'
fi

say '--quiet and --verbose'
quiet_err="${WORK}/q.txt"
finder_run --quiet --output "$OUT" "$SITE_ROOT" 2>"$quiet_err" >/dev/null
if grep -Eq '^INF ' "$quiet_err"; then
    bad '--quiet still printed info lines' "$(head -3 "$quiet_err")"
else
    ok '--quiet suppresses info lines'
fi
verbose_err="${WORK}/v.txt"
finder_run --verbose --output "$OUT" "$SITE_ROOT" 2>"$verbose_err" >/dev/null
if grep -Eq '^DBG ' "$verbose_err"; then
    ok '--verbose explains what it skips'
else
    bad '--verbose produced no debug lines' ''
fi

say 'no installation found'
empty="${WORK}/empty"
mkdir -p "$empty"
finder_run --output "$OUT" "$empty" >"${WORK}/e.log" 2>&1
rc=$?
if [ "$rc" = '5' ]; then ok 'nothing found exits 5'; else bad 'nothing-found exit code' "expected 5, got ${rc}"; fi
expect_lines "$OUT" 0 'an empty list is still written, so a stale list cannot survive'
finder_run --output "$OUT" --fail-empty "$empty" >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok '--fail-empty turns it into 1'; else bad '--fail-empty' "expected 1, got ${rc}"; fi

say 'unreadable and missing roots are reported, not fatal'
missing="${WORK}/does-not-exist"
finder_run --output "$OUT" "$missing" "$SITE_ROOT" >"${WORK}/m.log" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'a missing root does not abort the run'
else
    bad 'a missing root aborted the run' "exit ${rc}"
fi
expect_lines "$OUT" 3 'the readable root still produced its sites'
finder_run --output "$OUT" "$missing" >/dev/null 2>&1
rc=$?
if [ "$rc" = '5' ] || [ "$rc" = '1' ]; then
    ok "only missing roots: exit ${rc}"
else
    bad 'only missing roots' "expected 5 or 1, got ${rc}"
fi

say 'the site list is ready for the manager'
finder_run --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
# The manager must be able to consume it verbatim: absolute paths, one per line,
# no trailing whitespace, no CR, no header.
if grep -q $'\r' "$OUT"; then
    bad 'the list contains CR bytes' 'the manager would look for a directory with a \r in its name'
else
    ok 'the list has no CR bytes'
fi
if grep -Eq '^[[:space:]]|[[:space:]]$' "$OUT"; then
    bad 'the list has leading or trailing whitespace' ''
else
    ok 'the list has no stray whitespace'
fi
if grep -qv '^/' "$OUT"; then
    bad 'the list holds a relative path' "$(grep -v '^/' "$OUT" | head -2)"
else
    ok 'every entry is absolute'
fi
while IFS= read -r line; do
    [ -d "$line" ] || { bad "a listed path is not a directory" "$line"; break; }
done <"$OUT"
ok 'every listed path exists'

report 'finder'
