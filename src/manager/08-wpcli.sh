###############################################################################
# Section 15 - WP-CLI resolution
###############################################################################

# wp_resolve -> the wp binary to use, or non-zero.
#
# An operator who configured a path means that path. Falling back to whatever
# `wp` happens to be in PATH would run a different WP-CLI than the one that was
# asked for, against a fleet, without saying so -- so a configured path that does
# not exist is an error, not a hint.
wp_resolve() {
    local candidate
    if [ -n "${CLI_SET[WP_CLI_PATH]-}" ] || [ -n "${CONF_SRC[WP_CLI_PATH]-}" ]; then
        if [ -x "$WP_CLI_PATH" ] && [ ! -d "$WP_CLI_PATH" ]; then
            printf '%s' "$WP_CLI_PATH"
            return 0
        fi
        log_error "configured wp-cli is not an executable file: ${WP_CLI_PATH}"
        return 1
    fi
    if [ -n "$WP_CLI_PATH" ] && [ -x "$WP_CLI_PATH" ] && [ ! -d "$WP_CLI_PATH" ]; then
        printf '%s' "$WP_CLI_PATH"
        return 0
    fi
    for candidate in wp /usr/local/bin/wp /usr/bin/wp "${HOME:-/root}/wp-cli.phar"; do
        if command -v -- "$candidate" >/dev/null 2>&1; then
            command -v -- "$candidate"
            return 0
        fi
        if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# wp_ensure : resolve once and remember. Called from every wp invocation, so it
# must be cheap after the first time.
wp_ensure() {
    if [ -n "$WP_RESOLVED" ]; then return 0; fi
    WP_RESOLVED="$(wp_resolve)" || {
        log_error "WP-CLI not found (looked for '${WP_CLI_PATH}', then wp in PATH, /usr/local/bin/wp, /usr/bin/wp)"
        log_error 'install it with --wpcli-install, or from https://wp-cli.org/, or set WP_CLI_PATH'
        return 1
    }
    log_debug "wp-cli resolved to ${WP_RESOLVED}"
    return 0
}

# wp_realpath -> the resolved path of the binary, through every symlink.
# A distribution package often installs /usr/local/bin/wp -> ../share/wp-cli.phar,
# and "is this file writable?" is a question about the target, not the link.
wp_realpath() {
    local p="${WP_RESOLVED:-$WP_CLI_PATH}"
    [ -n "$p" ] || return 1
    readlink -f -- "$p" 2>/dev/null || printf '%s' "$p"
}

# wp_install_kind -> phar | symlink | script | unknown
wp_install_kind() {
    local real base
    real="$(wp_realpath)" || { printf 'unknown'; return 0; }
    base="$(path_base "$real")"
    case "$base" in
        *.phar) printf 'phar' ;;
        *)
            # A composer or git install is a PHP file inside a vendor tree; a
            # distribution package is usually a small shell wrapper. The first
            # line tells them apart without executing anything.
            case "$(head -c 64 -- "$real" 2>/dev/null)" in
                *'<?php'*) printf 'php-source' ;;
                '#!'*) printf 'script' ;;
                *) printf 'unknown' ;;
            esac
            ;;
    esac
    return 0
}

# wp_upgradable -> 0 when this tool may replace the binary in place.
# `wp cli update` only works for the Phar installation mechanism, and a
# self-update that cannot write its own target is a failure the operator should
# hear about before the download, not after it.
wp_upgradable() {
    local real dir kind
    kind="$(wp_install_kind)"
    if [ "$kind" != 'phar' ]; then
        log_debug "wp-cli install kind is '${kind}'; 'wp cli update' only supports a phar"
        return 1
    fi
    real="$(wp_realpath)" || return 1
    [ -w "$real" ] && return 0
    dir="$(path_dir "$real")"
    [ -w "$dir" ] && return 0
    return 1
}

###############################################################################
# Section 16 - WP-CLI version policy
###############################################################################
#
# Why this exists: the tool drives `wp` across a fleet, and the difference
# between WP-CLI 1.5 and 2.11 is not cosmetic. `plugin update --all` on an
# ancient build, `db export` without `--add-drop-table`, `language` before it
# existed, `maintenance-mode` before WP 5.5 -- each is a mode that silently does
# something else than the operator read in the documentation. A version gate at
# startup turns that class of surprise into one line of output.
#
# The gate is a floor, not a pin. Being *behind* the floor is an environment
# error; being behind the newest release is a warning, because a fleet host that
# cannot reach the internet must still be able to run maintenance.

