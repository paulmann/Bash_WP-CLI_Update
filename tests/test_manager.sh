#!/usr/bin/env bash
# Behavioural tests for Bash_WP-CLI_Update.sh.\n#\n# No root, no WordPress, no WP-CLI: a stub 'wp' records its own argv and returns\n# canned JSON, so the exact command line and the parsing can be verified.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/Bash_WP-CLI_Update.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/wpsmoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0

say() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf '  PASS  %s\n' "$1"; }
# The tally lives in a file: a counter incremented inside a pipeline or a command
# substitution would be lost in the subshell, which is exactly the bug class this
# suite looks for in the scripts under test.
fail_file="$work/fails"
: >"$fail_file"
bad() { printf '  FAIL  %s\n' "$1"; printf 'x\n' >>"$fail_file"; }
count_fails() { local n; n="$(grep -c '' "$fail_file" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
expect_rc() { # EXPECTED NAME COMMAND...
    local want="$1" name="$2"; shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else bad "$name: rc=$got, want $want"; fi
}
direct() { # extra args...
    bash "$script" "${LOGS[@]}" "$@"
}

# --- fake wp: records its own argv, one line per argument, then prints JSON ---
mkdir -p "$work/bin"
cat >"$work/bin/wp" <<'FAKE'
#!/usr/bin/env bash
: "${WP_ARGV_LOG:?WP_ARGV_LOG must be set}"
printf 'argc=%s\n' "$#" >>"$WP_ARGV_LOG"
for a in "$@"; do printf 'argv[%s]\n' "$a" >>"$WP_ARGV_LOG"; done
printf 'env HOMEDIR=%s DOCUMENT_ROOT=%s\n' "${HOMEDIR:-}" "${DOCUMENT_ROOT:-}" >>"$WP_ARGV_LOG"
cmd="${1:-}"; sub="${2:-}"
case "$cmd $sub" in
  'plugin list')
      printf '[{"name":"Akismet Anti-Spam","status":"active","version":"5.3","update":"none","update_version":"","slug":"akismet","title":"Akismet Anti-Spam"},'
      printf '{"name":"WooCommerce","status":"inactive","version":"8.1.0","update":"available","update_version":"9.0.0","slug":"woocommerce","title":"WooCommerce"},'
      printf '{"name":"All in One SEO","status":"active","version":"4.4.0","update":"none","update_version":"","slug":"all-in-one-seo-pack","title":"All in One SEO (AIOSEO)"}]\n'
      ;;
  'plugin update') printf 'Success: Updated 1 of 1 plugin.\n' ;;
  'plugin status') printf 'Plugin astra-addon is active\n' ;;
  'plugin activate')   printf 'Success: Activated plugin.\n' ;;
  'plugin deactivate') printf 'Success: Deactivated plugin.\n' ;;
  'plugin delete')     printf 'Success: Deleted plugin.\n' ;;
  'core version')      printf '6.6.2\n' ;;
  'core update')       printf 'Success: WordPress updated successfully.\n' ;;
  *)                   printf 'Success: %s %s ok\n' "$cmd" "$sub" ;;
esac
FAKE
chmod +x "$work/bin/wp"

# --- a synthetic WordPress tree ---
site="$work/var/www/example.com"
mkdir -p "$site/wp-includes"
printf '<?php\ndefine("DB_NAME", "wp_example");\ndefine("DB_USER", "siteuser");\n' >"$site/wp-config.php"
printf '<?php $wp_version = "6.6.2";\n' >"$site/wp-includes/version.php"
printf '%s\n' "$site" >"$work/sites.txt"

# All output goes into the test working directory: a test run must not create
# files in the repository root. --lock-file is also supplied, so concurrent test
# runs do not fight over one lock.
LOGS=(--log-file "$work/manager.log" --error-log-file "$work/errors.log" --lock-file "$work/lock")
run() { # extra args...
    WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" \
        --sites "$work/sites.txt" --allow-root never --color never "${LOGS[@]}" "$@"
}
: >"$work/argv.log"

