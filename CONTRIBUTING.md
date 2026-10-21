# Contributing

Two files matter more than this one: `AGENTS.md` (install, configure, verify, and the
absolute do-nots) and `docs/COMPARISON.md` (why the code looks the way it does).
Read them before changing anything.

## The rules that are not negotiable

The product runs as root and changes live sites. Four invariants have a test each, and
a change that breaks one of them will not be merged:

1. **Every WP-CLI call is an argv array.** No string is ever handed to a shell. No
   `eval`, no `printf %q`, no `su -c` without `-s`.
2. **Configuration is data.** A config file is parsed as `KEY=VALUE`, never sourced; a
   shell metacharacter rejects the whole file; a group- or world-writable file is
   refused before it is read.
3. **The licence never becomes an argument of any process.** It travels through a
   temporary file readable by root and the site owner's group, and is unlinked when the
   call returns.
4. **A backup happens before anything is modified**, and a failed backup stops the site
   instead of updating it unprotected.

## Adding a feature

The order is fixed, and it is the same order in `AGENTS.md` §10:

1. flag in `parse_args`, validation in `validate_args`;
2. key in `CONFIG_KEYS`, `config_validate_layer`, `config_apply_all`, `print_config`
   and `wp-cli-update.conf.example`;
3. the function, wired into `run_mode` (a mode) or `process_site` (a policy) — never
   into a second copy of the dispatch;
4. `--help` and `README.md` (the static suite checks that every advertised option is
   documented);
5. a check in `tests/test_v7.sh`, or a new `tests/test_<area>.sh` registered in
   `tests/run_tests.sh`;
6. `bash tests/run_tests.sh` and `shellcheck`, then bump the version in the script,
   `README.md` and `CHANGELOG.md` together.

A read-only mode must also be added to `mode_is_readonly`, or it will take a lock and a
backup it does not need.

## Versioning

Semantic versioning, with one local convention: the manager, the finder and the
documentation move together, and `CHANGELOG.md` gets the entry in the same commit.
`tests/test_static.sh` fails if the three disagree.

## Commits

* One change per commit, with the reason in the message, not the diff.
* No generated files: no logs, no backups, no site list, no `dist/`, no `.ragraf/`.
* Line endings are LF (`core.autocrlf=input`, `.gitattributes` enforces it). On Windows
  a checkout that flips endings will fail `tests/test_static.sh` with a CR-byte count —
  that is the test doing its job.
* Do not commit a credential, a licence value or a real host name. `tools/scan-secrets.sh`
  runs in the suite and in CI.

## Running the tests

```bash
bash tests/run_tests.sh          # everything
bash tests/run_tests.sh v7       # one suite
sudo bash tests/run_tests.sh     # the user-switch checks need root
unshare -r bash tests/run_tests.sh   # ...or borrow uid 0 in a private namespace
```

The suite needs no WordPress, no WP-CLI and no network: it builds synthetic site trees
and a stub `wp`. A check that cannot run reports `SKIP` with the reason; a `FAIL` is a
real regression and the message names the expected and the actual value.

## Reporting a problem

Include the version (`./Bash_WP-CLI_Update.sh --version`), the exact command line, the
relevant configuration keys (values redacted) and the exit code. For anything that can
become code execution as root, use the private channel in `SECURITY.md`, not an issue.