WP_CLI_FINGERPRINT_DEFAULT='63AF7AA15067C05616FDDD88A3A2E8F226F0BC06'

# wpcli_version_local -> the installed WP-CLI version, empty when it cannot be
# determined. Runs `wp cli version` *without* --path so that no WordPress is
# loaded: the answer must not depend on a site being healthy, and it must work
# on a host where the only problem is that every site is broken.
wpcli_version_local() {
    if [ -n "$WP_CLI_VERSION" ]; then
        printf '%s' "$WP_CLI_VERSION"
        return 0
    fi
    wp_ensure || return 1
    local out rc=0
    local -a argv=("$WP_RESOLVED" cli version)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>&1 </dev/null)" || rc=$?
    # `WP-CLI 2.11.0` is the normal answer; a nightly adds a suffix, and a broken
    # PHP install prints a fatal instead. Take the first thing that looks like a
    # version and ignore the rest.
    local line token
    while IFS= read -r line; do
        for token in $line; do
            token="${token%,}"
            if [[ "$token" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?$ ]]; then
                WP_CLI_VERSION="$token"
                printf '%s' "$WP_CLI_VERSION"
                return 0
            fi
        done
    done <<<"$out"
    log_debug "could not parse a version from 'wp cli version' (rc=${rc}): ${out}"
    return 1
}

# wpcli_latest_from_wp -> version + update_type from `wp cli check-update`.
# Preferred over the GitHub API because it is WP-CLI's own answer, it knows the
# channel, and it needs no JSON scraping of a third-party response.
WP_LATEST_UPDATE_TYPE=''
wpcli_latest_from_wp() {
    wp_ensure || return 1
    local out tsv rc=0
    local -a argv=("$WP_RESOLVED" cli check-update --format=json)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>/dev/null </dev/null)" || rc=$?
    # Exit 1 means "already the latest", which is an answer, not a failure.
    local body
    body="$(json_array_slice "$out" 2>/dev/null)" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv version update_type 2>/dev/null)" || return 1
    local ver type
    while IFS=$'\t' read -r ver type; do
        [ "$ver" = 'version' ] && continue
        [ -n "$ver" ] || continue
        WP_LATEST_VERSION="$ver"
        WP_LATEST_UPDATE_TYPE="${type:-unknown}"
        WP_LATEST_CHECKED='true'
        return 0
    done <<<"$tsv"
    return 1
}

# wpcli_latest_from_api -> version from the GitHub releases endpoint.
# Used when WP-CLI is absent or too old to have `cli check-update`, and when the
# operator pinned HTTP_CLIENT. Unauthenticated GitHub API requests are limited to
# 60 per hour per address; GITHUB_TOKEN raises that to 5000 and is honoured by
# passing it through when it is already in the environment.
wpcli_latest_from_api() {
    local body tag
    if ! body="$(http_get "$WP_CLI_RELEASE_API" 20)"; then
        log_debug "the release API did not answer: ${WP_CLI_RELEASE_API}"
        return 1
    fi
    tag="$(json_scalar tag_name <<<"$body")" || tag=''
    if [ -z "$tag" ]; then
        log_debug 'the release API answered without a tag_name'
        return 1
    fi
    WP_LATEST_VERSION="${tag#v}"
    WP_LATEST_CHECKED='true'
    return 0
}

# wpcli_latest [FORCE] -> the newest release, empty when it cannot be determined.
# Cached for the whole run: a fleet walk asks once, not once per site.
wpcli_latest() {
    local force="${1:-false}"
    if [ "$force" != 'true' ] && [ -n "$WP_LATEST_VERSION" ]; then
        printf '%s' "$WP_LATEST_VERSION"
        return 0
    fi
    WP_LATEST_VERSION=''
    WP_LATEST_UPDATE_TYPE=''
    if wpcli_latest_from_wp; then :
    elif wpcli_latest_from_api; then :
    else
        return 1
    fi
    printf '%s' "$WP_LATEST_VERSION"
    return 0
}

