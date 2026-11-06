# Why this tool exists

## The problem: a root script with a shell string

The tool has to change live WordPress sites, so it runs as root and switches into the
owner of each site. The original 5.0 manager did that by building every WP-CLI command
with string concatenation and handing the result to `su - USER -c`, which is command
injection running as root. The same tree expected the Astra licence to be edited into the
script, exited 1 with an empty list and no message on the finder, treated `--help` as a
directory to scan, and had no lock, no log rotation, no dry run and no timeout.

Every one of those is a defect in the mechanism, not in the intent. The rewrite is about
the mechanism.

## The safety model

Seven rules, each one enforced by something rather than promised:

1. **argv, never a string.** Every WP-CLI call is a bash array. Nothing is built by string
   concatenation, nothing goes through `eval`, and `printf %q` is never used. The user
   switch passes arguments as positional parameters, so a path with a quote or a space
   cannot break anything.
2. **Configuration is data.** A config file is parsed as `KEY=VALUE` and is never sourced.
   A line containing a shell metacharacter rejects the whole file (exit 4), and a group-
   or world-writable config file is refused before it is read.
3. **The licence never becomes an argument.** It is written to a temporary file readable
   by root and the site owner's group, the child shell reads it at run time, and the file
   is removed when the call returns. `ps` never shows it.
4. **A backup happens before anything is modified.** A failed backup stops the site
   instead of silently continuing unprotected; `--fail-on never` relaxes that, on purpose.
5. **Read-only means read-only.** `--health`, `--secrets`, `--security`, `--list-plugins`,
   `--verify`, `--list-backups` and `--check` take no backup, take no lock and write
   nothing but log lines.
6. **Destructive modes are two-key.** `--restore-db` needs `--yes`, dumps the current
   database first and runs `wp db check` afterwards.
7. **Exit codes are a contract**, and they are honoured: `2` for a usage error, `4` for a
   config error, not a generic `1`.

## Security posture since 8.1.0

The safety model is about what the tool does to a host. 8.1.0 adds the other question:
what state is the fleet in. A race condition in the WordPress core update mechanism
(CVE-2026-119977) makes an unpatched site exploitable while it updates, and an operator
needs both halves — a verdict and a mitigation.

* `--security` is read-only: it compares each site's core version with the fixed releases
  and exits 1 when a site is exposed or its version cannot be read, so monitoring or a
  pipeline can act on the answer instead of on a guess.
* `--harden`, `--harden-upgrade-dir` and `HARDEN_UPGRADE_DIR` append a marker-guarded deny
  block for `wp-content/upgrade/` to each site's `.htaccess` (Apache, LiteSpeed) and print
  the directive an nginx server block needs, because nginx ignores `.htaccess`.
* `--health` carries the verdict as a column; a `--core` or `--full` run that leaves a site
  below the fixed release says so in the log instead of reporting a success it cannot
  prove.

The rule is the same one as above: report the state rather than assume it. A branch the
tool has no fixed release for is reported as needing an upgrade, never as safe, and a site
that stays below the fixed release is logged, not hidden. The full advisory is on
[Security: CVE-2026-119977](09-Security-CVE-2026-119977).

## The measured lineage

Each earlier line of work is kept as a release and as an annotated tag `llm/<branch>`,
so the comparison stays checkable instead of being overwritten. The table is maintained in
[docs/RELEASE-HISTORY.md](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/docs/RELEASE-HISTORY.md):

| Release | Source | What it was |
|---|---|---|
| `v5.0.0` | `main` before the chain | the original monolith: two scripts, no lock, no backups, no tests |
| `v5.1.0` | `rewrite-v5.0.0` | first rewrite with test suites and documentation |
| `v6.0.0` | `v6.0.0-ragraf` | RAGRAF + Flash revision of the 6.0 line |
| `v6.0.1` | `v6.0.0-deepseek` | DeepSeek 4 Pro revision of the same line |
| `v6.0.2` | `AutoClaw-GLM-5.3-RAGRAF` | GLM 5.3 revision; adds a secret guard |
| `v6.0.3` | `SagaAI_DeepSeeek_Flash` | SagaAI sync of the 6.0 sources |
| `v6.1.0` | `DeepSeek_Hybrid` | `--health`, `--secrets`, site URL detection, short options |
| `v6.2.0` | `QWEN_Hybrid` | fleet release; the base of 8.0.0 |
| `v7.0.1` | `QWEN-Agent_Mode` | a modular tree (`src/manager`, `src/finder`) built into one script |
| `v8.0.0` | this tree | the merge: read-only modes, restore, fleet control, guards, reports |

The current release is 8.1.0: the security work described above, and the point at which
the licence moved to MIT, so commercial use no longer needs a separate agreement.

The three-way comparison measured the baselines before choosing one. The 6.0 tree
(`main`) was 59 084 B, 1 569 lines, about 24 functions, 4 files and no test suite.
`DeepSeek_Hybrid` (6.1.0) was 98 752 B, 2 689 lines, about 90 functions, 13 files and one
suite. `QWEN_Hybrid` (6.2.0) was 136 257 B, 3 344 lines, about 110 functions, 24 files and
six suites plus a recording stub `wp`; it became the base because it measured better, and
the DeepSeek ideas that also measured better were ported onto it.

7.0.1 is a different architecture, not an earlier draft: it has no restore path, no disk
guard and no circuit breaker, and 8.0.0 has no modular `src/` tree. It keeps its own
release rather than being folded in.

## What the tool is not

* **Not a WordPress plugin.** It is not installed into `wp-content`, and it does not need
  PHP on the manager side. It drives a `wp` binary.
* **Not an installer for WP-CLI.** The npm package installs two commands that exec the
  shipped scripts; it does not install WP-CLI and it runs nothing at install time.
* **Not portable to macOS.** The npm package declares `os: linux`; the floor is bash 4.2
  and GNU coreutils, and macOS ships bash 3.2.
* **Not a monitoring system.** `--health` answers "what is pending right now" and
  `--status` answers "what did the last run do"; a notification carries counters only.
  `--security` is the same kind of answer: a verdict per site, not a replacement for
  patching.
* **Not a firewall.** The `.htaccess` block closes one directory over HTTP. It is defence
  in depth behind the update, and it cannot help a site served by nginx, which never reads
  `.htaccess`.
* **Not the old code with a new number.** `legacy/` holds byte-exact copies of the 5.0
  scripts so citations stay checkable; nothing executes them and their defects are left
  exactly as they were.
