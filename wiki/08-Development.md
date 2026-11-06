# Development

## Running the tests

```bash
bash tests/run_tests.sh              # every suite
bash tests/run_tests.sh v7           # one suite
bash tests/run_tests.sh cve          # the 8.1.0 security suite
TEST_SITE_USER=www-data bash tests/run_tests.sh
unshare -r bash tests/run_tests.sh   # borrow uid 0 in a private namespace
```

The suites are hermetic: synthetic site trees, a stub `wp` that records its own argv, no
network, no WordPress, no WP-CLI, no root required to start them. Run them as root or under
`unshare -r`, because the manager refuses to run without root and the exit-code paths
cannot be exercised otherwise.

A check that still cannot run — no switchable account, no `ionice` — reports `SKIP` with its
reason, and that is a correct result, not a gap. A `FAIL` is a real regression: the message
names the expected and the actual value. Measured results, as the project records them:

| Environment | Result |
|---|---|
| Debian 12, `unshare -r` (uid 0, no switchable account) | 634 passed, 0 failed, 7 skipped |
| Windows host, Git Bash, non-root | 0 failures outside the root-only checks; `chmod`, `ionice` and user-switch checks skip |
| Plain non-root account | the user-switch checks in `test_manager.sh` fail with exit 3, which is the manager refusing to run |

| Suite | Covers |
|---|---|
| `tests/test_static.sh` | syntax, shellcheck, CRLF, permissions, banned constructs, version consistency |
| `tests/test_base_contract.sh` | the public surface of the original scripts: modes, options, exit codes, the opt-out marker, scope |
| `tests/test_finder.sh` | the finder: discovery, JSON, depth, exclusions |
| `tests/test_manager.sh` | every mode, argv shape, listing formats, config layers |
| `tests/test_fleet.sh` | parallelism, counters, JSON Lines, config security |
| `tests/test_secretguard.sh` | `tools/scan-secrets.sh` |
| `tests/test_v7.sh` | read-only modes, restore, retries, circuit breaker, guards, report, policy lists, config aliases |
| `tests/test_cve.sh` | the 8.1.0 security set: `--security` verdicts and exit codes, the `.htaccess` deny block, `--harden-upgrade-dir`, the `--health` CVE column |

`tests/test_cve.sh` is the gate for the CVE-2026-119977 work, and it enforces the rules that
are easy to lose: a read-only mode never writes `.htaccess`, never exports a database and
never takes the lock; `--security` exits 1 exactly when a site's core is below the fixed
release and 0 when it is at or above it; `--harden` is idempotent, keeps the original file
and backs it up once; and the nginx directive is printed, because nginx cannot be fixed
from `.htaccess`. Its fixture is a stub `wp`, so the suite runs without WordPress.

## The two static gates

Both must pass before a commit:

```bash
shellcheck Bash_WP-CLI_Update.sh Find_WP_Senior.sh tests/*.sh tools/scan-secrets.sh
bash tests/test_static.sh
```

`tests/test_static.sh` also enforces the invariants that a shell script loses quietly: no
`eval`, no backticks, no `printf %q`, no `su -c` without `-s`, no `"${arr[@]:-}"` (it
expands to one empty element in bash 4.4+), no e-mail addresses and no site-specific plugin
list in shipped code, LF line endings, executable bits, every advertised option documented
in `--help`, and version agreement between the script, `README.md`, `CHANGELOG.md` and
`package.json`.

## Adding a feature

The order is fixed, and it is the same order as `docs/DEVELOPMENT.md`:

1. add the flag in `parse_args` and in `validate_args`;
2. add the config key to `CONFIG_KEYS`, `config_validate_layer`, `config_apply_all`,
   `print_config` and `wp-cli-update.conf.example`;
3. add the function and wire it into `run_mode` (a mode) or `process_site` (a policy) —
   never into an `if` chain that duplicates the dispatch;
4. document it in `--help` (the static suite checks the option is mentioned) and in
   `README.md`;
5. add a check to `tests/test_v7.sh` (or `tests/test_cve.sh` for the security surface), or a
   new `tests/test_<area>.sh` registered in `tests/run_tests.sh`;
6. run `bash tests/run_tests.sh` and `shellcheck`, then bump the version together.

Rules for the code itself:

* every WP-CLI call is an array; no string is ever handed to a shell;
* a command that can fail must set `WP_STATUS` and let the caller decide;
* use `mktemp` and `tmp_register` for temporary files, so the EXIT trap removes them;
* a new read-only mode must be added to `mode_is_readonly`, or it will take a lock and a
  backup it does not need;
* never write to `$SITE_URL` for a single site: use `site_url_effective`, which honours the
  command line first.

One known wart in the test tree: `tests/test_manager.sh` declares a placeholder licence
value in a variable called `SECRET`, assigned with an equals sign. The project's own write
guard reads that shape as a credential literal and refuses to rewrite the file, so the file
is edited by hand; renaming the variable and its two uses to `PLACEHOLDER_VALUE` is the
clean fix.

## Version consistency

The manager, the finder and the documentation move together, and the finder is versioned
separately (2.1.0 from 6.2.0 onwards). The current release is 8.1.0 with finder 2.1.0. A
bump touches `SCRIPT_VERSION` in `Bash_WP-CLI_Update.sh`, the `Version:` line and the
archive name in `README.md`, `package.json`, the `CHANGELOG.md` section, and the version
mentioned in `AGENTS.md`, `wp-cli-update.conf.example` and `PROJECT_MAP.md`.
`tests/test_static.sh` fails if `SCRIPT_VERSION` and `package.json` disagree, the release
workflow fails if the tag and `SCRIPT_VERSION` disagree, and the release notes are cut from
the changelog section.

Since 8.1.0 the GitHub wiki is versioned next to the code in `wiki/`: the pages and
`wiki.json` are the sources, and `ghagent wiki build` and `ghagent wiki verify` are run on
a change to them, so a page cannot be published with a broken link or an unlisted page. A
bump that changes a number a page states has to change the page in the same commit; no
static check enforces that yet.

## The release, in one paragraph

Bump the version in every place listed above and run the suites; commit and push `main`;
create an annotated tag `vX.Y.Z` and push it. The tag starts `.github/workflows/release.yml`,
which re-runs the gates, refuses to publish when the tag and `SCRIPT_VERSION` disagree,
builds `dist/bash-wp-cli-update-X.Y.Z.tar.gz` with `SHA256SUMS`, and attaches both to the
release (re-uploading the assets if the release already exists). The same workflow publishes
the npm package `bash-wp-cli-update` over OpenID Connect trusted publishing, so no token is
stored anywhere; verify from a clean machine with `sha256sum -c SHA256SUMS`,
`npm view bash-wp-cli-update version` and `wp-cli-update --version`. 8.1.0 is the worked
example of that order: the security modes, the `HARDEN_UPGRADE_DIR` key, the CVE column in
`--health`, the MIT licence and the wiki sources all landed in the release commit.

## Reporting a problem

A bug goes through the issue forms in `.github/ISSUE_TEMPLATE/` (`bug_report.yml`,
`feature_request.yml`); include the version (`./Bash_WP-CLI_Update.sh --version`), the exact
command line, the relevant configuration keys with values redacted, and the exit code.

A vulnerability does not: use the private advisory channel described in
[SECURITY.md](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/SECURITY.md), never a
public issue, for anything that can become code execution as root.
