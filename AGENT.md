# AGENT.md — binding rules for changing these scripts

Read this before editing anything, human or model. Every rule below exists
because a previous revision of this project broke it, and in four cases the break
was not visible until the script was run against a real fleet.

## Project

Two standalone GNU/Linux bash scripts for WordPress maintenance:

- `Bash_WP-CLI_Update.sh` (6.2.0) — per-site WP-CLI maintenance, run as the
  system user that owns each installation.
- `Find_WP_Senior.sh` (2.1.0) — WordPress root discovery; writes the site list.

Plus `tools/scan-secrets.sh` (1.1.0) and the suites in `tests/`.

## Non-negotiable rules

1. **`set -uo pipefail`, and no `set -e`.** In a tool that walks a fleet, one
   failing site must not abort the run. Every error path is handled explicitly
   and counted. Adding `-e` turns “site 37 failed” into “sites 38–200 were never
   attempted”, and the exit code stops meaning anything.
2. **Never build a command by string concatenation.** WP-CLI calls are bash
   arrays that become argv. The only string handed to a shell is the user switch
   in `run_as_user`, and there the arguments travel as *positional parameters*:
   ```bash
   runuser -u "$user" -- /bin/sh -c 'cd -- "$1" || exit 127; shift; exec "$@"' sh "$workdir" "$@"
   ```
   No escaping is needed, so none can be wrong.
3. **`printf %q` is bash-only.** Never use it to build a string for `sh -c`, for
   `su -c` without `-s`, or for `ssh`. `/bin/sh` is dash on Debian, where `\&\&`
   is a literal, and the failure is `cd: too many arguments` on *every* site. If
   you truly need `%q`, force the interpreter: `su -s /bin/bash …`. If you need
   quoting for a POSIX shell, use `sh_quote()`.
4. **Never expand a possibly-empty array as `"${arr[@]:-}"`.** In bash 4.4+ that
   yields *one empty element*, not zero. Use `${arr[@]+"${arr[@]}"}`. This single
   pattern once made the finder scan the entire filesystem in addition to the
   root it was given.
5. **A configuration file is data.** Parse `KEY=VALUE`; never `source` it. A line
   with a backtick, `$(`, `|`, `;`, `&`, `<` or `>` rejects the whole file with
   exit 4.
6. **Never call a function that can `exit` inside `$(…)`.** The exit leaves the
   subshell only and the caller continues with an empty value. Option values are
   taken from the global `OPT_VALUE` set by `need_value` for exactly this reason.
   The same applies to registering temporary files: `make_tmp` sets `TMP_LAST`
   instead of printing.
7. **Traps are installed once, at file scope**, over global lists. A trap set
   inside a function that references a `local` variable fires after the variable
   is gone: `set -u` prints “unbound variable” on every successful run, the
   cleanup does not happen, and the previous handler is replaced.
8. **Do not re-`exit` from the EXIT trap without the captured status.** `exit`
   inside a trap replaces the pending exit status; capture `local rc=$?` first and
   end with `exit "$rc"`.
9. **Exit codes are a contract.** 0 success, 1 operational error, 2 usage error,
   3 environment error, 4 configuration error, and 5 for “nothing found” in the
   finder. `--help` and `--version` exit 0. A new failure mode gets classified
   into one of these, not a new number.
10. **Prose to stderr, data to stdout.** In a machine-readable format
    (`--format json|csv|tsv`, `-o -`) stdout must contain *only* the data: no
    banner, no progress, no summary. `is_machine_format` / `prose_stream` decide.
11. **The licence value never becomes an argument.** It travels through a
    temporary file that the child shell reads at run time. Register every secret
    with `redact_register` so `redact()` scrubs it from all output, and never let
    the internal marker `@@WP_CLI_UPDATE_LICENCE@@` reach an operator-facing
    message.
12. **Secrets are not defaults.** No plugin list, no e-mail address, no hostname,
    no path from anybody's production host belongs in the shipped code. Site-
    specific values go into `wp-cli-update.conf`, which is not committed.
13. **A soft failure still returns its outcome.** A helper that logs a warning
    and returns 0 unconditionally makes every `if helper; then` branch dead code
    — that is how the Astra retry path became unreachable.
14. **Do not count an informational probe as an operation.** `wp core
    check-update` exits 1 when the site is up to date; counting it reports a
    healthy fleet as broken.

### Fleet-wide rules added in v6.2.0

15. **A worker may not touch parent state — it cannot.** A subshell's increments
    are lost at exit. Every number a worker produces goes into
    `${WORK_DIR}/wN/res`, and `fold_worker` is the only place that adds them up.
    A worker zeroes its counters at fork: without that it reports the running
    total and every batch after the first double-counts. `test_fleet.sh` runs the
    same fleet at `-j 1`, `-j 2`, `-j 3` and `-j 5` and asserts identical totals,
    which is the check that catches a regression here.
