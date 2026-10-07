#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Tests for tools/scan-secrets.sh.
#
# A secret scanner that is only ever run against a clean tree proves nothing, so
# every check here plants a value first and then asserts that the guard sees it,
# masks it by default, and exits non-zero under --strict.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-guard.XXXXXX")"
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

GUARD="${repo}/tools/scan-secrets.sh"
if [ ! -f "$GUARD" ]; then
    bad 'tools/scan-secrets.sh is missing' ''
    report 'secret-guard'
    exit 1
fi

# Invented values. They look like credentials, they mean nothing, and they are
# deleted with the working directory at the end of this file.
SECRET_UUID='9f3c2a11-77bb-44dd-99aa-1122334455ff'
SECRET_TOKEN='ghp_16C7e42F292c6912E7710c838347Ae178B4a'
SECRET_PASSWORD='Tr0ub4dor-and-3-slam-dunk'
SECRET_AWS='wJalrXUtnFEMI7K7MDENG3bPxRfiCYEXAMPLE'

guard_run() { bash "$GUARD" "$@"; }

say 'the guard is usable'
expect_rc 0 '--help exits 0' guard_run --help
expect_rc 0 '--version exits 0' guard_run --version
expect_rc 2 'an unknown option exits 2' guard_run --nonsense
expect_rc 2 'a bad --min-length exits 2' guard_run --min-length abc
help_txt="${WORK}/help.txt"
guard_run --help >"$help_txt" 2>&1
for opt in --strict --history --show-values --min-length --allowlist --verbose --quiet; do
    if grep -Fq -- "$opt" "$help_txt"; then ok "help documents ${opt}"; else bad "help is missing ${opt}" ''; fi
done
expect_contains "$help_txt" 'not a verdict' 'the help states what the tool cannot prove'

say 'the repository itself is clean'
out="${WORK}/clean.txt"
guard_run --strict >"$out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'no finding in the shipped tree (--strict exits 0)'
else
    bad 'the shipped tree has findings' "$(grep -A2 FINDING "$out" | head -12)"
fi
expect_contains "$out" 'known-benign' 'the summary distinguishes benign hits from findings'
if grep -Fq 'scanned' "$out"; then
    ok 'the summary reports how many files were scanned'
else
    bad 'the summary has no scan count' ''
fi

say 'the allowlist is really consulted'
guard_run --strict --verbose >"${WORK}/verbose.txt" 2>&1
if grep -Fq '[allowlisted]' "${WORK}/verbose.txt" || grep -Fq 'allowlisted' "${WORK}/verbose.txt"; then
    ok '--verbose shows allowlisted lines with their class'
else
    bad 'no allowlisted line was reported' 'is the allowlist read at all?'
fi
empty_allow="${WORK}/empty-allowlist.txt"
: >"$empty_allow"
guard_run --strict --allowlist "$empty_allow" >"${WORK}/noallow.txt" 2>&1
rc=$?
if [ "$rc" = '1' ]; then
    ok 'with an empty allowlist the internal markers become findings (exit 1)'
else
    bad 'an empty allowlist changed nothing' "exit ${rc}; the allowlist may be ignored"
fi
expect_contains "${WORK}/noallow.txt" 'FINDING' 'the un-allowlisted markers are reported as findings'

say 'a planted value in an uncommitted file is found'
plant="${repo}/planted-for-test.conf"
cleanup_plant() { rm -f -- "$plant"; }
trap 'cleanup_plant; rm -rf -- "$WORK"' EXIT

printf 'ASTRA_LICENCE_KEY="%s"\n' "$SECRET_UUID" >"$plant"
guard_run --strict >"${WORK}/p1.txt" 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok '--strict exits 1 on a planted licence key'; else bad '--strict did not fail' "exit ${rc}"; fi
expect_contains "${WORK}/p1.txt" 'planted-for-test.conf' 'the finding names the file'
expect_contains "${WORK}/p1.txt" 'ASTRA_LICENCE_KEY' 'the finding names the variable'
expect_contains "${WORK}/p1.txt" 'length=36' 'the finding reports the value length'
expect_contains "${WORK}/p1.txt" 'fp=' 'the finding reports a fingerprint'
guard_run >"${WORK}/p2.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'without --strict it warns and exits 0'; else bad 'without --strict' "exit ${rc}"; fi

