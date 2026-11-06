# Operations

Scheduling, reading a report and handling a failure. The agent-facing version of the same
material is
[docs/AGENT-OPERATIONS.md](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/docs/AGENT-OPERATIONS.md).

## Schedule it with systemd

```bash
sudo install -m 644 contrib/wp-cli-update.service /etc/systemd/system/
sudo install -m 644 contrib/wp-cli-update.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wp-cli-update.timer
systemctl list-timers wp-cli-update.timer
```

The shipped unit is `Type=oneshot`, `User=root`, `WorkingDirectory=/opt/wp-cli-update`,
`Nice=10`, `IOSchedulingClass=idle`, `TimeoutStartSec=3h`, `KillSignal=SIGTERM`,
`KillMode=mixed`, logging to the journal as `SyslogIdentifier=wp-cli-update`, and it runs
`--full --backup db --report /var/log/wp-cli-update/last-run.json`.

The timer fires at `03:20` local time with `RandomizedDelaySec=15m`, so several hosts do not
start at the same second and saturate one database server, and `Persistent=true`, so a host
that was off at 03:20 runs once after boot. Prefer it over cron: it records the last run in
`systemctl status`.

## Or cron

```bash
sudo install -m 644 contrib/cron.example /etc/cron.d/wp-cli-update
```

The file is root-owned, mode 0644, and must not have a dot in its name. Its runnable lines
are a nightly `--full --backup db --skip-if-no-updates --retry 2 --max-failures 5
--min-free-mb 500 --report ... --notify-on failure` and a read-only `--health` probe every
ten minutes. Cron itself does not retry and does not alert; the manager does both.

## Log rotation

`contrib/logrotate.conf` installs as `/etc/logrotate.d/wp-cli-update` (root:root 0644). It
rotates `/var/log/wp-cli-update/*.log` and `cron.out` weekly with 12 generations, and
`/var/log/wp-cli-update/*.json` weekly with 13, all compressed with `copytruncate`,
`create 0640 root adm` and `su root adm`. `copytruncate` is deliberate: the manager keeps
its log file open for the whole run, and a rename would leave it writing into an unlinked
inode for hours. The manager also rotates by size on its own (`LOG_MAX_BYTES` 5242880,
`LOG_KEEP` 3); logrotate is for long-term history and the cron wrapper's output.

## Reading a run

`--report FILE` writes one JSON document per run, atomically, with counters, per-site status
and the change list:

```json
{"run":{"version":"8.1.0","mode":"full","dry_run":false,"host":"web01","duration_s":412,
        "sites_total":42,"sites_ok":41,"sites_failed":1,"sites_skipped":0,
        "ops_ok":180,"ops_failed":1,"warnings":0,"retries":1,"changes":6,"exit":1},
 "sites":[{"path":"/var/www/a","status":"OK"},{"path":"/var/www/b","status":"FAILED"}],
 "changes":[{"site":"/var/www/a","kind":"plugin","name":"jetpack","from":"13.0","to":"13.5"}]}
```

`sites_skipped` covers `--skip-if-no-updates` and the sites a circuit breaker or a
`--run-timeout` left untouched. `changes` is the part worth reading first: a run that
reports 0 changes across 40 sites on a night when WordPress released a security update is
suspicious.

`--json-lines` prints the same information as a stream: one object per site plus a summary
object, so a killed run still leaves valid lines behind. The console is for humans: read
`--report`, do not parse the console. The log is append-only, and the error log keeps the
first `ERROR_OUTPUT_LINES` lines of every failed command with its exact argv.

## Notifications

```bash
wp-cli-update --full --backup db --notify https://hooks.example/ops --notify-on failure
wp-cli-update --full --backup db --mail-to ops
```

`--notify URL` POSTs a small JSON summary (needs `curl`) when the run matches `--notify-on`
(`never` / `failure` / `always`, default `failure`); `--mail-to` sends the same payload
through `mail(1)`, and a host without `mail(1)` logs a note instead of failing the run.
`NOTIFY_TIMEOUT` bounds the webhook call, and `--no-notify` disables both for one run. The
payload carries counters only: no site content, no licence, no paths, which is what makes it
safe to send to a chat channel.

