###############################################################################
# Section 3 - small pure helpers
###############################################################################
#
# Everything in this section is side-effect free or nearly so: no logging, no
# counters, and no global state except the documented result variables. That is
# what makes these helpers testable in isolation and safe to call from a worker
# subshell.
#
# Fork discipline
# ---------------
# A helper on the per-site path publishes its result in a documented global as
# well as on stdout, so a hot caller can invoke it bare and read the global
# instead of paying for a subshell. A subshell is not free: on a 200-site run the
# per-site helpers are called thousands of times, and this tool has to keep
# working on a host that is near its process limit -- which is often exactly why
# the maintenance run was scheduled. Helpers that are called once per run just
# print.
#
# Portability floor is bash 4.2 (CentOS 7 / RHEL 7). That rules out, and this
# file therefore never uses: `declare -n` namerefs (4.3), `wait -n` (4.3),
# `mapfile -d` (4.4), `${var@Q}` (4.4), `$EPOCHSECONDS` (5.0).
# `shopt -s inherit_errexit` (4.4) is attempted once in the bootstrap and ignored
# when unavailable.

# have CMD -> is CMD runnable?
have() { command -v -- "$1" >/dev/null 2>&1; }

# is_set NAME -> true when NAME is set in this shell or in the environment.
# `printenv` is what makes the second half work: a variable exported by the
# *calling* process is not always visible to `${!NAME+x}` after an `env -i` style
# wrapper, and without it the documented WP_CLI_UPDATE_* layer silently did
# nothing under some cron and systemd setups.
is_set() {
    local n="${1:-}"
    [ -n "$n" ] || return 1
    [ -n "${!n+set}" ] && return 0
    printenv -- "$n" >/dev/null 2>&1
}

# env_value NAME -> value from the shell or the environment, empty when unset
env_value() {
    local n="${1:-}"
    if [ -n "${!n+set}" ]; then
        printf '%s' "${!n}"
        return 0
    fi
    printenv -- "$n" 2>/dev/null
    return 0
}

# trim STRING -> sets TRIMMED and prints it
TRIMMED=''
trim() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    TRIMMED="$s"
    printf '%s' "$s"
}

is_uint() { [[ "${1-}" =~ ^[0-9]+$ ]]; }
is_int() { [[ "${1-}" =~ ^-?[0-9]+$ ]]; }