# wpcli_version_gate : the startup floor check.
#   - no wp at all              -> environment error (3), unless the mode does
#                                  not need one
#   - below WP_CLI_MIN_VERSION  -> environment error (3)
#   - unparsable version        -> warning, run continues (a gate that cannot
#                                    read the answer must not brick the host)
#   - older than the latest     -> warning, run continues
wpcli_version_gate() {
    local installed='' latest='' cmp=''
    # Called bare, not through $(...): the function caches its answer in the
    # WP_CLI_VERSION global, and a command substitution would cache it in a
    # subshell that disappears. The symptom was a run summary that reported an
    # empty wpcli_version even though the gate had just read it successfully.
    if ! wpcli_version_local >/dev/null; then
        if [ -n "$WP_RESOLVED" ]; then
            log_warn "wp-cli at ${WP_RESOLVED} did not report a version; the minimum-version check was skipped"
            return 0
        fi
        return 1
    fi
    installed="$WP_CLI_VERSION"
    log_debug "wp-cli installed version: ${installed} (minimum ${WP_CLI_MIN_VERSION})"
    if [ -n "$WP_CLI_MIN_VERSION" ]; then
        version_compare "$installed" "$WP_CLI_MIN_VERSION" >/dev/null
        if [ "$VERSION_CMP" = '-1' ]; then
            log_error "WP-CLI ${installed} is older than the required minimum ${WP_CLI_MIN_VERSION}"
            log_error "run '${PROG_NAME} --wpcli-update' to bring it up to date, or lower WP_CLI_MIN_VERSION if you know why"
            return 1
        fi
    fi
    if [ "$WP_CLI_LATEST_CHECK" != 'true' ]; then
        return 0
    fi
    if ! latest="$(wpcli_latest)"; then
        log_debug 'the newest WP-CLI release could not be determined (offline, rate limited, or no HTTP client); continuing'
        return 0
    fi
    version_compare "$installed" "$latest" >/dev/null
    if [ "$VERSION_CMP" = '-1' ]; then
        log_warn "WP-CLI ${installed} is behind the current release ${latest}${WP_LATEST_UPDATE_TYPE:+ (${WP_LATEST_UPDATE_TYPE} update)}; run '${PROG_NAME} --wpcli-update'"
    else
        log_debug "WP-CLI ${installed} is current"
    fi
    return 0
}

###############################################################################
# Section 17 - WP-CLI self-update
###############################################################################
#
# Two mechanisms, chosen by what the operator asked for:
#
#   wp cli update        WP-CLI's own updater. It downloads, smoke-tests the new
#                        phar, keeps the previous one as *.old and swaps it in.
#                        Used for channel updates (stable/nightly) and for
#                        patch/minor/major scope. Cannot install a pinned
#                        version, and only works for a phar install.
#
#   direct download      A specific release phar from the wp-cli GitHub release
#                        assets, verified with GPG (preferred) or SHA-512 before
#                        it replaces anything. Used for WP_CLI_TARGET_VERSION,
#                        for --wpcli-install, and as the fallback when the
#                        installed wp is not a phar.
#
# Both keep a timestamped copy of the binary they replaced, and --wpcli-rollback
# puts it back. A self-update with no way back is how a fleet loses its
# maintenance tool at the worst possible moment.

WPCLI_BUILDS_BASE='https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar'
WPCLI_RELEASE_BASE='https://github.com/wp-cli/wp-cli/releases/download'

# wpcli_download_urls VERSION -> phar|asc|sha512 URLs, one per line.
# An empty VERSION means "the moving latest build", which lives in the wp-cli
# builds repository; a pinned version is a GitHub release asset.
wpcli_download_urls() { # VERSION
    local ver="${1-}" name
    if [ -z "$ver" ]; then
        if [ "$WP_CLI_UPDATE_CHANNEL" = 'nightly' ]; then
            name='wp-cli-nightly.phar'
        else
            name='wp-cli.phar'
        fi
        printf 'phar|%s/%s\n' "$WPCLI_BUILDS_BASE" "$name"
        printf 'asc|%s/%s.asc\n' "$WPCLI_BUILDS_BASE" "$name"
        printf 'sha512|%s/%s.sha512\n' "$WPCLI_BUILDS_BASE" "$name"
    else
        name="wp-cli-${ver}.phar"
        printf 'phar|%s/v%s/%s\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
        printf 'asc|%s/v%s/%s.asc\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
        printf 'sha512|%s/v%s/%s.sha512\n' "$WPCLI_RELEASE_BASE" "$ver" "$name"
    fi
    return 0
}

