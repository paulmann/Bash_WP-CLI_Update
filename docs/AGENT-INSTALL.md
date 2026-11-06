# Agent install guide

Instructions for an LLM agent (or a careful human) installing, configuring and
verifying Bash WP-CLI Update on a Linux host. Read the whole document before running
anything: this tool runs as root and changes live WordPress sites.

Two rules override every other consideration:

1. **Never run a mutating mode on a production host the first time.** Install, run
   `--doctor`, then `--check`, then one site with `--dry-run`, then one site for real.
2. **Never delete a backup, a site file or a database to "clean up" after a failed
   run.** Stop and report. The restore path exists; use it.

## 1. Preconditions to verify before installing

Run these and compare with the expected answers. If a check fails, stop and report the
exact command and output — do not install a workaround silently.

```bash
bash --version | head -1                 # >= 4.2
id -u                                    # 0 for a real run (root)
command -v wp                            # /usr/local/bin/wp or configure WP_CLI_PATH
command -v runuser || command -v sudo || command -v su
command -v flock; command -v timeout; command -v tar; command -v gzip
php -v | head -1                         # optional, WP-CLI needs PHP 7.2+
```

The manager does not read `wp` from `PATH` blindly: if `WP_CLI_PATH` is configured it
must be executable, and there is no silent fallback. A wrong path is an environment
error (exit 3), by design.

## 2. Install, in this order

There are two supported ways to get the code onto the host. They are equivalent — the npm
package contains the same two scripts and two shims that exec them — so pick one:

```bash
# A. npm (delivery only: it does not install WP-CLI and runs nothing)
npm install -g bash-wp-cli-update
# commands land in $(npm prefix -g)/bin: wp-cli-update, wp-find

# B. the repository (what the steps below assume)
```

```bash
# 3.1 place the code
sudo git clone https://github.com/paulmann/Bash_WP-CLI_Update.git /opt/wp-cli-update
sudo chmod 755 /opt/wp-cli-update/Bash_WP-CLI_Update.sh /opt/wp-cli-update/Find_WP_Senior.sh

# 3.2 commands on PATH
sudo ln -sf /opt/wp-cli-update/Bash_WP-CLI_Update.sh /usr/local/bin/wp-cli-update
sudo ln -sf /opt/wp-cli-update/Find_WP_Senior.sh   /usr/local/bin/wp-find

# 3.3 directories (the tool creates the backup dir itself, the rest do not exist yet)
sudo install -d -m 755 /var/log/wp-cli-update /var/backups/wp-cli-update /var/lib/wp-cli-update

# 3.4 configuration, root-readable only
sudo install -m 600 /opt/wp-cli-update/wp-cli-update.conf.example /etc/wp-cli-update.conf
```

With the npm route the steps 3.3 and 3.4 still apply; only 3.1 and 3.2 are replaced, and
the config template is then at `$(npm root -g)/bash-wp-cli-update/wp-cli-update.conf.example`.

A copy of the config next to the script (`/opt/wp-cli-update/wp-cli-update.conf`) wins
over `/etc/wp-cli-update.conf`. Prefer the `/etc` one; the local one is a trap for the
next operator.

### 2.1 Edit the configuration

Minimum viable configuration:

```ini
WP_CLI_PATH=/usr/local/bin/wp
SITES_FILE=/var/lib/wp-cli-update/wp-found.txt
AUTO_DISCOVER=0
LOG_FILE=/var/log/wp-cli-update/manager.log
ERROR_LOG_FILE=/var/log/wp-cli-update/errors.log
BACKUP=db
BACKUP_DIR=/var/backups/wp-cli-update
KEEP_BACKUPS=5
MIN_FREE_MB=500
JOBS=4
TIMEOUT=600
```

Rules that matter:

* `AUTO_DISCOVER=0` on a production host. An automatic scan costs I/O and can pick up
  a site that was not meant to be touched.
* `chmod 600` the file. The manager refuses a group- or world-writable config (exit 4)
  because the file can carry an Astra licence.
* Keys are `KEY=VALUE`. The file is **never sourced**: a backtick, `$(`, `|`, `;`, `&`,
  `<` or `>` anywhere in a line rejects the whole file. Do not write shell in it.
* Environment overrides use `WP_CLI_UPDATE_<KEY>`, for example
  `WP_CLI_UPDATE_JOBS=8`. The command line wins over everything.
* 6.1 names still work and are reported once: `WP_TIMEOUT` (`TIMEOUT`),
  `WP_CLI_BIN` (`WP_CLI_PATH`), `SITE_URL` (`URL`), `BACKUP_KEEP` (`KEEP_BACKUPS`),
  `DEFAULT_JOBS` (`JOBS`).

### 2.2 Build the site list

```bash
sudo wp-find --output /var/lib/wp-cli-update/wp-found.txt /var/www /home
sudo wc -l /var/lib/wp-cli-update/wp-found.txt
sudo wp-cli-update --list-sites
```

`--list-sites` prints the resolved list with the owner that will be used, and says how
many entries were skipped. A site with `.no_wp_cli` in its root is skipped on purpose: do
not remove that marker to "fix" a missing site, ask the owner.

## 3. Verify, in this order — do not skip a step

```bash
sudo wp-cli-update --doctor        # host: wp, switch, tools, paths, disk, policy
sudo wp-cli-update --check         # every site in the list, changes nothing
sudo wp-cli-update --health        # what is pending, per site (CVE column included)
sudo wp-cli-update --security --json-lines   # CVE-2026-119977 verdict; exit 1 if a site needs an update
sudo wp-cli-update --full --site /var/www/example.com --dry-run
sudo wp-cli-update --full --site /var/www/example.com --backup db
sudo wp-cli-update --status        # last run summary
```

Expected: `--doctor` names the `wp` binary and the user-switch mechanism; `--check`
exits 0 with a `✓` per site; `--health` prints a table with a CVE column; `--security`
exits 0 only when every core version is at or above the fixed release for its branch;
the dry run lists the exact commands; the real run on one site exits 0 and the summary
counts one site.

Only after that:

```bash
sudo wp-cli-update --full --jobs 4 --backup db --harden-upgrade-dir \
  --report /var/log/wp-cli-update/run.json
```

## 4. What to report back

When the install is done, report exactly these facts, with the values you observed:

1. the version (`wp-cli-update --version`) and the resolved `wp` path;
2. the host checks that passed and the ones that did not (`--doctor`);
3. how many sites the list holds, and how many were skipped (`--list-sites`);
4. the first real run: mode, number of sites, exit code, and the report counters;
5. anything you changed in the configuration, and why;
6. anything you could not verify, stated as unverified rather than assumed.

Next: [operations](AGENT-OPERATIONS.md) for scheduling and incident handling,
[development](DEVELOPMENT.md) for the test suite and extending the product.
