# Publishing a release

Three artefacts, one version number. The order matters, because each step checks the one
before it.

## 1. Bump the version everywhere

`tests/test_static.sh` fails if these disagree, so it is cheaper to do them together:

| File | What |
|---|---|
| `Bash_WP-CLI_Update.sh` | `# Version:` in the header **and** `SCRIPT_VERSION=` |
| `package.json` | `"version"` (the npm package) |
| `README.md` | the `Version:` line and the archive name in §3 |
| `CHANGELOG.md` | a `## [X.Y.Z / 2.1.0]` section — the release notes are cut from it |
| `AGENTS.md`, `wp-cli-update.conf.example`, `PROJECT_MAP.md` | the version they mention |

Then run the suites: `bash tests/run_tests.sh` (on Linux, as root or under `unshare -r`).

## 2. git

```bash
git add -A
git commit -m "X.Y.Z - what changed"
git push origin main
git tag -a vX.Y.Z -m "X.Y.Z - what changed"
git push origin vX.Y.Z
```

The tag starts `.github/workflows/release.yml`, which re-runs the gates, refuses to publish
when the tag and `SCRIPT_VERSION` disagree, builds `dist/`, and attaches the tarball plus
`SHA256SUMS` to the release. If the release already exists it uploads the assets again
instead of failing.

## 3. npm

The registry needs a token with **publish** permission; the repository deliberately holds
none, and the workflow does not publish to npm. A CI step would have to carry a
credential-shaped line, which the project's own write guard refuses — and a secret in a
repository is a worse trade than one command typed by hand.

```bash
cd <checkout>
npm login            # once per machine; stores a token in ~/.npmrc
npm whoami           # must print your npm account
npm publish --access public
```

Before publishing, `npm publish --dry-run` shows the file list and the size. The package is
`bash-wp-cli-update`, `os: linux`, licence PolyForm Noncommercial 1.0.0, and `files` is a
whitelist, so the tarball holds the two scripts, the two shims, the config example,
`contrib/`, `install.sh` and the documentation — 18 files, about 107 kB.

Check the result from a clean machine:

```bash
npm view bash-wp-cli-update version          # must equal the tag
npm install -g bash-wp-cli-update
wp-cli-update --version                      # must print the same version
```

### Two things that look like failures and are not

- **`npm view <name>` returns 404 for a few seconds after a successful publish.** The
  publish goes to the write side of the registry; reads come from a replica. `npm publish`
  printing `+ bash-wp-cli-update@X.Y.Z` is the success signal — wait a minute and ask
  again before concluding anything went wrong. Measured on 8.0.4: 404 at 11:45:50, the
  document answered at 11:46:46 with `dist-tags.latest` already correct.
- **The version list contains `0.0.0-stage`, with `"stub": true`.** That is npm's own
  placeholder, created at publish time while the tarball is scanned. It is not something
  this project published and it can never be reached through the `latest` tag.

## 4. What must not drift

| Pair | Checked by |
|---|---|
| `SCRIPT_VERSION` ↔ `package.json` | `tests/test_static.sh` |
| tag ↔ `SCRIPT_VERSION` | the release workflow |
| `CHANGELOG` section ↔ release notes | the release workflow (it cuts the body from the section) |
| `SHA256SUMS` ↔ the attached archive | `sha256sum -c SHA256SUMS` next to the download |
