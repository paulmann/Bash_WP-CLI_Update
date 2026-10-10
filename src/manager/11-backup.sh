###############################################################################
# Section 21 - backups
###############################################################################
#
# A maintenance tool that changes 200 databases and cannot undo any of them is a
# tool nobody will schedule. Two modes are offered and the difference matters:
#
#   db    `wp db export` -- seconds, and it covers everything the modes in this
#         script actually change;
#   full  a tar.gz of the whole installation -- complete, and on a site with a
#         large wp-content/uploads it can be tens of gigabytes and many minutes.
#
# `full` is opt-in and the tool says out loud how big the tree is before
# archiving it. Backups are off by default: silently writing a database dump per
# site per run fills disks that nobody monitors, and a full disk takes down the
# sites the run was supposed to protect.
#
# The rule that follows from all of it: a failed backup skips the site. Updating
# unprotected after being asked to take a backup is the one outcome worse than
# not updating.

# backup_dir_of -> sets BACKUP_ROOT and prints it: the configured root, or
# <script dir>/backups.
BACKUP_ROOT=''
backup_dir_of() {
    if [ -n "$BACKUP_DIR" ]; then
        BACKUP_ROOT="$BACKUP_DIR"
    else
        BACKUP_ROOT="${SCRIPT_DIR}/backups"
    fi
    printf '%s' "$BACKUP_ROOT"
    return 0
}

# site_backup_dir SITE -> one directory per site.
# Named after the site directory with everything outside a safe set replaced, so
# two sites both called `www` share a folder; the file names carry a timestamp
# and the kind, so nothing is lost and nothing is overwritten.
# site_backup_dir SITE -> sets SITE_BACKUP_DIR and prints it. Fork-free: it is
# consulted per site by every backup, prune and restore path.
SITE_BACKUP_DIR=''
site_backup_dir() { # SITE
    local name
    path_base "${1-}" >/dev/null
    name="${PATH_BASE//[^A-Za-z0-9._-]/_}"
    [ -n "$name" ] || name='_'
    backup_dir_of >/dev/null
    SITE_BACKUP_DIR="${BACKUP_ROOT}/${name}"
    printf '%s' "$SITE_BACKUP_DIR"
    return 0
}

# backup_ensure_dir DIR [USER]
#
# The manager creates this directory, but `wp db export` writes into it as the
# site owner after the user switch. A plain mkdir gives it the manager's umask --
# 0750 root, after the umask 077 at the top of this file -- and the export then
# dies with "Permission denied", which reads as "the database backup failed" and
# hides the real cause.
#
# The right answer is a directory owned by the site user, which is what happens
# when this runs as root: 0750 and chown, so a dump containing every password
# hash on the site is not readable by the neighbours. When chown is not
# available, the fallback is 1777 with the sticky bit -- exactly like /tmp: any
# local user may create a file inside, and the sticky bit stops one user from
# deleting or renaming another user's dump. The fallback is a compromise and the
# log says so.
backup_ensure_dir() { # DIR [USER]
    local dir="${1-}" user="${2-}"
    [ -n "$dir" ] || return 1
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        return 1
    fi
    if [ -n "$user" ] && [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        if chown -- "$user" "$dir" 2>/dev/null; then
            chmod 0750 "$dir" 2>/dev/null
            return 0
        fi
        log_debug "cannot chown ${dir} to ${user}; falling back to a sticky shared directory"
    fi
    chmod 1777 "$dir" 2>/dev/null
    return 0
}

# prune_backups DIR
#
# Keep the newest KEEP_BACKUPS of each kind. Sorting is done with stat(1) and
# `sort -rn` rather than `find -printf`, because -printf is a GNU extension and
# the fallback has to work on the hosts where the rest of this tool already
# degrades. `ls -1t` is not used either: its output is locale- and
# width-dependent and breaks on names with spaces.
prune_backups() { # DIR
    local dir="${1-}" keep="${KEEP_BACKUPS:-0}" f ts i=0
    ((keep > 0)) || return 0
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i + 1))
        if ((i > keep)); then
            if rm -f -- "$f" 2>/dev/null; then
                log_debug "backup pruned: $(path_base "$f")"
            fi
        fi
    done < <(
        find "$dir" -maxdepth 1 -type f \
            \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
            -print0 2>/dev/null |
            while IFS= read -r -d '' ts; do
                printf '%s %s\n' "$(stat -c '%Y' -- "$ts" 2>/dev/null || printf 0)" "$ts"
            done | sort -rn | cut -d' ' -f2-
    )
    return 0
}

