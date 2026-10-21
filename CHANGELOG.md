# Bash_WP-CLI_Update Changelog

Automatically maintained by DevAgent.

- [2026-10-07T09:19:20] Find_WP_Senior.sh (backup v2) - refactor 1.01.0 -> 2.0.0: correct find expression, anchored excludes, atomic output, new options
- [2026-10-07T09:19:29] Find_WP_Senior.sh (backup v3) - declare EXCLUDE_CLI, drop stray line, guard find_errors
- [2026-10-07T09:19:58] Find_WP_Senior.sh (backup v4) - normalise $0 separators and TMPDIR base for MSYS/Git Bash portability
- [2026-10-07T09:20:33] Find_WP_Senior.sh (backup v5) - fix empty-list write return code; soften no-default-roots handling
- [2026-10-07T09:25:32] Bash_WP-CLI_Update.sh (backup v2) - v6.0.0 part 1/3: header, identity, defaults, logging, locking, usage
- [2026-10-07T09:25:56] Bash_WP-CLI_Update.sh (backup v3) - v6.0.0 part 2/3: config, args, user detection, wp_exec, plugin helpers
- [2026-10-07T09:26:08] Bash_WP-CLI_Update.sh (backup v4) - v6.0.0 part 3/3: sites, modes, process_site, summary, main
- [2026-10-07T09:26:40] Find_WP_Senior.sh (backup v6) - guard collect_meta against an empty SITES array (bash 4.2/4.3 set -u)
- [2026-10-07T09:26:55] Bash_WP-CLI_Update.sh (backup v5) - JSON summary key: failures -> errors_logged
- [2026-10-07T09:26:55] Bash_WP-CLI_Update.sh (backup v6) - reject --action/--name outside their modes
- [2026-10-07T09:27:37] Bash_WP-CLI_Update.sh (backup v7) - re-apply lost edits: need_value, extract_conf_file, WP env HOME/USER, success counter, root handling
- [2026-10-07T09:33:15] Bash_WP-CLI_Update.sh (backup v8) - add AUTO_DISCOVER switch; document it
- [2026-10-07T09:39:56] Bash_WP-CLI_Update.sh (backup v9) - dry-run previews for plugin matching and astra state
- [2026-10-07T09:40:16] wp-cli-update.conf.example - config example for v6.0.0 (safe to commit: no secrets)
- [2026-10-07T09:40:16] .gitignore - keep runtime artefacts and secrets out of the repository
- [2026-10-07T09:41:23] README.md (backup v1) - document v6.0.0 updater and v2.0.0 finder: new options, config file, exit codes, output contract
- [2026-10-07T09:41:47] .gitignore (backup v1) - fix: leading spaces made the patterns literal; anchor runtime artefacts
- [2026-10-07T09:43:01] .gitattributes - force LF for shell scripts, keep CRLF for Windows helpers
