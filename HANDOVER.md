# Handover: Bash WP-CLI Update 7.0.1 — status and verification log

Date: 2026-10-11 · Branch base: `QWEN_Hybrid` (v6.2.0) · Result: **v7.0.1 manager / v3.0.0 finder**
(7.0.1 is the defect-fix round over 7.0.0 — see "The 7.0.1 round" below and
`CHANGELOG.md`; the finder's behaviour is unchanged, its modules only gained
`# shellcheck shell=bash` directives.)

## What is in `/home/user/project`

```
Bash_WP-CLI_Update.sh      7.0.1  single-file artifact (GENERATED from src/, 9201 lines)
Find_WP_Senior.sh          3.0.0  single-file artifact (GENERATED from src/, 1360 lines)
wp-cli-update.conf.example        annotated reference for all 96 settings
README.md  CHANGELOG.md  CONTRIBUTING.md  LICENSE  Makefile  .editorconfig
.gitattributes  .gitignore        (LF policy enforced)
.github/workflows/ci.yml          build + drift + shellcheck + secrets + 9 suites (+root job)
src/manager/01..18-*.sh           modular sources of the manager
src/finder/01..06-*.sh            modular sources of the discovery tool
tools/build.sh                    fork-free deterministic build, --check drift mode
tools/install.sh                  production installer (PREFIX/CONFDIR/DATADIR..., --dry-run)
tools/scan-secrets.sh             repository secret scanner (work tree + git history)
tools/secret-allowlist.txt        reviewed benign shapes
tests/run_tests.sh                suite runner (rebuilds artifacts first)
tests/harness.sh                  fixtures, counters, stub wiring
tests/stub/wp                     rich WP-CLI stub: records argv; hooks WP_FAIL_CMD,
                                  WP_HANG, WP_NOISY_JSON, WP_MULTISITE, WP_CLI_NEWER,
                                  WP_CORE_UPDATE(+TYPE), WP_BAD_CHECKSUMS, ASTRA_FAIL_SLUG,
                                  WP_STUB_VERSION_FILE, WP_NO_CLI_UPDATE...
tests/pure_check.sh + test_pure.sh        pure-logic checks (<1s inner loop)
tests/test_static.sh                      syntax/lint/CRLF/versions/drift/docs presence
tests/test_cli_contract.sh                help/version/exit codes/suggestions/list-sites/stdin
tests/test_config.sh                      layers, unsafe-file refusal, perm mask, licence
tests/test_manager.sh                     every mode's argv, ordering, failures, dry-run
tests/test_fleet.sh                       -j counters, filters, budget, retry, fail-fast,
                                          backups, state/metrics/notify, lock, multisite, smoke
tests/test_wpcli_policy.sh                floor gate, --wpcli-check/update/rollback (stub phar)
tests/test_finder.sh                      discovery, formats, manifest, audit, verify-list
tests/test_secretguard.sh                 the scanner itself (planted secrets, masking)
docs/CONFIGURATION.md OPERATIONS.md SECURITY.md ARCHITECTURE.md TROUBLESHOOTING.md MIGRATION.md
docs/ops/cron.example wp-cli-update.service wp-cli-update.timer logrotate.example
docs/ops/prometheus-rules.example
legacy/                             historical scripts (reference only)
```

## Requested scope — where each item lives

1. **Full professional refactoring** — modular `src/` + generated single-file
   artifacts; one `CONFIG_SPEC` table drives defaults/validation/env/CLI/docs
   (the 4-list drift class is gone); work-unit model `(path,user,url)`;
   ~30 fixed bugs (table word-splitting, parallel sink routing, per-unit
   counters, json-slice robustness, dead exit-code branch, help duplicates,
   `/dev/stdout` unportability, cwd leak in script-dir resolution, …).
2. **English documentation** — README + 6 docs + ops files + why-comments
   throughout the sources.
3. **DeepSeek_Hybrid ported** — config permission mask (`&022` refusal),
   perl portable-timeout supervisor (group signals, EINTR-safe waitpid),
   per-site health data (absorbed into `--report`), `--secrets` mode,
   `duration_human`, human elapsed in summaries.