# backup_space_ok DIR SITE -> 0 when there is room for the dump.
# A dump written onto a full filesystem is truncated, and a truncated dump looks
# exactly like a backup until the moment it is needed. Estimating "the database
# is at most as big as the site tree" is crude and deliberately so: the point is
# to catch "the volume has 40 MiB left", not to be precise.
backup_space_ok() { # DIR SITE
    local dir="${1-}" site="${2-}" need have
    ((MIN_FREE_MIB > 0)) || return 0
    ensure_parent_dir "${dir}/.probe" 2>/dev/null
    have="$(free_mib "$dir")" || have=0
    need="$MIN_FREE_MIB"
    if ((have < need)); then
        log_error "only ${have} MiB free on $(df -P -- "$dir" 2>/dev/null | awk 'NR==2 {print $1}'); MIN_FREE_MIB asks for ${need}"
        return 1
    fi
    log_debug "free space check: ${have} MiB available, ${need} MiB required"
    return 0
}

# backup_database SITE USER -> 0 when a usable dump exists.
backup_database() { # SITE USER
    local site="$1" user="$2" dir file stamp rc=0 size=0
    local saved="$TIMEOUT"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would export the database of ${site}"
        return 0
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$user"; then
        log_error "cannot create the backup directory ${dir}"
        return 1
    fi
    if ! backup_space_ok "$dir" "$site"; then
        return 1
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/db-${stamp}.sql"
    # The dump must not be killed by the per-command timeout: a large database
    # takes longer than a plugin update, and a truncated dump is worse than no
    # dump because it looks like a backup.
    TIMEOUT=0
    info_wp "$site" "$user" '' db export "$file"
    rc="$WP_STATUS"
    TIMEOUT="$saved"
    if ((rc != 0)) || [ ! -s "$file" ]; then
        log_error "database backup failed for ${site} (wp exit ${rc})"
        [ -n "$WP_OUTPUT" ] && log_error_detail 'backup_database' 'wp db export' "$WP_OUTPUT" "$rc"
        rm -f -- "$file" 2>/dev/null
        return 1
    fi
    # A dump that mysqld finished carries its own marker. Checking for it is the
    # difference between "a file appeared" and "the database was exported", and
    # it costs one tail.
    if have tail && ! tail -c 4096 -- "$file" 2>/dev/null | grep -q 'Dump completed'; then
        log_warn "${file} has no 'Dump completed' marker; the export may be truncated"
    fi
    chmod 0640 "$file" 2>/dev/null
    if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        chown -- "$user" "$file" 2>/dev/null
    fi
    size="$(file_size "$file")"
    LAST_BACKUP_DB="$file"
    STATS_BACKUPS=$((STATS_BACKUPS + 1))
    log_ok "database backup: ${file} ($(human_bytes "$size"))"
    prune_backups "$dir"
    return 0
}

