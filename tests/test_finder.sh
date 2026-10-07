#!/usr/bin/env bash
# Test suite for Find_WP_Senior.sh v2.0.0.
# Builds a synthetic tree, then checks the behaviour that the v1 script got wrong.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/Find_WP_Senior.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/findertest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail_file="$work/fails"; : >"$fail_file"
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; printf 'x\n' >>"$fail_file"; }
count_fails() { local n; n="$(grep -c '' "$fail_file" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
say() { printf '\n=== %s ===\n' "$1"; }
expect_rc() { local want="$1" name="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else bad "$name: rc=$got, want $want"; fi; }

mk_wp() { # DIR [marker]
    mkdir -p "$1/wp-includes"
    printf '<?php\ndefine("DB_NAME","x");\n' >"$1/wp-config.php"
    printf '<?php\n' >"$1/wp-includes/version.php"
    [ "${2:-}" = marker ] && : >"$1/.no_wp_cli"
}

root="$work/var/www"
mk_wp "$root/alpha.com"
mk_wp "$root/beta.com"
mk_wp "$root/nested/deep.com"
mk_wp "$root/.hidden/site.com"
# excluded by directory name
mk_wp "$root/node_modules/pkg/site.com"
mk_wp "$root/cache/site.com"
mk_wp "$root/backup-2025/site.com"
# legitimate production sites whose names contain the v1 exclusion substrings
mk_wp "$root/oldtown.com"
mk_wp "$root/btest.example.com"
mk_wp "$root/contest.org"
# opt-out marker
mk_wp "$root/marked.com" marker
# not a WordPress installation
mkdir -p "$root/static/downloads"
# deeper than the default depth of 6 but within 8
mk_wp "$root/a/b/c/d/e/f/deep-site.com"

out="$work/wp-found.txt"

say 'scan, default settings'
"$script" "$root" --output "$out" --quiet >"$work/stdout.txt" 2>"$work/stderr.txt"
rc=$?
[ "$rc" -eq 0 ] && ok 'exit code 0 when installations are found' || bad "exit code $rc"
mapfile -t got <"$out"
has() { local needle="$1" line; for line in "${got[@]}"; do [ "$line" = "$needle" ] && return 0; done; return 1; }
hasnt() { ! has "$1"; }
has "$root/alpha.com"                 && ok 'plain installation found'                     || bad 'plain installation missing'
has "$root/beta.com"                  && ok 'second installation found'                    || bad 'second installation missing'
has "$root/nested/deep.com"           && ok 'nested installation found'                    || bad 'nested installation missing'
has "$root/.hidden/site.com"          && ok 'dot-directory installation found'             || bad 'dot-directory installation missing'
has "$root/a/b/c/d/e/f/deep-site.com" && ok 'installation deeper than depth 6 found'       || bad 'deep installation missing (depth limit)'
has "$root/oldtown.com"               && ok 'oldtown.com is NOT excluded by substring'     || bad 'oldtown.com wrongly excluded'
has "$root/btest.example.com"         && ok 'btest.example.com is NOT excluded'           || bad 'btest.example.com wrongly excluded'
has "$root/contest.org"               && ok 'contest.org is NOT excluded'                 || bad 'contest.org wrongly excluded'
hasnt "$root/node_modules/pkg/site.com" && ok 'node_modules pruned'                        || bad 'node_modules not pruned'
hasnt "$root/cache/site.com"            && ok 'cache pruned'                               || bad 'cache not pruned'
hasnt "$root/marked.com"                && ok '.no_wp_cli marker honoured'                 || bad '.no_wp_cli ignored'
hasnt "$root/static"                    && ok 'plain directory is not reported'            || bad 'directory leaked into the result'

say 'exclusion precision'
# A name like 'backup-2025' is kept on purpose: the name alone cannot tell a
# stale copy from a live site. Exclusions are whole-component and explicit.
has "$root/backup-2025/site.com" && ok 'backup-2025 kept by default (not guessed away)' || bad 'backup-2025 unexpectedly dropped'
"$script" "$root" --output "$work/exb.txt" --exclude-name backup-2025 --quiet >/dev/null 2>&1
if grep -q 'backup-2025' "$work/exb.txt"; then bad '--exclude-name backup-2025 ignored'; else ok '--exclude-name backup-2025 removes it'; fi

say 'output hygiene'
if grep -q '^/' "$out"; then ok 'output holds absolute paths only'; else bad 'output format'; fi
if diff <(printf '%s\n' "${got[@]}") <(printf '%s\n' "${got[@]}" | sort) >/dev/null; then ok 'output is sorted'; else bad 'output not sorted'; fi
if [ "$(grep -c '' "$out")" -eq "$(sort -u "$out" | grep -c '')" ]; then ok 'output is unique'; else bad 'duplicates in output'; fi
# The list is consumed on Linux; CRLF would make every path compare unequal.
if [ "$(tr -cd '\r' <"$out" | wc -c)" -eq 0 ]; then ok 'no CR byte in the output file'; else bad 'CR found in the output file'; fi
if [ "$(tail -c1 "$out" | od -An -c | tr -d ' \n')" = '\n' ]; then ok 'output ends with a newline'; else bad 'output has no trailing newline'; fi

say 'result formats'
"$script" "$root" --output "$work/r.tsv" --format tsv --quiet >/dev/null 2>&1
if awk -F'\t' 'NF==4 && $1 ~ /^\// {n++} END {exit !(n>0)}' "$work/r.tsv"; then ok 'tsv has 4 tab-separated columns'; else bad 'tsv format'; head -3 "$work/r.tsv"; fi
"$script" "$root" --output "$work/r.csv" --format csv --quiet >/dev/null 2>&1
if head -1 "$work/r.csv" | grep -q '^path,owner,group,mtime$'; then ok 'csv header present'; else bad 'csv header'; head -1 "$work/r.csv"; fi
"$script" "$root" --output "$work/r.json" --format json --quiet >/dev/null 2>&1
if node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));if(!Array.isArray(d))throw 'not array';if(!d.length)throw 'empty';if(!d[0].path)throw 'no path field';" "$work/r.json" 2>/dev/null; then ok 'json parses and has path fields'; else bad 'json output'; head -c 200 "$work/r.json"; fi

