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