say 'help, version, modes'
expect_rc 0 'help exits 0' direct --help
expect_rc 0 'version exits 0' direct --version
expect_rc 0 'list-modes exits 0' direct --list-modes
expect_rc 2 'no mode exits 2' direct
expect_rc 2 'unknown option exits 2' direct --nonsense
expect_rc 2 'plugin-manage without action exits 2' direct --plugin-manage --name x
expect_rc 2 'conflicting modes exit 2' direct --full --core
expect_rc 2 'bad action exits 2' direct -m -A frobnicate -N x
expect_rc 2 'bad format exits 2' direct -l --format yaml

say 'plugin listing: table, json, csv, tsv'
# JSON is validated with Node rather than Python: the Python launcher on this host
# receives the MSYS path '/tmp/...' and cannot open it, while Node resolves it.
check_json() { # FILE ASSERTION_JS DESCRIPTION
    node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));$2" "$1" \
        2>/dev/null && ok "$3" || bad "$3"
}
out="$(run --list-plugins --format json 2>/dev/null)"
if printf '%s' "$out" | grep -q '"slug":"woocommerce"'; then ok 'json contains woocommerce'; else bad 'json output'; printf '%s\n' "$out"; fi
printf '%s' "$out" >"$work/out.json"
check_json "$work/out.json" "if(d.length!==3)throw 'rows '+d.length;if(d[1].update!=='available')throw 'update flag';" 'json parses, 3 rows, update flag correct'
out="$(run --list-plugins --format csv 2>/dev/null)"
if printf '%s' "$out" | python -c "import csv,sys; r=list(csv.reader(sys.stdin)); assert r[0]==['name','status','version','update','slug','title'], r[0]; assert len(r)==4, len(r); print('  PASS  csv parses, header and 3 rows')"; then :; else bad 'csv parse'; fi
out="$(run --list-plugins --format tsv 2>/dev/null)"
if [ "$(printf '%s' "$out" | grep -c '')" -eq 3 ]; then ok 'tsv has 3 rows'; else bad "tsv rows: $(printf '%s' "$out" | grep -c '')"; fi
out="$(run --list-plugins 2>/dev/null)"
if printf '%s' "$out" | grep -q 'WooCommerce'; then ok 'table mentions WooCommerce'; else bad 'table output'; printf '%s\n' "$out"; fi

