#!/bin/bash
# bin/backup_staging.sh
#
# Assembles a consistent staging copy of a set of source directories (plus
# optional extra directories outside the source root, e.g. a secrets vault
# or a bare git repo) under CONFIG's STAGING_DIR, wiped and rebuilt on
# every run.
#
# Live sqlite databases are NEVER plain-copied (a hot WAL-mode db can be
# silently corrupted or lose recent writes under cp). Every *.db file
# discovered under the configured source directories is instead exported
# with `sqlite3 <db> ".backup <dest>"`, which is transactionally safe
# against a live database. All non-db content is copied with rsync.
#
# Usage:
#   bin/backup_staging.sh <path-to-config-file>
#
# See config/config.example.conf for the full list of variables this script
# reads (SOURCE_ROOT, STAGING_DIRS, EXTRA_DIRS, STAGING_DIR,
# EXTRA_RSYNC_EXCLUDES).
#
# Exit code: 0 on success (with a one-line summary printed), non-zero on
# any failure (rsync error, sqlite3 backup error, etc).
#
# Idempotent: safe to run repeatedly; each run wipes and rebuilds
# $STAGING_DIR from scratch, so re-running never accumulates stale files.

set -uo pipefail

CONFIG="${1:-}"
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
    echo "backup_staging.sh: usage: $0 <path-to-config-file>" >&2
    echo "backup_staging.sh: see config/config.example.conf for the format" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$CONFIG"

: "${SOURCE_ROOT:?SOURCE_ROOT must be set in $CONFIG}"
: "${STAGING_DIR:?STAGING_DIR must be set in $CONFIG}"
STAGING_DIRS=("${STAGING_DIRS[@]:-}")
EXTRA_DIRS=("${EXTRA_DIRS[@]:-}")
EXTRA_RSYNC_EXCLUDES=("${EXTRA_RSYNC_EXCLUDES[@]:-}")
STAGING_DIRS_COUNT=0
for d in "${STAGING_DIRS[@]}"; do [ -n "$d" ] && STAGING_DIRS_COUNT=$((STAGING_DIRS_COUNT + 1)); done
EXTRA_DIRS_COUNT=0
for d in "${EXTRA_DIRS[@]}"; do [ -n "$d" ] && EXTRA_DIRS_COUNT=$((EXTRA_DIRS_COUNT + 1)); done
if [ "$STAGING_DIRS_COUNT" -eq 0 ] && [ "$EXTRA_DIRS_COUNT" -eq 0 ]; then
    echo "backup_staging.sh: at least one of STAGING_DIRS or EXTRA_DIRS must be set in $CONFIG" >&2
    exit 2
fi

FAIL=0

fail() {
    echo "backup_staging.sh: FAILURE: $1" >&2
    FAIL=1
}

# --- 1. Wipe and rebuild the staging dir -----------------------------------

if [ -e "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR" || { fail "could not remove existing staging dir $STAGING_DIR"; exit 1; }
fi
mkdir -p "$STAGING_DIR/source" || { fail "could not create staging dir $STAGING_DIR"; exit 1; }

# Default rsync excludes: reproducible bulk we never want in the backup set.
# Extend with EXTRA_RSYNC_EXCLUDES in the config, don't edit this script.
RSYNC_EXCLUDES=(
    --exclude='__pycache__/'
    --exclude='*.pyc'
    --exclude='node_modules/'
    --exclude='.git/'
    --exclude='*/cache/'
    --exclude='*/caches/'
    --exclude='*trajectory*'
    --exclude='*.db'
    --exclude='*.db-wal'
    --exclude='*.db-shm'
    --exclude='*.db-journal'
)
EXTRA_EXCLUDE_ARGS=()
for pattern in "${EXTRA_RSYNC_EXCLUDES[@]}"; do
    [ -n "$pattern" ] || continue
    RSYNC_EXCLUDES+=(--exclude="$pattern")
    EXTRA_EXCLUDE_ARGS+=(--exclude="$pattern")
done

# --- 2. Live sqlite DBs under SOURCE_ROOT: sqlite3 .backup, never cp -------
# Discover every *.db under the configured source dirs (rather than a
# hardcoded list) so newly added databases are picked up automatically.

for rel_dir in "${STAGING_DIRS[@]}"; do
    [ -n "$rel_dir" ] || continue
    src_dir="$SOURCE_ROOT/$rel_dir"
    [ -d "$src_dir" ] || continue
    while IFS= read -r -d '' db_path; do
        rel_path="${db_path#"$SOURCE_ROOT"/}"
        dest_path="$STAGING_DIR/source/$rel_path"
        mkdir -p "$(dirname "$dest_path")" || { fail "mkdir failed for $dest_path"; continue; }
        if ! sqlite3 "$db_path" ".backup '$dest_path'" 2>/tmp/backup_staging_sqlite_err.$$; then
            fail "sqlite3 .backup failed for $db_path: $(cat /tmp/backup_staging_sqlite_err.$$ 2>/dev/null)"
        fi
        rm -f /tmp/backup_staging_sqlite_err.$$
    done < <(find "$src_dir" -type f -name '*.db' -print0 2>/dev/null)
done

# --- 3. Everything else under SOURCE_ROOT: rsync ---------------------------

for rel_dir in "${STAGING_DIRS[@]}"; do
    [ -n "$rel_dir" ] || continue
    src_dir="$SOURCE_ROOT/$rel_dir"
    [ -d "$src_dir" ] || continue
    dest_dir="$STAGING_DIR/source/$rel_dir"
    mkdir -p "$dest_dir"
    if ! rsync -a "${RSYNC_EXCLUDES[@]}" "$src_dir/" "$dest_dir/"; then
        fail "rsync failed for $src_dir"
    fi
done

# --- 4. Extra directories (outside SOURCE_ROOT), verbatim ------------------
# Format: "label:path", e.g. a secrets vault or a bare git repo. .git is
# preserved for these (not excluded) unless you add it via
# EXTRA_RSYNC_EXCLUDES - useful when the extra dir's own git history is
# itself the thing worth backing up.

for entry in "${EXTRA_DIRS[@]}"; do
    [ -n "$entry" ] || continue
    label="${entry%%:*}"
    path="${entry#*:}"
    if [ -z "$label" ] || [ -z "$path" ] || [ "$label" = "$entry" ]; then
        fail "malformed EXTRA_DIRS entry (want label:path): $entry"
        continue
    fi
    if [ ! -d "$path" ]; then
        fail "EXTRA_DIRS path does not exist: $path (label $label)"
        continue
    fi
    dest_dir="$STAGING_DIR/extra-$label"
    mkdir -p "$dest_dir"
    if ! rsync -a "${EXTRA_EXCLUDE_ARGS[@]}" "$path/" "$dest_dir/"; then
        fail "rsync failed for extra dir $path (label $label)"
    fi
done

# --- 5. Summary + exit -------------------------------------------------------

if [ "$FAIL" -ne 0 ]; then
    echo "backup_staging.sh: one or more steps failed; staging dir may be incomplete" >&2
    exit 1
fi

FILE_COUNT=$(find "$STAGING_DIR" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$STAGING_DIR" 2>/dev/null | cut -f1)
TOTAL_SIZE_BYTES=$(du -sb "$STAGING_DIR" 2>/dev/null | cut -f1)

echo "backup_staging.sh: OK - $FILE_COUNT files, $TOTAL_SIZE ($TOTAL_SIZE_BYTES bytes) staged at $STAGING_DIR"
exit 0