4. **AutoClaw-GLM-5.3-RAGRAF ported** — `is_wordpress_root` gating,
   `wp_config_*` constant readers, `wp help` feature probing, table
   fit/pad discipline, mode-table-driven help/completion concept.
5. **"Forgotten" features added** — cache flush (advertised by the repo for
   years, absent until now), translations, cleanup (revisions-per-post, spam,
   trash, transients; enumerate-then-delete), security audit with score,
   restore runbook, smoke test, maintenance mode, state file, Prometheus
   metrics, notifications (webhook + command), include/exclude/stagger/retry/
   fail-fast/max-duration/min-free-space, lock-timeout, multisite expansion,
   stdin site list + TAB owner column, syslog + JSON logs, --init-config,
   shell completion, installer, Makefile, CI.
6. **Production readiness** — exit-code contract 0..6 honoured everywhere,
   atomic outputs even after interrupts, stream policy (stdout=data,
   stderr=prose) in all formats, security model documented and asserted by
   tests, degradation-with-warning for every optional tool.
7. **WP-CLI version check + update key** — `WP_CLI_MIN_VERSION` floor gate at
   startup (exit 3), `WP_CLI_LATEST_CHECK` currency warning, `--wpcli-check /
   --wpcli-update / --wpcli-install / --wpcli-rollback`; channel+scope updates
   via `wp cli update`; pinned versions via direct download with **fail-closed**
   GPG (pinned fingerprint `63AF…BC06`) / SHA-512 verification, pre-install
   smoke test, atomic swap, timestamped backups.

## Verification status (honest ledger)

The sandbox hit an unrecoverable process-table exhaustion mid-session
(1000+ unreaped zombies held by PID 1; every `fork()` returns EAGAIN).
Everything was verified that could be:

**Verified at runtime (before exhaustion), v7 artifacts:**
`--version/--version-detail/--help/--list-modes/--print-config/--init-config
(stdout+file 0600)/--completion bash (parses)`; usage errors rc2 (unknown flag,
bad --timeout, conflicting modes, no mode); `--check` full host+site report;
`--full` on a 2-site fixture (24 ops, correct ordering, no db repair);
`--report` table/JSON/CSV; `--security` scores+findings+crit-on-minor-release;
`--cache`; `--cleanup` (safe without --yes; enumerates in dry-run; deletes with
--yes); `--dry-run --full` (mutations skipped, read-only queries executed);
`--json-lines`; `-j 2` (counters fold correctly); `--list-plugins`
table/csv/-N filter (ambiguity bug fixed); `--wpcli-check` (PASS, rc3 floor,
OUTDATED via stub); finder: scan/opt-out/excludes/manifest tsv+json/--fields
validation/--audit findings/--verify-list rc1/--print0/--version-detail.

**Verified after the last fixes (fork-free methods):** build green for both
artifacts; in-shell parse check green for all 42 shell files; functional
probes for the config table (96 keys, every default passes its own validator),
validators, version_compare matrix, trim/path/glob/csv helpers, json escaping
+ quoting, redaction, licence bridge (config→runtime), placeholder refusal,
read-only command classification (14 cases), TAB owner parsing, site filters,
units, budget, backup-dir naming, wp-config constant readers (incl. injection
refusal), sinks, mode/option tables.

**Runtime-verified in the 7.0.1 round (Debian 12, bash 5.2.15, shellcheck
0.9.0, jq present):** all nine suites end-to-end via `bash tests/run_tests.sh`
and via `make`-equivalent manual steps; `tools/build.sh --check` idempotence
(md5 stable across repeated checks and rebuilds with a fixed `WPU_BUILD_ID`);
the secret scanner over the shipped tree (0 findings); stdout purity of a
prose-mode run (0 bytes) with `/dev/null` and with real log files; the lock
refusal message and summary on stderr; both JSON reader paths (jq and builtin)
cell-for-cell equal on escaped quotes, tabs and backslashes.

**NOT runtime-verified here (needs a normal host / CI):** the root job
(user-switch paths — no sudo in the fix sandbox), the Astra licence live
(no key), `--restore` against real archives, smoke-test/webhook/live WP-CLI
update paths (no network targets), and shellcheck 0.11.0 (not installed here;
0.9.0 gates error+warning clean, and the CI policy now counts exactly those
two classes).