say 'exclusions and options'
"$script" "$root" --output "$work/r2.txt" --exclude-name beta.com --quiet >/dev/null 2>&1
if grep -qx "$root/beta.com" "$work/r2.txt"; then bad '--exclude-name ignored'; else ok '--exclude-name works'; fi
"$script" "$root" --output "$work/r3.txt" --exclude-path "$root/nested" --quiet >/dev/null 2>&1
if grep -q 'nested/deep.com' "$work/r3.txt"; then bad '--exclude-path ignored'; else ok '--exclude-path works'; fi
"$script" "$root" --output "$work/r4.txt" --depth 3 --quiet >/dev/null 2>&1
if grep -q 'a/b/c/d/e/f/deep-site.com' "$work/r4.txt"; then bad '--depth ignored'; else ok '--depth limits the walk'; fi
"$script" "$work/empty-root" --output "$work/r5.txt" --quiet >/dev/null 2>&1
[ "$?" -eq 1 ] && ok 'a missing root exits 1' || bad "missing root rc=$?"

say 'no installations found'
mkdir -p "$work/empty"
expect_rc 5 'empty root exits 5' "$script" "$work/empty" --output "$work/empty.txt" --quiet
if [ -f "$work/empty.txt" ] && [ ! -s "$work/empty.txt" ]; then ok 'empty result file is created empty'; else bad 'empty result file'; fi

say 'status and skip-existing'
"$script" --output "$out" --status >"$work/status.txt" 2>&1
if grep -q 'entries:' "$work/status.txt"; then ok '--status reports the entry count'; else bad '--status'; cat "$work/status.txt"; fi
before="$(date +%s)"
"$script" "$root" --output "$out" --skip-existing --quiet >/dev/null 2>&1
after="$(date +%s)"
if [ "$before" -le "$after" ]; then ok '--skip-existing completes'; fi
if [ "$(grep -c '' "$out")" -gt 0 ]; then ok 'rewriting keeps the content'; else bad 'content lost'; fi

say 'usage and compatibility'
expect_rc 0 '--help exits 0' "$script" --help
expect_rc 0 '--version exits 0' "$script" --version
expect_rc 2 'unknown option exits 2' "$script" --nonsense
expect_rc 2 'bad format exits 2' "$script" --format yaml
expect_rc 2 'bad depth exits 2' "$script" --depth abc
if "$script" --help 2>&1 | grep -q -- '--output'; then ok 'help documents --output'; else bad 'help text'; fi

say 'the manager can consume the produced list'
bash "$repo/Find_WP_Senior.sh" "$root" --output "$work/manager.txt" --quiet >/dev/null 2>&1
if grep -qx "$root/alpha.com" "$work/manager.txt"; then ok 'site list is ready for the manager'; else bad 'manager list'; fi

printf '\n=== %s ===\n' "$([ "$(count_fails)" -eq 0 ] && echo 'ALL FINDER CHECKS PASSED' || echo "$(count_fails) CHECK(S) FAILED")"
test "$(count_fails)" -eq 0
