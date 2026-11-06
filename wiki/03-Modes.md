# Modes and options

Exactly one mode per run. Every option that takes a value accepts both spellings:
`--timeout 600` and `--timeout=600`.

## Modes

The table lists 23 modes and inspection commands. `--list-modes` prints the names a
completion script needs and does not list itself.

| Mode | Short | What it does | Mutating |
|---|---|---|---|
| `--full` | `-f` | core + plugins + themes + database schema + optimize/repair + cron (+ Astra if licensed) | yes |
| `--core` | `-c` | `core update`, `core update-db --skip-plugins` | yes |
| `--plugins` | `-p` | update all plugins, or the enumerated set with `--only-active`/`--exclude-plugins`/`--hold-plugins` | yes |
| `--themes` | `-t` | update all themes, or the enumerated set with `--exclude-themes`/`--hold-themes` | yes |
| `--db-optimize` | `-d` | `db optimize` then `db repair` | yes |
| `--db-fix` | `-x` | `db repair` | yes |
| `--cron` | `-r` | `cron event run --due-now` | yes |
| `--astra` | `-s` | Astra add-on update, activating the licence if needed | yes |
| `--list-plugins` | `-l` | plugin inventory as table, JSON, CSV or TSV | no |
| `--plugin-manage` | `-m` | activate / deactivate / delete one plugin (delete needs `--yes` or a terminal) | yes |
| `--verify` | | `core verify-checksums` and `plugin verify-checksums --all` | no |
| `--health` | | core version, pending plugin/theme updates, database size, and the CVE-2026-119977 verdict | no |
| `--secrets` | | secret constants in `wp-config.php` by name, permissions, stale copies | no |
| `--security` | | read-only CVE-2026-119977 assessment: each site's core version against the fixed releases, as a table or as JSON Lines | no |
| `--harden` | | append the marked deny block for `wp-content/upgrade/` to each site's `.htaccess`, then print the nginx directive | yes |
| `--list-backups` | | backup files per site, newest first | no |
| `--restore-db FILE` | | import FILE into the database (needs `--yes`) | yes |
| `--check` | | environment plus every site in the list, changes nothing | no |
| `--status` | | last run summary and log sizes | no |
| `--doctor` | | host diagnosis, no site list needed | no |
| `--completion SHELL` | | print a bash or zsh completion script | no |
| `--list-sites` | | the resolved site list and exit | no |
| `--list-modes` | | mode names, one per line (for shell completion) | no |

## Selection

| Option | Meaning |
|---|---|
| `-S, --site PATH` | operate on one site, overriding the site list |
| `--sites FILE` (`--sites-file`) | site list, one absolute path per line (default: `<script dir>/wp-found.txt`) |
| `--max-sites N` | process at most N sites (0 = all) |
| `-j, --jobs N` | process N sites per batch (1 = sequential) |
| `-u, --user NAME` | force the system user for every site, skipping owner detection |
| `--default-user NAME` | fall back to NAME when ownership cannot be determined |
| `-U, --url URL` | pass `--url` to every call (multisite); otherwise derived from `wp-config.php` |
| `--no-url-detect` | never derive `--url` |

`-j N` is a batch barrier, not a continuous pool: bash 4.2 has no `wait -n`, so the next
batch starts when the slowest site of the current one finishes. Per-site output and log
lines are replayed in site order at the barrier, so `tail -f` looks stalled until it lands.

## Fleet control

| Option | Default | Meaning |
|---|---|---|
| `--retry N` | `0` | re-run a failed site up to N extra times |
| `--retry-delay SEC` | `15` | wait between attempts |
| `--max-failures N` | `0` | stop the fleet after N failed sites (0 = never) |
| `--run-timeout SEC` | `0` | total time budget; the rest of the fleet is skipped, not failed silently |
| `--lock-wait SEC` | `0` | wait for another run's lock instead of failing at once |
| `--skip-if-no-updates` | off | skip sites whose core, plugins and themes are current (`--core`, `--plugins`, `--themes`, `--full`) |

A retry is worth it for a timed-out download or a busy database lock; it is not worth it for
a wrong `--url`, which is why the default is 0. The circuit breaker exists because a
fleet-wide failure (a broken WP-CLI, a full disk, a network outage) should stop the run
instead of writing the same error 200 times.

## Backups and restore

