#!/usr/bin/env bash
# ==============================================================================
# Scenario tests for Find_WP_Senior.sh (v2.0.0)
#
# Run: bash tests/scenarios/test_discovery.sh <project_dir>
# Arguments:
#   $1 - absolute POSIX path of the project directory.
#
# Each scenario sets up a synthetic WordPress tree under a private tmpdir and
# asserts the observed behaviour of the discovery script. The harness collects
# failures and exits non-zero when any assertion failed.
# ==============================================================================

PROJ="${1:?usage: test_discovery.sh <project_dir>}"
SCRIPT="${PROJ}/Find_WP_Senior.sh"

TOTAL=0
FAILED=0

pass() { TOTAL=$(( TOTAL + 1 )); printf 'PASS: %s\n' "$*"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL: %s\n' "$*" >&2; }

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${msg}"
    else
        fail "${msg} (expected='${expected}' actual='${actual}')"
    fi
}

assert_contains() {
    local file="$1" needle="$2" msg="$3"
    if grep -Fq -- "${needle}" "${file}"; then
        pass "${msg}"
    else
        fail "${msg} ('${needle}' not found in ${file})"
    fi
}

assert_not_contains() {
    local file="$1" needle="$2" msg="$3"
    if ! grep -Fq -- "${needle}" "${file}"; then
        pass "${msg}"
    else
        fail "${msg} ('${needle}' unexpectedly present in ${file})"
    fi
}

# mk_wp <dir>: create a minimal valid WordPress root.
mk_wp() {
    mkdir -p "$1/wp-includes"
    printf '%s\n' '<?php' > "$1/wp-config.php"
    printf '%s\n' '<?php\n$wp_version = "6.7";' > "$1/wp-includes/version.php"
}

T="$(mktemp -d /tmp/findwp_test.XXXXXX)"
cleanup_fixture() { rm -rf "${T}"; }
trap cleanup_fixture EXIT

ROOT="${T}/webroot"
mkdir -p "${ROOT}"

# ------------------------------------------------------------------------------
# Scenario 1: discovery finds valid WP roots only.
# Build tree:
#   webroot/
#     siteA/            valid
#     sub/siteB/        valid (nested)
#     node_modules/x/   valid-but-must-be-pruned
#     space dir/site C/ valid, path contains spaces
#     deep/1/2/3/4/5/6/siteD/  valid but beyond --max-depth 6 (depth 7)
# ------------------------------------------------------------------------------
mk_wp "${ROOT}/siteA"
mk_wp "${ROOT}/sub/siteB"
mk_wp "${ROOT}/node_modules/x"
mk_wp "${ROOT}/space dir/site C"
mkdir -p "${ROOT}/deep/1/2/3/4/5/6"
mk_wp "${ROOT}/deep/1/2/3/4/5/6/siteD"
printf '%s\n' 'not a config' > "${ROOT}/random.txt"

# A valid site that is excluded by absolute path.
mk_wp "${ROOT}/siteX"

OUT1="${T}/out1.txt"
"${SCRIPT}" --no-defaults --quiet --max-depth 6 \
    --exclude '*/node_modules' --exclude "${ROOT}/siteX" \
    -o "${OUT1}" "${ROOT}"
RC=$?
assert_eq 0 "${RC}" "scenario1: discovery exits 0"
if [[ -f "${OUT1}" ]]; then
    assert_eq 3 "$(wc -l < "${OUT1}")" "scenario1: exactly 3 sites discovered"
    assert_contains "${OUT1}" "${ROOT}/siteA" "scenario1: siteA found"
    assert_contains "${OUT1}" "${ROOT}/sub/siteB" "scenario1: nested siteB found"
    assert_contains "${OUT1}" "${ROOT}/space dir/site C" "scenario1: spaced site found"
    assert_not_contains "${OUT1}" "node_modules" "scenario1: node_modules pruned"
    assert_not_contains "${OUT1}" "siteX" "scenario1: absolute exclude honored"
    assert_not_contains "${OUT1}" "siteD" "scenario1: max depth honored"
    assert_not_contains "${OUT1}" "random.txt" "scenario1: non wp-config files not printed"
