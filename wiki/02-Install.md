# Install

Three routes, one result: a manager on `PATH`, a finder on `PATH`, the directories the tool
writes to, and a configuration file only root can read. The tool is released under the MIT
licence since 8.1.0.

## Route 1: npm

```bash
npm install -g bash-wp-cli-update
```

The package is a delivery channel: it ships the two scripts unchanged plus two shims
(`wp-cli-update`, `wp-find`) that resolve their own real path and `exec` the script. The
commands land in `$(npm prefix -g)/bin`. It does not install WP-CLI, it runs nothing at
install time, and root is still needed at run time.

## Route 2: the installer from the release archive

```bash
curl -LO https://github.com/paulmann/Bash_WP-CLI_Update/releases/latest/download/bash-wp-cli-update-8.1.0.tar.gz
sudo ./install.sh --dry-run     # show every step
sudo ./install.sh --systemd     # perform them, plus the nightly timer
```

`install.sh` is idempotent, has `--dry-run` and `--uninstall`, and installs the systemd unit
and timer only when asked to.

## Route 3: by hand

```bash
sudo apt-get install -y bash coreutils findutils gzip tar
curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod 755 /usr/local/bin/wp

sudo git clone https://github.com/paulmann/Bash_WP-CLI_Update.git /opt/wp-cli-update
sudo chmod 755 /opt/wp-cli-update/Bash_WP-CLI_Update.sh /opt/wp-cli-update/Find_WP_Senior.sh
sudo ln -sf /opt/wp-cli-update/Bash_WP-CLI_Update.sh /usr/local/bin/wp-cli-update
sudo ln -sf /opt/wp-cli-update/Find_WP_Senior.sh   /usr/local/bin/wp-find
sudo install -d -m 755 /var/log/wp-cli-update /var/backups/wp-cli-update /var/lib/wp-cli-update
sudo install -m 600 /opt/wp-cli-update/wp-cli-update.conf.example /etc/wp-cli-update.conf
```

## Directories and permissions

| Path | Mode | Holds |
|---|---|---|
| `/opt/wp-cli-update` | 755 | the checkout; both scripts are 755 |
| `/usr/local/bin/wp-cli-update`, `wp-find` | symlinks | the two entry points |
| `/var/log/wp-cli-update` | 755 | `manager.log`, `errors.log`, JSON reports |
| `/var/backups/wp-cli-update` | created by the tool, 0700 | database dumps and tree archives |
| `/var/lib/wp-cli-update` | 755 | the site list |
| `/etc/wp-cli-update.conf` | 600 | configuration; it can carry a licence |

The backup tree is root-only: a dump is a complete copy of a customer's data. Since 8.0.3 the
export runs in a private temporary directory owned by the site owner and the dump is moved
into place by root with `root:root 0640`.

## Configuration file placement

* `/etc/wp-cli-update.conf` is read by every invocation; `<script dir>/wp-cli-update.conf`
  wins over it, and a local copy is a trap for the next operator.
* `--config FILE` reads one file instead of both; with the npm route the template is at
  `$(npm root -g)/bash-wp-cli-update/wp-cli-update.conf.example`.

`chmod 600` is not cosmetic: the manager refuses a group- or world-writable file with exit 4,
because the file can hold a licence.

## Build the site list

```bash
sudo wp-find --output /var/lib/wp-cli-update/wp-found.txt /var/www /srv
sudo wc -l /var/lib/wp-cli-update/wp-found.txt
sudo wp-cli-update --list-sites
```

A directory is a WordPress root when it holds `wp-config.php` and one of `wp-load.php` or
`wp-includes/version.php`. A directory containing `.no_wp_cli` is always skipped: that marker
is how a site opts out. `--list-sites` prints the resolved list with the owner that will be
used and says how many entries were skipped. The finder exits 5 when nothing was found
(`--fail-empty` makes it 1).

## Verify in this order

Do not skip a step, and do not start with a mutating mode.

| Step | Command | What it must show |
|---|---|---|
| 1 | `sudo wp-cli-update --doctor` | the `wp` binary it will use, the user-switch mechanism, optional tools, paths, free space, config permissions, policy in force |
| 2 | `sudo wp-cli-update --check` | exit 0 and a `✓` per site; it changes nothing |
| 3 | `sudo wp-cli-update --health` | a table: core version, pending plugin and theme updates, database size, and the `safe` / `UPDATE` / `?` verdict for CVE-2026-119977 |
| 4 | `sudo wp-cli-update --security --json-lines` | one `{"type":"security",...}` object per site; exit 0 when every site is at or above the fixed release, 1 when one is exposed or its version cannot be read |
| 5 | `sudo wp-cli-update --full --site /var/www/example.com --dry-run` | the exact commands it would run, exit 0, nothing changed |
| 6 | `sudo wp-cli-update --full --site /var/www/example.com --backup db` | exit 0, and a summary that counts one site |
| 7 | `sudo wp-cli-update --status` | the last run summary and the log sizes |

Only after that, run the fleet:

```bash
sudo wp-cli-update --full --jobs 4 --backup db --report /var/log/wp-cli-update/run.json
```

## Security: assess first, harden second

Once the host checks pass, the first thing to run against the fleet is the read-only
assessment, and the second is the hardening pass:

```bash
# 1. read-only: which sites are exposed to CVE-2026-119977 (exit 1 when one is)
sudo wp-cli-update --security --json-lines

# 2. deny web access to wp-content/upgrade/ on Apache and LiteSpeed
sudo wp-cli-update --harden
```

`--security` takes no lock and no backup, so it is safe to run on a live host and safe to
repeat. `--harden` is a writing mode: it backs up each site's `.htaccess` once to
`.htaccess.wp-cli-update.bak`, is idempotent, and prints the nginx directive at the end of
the run because nginx ignores `.htaccess`. Neither replaces updating WordPress; they make
the state visible and the upgrade directory unreachable while the update happens. The
advisory, the fleet commands and an agent prompt are on
[Security: CVE-2026-119977](09-Security-CVE-2026-119977).

## Upgrade from 6.x

1. Back up the current script and configuration.
2. Replace the script; keep `/etc/wp-cli-update.conf`. Legacy keys keep working, reported once.
3. `--print-config` and diff it against your expectations before the first run.
4. `--doctor` and `--check` before the first real run.
5. Nothing in 6.x was removed: `--backup`, `--json-lines`, `--only-active`,
   `--exclude-plugins`, `--fail-on`, `--strict` and `--allow-root` behave as before.

## What npm does not do

* It does not install WP-CLI, PHP or a database client.
* It does not create the log, backup or site-list directory, and it does not write
  `/etc/wp-cli-update.conf`.
* It does not run a maintenance pass, and it does not grant root: run with `sudo`.

See [Configuration](04-Configuration) for the keys, and [Modes](03-Modes) for the first run.
