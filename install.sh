#!/usr/bin/env bash
# shellcheck shell=bash
# Installer for Bash WP-CLI Update.
#
# It does what the README describes, in the order the README describes it, and it is
# safe to run twice: every step is idempotent, nothing is deleted, and a file that
# already exists is left alone unless --force is given.
#
#   ./install.sh --dry-run                 # show every step, change nothing
#   sudo ./install.sh                      # /usr/local, config in /etc
#   sudo ./install.sh --prefix /opt/wp     # elsewhere
#   ./install.sh --uninstall               # remove the symlinks only
#
# What it installs:
#   PREFIX/lib/wp-cli-update/{Bash_WP-CLI_Update.sh,Find_WP_Senior.sh}
#   PREFIX/bin/{wp-cli-update,wp-find}                  (symlinks)
#   /var/log/wp-cli-update, /var/backups/wp-cli-update, /var/lib/wp-cli-update
#   /etc/wp-cli-update.conf                              (only if absent)
#
# It does NOT run the finder, does NOT touch a site and does NOT start anything.
set -uo pipefail

VERSION='1.0.0'
PROG='install.sh'
PREFIX='/usr/local'
CONFIG='/etc/wp-cli-update.conf'
DRY_RUN='false'
FORCE='false'
UNINSTALL='false'
WITH_SYSTEMD='false'
HEREDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = 'true' ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    "$@" || die "command failed: $*"
}

usage() {
    cat <<EOF
$PROG $VERSION — install Bash WP-CLI Update

Usage: $PROG [options]

  --prefix DIR     install under DIR (default $PREFIX)
  --config FILE    configuration file to create (default $CONFIG)
  --systemd        also install the timer and service into /etc/systemd/system
  --force          overwrite an existing config file
  --dry-run        print every step, change nothing
  --uninstall      remove the two symlinks; keep code, config, logs and backups
  -h, --help       this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --systemd) WITH_SYSTEMD='true'; shift ;;
        --force) FORCE='true'; shift ;;
        --dry-run) DRY_RUN='true'; shift ;;
        --uninstall) UNINSTALL='true'; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

LIBDIR="${PREFIX}/lib/wp-cli-update"
BINDIR="${PREFIX}/bin"

if [ "$UNINSTALL" = 'true' ]; then
    say "removing the symlinks from ${BINDIR}"
    run rm -f "${BINDIR}/wp-cli-update" "${BINDIR}/wp-find"
    say "kept: ${LIBDIR}, ${CONFIG}, /var/log/wp-cli-update, /var/backups/wp-cli-update, /var/lib/wp-cli-update"
    exit 0
fi

[ -f "${HEREDIR}/Bash_WP-CLI_Update.sh" ] || die "run this from the checkout: ${HEREDIR}/Bash_WP-CLI_Update.sh is missing"
[ -f "${HEREDIR}/Find_WP_Senior.sh" ] || die "${HEREDIR}/Find_WP_Senior.sh is missing"

# bash 4.2 is the documented floor; the manager refuses to start below it, and an
# installer that installs something which cannot run is not an installer.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    die "bash 4.2 or newer is required (found ${BASH_VERSION:-none})"
fi

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != 'true' ]; then
    die "install needs root: it switches into the owner of every site; re-run with sudo, or use --dry-run"
fi

if ! command -v wp >/dev/null 2>&1; then
    say "warning: no wp in PATH. Install WP-CLI or set WP_CLI_PATH in ${CONFIG}"
fi

say "installing Bash WP-CLI Update"
step "prefix   : ${PREFIX}"
step "code     : ${LIBDIR}"
step "config   : ${CONFIG}$([ -f "$CONFIG" ] && printf ' (exists, will not be overwritten)')"

run install -d -m 755 "$LIBDIR"
run install -m 755 "${HEREDIR}/Bash_WP-CLI_Update.sh" "${LIBDIR}/Bash_WP-CLI_Update.sh"
run install -m 755 "${HEREDIR}/Find_WP_Senior.sh" "${LIBDIR}/Find_WP_Senior.sh"
run install -m 644 "${HEREDIR}/wp-cli-update.conf.example" "${LIBDIR}/wp-cli-update.conf.example"
run install -m 644 "${HEREDIR}/README.md" "${LIBDIR}/README.md"
run install -m 644 "${HEREDIR}/AGENTS.md" "${LIBDIR}/AGENTS.md"
run install -d -m 755 "$BINDIR"
run ln -sfn "${LIBDIR}/Bash_WP-CLI_Update.sh" "${BINDIR}/wp-cli-update"
run ln -sfn "${LIBDIR}/Find_WP_Senior.sh" "${BINDIR}/wp-find"

for d in /var/log/wp-cli-update /var/backups/wp-cli-update /var/lib/wp-cli-update; do
    run install -d -m 755 "$d"
done

if [ ! -f "$CONFIG" ] || [ "$FORCE" = 'true' ]; then
    run install -D -m 600 "${HEREDIR}/wp-cli-update.conf.example" "$CONFIG"
    step "config written; edit it before the first run"
else
    step "config kept as it is (use --force to overwrite)"
fi

if [ "$WITH_SYSTEMD" = 'true' ]; then
    if [ -d /etc/systemd/system ]; then
        run install -m 644 "${HEREDIR}/contrib/wp-cli-update.service" /etc/systemd/system/wp-cli-update.service
        run install -m 644 "${HEREDIR}/contrib/wp-cli-update.timer" /etc/systemd/system/wp-cli-update.timer
        step "systemd units installed; enable with: systemctl enable --now wp-cli-update.timer"
    else
        say "warning: --systemd asked for, but /etc/systemd/system does not exist here"
    fi
fi

say ''
say "next steps:"
say "  1. edit ${CONFIG}  (WP_CLI_PATH, SITES_FILE, BACKUP_DIR, MIN_FREE_MB)"
say "  2. wp-find --output /var/lib/wp-cli-update/wp-found.txt /var/www /home"
say "  3. wp-cli-update --doctor"
say "  4. wp-cli-update --check"
say "  5. wp-cli-update --health"
say "  6. wp-cli-update --full --site /var/www/example.com --backup db --dry-run"
