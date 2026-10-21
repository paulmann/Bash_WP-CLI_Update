# Project map

File-by-file map of the repository, with the direction of every dependency.

**Files: 26** · generated 2026-10-08 · `tests/test_static.sh` verifies the count
against `git ls-files`, so this document cannot go stale silently the way the
auto-generated map of an earlier revision did (it declared 5 files while the
branch shipped 11, in a second language, with a content fingerprint that did not
match its own content).

If you add or remove a file, update the count above and the table below in the
same commit.

## Runtime

| File | Version | Purpose | Depends on |
|---|---|---|---|
| `Bash_WP-CLI_Update.sh` | 6.2.0 | Runs WP-CLI maintenance over every site in the list, each as its owner. Modes, configuration layers, locking, logging, timeouts, licence handoff, rendering. | `Find_WP_Senior.sh` (only when the site list is missing and `AUTO_DISCOVER` is on) · `wp` · `runuser`/`sudo`/`su` · `flock`, `timeout` (optional) |
| `Find_WP_Senior.sh` | 2.1.0 | Scans named web roots for WordPress installations, honours `.no_wp_cli` and exclusions, deduplicates, enriches with metadata, writes the list atomically. | `find`, `sort`, `stat`, `mktemp` |
| `wp-cli-update.conf.example` | — | Every manager setting with its default and the reason it exists. Copy to `/etc/wp-cli-update.conf` or next to the script. | read by `Bash_WP-CLI_Update.sh` |

The two scripts are independent executables: neither sources the other, and the
only coupling is the site-list format (one absolute path per line, no header, no
trailing whitespace) and the `--output` / `--sites` flags.

## Tooling

| File | Version | Purpose | Depends on |
|---|---|---|---|
| `tools/scan-secrets.sh` | 1.1.0 | Looks for credential literals in the working tree and, with `--history`, in every reachable commit. Masks values by default, prints a fingerprint, classifies benign hits, exits 1 under `--strict`. | `git` (only for `--history`) · `sha256sum` or `cksum` |
| `tools/secret-allowlist.txt` | — | Known-benign lines, as `path-glob\|line-substring\|reason`. Never scanned itself, because it quotes the shapes it documents. | read by `tools/scan-secrets.sh` |

## Tests

| File | Purpose | Depends on |
|---|---|---|
| `tests/run_tests.sh` | Runs every suite, prints the environment it found, tallies all suites, exits non-zero on any failure. Accepts suite names as arguments. | `tests/test_*.sh` |
| `ANALYSIS.md` | Audit of the **original** `main` code: every defect with a line citation, the reproduced command-injection proof of concept, what was verified and is *not* a defect, and the residual limitations of the replacement. | `legacy/` |
| `REFACTORING.md` | What v6.2.0 took from each of the five revisions, what it rejected and with which measurement, and the fourteen defects found while integrating. | `ANALYSIS.md`, `tests/` |
| `legacy/Bash_WP-CLI_Update.v5.0.sh` | Byte-exact copy of `main:Bash_WP-CLI_Update.sh`, verified with `git hash-object`. Executed by nothing. Exists so that citations in `ANALYSIS.md` stay checkable without git history and so that rollback does not depend on git. | — |
| `legacy/Find_WP_Senior.v1.01.sh` | Byte-exact copy of `main:Find_WP_Senior.sh`. Same reason. | — |
| `legacy/README.md` | Why the archive exists, and a do-not-fix notice: the known defects are left exactly as they were. | — |
| `tests/test_fleet.sh` | The fleet-wide surface: `--no-user-switch`; `-j N` measured against a sleeping stub (5 s sequential vs 1 s at `-j 5`, 3 s at `-j 2`); counters identical at `-j 1/2/3/5`; console order and log contiguity; a failing site inside a batch; a worker killed with SIGKILL; leaked worker directories; `--backup db\|full` and rotation; an impossible backup destination; plugin-deletion backup and deactivation; `--verify` issues no mutation; `--only-active` and `--exclude-plugins`; `--strict`; JSON Lines shape, ordering and purity; `--list-sites`; `--url`; the configuration layers for the new keys; every shell metacharacter in a config file. | `tests/harness.sh` |
| `tests/harness.sh` | Shared harness: file-backed counters (so a check inside a pipeline still counts), the synthetic WordPress tree, the stub `wp` installation, environment probes, assertion helpers, SKIP handling. | `tests/stub/wp` |
| `tests/stub/wp` | Recording stub of WP-CLI. Logs its own argv, cwd, user, the environment contract and whether a licence arrived (length and checksum only, never the value). Answers `plugin list` in table and JSON. | — |
| `tests/test_static.sh` | `bash -n`, ShellCheck cleanliness, LF endings, executable bits, shebang and mode switches, absence of banned constructs, absence of personal data, documentation present and version-consistent, project map not stale. | `shellcheck` (SKIPs without it) |
| `tests/test_base_contract.sh` | The public surface of the **original** scripts: all ten modes and their short forms, documented options, exit-code contract, `.no_wp_cli`, paths with spaces, the `DOCUMENT_*` environment contract, CRLF lists, and that no scan exceeds the requested roots. | `tests/harness.sh` |
| `tests/test_finder.sh` | Detection rule, exclusions, depth, deduplication, four output formats (JSON and CSV validated with a real parser), atomic write and permission preservation, `--status`, `--skip-existing`, empty-result exit code, stdout/stderr separation. | `tests/harness.sh` |
| `tests/test_manager.sh` | Per-mode argv, `--skip-plugins` and `--allow-root` policies, dry run, four list formats, `--fields`, `--name` filtering, slug resolution, ambiguity refusal, delete confirmation, injection attempts, licence containment, `--check`, `--status`, failure counting, `--fail-on`, timeouts, concurrency, stale locks, config precedence, config rejection, log rotation, colour policy, no writes into the repository. | `tests/harness.sh` |
| `tests/test_secretguard.sh` | Planted values in five name conventions, masking by default, `--strict`, the allowlist, `--history` for a value that was committed and then removed, false-positive classes, `--min-length`, `--quiet`, target arguments. | `tests/harness.sh`, `git` (SKIPs without it) |

