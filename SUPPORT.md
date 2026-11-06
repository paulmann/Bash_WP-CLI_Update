# Support

This project is maintained by one volunteer. There is no commercial support, no paid
tier and no service-level agreement: an answer is best effort, and a fix lands when there
is a reproducible report and the maintainer has time to make it. Nothing in this document
creates a support obligation.

## 1. Read the documentation first

Most questions about installation, configuration and exit codes are already answered:

| Document | Answers |
|---|---|
| [README.md](README.md) | what the tool does, every mode and option, every configuration key, exit codes, the production profile |
| [AGENTS.md](AGENTS.md) | the install-and-operate map for an agent or a careful human: install, verify, operate, the non-negotiable rules, the do-not list |
| [docs/README.md](docs/README.md) | the documentation index, by document and by task |
| [docs/PUBLISHING.md](docs/PUBLISHING.md) | how a release is cut, if you are packaging the tool |
| [the wiki](https://github.com/paulmann/Bash_WP-CLI_Update/wiki) | walkthroughs, host notes and the material that does not belong in the repository |

Start with the wiki for a first installation on a host; the repository documents are
canonical when the two disagree.

## 2. Search the existing issues before opening one

<https://github.com/paulmann/Bash_WP-CLI_Update/issues>

Search first: a fleet problem is often already reported with the distribution, bash
version and WP-CLI version that trigger it. One compatibility report per unique
distribution, bash, coreutils and WP-CLI version combination is enough - duplicates are
closed and the first report is kept.

## 3. Choose the right channel

| What you have | Where it goes |
|---|---|
| A mode, an option or an exit code that contradicts the documentation | the **Bug report** form |
| A capability the tool does not have | the **Feature request** form |
| Anything that can become code execution as root, a credential leak or data loss | privately, per [SECURITY.md](SECURITY.md), never a public issue |
| A question about installation or configuration | the documents and the wiki in step 1 first; there is no question form, so open a bug report only when something contradicts the documentation |

Blank issues are disabled on purpose: the forms ask for the facts that make a report
actionable.

## 4. What a bug report must contain

* the output of `./Bash_WP-CLI_Update.sh --version`;
* the exact command line, copied rather than retyped;
* the relevant configuration keys with their values **redacted** - keep the key name and
  cut the value; `LICENCE`, `MAIL_TO`, `NOTIFY_WEBHOOK` and every credential must never
  appear;
* the exit code (the contract is in README section 10: `0` success, `1` operational
  failure, `2` usage, `3` environment, `4` configuration, `130` or `143` interrupted);
* the distribution and the bash version (`bash --version | head -1`);
* what you observed and what you expected instead;
* the steps that reproduce it, starting from a site list;
* the relevant lines of `ERROR_LOG_FILE`, with site paths, values and site content
  redacted.

Never paste a licence value, a database password, a `wp-config.php` secret, a complete
`wp-config.php` or real site content. `--secrets` reports constant names and never their
values; a report should follow the same rule.

## 5. Security issues

A vulnerability does not belong in the issue tracker. [SECURITY.md](SECURITY.md) names
the private channel and what to include, and lists the behaviours that are known and
deliberate so that they are not reported again.

## 6. Supported versions

Quoted from [SECURITY.md](SECURITY.md), with the 6.x and 5.x rows collapsed into one:

| Version | Supported |
|---|---|
| 8.0.x | yes |
| 7.0.x | security fixes only (the modular `src/` tree, kept as its own release) |
| 6.x and older | no (`legacy/` is kept for citations, not for use) |

A report against an unsupported version may be closed with a pointer to 8.0.x. Upgrading
is a file copy; `CHANGELOG.md` names what moved.
