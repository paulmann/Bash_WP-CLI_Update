#!/usr/bin/env bash
# shellcheck shell=bash
# Shared harness for the Bash WP-CLI Update test suites (v7).
#
# Sourced by tests/test_*.sh. Provides:
#   - counters that live in FILES, not variables, so a check that runs in a
#     pipeline or a subshell still counts (the classic bash testing bug);
#   - a synthetic WordPress tree with a stub `wp` that records its own argv and
#     can be told to fail, hang, report versions or pretend to be a multisite;
#   - skip handling for the things a portable suite cannot assume: root, a real
#     su/runuser, flock, timeout, curl/wget, gpg, jq, perl.
#
# Nothing here may require root, network access, WordPress or WP-CLI.

# --- counters ----------------------------------------------------------------
say() { printf '\n=== %s ===\n' "$1"; }
ok() { printf '  PASS  %s\n' "$1"; printf 'x\n' >>"$PASS_FILE"; }
bad() {
    printf '  FAIL  %s\n' "$1"
    [ -n "${2:-}" ] && printf '        %s\n' "$2"
    printf 'x\n' >>"$FAIL_FILE"
}
skip() { printf '  SKIP  %s (%s)\n' "$1" "$2"; printf 'x\n' >>"$SKIP_FILE"; }

# `grep -c ''` prints 0 *and* exits 1 for an empty file, so `cmd || printf 0`
# would print "00" and every `[ "$n" -eq 0 ]` downstream would die with
# "integer expression expected". Capture first, then default.
count() {
    local n
    n="$(grep -c '' "$1" 2>/dev/null)"
    n="${n//[^0-9]/}"
    printf '%s' "${n:-0}"
}

expect_rc() { # EXPECTED NAME COMMAND...
    local want="$1" name="$2"
    shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        ok "$name (rc=$got)"
    else
        bad "$name" "expected exit $want, got $got"
    fi
}

expect_contains() { # FILE NEEDLE NAME
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        ok "$3"
    else
        bad "$3" "'$2' not found in $1"
    fi
}

expect_not_contains() { # FILE NEEDLE NAME
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        bad "$3" "'$2' unexpectedly found in $1"
    else
        ok "$3"
    fi
}

expect_lines() { # FILE EXPECTED NAME
    local got
    got="$(grep -c '' "$1" 2>/dev/null)" || got=0
    got="${got//[^0-9]/}"
    if [ "${got:-0}" = "$2" ]; then
        ok "$3 ($got line(s))"
    else
        bad "$3" "expected $2 line(s), got ${got:-0}"
    fi
}

expect_grep_count() { # FILE PATTERN EXPECTED NAME
    local got
    got="$(grep -Ec -- "$2" "$1" 2>/dev/null)" || got=0
    got="${got//[^0-9]/}"
    if [ "${got:-0}" = "$3" ]; then
        ok "$4 ($got)"
    else
        bad "$4" "expected $3 match(es) of /$2/, got ${got:-0}"
    fi
}

# --- environment probes ------------------------------------------------------
HAVE_ROOT=0
[ "$(id -u)" = '0' ] && HAVE_ROOT=1

# A user we can switch to. Without one, the user-switch tests are skipped
# instead of failing: they need a real account, and creating one needs root.
SU_USER=''
if [ "$HAVE_ROOT" = '1' ]; then
    for candidate in "${TEST_SITE_USER:-}" wptest siteuser www-data nobody; do
        [ -n "$candidate" ] || continue
        if id -u "$candidate" >/dev/null 2>&1; then
            shell="$(getent passwd "$candidate" 2>/dev/null | cut -d: -f7)"
            case "$shell" in */nologin | */false) continue ;; esac
            SU_USER="$candidate"
            break
        fi
    done
fi

have_tool() { command -v -- "$1" >/dev/null 2>&1; }

# --- the synthetic tree ------------------------------------------------------
# Created under TMPDIR with mode 0755 on purpose. `mktemp -d` yields 0700, and a
# 0700 root-owned working directory makes every user-switch test fail with
# "Permission denied" before the script under test has done anything wrong.
WORK="${TEST_WORK:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-tests.XXXXXX")" || {
        printf 'FATAL: cannot create a temporary working directory\n' >&2
        exit 3
    }
    chmod 755 "$WORK"
fi
chmod 755 "$WORK" 2>/dev/null

if [ -z "${FAIL_FILE:-}" ] || [ -z "${PASS_FILE:-}" ] || [ -z "${SKIP_FILE:-}" ]; then
    FAIL_FILE="${WORK}/fail"
    PASS_FILE="${WORK}/pass"
    SKIP_FILE="${WORK}/skip"
    : >"$FAIL_FILE"
    : >"$PASS_FILE"
    : >"$SKIP_FILE"