say 'the value stays masked by default'
if grep -Fq "$SECRET_UUID" "${WORK}/p1.txt" "${WORK}/p2.txt" 2>/dev/null; then
    bad 'the value was printed by default' 'a scanner must not become the leak'
else
    ok 'the value is masked by default'
fi
guard_run --show-values >"${WORK}/p3.txt" 2>&1
if grep -Fq "$SECRET_UUID" "${WORK}/p3.txt"; then
    ok '--show-values prints the value when the operator asks for it'
else
    bad '--show-values did not print the value' ''
fi

say 'other credential shapes are found'
for pair in \
    "API_TOKEN|${SECRET_TOKEN}|a provider-prefixed API token" \
    "DB_PASSWORD|${SECRET_PASSWORD}|a database password" \
    "AWS_SECRET_ACCESS_KEY|${SECRET_AWS}|an AWS secret access key" \
    "private_key|${SECRET_UUID}|a lower-case name" \
    "SessionSecret|${SECRET_PASSWORD}|a mixed-case name"
do
    name="${pair%%|*}"
    rest="${pair#*|}"
    value="${rest%%|*}"
    label="${rest#*|}"
    printf '%s="%s"\n' "$name" "$value" >"$plant"
    if guard_run --strict "$plant" >/dev/null 2>&1; then
        bad "not detected: ${name}" "${label}"
    else
        ok "detected: ${label}"
    fi
done

say 'a real value that happens to contain a placeholder word is still found'
# The canonical AWS documentation key ends in "EXAMPLEKEY". A substring rule for
# EXAMPLE classified it as a placeholder and let it through; the rule is anchored
# now, and this check is what keeps it anchored.
printf 'AWS_SECRET_ACCESS_KEY="%s"\n' "$SECRET_AWS" >"$plant"
if guard_run --strict "$plant" >/dev/null 2>&1; then
    bad 'a value ending in EXAMPLEKEY was treated as a placeholder' ''
else
    ok 'a value ending in EXAMPLEKEY is reported'
fi
# A lower-case word inside a passphrase is content, not a template: `example`
# appears in plenty of real passwords. The placeholder rule is therefore
# upper-case and anchored, and this check keeps it that way.
printf 'DB_PASSWORD="Example123-ChangeMe-now"\n' >"$plant"
if guard_run --strict "$plant" >/dev/null 2>&1; then
    bad 'a passphrase that merely contains a template word was missed' ''
else
    ok 'a passphrase containing a template word is still reported'
fi
printf 'DB_PASSWORD="example lowercase passphrase 42"\n' >"$plant"
if guard_run --strict "$plant" >/dev/null 2>&1; then
    bad 'a lower-case passphrase was missed' ''
else
    ok 'a lower-case passphrase is reported'
fi
cleanup_plant

say 'shapes that are not credentials stay quiet'
for pair in \
    "ASTRA_SLUG=astra-addon|a plugin slug is a setting" \
    "WP_CLI_PATH=/usr/local/bin/wp|a path is not a secret" \
    'API_TOKEN="${FROM_THE_ENV}"|an expansion is not a literal' \
    'DB_PASSWORD=YOUR_PASSWORD_HERE|a documented placeholder' \
    'SESSION_TIMEOUT=3600|too short to be a credential' \
    '# ASTRA_KEY=commented-out-value|a comment is documentation'
do
    line="${pair%%|*}"
    label="${pair#*|}"
    printf '%s\n' "$line" >"$plant"
    if guard_run --strict "$plant" >/dev/null 2>&1; then
        ok "quiet: ${label}"
    else
        bad "false positive: ${label}" "$(guard_run "$plant" 2>&1 | grep -A1 FINDING | head -3)"
    fi
done
cleanup_plant

say 'the pattern definitions of the guard are not findings'
# A scanner that reports its own rule table is useless: the operator would have
# to allowlist the tool itself.
guard_run --strict >"${WORK}/self.txt" 2>&1
if grep -Fq 'FINDING   tools/scan-secrets.sh' "${WORK}/self.txt"; then
    bad 'the guard reports its own rule table' "$(grep -F 'FINDING' "${WORK}/self.txt" | head -3)"
else
    ok 'the guard does not report its own rule table'