say 'filter'
out="$(run --list-plugins --format json --name woo 2>/dev/null)"
printf '%s' "$out" >"$work/out2.json"
check_json "$work/out2.json" "if(d.length!==1)throw 'rows '+d.length;if(d[0].slug!=='woocommerce')throw 'slug';" 'filter --name woo selects exactly one row'
out="$(run --list-plugins --format json --name 'woo") | .[] | select(true) | .["' 2>/dev/null)"
printf '%s' "$out" >"$work/out3.json"
check_json "$work/out3.json" "if(d.length!==0)throw 'rows '+d.length;" 'jq-style metacharacters in --name are inert, empty result'

say 'command construction: no injection, no word splitting'
[ -f /tmp/INJECTED_zz ] && rm -f /tmp/INJECTED_zz
inj='zz"; touch /tmp/INJECTED_zz; echo "'
: >"$work/argv.log"
run --plugin-manage -A deactivate -N "$inj" --yes --site "$site" >/dev/null 2>&1
if [ -f /tmp/INJECTED_zz ]; then bad 'injection: file was created'; rm -f /tmp/INJECTED_zz; else ok 'injection attempt created no file'; fi

say 'plugin manage: selection and argv'
# The fake reports Akismet as active and WooCommerce as inactive, so the actions
# below are the ones that actually reach wp.
: >"$work/argv.log"
run --plugin-manage -A deactivate -N 'Akismet Anti-Spam' --yes --site "$site" >/dev/null 2>&1
if grep -Fqx 'argv[plugin]' "$work/argv.log" && grep -Fqx 'argv[deactivate]' "$work/argv.log"; then ok 'subcommand arguments are separate'; else bad 'argv shape'; cat "$work/argv.log"; fi
if grep -Fqx 'argv[akismet]' "$work/argv.log"; then ok 'the slug, not the display name, is passed to wp'; else bad 'slug not used'; cat "$work/argv.log"; fi
if grep -Fq 'argv[--skip-plugins=saphali-woocommerce-lite' "$work/argv.log"; then bad 'a manage call got --skip-plugins'; else ok 'no --skip-plugins on a manage call'; fi

: >"$work/argv.log"
run --plugin-manage -A activate -N 'woo' --yes --site "$site" >/dev/null 2>&1
if grep -Fqx 'argv[activate]' "$work/argv.log" && grep -Fqx 'argv[woocommerce]' "$work/argv.log"; then ok 'a unique partial name selects and acts on the plugin'; else bad 'partial name selection'; cat "$work/argv.log"; fi

: >"$work/argv.log"
run --plugin-manage -A activate -N 'o' --yes --site "$site" >/dev/null 2>&1
if grep -Fqx 'argv[activate]' "$work/argv.log"; then bad 'an ambiguous name performed an action'; else ok 'an ambiguous name performs nothing'; fi

: >"$work/argv.log"
run --plugin-manage -A activate -N 'Akismet Anti-Spam' --yes --site "$site" >/dev/null 2>&1
if grep -Fqx 'argv[activate]' "$work/argv.log"; then bad 'an already active plugin was activated again'; else ok 'an already active plugin is left alone'; fi

# A name with a space must survive as one argument when it is passed to wp.
: >"$work/argv.log"
run --plugin-manage -A deactivate -N 'Akismet Anti-Spam' --yes --site "$site" >/dev/null 2>&1
if grep -Fq 'argv[Akismet Anti-Spam]' "$work/argv.log"; then bad 'the display name reached wp instead of the slug'; else ok 'no display name with a space is passed to wp'; fi

say 'environment handed to wp'
if grep -q 'env HOMEDIR=' "$work/argv.log" && grep -q 'DOCUMENT_ROOT=' "$work/argv.log"; then
    if grep -q 'HOMEDIR=$' "$work/argv.log"; then bad 'HOMEDIR exported empty'; else ok 'HOMEDIR and DOCUMENT_ROOT exported'; fi
else bad 'environment not exported'; fi

say 'skip-plugins policy'
: >"$work/argv.log"
run --plugins --site "$site" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=saphali' "$work/argv.log"; then ok 'update call receives --skip-plugins'; else bad 'update call lost --skip-plugins'; cat "$work/argv.log"; fi
: >"$work/argv.log"
run --list-plugins --format json --site "$site" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=' "$work/argv.log"; then bad 'list call receives --skip-plugins by default'; else ok 'list call does not receive --skip-plugins by default'; fi
: >"$work/argv.log"
run --list-plugins --format json --skip-plugins-for-listing on --site "$site" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=' "$work/argv.log"; then ok 'listing honours --skip-plugins-for-listing on'; else bad 'listing ignored the on switch'; fi

say 'quiet and allow-root'
: >"$work/argv.log"
run --plugins --site "$site" >/dev/null 2>&1
if grep -Fqx 'argv[--quiet]' "$work/argv.log"; then bad 'legacy unconditional --quiet is still passed'; else ok 'no unconditional --quiet'; fi
if grep -Fqx 'argv[--allow-root]' "$work/argv.log"; then bad '--allow-root passed although --allow-root never was requested'; else ok '--allow-root suppressed by policy'; fi

say 'dry run'
: >"$work/argv.log"
run --db-optimize --dry-run --site "$site" >/dev/null 2>&1
if [ -s "$work/argv.log" ]; then bad 'dry run executed wp'; cat "$work/argv.log"; else ok 'dry run executed nothing'; fi

say 'exit codes'
expect_rc 0 'plugins mode exits 0' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" --plugins --site "$site" --color never "${LOGS[@]}"
expect_rc 1 'nonexistent --site exits 1' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" --plugins --site /no/such/site --color never "${LOGS[@]}"
expect_rc 3 'missing wp binary exits 3' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp /no/such/wp --sites "$work/sites.txt" --plugins --site "$site" --color never "${LOGS[@]}"
expect_rc 0 'check on a good site exits 0' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" --check --site "$site" --color never "${LOGS[@]}"

say 'site list handling'
: >"$work/mixed.txt"
printf '# comment\r\n\n   \r\n%s\r\n' "$site" >>"$work/mixed.txt"
expect_rc 0 'CRLF list with comments works' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/mixed.txt" --plugins --color never "${LOGS[@]}"
: >"$work/empty.txt"
expect_rc 1 'empty list exits 1' env WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/empty.txt" --plugins --color never "${LOGS[@]}"

say 'no colour when redirected, colour fields never leak into data'
out="$(run --list-plugins --format json 2>/dev/null)"
if printf '%s' "$out" | grep -q $'\033'; then bad 'ANSI escape in JSON output'; else ok 'no ANSI escape in JSON output'; fi
out="$(direct --help 2>&1)"
if printf '%s' "$out" | grep -q $'\033'; then bad 'ANSI escape in --help when not a terminal'; else ok 'no ANSI escape in --help when redirected'; fi

say 'logging'
: >"$work/argv.log"
run --plugins --site "$site" --debug >/dev/null 2>&1
log="$work/manager.log"
if [ -f "$log" ]; then
    if grep -q $'\033' "$log"; then bad 'ANSI escape written into the log file'; else ok 'log file is plain text'; fi
    if grep -q 'exec: ' "$log"; then ok 'debug log records the executed command'; else bad 'debug log has no command record'; fi
    if grep -q 'SUMMARY' "$log"; then bad 'the console summary leaked into the log file'; else ok 'the console summary stays out of the log file'; fi
else bad "log file was not created at $log"; fi

say 'licence handling: value never written to a log or to argv'
testkey='NOT-A-REAL-KEY-0123456789'
logf="$work/manager.log"
errf="$work/errors.log"
: >"$logf" 2>/dev/null || true
: >"$errf" 2>/dev/null || true
: >"$work/argv.log"
env WP_ARGV_LOG="$work/argv.log" WP_CLI_UPDATE_LICENCE="$testkey" bash "$script" \
    --wp "$work/bin/wp" --sites "$work/sites.txt" --astra --site "$site" \
    --allow-root never --color never --debug "${LOGS[@]}" >/dev/null 2>&1
if grep -q "$testkey" "$work/argv.log" 2>/dev/null; then bad 'licence appears in the recorded argv'; else ok 'licence absent from the argv handed to wp'; fi
if [ -f "$logf" ] && grep -q "$testkey" "$logf"; then bad 'licence appears in the log file'; else ok 'licence absent from the log file'; fi
if [ -f "$errf" ] && grep -q "$testkey" "$errf"; then bad 'licence appears in the error log'; else ok 'licence absent from the error log'; fi
if grep -Fq 'WP_CLI_LICENCE' "$work/argv.log" 2>/dev/null; then bad 'the environment was not expanded for the licence'; else ok 'licence expanded inside the child shell'; fi

say 'configuration: precedence and safety'
cat >"$work/conf-safe.conf" <<CONF
LOG_LEVEL=warning
PLUGIN_SKIP_LIST=only-this-one
CONF
: >"$work/argv.log"
WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" \
    --config "$work/conf-safe.conf" --plugins --site "$site" \
    --allow-root never --color never "${LOGS[@]}" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=only-this-one]' "$work/argv.log"; then ok 'a safe config file is applied'; else bad 'config file ignored'; cat "$work/argv.log"; fi

cat >"$work/conf-unsafe.conf" <<'CONF'
PLUGIN_SKIP_LIST=safe-one
LOG_LEVEL=$(touch /tmp/CONF_INJECTED)`touch /tmp/CONF_INJECTED2`
CONF
[ -f /tmp/CONF_INJECTED ] && rm -f /tmp/CONF_INJECTED
[ -f /tmp/CONF_INJECTED2 ] && rm -f /tmp/CONF_INJECTED2
: >"$work/argv.log"
WP_ARGV_LOG="$work/argv.log" bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" \
    --config "$work/conf-unsafe.conf" --plugins --site "$site" \
    --allow-root never --color never "${LOGS[@]}" >/dev/null 2>&1
if [ -f /tmp/CONF_INJECTED ] || [ -f /tmp/CONF_INJECTED2 ]; then bad 'a config file was executed'; rm -f /tmp/CONF_INJECTED /tmp/CONF_INJECTED2; else ok 'a shell-metacharacter config is refused, not executed'; fi
if grep -Fq 'argv[--skip-plugins=safe-one]' "$work/argv.log"; then bad 'an unsafe config was partly applied'; else ok 'nothing from an unsafe config is applied'; fi

: >"$work/argv.log"
WP_ARGV_LOG="$work/argv.log" WP_CLI_UPDATE_PLUGIN_SKIP_LIST=from-environment bash "$script" \
    --wp "$work/bin/wp" --sites "$work/sites.txt" --config "$work/conf-safe.conf" \
    --plugins --site "$site" --allow-root never --color never "${LOGS[@]}" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=from-environment]' "$work/argv.log"; then ok 'environment overrides the config file'; else bad 'environment did not win'; cat "$work/argv.log"; fi