# wpcli_verify PHAR WORKDIR -> 0 when the download is authentic.
#
# Fail-closed by design: when WP_CLI_VERIFY_PHAR is on and no verification method
# is available, the answer is "not verified", and the caller refuses to install.
# An unverifiable binary about to be executed as root on every site of a fleet is
# exactly the thing a maintenance tool must not shrug about.
wpcli_verify() { # PHAR WORKDIR
    local phar="${1-}" work="${2-}" kind url asc='' sum='' expected='' got=''
    if [ "$WP_CLI_VERIFY_PHAR" != 'true' ]; then
        log_warn 'phar verification is disabled (WP_CLI_VERIFY_PHAR=false); installing an unverified download'
        return 0
    fi
    while IFS='|' read -r kind url; do
        case "$kind" in
            asc) asc="${work}/phar.asc"
                 download_file "$url" "$asc" 60 || asc='' ;;
            sha512) sum="${work}/phar.sha512"
                    download_file "$url" "$sum" 60 || sum='' ;;
        esac
    done < <(wpcli_download_urls "$WP_CLI_TARGET_VERSION")

    # --- GPG ---------------------------------------------------------------
    if [ -n "$asc" ] && have gpg; then
        local gnupghome="${work}/gnupg"
        mkdir -p -- "$gnupghome" && chmod 700 "$gnupghome"
        local keyfile="${work}/wp-cli.pgp"
        if download_file "${WP_CLI_GPG_KEY_URL}" "$keyfile" 60; then
            if GNUPGHOME="$gnupghome" gpg --batch --quiet --import "$keyfile" >/dev/null 2>&1; then
                local fp=''
                fp="$(GNUPGHOME="$gnupghome" gpg --batch --with-colons --list-keys 2>/dev/null \
                      | awk -F: '/^fpr:/ {print $10; exit}')"
                if [ -n "$WP_CLI_GPG_FINGERPRINT" ] && [ "${fp^^}" != "${WP_CLI_GPG_FINGERPRINT^^//:/}" ]; then
                    log_error "the imported WP-CLI signing key has fingerprint ${fp}, expected ${WP_CLI_GPG_FINGERPRINT}"
                    log_error 'refusing to install: the key that would verify this download is not the published one'
                    return 1
                fi
                if GNUPGHOME="$gnupghome" gpg --batch --quiet --verify "$asc" "$phar" >/dev/null 2>&1; then
                    log_ok "GPG signature verified (fingerprint ${fp:-unknown})"
                    return 0
                fi
                log_error 'the GPG signature does not verify against the downloaded phar'
                return 1
            fi
            log_warn 'the WP-CLI signing key could not be imported; falling back to the checksum'
        else
            log_warn 'the WP-CLI signing key could not be downloaded; falling back to the checksum'
        fi
    elif [ -n "$asc" ]; then
        log_debug 'gpg(1) is not installed; falling back to the checksum'
    fi

    # --- SHA-512 / SHA-256 -------------------------------------------------
    if [ -n "$sum" ] && [ -s "$sum" ]; then
        local tool=''
        if have sha512sum; then tool='sha512sum'
        elif have shasum; then tool='shasum -a 512'
        elif have sha256sum; then tool='sha256sum'; fi
        if [ -n "$tool" ]; then
            # shellcheck disable=SC2086  # $tool is at most two fixed words
            got="$($tool "$phar" 2>/dev/null | awk '{print $1}')"
            expected="$(awk '{print $1; exit}' "$sum" 2>/dev/null)"
            if [ -n "$got" ] && [ "${got,,}" = "${expected,,}" ]; then
                log_ok "checksum verified with ${tool%% *}"
                return 0
            fi
            log_error "checksum mismatch: computed ${got:-<none>}, published ${expected:-<none>}"
            return 1
        fi
    fi

    log_error 'WP_CLI_VERIFY_PHAR is set but neither a GPG signature nor a checksum could be checked'
    log_error 'refusing to install an unverified phar; install gpg(1) or coreutils, or set WP_CLI_VERIFY_PHAR=false'
    return 1
}

