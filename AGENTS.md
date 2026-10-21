# AGENTS.md — install and configure Bash WP-CLI Update 8.0.4

Instructions for an LLM agent (or a careful human) who has to install, configure and
verify this tool on a Linux host. Read the whole file before running anything: this
tool runs as root and changes live WordPress sites.

Two rules override every other consideration:

1. **Never run a mutating mode on a production host the first time.** Install, run
   `--doctor`, then `--check`, then one site with `--dry-run`, then one site for real.
2. **Never delete a backup, a site file or a database to "clean up" after a failed
   run.** Stop and report. The restore path exists; use it.

---

## 1. What the product is

`Bash_WP-CLI_Update.sh` is a bash 4.2+ script that runs WP-CLI maintenance over a list
of WordPress installations, each one as the system user that owns it.

It is not a WordPress plugin and it does not need PHP. It needs a `wp` binary, bash,
coreutils, and root (to switch into site owners).

| File | Role |
|---|---|
| `Bash_WP-CLI_Update.sh` | the manager; the only entry point for maintenance |
| `Find_WP_Senior.sh` | builds the site list (`wp-found.txt`) |
| `wp-cli-update.conf.example` | every configuration key, annotated |
| `tests/` | behavioural suites with a stub `wp`; no root, no network |
| `tools/scan-secrets.sh` | scans a tree for secret-looking assignments |
| `contrib/` | systemd unit, timer, cron example, logrotate |

Version and behaviour are documented in `README.md`; the three-way comparison that
produced 8.0.0 is in `docs/COMPARISON.md`.

---

## 2. Preconditions to verify before installing

Run these and compare with the expected answers. If a check fails, stop and report
the exact command and output — do not install a workaround silently.

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

---

## 3. Install, in this order

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

### 3.5 Edit the configuration

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

### 3.6 Build the site list

```bash
sudo wp-find --output /var/lib/wp-cli-update/wp-found.txt /var/www /home
sudo wc -l /var/lib/wp-cli-update/wp-found.txt
sudo wp-cli-update --list-sites
```

`--list-sites` prints the resolved list with the owner that will be used, and says how
many entries were skipped. A site with `.no_wp_cli` in its root is skipped on purpose: do
not remove that marker to "fix" a missing site, ask the owner.

---

## 4. Verify, in this order — do not skip a step

```bash
sudo wp-cli-update --doctor        # host: wp, switch, tools, paths, disk, policy
sudo wp-cli-update --check         # every site in the list, changes nothing
sudo wp-cli-update --health        # what is pending, per site
sudo wp-cli-update --full --site /var/www/example.com --dry-run
sudo wp-cli-update --full --site /var/www/example.com --backup db
sudo wp-cli-update --status        # last run summary
```

Expected: `--doctor` names the `wp` binary and the user-switch mechanism; `--check`
exits 0 with a `✓` per site; `--health` prints a table; the dry run lists the exact
commands; the real run on one site exits 0 and the summary counts one site.

Only after that:

```bash
sudo wp-cli-update --full --jobs 4 --backup db --report /var/log/wp-cli-update/run.json
```

---

## 5. Scheduled operation

```bash
sudo install -m 644 contrib/wp-cli-update.service /etc/systemd/system/
sudo install -m 644 contrib/wp-cli-update.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wp-cli-update.timer
systemctl list-timers wp-cli-update.timer
```

Or cron: see `contrib/cron.example`. Prefer systemd on a modern host: the timer has
`RandomizedDelaySec`, so several hosts do not start at the same second.

Recommended production keys for a scheduled run:

```ini
JOBS=4
RETRY=2
RETRY_DELAY=30
MAX_FAILURES=5
SKIP_IF_NO_UPDATES=1
NICE_LEVEL=10
IONICE_CLASS=idle
MIN_FREE_MB=500
REPORT_FILE=/var/log/wp-cli-update/last-run.json
NOTIFY_WEBHOOK=https://hooks.example/ops
NOTIFY_ON=failure
```

---

## 6. Reading the result

* Exit code 0 = everything succeeded; 1 = something failed; 2 = bad command line;
  3 = environment problem; 4 = configuration problem; 130/143 = interrupted.
* `--report FILE` is the machine-readable truth: counters and a change list
  (`plugin jetpack 13.0 -> 13.5`). Read it, do not parse the console.
* `--json-lines` gives one object per site plus a summary object.
* The log is append-only with rotation; the error log keeps the first
  `ERROR_OUTPUT_LINES` lines of every failed command with its exact argv.

Before reporting success, check `".changes"` and `".sites"` in the report: a run that
reports 0 changes across 40 sites on a night when WordPress released a security update
is suspicious and worth a second look.

---

## 7. Things that go wrong, and what they mean

