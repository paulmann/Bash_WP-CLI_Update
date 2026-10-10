###############################################################################
# Section 19 - site inventory
###############################################################################
#
# The site list is the most dangerous input this tool accepts: everything in it
# will be modified, as root's delegate, on a schedule. The rules below all come
# from that fact.
#
#   - One absolute path per line. Blank lines and `#` comments are ignored, a
#     trailing CR is tolerated, leading and trailing whitespace is trimmed.
#   - An owner may be forced per line by appending a TAB and the user name. TAB,
#     not space: a directory whose name contains a space is unusual but legal,
#     and splitting on whitespace would silently rewrite the path -- which turns
#     "site updated" into "site skipped, not a directory" with nothing in the log
#     to explain why.
#   - An entry that is not a directory is skipped with a warning, never
#     silently: "site updated" and "site vanished" must not look the same.
#   - An existing but EMPTY list is a statement, not an accident. Discovery is
#     not run over it. Scanning the default web roots and then updating whatever
#     turns up is the one surprise a maintenance tool must never produce.

SITES=()
declare -A SITE_FORCED_USER=()

# A single tab character, named once at load time. `printf -v` is a builtin, so
# this costs no process; writing the byte literally in the source is how the
# previous revision lost the owner column, because a raw tab is invisible in a
# diff and some editors and tools silently normalise it away.
TAB=''
printf -v TAB '\t'

# parse_site_line LINE -> fills PARSED_PATH / PARSED_USER, non-zero for lines
# that carry no entry (blank or comment).
PARSED_PATH=''
PARSED_USER=''
parse_site_line() {
    local line="${1-}"
    line="${line%$'\r'}"
    # trim leading and trailing whitespace, but never inside the path
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    PARSED_PATH='' PARSED_USER=''
    [ -n "$line" ] || return 1
    case "$line" in
        '#'*) return 1 ;;
    esac
    if [[ "$line" == *"$TAB"* ]]; then
        PARSED_PATH="${line%%"$TAB"*}"
        PARSED_USER="${line#*"$TAB"}"
        # trim sets TRIMMED as well as printing, so this costs no subshell per
        # field; the site list can hold a few hundred lines.
        trim "$PARSED_PATH"; PARSED_PATH="$TRIMMED"
        # Anything after a second TAB is a comment in the operator's own format.
        PARSED_USER="${PARSED_USER%%"$TAB"*}"
        trim "$PARSED_USER"; PARSED_USER="$TRIMMED"
    else
        PARSED_PATH="$line"
    fi
    [ -n "$PARSED_PATH" ] || return 1
    return 0
}

INCLUDE_GLOBS=()
EXCLUDE_GLOBS=()