: >"$work/argv.log"
WP_ARGV_LOG="$work/argv.log" WP_CLI_UPDATE_PLUGIN_SKIP_LIST=from-environment bash "$script" \
    --wp "$work/bin/wp" --sites "$work/sites.txt" --plugins --site "$site" \
    --allow-root never --color never --skip-plugins from-cli "${LOGS[@]}" >/dev/null 2>&1
if grep -Fq 'argv[--skip-plugins=from-cli]' "$work/argv.log"; then ok 'the command line overrides the environment'; else bad 'CLI did not win'; cat "$work/argv.log"; fi

say 'concurrent runs are refused'
# A run that holds the lock must make a second, overlapping run fail fast.
lockf="$work/conc.lock"
slowlog=(--log-file "$work/slow.log" --error-log-file "$work/slowerr.log")
cat >"$work/slow-wp" <<'SLOW'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'plugin list') printf '[]\n' ;;
  *) sleep 4; printf 'Success: done\n' ;;
esac
SLOW
chmod +x "$work/slow-wp"
( bash "$script" --wp "$work/slow-wp" --sites "$work/sites.txt" --plugins --site "$site" \
    --allow-root never --color never "${slowlog[@]}" --lock-file "$lockf" >/dev/null 2>&1 ) &
bg=$!
sleep 1
bash "$script" --wp "$work/bin/wp" --sites "$work/sites.txt" --plugins --site "$site" \
    --allow-root never --color never "${LOGS[@]}" --lock-file "$lockf" >/dev/null 2>&1
second=$?
wait "$bg" 2>/dev/null || true
if [ "$second" -eq 3 ]; then ok 'the second concurrent run exits 3'; else bad "second concurrent run exited $second, expected 3"; fi
rm -f "$lockf"

printf '\n=== %s ===\n' "$([ "$(count_fails)" -eq 0 ] && echo 'ALL SMOKE CHECKS PASSED' || echo "$(count_fails) CHECK(S) FAILED")"
test "$(count_fails)" -eq 0