| Option | Meaning |
|---|---|
| `-b, --backup MODE` | `off` (default), `db` (`wp db export`), `full` (`tar.gz` of the tree) |
| `--no-backup` | never back up, including before a plugin delete |
| `-B, --backup-dir DIR` | where backups go (default `<script dir>/backups`) |
| `--keep-backups N` | backups kept per site (default 3, 0 = keep everything) |
| `--backup-age-days N` | also drop backups older than N days |
| `--backup-compress` | gzip a database dump after export |
| `--min-free-mb N` | refuse to write a dump when free space is below N MiB |

Layout: `<backup dir>/<site directory name>/db-YYYYmmdd-HHMMSS-PID.sql[.gz]`,
`site-...tar.gz`, `plugin-<slug>-...tar.gz`. The dump runs with the per-command timeout
disabled: a truncated dump looks like a backup and is worse than none.

Restore is intentionally awkward:

```bash
wp-cli-update --list-backups --site /var/www/example.com
wp-cli-update --restore-db /var/backups/wp-cli-update/example.com/db-20261020-030000.sql --site /var/www/example.com --yes
```

Without `--yes` every site refuses. With it, the manager dumps the live database first,
imports, then runs `wp db check` and reports the result.

## Policy pins

| Option | Effect |
|---|---|
| `--hold-plugins LIST` | a pin: these plugins are never updated, and the log says so |
| `--hold-themes LIST` | the same for themes |
| `--exclude-plugins LIST` (`-e`) | leave them out of `--plugins` / `--full`; implies enumeration, matching is case-insensitive on slug or display name, never a pattern |
| `--exclude-themes LIST` | leave them out of `--themes` / `--full` |
| `--only-active` | update only active plugins that have an update available |

## Security: CVE-2026-119977

Two modes and one configuration key were added in 8.1.0 for the WordPress core race
condition CVE-2026-119977. The advisory itself is on
[Security: CVE-2026-119977](09-Security-CVE-2026-119977).

`--security` is read-only. It reads each site's core version and prints a table with
`SITE`, `CORE`, `CVE` and `STATUS` columns, where the CVE column carries the verdict
`safe`, `UPDATE` or `?` and `STATUS` names the release to reach (`-` when the site is
safe). With `--json-lines` it emits one `{"type":"security",...}` object per site instead.
It exits 1 when at least one site needs an update or its version cannot be read, and 0 when
every site is at or above the fixed release for its branch. It takes no lock and no
backup, so monitoring may call it as often as it likes.

`--harden` is a writing mode. It appends a marker-guarded block to each site's root
`.htaccess`, which is read by Apache and LiteSpeed:

```apache
# BEGIN Bash WP-CLI Update - deny web access to wp-content/upgrade/ (CVE-2026-119977)
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteRule ^wp-content/upgrade/ - [F,L]
</IfModule>
# END Bash WP-CLI Update - deny web access to wp-content/upgrade/
```

It copies an existing `.htaccess` once to `.htaccess.wp-cli-update.bak`, is idempotent (a
file that already carries the markers is left alone), and prints the directive nginx needs
at the end of the run, because nginx never reads `.htaccess`. It takes no database backup:
one file is copied before it is edited.

| Option | Meaning |
|---|---|
| `--harden-upgrade-dir` | apply the deny block during any writing mode (same as `HARDEN_UPGRADE_DIR=1`) |
| `--no-harden-upgrade-dir` | disable `HARDEN_UPGRADE_DIR` for one run |
| `HARDEN_UPGRADE_DIR` | configuration key, boolean, default `0` |

A read-only mode (`--security`, `--health`, `--check`) refuses both flags with exit 2:
it never modifies a site. The per-site remediation line and the fleet command are in
[Operations](05-Operations), together with the nginx directive.

## Plugin listing and completion

`--list-plugins` renders a table, JSON, CSV or TSV through `--format`, with `-J` as the short
form of `--format json` inside this mode; `--fields` chooses the columns and `--page-limit N`
caps the rows. In machine-readable formats stdout carries the payload and nothing else.
Outside `--list-plugins`, `-J` means `--json-lines`: one object per site plus a summary. The
dual meaning is resolved once, after all mode flags are parsed, so `--json -l` and `-l --json`
agree.

```bash
wp-cli-update --completion bash > /etc/bash_completion.d/wp-cli-update
wp-cli-update --list-modes
```

Next: [Configuration](04-Configuration) for the keys behind these options.
