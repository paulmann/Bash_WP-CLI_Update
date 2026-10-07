#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Regression tests for the contract of the ORIGINAL scripts (main @ 8c720e6).
#
# These are the checks a rewrite breaks most easily, and that the four 2026
# revisions did break:
#   - v5 dropped the --list-plugins and --plugin-manage modes entirely;
#   - v5 dropped the .no_wp_cli opt-out marker, so opted-out sites got updated;
#   - ragraf expanded an empty array with "${arr[@]:-}" and scanned all of "/"
#     in addition to the root it was given, adding unrelated sites to the list;
#   - deepseek built the child command with `printf %q` and handed it to
#     `su -c`, which is dash on Debian: every single site failed;
#   - main itself exits 1 from Find_WP_Senior.sh --help and starts scanning
#     the filesystem instead of printing help.
#
# If you rewrite these scripts again, run this file first and last.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-contract.XXXXXX")"
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

M="$MANAGER"
F="$FINDER"

say 'every mode of the original manager still exists'
# The ten modes of main @ 8c720e6, plus their short forms.
MODES=(
    '--full:-f' '--core:-c' '--plugins:-p' '--themes:-t'
    '--db-optimize:-d' '--db-fix:-x' '--cron:-r' '--astra:-s'
    '--list-plugins:-l' '--plugin-manage:-m'
)
help_out="${WORK}/help.txt"
bash "$M" --help >"$help_out" 2>&1
for entry in "${MODES[@]}"; do
    long="${entry%%:*}"
    short="${entry##*:}"
    if grep -Fq -- "$long" "$help_out"; then
        ok "mode documented: ${long}"
    else
        bad "mode missing from --help: ${long}" 'a rewrite dropped a public mode'
    fi
    if grep -Fq -- "$short" "$help_out"; then
        ok "short form documented: ${short}"
    else
        bad "short form missing: ${short}" ''
    fi
done
# --list-modes is the machine-readable contract used by shell completion
modes_out="$(bash "$M" --list-modes 2>/dev/null)"
for entry in "${MODES[@]}"; do
    long="${entry%%:*}"
    name="${long#--}"
    if printf '%s\n' "$modes_out" | grep -Fxq "$name"; then
        ok "--list-modes contains ${name}"
    else
        bad "--list-modes is missing ${name}" "$(printf '%s' "$modes_out" | tr '\n' ' ')"
    fi
done

say 'the documented option surface of the original manager'
for opt in --site --action --name --force --json --skip-plugins --debug --help; do
    if grep -Fq -- "$opt" "$help_out"; then
        ok "option documented: ${opt}"
    else
        bad "option missing from --help: ${opt}" ''
    fi
done
for opt in -S -A -N -F -J -D -h; do
    if grep -Fq -- "$opt" "$help_out"; then
        ok "short option documented: ${opt}"
    else
        bad "short option missing: ${opt}" ''
    fi
done

say 'the finder accepts the original options'
fhelp="${WORK}/fhelp.txt"
bash "$F" --help >"$fhelp" 2>&1
for opt in --output --exclude --help; do
    if grep -Fq -- "$opt" "$fhelp"; then
        ok "finder option documented: ${opt}"
    else
        bad "finder option missing: ${opt}" ''
    fi
done

say 'exit-code contract'
expect_rc 0 'manager --help exits 0' bash "$M" --help
expect_rc 0 'manager --version exits 0' bash "$M" --version
expect_rc 2 'manager with no mode exits 2' bash "$M"
expect_rc 2 'manager with an unknown option exits 2' bash "$M" --nonsense
expect_rc 2 'manager with conflicting modes exits 2' bash "$M" --full --core
expect_rc 0 'finder --help exits 0' bash "$F" --help
expect_rc 0 'finder --version exits 0' bash "$F" --version
expect_rc 2 'finder with an unknown option exits 2' bash "$F" --nonsense
expect_rc 2 'finder with a bad --format exits 2' bash "$F" --format yaml /srv
expect_rc 2 'finder with a bad --depth exits 2' bash "$F" --depth 0 /srv

say 'the finder never scans more than it was asked to'
# This is the ragraf defect: `--output FILE /some/root` also scanned `/`.
scope_root="${WORK}/scope"
make_site "${scope_root}/in-scope"
other_root="${WORK}/other"
make_site "${other_root}/out-of-scope"
out="${WORK}/scope.txt"
log="${WORK}/scope.log"
finder_run --output "$out" "$scope_root" >"$log" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'scoped scan exits 0'
else
    bad 'scoped scan exit code' "expected 0, got ${rc}"
fi
expect_lines "$out" 1 'the list holds exactly the in-scope site'
expect_contains "$out" "${scope_root}/in-scope" 'in-scope site is listed'
if grep -Fq 'out-of-scope' "$out"; then
    bad 'scope leak' 'a site outside the requested root ended up in the list'
else
    ok 'no site from another root leaked into the list'
fi
# Anchored: `scanning: /srv/x` contains the substring `scanning: /`.
if grep -Eq 'scanning: /$' "$log"; then
    bad 'the finder scanned the filesystem root' "$(grep -F 'scanning:' "$log")"
else
    ok 'the filesystem root was not scanned'
fi
# ...and the same with the default roots: still no "/"
log2="${WORK}/default.log"
finder_run --output "$out" >"$log2" 2>&1 || true
if grep -Eq 'scanning: /$' "$log2"; then
    bad 'default roots include /' "$(grep -F 'scanning:' "$log2" | head -3)"
