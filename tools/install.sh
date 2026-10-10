#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# install.sh — install Bash WP-CLI Update onto a host.
#
#   sudo bash tools/install.sh                    # defaults below
#   sudo PREFIX=/usr/local/lib/wp-cli-update bash tools/install.sh
#   bash tools/install.sh --dry-run               # show what would happen
#
# Installs:
#   $PREFIX/Bash_WP-CLI_Update.sh, Find_WP_Senior.sh   (0755)
#   $PREFIX/tools/scan-secrets.sh + allowlist          (used by --security)
#   /etc/wp-cli-update.conf                            (0600, never overwritten)
#   $DATADIR, $LOGDIR, $BACKUPDIR                      (created)
#   bash completion for `wp-fleet`                     (when the dir exists)
#
# Idempotent: re-running upgrades the scripts and leaves config, logs, state
# and backups alone.
###############################################################################
set -euo pipefail

PREFIX="${PREFIX:-/opt/wp-cli-update}"
CONFDIR="${CONFDIR:-/etc}"
DATADIR="${DATADIR:-/var/lib/wp-cli-update}"
LOGDIR="${LOGDIR:-/var/log/wp-cli-update}"
BACKUPDIR="${BACKUPDIR:-/var/backups/wp-cli-update}"
COMPLDIR="${COMPLDIR:-/usr/share/bash-completion/completions}"
DRY='false'
[ "${1:-}" = '--dry-run' ] && DRY='true'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="${here}/Bash_WP-CLI_Update.sh"
FINDER="${here}/Find_WP_Senior.sh"

run() {
    if [ "$DRY" = 'true' ]; then
        printf 'would run: %s\n' "$*"
    else
        "$@"
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ] && [ "$DRY" != 'true' ]; then
        printf 'ERROR: install as root (sudo bash tools/install.sh), or use --dry-run to preview\n' >&2
        exit 3
    fi
}

for f in "$MANAGER" "$FINDER"; do
    [ -f "$f" ] || { printf 'ERROR: %s is missing; run tools/build.sh first\n' "$f" >&2; exit 1; }
done
need_root

printf 'Installing Bash WP-CLI Update\n'
printf '  prefix   : %s\n' "$PREFIX"
printf '  config   : %s/wp-cli-update.conf\n' "$CONFDIR"
printf '  data     : %s\n' "$DATADIR"
printf '  logs     : %s\n' "$LOGDIR"
printf '  backups  : %s\n' "$BACKUPDIR"
printf '\n'

run install -d "$PREFIX" "$PREFIX/tools" "$DATADIR" "$LOGDIR" "$BACKUPDIR" "${DATADIR}/prometheus"
run install -m 755 "$MANAGER" "$FINDER" "$PREFIX/"
run install -m 755 "${here}/tools/scan-secrets.sh" "$PREFIX/tools/"
run install -m 644 "${here}/tools/secret-allowlist.txt" "$PREFIX/tools/"

CONF="${CONFDIR}/wp-cli-update.conf"
if [ -e "$CONF" ]; then
    printf 'keeping the existing %s\n' "$CONF"
else
    if [ "$DRY" = 'true' ]; then
        printf 'would create %s (0600) from --init-config\n' "$CONF"
    else
        "$PREFIX/Bash_WP-CLI_Update.sh" --init-config "$CONF"
        # Point the starter config at the FHS locations we just created. A
        # generated file is data; adjusting three paths in it is configuration,
        # not code, and it is what an operator would do by hand anyway.
        tmp="${CONF}.tmp.$$"
        while IFS= read -r line; do
            case "$line" in
                SITES_FILE=*)   printf 'SITES_FILE=%s/wp-found.txt\n' "$DATADIR" ;;
                LOG_FILE=*)     printf 'LOG_FILE=%s/manager.log\n' "$LOGDIR" ;;
                ERROR_LOG_FILE=*) printf 'ERROR_LOG_FILE=%s/errors.log\n' "$LOGDIR" ;;
                LOCK_FILE=*)    printf 'LOCK_FILE=/run/wp-cli-update.lock\n' ;;
                BACKUP_DIR=*)   printf 'BACKUP_DIR=%s\n' "$BACKUPDIR" ;;
                DISCOVER_SCRIPT=*) printf 'DISCOVER_SCRIPT=%s/Find_WP_Senior.sh\n' "$PREFIX" ;;
                *)              printf '%s\n' "$line" ;;
            esac
        done <"$CONF" >"$tmp"
        cat "$tmp" >"$CONF"
        rm -f -- "$tmp"
        chmod 600 "$CONF"
        printf 'created %s (0600)\n' "$CONF"
    fi
fi

if [ -d "$COMPLDIR" ]; then
    if [ "$DRY" = 'true' ]; then
        printf 'would install bash completion as %s/wp-fleet\n' "$COMPLDIR"
    else
        "$PREFIX/Bash_WP-CLI_Update.sh" --completion bash >"${COMPLDIR}/wp-fleet" 2>/dev/null \
            && chmod 644 "${COMPLDIR}/wp-fleet" \
            && printf 'installed bash completion: %s/wp-fleet\n' "$COMPLDIR"
    fi
fi

printf '\nNext steps:\n'
printf '  1. %s/%s --wpcli-check\n' "$PREFIX" "$(basename "$MANAGER")"
printf '  2. edit %s\n' "$CONF"
printf '  3. %s/%s --output %s/wp-found.txt /var/www\n' "$PREFIX" "$(basename "$FINDER")" "$DATADIR"
printf '  4. %s/%s --check && %s/%s --report\n' "$PREFIX" "$(basename "$MANAGER")" "$PREFIX" "$(basename "$MANAGER")"
printf '  5. schedule it: see docs/ops/cron.example or docs/ops/wp-cli-update.{service,timer}\n'
