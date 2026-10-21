# Three-way comparison: `main`, `QWEN_Hybrid`, `DeepSeek_Hybrid` → 8.0.0

This document records how 8.0.0 was assembled, what was taken from which branch, and
what was deliberately left out. It is the answer to "why does this file look like
that", so a future reader does not have to repeat the comparison.

## 1. Method

* Cloned the repository and checked out the three lines of work:
  `origin/main`, `origin/QWEN_Hybrid`, `origin/DeepSeek_Hybrid`.
* Measured each tree: file list, size, line count, function inventory, and a keyword
  census for the mechanisms that matter here (config parsing, locking, backup,
  timeouts, JSON, retries).
* Ran the same behavioural test suite against the current tree, then against each
  candidate, to see which branch's behaviour was actually better rather than which one
  read better.
* Built 8.0.0 on the QWEN lineage (the current code, plus local fixes present in `6.4/`)
  and ported the DeepSeek ideas that measured better.

The local `6.3/` and `6.4/` directories are frozen snapshots of the two branches used
for this comparison; they are inputs, not part of the product.

## 2. The three baselines

| | `main` (6.0) | `QWEN_Hybrid` (6.2.0) | `DeepSeek_Hybrid` (6.1.0) |
|---|---|---|---|
| Manager size | 59 084 B | 136 257 B | 98 752 B |
| Manager lines | 1 569 | 3 344 | 2 689 |
| Functions (definitions) | ~24 | ~110 | ~90 |
| Files in the tree | 4 | 24 | 13 |
| Test suites | none | 6 suites + harness + stub `wp` | 1 suite (`compat_test.sh`) |
| Secret scanner | no | `tools/scan-secrets.sh` (19 695 B) | `tools/scan-secrets.sh` (9 883 B) |
| Verify helpers | no | — | `verify.sh`, `verify_build.sh` |

## 3. Feature matrix

`yes` = implemented and reachable from the command line; `part` = present but not
reachable or not covered by a test; `no` = absent.

| Capability | main | QWEN | DeepSeek | 8.0.0 |
|---|---|---|---|---|
| Ten original modes | yes | yes | yes | yes |
| Plugin listing as table/JSON/CSV/TSV | part | yes | part | yes |
| Configuration is data (never sourced) | no | yes | no (a bash snippet by design) | yes |
| Config: unknown keys reported, metacharacters rejected | no | yes | no | yes |
| Config: group/world-writable file refused | no | yes (local fix) | no | yes |
| Lock | no | yes (`flock`, pid-file fallback) | yes | yes (+ `--lock-wait`) |
| Per-command timeout | no | yes (+ perl supervisor when `timeout(1)` is absent) | yes | yes |
| Backup `db` / `full` | no | yes | yes | yes |
| Backup retention | — | count | count | count + age + compression |
| Restore from a dump | no | no | no | **yes** (`--restore-db`, `--list-backups`) |
| Disk guard before a dump | no | no | no | **yes** (`--min-free-mb`) |
| Parallel batches | no | yes | yes | yes |
| JSON Lines fleet report | no | yes | yes | yes |
| JSON run report file | no | no | no | **yes** (`--report`) |
| Structured (JSON) log lines | no | no | no | **yes** (`--json-log`) |
| Notifications | no | no | no | **yes** (webhook + mail) |
| `--health` | no | no | `part` (delegates to the status printer) | **yes** (per-site inventory) |
| `--secrets` | no | no | yes | yes (masked, plus permission findings) |
| `--doctor` | no | `part` (`--check` covers sites only) | `part` (`preflight`) | **yes** |
| Shell completion | no | `--list-modes` only | `--list-modes` only | **yes** (`--completion bash|zsh`) |
| Retry a failed site | no | no | no | **yes** |
| Circuit breaker | no | no | no | **yes** (`--max-failures`) |
| Total run budget | no | no | no | **yes** (`--run-timeout`) |
| Skip sites with nothing pending | no | no | no | **yes** (`--skip-if-no-updates`) |
| `--url` from `wp-config.php` | no | no | yes | yes (`--no-url-detect` to turn off) |
| Multisite awareness | no | `part` (manual `--url`) | yes | yes |
| Theme exclusion / plugin pinning | part (`--exclude`) | `part` (plugins only) | `part` (plugins only) | **yes** (plugins and themes) |
| nice / ionice | no | no | no | **yes** |
| Read-only modes take no lock and no backup | — | no | no | yes |
| Licence never in `argv` | no | yes | no | yes |
| Exit-code contract with 4 = config error | no | yes | part (uses 1) | yes |
| Change log (what actually changed) | no | no | no | **yes** (in the report) |
| Legacy 6.1 config names accepted | — | no | — | **yes** |

## 4. What came from where

From **QWEN_Hybrid** (the base, because it measured better):

* the overall structure: sections, dispatch, one function per concern;
* data-only configuration with metacharacter rejection and unknown-key reporting;
* the licence handoff through a group-restricted temporary file;
* flock with a pid-file fallback, the temporary-file registry and the EXIT trap;
* the fleet worker with per-worker fragments replayed in site order;
* table/JSON/CSV/TSV rendering without `jq`;
* `--plugin-manage`, `--verify`, `--check`, `--status`, `--print-config`.

From the local `6.4/` snapshot (fixes made after 6.2.0 was published):

* the config permission check (group-writable is as bad as world-writable);
* octal-safe integer validation and `norm_uint` (`08` is not a bash number);
* the perl timeout supervisor for hosts without `timeout(1)`;
* `SITE_ENVV` as an array instead of a line protocol (a newline in a path broke it);
* `log_note` for missing optional tools, so `--strict` stays satisfiable on a minimal
  host.