fi

say '--min-length moves the threshold'
printf 'DB_PASSWORD="abcdefgh"\n' >"$plant"
if guard_run --strict --min-length 4 >/dev/null 2>&1; then
    bad '--min-length 4 let an 8-character value through' ''
else
    ok '--min-length 4 reports an 8-character value'
fi
if guard_run --strict --min-length 20 >/dev/null 2>&1; then
    ok '--min-length 20 ignores the same value'
else
    bad '--min-length 20 still reported it' ''
fi
cleanup_plant

say '--quiet is quiet'
printf 'ASTRA_LICENCE_KEY="%s"\n' "$SECRET_UUID" >"$plant"
q_out="$(guard_run --quiet --strict 2>&1)"
rc=$?
if [ "$rc" = '1' ]; then ok '--quiet still exits 1 under --strict'; else bad '--quiet exit code' "got ${rc}"; fi
if printf '%s' "$q_out" | grep -Fq 'scanning'; then
    bad '--quiet printed the banner' ''
else
    ok '--quiet suppresses the banner'
fi
cleanup_plant

say 'history mode finds a value that was later removed'
if command -v git >/dev/null 2>&1; then
    hist_repo="${WORK}/histrepo"
    mkdir -p "$hist_repo"
    (
        cd "$hist_repo" || exit 1
        git init -q . 2>/dev/null
        git config user.email 'test@example.invalid' 2>/dev/null
        git config user.name 'test' 2>/dev/null
        printf 'ASTRA_LICENCE_KEY="%s"\n' "$SECRET_UUID" >leaked.conf
        git add leaked.conf >/dev/null 2>&1
        git commit -q -m 'oops' >/dev/null 2>&1
        rm -f leaked.conf
        git add -A >/dev/null 2>&1
        git commit -q -m 'removed the value' >/dev/null 2>&1
    )
    if [ -f "${hist_repo}/.git/HEAD" ]; then
        # The guard scans the repository it lives in, so copy it into the fixture.
        mkdir -p "${hist_repo}/tools"
        cp "$GUARD" "${hist_repo}/tools/scan-secrets.sh"
        : >"${hist_repo}/tools/secret-allowlist.txt"
        if [ -f "${hist_repo}/leaked.conf" ]; then
            bad 'the fixture did not remove the value from the work tree' ''
        else
            ok 'the value is gone from the working tree'
        fi
        ( cd "${hist_repo}" && bash tools/scan-secrets.sh --strict ) >"${WORK}/h1.txt" 2>&1
        rc=$?
        if [ "$rc" = '0' ]; then
            ok 'a work-tree scan of the fixture is clean, as expected'
        else
            bad 'the work-tree scan found something it should not' "$(head -4 "${WORK}/h1.txt")"
        fi
        ( cd "${hist_repo}" && bash tools/scan-secrets.sh --history --strict ) >"${WORK}/h2.txt" 2>&1
        rc=$?
        if [ "$rc" = '1' ]; then
            ok '--history finds the value that was committed and later removed'
        else
            bad '--history missed the removed value' "exit ${rc}; $(head -4 "${WORK}/h2.txt")"
        fi
        expect_contains "${WORK}/h2.txt" 'leaked.conf' 'the historical finding names the old file'
    else
        skip 'history mode' 'git could not initialise a fixture repository here'
    fi
else
    skip 'history mode' 'git is not available'
fi

say 'a target argument scans one file or one directory'
printf 'ASTRA_LICENCE_KEY="%s"\n' "$SECRET_UUID" >"${WORK}/one.conf"
guard_run --strict "${WORK}/one.conf" >"${WORK}/t1.txt" 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'a single file argument is scanned'; else bad 'single file argument' "exit ${rc}"; fi
expect_contains "${WORK}/t1.txt" 'one.conf' 'the finding names the file that was passed'
guard_run --strict "${WORK}" >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'a directory argument is scanned recursively'; else bad 'directory argument' "exit ${rc}"; fi
guard_run --strict "${WORK}/does-not-exist" >/dev/null 2>&1
rc=$?
if [ "$rc" = '2' ]; then ok 'a nonexistent target exits 2'; else bad 'nonexistent target' "expected 2, got ${rc}"; fi

report 'secret-guard'