# site_filter_verdict PATH -> 0 process, 1 skip (reason at debug level).
# Exclude wins over include: an operator who whitelists a tree and then
# blacklists one site inside it means the blacklist.
site_filter_verdict() {
    local site="${1-}"
    if ((${#EXCLUDE_GLOBS[@]} > 0)) && any_glob_match "$site" "${EXCLUDE_GLOBS[@]}"; then
        log_debug "excluded by --exclude: ${site}"
        return 1
    fi
    if ((${#INCLUDE_GLOBS[@]} > 0)) && ! any_glob_match "$site" "${INCLUDE_GLOBS[@]}"; then
        log_debug "not matched by --include: ${site}"
        return 1
    fi
    return 0
}

# load_site_list FILE : fill SITES[] and SITE_FORCED_USER[].
# Reading the file and resolving owners are separate steps: the list can be read
# and printed (--list-sites) on a host with no wp binary and no root.
# FILE may be '-', which reads the list from stdin.
load_site_list() { # FILE
    local file="${1-}" line
    SITES=()
    SITE_FORCED_USER=()
    if [ "$file" = '-' ]; then
        SITES_FROM_STDIN='true'
        while IFS= read -r line || [ -n "$line" ]; do
            parse_site_line "$line" || continue
            SITES+=("$PARSED_PATH")
            [ -n "$PARSED_USER" ] && SITE_FORCED_USER["$PARSED_PATH"]="$PARSED_USER"
        done
        log_debug "site list read from stdin (${#SITES[@]} entries)"
        SITES_FILE_RESOLVED='<stdin>'
        return 0
    fi
    [ -n "$file" ] || { log_error 'no site list configured'; return 1; }
    if [ ! -f "$file" ]; then
        log_error "site list not found: ${file}"
        return 1
    fi
    if [ ! -r "$file" ]; then
        log_error "site list is not readable: ${file}"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        parse_site_line "$line" || continue
        SITES+=("$PARSED_PATH")
        [ -n "$PARSED_USER" ] && SITE_FORCED_USER["$PARSED_PATH"]="$PARSED_USER"
    done <"$file"
    SITES_FILE_RESOLVED="$file"
    log_debug "site list ${file}: ${#SITES[@]} entries"
    return 0
}

# ensure_site_list : create the list by discovery when it is genuinely missing.
ensure_site_list() {
    [ "$SITES_FILE" = '-' ] && return 0
    if [ -f "$SITES_FILE" ] && [ -s "$SITES_FILE" ]; then return 0; fi
    if [ -f "$SITES_FILE" ]; then
        log_warn "site list ${SITES_FILE} exists but is empty; not running discovery"
        return 1
    fi
    if [ "$AUTO_DISCOVER" != 'true' ]; then
        log_error "site list ${SITES_FILE} is missing and AUTO_DISCOVER is off"
        return 1
    fi
    if [ ! -f "$DISCOVER_SCRIPT" ]; then
        log_error "site list ${SITES_FILE} is missing, and the discovery script ${DISCOVER_SCRIPT} is not there"
        return 1
    fi
    path_base "$DISCOVER_SCRIPT" >/dev/null
    log_info "site list missing; running discovery: ${PATH_BASE}"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would run: bash ${DISCOVER_SCRIPT} --output ${SITES_FILE} ${DISCOVER_ROOTS}"
        return 1
    fi
    local rc=0 root
    local -a argv=(bash "$DISCOVER_SCRIPT" --output "$SITES_FILE" --color "$COLOR")
    [ "$VERBOSE" = 'true' ] || argv+=(--quiet)
    for root in $DISCOVER_ROOTS; do
        [ -d "$root" ] && argv+=("$root")
    done
    # The finder is started with an explicit `bash`, never through its shebang: a
    # host whose `bash` in PATH is older than the one running this script would
    # otherwise make auto-discovery fail with a confusing syntax error.
    "${argv[@]}" || rc=$?
    if ((rc == 5)); then
        log_warn 'discovery found no WordPress installation'
        return 1
    elif ((rc != 0)); then
        log_error "discovery failed with exit ${rc}"
        return 1
    fi
    return 0
}

###############################################################################
# Section 20 - work units (path, user, url) and multisite expansion
###############################################################################
#
# A work unit is one (path, user, url) triple. The fleet is a list of units, not
# a list of paths: a multisite installation expands into one unit per subsite,
# and `--url` becomes a property of the unit instead of a global that every mode
# has to remember to pass on. Every mode function takes (SITE USER URL) for the
# same reason.

units_reset() {
    UNIT_PATH=() UNIT_USER=() UNIT_URL=() UNIT_LABEL=()
    UNIT_COUNT=0
    SITE_USER=()
    return 0
}

# units_add PATH USER URL LABEL
units_add() {
    UNIT_PATH+=("$1")
    UNIT_USER+=("$2")
    UNIT_URL+=("$3")
    UNIT_LABEL+=("${4:-$1}")
    SITE_USER["$1"]="$2"
    UNIT_COUNT=$((UNIT_COUNT + 1))
    return 0
}

# site_subsite_urls SITE USER -> one URL per line for a multisite installation.
# Non-zero when the installation is not a multisite, when WP-CLI is too old for
# `site list`, or when the query failed. Nothing here may ever abort a run: a
# site that cannot answer "how many subsites do you have?" is still a site worth
# updating, as the main site.
site_subsite_urls() { # SITE USER
    local site="$1" user="$2" body tsv id url found=0
    wp_data "$site" "$user" '' site list --fields=blog_id,url --format=json 2>/dev/null
    [ "$WP_SKIPPED" = 'true' ] && return 1
    ((WP_STATUS == 0)) || return 1
    body="$(json_array_slice "$WP_OUTPUT" 2>/dev/null)" || return 1
    tsv="$(printf '%s' "$body" | json_to_tsv blog_id url 2>/dev/null)" || return 1
    while IFS="$TAB" read -r id url; do
        [ "$id" = 'blog_id' ] && continue
        [ -n "$url" ] || continue
        case "$url" in
            http://* | https://*) ;;
            *) continue ;;
        esac
        printf '%s\n' "${url%/}"
        found=1
    done <<<"$tsv"
    ((found)) || return 1
    return 0
}

# units_build : turn SITES[] into the unit list.
#
# Three separate concerns meet here, and keeping them in one function in this
# order is what makes it auditable: the include/exclude filters (free, run
# first), owner resolution (one stat per site, run second), and multisite
# expansion (a WP-CLI call per site, run last and only when asked for).
units_build() {
    local site user url expanded skipped=0
    units_reset
    for site in ${SITES[@]+"${SITES[@]}"}; do
        if ((MAX_SITES > 0)) && ((UNIT_COUNT >= MAX_SITES)); then
            log_warn "--max-sites=${MAX_SITES} reached; the remaining entries are not processed"
            break
        fi
        if ! site_filter_verdict "$site"; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ ! -d "$site" ]; then
            log_warn "skipping, not a directory: ${site}"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        if ! is_wordpress_root "$site"; then
            log_warn "skipping, not a WordPress root (no wp-config.php, wp-load.php or wp-includes/version.php): ${site}"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        user="${SITE_FORCED_USER[$site]-}"
        if [ -n "$user" ]; then
            if ! is_valid_username "$user" || ! id -u "$user" >/dev/null 2>&1; then
                log_error "skipping ${site}: the owner named in the site list is not a valid account: ${user}"
                STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
                continue
            fi
            log_debug "${site}: owner ${user} taken from the site list"
        elif ! user="$(site_user_resolve "$site")"; then
            log_error "skipping ${site}: cannot determine the site owner (fix the ownership, name it in the list after a TAB, or pass --user NAME)"
            STATS_SITES_SKIPPED=$((STATS_SITES_SKIPPED + 1))
            continue
        fi
        if [ "$MULTISITE" = 'all' ]; then
            expanded=0
            while IFS= read -r url; do
                [ -n "$url" ] || continue
                path_base "$site" >/dev/null
                units_add "$site" "$user" "$url" "${PATH_BASE} ${url}"
                expanded=1
            done < <(site_subsite_urls "$site" "$user")
            if ((expanded)); then
                log_debug "${site}: expanded into subsites (MULTISITE=all)"
                continue
            fi
            log_debug "${site}: MULTISITE=all but no subsite list came back; treating it as a single site"
        fi
        path_base "$site" >/dev/null
        units_add "$site" "$user" "$URL" "$PATH_BASE"
    done
    if ((skipped > 0)); then
        log_debug "${skipped} entr(y/ies) filtered out by --include / --exclude"
    fi
    return 0
}

# is_wordpress_root DIR -> 0 when DIR looks like a WordPress installation.
# Accepting wp-config.php, wp-load.php or wp-includes/version.php is deliberate:
# a Bedrock-style layout has no wp-load.php in the root, and a half-extracted
# archive may have no wp-config.php yet. The check exists to stop the tool from
# running `wp --path=/var/www` against a directory that merely contains one site
# somewhere below it.
is_wordpress_root() {
    local dir="${1-}"
    [ -d "$dir" ] || return 1
    [ -f "${dir}/wp-load.php" ] && return 0
    [ -f "${dir}/wp-config.php" ] && return 0
    [ -f "${dir}/wp-includes/version.php" ] && return 0
    return 1
}

# wp_config_path SITE -> the wp-config.php that belongs to this site.
# WordPress allows it one level up, and Bedrock puts it somewhere else again;
# both are handled, because a security audit that reports "no wp-config" for a
# correctly configured site teaches the operator to ignore the audit.
wp_config_path() {
    local site="${1-}" up
    if [ -f "${site}/wp-config.php" ]; then
        printf '%s' "${site}/wp-config.php"
        return 0
    fi
    up="${site%/}"
    up="${up%/*}"
    if [ -n "$up" ] && [ -f "${up}/wp-config.php" ]; then
        printf '%s' "${up}/wp-config.php"
        return 0
    fi
    return 1
}

# wp_config_constant FILE NAME -> the literal value of a define(), or empty.
# Read with a bash regex; the result is only ever compared or logged, never
# executed, never passed to a shell.
wp_config_constant() { # FILE NAME
    local cfg="${1-}" name="${2-}" line value
    [ -r "$cfg" ] || return 1
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *"$name"*) ;;
            *) continue ;;
        esac
        if [[ "$line" =~ define\([[:space:]]*[\'\"]${name}[\'\"][[:space:]]*,[[:space:]]*[\'\"]([^\'\"]*)[\'\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
        if [[ "$line" =~ define\([[:space:]]*[\'\"]${name}[\'\"][[:space:]]*,[[:space:]]*(true|false|TRUE|FALSE|null|NULL|[0-9]+)[[:space:]]*\) ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$cfg"
    return 1
}

# site_home SITE USER -> the site's home URL, cached per site.
# The smoke test and the report both need it, and asking twice per site doubles
# the number of WordPress boots for no reason.
SITE_HOME_CACHE=''
SITE_HOME_CACHE_FOR=''
site_home() { # SITE USER
    local site="$1" user="$2"
    if [ "$SITE_HOME_CACHE_FOR" = "$site" ]; then
        printf '%s' "$SITE_HOME_CACHE"
        return 0
    fi
    SITE_HOME_CACHE=''
    SITE_HOME_CACHE_FOR="$site"
    if wp_probe "$site" "$user" '' option get home; then
        case "$WP_PROBE" in
            http://* | https://*) SITE_HOME_CACHE="$WP_PROBE" ;;
        esac
    fi
    printf '%s' "$SITE_HOME_CACHE"
    return 0
}

# print_site_list : what would be processed, without processing it.
#
# Resolving the list is the half of a fleet run that can go wrong quietly: an
# owner that cannot be determined, a directory that vanished, a filter that
# matched nothing. This prints the resolved result -- including the units a
# multisite expands into -- and exits, so it can be diffed before a change and
# after it.
print_site_list() {
    local i sink tsv=''
    if [ -z "$TARGET_SITE" ]; then
        if ! ensure_site_list; then
            if [ "$SITES_FILE" != '-' ] && [ ! -f "$SITES_FILE" ]; then
                log_error "no site list to work from: ${SITES_FILE}"
                return 1
            fi
        fi
        load_site_list "$SITES_FILE" || return 1
    else
        SITES=("$TARGET_SITE")
        SITE_FORCED_USER=()
        [ -n "$SITE_USER" ] && SITE_FORCED_USER["$TARGET_SITE"]="$SITE_USER"
    fi
    units_build
    printf '%s (%s unit(s), source: %s)\n' \
        "${C_BOLD}resolved work list${C_RESET}" "$UNIT_COUNT" \
        "$([ -n "$TARGET_SITE" ] && printf -- '--site' || printf '%s' "$SITES_FILE")" >&2

    data_sink
    sink="$DATA_SINK"
    case "$OUTPUT_FORMAT" in
        json)
            local jp jo ju jk
            for ((i = 0; i < UNIT_COUNT; i++)); do
                json_escape "${UNIT_PATH[i]}"; jp="$JSON_ESCAPED"
                json_escape "${UNIT_USER[i]}"; jo="$JSON_ESCAPED"
                json_escape "${UNIT_URL[i]}"; ju="$JSON_ESCAPED"
                if [ -n "${UNIT_URL[i]}" ]; then jk='subsite'; else jk='site'; fi
                printf '{"path":"%s","owner":"%s","url":"%s","kind":"%s"}\n' \
                    "$jp" "$jo" "$ju" "$jk" | sink_write "$sink"
            done
            ;;
        *)
            tsv="PATH${TAB}OWNER${TAB}URL${TAB}KIND"
            for ((i = 0; i < UNIT_COUNT; i++)); do
                if [ -n "${UNIT_URL[i]}" ]; then
                    tsv+=$'\n'"${UNIT_PATH[i]}${TAB}${UNIT_USER[i]}${TAB}${UNIT_URL[i]}${TAB}subsite"
                else
                    tsv+=$'\n'"${UNIT_PATH[i]}${TAB}${UNIT_USER[i]}${TAB}<main>${TAB}site"
                fi
            done
            render_tsv "$tsv" "$PAGE_LIMIT" "$sink"
            ;;
    esac
    if ((STATS_SITES_SKIPPED > 0)); then
        printf 'skipped: %s (see the warnings above)\n' "$STATS_SITES_SKIPPED" >&2
    fi
    return 0
}
