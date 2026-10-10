# Operations guide

How to run `Bash_WP-CLI_Update.sh` in production: installation, scheduling,
monitoring, alerting, and the runbooks for the incidents it exists to prevent.

## 1. Installation

```bash
sudo install -d /opt/wp-cli-update /var/lib/wp-cli-update \
     /var/log/wp-cli-update /var/backups/wp-cli-update \
     /var/lib/wp-cli-update/prometheus
sudo install -m 755 Bash_WP-CLI_Update.sh Find_WP_Senior.sh /opt/wp-cli-update/
sudo install -D -m 644 <(/opt/wp-cli-update/Bash_WP-CLI_Update.sh --completion bash) \
     /usr/share/bash-completion/completions/wp-fleet
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --init-config /etc/wp-cli-update.conf
sudo chmod 600 /etc/wp-cli-update.conf   # --init-config already did this
```

Or `sudo make install` from a checkout (same layout, `PREFIX` overridable).

Sanity-check the host before the first scheduled run:

```bash
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --wpcli-check   # version policy
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --check         # host + every site
```

`--check` exits non-zero when something is structurally wrong (no wp, a version
below the floor, an unenforceable timeout, a site with no owner, < 200 MiB free
on a site filesystem) and prints a per-site report otherwise.

## 2. Building the inventory

```bash
sudo /opt/wp-cli-update/Find_WP_Senior.sh \
     --output  /var/lib/wp-cli-update/wp-found.txt \
     --manifest /var/lib/wp-cli-update/inventory.tsv \
     --audit /var/www /srv/www
sudo /opt/wp-cli-update/Find_WP_Senior.sh --verify-list /var/lib/wp-cli-update/wp-found.txt
```

- A site opts out of automated maintenance by creating `.no_wp_cli` in its root.
  Discovery honours it; `--verify-list` reports it as OPTED-OUT rather than
  silently dropping it from view.
- The manifest (`--manifest`) is the richer document: owner, group, modes,
  wp-config mode, WP version, DB name, multisite flag, mtime — TSV/CSV/JSON.
- `--audit` during discovery flags world-readable/writable wp-config.php, PHP
  files in uploads and root-owned sites — the same findings the manager's
  `--security` makes per site, available before the first run.
- Re-verify the list on a schedule (`cron.example` does it weekly): a list that
  rots silently means sites that stop being updated silently.

## 3. The first run

Look before you leap, in this order:

```bash
sudo Bash_WP-CLI_Update.sh --list-sites          # what will be touched, as whom
sudo Bash_WP-CLI_Update.sh --report              # what state is it in
sudo Bash_WP-CLI_Update.sh --full --dry-run      # the real argv of every mutation
sudo Bash_WP-CLI_Update.sh --full -S /var/www/one-site.example.com --backup db
sudo Bash_WP-CLI_Update.sh --full --backup db    # the fleet
```

`--dry-run` executes read-only queries and prints the exact argv of every
mutating command, so enumeration (`--only-active`, `--cleanup`, plugin
resolution) is truthful in a dry run — it reports what *would* be deleted, not
a guess.

## 4. Scheduling

Ready-made units in [`ops/`](ops/):

- `cron.example` — nightly updates, weekly inventory + audit, monthly WP-CLI
  self-update, all wired to the state/metrics/notification flags.
- `wp-cli-update.service` + `.timer` — systemd one-shot with hardening knobs
  and `Persistent=true` catch-up.
- `logrotate.example` — time-based rotation alongside the tool's own
  size-based rotation (`copytruncate`, so it never races the writer).

Scheduling rules of thumb:

- **`--max-duration`** keeps a run inside its window; sites that did not start
  are next window's job, the summary says `stopped early`, exit code is 6.
- **`-j N`** is bounded by the database server, not the CPU: 4–8 for one MySQL
  instance. Batches are barriers; per-site output replays in site order.
- **`--timeout`** per command (900 s is a sane default with a real database);
  on a host without `timeout(1)` the perl supervisor enforces it, and without
  either the tool says so loudly at startup instead of hanging forever.
- **`--lock-timeout`** when two schedules may overlap; the second run waits
  instead of failing.

## 5. Monitoring

Three outputs, one run document — they cannot disagree:

| Output | Flag | Consumer |
|---|---|---|
| JSON Lines stream | `--json-lines` / `-J` | pipes, `jq`, log shippers |
| State file | `--state-file` | dashboards; atomic, written even after an interrupt |
| Prometheus textfile | `--metrics-file` | node_exporter textfile collector |

Series worth alerting on (see [`ops/prometheus-rules.example`](ops/prometheus-rules.example)):

- `wpu_up == 0` or absent → the run stopped producing metrics (the exporter
  died, the timer stopped, the host is off).
- `wpu_exit_code != 0` for the nightly job → page per your `FAIL_ON` policy.
- `wpu_sites_failed > 0` → the site-level breakdown is in
  `wpu_unit_status{path=…} == 0`.
- `wpu_findings_critical > 0` after the weekly `--security` → investigate today.
- `wpu_stopped_early == 1` → the window is too small or something hangs.
- `wpu_duration_seconds` trending up → the database or the network is telling
  you something before it becomes an outage.

`--status` is the human version: the last run document (or the log tail when
there is no state file), log sizes and the backup inventory.

Notifications: `--notify failure --webhook URL --webhook-format slack` posts
one line (mode, sites ok/failed/skipped, failed ops, warnings, duration) only
when the run failed; `--notify-command /path/to/exec` gets the same summary as
argv **and** as `WPU_*` environment variables, and is never run through a
shell. A failing notification is a warning, never a run failure.

## 6. Backups, restore, rollback

- `--backup db` before mutations; the dump is verified (`Dump completed`
  marker), 0640, owned by the site user, pruned to `KEEP_BACKUPS` per site.
- **A failed backup skips the site.** If you must update anyway:
  `--fail-on never` — the log records that you asked for it.
- Restore is a manual, deliberate act:

```bash
Bash_WP-CLI_Update.sh --restore -S /var/www/site.example.com            # list
Bash_WP-CLI_Update.sh --restore -S /var/www/site.example.com --from 1 --yes
```

  A fresh dump of the *current* database is taken before the import
  (`BACKUP_BEFORE_RESTORE=1`), and a file that does not look like a SQL dump
  is refused. There is deliberately **no automatic rollback** after a failed
  update: restoring a database whose core files were already replaced creates a
  state that never existed. The runbook for a failed site is: maintenance mode
  on → inspect → restore the DB → restore files if needed → smoke test →
  maintenance mode off.
- `--wpcli-rollback` restores a previous `wp` binary the same deliberate way.

## 7. Runbooks

**A site failed the nightly run.** The error box on stderr names the site, the
command and the first 20 lines; `ERROR_LOG_FILE` has the full text; the state
file has `"status":"FAILED"` for that path. Fix forward (re-run
`--full -S /path --backup db`) or restore (above).

**The smoke test failed after "success".** The site did not answer correctly
after its update: check the status code in the log line, put the site into
maintenance mode (`wp maintenance-mode activate`), and roll back the database
if the failure is a white screen. `SMOKE_ON_FAIL=warn` downgrades this to a
warning — useful while you tune `SMOKE_EXPECT` for redirect-heavy fleets.

**`--wpcli-update` broke wp.** `--wpcli-rollback` lists `.old` and
`.bak-<timestamp>` candidates, smoke-tests the chosen one and installs it back.

**The lock is held by a dead run.** flock releases on process death; the
pid-file fallback detects a dead holder automatically. If you must intervene:
`--no-lock` for one manual run — and only when you are certain nothing else is
running.

**Disk filled by backups.** `KEEP_BACKUPS` prunes per site per kind after every
new archive; `--status` prints the inventory and the free space of the backup
volume; `MIN_FREE_MIB` refuses to back up (and therefore to update) when the
volume is low — which is the correct order of failures.

## 8. Upgrades of the tool itself

```bash
git pull && make check          # build + drift + tests
sudo install -m 755 Bash_WP-CLI_Update.sh Find_WP_Senior.sh /opt/wp-cli-update/
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --version-detail
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --check
```

Read [`MIGRATION.md`](MIGRATION.md) when crossing a major version: the exit
code contract, the stream policy (stderr for prose since 7.0) and the
configuration keys are the three things a wrapper script might depend on.
