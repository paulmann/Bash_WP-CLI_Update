# Refactoring report — v6.1.0 → v6.2.0

What this tree took from each of the five revisions of the project, what it
rejected and why, and what broke on the way.

The originals are in [`legacy/`](legacy), byte-exact and verified with
`git hash-object`, so every citation of the form `main:396` below is checkable
without git history. The audit of the **original** code — the defects that made a
rewrite necessary, with a reproduced proof of concept for the command injection —
is in [`ANALYSIS.md`](ANALYSIS.md). This file is about the consolidation.

| | v6.1.0 | v6.2.0 |
|---|---|---|
| Modes | 12 | **13** (`--verify`) |
| Fleet-wide options | — | **9** (`-j`, `-b`, `-B`, `--keep-backups`, `--no-backup`, `--only-active`, `-e`, `-U`, `--strict`, `--list-sites`, `--no-user-switch`) |
| Machine-readable fleet report | plugin list only | **JSON Lines**, one object per site plus a summary |
| Backups | plugin files before a delete | **database and whole-tree**, with rotation, plus the plugin archive |
| Parallelism | none | **batched, `-j N`** |
| Test checks | 433 | **532** across six suites |
| ShellCheck findings, whole tree | 0 | **0** |

---

## 1. How this was verified

Nothing below is a reading of the diff. Every claim was produced by running
something.

* **Bash 5.2.15**, `/bin/sh` → **dash** (Debian). The dash detail is not
  incidental: it is what makes `printf %q` unsafe here, and one of the five
  revisions shipped a manager that could not update a single site because of it.
* **ShellCheck 0.11.0** over all eleven shell files in the tree: 0 error,
  0 warning, 0 info. `tests/test_static.sh` asserts this, so it cannot rot.
* **Six test suites, 532 checks**, `bash tests/run_tests.sh` exits 0. No root, no
  WordPress, no WP-CLI and no network: a recording stub of `wp` answers for the
  real thing and logs the exact argv it received, so assertions are about what
  would be executed and not about what was printed.
* **Parallelism was measured, not inferred.** Five sites, a stub that sleeps one
  second: 5 s sequential, 1 s at `-j 5`, 3 s at `-j 2` (three barriers). A batch
  implementation that silently degrades to a loop fails these numbers.
* **The injection probes were run**, not reasoned about: a site directory named
  `siteA;touch /tmp/PWNED;echo `, a `--name` of `zz"; touch /tmp/PWNED2; echo "`,
  a plugin title of `Safe; $(touch /tmp/PWNED3) "quoted"`, and a jq payload in
  `--name`. In all four cases nothing was created and the value arrived as one
  argv element.
* **The licence was traced end to end.** A stub records the length and a checksum
  of what it receives, never the value. The handoff file is 0644 for the duration
  of one call; the value appears in no argv, no log line, no dry-run listing and
  no error box.

---

## 2. What was taken, and from where

| Taken from | What | Why it won |
|---|---|---|
| `v6.0.0-ragraf` | `run_as_user` with positional parameters: `su -s /bin/sh -c 'cd -- "$1" \|\| exit 127; shift; exec "$@"' user sh DIR PROG ARGS…` | Needs no escaping in any shell. The two alternatives both have an edge: `printf %q` is bash-only, and hand-rolled POSIX quoting is one more thing to get wrong. |
| `AutoClaw-GLM-5.3-RAGRAF` | Licence handoff through a temporary file read by the child shell; config parsed as data and never sourced; exit-code taxonomy 0/1/2/3/4 honoured including for `--help`; `CHANGELOG` in Keep-a-Changelog format | The only revision where the licence never becomes an argument of any process, and the only one whose config file cannot execute code. |
| `AutoClaw-GLM-5.3-RAGRAF` | `tools/scan-secrets.sh` with `--history`, masking, fingerprints and an allowlist | Extended here to five naming conventions; the original missed `DB_PASSWORD` and `AWS_SECRET_ACCESS_KEY` entirely (see §4). |
| `rewrite-v5.0.0` | `AGENT.md` as a binding rule set; `--skip-plugins` applied only to plugin/theme operations; a Python-free scenario runner | The rules document is what stops the next rewrite from re-learning all of this. The skip-plugins policy is the behaviour the README always promised and `main` never implemented. |
| `v6.0.0-deepseek` | Licence from a key file with a documented search order; `_redact()` over every outgoing message; spaces instead of tabs | The cleanest code of the five, and the only one that treated the key as data with a provenance chain. |
| `SagaAI_DeepSeeek_Flash` | `-j N` batched parallelism with per-worker buffering and ordered replay; `-b db\|full` with `--keep-backups`; `--verify`; `--only-active`; `-e`; `-U`; `--strict`; `--list-sites`; `--no-user-switch`; JSON Lines; `legacy/`; the structure of `ANALYSIS.md` | Measured ahead of this tree on functionality, static analysis and documentation. See §3 for what was **not** taken. |