# backup_site_tree SITE USER -> 0 when an archive exists
backup_site_tree() { # SITE USER
    local site="$1" user="$2" dir file stamp size rc=0
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would archive the whole tree of ${site}"
        return 0
    fi
    if ! have tar; then
        if [ "$WARNED_NO_TAR" = 'false' ]; then
            log_warn 'tar(1) not found; --backup full degrades to a database dump'
            WARNED_NO_TAR='true'
        fi
        backup_database "$site" "$user"
        return $?
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$user"; then
        log_error "cannot create the backup directory ${dir}"
        return 1
    fi
    if ! backup_space_ok "$dir" "$site"; then
        return 1
    fi
    size="$(dir_kib "$site")"
    if [ -n "$size" ] && ((size > 1048576)); then
        log_warn "${site} is $((size / 1024)) MiB; --backup full will take a while and a lot of disk"
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/site-${stamp}.tar.gz"
    # --warning=no-file-changed: a live uploads directory changes while it is
    # archived, and tar reports that as an error. It is not one; the archive is
    # still a valid recovery point for everything that was stable.
    if tar --warning=no-file-changed -czf "$file" \
            -C "$(path_dir "$site")" "$(path_base "$site")" 2>/dev/null; then
        :
    else
        rc=$?
        # 1 = "some files differ/vanished", which for a live site is normal.
        if ((rc != 1)) || [ ! -s "$file" ]; then
            log_error "site archive failed for ${site} (tar exit ${rc})"
            rm -f -- "$file" 2>/dev/null
            return 1
        fi
        log_debug "tar reported changed files while archiving ${site} (exit 1); the archive is usable"
    fi
    chmod 0640 "$file" 2>/dev/null
    if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
        chown -- "$user" "$file" 2>/dev/null
    fi
    STATS_BACKUPS=$((STATS_BACKUPS + 1))
    log_ok "site archive: ${file} ($(human_bytes "$(file_size "$file")"))"
    prune_backups "$dir"
    return 0
}

# maybe_backup SITE USER : the pre-flight step of process_site.
maybe_backup() { # SITE USER
    local site="$1" user="$2"
    LAST_BACKUP_DB=''
    case "$BACKUP" in
        db) backup_database "$site" "$user" || return 1 ;;
        full) backup_site_tree "$site" "$user" || return 1 ;;
        off | *) return 0 ;;
    esac
    return 0
}

# backup_plugin SITE SLUG
#
# A plugin that is about to be deleted has no other copy anywhere, so this backup
# is not optional: it happens unless the operator explicitly said --no-backup.
backup_plugin() { # SITE SLUG
    local site="$1" slug="$2" dir src file stamp
    if [ "$NO_BACKUP_EXPLICIT" = 'true' ]; then
        log_warn "deleting ${slug} on ${site} without a backup, because --no-backup was given"
        return 0
    fi
    src="${site}/wp-content/plugins/${slug}"
    if [ ! -d "$src" ]; then
        log_debug "no plugin directory to back up: ${src}"
        return 0
    fi
    if ! have tar; then
        log_warn "tar(1) not found; ${slug} will be deleted without a file backup"
        return 0
    fi
    site_backup_dir "$site" >/dev/null; dir="$SITE_BACKUP_DIR"
    if ! backup_ensure_dir "$dir" "$CURRENT_USER"; then
        log_warn "cannot create the backup directory; deleting without a file backup"
        return 0
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would archive ${src} into ${dir}"
        return 0
    fi
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    file="${dir}/plugin-${slug//[^A-Za-z0-9._-]/_}-${stamp}.tar.gz"
    if tar --warning=no-file-changed -czf "$file" -C "${site}/wp-content/plugins" "$slug" 2>/dev/null; then
        chmod 0640 "$file" 2>/dev/null
        log_ok "plugin backup: ${file}"
        prune_backups "$dir"
    else
        log_warn "plugin backup failed for ${slug}; deleting anyway, because that is what was asked"
        rm -f -- "$file" 2>/dev/null
    fi
    return 0
}

###############################################################################
# Section 22 - restore
###############################################################################
#
# Recovery is a manual decision, so this is a manual tool: it lists what exists,
# takes a fresh dump before it overwrites anything, and refuses to run without an
# explicit --yes. There is deliberately no automatic rollback after a failed
# update -- restoring a database whose core files were already replaced leaves a
# site in a state that never existed, which is worse than the failure it was
# meant to fix.