## Monitoring with `--health`

`--health` is read-only: no lock, no backup, nothing written but log lines. It prints the
core version, the pending plugin and theme updates, the database size and the
CVE-2026-119977 verdict (`safe`, `UPDATE` or `?`) per site, so it is safe to call every ten
minutes from monitoring and safe to call while a `--full` run is in progress. It warns about
each exposed site and still exits 0; use `--security` when the probe needs a non-zero exit
to act on.

Use `--health` for the state question, `--security` for the yes/no gate, and `--status` for
the history question: `--status` reports the last run summary and the log sizes, not what
is pending now.

## CVE-2026-119977 response

WordPress core 4.7 through 7.1.3 carries a race condition in the core update mechanism; an
unauthenticated attacker can execute code while a site is updating. CVSS 8.1, added to CISA
KEV on 2026-11-03, mass scanning observed. Fixed: 7.1.4 (recommended), 7.0.8 on the 7.0
branch, 6.9.11 on the 6.9 branch and 4.7.39 on the 4.7 branch. 4.6 and older get no fix and
must be upgraded or retired. The advisory is on
[Security: CVE-2026-119977](09-Security-CVE-2026-119977).

The runbook is three commands: assess, update, verify.

```bash
# 1. read-only assessment; exit 1 when a site needs an update or its version is unreadable
wp-cli-update --security --json-lines

# 2. update the fleet, dumping each database first and hardening in the same pass
wp-cli-update --full -j 4 --backup db --harden-upgrade-dir \
  --report /var/log/wp-cli-update/cve-run.json

# 3. prove the versions really moved
wp-cli-update --security --json-lines
```

One site, dry run first, is the safe rehearsal:

```bash
wp-cli-update --full --site /var/www/example.com --backup db --dry-run --harden-upgrade-dir
```

**`.htaccess` cannot help nginx.** nginx never reads the file, so `--harden` prints the
directive that an nginx host needs in every `server` block, to be added by hand or by an
agent:

```nginx
location ^~ /wp-content/upgrade/ { deny all; }
```

The tool does not edit nginx configuration. It also does not hide a site that stays below
the fixed release: after a `--core` or `--full` run the log says another core update is
required, `--health` keeps its column at `UPDATE`, and `--security` keeps exiting 1 until
the version really moved.

Finally, look inside `wp-content/upgrade/` on any site that may have been exposed and treat
a stray `.php` file there as an incident, not as cleanup.

## Retry and the circuit breaker

* `--retry N` re-runs a failed site up to N extra times, `--retry-delay SEC` apart (default
  15). The default is 0: a retry hides a real failure for as long as the delay allows and
  doubles the time a broken fleet takes to fail.
* `--max-failures N` stops the run after N failed sites; the remaining sites are reported as
  skipped, not as failed, because they were never attempted.
* `--run-timeout SEC` is checked before each site; `--lock-wait SEC` waits for a concurrent
  run instead of failing at once.

Never silence a failure with `--fail-on never`: it hides the site from monitoring and from
the report. Stop the fleet honestly with `--max-failures`.

## Nightly checklist

1. The timer or cron entry fired: `systemctl list-timers wp-cli-update.timer`, or the log
   timestamp.
2. The exit code is 0, or the failure is understood: `--status` reads it back.
3. `.changes` and `.sites` in the report are non-empty and plausible for the night.
4. No dump was refused: grep the log for "refusing to export".
5. This night's dumps exist, and `--list-backups` lists them.
6. `--health` agrees: nothing is still pending on a site that reported OK.
7. `--security --json-lines` exits 0, or the site it names is the one being updated
   tonight. A non-zero verdict that nobody looked at is the failure mode this checklist
   exists to prevent.

Any of these failing is a reason to read [Troubleshooting](07-Troubleshooting) before the
next run, not to change `FailOn`.
