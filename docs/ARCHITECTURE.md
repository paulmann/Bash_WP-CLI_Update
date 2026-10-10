# Architecture

Two products, one build. The repository keeps its "copy one file to the host"
installation story — the artifacts at the root are single, standalone bash
scripts — while the sources are modules of a few hundred lines that can be
reviewed, linted and tested in pieces.

```
src/manager/01-bootstrap.sh   shebang+guards, PATH/LC_ALL/umask, identity, exit
                              codes, CONFIG_SPEC (the single settings table)
src/manager/02-util.sh        pure helpers: trim/paths/json/csv/quoting, version
                              compare, HTTP (curl|wget), sinks, table & JSON
                              readers (jq optional, built-in fallback)
src/manager/03-color-log.sh   colour policy, logging (text|json), redaction,
                              rotation, syslog, error detail/box
src/manager/04-config.sh      fatal helpers, validate_value (one validator,
                              three exit codes), file-as-data parser + perms,
                              env layer, apply, --print-config, --init-config
src/manager/05-runtime.sh     mutable state (counters, units), lock, traps,
                              temp registry, run budget
src/manager/06-secret.sh      licence resolution (CLI/config/env/key files),
                              redaction registration, stdin|file handoff,
                              child_argv wrapper builder
src/manager/07-user.sh        user switch (runuser→sudo→su, positional argv),
                              owner resolution, child environment, --allow-root,
                              privilege preflight
src/manager/08-wpcli.sh       wp resolution, install-kind detection, version
                              policy (floor+currency), self-update (wp cli
                              update | verified direct download), rollback
src/manager/09-wp-exec.sh     THE invocation point: argv assembly, timeout
                              (GNU | perl supervisor), merged|stdout capture,
                              run_wp/run_wp_soft/info_wp/wp_data/wp_probe,
                              read-only classification for --dry-run
src/manager/10-inventory.sh   site list parsing (TAB owner column), filters,
                              discovery, work units + multisite expansion,
                              wp-config readers, --list-sites
src/manager/11-backup.sh      backup dirs/ownership, free-space guard, db/tree/
                              plugin archives, pruning, --restore
src/manager/12-modes.sh       the maintenance modes (full/core/plugins/themes/
                              languages/cache/cleanup/db/cron/astra/verify)
src/manager/13-plugins.sh     plugin inventory & management, data_sink
src/manager/14-audit.sh       --report, --security (findings+score), --secrets,
                              --check, --status
src/manager/15-report.sh      JSON Lines, run document, state file, Prometheus
                              metrics, notifications, summary, exit-code policy
src/manager/16-cli.sh         MODE_TABLE, help, LONG_OPTIONS, completion,
                              parse_args, validate_args
src/manager/17-fleet.sh       report buffer, maintenance mode, smoke test,
                              per-unit pipeline, sequential & batched-parallel
                              fleet, worker protocol & fold
src/manager/18-main.sh        startup checks, banner, main()

src/finder/01..06             discovery: bootstrap, log, scan (find -prune
                              expression), output (paths/tsv/csv/json, manifest,
                              audit, verify-list), CLI, main

tools/build.sh                fork-free concatenation + in-shell parse check
tools/scan-secrets.sh         repository secret scanner (work tree + history)
tools/install.sh              PREFIX-based installer
tests/                        nine suites + stub wp + harness
```

## Build

`tools/build.sh` concatenates the modules in numeric order, lifts the shebang
of module 01 to byte one, inserts a generated-file notice, substitutes the
build stamp, and parse-checks the result **without forking**: the whole file is
wrapped in a function definition and `eval`ed — bash parses every line and
executes none. `--check` rebuilds and diffs against the committed artifact
(ignoring the stamp line) so CI can prove the sources and the artifact agree.

Editing an artifact directly is always wrong; `make check` will say so.

## Data flow of a fleet run

```
main
 ├─ config_init_defaults → parse_args → config_load (file<env, CLI wins)
 │   → config_apply (validate ALL effective values) → validate_args
 ├─ inspection exits: --list-modes/--completion/--version-detail/--init-config/
 │   --print-config/--list-sites/--wpcli-* / --status / --check
 ├─ startup_checks (wp resolution, version floor, capability warnings)
 ├─ load_site_list → units_build (filters → owners → multisite expansion)
 ├─ privilege_preflight → lock_acquire → banner
 ├─ run_fleet
 │    sequential: for each unit → process_unit
 │    batched:    worker_run &  (fork) → fragments {out,log,data,rows,res}
 │                wait → fold_worker (counters, ordered replay)
 │    process_unit: backup → maintenance on → dispatch_mode → maintenance off
 │                  → retry? → smoke test → status/record
 └─ report_finish → finish_run: exit-code policy → summary (stderr)
      → state file + metrics (atomic) → notification → exit
```

**Work unit.** The fleet iterates units `(path, user, url, label)`, not paths.
Multisite expansion (`MULTISITE=all`) and per-line owners are properties of the
unit; every mode function takes `(site, user, url)`.

**Parallel contract.** A worker owns its counters (zeroed on entry, written to
`res` on exit); the parent folds them after the barrier and replays
`out`/`log`/`data`/`rows` in site order. Anything a parser consumes is emitted
by the parent, never by a worker — that invariant is why `--format json -j 4`
stays parseable.

## The fork discipline

A 200-site run performs ~30 WP-CLI calls per site plus logging per call. Every
avoidable `$(...)`, `date`, `basename` and `cat` on those paths was a process:
the run measured in thousands of forks and, at the extreme, stopped working on
a host at its process limit — exactly the host where maintenance matters. The
rules now:

1. Hot-path helpers publish **globals** (`trim`→`TRIMMED`, `redact`→`REDACTED`,
   `json_escape`→`JSON_ESCAPED`, `path_base`→`PATH_BASE`, `now_epoch`→
   `EPOCH_NOW`, `data_sink`→`DATA_SINK`, …) and may additionally print for
   cold callers.
2. Time comes from `printf '%(…)T'` (builtin), never `date`.
3. Log rotation tracks the file size in memory; `stat` runs at init and after
   a rotation, not per line.
4. JSON slurps use `read -r -d ''`, not `$(cat)`.
5. `basename`/`dirname` are parameter expansions.
6. Sinks never use `/dev/stdout` (unportable: ENXIO when fd 1 is a socket,
   absent without /proc): an empty sink string means "no redirection".
7. The build creates no processes at all.

Cold paths (once per run: summaries, reports, status) may fork normally;
readability wins there.

## Design rules for changes

1. No command is built by string concatenation; the user switch is the only
   shell-parsed string and it is positional.
2. `printf %q` never feeds `sh -c`, `su -c` or `ssh`.
3. Secrets: never argv of this process; redact every outgoing string.
4. Config is data: whitelist, metacharacter rejection, permission mask.
5. Exit codes are a contract (0/1/2/3/4/5/6), including for `--help`.
6. A failing site never aborts the fleet (unless `--fail-fast`).
7. Destructive work is opt-in, enumerated, validated and backed up.
8. Read-only classification (`wp_is_readonly`) is an allowlist: unknown =
   mutating. `--dry-run` must never lie in either direction.
9. New setting ⇒ one `CONFIG_SPEC` row (defaults, validation, docs, completion
   follow automatically). New mode ⇒ one `MODE_TABLE` row + one function + one
   `dispatch_mode` branch; the test suite fails if any of the three is missing.
10. Bash 4.2 floor: no namerefs, no `wait -n`, no `mapfile -d`, no `${v@Q}`.