## Documentation and repository hygiene

| File | Purpose |
|---|---|
| `README.md` | Operator documentation: quick start, modes, exit codes, configuration precedence, discovery rules, safety features, tests, cron examples. |
| `CHANGELOG.md` | Keep a Changelog. User-facing; an internal agent log is not a changelog. |
| `AGENT.md` | Binding rules for anyone changing these scripts, with the reason each rule exists and a definition of done. |
| `PROJECT_MAP.md` | This file. |
| `.gitignore` | Generated and local files: the site list, logs, lock files, key files, editor and OS droppings. |
| `.gitattributes` | Line-ending policy. The scripts run on Linux; a CR byte becomes part of the last word on every line and silently breaks pattern matching, `case` labels and the generated site list. |
| `LICENSE` | MIT. |

## Data flow

The manager grew a fleet layer on top of the per-site one in v6.2.0:

```
parse_args → validate_args → config_load → config_apply_all → validate_args
   │
   ├─ --list-modes / --print-config / --list-sites … inspect and exit
   │
   └─ log_init → lock_acquire → ensure_site_list → load_site_list
        → resolve_site_users → run_fleet
             ├─ run_sequential            (JOBS == 1)
             └─ run_batched               (JOBS > 1)
                  worker_init → worker_run & → wait → fold_worker
                       └─ process_site → maybe_backup → mode_* → run_wp
        → print_summary (+ emit_summary_json under --json-lines)
        → final_exit_code
```

Four things a parallel worker cannot do on its own, and where each is handled:

| Problem | Where it is solved |
|---|---|
| a subshell cannot increment a parent counter | the worker zeroes its counters at fork and writes them to `${WORK_DIR}/wN/res`; `fold_worker` adds them up |
| concurrent sites interleave on the terminal | the worker's stdout is a fragment; the parent replays fragments in site order at the barrier |
| concurrent sites interleave in the shared log file | `log_write_file` appends to the fragment while `PARALLEL=true`; the parent appends fragments in order |
| a machine-readable payload must stay parseable | `render_plugin_table` and `emit_site_record` route to the fragment whenever the output is machine-readable |

```
Find_WP_Senior.sh --output FILE [ROOT ...]
        |
        |  one absolute path per line, atomic write, permissions preserved
        v
   wp-found.txt  <----------------------------- edited by hand, or --skip-existing
        |
        |  --sites FILE (or SITES_FILE, or the default next to the script)
        v
Bash_WP-CLI_Update.sh MODE [options]
        |
        |  per site: owner resolved from wp-config.php owner -> directory owner
        |            -> DB_USER, validated against the passwd database
        v
   runuser -u OWNER -- /bin/sh -c 'cd -- "$1" || exit 127; shift; exec "$@"' sh SITE \
        env DOCUMENT_URI=... DOCUMENT_ROOT=... HOMEDIR=... HTTP_HOST=... HOME=... \
        [timeout --signal=TERM NNN -k NN] wp --path=SITE [--allow-root] \
        [--skip-plugins=...] SUBCOMMAND ...
        |
        +-> stdout+stderr captured per call -> counters, console, manager.log
        +-> failures additionally -> errors.log with context, command and output
        +-> summary -> <log>.state, read back by --status
```

## Configuration layers

```
defaults (in the script)
   ^  overridden by
/etc/wp-cli-update.conf
   ^  overridden by
<script dir>/wp-cli-update.conf      (or the file named by --config)
   ^  overridden by
WP_CLI_UPDATE_<KEY> in the environment
   ^  overridden by
the command line
```

`--print-config` prints the result of that stack together with the winning layer
for each key. Values from a file or the environment are validated *before* the
merge (exit 4), values from the command line after it (exit 2), so the exit code
tells the operator which file to open.