# wpcli_backup PHAR -> the path of the timestamped copy, empty when it failed
wpcli_backup() { # PHAR
    local phar="${1-}" stamp dest dir
    [ -n "$phar" ] && [ -f "$phar" ] || return 0
    dir="$(path_dir "$phar")"
    if [ -n "$WP_CLI_BACKUP_DIR" ]; then
        dir="$WP_CLI_BACKUP_DIR"
        mkdir -p -- "$dir" 2>/dev/null || dir="$(path_dir "$phar")"
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    dest="${dir}/$(path_base "$phar").bak-${stamp}"
    if cp -p -- "$phar" "$dest" 2>/dev/null; then
        printf '%s' "$dest"
        return 0
    fi
    return 1
}

# wpcli_smoke_test PHAR -> 0 when the file is a working WP-CLI
wpcli_smoke_test() { # PHAR
    local phar="${1-}" out rc=0 php
    php="${PHP_BIN:-php}"
    if ! have "$php"; then
        log_debug "php binary '${php}' not found; skipping the pre-install smoke test"
        return 0
    fi
    local -a argv=("$phar" cli version)
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)
    out="$("${argv[@]}" 2>&1 </dev/null)" || rc=$?
    if ((rc != 0)); then
        log_error "the downloaded phar does not run: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
        return 1
    fi
    log_debug "downloaded phar reports: $(trim "$out")"
    return 0
}

# wpcli_install_phar DEST WORKDIR : verified, smoke-tested, atomic, reversible.
wpcli_install_phar() { # DEST WORKDIR
    local dest="${1-}" work="${2-}" tmp url kind backup new_version=''
    tmp="${work}/wp-cli.phar"
    while IFS='|' read -r kind url; do
        [ "$kind" = 'phar' ] || continue
        log_info "downloading ${url}"
        if ! download_file "$url" "$tmp" 300; then
            log_error "the download failed: ${url}"
            return 1
        fi
        break
    done < <(wpcli_download_urls "$WP_CLI_TARGET_VERSION")
    [ -s "$tmp" ] || { log_error 'the downloaded phar is empty'; return 1; }

    wpcli_verify "$tmp" "$work" || return 1
    wpcli_smoke_test "$tmp" || return 1

    if [ -f "$dest" ]; then
        if backup="$(wpcli_backup "$dest")"; then
            log_ok "previous binary kept as ${backup}"
        else
            log_warn "could not back up ${dest}; continuing, but there will be no rollback"
        fi
    fi
    # Same filesystem, so the rename is atomic: a reader never sees a half-written
    # wp, and a concurrent run either gets the old binary or the new one.
    local staged="${dest}.new.$$"
    if ! cp -- "$tmp" "$staged" 2>/dev/null; then
        # A different filesystem or an unwritable directory: fall back to writing
        # straight to a temporary name inside the target directory.
        staged="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || {
            log_error "cannot stage the new phar next to ${dest} (permission or filesystem problem)"
            return 1
        }
        cp -- "$tmp" "$staged" 2>/dev/null || { rm -f -- "$staged"; return 1; }
    fi
    chmod 0755 "$staged" 2>/dev/null
    if [ -f "$dest" ]; then
        chown --reference="$dest" -- "$staged" 2>/dev/null ||
            log_debug "could not copy the ownership of ${dest} onto the new phar"
    fi
    if ! mv -f -- "$staged" "$dest" 2>/dev/null; then
        rm -f -- "$staged" 2>/dev/null
        log_error "cannot replace ${dest}; check the permissions of $(path_dir "$dest")"
        return 1
    fi
    WP_RESOLVED='' WP_CLI_VERSION=''
    if new_version="$(wpcli_version_local)"; then
        log_ok "WP-CLI installed: ${new_version} at ${dest}"
    else
        log_warn "installed ${dest} but it does not report a version; check it with --wpcli-check"
    fi
    return 0
}

