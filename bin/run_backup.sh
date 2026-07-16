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
#     the configured PRUNE_DAY, optionally narrowed to PRUNE_HOUR_UTC too).
#   - Any failure calls the configured NOTIFY_CMD (if set); if unset, logs a
#     warning line instead of failing silently.
#   - Non-blocking overlap guard (flock on <STAGING_DIR>.run_backup.lock):
#     if a previous run is still going when this one fires, this run logs
#     and exits 0 rather than racing the same STAGING_DIR.

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
PRUNE_HOUR_UTC="${PRUNE_HOUR_UTC:-}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
RESTIC_TAG="${RESTIC_TAG:-backup}"

# --- Overlap guard -----------------------------------------------------
# A run on a 1-2 hourly cron can, in principle, still be going (slow
# network, large snapshot) when the next one fires; two runs racing on the
# same STAGING_DIR (wiped and rebuilt by backup_staging.sh) could back up
# a half-built tree. Non-blocking flock: if another run already holds the
# lock, log and exit 0 rather than treating it as a failure - it isn't
# one, the other run is doing the work.
LOCK_FILE="${STAGING_DIR%/}.run_backup.lock"
exec 200>"$LOCK_FILE" || { echo "run_backup.sh: FATAL - cannot open lock file $LOCK_FILE" >&2; exit 1; }
if ! flock -n 200; then
    echo "$(date -u +%FT%TZ) run_backup.sh: SKIPPED - another run_backup.sh invocation already holds the lock ($LOCK_FILE); not overlapping it"
    exit 0
fi

log() {
    echo "$(date -u +%FT%TZ) run_backup.sh: $1"
}

# Failure/recovery marker (2026-07-16, notif-smallfix-0716): a sibling file
# next to STAGING_DIR, separate from LOCK_FILE. notify_failure() records
# what failed here; a later successful run checks it and, if present, sends
# an explicit "recovered" notice and clears it - so a failure alert is never
# followed by silence (the owner previously had to infer resolution from a
# gap in alerts, e.g. the 2026-07-16 07:45 lock failure that quietly
# self-resolved at 07:55 with no follow-up notice).
FAILURE_MARKER="${STAGING_DIR%/}.run_backup.failed"

notify_failure() {
    # $1 = title, $2 = body. Best-effort: a notify problem is logged but
    # never raised - it must never mask the real failure or change this
    # script's exit code.
    local title="$1"
    local body="$2"
    echo "${title}|$(date -u +%FT%TZ)" > "$FAILURE_MARKER" 2>/dev/null || true
    if [ -z "$NOTIFY_CMD" ]; then
        log "WARNING - no NOTIFY_CMD configured; failure not delivered anywhere but this log: $title"
        return
    fi
    if ! "$NOTIFY_CMD" "$title" "$body" "high" 2>/tmp/run_backup_notify_err.$$; then
        log "WARNING - NOTIFY_CMD ($NOTIFY_CMD) could not deliver the notification ($(tail -1 /tmp/run_backup_notify_err.$$ 2>/dev/null)); failure was: $title"
    fi
    rm -f /tmp/run_backup_notify_err.$$
}