---

## 3. What was rejected, with the measurement that decided it

Rejecting a feature from the best-scoring revision needs a reason, or the next
reader will re-add it.

### 3.1 The Astra licence as an argument to `wp`

`SagaAI` calls `run_wp … brainstormforce license activate astra-addon "${ASTRA_KEY}"`.
Measured with a stub that records its own argv:

```
ARGV: [--path=…] [--allow-root] [brainstormforce] [license] [activate] [astra-addon] [SAGA-SECRET-KEY-1234567890]
```

The value is in the child's argument vector, therefore in `/proc/<pid>/cmdline`,
therefore in `ps`, for the duration of the call. Their own `ANALYSIS.md` §10
discloses this honestly and lists the mitigations; their own script header
(`Bash_WP-CLI_Update.sh:82`) forbids it in terms — *"never pass the licence key on
the command line — it is visible in `ps`"*. The disclosure is good practice. The
contradiction between the header and the code is what a reader of the header will
not expect.

This tree keeps the file handoff. The residual risk there is a 0644 temporary
file in a sticky directory for the length of one WP-CLI call, and
`licence_open()` documents why the three alternatives are worse: 0600 does not
work at all (the child has already switched user and gets `Permission denied`, so
the licence arrives **empty** — measured), `runuser -m` has no equivalent under
`sudo`/`su`, and argv is what is being avoided.

### 3.2 `source` for the configuration file

`SagaAI` sources it and guards against group/world-writable files. The guard
works — measured, a 0664 config is refused with exit 2. But a **root-owned 0644**
config is still root code execution, and measured, the payload ran:

```
$ printf 'SKIP_PLUGINS=a; touch /tmp/PWNED\n' > evil.conf   # 0644, root:root
$ Bash_WP-CLI_Update.sh --print-config -C evil.conf
…
$ ls /tmp/PWNED
/tmp/PWNED
```

This tree parses `KEY=VALUE` and rejects the whole file with exit 4 when any line
carries a backtick, `$(`, `|`, `;`, `&`, `<` or `>`. All seven are asserted by
`tests/test_fleet.sh`.

### 3.3 `shell_join` on `printf %q`

Correct in `SagaAI`, because the `su` fallback says `-s /bin/sh` explicitly —
which is exactly the twelve characters `v6.0.0-deepseek` omitted, and why that
revision could not update a single site on a host where `/bin/sh` is dash. But
`%q` emits `$'…'` for a string containing control characters, and POSIX `sh` does
not understand that form. A site directory with a newline in its name is rare;
"rare" is not a property a maintenance tool wants in its command construction
path. The positional-parameter runner has no such edge because it does no
escaping at all.

### 3.4 The author's plugin list as a default

`--skip-plugins` defaults to `saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer`
in four of the five revisions, including this one's own ancestors. It is one
installation's requirement presented as everybody's default, and it is passed to
every `wp` call. Here the default is empty and the list lives in
`wp-cli-update.conf.example` as a commented example. `tests/test_static.sh` fails
the build if the strings come back.

### 3.5 `--dry-run` that contacts every site

`SagaAI`'s dry run executes the read-only probes with WP-CLI's own `--dry-run`
and skips the mutations: measured, 9 real invocations and 12 skipped operations
over three sites. That is a genuinely useful answer — it tells you what *would*
change, not just what would be attempted — but it loads WordPress on every site
and is not side-effect free. This tree's dry run executes nothing and prints the
exact command per site; `--check` is the mode that contacts sites read-only.

---

## 4. Defects found in the adopted code, and in this tree, while integrating