## The 7.0.1 round (defect report `cabb66e` → fixed)

An external defect report measured the published 7.0.0 tree (`cabb66e`) at
**446 passed / 253 failed / 1 skipped** across the nine suites and localised
ten defect groups (D1–D10). All ten were fixed at the cause; the same bench on
the fixed tree is recorded in `CHANGELOG.md` (7.0.1) and re-runs green. The
groups, one line each:

- **D1** `--log-file ''` rejected → the parser accepts an explicit empty value
  (documented "empty disables"); a missing argument stays exit 2. New guards in
  `test_cli_contract.sh`.
- **D2** `LICENCE_VALUE: unbound variable` aborted every mode → global
  initialisation restored in `src/manager/06-secret.sh` (lost in the modular
  split).
- **D3** `build.sh --check` always red and rewriting the artifact → in-memory
  build, stamp-aware exact comparison with a normalized fallback, no writes in
  `--check`, idempotent builds via `WPU_BUILD_ID` date reuse / `WPU_BUILD_DATE`.
- **D4** digits in stdout (broke json-lines/csv/tsv) → bare calls of
  print-and-publish helpers (`file_size` in log init/rotation, `trim` in the
  site-list parser, `data_sink` in record emitters) discarded with
  `>/dev/null`; stdout of a prose run is empty again.
- **D5** "`--full` doubles operations" → measured false: the product runs each
  operation once per site (stub argv log verified); the test patterns also
  matched `[language] [core] [update]` lines and are anchored now. The real
  half of D5 — `--skip-plugins` position — is fixed: the flag lands after the
  subcommand, as the contract asserts.
- **D6** pure functions → `json_array_slice` cuts the trailing prose,
  `csv_escape` quotes whitespace, `in_csv_list` trims the needle, the builtin
  JSON reader's string-body regex is portable (glibc ≡ MSYS2) and re-escapes
  like jq's `@tsv`; `LONG_OPTIONS` gained `--no-smoke-test`; the
  option-coverage extractor no longer reads comment rulers as options.
- **D7** shellcheck gate → `SC1102` fixed at the source, real warnings fixed
  (duplicate case pattern, `local a=1 b=$a` reuse ×2, dead array local, stub's
  two unreachable arms `help`/`maintenance-mode`, harness/stub warnings);
  `# shellcheck shell=bash` on every src fragment; CI/Makefile gate pinned to
  warning-and-above and print the linter version.
- **D8** backtick check false positives → the comment filter now accounts for
  `grep -n`'s `N:` prefix; the shipped tree has zero findings.
- **D9** secret scanner 18 findings → 0: reviewed allowlist entries for the
  `${LICENCE_HANDOFF:-stdin}` expansions, parser variable plumbing and two
  test fixtures; the `CHANGELOG.md` line reworded; two broken allowlist globs
  corrected.
- **D10** remainder → `CACHE_EXTRA`/`DISCOVER_ROOTS` retyped `tokens`, path
  settings retyped `apath`/`exec` (relative refused: exit 4 file / exit 2
  flag), the lock-refusal message rescued from the permanent `exec …
  2>/dev/null` stderr redirection, `SITE_USER` scalar again (`units_reset` no
  longer erases `--user`), `--version-detail` prints the WP-CLI floor without
  wp installed, harness `chmod -R a+rX` no longer undoes the fixture's 0640
  wp-config.

## First commands on a healthy machine

```bash
cd project
chmod +x tools/*.sh tests/run_tests.sh tests/stub/wp Bash_WP-CLI_Update.sh Find_WP_Senior.sh
bash tools/build.sh                 # rebuild + parse check
bash tools/build.sh --check         # drift gate: compares, never writes
bash tests/run_tests.sh             # the full bench (~700 checks, no root/wp/network)
make lint                           # shellcheck, error+warning classes
git add -A && git commit -m "v7.0.1: defect-fix round"  # sources AND artifacts together
```

If a suite fails, the fastest triage is `VERBOSE=1 bash tests/run_tests.sh <suite>`
(keeps the fixture tree) plus `tests/stub/wp`'s argv log, which records every
command line the product built.