notify_recovered() {
    # $1 = title, $2 = body. Same best-effort contract as notify_failure(),
    # but priority "medium" not "high" - this is good news, not an alarm.
    local title="$1"
    local body="$2"
    if [ -z "$NOTIFY_CMD" ]; then
        log "WARNING - no NOTIFY_CMD configured; recovery notice not delivered anywhere but this log: $title"
        return
    fi
    if ! "$NOTIFY_CMD" "$title" "$body" "medium" 2>/tmp/run_backup_notify_err.$$; then
        log "WARNING - NOTIFY_CMD ($NOTIFY_CMD) could not deliver the recovery notice ($(tail -1 /tmp/run_backup_notify_err.$$ 2>/dev/null))"
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
        "The backup could not start - the staging step (gathering files to back up) failed. This is not auto-retried; it needs a look."$'\n\n'"Technical detail: run_backup.sh: backup_staging.sh exited $STAGING_STATUS. Output:"$'\n'"$STAGING_OUTPUT"
    exit 1
fi

RESTIC_OUTPUT=$(restic -r "$RESTIC_REPO" backup "$STAGING_DIR" --tag "$RESTIC_TAG" 2>&1)
RESTIC_STATUS=$?
log "restic backup output: $RESTIC_OUTPUT"

if [ "$RESTIC_STATUS" -ne 0 ]; then
    log "FAILED - restic backup exited $RESTIC_STATUS"
    notify_failure "Backup FAILED: restic backup step" \
        "Files were staged, but the upload to the backup repository failed. This is not auto-retried; it needs a look."$'\n\n'"Technical detail: run_backup.sh: restic backup to $RESTIC_REPO exited $RESTIC_STATUS. Output:"$'\n'"$RESTIC_OUTPUT"
    exit 1
fi

# --- 3. Retention: forget every run, prune only on PRUNE_DAY ----------------
#
# PRUNE_HOUR_UTC is optional. Left unset (the default), --prune is added
# on every invocation that falls on PRUNE_DAY - matching the original
# behaviour this was generalised from, which on an every-2-hours cron
# means --prune runs ~12 times on the prune day, not once. That is
# tolerated by design (forget/prune is safe to run repeatedly, just more
# I/O than strictly needed) rather than changed by default, since it's an
# existing consumer's already-relied-on behaviour. Set PRUNE_HOUR_UTC
# (0-23) if you want --prune gated to a single hour on PRUNE_DAY instead.
PRUNE_FLAG=""
if [ -n "$PRUNE_DAY" ] && [ "$(date -u +%u)" -eq "$PRUNE_DAY" ]; then
    HOUR_MATCH=1
    if [ -n "$PRUNE_HOUR_UTC" ]; then
        # 10# forces base-10 so a zero-padded hour (e.g. "08") isn't
        # misread as an invalid octal literal by bash arithmetic.
        CURRENT_HOUR_UTC="$(date -u +%H)"
        [ "$((10#$CURRENT_HOUR_UTC))" -eq "$((10#$PRUNE_HOUR_UTC))" ] || HOUR_MATCH=0
    fi
    if [ "$HOUR_MATCH" -eq 1 ]; then
        PRUNE_FLAG="--prune"
        log "configured prune day (UTC)${PRUNE_HOUR_UTC:+/hour} - forget will include --prune"
    fi
fi

FORGET_OUTPUT=$(restic -r "$RESTIC_REPO" forget \
    --keep-hourly "$RETENTION_HOURLY" --keep-daily "$RETENTION_DAILY" \
    --keep-weekly "$RETENTION_WEEKLY" --keep-monthly "$RETENTION_MONTHLY" \
    $PRUNE_FLAG 2>&1)
FORGET_STATUS=$?
log "restic forget output: $FORGET_OUTPUT"

# Stale-lock retry-before-alerting guard (2026-07-16, notif-smallfix-0716,
# review recommendation 7): the 07:45 UTC "Backup FAILED" notification on
# 2026-07-16 was a stale restic lock from an overlapping prior run that
# cleared itself 10 minutes later with no owner-visible resolution. `restic
# unlock` (no --remove-all) only removes locks restic itself judges stale
# (owning process no longer alive) - it will refuse to touch a lock held by
# a genuinely still-running restic, so this is safe to run unconditionally
# whenever forget reports a lock conflict. One retry only; a lock that
# survives the unlock+retry is treated as a real failure, not swallowed.
if [ "$FORGET_STATUS" -ne 0 ] && printf '%s' "$FORGET_OUTPUT" | grep -qiE 'already locked|unable to create lock'; then
    log "retention step hit a repository lock (likely stale, from an overlapping earlier run) - clearing stale locks only (restic unlock) and retrying once before alerting"
    UNLOCK_OUTPUT=$(restic -r "$RESTIC_REPO" unlock 2>&1)
    UNLOCK_STATUS=$?
    log "restic unlock output: $UNLOCK_OUTPUT"
    if [ "$UNLOCK_STATUS" -eq 0 ]; then
        FORGET_OUTPUT=$(restic -r "$RESTIC_REPO" forget \
            --keep-hourly "$RETENTION_HOURLY" --keep-daily "$RETENTION_DAILY" \
            --keep-weekly "$RETENTION_WEEKLY" --keep-monthly "$RETENTION_MONTHLY" \
            $PRUNE_FLAG 2>&1)
        FORGET_STATUS=$?
        log "restic forget retry (post-unlock) output: $FORGET_OUTPUT"
        if [ "$FORGET_STATUS" -eq 0 ]; then
            log "RECOVERED - stale lock cleared automatically, retention retry succeeded, no alert needed"
        fi
    else
        log "WARNING - restic unlock itself failed ($UNLOCK_STATUS); not retrying forget"
    fi
fi

if [ "$FORGET_STATUS" -ne 0 ]; then
    log "FAILED - restic forget exited $FORGET_STATUS"
    PLAIN_LEAD="A backup completed successfully, but the retention/cleanup step (removing old snapshots) failed."
    if printf '%s' "$FORGET_OUTPUT" | grep -qiE 'already locked|unable to create lock'; then
        PLAIN_LEAD="A backup completed successfully, but a leftover lock from a previous run blocked the retention/cleanup step. This script already tried clearing the stale lock and retrying automatically - that did NOT clear it, so this needs a manual look (a lock this persistent may mean a process is genuinely still running, or stuck)."
    fi
    notify_failure "Backup retention step FAILED${PRUNE_FLAG:+ (prune day)}" \
        "$PLAIN_LEAD"$'\n\n'"Technical detail: run_backup.sh: restic forget${PRUNE_FLAG:+ --prune} on $RESTIC_REPO exited $FORGET_STATUS. Output:"$'\n'"$FORGET_OUTPUT"
    exit 1
fi

log "OK - backup + retention completed successfully"

# Resolution notice (2026-07-16, notif-smallfix-0716): if a PRIOR run left a
# failure marker (see notify_failure()), this run's clean success clears it
# and tells the owner plainly - avoids the "alarm-then-silence" pattern from
# 2026-07-16's 07:45 lock failure, which self-resolved at 07:55 with no
# follow-up notice of its own.
if [ -f "$FAILURE_MARKER" ]; then
    PRIOR_RECORD="$(cat "$FAILURE_MARKER" 2>/dev/null)"
    log "RECOVERED - this run succeeded after a previous failure ($PRIOR_RECORD); sending resolution notice"
    notify_recovered "Backup recovered" \
        "The earlier backup failure has cleared - this run completed successfully with no errors."$'\n\n'"Previous failure record: ${PRIOR_RECORD:-unknown}"
    rm -f "$FAILURE_MARKER"
fi

exit 0