# backups_list SITE -> one path per line, newest first
backups_list() { # SITE
    local dir f
    site_backup_dir "${1-}" >/dev/null; dir="$SITE_BACKUP_DIR"
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && printf '%s\n' "$f"
    done < <(
        find "$dir" -maxdepth 1 -type f \
            \( -name 'db-*.sql' -o -name 'db-*.sql.gz' -o -name 'site-*.tar.gz' -o -name 'plugin-*.tar.gz' \) \
            -print0 2>/dev/null |
            while IFS= read -r -d '' f; do
                printf '%s %s\n' "$(stat -c '%Y' -- "$f" 2>/dev/null || printf 0)" "$f"
            done | sort -rn | cut -d' ' -f2-
    )
    return 0
}

# looks_like_sql_dump FILE -> 0 when the file is plausibly a mysqldump.
# Importing the wrong file into a production database is unrecoverable, so the
# check is deliberately shallow and cheap: read the head, look for what mysqldump
# always writes, and refuse anything else.
looks_like_sql_dump() { # FILE
    local f="${1-}" head
    [ -s "$f" ] || return 1
    case "$f" in
        *.gz)
            have zcat || return 1
            head="$(zcat -- "$f" 2>/dev/null | head -c 2048)"
            ;;
        *) head="$(head -c 2048 -- "$f" 2>/dev/null)" ;;
    esac
    case "$head" in
        *'MySQL dump'* | *'MariaDB dump'* | *'phpMyAdmin SQL Dump'*) return 0 ;;
        *'CREATE TABLE'* | *'INSERT INTO'* | *'DROP TABLE IF EXISTS'*) return 0 ;;
    esac
    return 1
}

