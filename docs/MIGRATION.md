# Migration guide: 6.x → 7.0

7.0 is a major version for three reasons: the exit-code contract gained a
member, the stream policy changed, and a handful of defaults now do the safe
thing instead of the historical thing. Everything else is additive. The
configuration **keys** of 6.x all still exist and mean the same thing.

## What breaks (and how to fix it)

### 1. Prose moved to stderr — in every format

In 6.x, info-level log lines went to **stdout** when the output format was
`table`. Since 7.0 stdout carries data only and *all* logs, warnings, banners
and summaries go to stderr, tables included.

```bash
# 6.x habit — captured logs together with the table:
./Bash_WP-CLI_Update.sh -l > plugins.txt
# 7.0 — does what it looks like; add 2>>log to keep the prose:
./Bash_WP-CLI_Update.sh --list-plugins > plugins.txt 2>> plugins.err
```

Anything that parsed merged output (`2>&1 |`) keeps working; anything that
assumed logs on stdout needs the redirect flipped. This is the single most
common migration fix.

### 2. `--full` no longer runs `db repair`

`mysqlcheck --repair` is a no-op that still walks every InnoDB table and locks
MyISAM ones — a self-inflicted window on every nightly run. 7.0 `--full` runs
`db optimize` only. Want the old behaviour back:

```
FULL_DB_REPAIR=1        # config or WP_CLI_UPDATE_FULL_DB_REPAIR=1
```

`--db-optimize` still does optimize+repair, and `--db-fix` still repairs.

### 3. New exit code 6 — stopped early

`--fail-fast` and `--max-duration` stop a run between sites and exit **6**
(summary, state file and notification still happen). Wrappers that treat
"non-zero and not 1/2/3/4" as unknown should learn 6. `--fail-on never` maps
it back to 0.

### 4. Stricter config-file permissions

A group- or world-writable config file (0620/0660/0664/0666/0777…) is now
**rejected with exit 4**, where 6.x checked only the world-write nibble. Fix:
`chmod 0600 /etc/wp-cli-update.conf`. A root-run also warns when the file is
not root-owned.

### 5. Site-list entries must look like WordPress

An entry without `wp-config.php`, `wp-load.php` or `wp-includes/version.php`
is skipped with a warning (counted as skipped, not processed). In 6.x any
existing directory was processed and failed later, deeper, and more
confusingly. `--strict` turns the skip warning into exit 1 if you want that.

### 6. Non-root runs are decided per site, not refused wholesale

6.x exited 3 for any non-root run (unless `--user`/`--dry-run`/`--check`).
7.0 allows an unprivileged run when every resolved site owner is the caller —
and names the first site that would need a switch when not. If you relied on
the blanket refusal as a guard rail, use `--user` explicitly or keep running
under sudo.

### 7. Licence handoff defaults to stdin

`LICENCE_HANDOFF=stdin` (default) pipes the value to the child; no temporary
file is created. If your wrapper provably consumes the child's stdin (rare:
some `use_pty` sudo setups), set `LICENCE_HANDOFF=file` for the 6.x behaviour.
Env aliases (`ASTRA_KEY`, `ASTRA_LICENSE_KEY`) and key-file locations are
unchanged; `~/.config/astra.key` was added.

### 8. Renamed internals (scripts/wrappers that source the tool — don't)

Variable names now equal config keys (`ALLOW_ROOT`, `TIMEOUT`, `BACKUP`,
`COLOR`, `URL`, `USER_ENV`, …). Nothing external consumes these; if a wrapper
greps `--print-config` output, note the table gained a TYPE column and rows are
`KEY  VALUE  TYPE  FROM  CLI`.

## What is new (opt-in, nothing to do)

- **WP-CLI version policy**: the floor check runs automatically
  (`WP_CLI_MIN_VERSION=2.8.0`; exit 3 below it). If your fleet legitimately
  runs an older WP-CLI, lower the floor in config rather than disabling the
  check — and read the warning it prints.
- `--wpcli-check/--wpcli-update/--wpcli-install/--wpcli-rollback`
- Modes: `--cache`, `--languages`, `--cleanup`, `--report`, `--security`,
  `--secrets`, `--restore`; `--plugin-manage` grew `install/update/status`
- Fleet: `--include/--exclude`, `--stagger`, `--retry`, `--fail-fast`,
  `--max-duration`, `--min-free-space`, `--maintenance-mode`, `--smoke-test`,
  `--lock-timeout/--lock-required`, `--multisite all`, `--sites -` (stdin),
  TAB owner column in the site list
- Outputs: `--state-file`, `--metrics-file`, `--notify/--webhook/
  --notify-command`, `--log-format json`, `--syslog`
- DX: `--init-config`, `--completion bash|zsh`, `--version-detail`,
  "did you mean" suggestions
- Finder 3.0: `--manifest`, `--fields`, `--audit`, `--verify-list`,
  `--print0`, `--min-depth`, `--include-name`, `--follow-symlinks`

## Suggested migration sequence

```bash
# 1. read the new report before changing anything
Bash_WP-CLI_Update.sh --wpcli-check
Bash_WP-CLI_Update.sh --check
Bash_WP-CLI_Update.sh --report

# 2. diff the behaviour on one site
Bash_WP-CLI_Update.sh --full --dry-run -S /var/www/one-site
Bash_WP-CLI_Update.sh --full -S /var/www/one-site --backup db

# 3. fix the config (permissions, FULL_DB_REPAIR if you want it, MIN version)
Bash_WP-CLI_Update.sh --print-config

# 4. update the scheduler (stderr redirections, exit code 6, notify/state/metrics)
```

## From the legacy scripts (≤5.x)

`legacy/` holds the original single-file updater (config via `source`, licence
in argv, undifferentiated exit codes). Migration to 6.x is documented in the
branch history; to 7.0 the short version is: replace the script, generate a
config with `--init-config`, move the licence to a key file, and re-point cron
at the modes above. Do not run legacy and 7.x against the same fleet: the
legacy script does not honour the run lock.
