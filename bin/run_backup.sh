#!/bin/bash
# bin/run_backup.sh
#
# Cron entrypoint for restic+rclone offsite backups. Generic across
# consumers: all account-specific detail (paths, staging list, rclone
# remote, restic repo, retention, notifier) comes from a config file
# passed as the first argument - see config/config.example.conf.
#
# Suggested crontab line (adjust the config path and log path per consumer,
# and see your consumer's own setup docs for the exact schedule/safety
# procedure for editing crontab):
#
#   45 */2 * * * bin/run_backup.sh /path/to/your/config.conf >> /path/to/your/backup.log 2>&1
#
# Behaviour:
#   - If the configured rclone remote is not set up yet, or the restic repo
#     is not reachable through it (e.g. not yet initialised), this logs a
#     single clear line and exits 0. That lets the cron line be installed
#     ahead of a one-time OAuth/setup step without alert spam or a broken
#     cron.
#   - Otherwise: runs bin/backup_staging.sh with the same config, then
#     `restic backup` of the staging dir against the configured repo, then
#     `restic forget` with the configured retention policy (--prune only on
#     the configured PRUNE_DAY, since prune is the expensive repack step).
#   - Any failure calls the configured NOTIFY_CMD (if set); if unset, logs a
#     warning line instead of failing silently.

set -uo pipefail

CONFIG="${1:-}"
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
    echo "run_backup.sh: usage: $0 <path-to-config-file>" >&2
    echo "run_backup.sh: see config/config.example.conf for the format" >&2
    exit 2
fi
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "$CONFIG"

: "${STAGING_DIR:?STAGING_DIR must be set in $CONFIG}"
: "${RESTIC_REPO:?RESTIC_REPO must be set in $CONFIG}"
: "${RCLONE_REMOTE_NAME:?RCLONE_REMOTE_NAME must be set in $CONFIG}"
: "${RESTIC_PASSWORD_COMMAND:?RESTIC_PASSWORD_COMMAND must be set in $CONFIG}"
RETENTION_HOURLY="${RETENTION_HOURLY:-24}"
RETENTION_DAILY="${RETENTION_DAILY:-14}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-8}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-6}"
PRUNE_DAY="${PRUNE_DAY:-7}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
RESTIC_TAG="${RESTIC_TAG:-backup}"

log() {
    echo "$(date -u +%FT%TZ) run_backup.sh: $1"
}

notify_failure() {
    # $1 = title, $2 = body. Best-effort: a notify problem is logged but
    # never raised - it must never mask the real failure or change this
    # script's exit code.
    local title="$1"
    local body="$2"
    if [ -z "$NOTIFY_CMD" ]; then
        log "WARNING - no NOTIFY_CMD configured; failure not delivered anywhere but this log: $title"
        return
    fi
    if ! "$NOTIFY_CMD" "$title" "$body" "high" 2>/tmp/run_backup_notify_err.$$; then
        log "WARNING - NOTIFY_CMD ($NOTIFY_CMD) could not deliver the notification ($(tail -1 /tmp/run_backup_notify_err.$$ 2>/dev/null)); failure was: $title"
    fi
    rm -f /tmp/run_backup_notify_err.$$
}

# --- 1. Not configured yet? Skip quietly (exit 0) ---------------------------

if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE_NAME}:"; then
    log "NOT CONFIGURED YET - skipping (rclone setup pending): rclone remote '${RCLONE_REMOTE_NAME}:' does not exist"
    exit 0
fi

export RESTIC_PASSWORD_COMMAND

if ! restic -r "$RESTIC_REPO" snapshots --latest 1 >/dev/null 2>/tmp/run_backup_repo_check.$$; then
    log "NOT CONFIGURED YET - skipping (repo setup pending): restic repo $RESTIC_REPO not reachable/initialised ($(tail -1 /tmp/run_backup_repo_check.$$ 2>/dev/null))"
    rm -f /tmp/run_backup_repo_check.$$
    exit 0
fi
rm -f /tmp/run_backup_repo_check.$$

# --- 2. Real backup path -----------------------------------------------------

log "starting: staging + restic backup to $RESTIC_REPO"

STAGING_OUTPUT=$(bash "$BIN_DIR/backup_staging.sh" "$CONFIG" 2>&1)
STAGING_STATUS=$?
log "backup_staging.sh output: $STAGING_OUTPUT"

if [ "$STAGING_STATUS" -ne 0 ]; then
    log "FAILED - backup_staging.sh exited $STAGING_STATUS"
    notify_failure "Backup FAILED: staging step" \
        "run_backup.sh: backup_staging.sh exited $STAGING_STATUS. Output:\n$STAGING_OUTPUT"
    exit 1
fi

RESTIC_OUTPUT=$(restic -r "$RESTIC_REPO" backup "$STAGING_DIR" --tag "$RESTIC_TAG" 2>&1)
RESTIC_STATUS=$?
log "restic backup output: $RESTIC_OUTPUT"

if [ "$RESTIC_STATUS" -ne 0 ]; then
    log "FAILED - restic backup exited $RESTIC_STATUS"
    notify_failure "Backup FAILED: restic backup step" \
        "run_backup.sh: restic backup to $RESTIC_REPO exited $RESTIC_STATUS. Output:\n$RESTIC_OUTPUT"
    exit 1
fi

# --- 3. Retention: forget every run, prune only on PRUNE_DAY ----------------

PRUNE_FLAG=""
if [ -n "$PRUNE_DAY" ] && [ "$(date -u +%u)" -eq "$PRUNE_DAY" ]; then
    PRUNE_FLAG="--prune"
    log "configured prune day (UTC) - forget will include --prune"
fi

FORGET_OUTPUT=$(restic -r "$RESTIC_REPO" forget \
    --keep-hourly "$RETENTION_HOURLY" --keep-daily "$RETENTION_DAILY" \
    --keep-weekly "$RETENTION_WEEKLY" --keep-monthly "$RETENTION_MONTHLY" \
    $PRUNE_FLAG 2>&1)
FORGET_STATUS=$?
log "restic forget output: $FORGET_OUTPUT"

if [ "$FORGET_STATUS" -ne 0 ]; then
    log "FAILED - restic forget exited $FORGET_STATUS"
    notify_failure "Backup FAILED: retention (forget${PRUNE_FLAG:+/prune}) step" \
        "run_backup.sh: restic forget${PRUNE_FLAG:+ --prune} on $RESTIC_REPO exited $FORGET_STATUS. Output:\n$FORGET_OUTPUT"
    exit 1
fi

log "OK - backup + retention completed successfully"
exit 0