16. **Nothing writes to the console or the log file from inside a worker.** Both
    go to fragments and are replayed at the barrier in site order, so neither the
    terminal nor the log interleaves. If you need to emit from a worker, decide
    which of the three sinks it belongs to — `out` for prose, `log` for log lines,
    `data` for machine-readable payloads — and use that.
17. **A backup that failed is not a backup that was skipped.** If `--backup` was
    asked for and produced no file, the site must not be updated, unless
    `--fail-on never` says otherwise. A truncated dump is worse than no dump,
    because it looks like a backup.
18. **A deletion backs up and deactivates first.** `plugin delete` on an active
    plugin leaves its options, tables and cron events behind, because the
    deactivation hooks never run.
19. **`-j N` is a batch barrier and must stay one.** Bash 4.2 has no `wait -n`.
    If a change needs a continuous pool, raise the documented bash floor in the
    same commit and say so in the CHANGELOG.
20. **A new fleet-wide setting needs all of these**, or it will work on the
    command line and silently not work from a config file: a `DEFAULT_*`
    constant, an entry in `CONFIG_KEYS`, an `apply_conf` line, validation in both
    `config_validate_layer` and `validate_args`, a line in `print_config`, a line
    in `--check`'s report, a help entry, a documented default in
    `wp-cli-update.conf.example`, and a precedence check in `test_fleet.sh`.
21. **`is_set` / `env_value` consult `printenv`,** not only shell variables. A
    version that tested `${!NAME+x}` alone made the whole environment layer of
    the documented precedence disappear, and every check still passed because
    they all set shell variables. Read the environment the way a login shell
    hands it over.

## Conventions

- bash 4.2+; `shopt -s inherit_errexit` where available.
- 4 spaces, no tabs, no line over ~100 characters, LF endings (`.gitattributes`
  enforces it), `#!/usr/bin/env bash`, `# shellcheck shell=bash` at the top.
- **ShellCheck must be clean at the default severity — zero findings, including
  informational ones.** Suppress with a `# shellcheck disable=` directive only
  when the finding is genuinely wrong, and say why in the directive comment. Two
  known cases: `SC2016` where a single-quoted string is a literal shell snippet,
  and `SC2254` where a glob in a `case` pattern is the point.
- `local` on every function variable; declare and assign on separate lines
  (`SC2155`); never `local x=$(…) x=…` on one line (`SC2318`).
- Quote every expansion. Use `--` before any path that could start with `-`.
- Comments explain *why*, not what. If a construct is subtle enough to need a
  comment, the comment records what was measured, not what was assumed — see
  `build_find_args` for the model.
- Functions are small and named for what they decide, not how they do it.
- English in code and UI strings. A generated document in another language next
  to an English one is how a repository ends up with two sources of truth.

## Definition of done

A change is finished when all of these hold:

```bash
bash -n Bash_WP-CLI_Update.sh Find_WP_Senior.sh          # parses
shellcheck Bash_WP-CLI_Update.sh Find_WP_Senior.sh \
           tools/scan-secrets.sh tests/*.sh tests/stub/wp # zero findings
bash tests/run_tests.sh                                   # 532 checks, zero failures
bash tools/scan-secrets.sh --strict                       # exit 0
```

…and, for anything that touches behaviour:

```bash
Bash_WP-CLI_Update.sh --check                  # environment and sites
Bash_WP-CLI_Update.sh --list-sites             # what would be touched, and as whom
Bash_WP-CLI_Update.sh --full --dry-run         # the exact commands, per site
Bash_WP-CLI_Update.sh --full --dry-run -j 4    # the same, at the intended width
Find_WP_Senior.sh --output - /one/small/root   # only that root, nothing else
```

If a change alters the public surface — a mode, an option, an exit code, a
default, the site-list format — update `README.md`, add a `CHANGELOG.md` entry
under **Changed** and mark it `BREAKING` when a caller would notice, and add a
check to `tests/test_base_contract.sh`. That suite exists so the next rewrite
cannot quietly drop what this one promises.

## Things that look like improvements and are not

- Adding `-e` “for safety”. See rule 1.
- “Simplifying” `run_as_user` into a quoted string. See rule 2.
- Passing the licence as an argument because the temporary file needs a relaxed
  mode. `licence_open()` documents the trade-off and the rejected alternatives.
- Sourcing the config file “because it is more flexible”. See rule 5.
- Scanning `/` by default “so nothing is missed”. The operator names the roots;
  the tool must not exceed them.
- Reporting a finding from the secret guard as a verdict. It reports shapes. A
  false negative is the expensive direction, so the placeholder rule stays narrow
  and a real value that contains the word `example` is reported.
- Deleting a test that fails in your environment. Make it SKIP with a reason; the
  harness has `skip` for exactly that. A suite that silently tests nothing is
  worse than no suite, because it is trusted.
