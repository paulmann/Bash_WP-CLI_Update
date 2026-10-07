# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [6.0.0 / 2.0.0] - 2026-10-07

Full rewrite of both scripts on branch `v6.1.0-refactor`. The public command line of
`Bash_WP-CLI_Update.sh` is extended, not broken: every existing mode flag still
works. `Find_WP_Senior.sh` keeps `--output` and `--exclude` and gains options.

The defects below were reproduced before being fixed; the reproduction commands
are the diagnostics kept in `tests/`.

### Fixed in `Bash_WP-CLI_Update.sh`

1. **`--skip-plugins` was applied to every command**, including
   `plugin list --format=json` and `plugin activate`. The flag changes which
   plugins WP-CLI loads, so a listing produced with it is not the real plugin
   set, and activation of a skipped plugin silently does nothing. It is now
   passed to update commands only; listing needs explicit
   `--skip-plugins-for-listing on`.
2. **`--quiet` was added unconditionally.** It suppressed the per-plugin result
   lines of `wp plugin update --all`, so the summary could not report what was
   updated. It is no longer passed.
3. **The command was assembled as a string and handed to `su -c`.** Any argument
   containing a quote, a dollar sign or a backtick executed as shell code
   (`--name 'zz"; touch /tmp/x; echo "'` ran `touch`). The command is now built
   from an argument array with explicit POSIX quoting, and the suite proves the
   injection attempt creates no file.
4. **`cmd[*]` inside a string split arguments on spaces.** A plugin name such as
   `Akismet Anti-Spam` became two arguments. Arguments are now preserved exactly;
   the same test checks it.
5. **`get_plugins_json` ignored its own suppression argument** (the callers passed
   `true`/`false`, the function never read `$3`), and its retry path only ran in
   debug mode. Replaced by one code path with a real error report.
6. **`grep -c . || echo 0` produced two lines** (`0\n0`) on empty input, which
   then broke every numeric comparison: `[[: 0\n0: arithmetic syntax error`.
   All counts go through one helper that always returns a single number.
7. **The error box lost its last line** when the file read returned on a short
   final line, and `wc -l` under-counted a message without a trailing newline.
   Both replaced by a single pass that counts and prints consistently.
8. **`run_wp_cli` reported success for a failed command**, so `Errors` stayed at
   zero while WP-CLI was failing, and modes continued past a failure. Return
   codes are propagated and counted now; `--full` continues by design but the
   summary says `operations failed: N`.
9. **`process_site` was called without checking the result in single-site mode**
   (`process_site "${TARGET_SITE}"`), and a wrong `--site` was skipped with a
   warning instead of an error. A site named explicitly is now a hard error with
   exit code 1.
10. **`--help` exited with status 1.** It now exits 0; bad options still exit 2.
11. **The startup banner printed warnings for actions that were not requested**
    (the delete confirmation warning appeared during a plain `--full`).
12. **`$HEADER_SHOWN && return 0` was a bare command under `set -e`.** The banner
    and its duplicate call site are gone.
13. **The progress bar printed a newline on every render**, producing one line per
    site instead of one updating line.
14. **`printf '%-38s'` broke the frame** for longer values (measured 65-character
    frame against 40-character padding).
15. **Astra handling was duplicated** in two functions (~120 lines) and decided
    whether an update was pending by grepping a localised word out of the output.
    One implementation remains, and the decision uses the exit status plus the
    dry-run result.
16. **The Astra licence was echoed to the log** (`Activating license with key: ...`)
    and passed on a command line. The value now reaches the child process through
    a mode-600 file handed over under an internal marker, the file is removed
    immediately after the call, and a test asserts the value appears in neither
    the log nor the recorded `argv`.
17. **`--allow-root` was always passed.** It is now controlled by
    `--allow-root auto|always|never` (default `auto`: only when running as root).
18. **`STATS` counters were incremented inside command substitutions**, where the
    increments are lost in a subshell. The counters are updated in the current
    shell; a test asserts the reported totals.
19. **`su -` created a PAM session per call.** The privilege drop now prefers
    `runuser`, then `sudo -n`, then `su -s /bin/sh`, and each call has a timeout.
20. **The `--site` path, plugin name and `--action` were not validated** against
    the documented set. Options are validated with exit code 2 and a usable hint.
21. **No locking.** Two concurrent runs could interleave DB optimization. A lock
    file is taken (flock when available, pid file otherwise); a second run exits 3.
22. **No log rotation, and colours went into the log file.** Log rotation by size
    and generation count was added, and log lines are plain text: colours are
    emitted only to a terminal and are disabled by `NO_COLOR`.
23. **`jq` was mandatory** for listing and filtering, and the fallback was a
    `grep` over JSON. A self-contained reader parses the WP-CLI JSON, so
    `--list-plugins` and `--name` work without `jq` at all.
24. **The `jq` program was built by string interpolation**, so a quote or a
    bracket in `--name` rewrote the query. Filtering happens in `awk` with the
    needle passed through the environment; a test uses a jq-style payload as the
    plugin name and expects an empty result.
25. **`plugins_to_tsv` lost the last row** when the producer did not end with a
    newline, because `read` returns non-zero at EOF without a delimiter. Every
    reader now handles the short final line.
26. **`grep -c .` / `wc -l` were used as counters** throughout; replaced by one
    helper.
27. **Duplicate summary blocks and a duplicated site loop** were removed.
28. **`set -euo pipefail` plus `shopt -s inherit_errexit || true`** hid the fact
    that `inherit_errexit` needs bash 4.4. The requirement is now stated as bash
    4.2 and checked explicitly.

