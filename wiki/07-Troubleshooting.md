# Troubleshooting

## Symptom, real cause, action

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

The first two share a code but not a cause: "must run as root" is a privilege problem,
"another run holds" is a lock problem. Read the message, not the number.

## Diagnosis paths

`--doctor` answers "why would a run fail before it starts", needs no site list and changes
nothing:

```bash
sudo wp-cli-update --doctor
```

It reports the `wp` binary it will use, the user-switch mechanism, the optional tools,
the paths, the free space, the configuration permissions and the policy actually in force.
A wrong `WP_CLI_PATH` is an environment error (exit 3) by design: there is no silent
fallback to `PATH`.

`--secrets` answers "what is in `wp-config.php`" without printing a value:

```bash
sudo wp-cli-update --secrets --site /var/www/example.com
```

It lists secret-bearing constant **names**, flags a world-readable `wp-config.php`, and
reports stale copies (`.save`, `.bak`, `.old`, `.env`) as findings. It exits 1 only for a
real defect. Do not edit `wp-config.php` while a run is in progress: `--secrets` will then
report the leftover copy and nobody will know which file is real.

`--print-config` answers "what is actually in force", with the layer that produced each
value. Use it before blaming the code, and after anyone says they changed something
"temporarily".

## The licence handoff gotcha

The Astra licence is never an argument of any process. It is read from
`WP_CLI_UPDATE_LICENCE`, `ASTRA_KEY` or `ASTRA_LICENSE_KEY`, or from the first readable
file among `./astra.key`, `/etc/wp-cli-update/astra.key` and `$HOME/.astra.key`, and it is
redacted as `<licence>` in every log line, dry-run listing and error box.

"licence arrived empty" therefore means the child shell, running as the site owner, could
not read the key file — not that the key is wrong. Either set
`WP_CLI_UPDATE_LICENCE` for that one invocation, or fix the key file's mode and owner. Do
not paste the key onto the command line: it would land in `ps` for the duration of the
call, which is the one thing this design exists to prevent.

## Backup and disk-guard refusals

A missing backup has two causes and the log distinguishes them:

* `BACKUP=off` (the default) — nothing was requested. `--backup db` or `BACKUP=db` asks for
  one.
* the disk guard refused — the log says "refusing to export", with the free space and the
  configured `MIN_FREE_MB`. The guard runs *before* the export, not after it failed. Free
  space first; lowering `MIN_FREE_MB` on a full disk only moves the failure into the
  filesystem.

A failed backup stops the site instead of updating it unprotected. That is the designed
behaviour, not a bug, and `--fail-on never` is the wrong way to get past it.

## Multisite

`--url` is derived from `WP_HOME` / `WP_SITEURL` in `wp-config.php` when it is not given on
the command line, which is what lets WP-CLI pick a site on a multisite install. If a site's
`wp-config.php` names a URL you do not want to operate on, pass `-U, --url URL` explicitly
or set `URL` in the configuration; `--no-url-detect` turns the derivation off.

## Absolute do-nots

* Do not `source` the config, add shell to it, or template it with `envsubst` into a place
  the manager reads while a run is in progress.
* Do not put the licence in `argv`, in a cron line, or in the config when
  `WP_CLI_UPDATE_LICENCE` will do.
* Do not edit `wp-config.php` while a run is in progress.
* Do not delete `.no_wp_cli` markers, lock files of active runs, or backups.
* Do not run `--restore-db` without a reason and without `--yes`; it overwrites a live
  database.
* Do not run the test suite as root just to make the user-switch checks pass.
* Do not change `FAIL_ON`, `JOBS` or `BACKUP` "temporarily" and forget it.

Never silence a failure with `--fail-on never`: it hides the site from monitoring and from
the report. Stop the fleet honestly with `--max-failures` instead, and see
[Exit codes](06-Exit-Codes) for what each code commits you to.
