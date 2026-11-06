# Agent operations guide

Scheduled operation, reading the result of a run, the failure table and the absolute
do-nots. Install and first verification are in [AGENT-INSTALL.md](AGENT-INSTALL.md).

## 1. Scheduled operation

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

## 2. Reading the result

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

## 3. Things that go wrong, and what they mean

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

## 4. Absolute do-nots

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
* Do not change `FAIL_ON`, `JOBS` or `BACKUP` "temporarily" and forget it: `--print-config`
  is the way to see what is actually in force.

## 5. Security advisory: CVE-2026-119977

A race condition in the WordPress core updater lets an unauthenticated attacker execute
code while a site is updating (CVSS 8.1; CISA KEV since 2026-11-03). Affected core:
4.7 through 7.1.3. Fixed: 7.1.4, 7.0.8 on the 7.0 branch, 6.9.11 on the 6.9 branch,
4.7.39 on the 4.7 branch; 4.6 and older have no fix and must be upgraded or retired.

The tool answers the two questions that matter, and the operator should not improvise
around it:

```bash
# 1. read-only verdict per site; exit 1 when any site is exposed
sudo wp-cli-update --security --json-lines

# 2. update the exposed fleet, dumping each database first, and harden in the same pass
sudo wp-cli-update --full -j 4 --backup db --harden-upgrade-dir \
  --report /var/log/wp-cli-update/cve-run.json

# 3. prove the versions moved
sudo wp-cli-update --security --json-lines
```

`--harden` writes a marker-guarded block into each site's root `.htaccess` for Apache
and LiteSpeed, keeps the original as `.htaccess.wp-cli-update.bak`, and is idempotent.
**nginx ignores `.htaccess`**: add this to every nginx `server` block instead, by hand
or by an agent:

```nginx
location ^~ /wp-content/upgrade/ { deny all; }
```

A site that stays below the fixed release is reported, not hidden: the `--core`/`--full`
run logs it, `--health` keeps its CVE column at `UPDATE`, and `--security` keeps exiting
1 until it is fixed. Also look for stray `.php` files under `wp-content/upgrade/` on any
site that may have been exposed, and treat a find as an incident, not a cleanup task.

Agent prompt for a host where this advisory is being worked:

```text
You are responding to WordPress CVE-2026-119977 (core 4.7-7.1.3, race condition in the
core updater; CVSS 8.1; CISA KEV since 2026-11-03). Use Bash WP-CLI Update; do not
improvise with ad-hoc wp calls.
1. Assess read-only: wp-cli-update --security --json-lines
2. Update the exposed sites with a database dump first:
   wp-cli-update --full -j 4 --backup db --harden-upgrade-dir --report /var/log/wp-cli-update/cve-run.json
3. Verify: wp-cli-update --security --json-lines must exit 0, and the core version of
   every updated site must have changed.
4. On nginx hosts add "location ^~ /wp-content/upgrade/ { deny all; }" to every server
   block; .htaccess does nothing there.
5. Report before/after versions, sites that still need an update, the .htaccess backup
   paths and the nginx change. Never call a site patched without the --security verdict.
```

