###############################################################################
# 5. Classification helpers
###############################################################################

# A WordPress root must carry wp-config.php and one of the two markers that
# distinguish a real installation from a stray config file.
is_valid_wp() { # DIR
    local dir="${1:-}"
    [ -f "${dir}/wp-config.php" ] || return 1
    [ -f "${dir}/wp-load.php" ] && return 0
    [ -f "${dir}/wp-includes/version.php" ] && return 0
    return 1
}

# name_is_included NAME -> 0 when no --include-name was given, or when one matches.
# Inclusion is opt-in and empty means "everything", so that adding an include
# pattern narrows the scan and removing it restores the previous behaviour.
name_is_included() { # NAME
    local name="${1:-}" pat
    ((${#INCLUDE_NAMES[@]} == 0)) && return 0
    for pat in ${INCLUDE_NAMES[@]+"${INCLUDE_NAMES[@]}"}; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254  # the pattern is the point: globs are wanted
        case "$name" in $pat) return 0 ;; esac
    done
    return 1
}

# is_multisite DIR -> 0 when wp-config.php enables the multisite.
# Read from the config rather than by asking WordPress: discovery must work on a
# host where the database server is down, which is exactly when an inventory is
# most useful.
is_multisite() { # DIR
    local f="${1:-}/wp-config.php" line
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *WP_ALLOW_MULTISITE* | *MULTISITE* | *subdomain_install*)
                case "$line" in
                    *true* | *,1\)* | *'1'*) return 0 ;;
                esac
                ;;
        esac
    done <"$f"
    return 1
}

name_is_excluded() { # NAME
    local name="${1:-}" pat
    for pat in ${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"}; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254  # the pattern is the point: globs are wanted
        case "$name" in $pat) return 0 ;; esac
    done
    return 1
}

