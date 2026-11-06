## What and why

<!-- One paragraph: what this pull request changes, and the problem it solves.
     Link the issue or the report it answers. -->

## How it was verified

<!-- The commands you actually ran and their results, not the word "tests pass".
     State the Linux distribution and bash version; a SKIP needs its reason. -->

| Command | Result |
|---|---|
| `bash tests/run_tests.sh` | <!-- e.g. 634 passed, 0 failed, 7 skipped --> |
| `shellcheck Bash_WP-CLI_Update.sh Find_WP_Senior.sh tests/*.sh tools/scan-secrets.sh` | <!-- clean, or the remaining warnings --> |
| `./Bash_WP-CLI_Update.sh --help` | <!-- the mode or option is documented --> |

## Checklist

- [ ] `bash tests/run_tests.sh` is clean: no `FAIL`, and every `SKIP` names its reason
- [ ] `shellcheck` is clean on all shell files: `Bash_WP-CLI_Update.sh`,
      `Find_WP_Senior.sh`, `tests/*.sh`, `tools/scan-secrets.sh`
- [ ] No `eval`, no backticks, no `printf %q` and no `su -c` without `-s` was introduced
- [ ] Configuration is still data only: parsed as `KEY=VALUE`, never sourced, a shell
      metacharacter still rejects the file, a wrong mode is still refused before reading
- [ ] The version is bumped in the script (`SCRIPT_VERSION`), `package.json`, `README.md`
      and `CHANGELOG.md` if behaviour changed
- [ ] Documentation is updated: `README.md`, `AGENTS.md`, `CHANGELOG.md` and the file
      counts and lists in `PROJECT_MAP.md`
- [ ] No credential, licence value, host name or personal data is included
- [ ] Line endings are LF (`.gitattributes` enforces it; `tests/test_static.sh` fails on
      a CR byte)

## Notes on risk

<!-- This tool runs as root and changes live WordPress sites, so a reviewer reads the
     diff for behaviour, not for style. Say here what a reviewer should look at: -->

- Does a new read-only mode appear in `mode_is_readonly` (otherwise it takes a lock and
  a backup it does not need)?
- Does anything modify a site before its backup succeeds, and is a failed backup still
  fatal?
- Is every WP-CLI argument still an array element, with no string handed to a shell?
- Is the licence still kept out of `argv` and out of the report?
- Do the exit codes still match the documented contract (`0`, `1`, `2`, `3`, `4`,
  `130`/`143`)?