# wpcli_update_via_wp : let WP-CLI update itself.
wpcli_update_via_wp() {
    local -a argv=() out rc=0 before='' after=''
    before="$(wpcli_version_local)"
    argv=("$WP_RESOLVED" cli update)
    case "$WP_CLI_UPDATE_CHANNEL" in
        nightly) argv+=(--nightly) ;;
        stable) argv+=(--stable) ;;
    esac
    case "$WP_CLI_UPDATE_SCOPE" in
        patch) argv+=(--patch) ;;
        minor) argv+=(--minor) ;;
        major) argv+=(--major) ;;
        auto | *) : ;;   # WP-CLI's own default: newest within the current major
    esac
    [ "$WP_CLI_INSECURE" = 'true' ] && argv+=(--insecure)
    if [ "$ASSUME_YES" = 'true' ] || [ "$FORCE_DELETE" = 'true' ] || [ "$WP_CLI_UPDATE_YES" = 'true' ] || [ ! -t 0 ]; then
        argv+=(--yes)
    fi
    [ "$(id -u)" -eq 0 ] && argv+=(--allow-root)

    log_info "running: $(argv_display "${argv[@]}")"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info '[dry-run] nothing was changed'
        return 0
    fi
    # GITHUB_TOKEN lifts the unauthenticated 60-requests-per-hour limit on the
    # releases API. It is forwarded when the operator already has it, and never
    # stored, logged or asked for.
    if is_set GITHUB_TOKEN; then
        out="$(GITHUB_TOKEN="$(env_value GITHUB_TOKEN)" "${argv[@]}" 2>&1)" || rc=$?
    else
        out="$("${argv[@]}" 2>&1)" || rc=$?
    fi
    printf '%s\n' "$out" | while IFS= read -r line; do
        [ -n "$line" ] && log_info "  ${line}"
    done
    WP_RESOLVED='' WP_CLI_VERSION=''
    after="$(wpcli_version_local || printf '')"
    if ((rc != 0)); then
        # "already the latest" is reported as a failure by some versions.
        case "$out" in
            *'latest version'* | *'up to date'*)
                log_ok "WP-CLI ${after:-$before} is already the latest release"
                return 0
                ;;
            *'Phar'* | *'phar'*)
                log_warn "'wp cli update' only supports a phar install; falling back to a verified direct download"
                return 2
                ;;
        esac
        log_error "'wp cli update' failed with exit ${rc}"
        log_error_detail 'wpcli-update' "$(argv_display "${argv[@]}")" "$out" "$rc"
        return 1
    fi
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
        log_ok "WP-CLI updated: ${before:-unknown} -> ${after}"
    elif [ -n "$after" ]; then
        log_ok "WP-CLI ${after} is already the latest release"
    else
        log_warn 'the update reported success but the version could not be read back'
    fi
    return 0
}