From **DeepSeek_Hybrid**:

* `--secrets`: the idea and the finding shape — names, never values;
* `--health`: the idea of a read-only inventory separate from `--status` (last run);
* `--url` detection from `WP_HOME`/`WP_SITEURL`, and the multisite warning;
* `wp_probe`-style "count this call as neither success nor failure" (already present in
  QWEN as `info_wp`/`wp_soft`, kept);
* the short options `-u`, `-C`, `-T`, `-L`, `-k` that operators already have in muscle
  memory;
* the human duration in the summary.

## 5. What was rejected, and why

| Candidate | Why it was not merged |
|---|---|
| DeepSeek's configuration format (`: "${VAR:=default}"`, sourced as bash) | It is code execution with root privileges: one writable bit, or one `$( )` in a value, and the file runs. QWEN's parser rejects metacharacters and unknown keys instead. `tests/test_fleet.sh` proves the rejection. |
| DeepSeek's `verify.sh` / `verify_build.sh` | They duplicate what the test suites already prove, and they cannot be run from CI without a WordPress tree. The suites are portable; the helpers were not. |
| DeepSeek's `--health` implementation (calls the status printer) | It reports the last run, not the current state, and conflates two different questions. 8.0.0 answers the state question and leaves `--status` for the history. |
| QWEN's `-J` overloading (`--json` meaning two things) | Kept for compatibility, but the ambiguity is resolved once, in `validate_args`, and documented. It is the only overloaded flag. |
| `main`'s monolithic mode bodies | No dispatch table, so the retry loop and the circuit breaker could not be added without duplicating 10 branches. `run_mode` exists for that reason. |
| Retry on by default | A retry hides a real failure for as long as the delay allows and doubles the time a broken fleet takes to fail. Default 0; the operator decides. |
| `--fail-on never` as a way to "keep going" | It hides failures from the report and from monitoring. `--max-failures` stops the run honestly instead. |

## 6. Defects found and fixed while merging

| Defect | Where | Fix |
|---|---|---|
| A read-only mode exported a database when `--backup db` was set | QWEN/DeepSeek | `mode_is_readonly`; read-only modes skip the backup and the lock |
| A failed backup still updated the site when `--fail-on never` was set | QWEN | the site is stopped and reported unless the operator asked for `never` |
| `duration` printed twice in the summary | local 6.4 edit | printed once, `1m 12s (72s)` |
| The change log (and the report) could be lost on interrupt | new code | the summary runs before `tmp_cleanup` in the EXIT trap |
| `wp plugin list --format=count` is not universal; digit-stripping a table produced a plausible nonsense number | new code | count the rows of a name-only CSV instead |
| `--health` emitted two JSON objects per site | new code | the health object replaces the generic site record in that mode |
| A group-writable config file was accepted | 6.2.0 | `config_perm_is_unsafe` rejects `022` |
| Leading-zero integers (`08`) died with "value too great for base" | 6.2.0 | `10#` in comparisons, `norm_uint` after validation |
| A missing `timeout(1)` silently disabled the bound | 6.2.0 | perl supervisor, else a `log_note` |

## 7. What all three had forgotten (now added)

Checked against the questions an operator actually asks during an incident:

1. "What would change if I ran it now?" → `--health`.
2. "Which of these keys is already in a config?" → `--secrets`, `--doctor`.
3. "We took a backup — how do we get it back?" → `--list-backups`, `--restore-db`.
4. "The run died at site 30 of 200, what now?" → `--report`, retries, `--max-failures`,
   `--run-timeout`, a partial summary on SIGINT.
5. "A plugin must not move" → `--hold-plugins`, `--hold-themes`.
6. "Do not fill the disk" → `--min-free-mb`, `--backup-age-days`, `--backup-compress`.
7. "Do not starve the web server" → `--nice`, `--ionice`.
8. "Tell me when it fails" → `--notify`, `--mail-to`.
9. "Let cron skip the 180 sites that are current" → `--skip-if-no-updates`.
10. "Two runs overlapped" → `--lock-wait`.
11. "The multisite half of the fleet fails" → `--url` detection.
12. "I upgraded from 6.1 and my timeout vanished" → accepted legacy names.
13. "Type the mode names for me" → `--completion`.

## 8. Verification

| Check | Result |
|---|---|
| `bash -n` on every shell file | clean |
| `shellcheck` (0.9 on the Debian test host, 0.11 gate in CI) | clean, with `SC2329,SC2317` disabled file-wide and justified |
| `bash tests/run_tests.sh` on Debian 12 as root (`unshare -r`) | 634 checks, 0 failures, 7 skips |
| `bash tests/run_tests.sh` on the Windows Git Bash host (non-root) | 0 failures outside the checks that need root; `chmod`, `ionice` and user-switch checks skip |
| `tests/test_v7.sh` | 113 checks (111 on a host without `ionice`) |
| Static gates | no `eval`, no backticks, no `printf %q`, no `su -c`, no `"${arr[@]:-}"`, no CRLF, no e-mail addresses, no site-specific plugin list |
| Version consistency | `SCRIPT_VERSION`, `README.md` and `CHANGELOG.md` agree |

## 9. What is still open

* `Find_WP_Senior.sh` was not rewritten: it is a separate tool with its own suite, and
  6.2.0's version (2.1.0) already passes the contract tests.
* Continuous parallelism (a real pool with `wait -n`) needs bash 4.3+; the floor is
  4.2, so the batch barrier stays. It costs at most one slow site per batch.
* Email notification uses `mail(1)`; a host without it logs a note and moves on, it does
  not fail the run. A SMTP client would be a new dependency for one feature.