### Added to `Bash_WP-CLI_Update.sh`

- Modes: `--check` (validate environment, sites, WP-CLI, core version, plugin
  count; changes nothing) and `--status` (last run, log sizes, lock state).
- Options: `--format table|json|csv|tsv`, `--page`, `--dry-run`, `--timeout`,
  `--config`, `--sites`, `--wp`, `--user-env`, `--skip-plugins`,
  `--skip-plugins-for-listing`, `--allow-root`, `--astra-key`, `--astra-slug`,
  `--lock-file`, `--color`, `--no-color`, `--quiet`, `--yes`, `--list-modes`,
  `--version`.
- Configuration file in plain `KEY=VALUE` form, parsed and never sourced, refused
  when it contains shell metacharacters. Precedence: defaults < global file <
  local file < environment < command line.
- Exit codes: 0 success, 1 operational error, 2 usage error, 3 environment error,
  4 configuration error.
- A `SUMMARY` block that always prints, including on `INT`/`TERM`, and exactly once.

### Fixed in `Find_WP_Senior.sh`

29. **`build_prune_args` returned the `find` arguments as one string**, so
    `-path X -prune -o` became a single invalid operand. Measured effect: with at
    least one absolute exclusion, `find` printed **every** directory that had a
    `wp-config.php` anywhere below, and `dirname` then produced non-WordPress
    paths. The expression is now an array of complete operands.
30. **The file branch had no `-print` of its own.** Whether anything was printed
    depended on the prune helper, so the result set was an accident of the
    exclusion list. The file branch ends with its own `-print`.
31. **`.no_wp_cli` was pruned as a directory name**, which never matches a marker
    *file*. It is now checked explicitly for each candidate.
32. **`DEFAULT_OUTPUT_FILE="${PWD}/wp-found.txt"`** wrote the list into the
    current directory, while the manager reads it next to the script. Discovery
    started from another directory produced a list the manager never saw. The
    default is now derived from the script directory.
33. **`--exclude` patterns such as `*/old*`, `*/test*`, `*/tests*`, `*/backup*`
    dropped live sites** whose names merely contain the substring: measured
    `oldtown.com`, `btest.example.com`, `contest.org` were excluded. Exclusions
    now match whole directory names (`--exclude-name`) or whole paths
    (`--exclude-path`).
34. **`MAX_DEPTH=6` silently lost deeper installations.** Measured: a site whose
    `wp-config.php` sat 11 levels below the root was invisible. The default is 8
    and `--depth` changes it.
35. **`IFS=$'\n\t'` was set globally and exported**, which changes word splitting
    in every child (`IFS` is in the environment for subshells and commands).
    Removed.
36. **`set -euo pipefail` was declared twice**, the first time in a "bash or
    POSIX" block that could not work and misled readers. One declaration remains.
37. **`is_valid_wp` required `wp-includes/version.php`**, rejecting installations
    where the path is behind a symlink. `wp-load.php` is accepted as well.
38. **The result file was written in place**, so an interrupted run left a
    truncated site list for the manager to read. The result is written to a
    temporary file in the target directory and moved into place.
39. **`grep -c ''` and `wc -l` were used as counters** with the same
    `|| printf 0` double-value defect as in the manager. One helper is used.
40. **`continue 2` inside a pipeline subshell** made exclusions exit quietly
    without any report. Exclusions are decided in the parent shell now, and
    `--verbose` prints why a candidate was skipped.
41. **`cleanup()` logged during `EXIT`** and `trap cleanup EXIT` ran even when the
    script had exited with an error, mixing a normal message into error output.
42. **Whether the run found anything was not reflected in the exit code.** Exit
    codes are now 0 found, 1 error, 2 usage, 3 environment, 5 nothing found.

### Added to `Find_WP_Senior.sh`

- `--format paths|tsv|csv|json`, `--depth`, `--exclude-name`, `--exclude-path`,
  `--delimiter`, `--skip-existing`, `--status`, `--quiet`, `--verbose`,
  `--color`, `--no-color`, `--version`.
- `--status` reports the entry count, size, modification time and whether the list
  is stale relative to newer `wp-config.php` files.
- Human messages go to stderr, results to stdout, so the script is pipeable.

### Tests

`tests/run_tests.sh` runs both suites. They need no root, no WordPress and no
WP-CLI: a synthetic tree and a stub `wp` that records its own `argv` provide the
observable behaviour. Covered: argument preservation, injection attempts, all four
output formats parsed by an independent parser, exit codes, `--help` status,
`--dry-run` executing nothing, skip-plugins policy, configuration precedence and
the refusal of a shell-metacharacter config, licence non-leakage, concurrent-run
refusal, and for the finder: exclusion precision, depth, marker file, output
hygiene (sorted, unique, no CR, trailing newline).

### Not verified

- No run against a live WordPress installation: this machine has no Linux target,
  no root and no WP-CLI. Behaviour against real WP-CLI output is unverified.
- `shellcheck` is not installed on this machine, so static analysis beyond
  `bash -n` was not performed.

## [5.0.0 / 1.01.0]

Previous state of `main`: single-file manager with `--full`, `--core`,
`--plugins`, `--themes`, `--db-optimize`, `--db-fix`, `--cron`, `--astra`,
`--list-plugins`, `--plugin-manage`, and a discovery script with `--output` and
`--exclude`.