Fifteen, all reproduced. The first five are in code taken from `SagaAI`; the rest
were introduced or uncovered here.

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | `tests/smoke_test.sh` writes the mock's shebang as `#!${BASH_BIN}` with `BASH_BIN` defaulting to `bash` | The shebang becomes literally `#!bash`, the kernel cannot resolve it, and **every** WP-CLI call fails with 127. Measured: 35 passed / 57 failed out of the box, against a claimed 91/91 | Not fixed in their tree; documented. Our equivalent stub has a fixed `#!/usr/bin/env bash` shebang |
| 2 | Their fixture never gives the sites a non-root owner, and `mktemp -d` yields 0700 root | `resolve_site_user` refuses every site: "cannot determine a system user". This is the remaining 57 failures | Our harness `chmod 755` the working directory and `chown`s the tree to a switchable account when one exists; `--no-user-switch` removes the dependency entirely |
| 3 | `ASTRA_KEY` / `ASTRA_KEY_FILE` are never read from the environment | `: "${ASTRA_KEY:=}"` only declares an empty variable. `ASTRA_KEY=… --astra` answers "licence key is not configured", while the header promises environment priority | Not adopted; this tree reads the licence through `env_value`, which consults `printenv` |
| 4 | Their backup prune expects `backups/<site>/…` while the manager writes `backups/…` | Their own check "no plugin backup archive found" fails although the archive exists | Our prune and our check agree on one layout, and the check derives the path from the same helper the code uses |
| 5 | Their mock ignores `--fields` | The hostile-plugin-title check compares against a column the parser never received | Our stub honours `--format` and `--fields` |
| 6 | **`is_set` looked only at shell variables** | The environment layer of the documented precedence did not exist: `WP_CLI_UPDATE_JOBS=7` was invisible and `file < env < CLI` collapsed into `file < CLI` | `is_set` now falls back to `printenv`; a new `env_value` reads the value the same way; asserted for `JOBS` in `test_fleet.sh` |
| 7 | **`run_sequential` called `run_fleet`, which called `run_sequential`** | An integration patch matched the loop *inside* the helper instead of the one in `main`. `-j N` ran sequentially: 4 s instead of 1 s for four one-second sites | Both blocks rewritten with unambiguous anchors. `test_fleet.sh` measures the wall clock, which is the only reason this was caught |
| 8 | **A forked worker inherited the parent's counters and wrote them back** | `ops_ok` was 8 for a four-site fleet at `-j 2`, and grew with every batch | Workers zero their counters at fork. The suite runs the same fleet at `-j 1/2/3/5` and asserts identical totals |
| 9 | **`BACKTICK="$'\140'"`** | In double quotes that is the seven-character literal `$'\140'`, not a backtick, so the config guard's strongest metacharacter was the one that slipped through. Measured: a config with a backtick payload was accepted | `BACKTICK=$'\140'`; all seven metacharacters now asserted |
| 10 | **Backticks in the `--help` text were executed** | The usage heredoc is unquoted (it expands `${PROG_NAME}`), so a literal pair became a command substitution and `--help` hung — measured, `tail -f` was started by the help text | Help text uses single quotes for literals; `test_static.sh` greps the shipped code for backticks |
| 11 | **`--list-sites --json` printed the table** | The branch ran before `validate_args`, which is where the dual meaning of `-J` is resolved | Moved after `validate_args`, still before `log_init` and the environment checks |
| 12 | **`--strict` did not fire on an empty fleet** | The "nothing to do" path exited 0 before `final_exit_code`, so the run a cron job most needs to hear about was the one it never reported | The empty path now consults `final_exit_code` |
| 13 | **`--print-config` named the wrong layer** | It printed the config-layer source, so a command-line override was reported as `file:…` — a diagnostic tool that looks like the bug it is diagnosing | `effective_source` plus a `CLI OVERRIDE` column |
| 14 | `--skip-plugins` reached `plugin list` | It hid the very plugins being listed | Applied only to operations that change plugins or themes; listings only under `--skip-plugins-for-listing on` |
| 15 | **The backup directory was created by the manager, but written by the site owner** | `mkdir -p` gave it the manager's umask — 0755 root. After the user switch `wp db export` died with *Permission denied*, and the run reported "database backup failed … the site is still going to be updated" followed by "backup failed; skipping the site". Every site, every mode with `--backup`. Invisible to the whole suite, because the suite runs `--no-user-switch` | `backup_ensure_dir` creates 1777 with the sticky bit, exactly like `/tmp`: any local user may create a file inside, and the sticky bit stops one user from deleting another's dump. The dumps themselves stay 0640. Asserted in `test_fleet.sh` |

