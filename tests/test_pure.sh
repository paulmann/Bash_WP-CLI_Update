#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091  # the harness path is resolved at run time
# Runs tests/pure_check.sh under the shared counters. The checks themselves need
# no fixture, no stub and no temporary tree: they source the manager modules and
# exercise the pure logic (configuration table, validators, JSON readers,
# redaction, the read-only classification behind --dry-run, the mode and option
# tables).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-pure.XXXXXX")}"
chmod 755 "$WORK" 2>/dev/null
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
REPO="$repo"
export REPO
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"

say 'pure functional checks (sourced modules; no wp, no fixture)'
# shellcheck source=tests/pure_check.sh
. "${here}/pure_check.sh" || true

report test_pure