else
    fail "scenario1: output file not created"
fi

# ------------------------------------------------------------------------------
# Scenario 2: glob --exclude patterns
# ------------------------------------------------------------------------------
OUT2="${T}/out2.txt"
"${SCRIPT}" --no-defaults --quiet --max-depth 12 -o "${OUT2}" --exclude '*/space*' "${ROOT}"
RC=$?
assert_eq 0 "${RC}" "scenario2: exits 0"
if [[ -f "${OUT2}" ]]; then
    assert_not_contains "${OUT2}" "space dir" "scenario2: glob exclusion works"
    assert_contains "${OUT2}" "deep/1/2/3/4/5/6/siteD" "scenario2: deep site visible within default depth"
else
    fail "scenario2: output file not created"
fi

# ------------------------------------------------------------------------------
# Scenario 3: default output goes NEXT TO THE SCRIPT, not to CWD
# ------------------------------------------------------------------------------
PREV="${PROJ}/wp-found.txt"
[[ -f "${PREV}" ]] && mv "${PREV}" "${PREV}.bak"
( cd "${T}" && "${SCRIPT}" --no-defaults --quiet "${ROOT}/siteA" >/dev/null 2>&1 )
RC=$?
assert_eq 0 "${RC}" "scenario3: run from another CWD exits 0"
if [[ -f "${PROJ}/wp-found.txt" ]]; then
    pass "scenario3: output created next to script"
else
    fail "scenario3: output NOT next to script"
fi
if [[ -f "${T}/wp-found.txt" ]]; then
    fail "scenario3: output leaked into CWD"
else
    pass "scenario3: nothing written into CWD"
fi
rm -f "${PROJ}/wp-found.txt"
[[ -f "${PREV}.bak" ]] && mv "${PREV}.bak" "${PREV}"

# ------------------------------------------------------------------------------
# Scenario 4: CLI surface
# ------------------------------------------------------------------------------
VEROUT="$("${SCRIPT}" --version)"
assert_eq "Find_WP_Senior.sh v2.0.0" "${VEROUT}" "scenario4: --version prints name and version"

"${SCRIPT}" --help > "${T}/help.txt" 2>&1
assert_eq 0 "$?" "scenario4: --help exits 0"
assert_contains "${T}/help.txt" "--max-depth" "scenario4: help documents --max-depth"
assert_contains "${T}/help.txt" "--no-defaults" "scenario4: help documents --no-defaults"

"${SCRIPT}" --definitely-unknown >/dev/null 2>&1
assert_eq 1 "$?" "scenario4: unknown option exits 1"

"${SCRIPT}" --no-defaults --output >/dev/null 2>&1
assert_eq 1 "$?" "scenario4: --output without value exits 1"

# ------------------------------------------------------------------------------
# Scenario 5: no findings -> empty output file, exit 0
# ------------------------------------------------------------------------------
EMPTY="${T}/emptyroot"
mkdir -p "${EMPTY}"
touch "${EMPTY}/file.txt"
OUT5="${T}/out5.txt"
"${SCRIPT}" --no-defaults --quiet -o "${OUT5}" "${EMPTY}"
RC=$?
assert_eq 0 "${RC}" "scenario5: empty scan exits 0"
if [[ -f "${OUT5}" && ! -s "${OUT5}" ]]; then
    pass "scenario5: empty output file created"
else
    fail "scenario5: output missing or not empty"
fi

# ------------------------------------------------------------------------------
# Scenario 6: nonexistent search root is skipped with a warning, exit 0
# ------------------------------------------------------------------------------
OUT6="${T}/out6.txt"
"${SCRIPT}" --no-defaults -o "${OUT6}" "${T}/does-not-exist" "${ROOT}/siteA" >/dev/null 2>&1
RC=$?
assert_eq 0 "${RC}" "scenario6: missing root tolerated"
if [[ -f "${OUT6}" ]]; then
    assert_eq 1 "$(wc -l < "${OUT6}")" "scenario6: valid root still scanned"
else
    fail "scenario6: output file not created"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf '\n%d assertions, %d failed\n' "${TOTAL}" "${FAILED}"
[[ "${FAILED}" -eq 0 ]]