path_is_excluded() { # PATH
    local path="${1:-}" ex
    for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
        [ -n "$ex" ] || continue
        [ "$path" = "$ex" ] && return 0
        case "$path" in "$ex"/*) return 0 ;; esac
    done
    return 1
}

wp_version_of() { # DIR
    local f="${1:-}/wp-includes/version.php" line
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ \$wp_version[[:space:]]*=[[:space:]]*[\'\"]([^\'\"]+)[\'\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$f"
    return 1
}

db_name_of() { # DIR
    local f="${1:-}/wp-config.php" line
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ define\([[:space:]]*[\']DB_NAME[\'][[:space:]]*,[[:space:]]*[\']([^\']*)[\'] ]] ||
           [[ "$line" =~ define\([[:space:]]*[\"]DB_NAME[\"][[:space:]]*,[[:space:]]*[\"]([^\"]*)[\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$f"
    return 1
}

###############################################################################
# 6. Scanning
###############################################################################

# build_find_args ROOT -> argv on stdout, one element per line.
#
# The expression is:
#   \( -type d \( <name globs> \) -false \) -prune -o
#   \( <path prefixes> -false \) -prune -o
#   \( -type f -name wp-config.php \) -print0
#
# Two details matter. `-false` terminates each prune group so the group is false
# for anything that did not match -- a bare `-prune` inside the group evaluates
# to true even for a plain file and silently swallows the rest of the
# expression. And `-type d` in front keeps find from calling the prune action on
# every file it meets.
build_find_args() { # ROOT
    local root="$1" pat first
    # Order is not cosmetic here: `-L` is a global option and GNU find rejects it
    # after the starting point, while -mindepth/-maxdepth are ordinary tests and
    # belong with the expression.
    if [ "$FOLLOW_SYMLINKS" = 'true' ]; then
        printf '%s\n' -L
    fi
    printf '%s\n' "$root"
    printf '%s\n' -mindepth "$MIN_DEPTH"
    printf '%s\n' -maxdepth "$MAX_DEPTH"
    # The shape below is the only one of the four plausible variants that works,
    # and the reason is worth writing down because every alternative fails
    # silently by simply not pruning:
    #
    #   \( -type d \( <names> \) \) -prune -o \( -type f -name wp-config.php \) -print0
    #
    # `-type d` has to be INSIDE the parenthesised group. GNU find evaluates
    # `-prune` to true for anything, including a plain file, so a group that ends
    # up true makes the whole left side of `-o` true and the right side -- the
    # actual search -- never runs. With `-type d` inside, a file makes the group
    # false, `-prune` is never reached, and the right side is evaluated. Putting
    # `-false` at the end of the group instead looks equivalent and is not: on
    # findutils 4.9.0 it still fails to prune. This was measured, not reasoned.
    if ((${#EXCLUDE_NAMES[@]} > 0)); then
        printf '%s\n' '(' -type d '('
        first=1
        for pat in "${EXCLUDE_NAMES[@]}"; do
            [ -n "$pat" ] || continue
            ((first)) || printf '%s\n' -o
            first=0
            printf '%s\n' -name "$pat"
        done
        printf '%s\n' ')' ')' -prune -o
    fi
    if ((${#EXCLUDE_PATHS[@]} > 0)); then
        printf '%s\n' '(' -type d '('
        first=1
        for pat in "${EXCLUDE_PATHS[@]}"; do
            [ -n "$pat" ] || continue
            ((first)) || printf '%s\n' -o
            first=0
            printf '%s\n' -path "$pat" -o -path "${pat%/}/*"
        done
        printf '%s\n' ')' ')' -prune -o
    fi
    printf '%s\n' '(' -type f -name wp-config.php ')' -print0
}

scan_root() { # ROOT
    local root="$1" config site base
    local -a fargs=()
    if [ ! -d "$root" ]; then
        log_debug "root is not a directory, skipped: ${root}"
        SKIPPED_UNREADABLE=$((SKIPPED_UNREADABLE + 1))
        return 0
    fi
    if [ ! -r "$root" ] || [ ! -x "$root" ]; then
        log_warn "root is not readable, skipped: ${root}"
        SKIPPED_UNREADABLE=$((SKIPPED_UNREADABLE + 1))
        return 0
    fi
    mapfile -t fargs < <(build_find_args "$root")
    log_debug "scanning ${root} (max depth ${MAX_DEPTH})"
    # -print0 / read -d '' is the only combination that survives every filename.
    while IFS= read -r -d '' config; do
        site="$(dirname -- "$config")"
        base="${site##*/}"
        if [ -e "${site}/${OPT_OUT_MARKER}" ]; then
            SKIPPED_OPTOUT=$((SKIPPED_OPTOUT + 1))
            log_debug "opt-out marker, skipped: ${site}"
            continue
        fi
        if name_is_excluded "$base" || path_is_excluded "$site"; then
            SKIPPED_EXCLUDED=$((SKIPPED_EXCLUDED + 1))
            log_debug "excluded, skipped: ${site}"
            continue
        fi
        if ! name_is_included "$base"; then
            SKIPPED_EXCLUDED=$((SKIPPED_EXCLUDED + 1))
            log_debug "not matched by --include-name, skipped: ${site}"
            continue
        fi
        if ! is_valid_wp "$site"; then
            SKIPPED_INVALID=$((SKIPPED_INVALID + 1))
            log_debug "not a WordPress root, skipped: ${site}"
            continue
        fi
        printf '%s\0' "$site"
    done < <(find "${fargs[@]}" 2>/dev/null)
    return 0
}

collect_results() {
    local root
    make_tmp results; RESULTS_FILE="$TMP_LAST"
    make_tmp sorted; SORTED_FILE="$TMP_LAST"
    : >"$RESULTS_FILE"
    for root in ${SEARCH_ROOTS[@]+"${SEARCH_ROOTS[@]}"}; do
        log_info "scanning: ${root}"
        scan_root "$root" >>"$RESULTS_FILE"
    done
    # Deduplicate and sort in one pass; NUL separated, so any filename survives.
    sort -z -u <"$RESULTS_FILE" >"$SORTED_FILE"
    FOUND_COUNT="$(tr -cd '\0' <"$SORTED_FILE" | wc -c)"
    FOUND_COUNT="${FOUND_COUNT//[^0-9]/}"
    FOUND_COUNT="${FOUND_COUNT:-0}"
    return 0
}
