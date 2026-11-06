# Exit codes

The exit code is a contract, not a side effect. A cron job has to be able to tell "you
typed it wrong" from "the update failed", so `2` and `4` are never collapsed into `1`.

## The contract

| Code | Meaning | What it means operationally |
|---|---|---|
| `0` | success | with `--fail-on any`: every operation on every site succeeded |
| `1` | operational error | at least one WP-CLI operation or site failed; read `.sites` and `.changes` in the report |
| `2` | usage error | bad command line: unknown option, missing value, two modes, a mode-restricted flag with the wrong mode |
| `3` | environment error | bash too old, `wp` missing or not executable, lock held, not root without a read-only mode |
| `4` | configuration error | unreadable config, group- or world-writable config, a shell metacharacter in a line |
| `130` | interrupted | SIGINT (Ctrl-C): a partial summary is printed and the JSON report is still written |
| `143` | terminated | SIGTERM (systemd stop, `timeout`): same partial summary and report |
| `131` | hangup | SIGHUP: the session went away |

The distinction matters on a schedule: exit 3 on a nightly host usually means the site list
or the `wp` path moved, exit 4 means somebody edited the configuration, and neither is a
WordPress problem.

## `--security`: exit 1 is a verdict, not a crash

`--security` is read-only, so its exit code is the answer rather than a report of work:

| Code | Meaning |
|---|---|
| `0` | every site is at or above the fixed release for its branch (CVE-2026-119977) |
| `1` | at least one site is below the fixed release, or its core version cannot be read |
| `2` | usage error, for example `--security` with `--harden-upgrade-dir`, which a read-only mode refuses |
| `3` | environment error: `wp` missing or not executable, or no site list to work from |

An unreadable version is a failure, not a pass: `?` in the table and `UNKNOWN` in the
status column mean the tool could not prove the site safe, and a false "safe" is the
expensive error. Because the code composes with the usual policy, `--fail-on never` turns
the verdict back into `0` — do not use it on a gate.

## `--harden` returns 1 when it cannot write

`--harden` edits one file per site, the root `.htaccess`. A site whose file cannot be
backed up or written is counted as a failed site and the run exits 1 under the default
`--fail-on any`, with the path and the reason in the log. The failure is deliberately not
swallowed: a site that was meant to be hardened and was not is the one an operator needs
to hear about. When the same block is applied by `--harden-upgrade-dir` during a writing
mode, the failure is a warning instead — the update proceeds, because refusing to update a
site over a read-only `.htaccess` would be the wrong trade.

## `--fail-on`: when a partial fleet run is a failure

| Value | Exits non-zero when | Right for |
|---|---|---|
| `any` (default) | at least one site failed | cron alerts: one bad site is still bad |
| `all` | every site failed | best-effort jobs, where one failure out of forty is acceptable |
| `never` | never | parsing the log yourself; it hides the site from monitoring, so do not use it to silence a failure |

## `--strict`: warnings count

`--strict` (or `STRICT=1`) makes the run exit non-zero when anything was warned about, not
only when something failed. It applies to an empty fleet as well: "processed zero sites" is
exactly the silent failure a cron job needs to shout about, so the no-work path consults
`final_exit_code` too.

## What an interruption does

`SIGINT`, `SIGTERM` and `SIGHUP` are trapped. On any of them the manager prints a partial
summary, writes the JSON report and only then removes its temporary files: the summary and
the report run before `tmp_cleanup` in the EXIT trap, so the change list survives. An
interrupted run therefore exits `130`, `143` or `131` with real counters rather than an
empty report.

The shipped systemd unit is built around that: `KillSignal=SIGTERM` with `KillMode=mixed`,
because a partial summary and the JSON report are worth more than a clean kill.

## Reading the code without reading the console

```bash
sudo wp-cli-update --full --backup db --report /var/log/wp-cli-update/last-run.json
echo "exit=$?"
python3 -c 'import json,sys; d=json.load(open("/var/log/wp-cli-update/last-run.json")); print(d["run"]["exit"], d["run"]["sites_failed"], len(d["changes"]))'
```

`run.exit` in the report is the code the process returned, so the report and the shell agree
even when the run was wrapped by cron, systemd or `timeout`.

## The finder has its own contract

`Find_WP_Senior.sh` is a separate tool and is not part of this table: it exits `0` when it
found sites, `1` on an operational error, `2` on a usage error, `3` on an environment error
and `5` when nothing was found (`--fail-empty` turns that `5` into `1`). A `5` from
`wp-find` is a finding about the host, not a broken manager.

Back to [Operations](05-Operations), or forward to [Troubleshooting](07-Troubleshooting) for
the symptom that produces each of these codes.