# mode_wpcli_check : the version report. Read-only, no site list, no lock.
mode_wpcli_check() {
    local installed='' latest='' cmp='' kind='' real='' rc=0 writable='no' phpver=''
    printf '\n%s== wp-cli ==%s\n' "$C_BOLD" "$C_RESET"
    if ! wp_ensure; then
        printf '  %-18s %sNOT FOUND%s\n' 'installed:' "$C_RED" "$C_RESET"
        printf '  %-18s %s\n' 'install with:' "${PROG_NAME} --wpcli-install"
        printf '\n'
        return "$EXIT_ENV"
    fi
    real="$(wp_realpath)"
    kind="$(wp_install_kind)"
    installed="$(wpcli_version_local)" || installed=''
    [ -w "$real" ] && writable='yes'
    if have "${PHP_BIN:-php}"; then
        phpver="$("${PHP_BIN:-php}" -r 'echo PHP_VERSION;' 2>/dev/null | head -n 1)"
    fi

    printf '  %-18s %s\n' 'binary:' "$WP_RESOLVED"
    printf '  %-18s %s\n' 'resolved:' "${real}"
    printf '  %-18s %s\n' 'install kind:' "$kind"
    printf '  %-18s %s\n' 'version:' "${installed:-<unknown>}"
    printf '  %-18s %s\n' 'php:' "${phpver:-<not found>}"
    printf '  %-18s %s\n' 'writable:' "$writable"
    printf '  %-18s %s\n' 'minimum:' "${WP_CLI_MIN_VERSION:-<none>}"

    if [ -z "$installed" ]; then
        printf '  %-18s %s?%s the version could not be read; the floor check was skipped\n' \
            'gate:' "$C_YELLOW" "$C_RESET"
    elif [ -n "$WP_CLI_MIN_VERSION" ]; then
        version_compare "$installed" "$WP_CLI_MIN_VERSION" >/dev/null
        if [ "$VERSION_CMP" = '-1' ]; then
            printf '  %-18s %sFAIL%s %s is below the required %s\n' 'gate:' "$C_RED" "$C_RESET" \
                "$installed" "$WP_CLI_MIN_VERSION"
            rc="$EXIT_ENV"
        else
            printf '  %-18s %sPASS%s %s satisfies %s\n' 'gate:' "$C_GREEN" "$C_RESET" \
                "$installed" "$WP_CLI_MIN_VERSION"
        fi
    else
        printf '  %-18s %sPASS%s no minimum configured\n' 'gate:' "$C_GREEN" "$C_RESET"
    fi

    if [ "$WP_CLI_LATEST_CHECK" = 'true' ] || [ "$WPCLI_ACTION" = 'check' ]; then
        if latest="$(wpcli_latest true)"; then
            printf '  %-18s %s\n' 'newest release:' "$latest"
            version_compare "${installed:-0}" "$latest" >/dev/null
            cmp="$VERSION_CMP"
            if [ -z "$installed" ]; then
                printf '  %-18s %s?%s unknown\n' 'currency:' "$C_YELLOW" "$C_RESET"
            elif [ "$cmp" = '-1' ]; then
                printf '  %-18s %sOUTDATED%s run: %s --wpcli-update\n' 'currency:' "$C_YELLOW" "$C_RESET" "$PROG_NAME"
                [ "$STRICT" = 'true' ] && rc="$EXIT_ERROR"
            else
                printf '  %-18s %sCURRENT%s\n' 'currency:' "$C_GREEN" "$C_RESET"
            fi
            [ -n "$WP_LATEST_UPDATE_TYPE" ] &&
                printf '  %-18s %s\n' 'update type:' "$WP_LATEST_UPDATE_TYPE"
        else
            printf '  %-18s %s\n' 'newest release:' '<could not be determined (offline or rate limited)>'
        fi
    fi

    if [ "$kind" != 'phar' ]; then
        printf '  %-18s %s!%s "wp cli update" only supports a phar; use --wpcli-install to replace it\n' \
            'self-update:' "$C_YELLOW" "$C_RESET"
    elif [ "$writable" != 'yes' ]; then
        printf '  %-18s %s!%s %s is not writable by %s\n' 'self-update:' "$C_YELLOW" "$C_RESET" \
            "$real" "$(id -un)"
    else
        printf '  %-18s %sok%s\n' 'self-update:' "$C_GREEN" "$C_RESET"
    fi
    printf '\n'
    return "$rc"
}