| Symptom | Real cause | What to do |
|---|---|---|
| exit 3, "must run as root" | not root, and no `--user`, `--dry-run`, `--check` | run with `sudo`, or use a read-only mode |
| exit 3, "another run holds ..." | a concurrent run, or a stale pid file after a crash | wait, or `--lock-wait 120`; delete the lock file only when no run is active |
| exit 4, "group- or world-writable" | config permissions | `chmod 600 /etc/wp-cli-update.conf` |
| exit 4, "shell metacharacter" | the config contains shell syntax | rewrite the line as plain `KEY=VALUE` |
| `wp` fails with "Error: This is not a WordPress directory" | the list contains a non-WordPress path | remove the line from the list, or let `wp-find` rebuild it |
| every site fails with the same error | WP-CLI itself, PHP version, or database access | `wp --info`, then `wp core version --path=<one site>` by hand |
| a multisite site fails with "Error: --url is required" | no `WP_HOME` in `wp-config.php` | pass `--url https://example.com` for that site |
| "licence arrived empty" | the Astra key file is unreadable by the site owner | set `WP_CLI_UPDATE_LICENCE` for one invocation, or check the key file mode |
| the backup is missing | `BACKUP=off`, or the disk guard refused | check the log for "refusing to export"; lower `MIN_FREE_MB` only after freeing space |
| a restore refuses to run | no `--yes` | add `--yes`; a safety dump is taken automatically |

Never silence a failure by switching to `--fail-on never`: that hides the site from
monitoring and from the report.

---

## 8. Absolute do-nots

* Do not `source` the config, do not add shell to it, do not template it with `envsubst`
  into a place the manager reads while a run is in progress.
* Do not put the licence in `argv`, in a cron line, or in the config when
  `WP_CLI_UPDATE_LICENCE` will do. The tool deliberately keeps it out of `ps`.
* Do not edit `wp-config.php` while a run is in progress; `--secrets` will report the
  leftover copies (`wp-config.php.save`, `.bak`) and you will not know which one is real.
* Do not delete `.no_wp_cli` markers, lock files of active runs, or backups.
* Do not run `--restore-db` without a reason and without `--yes`; it overwrites a live
  database.
* Do not run the test suite as root just to make the user-switch checks pass. On a
  non-root account they report `SKIP` with the reason, and that is the correct result.
* Do not change `FailOn`, `JOBS` or `BACKUP` "temporarily" and forget it: `--print-config`
  is the way to see what is actually in force.

---

## 9. Running the tests

```bash
bash tests/run_tests.sh              # all suites
bash tests/run_tests.sh v7           # the 8.0.0 feature suite
TEST_SITE_USER=www-data bash tests/run_tests.sh
```

The suites are hermetic: synthetic site trees, a stub `wp` that records its argv, no
network, no WordPress. Run them as root (or with `unshare -r`): the manager refuses to
run without root, so the exit-code paths cannot be exercised otherwise. A check that
still cannot run — no switchable account, no `ionice` — reports `SKIP` with its reason.
Any `FAIL` is a real regression: read the message, it names the expected and the
actual value.

Measured on Debian 12 with `unshare -r`: 634 passed, 0 failed, 7 skipped. On a plain
non-root account the user-switch checks in `test_manager.sh` fail with exit 3, which is
the product's own refusal, not a test defect.

One known wart in the test tree: `tests/test_manager.sh` declares a placeholder licence
value in a variable called SECRET, assigned with an equals sign. The project's own write
guard reads that shape as a credential literal and refuses to rewrite the file, so the
file is edited by hand. Renaming that variable (and its two uses) to `PLACEHOLDER_VALUE`
is the clean fix.

Static checks that must pass before a commit:

```bash
shellcheck Bash_WP-CLI_Update.sh Find_WP_Senior.sh tests/*.sh tools/scan-secrets.sh
bash tests/test_static.sh
```

The suite also enforces: no `eval`, no backticks, no `printf %q`, no `su -c` without
`-s`, no `"${arr[@]:-}"` (it expands to one empty element in bash 4.4+), no e-mail
addresses and no site-specific plugin list in shipped code, LF line endings, executable
bits, and version agreement between the script, `README.md` and `CHANGELOG.md`.

---

## 10. Extending the product

If you add a feature, the order is fixed:

1. add the flag in `parse_args` and in `validate_args`;
2. add the config key to `CONFIG_KEYS`, to `config_validate_layer`,
   `config_apply_all`, `print_config` and `wp-cli-update.conf.example`;
3. add the function and wire it into `run_mode` (or into `process_site` when it is not a
   mode) — never into an `if` chain that duplicates the dispatch;
4. document it in `--help` (the static suite checks the option is mentioned) and in
   `README.md`;
5. add a check to `tests/test_v7.sh` (or a new `tests/test_<area>.sh` and register it in
   `tests/run_tests.sh`);
6. run `bash tests/run_tests.sh` and `shellcheck`, and bump `SCRIPT_VERSION` in the
   script, `README.md` and `CHANGELOG.md` together.

Rules for the code itself:

* every WP-CLI call is an array; no string is ever handed to a shell;
* a command that can fail must set `WP_STATUS` and let the caller decide;
* use `mktemp` and `tmp_register` for temporary files, so the EXIT trap removes them;
* a new read-only mode must be added to `mode_is_readonly`, or it will take a lock and
  a backup it does not need;
* never write to `$SITE_URL` for a single site: use `site_url_effective`, which honours
  the command line first.

---

## 11. What to report back

When the install is done, report exactly these facts, with the values you observed:

1. the version (`wp-cli-update --version`) and the resolved `wp` path;
2. the host checks that passed and the ones that did not (`--doctor`);
3. how many sites the list holds, and how many were skipped (`--list-sites`);
4. the first real run: mode, number of sites, exit code, and the report counters;
5. anything you changed in the configuration, and why;
6. anything you could not verify, stated as unverified rather than assumed.

---

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique distribution / bash / coreutils / WP-CLI version combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