# is_valid_username NAME -> conservative account-name check. Applied before a name
# is handed to runuser/sudo/su, so a wp-config.php containing
# define('DB_USER', 'x; rm -rf /') cannot reach a command line at all.
is_valid_username() { [[ "${1-}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; }

# file_mode PATH -> octal permission bits (for example 644), empty when unknown
file_mode() { stat -c '%a' -- "$1" 2>/dev/null; }

# file_owner PATH -> owner name, empty when unknown
file_owner() { stat -c '%U' -- "$1" 2>/dev/null; }

# file_group PATH -> group name, empty when unknown
file_group() { stat -c '%G' -- "$1" 2>/dev/null; }

# file_size PATH -> sets FILE_SIZE (bytes, 0 when unknown) and prints it.
# rotate_log reads the global, because it runs on every log line and cannot
# afford a subshell; the printed form serves the places that read a size once.
FILE_SIZE=0
file_size() {
    local n
    n="$(stat -c '%s' -- "$1" 2>/dev/null)"
    is_uint "$n" || n=0
    FILE_SIZE="$n"
    printf '%s' "$n"
}

# dir_kib PATH -> size in KiB, empty when unknown or unreadable
dir_kib() {
    local n
    n="$(du -sk -- "$1" 2>/dev/null)"
    n="${n%%[^0-9]*}"
    n="${n//[^0-9]/}"
    printf '%s' "$n"
}

# free_mib PATH -> free space in MiB on the filesystem holding PATH.
# `df -P` is POSIX and always prints exactly one line per filesystem, which the
# default GNU output does not guarantee for long device names.
free_mib() {
    local target="${1:-.}" kib
    kib="$(df -Pk -- "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
    kib="${kib//[^0-9]/}"
    if [ -z "$kib" ]; then printf '0'; return 1; fi
    printf '%s' "$((kib / 1024))"
}

# human_bytes N -> sets HUMAN_BYTES and prints it: "1.5 MiB" style
HUMAN_BYTES=''
human_bytes() {
    local n="${1:-0}"
    is_uint "$n" || n=0
    if ((n >= 1073741824)); then
        printf -v HUMAN_BYTES '%s.%s GiB' "$((n / 1073741824))" "$(((n % 1073741824) * 10 / 1073741824))"
    elif ((n >= 1048576)); then
        printf -v HUMAN_BYTES '%s.%s MiB' "$((n / 1048576))" "$(((n % 1048576) * 10 / 1048576))"
    elif ((n >= 1024)); then
        printf -v HUMAN_BYTES '%s KiB' "$((n / 1024))"
    else
        printf -v HUMAN_BYTES '%s B' "$n"
    fi
    printf '%s' "$HUMAN_BYTES"
}

# duration_human SECONDS -> sets DURATION_HUMAN and prints it
DURATION_HUMAN=''
duration_human() {
    local s="${1:-0}"
    is_uint "$s" || s=0
    if ((s >= 3600)); then
        printf -v DURATION_HUMAN '%dh %02dm %02ds' "$((s / 3600))" "$(((s % 3600) / 60))" "$((s % 60))"
    elif ((s >= 60)); then
        printf -v DURATION_HUMAN '%dm %02ds' "$((s / 60))" "$((s % 60))"
    else
        printf -v DURATION_HUMAN '%ss' "$s"
    fi
    printf '%s' "$DURATION_HUMAN"
}

# now_epoch -> seconds since the epoch, and sets EPOCH_NOW.
# bash's own printf formats time, so this needs no date(1) and no exec. It is a
# function at all -- rather than inlining $EPOCHSECONDS -- so a test can stub it
# and so bash 4.2, which has no EPOCHSECONDS, is still supported.
EPOCH_NOW=0
now_epoch() {
    printf -v EPOCH_NOW '%(%s)T' -1
    printf '%s' "$EPOCH_NOW"
}

# version_compare A B -> sets VERSION_CMP to -1, 0 or 1, and prints it.
#
# The global matters: version_at_least is called once per site by the security
# audit, and capturing the result through a subshell would put a fork in the
# middle of a fleet walk.
#
VERSION_CMP=0
#
# Numeric, dot separated, segment by segment: 2.10.0 > 2.9.0, which a string
# comparison gets wrong and which is exactly the mistake a version gate must not
# make. A non-numeric suffix (-nightly, -rc1) is compared after the numeric part
# with one rule only -- a release outranks a pre-release of the same number --
# because that is the rule both WP-CLI and WordPress follow. Anything exotic
# yields 0 (equal) instead of a guess: a gate that cries wolf gets disabled, and
# a disabled gate protects nobody.
version_compare() {
    local a="${1-}" b="${2-}"
    local na='' nb='' ta='' tb='' x y i n ai bi
    local -a pa=() pb=()

    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
    [ -n "$a" ] && [ -n "$b" ] || { VERSION_CMP=0; printf '0'; return 0; }
    na="${a%%[!0-9.]*}"
    nb="${b%%[!0-9.]*}"
    ta="${a#"$na"}"; ta="${ta#-}"
    tb="${b#"$nb"}"; tb="${tb#-}"

    IFS='.' read -r -a pa <<<"$na"
    IFS='.' read -r -a pb <<<"$nb"
    n=${#pa[@]}
    ((${#pb[@]} > n)) && n=${#pb[@]}
    for ((i = 0; i < n; i++)); do
        x="${pa[i]-0}"; y="${pb[i]-0}"
        x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
        ai=$((10#${x:-0})); bi=$((10#${y:-0}))
        if ((ai > bi)); then VERSION_CMP=1; printf '1'; return 0; fi
        if ((ai < bi)); then VERSION_CMP=-1; printf -- '-1'; return 0; fi
    done
    if [ -z "$ta" ] && [ -n "$tb" ]; then VERSION_CMP=1; printf '1'; return 0; fi
    if [ -n "$ta" ] && [ -z "$tb" ]; then VERSION_CMP=-1; printf -- '-1'; return 0; fi
    if [ "$ta" = "$tb" ]; then VERSION_CMP=0; printf '0'; return 0; fi
    if [[ "$ta" > "$tb" ]]; then VERSION_CMP=1; printf '1'; return 0; fi
    VERSION_CMP=-1
    printf -- '-1'
}

# version_at_least HAVE WANT -> 0 when HAVE >= WANT. Reads the global that
# version_compare publishes, so the comparison itself costs no subshell.
version_at_least() {
    version_compare "$1" "$2" >/dev/null
    [ "$VERSION_CMP" != -1 ]
}

# version_major_minor VERSION -> "6.5": the WordPress release line, which is the
# unit that matters for security support.
version_major_minor() {
    local v="${1-}"
    v="${v%%[!0-9.]*}"
    case "$v" in
        *.*.*) printf '%s' "${v%.*}" ;;
        *) printf '%s' "$v" ;;
    esac
}

# json_escape STRING -> sets JSON_ESCAPED.
#
# This one deliberately does NOT print. It runs once per field of every JSON
# record, so a 200-site run with fifteen fields per site would otherwise fork
# three thousand subshells to produce text that is immediately concatenated into
# a string. Every caller reads the global.
#
# The character loop only runs when a control byte is actually present, so the
# common case -- a path, a slug, a version -- is five expansions and no loop.
JSON_ESCAPED=''
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # shellcheck disable=SC2295  # the class is a literal control range
    case "$s" in
        *[$'\001'-$'\037']*)
            local out='' i ch
            for ((i = 0; i < ${#s}; i++)); do
                ch="${s:i:1}"
                # shellcheck disable=SC2295
                case "$ch" in
                    [$'\001'-$'\037']) continue ;;
                esac
                out+="$ch"
            done
            s="$out"
            ;;
    esac
    JSON_ESCAPED="$s"
    return 0
}

# json_quote STRING -> sets JSON_QUOTED to a complete, quoted JSON string, and
# prints it. Printing keeps the `printf '%s' "$(json_quote "$x")"` call sites
# readable; the global lets a tight loop skip the subshell.
JSON_QUOTED=''
json_quote() {
    json_escape "${1-}"
    JSON_QUOTED="\"${JSON_ESCAPED}\""
    printf '%s' "$JSON_QUOTED"
}

# csv_escape VALUE -> VALUE quoted for CSV when it needs it
csv_escape() {
    local f="${1-}"
    case "$f" in
        *[,\"]* | *$'\n'* | *$'\r'*) printf '"%s"' "${f//\"/\"\"}" ;;
        *) printf '%s' "$f" ;;
    esac
}

# sh_quote STRING -> POSIX-shell-safe single-quoted form.
#
# `printf %q` is *not* used here on purpose: it emits bash syntax, and the
# strings built with this function are parsed by /bin/sh, which on Debian is
# dash. There, %q's `\&\&` is a literal, so a %q-built command silently degrades
# into `cd: too many arguments`. This quoting works in every POSIX shell, which
# is the whole reason the user switch needs no escaping.
sh_quote() {
    local s="${1-}"
    if [ -z "$s" ]; then printf "''"; return 0; fi
    case "$s" in
        *[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "${s//\'/\'\\\'\'}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# argv_display ARGS... -> sets ARGV_DISPLAY and prints it: the argv as a human
# would type it. For dry-run output, debug lines and the error log only; never
# used to execute anything.
ARGV_DISPLAY=''
argv_display() {
    ARGV_DISPLAY=''
    local a
    for a in "$@"; do
        ARGV_DISPLAY+="$(sh_quote "$a") "
    done
    ARGV_DISPLAY="${ARGV_DISPLAY% }"
    printf '%s' "$ARGV_DISPLAY"
}

# glob_match PATTERN STRING -> bash pattern match on a path. Never `eval`, never
# a user-supplied regex: a pattern here is data, and the worst an operator can do
# with one is match nothing.
glob_match() {
    local pattern="${1-}" s="${2-}"
    [ -n "$pattern" ] || return 1
    # shellcheck disable=SC2254  # the expansion is a pattern on purpose
    case "$s" in
        $pattern) return 0 ;;
    esac
    return 1
}

# any_glob_match STRING PATTERN... -> 0 when one of the patterns matches.
# Patterns are passed as arguments rather than by array name: namerefs need
# bash 4.3 and the floor here is 4.2.
any_glob_match() {
    local s="${1-}" p
    shift
    for p in "$@"; do
        glob_match "$p" "$s" && return 0
    done
    return 1
}

# split_csv VALUE -> one trimmed, non-empty token per line
split_csv() {
    local v="${1-}" t saved="$IFS"
    IFS=','
    for t in $v; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [ -n "$t" ] && printf '%s\n' "$t"
        IFS=','
    done
    IFS="$saved"
    return 0
}

# split_words VALUE -> one token per line
split_words() {
    local v="${1-}" t
    for t in $v; do
        [ -n "$t" ] && printf '%s\n' "$t"
    done
    return 0
}

# in_csv_list NEEDLE CSV -> 0 when NEEDLE is one of the comma separated tokens.
#
# Written as a plain loop over an IFS split rather than a `while read` fed by a
# process substitution, for two reasons. It is on the hot path -- every `choice:`
# setting is validated through it, three times per run -- and each `< <(...)`
# costs a fork. More importantly, a fork can *fail*: under process-table pressure
# the substitution produces no input at all, the loop finds nothing, and a
# perfectly valid value is rejected. A validation helper that depends on being
# able to fork is a helper that fails exactly when the host is already in trouble.
in_csv_list() {
    local needle="${1-}" csv="${2-}" t saved="$IFS" rc=1
    IFS=','
    for t in $csv; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        if [ "$t" = "$needle" ]; then rc=0; IFS=','; break; fi
        IFS=','
    done
    IFS="$saved"
    return "$rc"
}

# fill_csv CSV / fill_words WORDS -> SPLIT_RESULT[]
#
# Same reasoning: the array is filled in place instead of being streamed through
# a pipe, so no fork is involved and the caller iterates with a plain for.
SPLIT_RESULT=()
fill_csv() {
    local v="${1-}" t saved="$IFS"
    SPLIT_RESULT=()
    IFS=','
    for t in $v; do
        IFS="$saved"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [ -n "$t" ] && SPLIT_RESULT+=("$t")
        IFS=','
    done
    IFS="$saved"
    return 0
}
fill_words() {
    local v="${1-}" t
    SPLIT_RESULT=()
    for t in $v; do
        [ -n "$t" ] && SPLIT_RESULT+=("$t")
    done
    return 0
}

# path_base / path_dir -> set PATH_BASE / PATH_DIR and print them.
#
# basename(1) and dirname(1) are separate executables, and these two are called
# from inside log messages -- roughly once per site per operation. Turning an
# exec of /usr/bin/basename into ${p##*/} is the cheapest performance win in this
# file, and it removes a failure mode too: a host with a read-only or partially
# mounted /usr still has working bash expansions.
#
# The one behavioural difference from the external tools is a trailing slash:
# /var/www/ yields "www" here, which is what every caller in this project wants.
PATH_BASE=''
PATH_DIR=''
path_base() {
    local p="${1-}"
    p="${p%/}"
    PATH_BASE="${p##*/}"
    printf '%s' "$PATH_BASE"
}
path_dir() {
    local p="${1-}"
    p="${p%/}"
    case "$p" in
        */*) PATH_DIR="${p%/*}" ;;
        *) PATH_DIR='.' ;;
    esac
    printf '%s' "$PATH_DIR"
}

# safe_name STRING -> STRING with everything outside [A-Za-z0-9._-] replaced by
# an underscore, so a site directory called `my site (prod)` still yields a
# usable backup directory name.
safe_name() {
    local n="${1-}"
    n="${n//[^A-Za-z0-9._-]/_}"
    [ -n "$n" ] || n='_'
    printf '%s' "$n"
}

# numeric_lines < IDs -> keep only lines that are a plain non-negative integer.
# Every id list that reaches `wp post delete` or `wp comment delete` passes
# through here, so a malformed WP-CLI response can never become a flag or a file
# name.
numeric_lines() {
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        is_uint "$line" && printf '%s\n' "$line"
    done
    return 0
}

# chunk_lines SIZE < LINES -> one line per batch, tokens space separated.
# Deleting 40k revisions in a single command line hits ARG_MAX; batches of 200 do
# not, and one failing batch does not lose the other 199.
chunk_lines() {
    local size="${1:-200}" line out='' n=0
    is_uint "$size" || size=200
    ((size > 0)) || size=200
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        out+="${out:+ }${line}"
        n=$((n + 1))
        if ((n >= size)); then
            printf '%s\n' "$out"
            out='' n=0
        fi
    done
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# count_id_words < BATCHES -> how many ids in total, across space separated lines
count_id_words() {
    local line w n=0
    while IFS= read -r line; do
        for w in $line; do
            is_uint "$w" && n=$((n + 1))
        done
    done
    printf '%s' "$n"
}

# count_lines < TEXT -> number of lines
count_lines() {
    local n=0
    while IFS= read -r _; do n=$((n + 1)); done
    printf '%s' "$n"
}

# ensure_parent_dir FILE -> mkdir -p of the directory part, tolerating '.'
ensure_parent_dir() {
    local f="${1-}" d
    [ -n "$f" ] || return 1
    path_dir "$f" >/dev/null
    d="$PATH_DIR"
    if [ -z "$d" ] || [ "$d" = '.' ]; then return 0; fi
    [ -d "$d" ] && return 0
    mkdir -p -- "$d" 2>/dev/null
}

# atomic_write FILE < CONTENT : write to a sibling temporary file and rename.
# A monitoring system that reads a state file while it is half written gets a
# truncated document; rename(2) is atomic on every filesystem targeted here.
atomic_write() {
    local file="${1-}" tmp
    [ -n "$file" ] || return 1
    ensure_parent_dir "$file" || return 1
    tmp="${file}.tmp.$$"
    if ! cat >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null
    if ! mv -f -- "$tmp" "$file" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# --- HTTP -------------------------------------------------------------------
# curl first, then wget. curl is preferred because it reports the status code,
# which the release check needs in order to tell "the host is offline" from "the
# API answered with something unexpected".

HTTP_CLIENT_RESOLVED=''
WARNED_NO_HTTP='false'

# http_client_resolve -> curl | wget; empty and non-zero when neither exists
http_client_resolve() {
    if [ -n "$HTTP_CLIENT_RESOLVED" ]; then
        [ "$HTTP_CLIENT_RESOLVED" != 'none' ] || return 1
        printf '%s' "$HTTP_CLIENT_RESOLVED"
        return 0
    fi
    case "${HTTP_CLIENT:-auto}" in
        curl) if have curl; then HTTP_CLIENT_RESOLVED='curl'; else HTTP_CLIENT_RESOLVED='none'; fi ;;
        wget) if have wget; then HTTP_CLIENT_RESOLVED='wget'; else HTTP_CLIENT_RESOLVED='none'; fi ;;
        auto | *)
            if have curl; then HTTP_CLIENT_RESOLVED='curl'
            elif have wget; then HTTP_CLIENT_RESOLVED='wget'
            else HTTP_CLIENT_RESOLVED='none'; fi
            ;;
    esac
    if [ "$HTTP_CLIENT_RESOLVED" = 'none' ]; then
        if [ "$WARNED_NO_HTTP" = 'false' ] && [ "${LOG_INIT:-false}" = 'true' ]; then
            log_warn 'neither curl(1) nor wget(1) was found; release checks, smoke tests and webhooks are unavailable'
            WARNED_NO_HTTP='true'
        fi
        return 1
    fi
    printf '%s' "$HTTP_CLIENT_RESOLVED"
    return 0
}

# http_get URL [MAX_SECONDS] -> body on stdout
http_get() {
    local url="${1-}" t="${2:-15}" client
    client="$(http_client_resolve)" || return 1
    case "$client" in
        curl) curl -fsSL --max-time "$t" --retry 1 -- "$url" 2>/dev/null ;;
        wget) wget -q -T "$t" -t 1 -O - -- "$url" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# http_post_json URL JSON [MAX_SECONDS] -> 0 on a 2xx response
http_post_json() {
    local url="${1-}" body="${2-}" t="${3:-15}" client
    client="$(http_client_resolve)" || return 1
    case "$client" in
        curl)
            curl -fsS --max-time "$t" -H 'Content-Type: application/json' \
                -X POST --data-binary "$body" -- "$url" >/dev/null 2>&1
            ;;
        wget)
            wget -q -T "$t" -t 1 --header='Content-Type: application/json' \
                --post-data="$body" -O /dev/null -- "$url" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# http_status URL [MAX_SECONDS] -> numeric status code, 000 when unreachable
http_status() {
    local url="${1-}" t="${2:-15}" client code=''
    client="$(http_client_resolve)" || { printf '000'; return 1; }
    case "$client" in
        curl)
            local -a copts=(-sS -o /dev/null -m "$t" -w '%{http_code}' -L)
            [ "${SMOKE_SSL_VERIFY:-true}" = 'true' ] || copts+=(-k)
            code="$(curl "${copts[@]}" -- "$url" 2>/dev/null)"
            ;;
        wget)
            # wget cannot print the status; --spider succeeds on 2xx and 3xx.
            # That is enough for a smoke test whose contract is "the site still
            # answers", and the limitation is documented rather than hidden.
            local -a wopts=(-q -T "$t" -t 1 --spider)
            [ "${SMOKE_SSL_VERIFY:-true}" = 'true' ] || wopts+=(--no-check-certificate)
            if wget "${wopts[@]}" -- "$url" >/dev/null 2>&1; then code='200'; else code='000'; fi
            ;;
        *) printf '000'; return 1 ;;
    esac
    code="${code//[^0-9]/}"
    is_uint "$code" || code=0
    printf '%s' "$code"
    return 0
}

# download_file URL DEST [MAX_SECONDS] -> 0 on success. Downloads to a temporary
# name and renames, so a truncated download never sits there looking like a
# complete phar.
download_file() {
    local url="${1-}" dest="${2-}" t="${3:-300}" client tmp rc=0
    client="$(http_client_resolve)" || return 1
    [ -n "$dest" ] || return 2
    ensure_parent_dir "$dest" || return 2
    tmp="${dest}.part.$$"
    case "$client" in
        curl) curl -fSL --max-time "$t" --retry 2 -o "$tmp" -- "$url" >/dev/null 2>&1 || rc=$? ;;
        wget) wget -q -T "$t" -t 2 -O "$tmp" -- "$url" >/dev/null 2>&1 || rc=$? ;;
        *) rc=1 ;;
    esac
    if ((rc != 0)) || [ ! -s "$tmp" ]; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

###############################################################################
# Section 4 - tabular and JSON rendering
###############################################################################

# table_render [MAX_ROWS] < TSV
#
# Aligned columns from a TSV stream. Widths are measured over the rows that will
# actually be printed, so a 400-plugin site cannot blow up the terminal or spend
# a second measuring text nobody will read.
#
# Two bugs that shipped once and are gone:
#   - iterating rows with an unquoted expansion, which split any cell holding a
#     space into two columns;
#   - measuring widths over every row but printing only MAX_ROWS of them, which
#     produced a table aligned for columns that were never shown.
table_render() {
    local max="${1:-0}"
    local -a header=() rows=() widths=() col=()
    local line i n j sep='' dashes

    IFS= read -r line || return 0
    line="${line%$'\r'}"
    IFS=$'\t' read -r -a header <<<"$line"
    n=${#header[@]}
    ((n == 0)) && return 0
    for ((i = 0; i < n; i++)); do widths[i]=${#header[i]}; done

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        ((max > 0)) && ((${#rows[@]} >= max)) && break
        rows+=("$line")
        col=()
        IFS=$'\t' read -r -a col <<<"$line"
        for ((i = 0; i < n && i < ${#col[@]}; i++)); do
            ((${#col[i]} > widths[i])) && widths[i]=${#col[i]}
        done
    done

    for ((j = 0; j < n; j++)); do
        printf '%-*s  ' "${widths[j]}" "${header[j]-}"
    done
    printf '\n'
    for ((i = 0; i < n; i++)); do
        printf -v dashes '%*s' "${widths[i]}" ''
        sep+="${dashes// /-}  "
    done
    printf '%s%s%s\n' "$C_DIM" "${sep%  }" "$C_RESET"

    for ((i = 0; i < ${#rows[@]}; i++)); do
        col=()
        IFS=$'\t' read -r -a col <<<"${rows[i]}"
        for ((j = 0; j < n; j++)); do
            printf '%-*s  ' "${widths[j]}" "${col[j]-}"
        done
        printf '\n'
    done
    return 0
}

# tsv_to_csv < TSV
tsv_to_csv() {
    local line first field out
    local -a f=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        f=()
        IFS=$'\t' read -r -a f <<<"$line"
        first=1 out=''
        for field in ${f[@]+"${f[@]}"}; do
            ((first)) || out+=','
            first=0
            out+="$(csv_escape "$field")"
        done
        printf '%s\n' "$out"
    done
    return 0
}

# --- output sinks -----------------------------------------------------------
#
# Nothing in this project redirects to /dev/stdout. It looks like the obvious way
# to say "the default destination", and it is not portable: /dev/stdout is a
# symlink to /proc/self/fd/1 on Linux, so it disappears in a chroot with no
# /proc, it is absent on a few minimal images, and where fd 1 is a socket the
# open fails with ENXIO ("No such device or address") -- which a `2>/dev/null`
# guard turns into silently lost output. The convention here is therefore: an
# EMPTY sink string means stdout, and every writer goes through one of these.

# sink_write SINK < CONTENT : truncate and write
sink_write() {
    local s="${1-}"
    if [ -n "$s" ]; then cat >"$s"; else cat; fi
}

# sink_append SINK < CONTENT : append
sink_append() {
    local s="${1-}"
    if [ -n "$s" ]; then cat >>"$s"; else cat; fi
}

# sink_of PATH_OR_EMPTY : normalise a caller-supplied destination, where both ''
# and '-' mean stdout.
sink_of() {
    case "${1-}" in
        '' | '-' | /dev/stdout) printf '' ;;
        *) printf '%s' "${1}" ;;
    esac
}

# render_tsv TSV [MAX_ROWS] [SINK] : send a TSV document to a sink in the
# configured format. Every listing goes through here, which is why `--format`
# works uniformly for plugins, sites, reports and audits.
render_tsv() { # TSV [MAX_ROWS] [SINK]
    local tsv="${1-}" max="${2:-0}" sink
    sink="$(sink_of "${3-}")"
    case "${OUTPUT_FORMAT:-table}" in
        csv) printf '%s\n' "$tsv" | tsv_to_csv | sink_write "$sink" ;;
        tsv) printf '%s\n' "$tsv" | sink_write "$sink" ;;
        table | *) printf '%s\n' "$tsv" | table_render "$max" | sink_write "$sink" ;;
    esac
    return 0
}

# jq_available -> path to jq, non-zero when unavailable or disallowed.
# jq is an accelerator, never a dependency: a host without it must behave
# identically, which is why the pure-bash reader below stays in the tree and
# stays tested even where jq is installed.
JQ_RESOLVED=''
jq_available() {
    if [ -n "$JQ_RESOLVED" ]; then
        [ "$JQ_RESOLVED" != 'no' ] || return 1
        printf '%s' "$JQ_RESOLVED"
        return 0
    fi
    case "${USE_JQ:-auto}" in
        no) JQ_RESOLVED='no' ;;
        yes)
            if have jq; then
                JQ_RESOLVED="$(command -v jq)"
            else
                JQ_RESOLVED='no'
                log_warn 'USE_JQ=yes but jq(1) is not installed; using the built-in reader'
            fi
            ;;
        auto | *)
            if have jq; then JQ_RESOLVED="$(command -v jq)"; else JQ_RESOLVED='no'; fi
            ;;
    esac
    [ "$JQ_RESOLVED" != 'no' ] || return 1
    printf '%s' "$JQ_RESOLVED"
    return 0
}

# json_to_tsv KEYS... < JSON -> TSV, header line first.
json_to_tsv() {
    local data='' jq_bin keys_json='' k out='' tsv=''
    # `read -r -d ''` slurps stdin without forking. `$(cat)` is the obvious way
    # and it execs /bin/cat once per call -- and this function is called once per
    # site for every listing, report and audit, so on a 200-site fleet that is
    # several hundred processes spent on reading a pipe. read returns non-zero at
    # EOF, which is the normal end of the input and not an error.
    IFS= read -r -d '' data || true
    data="${data#"${data%%[![:space:]]*}"}"
    data="${data%"${data##*[![:space:]]}"}"
    [ -n "$data" ] || return 0
    for k in "$@"; do out+="${out:+$'\t'}${k}"; done

    if jq_bin="$(jq_available)"; then
        for k in "$@"; do
            [ -n "$keys_json" ] && keys_json+=','
            json_escape "$k"
            keys_json+="\"${JSON_ESCAPED}\""
        done
        # `// ""` keeps a missing key an empty cell instead of null, and tostring
        # normalises numbers and booleans, so both readers agree cell for cell.
        if tsv="$("$jq_bin" -r --argjson keys "[${keys_json}]" \
            '.[] | . as $o | [$keys[] | (($o[.] // "") | if type == "string" then . else tostring end)] | @tsv' \
            <<<"$data" 2>/dev/null)"; then
            printf '%s\n' "$out"
            [ -n "$tsv" ] && printf '%s\n' "$tsv"
            return 0
        fi
        log_debug 'the jq path failed; falling back to the built-in JSON reader'
    fi
    _json_to_tsv_builtin "$@" <<<"$data"
}

# _json_unescape BODY -> the literal value of a JSON string body
_json_unescape() {
    local s="${1-}" out='' ch two hex seq
    while [ -n "$s" ]; do
        ch="${s:0:1}"
        if [ "$ch" != '\' ]; then
            out+="$ch"; s="${s:1}"; continue
        fi
        two="${s:1:1}"
        case "$two" in
            n) out+=$'\n'; s="${s:2}" ;;
            r) out+=$'\r'; s="${s:2}" ;;
            t) out+=$'\t'; s="${s:2}" ;;
            b) out+=$'\b'; s="${s:2}" ;;
            f) out+=$'\f'; s="${s:2}" ;;
            '/') out+='/'; s="${s:2}" ;;
            u)
                hex="${s:2:4}"
                if [[ "$hex" =~ ^[0-9A-Fa-f]{4}$ ]]; then
                    # Only the BMP is decoded. A surrogate half becomes the
                    # replacement character rather than half a word, because a
                    # mangled plugin title in a report beats a malformed TSV line.
                    if ((16#$hex >= 55296)) && ((16#$hex <= 57343)); then
                        out+=$'\xEF\xBF\xBD'
                    else
                        printf -v seq '\\u%04x' "$((16#$hex))"
                        if printf -v ch '%b' "$seq" 2>/dev/null && [ -n "$ch" ]; then
                            out+="$ch"
                        else
                            out+=$'\xEF\xBF\xBD'
                        fi
                    fi
                    s="${s:6}"
                else
                    out+="$two"; s="${s:2}"
                fi
                ;;
            '') out+='\\'; s="${s:1}" ;;
            *) out+="$two"; s="${s:2}" ;;
        esac
    done
    printf '%s' "$out"
}

# _json_to_tsv_builtin KEYS... < JSON
#
# A minimal reader for the flat array-of-objects shape WP-CLI emits with
# --format=json. Not a JSON parser and it does not pretend to be one: string,
# number, boolean and null values plus the standard escapes, no nesting.
_json_to_tsv_builtin() {
    local data obj val esc rest ch two
    local BSLASH='\'
    local -a keys=("$@")
    local out='' k

    IFS= read -r -d '' data || true      # slurp without forking cat(1)
    data="${data#"${data%%[![:space:]]*}"}"
    data="${data%"${data##*[![:space:]]}"}"
    [ -n "$data" ] || return 0
    case "$data" in
        '['*']') ;;
        *) return 1 ;;
    esac
    data="${data#\[}"
    data="${data%\]}"

    for k in ${keys[@]+"${keys[@]}"}; do out+="${out:+$'\t'}${k}"; done
    printf '%s\n' "$out"

    while [ -n "$data" ]; do
        data="${data#"${data%%[![:space:]]*}"}"
        data="${data%"${data##*[![:space:]]}"}"
        [ -n "$data" ] || break
        case "$data" in
            ,*) data="${data#,}"; continue ;;
        esac
        [ "${data:0:1}" = '{' ] || return 1
        rest="${data#\{}"
        obj=''
        # Walk one object while keeping quoted strings intact, so a comma, a
        # brace or a bracket inside a plugin title cannot end the object early.
        while :; do
            case "$rest" in
                '' | \}*) break ;;
                '"'*)
                    esc="${rest#\"}"
                    val=''
                    while :; do
                        ch="${esc:0:1}"
                        two="${esc:0:2}"
                        if [ -z "$ch" ] || [ "$ch" = '"' ]; then
                            break
                        elif [ "$two" = '\"' ]; then
                            val+='\"'; esc="${esc:2}"
                        elif [ "$ch" = "$BSLASH" ]; then
                            val+="$two"; esc="${esc:2}"
                        else
                            val+="$ch"; esc="${esc:1}"
                        fi
                    done
                    obj+="\"${val}\""
                    rest="${esc#\"}"
                    ;;
                *) obj+="${rest:0:1}"; rest="${rest:1}" ;;
            esac
        done
        data="$rest"
        data="${data#\}}"

        out=''
        for k in ${keys[@]+"${keys[@]}"}; do
            val=''
            if [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                val="$(_json_unescape "${BASH_REMATCH[1]}")"
                # A tab or a newline inside a value would invent columns; both
                # are legal JSON and both are flattened to a space here.
                val="${val//$'\t'/ }"
                val="${val//$'\n'/ }"
                val="${val//$'\r'/ }"
            elif [[ "$obj" =~ \"$k\"[[:space:]]*:[[:space:]]*(true|false|null|-?[0-9.]+) ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            out+="${out:+$'\t'}${val}"
        done
        printf '%s\n' "$out"
    done
    return 0
}

# json_array_slice TEXT -> the substring from the first '[' to the last ']'.
#
# WP-CLI writes notices and plugin deprecation warnings to stderr, and this tool
# merges the two streams so the operator reads one story in order. A JSON payload
# can therefore arrive with prose glued in front of it. Cutting to the brackets
# is what makes `plugin list --format=json` survive a chatty plugin instead of
# reporting "wp did not return JSON".
json_array_slice() {
    local body="${1-}" head
    case "$body" in
        *'['*']'*) ;;
        *) return 1 ;;
    esac
    head="${body%%\[*}"
    body="${body#"$head"}"
    printf '%s' "$body"
    return 0
}

# json_scalar KEY < JSON_OBJECT -> the value of KEY in a flat object.
# Used for the release API response, where a full parser for one field would be
# silly and a hard jq dependency would be worse.
json_scalar() {
    local key="${1-}" data=''
    IFS= read -r -d '' data || true      # slurp without forking cat(1)
    if [[ "$data" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        printf '%s' "$(_json_unescape "${BASH_REMATCH[1]}")"
        return 0
    fi
    if [[ "$data" =~ \"$key\"[[:space:]]*:[[:space:]]*(true|false|null|-?[0-9.eE+]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}