Four of these (#7, #8, #9, #15) are in code written during this integration, and
each was caught only because a test measured something rather than asserting that
the code looks right: wall-clock time against a sleeping stub, counter equality
across four degrees of parallelism, each metacharacter separately, and the
permission bits of a directory that only a different uid ever writes to.

\#15 deserves the emphasis, because it survived all 95 fleet checks. The suite runs
`--no-user-switch` for portability — which is exactly the configuration under
which the bug cannot appear. The check that catches it asserts the *mode of the
directory*, not the success of the backup, so it holds with and without the
switch. That is the general lesson: a portable suite needs at least one check per
feature that asserts the property the portability switch disables.

---

## 5. Residual limitations

Stated plainly, because the alternative is that somebody finds them in production.

* **The licence handoff file is 0644** for the duration of one WP-CLI call, in a
  sticky directory with an unpredictable name. Any local user can read it in that
  window. If your threat model includes that, feed `WP_CLI_UPDATE_LICENCE` per
  invocation from a secrets manager instead of keeping a key file on disk.
* **`-j N` is a batch barrier.** The next batch waits for the slowest site of the
  current one. On a fleet with one very slow site the gain is bounded by that
  site. A continuous pool needs `wait -n`, which is bash 4.3.
* **During a parallel run the log file grows at the barrier, not during the
  work.** `tail -f` looks stalled. Buffering is what keeps the file readable;
  the two cannot both be had.
* **`--backup full` archives `wp-content/uploads`.** On a media-heavy site that is
  tens of gigabytes and many minutes. The script reports the tree size before
  starting, but it does not refuse.
* **The table renderer measures width in bytes**, so titles in a multi-byte
  alphabet will not align. Data columns are unaffected; `--format csv` and
  `--format tsv` are exact.
* **`plugin_select_targets` reads the whole plugin list into memory** as TSV. At
  a few hundred plugins per site this is irrelevant; at a few thousand it is
  still fine, but it is not streaming.
* **`tools/scan-secrets.sh` reports shapes, not verdicts.** A credential split
  across lines, assembled from fragments, base64-encoded or inside a binary is
  not matched. Absence of findings is evidence, not proof; run `gitleaks` or
  `trufflehog` in addition, not instead.
* **Owner resolution accepts `root` as a last resort**, with a warning. Refusing
  root-owned sites outright — what the original did — means every site in a
  container is silently skipped, which is worse.

---

## 6. Files

| File | What it is |
|---|---|
| [`Bash_WP-CLI_Update.sh`](Bash_WP-CLI_Update.sh) | the manager, v6.2.0 |
| [`Find_WP_Senior.sh`](Find_WP_Senior.sh) | discovery, v2.1.0 |
| [`tools/scan-secrets.sh`](tools/scan-secrets.sh) | secret guard, v1.1.0 |
| [`tools/secret-allowlist.txt`](tools/secret-allowlist.txt) | known-benign lines, each with a reason |
| [`tests/run_tests.sh`](tests/run_tests.sh) | runs all six suites, exits non-zero on any failure |
| [`tests/harness.sh`](tests/harness.sh) | fixtures, file-backed counters, SKIP handling |
| [`tests/stub/wp`](tests/stub/wp) | recording stub of WP-CLI |
| [`tests/test_static.sh`](tests/test_static.sh) | lint, banned constructs, documentation consistency |
| [`tests/test_base_contract.sh`](tests/test_base_contract.sh) | the public surface of the **original** scripts |
| [`tests/test_finder.sh`](tests/test_finder.sh) | discovery behaviour and output formats |
| [`tests/test_manager.sh`](tests/test_manager.sh) | per-site behaviour, injection, licence containment |
| [`tests/test_fleet.sh`](tests/test_fleet.sh) | parallelism, backups, fleet-wide reporting |
| [`tests/test_secretguard.sh`](tests/test_secretguard.sh) | the guard, including planted values and history mode |
| [`legacy/`](legacy) | byte-exact originals from `main` |
| [`ANALYSIS.md`](ANALYSIS.md) | audit of the original code, with the PoC |
| [`REFACTORING.md`](REFACTORING.md) | this file |
| [`AGENT.md`](AGENT.md) | binding rules for changing these scripts |
| [`PROJECT_MAP.md`](PROJECT_MAP.md) | file-by-file map with dependencies |
| [`CHANGELOG.md`](CHANGELOG.md) | Keep a Changelog |
| [`wp-cli-update.conf.example`](wp-cli-update.conf.example) | every setting, with its default and its reason |

## 7. Definition of done, restated

```bash
bash tests/run_tests.sh          # 532 checks, exit 0
bash tools/scan-secrets.sh --strict   # exit 0
shellcheck *.sh tools/*.sh tests/*.sh tests/stub/wp   # no output
```

…and, on a real host, before anything is scheduled:

```bash
Bash_WP-CLI_Update.sh --print-config          # what came from where
Bash_WP-CLI_Update.sh --list-sites            # what would be touched, and as whom
Bash_WP-CLI_Update.sh --check                 # environment and every site, changes nothing
Bash_WP-CLI_Update.sh --full --dry-run        # the exact command per site
Bash_WP-CLI_Update.sh --full --dry-run -j 4   # the same, at the intended width
```