# mode_wpcli_update : bring the wp binary up to date.
mode_wpcli_update() {
    local work rc=0 kind='' before='' after=''
    if [ -n "$WP_CLI_TARGET_VERSION" ] && ! [[ "$WP_CLI_TARGET_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$ ]]; then
        usage_error "--wpcli-target-version must look like 2.11.0 (got '${WP_CLI_TARGET_VERSION}')"
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/${PROG_NAME}.wpcli.XXXXXX")" || {
        log_error 'cannot create a working directory for the WP-CLI update'
        return "$EXIT_ENV"
    }
    chmod 700 "$work" 2>/dev/null
    tmp_register "$work"

    if ! wp_ensure; then
        if [ "$WPCLI_ACTION" = 'install' ]; then
            log_info "WP-CLI is not installed; installing to ${WP_CLI_PATH}"
            mkdir -p -- "$(path_dir "$WP_CLI_PATH")" 2>/dev/null
            WP_RESOLVED="$WP_CLI_PATH"
            if wpcli_install_phar "$WP_CLI_PATH" "$work"; then return 0; fi
            return "$EXIT_ERROR"
        fi
        log_error 'WP-CLI is not installed; nothing to update'
        log_error "run '${PROG_NAME} --wpcli-install' to install it to ${WP_CLI_PATH}"
        return "$EXIT_ENV"
    fi

    before="$(wpcli_version_local)"
    kind="$(wp_install_kind)"
    log_info "WP-CLI ${before:-<unknown version>} at $(wp_realpath) (install kind: ${kind})"

    if [ -n "$WP_CLI_TARGET_VERSION" ]; then
        if [ "$WP_CLI_TARGET_VERSION" = "$before" ]; then
            log_ok "WP-CLI is already at the requested version ${before}; nothing to do"
            return 0
        fi
        log_info "installing the pinned version ${WP_CLI_TARGET_VERSION} by verified direct download"
        if ! wp_upgradable && [ ! -w "$(path_dir "$(wp_realpath)")" ]; then
            log_error "$(wp_realpath) and its directory are not writable by $(id -un); cannot replace the binary"
            return "$EXIT_ENV"
        fi
        if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
        return "$EXIT_ERROR"
    fi

    if [ "$kind" = 'phar' ] && wp_upgradable; then
        wpcli_update_via_wp
        rc=$?
        if ((rc == 2)); then
            # The updater itself said this is not a phar it can handle.
            if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
            return "$EXIT_ERROR"
        fi
        ((rc == 0)) && return 0
        log_warn "falling back to a verified direct download"
        if wpcli_install_phar "$(wp_realpath)" "$work"; then return 0; fi
        return "$EXIT_ERROR"
    fi

    if [ "$kind" != 'phar' ]; then
        log_warn "the installed WP-CLI is a ${kind} install, which 'wp cli update' cannot upgrade"
    else
        log_warn "$(wp_realpath) is not writable by $(id -un); trying a direct download anyway"
    fi
    log_info "installing the newest ${WP_CLI_UPDATE_CHANNEL} build by verified direct download"
    if wpcli_install_phar "$WP_CLI_PATH" "$work"; then return 0; fi
    return "$EXIT_ERROR"
}

# mode_wpcli_rollback : put the previous binary back.
#
# `wp cli update` keeps its own copy as <phar>.old; this tool keeps a
# timestamped one. Both are offered, newest first, because the operator who is
# rolling back is doing it under pressure and should not have to remember which
# mechanism produced the file.
mode_wpcli_rollback() {
    local real target='' f best='' best_ts=0 ts
    local -a candidates=()
    wp_ensure || real="${WP_CLI_PATH}"
    real="$(wp_realpath)"
    while IFS= read -r f; do
        [ -n "$f" ] && candidates+=("$f")
    done < <(
        {
            [ -f "${real}.old" ] && printf '%s\n' "${real}.old"
            find "$(path_dir "$real")" -maxdepth 1 -name "$(path_base "$real").bak-*" -print 2>/dev/null
            [ -n "$WP_CLI_BACKUP_DIR" ] && [ -d "$WP_CLI_BACKUP_DIR" ] &&
                find "$WP_CLI_BACKUP_DIR" -maxdepth 1 -name '*.bak-*' -print 2>/dev/null
        } | sort -r
    )
    if ((${#candidates[@]} == 0)); then
        log_error "no previous WP-CLI binary was found next to ${real}"
        log_error 'looked for <binary>.old and <binary>.bak-<timestamp>'
        return "$EXIT_ERROR"
    fi
    printf '\n%s== rollback candidates ==%s\n' "$C_BOLD" "$C_RESET"
    local i=0
    for f in ${candidates[@]+"${candidates[@]}"}; do
        i=$((i + 1))
        printf '  %2d) %-56s %s\n' "$i" "$f" "$(human_bytes "$(file_size "$f")")"
    done
    printf '\n'
    target="${candidates[0]}"
    if [ -n "$RESTORE_FROM" ]; then
        if is_uint "$RESTORE_FROM" && ((RESTORE_FROM >= 1)) && ((RESTORE_FROM <= ${#candidates[@]})); then
            target="${candidates[$((RESTORE_FROM - 1))]}"
        elif [ -f "$RESTORE_FROM" ]; then
            target="$RESTORE_FROM"
        else
            log_error "--from '${RESTORE_FROM}' is neither a listed number nor an existing file"
            return "$EXIT_USAGE"
        fi
    fi
    log_info "rolling back to ${target}"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: install -m 0755 $(sh_quote "$target") $(sh_quote "$real")"
        return 0
    fi
    if ! wpcli_smoke_test "$target"; then
        log_error "the rollback candidate does not run; refusing to install it"
        return "$EXIT_ERROR"
    fi
    local backup
    if backup="$(wpcli_backup "$real")"; then
        log_debug "the current binary was kept as ${backup}"
    fi
    if ! install -m 0755 -- "$target" "$real" 2>/dev/null; then
        if ! cp -p -- "$target" "$real" 2>/dev/null; then
            log_error "cannot write ${real}"
            return "$EXIT_ERROR"
        fi
        chmod 0755 "$real" 2>/dev/null
    fi
    WP_RESOLVED='' WP_CLI_VERSION=''
    log_ok "WP-CLI rolled back to $(wpcli_version_local || printf '<unknown version>')"
    return 0
}