fi

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANAGER="${REPO}/Bash_WP-CLI_Update.sh"
FINDER="${REPO}/Find_WP_Senior.sh"
STUB_DIR="${WORK}/bin"
STUB_WP="${STUB_DIR}/wp"
SITE_ROOT="${WORK}/var/www"
SITES="${SITE_ROOT}/example.com"
SITES2="${SITE_ROOT}/second.org"
SITES_SPACE="${SITE_ROOT}/with space"
SITES_OPTOUT="${SITE_ROOT}/opted-out.com"
SITES_NOTWP="${SITE_ROOT}/plain-html"
# The stub `wp` is executed as the SITE USER, so its log must live where that
# user can write. $WORK itself is root-owned and must stay 0755 (traversable but
# not writable), which is why the log goes under a 1777 directory. Getting this
# wrong does not fail loudly: the stub simply records nothing and every argv
# assertion looks like a product bug.
LOG_DIR="${WORK}/var/log-stub"
ARGV_LOG="${LOG_DIR}/argv.log"
SITE_LIST="${WORK}/sites.txt"
LOG_FILE="${WORK}/manager.log"
ERR_FILE="${WORK}/errors.log"
LOCK_FILE="${WORK}/lock"
STATE_FILE="${WORK}/state.json"
METRICS_FILE="${WORK}/metrics.prom"
WPCLI_VER_FILE="${WORK}/wpcli-version.txt"

make_site() { # DIR [DB_USER] [MARKER]
    local dir="$1" dbuser="${2:-siteuser}" marker="${3:-}"
    mkdir -p "${dir}/wp-includes" "${dir}/wp-content/plugins" "${dir}/wp-content/uploads"
    printf '<?php\ndefine("DB_NAME", "db_%s");\ndefine("DB_USER", "%s");\n' \
        "$(basename -- "$dir" | tr -c 'A-Za-z0-9' '_')" "$dbuser" >"${dir}/wp-config.php"
    # shellcheck disable=SC2016  # literal PHP source: $wp_version must not expand
    printf '<?php\n$wp_version = "6.6.2";\n' >"${dir}/wp-includes/version.php"
    printf '<?php // wp-load\n' >"${dir}/wp-load.php"
    if [ -n "$marker" ]; then : >"${dir}/${marker}"; fi
    chmod 640 "${dir}/wp-config.php" 2>/dev/null
    if [ -n "$SU_USER" ] && [ "$HAVE_ROOT" = '1' ]; then
        chown -R "${SU_USER}:${SU_USER}" "$dir" 2>/dev/null
    fi
    chmod -R a+rX "$dir" 2>/dev/null
}

build_fixture() {
    mkdir -p "$STUB_DIR" "$SITE_ROOT" "$LOG_DIR"
    install -m 755 "${REPO}/tests/stub/wp" "$STUB_WP" 2>/dev/null ||
        cp "${REPO}/tests/stub/wp" "$STUB_WP"
    chmod 755 "$STUB_WP"
    make_site "$SITES"
    make_site "$SITES2"
    make_site "$SITES_SPACE"
    make_site "$SITES_OPTOUT" 'siteuser' '.no_wp_cli'
    mkdir -p "$SITES_NOTWP"
    printf '<html></html>\n' >"${SITES_NOTWP}/index.html"
    printf '%s\n' "$SITES" "$SITES2" >"$SITE_LIST"
    printf '2.11.0\n' >"$WPCLI_VER_FILE"
    chmod 1777 "$LOG_DIR" 2>/dev/null
    if [ -n "$SU_USER" ] && [ "$HAVE_ROOT" = '1' ]; then
        chown -R "${SU_USER}:${SU_USER}" "$LOG_DIR" 2>/dev/null
    fi
    : >"$ARGV_LOG"
    chmod 666 "$ARGV_LOG" 2>/dev/null
}

# manager_run: run the manager against the fixture with a fixed, hermetic set of
# paths so a test run never writes into the repository or fights over a lock.
#
# --user-env FAKE_WP_LOG is load-bearing, not decoration: the manager builds a
# fresh environment for the child, so the stub would not see FAKE_WP_LOG and
# would fall back to its own default log. Passing it through is exactly what the
# option is for, and it exercises the option on every single call.
manager_run() {
    FAKE_WP_LOG="$ARGV_LOG" bash "$MANAGER" \
        --wp "$STUB_WP" \
        --sites "$SITE_LIST" \
        --log-file "$LOG_FILE" \
        --error-log-file "$ERR_FILE" \
        --lock-file "$LOCK_FILE" \
        --color never \
        --user-env FAKE_WP_LOG \
        "$@"
}

finder_run() {
    FAKE_WP_LOG="$ARGV_LOG" bash "$FINDER" --color never "$@"
}

argv_log_reset() {
    : >"$ARGV_LOG" 2>/dev/null || true
    chmod 666 "$ARGV_LOG" 2>/dev/null || true
    if [ -n "$SU_USER" ] && [ "$HAVE_ROOT" = '1' ]; then
        chown "${SU_USER}:${SU_USER}" "$ARGV_LOG" 2>/dev/null || true
    fi
}

argv_count() { grep -Ec -- "$1" "$ARGV_LOG" 2>/dev/null || printf '0'; }

cleanup_work() {
    if [ -z "${TEST_WORK:-}" ] && [ -n "$WORK" ] && [ -d "$WORK" ]; then
        case "$WORK" in
            */wpcli-tests.*) rm -rf -- "$WORK" ;;
        esac
    fi
}

report() { # SUITE_NAME
    local p f s
    p="$(count "$PASS_FILE")"
    f="$(count "$FAIL_FILE")"
    s="$(count "$SKIP_FILE")"
    printf '\n'
    if [ "$f" -eq 0 ]; then
        printf 'ALL CHECKS PASSED: %s passed, %s failed, %s skipped\n' "$p" "$f" "$s"
    else
        printf 'CHECKS FAILED: %s passed, %s failed, %s skipped\n' "$p" "$f" "$s"
    fi
    cleanup_work
    [ "$f" -eq 0 ]
}
