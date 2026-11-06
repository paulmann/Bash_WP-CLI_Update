# Development guide

The test suites, the static gates, the fixed order for adding a feature, the version
rules and the release pointer. Everything here applies to a change to the product, not
to running it — for that see [AGENT-INSTALL.md](AGENT-INSTALL.md) and
[AGENT-OPERATIONS.md](AGENT-OPERATIONS.md).

## 1. Running the tests

```bash
bash tests/run_tests.sh              # all suites
bash tests/run_tests.sh v7           # the 8.0.0 feature suite
TEST_SITE_USER=www-data bash tests/run_tests.sh
```

The suites are hermetic: synthetic site trees, a stub `wp` that records its argv, no
network, no WordPress. Run them as root (or with `unshare -r`): the manager refuses to
run without root, so the exit-code paths cannot be exercised otherwise. A check that
still cannot run — no switchable account, no `ionice` — reports `SKIP` with its reason.
Any `FAIL` is a real regression: read the message, it names the expected and the
actual value.

Measured on Debian 12 with `unshare -r`: 634 passed, 0 failed, 7 skipped. On a plain
non-root account the user-switch checks in `test_manager.sh` fail with exit 3, which is
the product's own refusal, not a test defect.

Static checks that must pass before a commit:

```bash
shellcheck Bash_WP-CLI_Update.sh Find_WP_Senior.sh tests/*.sh tools/scan-secrets.sh
bash tests/test_static.sh
```

The suite also enforces: no `eval`, no backticks, no `printf %q`, no `su -c` without
`-s`, no `"${arr[@]:-}"` (it expands to one empty element in bash 4.4+), no e-mail
addresses and no site-specific plugin list in shipped code, LF line endings, executable
bits, and version agreement between the script, `README.md` and `CHANGELOG.md`.

One known wart in the test tree: `tests/test_manager.sh` declares a placeholder licence
value in a variable called `SECRET`, assigned with an equals sign. The project's own write
guard reads that shape as a credential literal and refuses to rewrite the file, so the
file is edited by hand. Renaming that variable (and its two uses) to `PLACEHOLDER_VALUE`
is the clean fix.

## 2. Adding a feature

The order is fixed:

1. add the flag in `parse_args` and in `validate_args`;
2. add the config key to `CONFIG_KEYS`, to `config_validate_layer`,
   `config_apply_all`, `print_config` and `wp-cli-update.conf.example`;
3. add the function and wire it into `run_mode` (or into `process_site` when it is not a
   mode) — never into an `if` chain that duplicates the dispatch;
4. document it in `--help` (the static suite checks the option is mentioned) and in
   `README.md`;
5. add a check to `tests/test_v7.sh` (or a new `tests/test_<area>.sh` and register it in
   `tests/run_tests.sh`);
6. run `bash tests/run_tests.sh` and `shellcheck`, and bump `SCRIPT_VERSION` in the
   script, `README.md`, `package.json` and `CHANGELOG.md` together.

## 3. Rules for the code itself

* every WP-CLI call is an array; no string is ever handed to a shell;
* a command that can fail must set `WP_STATUS` and let the caller decide;
* use `mktemp` and `tmp_register` for temporary files, so the EXIT trap removes them;
* a new read-only mode must be added to `mode_is_readonly`, or it will take a lock and
  a backup it does not need;
* never write to `$SITE_URL` for a single site: use `site_url_effective`, which honours
  the command line first.

## 4. Versioning and the release

Semantic versioning, with one local convention: the manager, the finder and the
documentation move together, and `CHANGELOG.md` gets the entry in the same commit.
`tests/test_static.sh` fails if `SCRIPT_VERSION` and `package.json` disagree, and the
release workflow fails if the tag and `SCRIPT_VERSION` disagree.

A release is cut from `main` after CI is green (see [PUBLISHING.md](PUBLISHING.md)):

1. bump the version everywhere the table there lists;
2. commit, push, and create an annotated tag `vX.Y.Z` and push it;
3. the tag starts `.github/workflows/release.yml`, which re-runs the gates, builds
   `dist/bash-wp-cli-update-X.Y.Z.tar.gz` plus `SHA256SUMS`, and publishes the release;
4. the same workflow publishes the npm package over OpenID Connect (trusted publishing),
   so no token is stored anywhere;
5. verify by reading the remote: release page, asset checksum, `npm view
   bash-wp-cli-update version`.

## 5. Reporting a problem

A bug: use the issue forms under `.github/ISSUE_TEMPLATE/`. A vulnerability: the private
advisory channel in [SECURITY.md](../SECURITY.md), never a public issue.