else
    ok 'default roots do not include /'
fi

say 'the opt-out marker is honoured'
list="${WORK}/optout.txt"
finder_run --output "$list" "$SITE_ROOT" >/dev/null 2>&1 || true
if grep -Fq "$SITES_OPTOUT" "$list" 2>/dev/null; then
    bad '.no_wp_cli ignored' "${SITES_OPTOUT} was listed although it opted out"
else
    ok 'a site with .no_wp_cli is not listed'
fi
if grep -Fq "$SITES_NOTWP" "$list" 2>/dev/null; then
    bad 'a plain HTML directory was reported as WordPress' "$SITES_NOTWP"
else
    ok 'a directory without wp-config.php is not listed'
fi
for s in "$SITES" "$SITES2" "$SITES_SPACE"; do
    if grep -Fxq "$s" "$list" 2>/dev/null; then
        ok "listed: ${s##*/}"
    else
        bad "not listed: ${s##*/}" "$(cat "$list" 2>/dev/null | tr '\n' ' ')"
    fi
done

say 'a path with a space survives the whole pipeline'
space_list="${WORK}/space.txt"
printf '%s\n' "$SITES_SPACE" >"$space_list"
argv_log_reset
if [ -n "$SU_USER" ]; then
    manager_run --plugins --sites "$space_list" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = '0' ]; then ok "run on 'with space' exits 0"; else bad "run on 'with space'" "exit ${rc}"; fi
    if [ "$(argv_count 'plugin')" -ge 1 ]; then
        ok "wp was invoked for 'with space'"
    else
        bad "wp was never invoked for 'with space'" 'a space in the path broke the command'
    fi
    if grep -Fq -- "--path=${SITES_SPACE}" "$ARGV_LOG" 2>/dev/null; then
        ok 'the path arrived as one --path argument'
    else
        bad 'the path was split' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
    fi
else
    skip "run on 'with space'" 'no switchable test user available'
fi

say 'the child command works when /bin/sh is not bash'
# The deepseek defect: `printf %q` emits bash syntax, `su -c` runs it with the
# target user's shell, and /bin/sh is dash on Debian. Reproduce the shape of the
# failure without depending on the scripts: build the same way and compare.
if [ -x /bin/sh ]; then
    probe="${WORK}/probe.txt"
    if /bin/sh -c 'cd -- "$1" || exit 127; shift; exec "$@"' sh "$WORK" \
            /bin/sh -c 'printf ok > "$1"' x "$probe" 2>/dev/null; then
        ok 'the positional-parameter runner works under /bin/sh'
    else
        bad 'the positional-parameter runner failed under /bin/sh' ''
    fi
    if grep -Fq ok "$probe" 2>/dev/null; then
        ok 'the runner executed the program it was given'
    else
        bad 'the runner did not execute the program' ''
    fi
    # Look at code only: both scripts document the banned patterns in prose.
    code_of() { grep -vE '^\s*#' "$1" | sed -E 's/[[:space:]]#.*$//'; }
    code_of "$MANAGER" >"${WORK}/manager.code"
    code_of "$FINDER" >"${WORK}/finder.code"
    if grep -qE "printf +'%q'" "${WORK}/manager.code" "${WORK}/finder.code"; then
        bad 'a product script uses printf %q' 'that output is not valid POSIX sh'
    else
        ok 'no printf %q in the product scripts'
    fi
    if grep -qE 'su +-[a-zA-Z]*c' "${WORK}/manager.code"; then
        bad 'the manager calls su -c without -s' 'the shell would be the site owner login shell'
    else
        ok 'no bare `su -c` in the manager'
    fi
else
    skip '/bin/sh runner probe' '/bin/sh not present'
fi

say 'the environment contract of the original scripts is preserved'
# main exported DOCUMENT_URI, DOCUMENT_ROOT, HOMEDIR and HTTP_HOST for every
# wp call; plugins in the wild read them, so dropping them is a regression.
if [ -n "$SU_USER" ]; then
    argv_log_reset
    manager_run --plugins --sites "$space_list" >/dev/null 2>&1
    for v in DOCUMENT_ROOT HTTP_HOST HOMEDIR DOCUMENT_URI; do
        if grep -Fq "${v}=" "$ARGV_LOG" 2>/dev/null ||
           grep -Fq "${v}=<unset>" "$ARGV_LOG" 2>/dev/null; then
            if grep -Fq "${v}=<unset>" "$ARGV_LOG" 2>/dev/null; then
                bad "${v} did not reach the wp process" ''
            else
                ok "${v} reached the wp process"
            fi
        else
            bad "${v} is not part of the child environment" ''
        fi
    done
else
    skip 'environment contract' 'no switchable test user available'
fi

say 'the manager works from a site list with CRLF and comments'
crlf="${WORK}/crlf.txt"
printf '%s\r\n# a comment\r\n\r\n%s\r\n' "$SITES" "$SITES2" >"$crlf"
argv_log_reset
if [ -n "$SU_USER" ]; then
    manager_run --plugins --sites "$crlf" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = '0' ]; then ok 'a CRLF list exits 0'; else bad 'a CRLF list' "exit ${rc}"; fi
    if [ "$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)" = '2' ]; then
        ok 'both entries of the CRLF list were processed'
    else
        bad 'CRLF list processing' "$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null) invocation(s), expected 2"
    fi
else
    skip 'CRLF site list' 'no switchable test user available'
fi

report 'base-contract'
