#!/usr/bin/env bash
# Pre-commit checks that need no root, no WordPress and no WP-CLI.
#
# Usage: bash tests/run_tests.sh
#
# The suites build a synthetic tree and a stub 'wp' that records its own argv, so
# the exact command line, the parsing and the exit codes are observable.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
rc=0

printf 'repository: %s\n' "$repo"
printf 'bash:       %s\n\n' "${BASH_VERSION:-unknown}"

check_syntax() {
    local f
    for f in "$repo/Bash_WP-CLI_Update.sh" "$repo/Find_WP_Senior.sh" "$here"/test_*.sh; do
        [ -f "$f" ] || continue
        if bash -n "$f" 2>"$tmp"; then
            printf '  syntax ok   %s\n' "${f#"$repo"/}"
        else
            printf '  SYNTAX FAIL %s\n' "${f#"$repo"/}"
            sed 's/^/    /' "$tmp"
            rc=1
        fi
    done
}

check_line_endings() {
    local f cr
    for f in "$repo"/*.sh "$repo"/tests/*.sh; do
        [ -f "$f" ] || continue
        cr="$(tr -cd '\r' <"$f" | wc -c)"
        if [ "$cr" -ne 0 ]; then
            printf '  CRLF FOUND  %s (%s CR bytes)\n' "${f#"$repo"/}" "$cr"
            rc=1
        fi
    done
    printf '  line endings checked (LF only)\n'
}

tmp="$(mktemp "${TMPDIR:-/tmp}/wptest.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

printf '### static checks\n'
check_syntax
check_line_endings
printf '\n'

# The secret guard runs on the real tree and must find nothing. It is the same
# check that caught a false alarm being reported as a live key, so it runs before
# the behavioural suites: a mismatch here invalidates everything after it.
printf '### secret guard (tools/scan-secrets.sh)\n'
if bash "$repo/tools/scan-secrets.sh" --strict --quiet; then
    printf '  guard ok    no credential-shaped value in the tree\n\n'
else
    printf '  GUARD FAILED  see the findings above\n\n'
    rc=1
fi

for t in "$here"/test_*.sh; do
    [ -f "$t" ] || continue
    printf '### %s\n' "$(basename "$t")"
    if bash "$t"; then
        printf '### %s: OK\n\n' "$(basename "$t")"
    else
        printf '### %s: FAILED\n\n' "$(basename "$t")"
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    printf 'ALL CHECKS PASSED\n'
else
    printf 'SOME CHECKS FAILED\n'
fi
exit "$rc"