# mode_restore SITE USER : list or restore.
mode_restore() { # SITE USER
    local site="$1" user="$2" target='' i=0
    local -a found=()
    while IFS= read -r target; do
        [ -n "$target" ] && found+=("$target")
    done < <(backups_list "$site")

    if ((${#found[@]} == 0)); then
        site_backup_dir "$site" >/dev/null
        log_error "no backups were found for ${site} in ${SITE_BACKUP_DIR}"
        log_error "run with --backup db (or full) first, or point --from at an existing file"
        return 1
    fi
    if [ -z "$RESTORE_FROM" ]; then
        printf '\n%s== backups for %s ==%s\n' "$C_BOLD" "$site" "$C_RESET"
        for target in ${found[@]+"${found[@]}"}; do
            i=$((i + 1))
            printf '  %2d) %-46s %10s  %s\n' "$i" "$(path_base "$target")" \
                "$(human_bytes "$(file_size "$target")")" \
                "$(date -r "$target" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
        done
        printf '\n  newest: %s\n\n' "${found[0]}"
        printf 'restore with: %s --restore -S %s --from <number|path> --yes\n' \
            "$PROG_NAME" "$(sh_quote "$site")"
        return 0
    fi

    target="$RESTORE_FROM"
    if is_uint "$target" && ((target >= 1)) && ((target <= ${#found[@]})); then
        target="${found[$((target - 1))]}"
    elif [ ! -f "$target" ]; then
        log_error "--from '${RESTORE_FROM}' is neither a listed number nor an existing file"
        return 1
    fi
    if [ ! -r "$target" ]; then
        log_error "the backup is not readable by $(id -un): ${target}"
        return 1
    fi

    case "$target" in
        *'site-'*.tar.gz)
            if [ "$RESTORE_FILES" != 'true' ]; then
                log_error "${target##*/} is a whole-tree archive; restoring it needs --restore-files"
                log_error 'it overwrites wp-content, so the site should be offline while it runs'
                return 1
            fi
            restore_tree "$site" "$user" "$target"
            return $?
            ;;
        *'plugin-'*.tar.gz)
            if [ "$RESTORE_FILES" != 'true' ]; then
                log_error "${target##*/} is a plugin archive; restoring it needs --restore-files"
                return 1
            fi
            restore_tree "$site" "$user" "$target" "${site}/wp-content/plugins"
            return $?
            ;;
    esac

    if ! looks_like_sql_dump "$target"; then
        log_error "${target##*/} does not look like a SQL dump; refusing to import it"
        log_error 'a database import cannot be undone, so the file has to be recognisable'
        return 1
    fi
    restore_database "$site" "$user" "$target"
    return $?
}

# confirm_destructive PROMPT : the one interactive gate for irreversible work.
# A fleet run is normally unattended, so the rule is: with --yes the operator has
# already answered; without it a terminal is required, and a cron job with no
# terminal is refused rather than left hanging on a prompt nobody will see.
confirm_destructive() { # PROMPT
    local prompt="$1" answer
    if [ "$FORCE_DELETE" = 'true' ] || [ "$ASSUME_YES" = 'true' ]; then return 0; fi
    if [ ! -t 0 ]; then
        log_error "refusing to run '${prompt}' without a terminal; pass --yes to confirm explicitly"
        return 1
    fi
    printf '%s%s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RESET" >&2
    IFS= read -r answer || answer=''
    case "${answer,,}" in
        y | yes) return 0 ;;
    esac
    log_warn 'cancelled by the operator'
    return 1
}

restore_database() { # SITE USER FILE
    local site="$1" user="$2" file="$3"
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would import ${file} into ${site}"
        return 0
    fi
    if ! confirm_destructive "import ${file##*/} into the database of ${site}? This overwrites every table."; then
        return 1
    fi
    if [ "$BACKUP_BEFORE_RESTORE" = 'true' ]; then
        log_info 'taking a dump of the current database before the restore'
        if ! backup_database "$site" "$user"; then
            log_error 'the pre-restore dump failed; refusing to overwrite a database with no way back'
            log_error 'pass --no-backup to override, once you understand what that means'
            return 1
        fi
    fi
    # The dump is readable by root; the import runs as the site user, so the file
    # has to be readable by that account for the duration of one call.
    local restore_as_root='false'
    if [ "$(id -u)" -eq 0 ] && [ ! -r "$file" ]; then
        restore_as_root='true'
    fi
    if [ -n "$user" ] && [ "$(id -u)" -eq 0 ] && [ "$(file_owner "$file")" != "$user" ]; then
        chmod 0644 "$file" 2>/dev/null
    fi
    if run_wp "$site" "$user" '' db import "$file"; then
        log_ok "database restored on ${site} from ${file}"
        run_wp_soft "$site" "$user" '' cache flush >/dev/null
        return 0
    fi
    log_error "the import failed on ${site}"
    return 1
}

restore_tree() { # SITE USER ARCHIVE [DEST_DIR]
    local site="$1" user="$2" file="$3" dest="${4:-$(path_dir "$site")}"
    if ! have tar; then
        log_error 'tar(1) is required to restore an archive and was not found'
        return 1
    fi
    if [ "$DRY_RUN" = 'true' ]; then
        log_info "[dry-run] would extract ${file} into ${dest}"
        return 0
    fi
    if ! confirm_destructive "extract ${file##*/} over ${dest}? Existing files with the same names are overwritten."; then
        return 1
    fi
    mkdir -p -- "$dest" 2>/dev/null
    if tar -xzf "$file" -C "$dest" 2>/dev/null; then
        if [ "$(id -u)" -eq 0 ] && is_valid_username "$user"; then
            chown -R -- "$user" "$dest" 2>/dev/null
        fi
        log_ok "archive restored into ${dest}"
        return 0
    fi
    log_error "extracting ${file} into ${dest} failed"
    return 1
}
