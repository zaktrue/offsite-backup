# Offsite backup runbook (restic + rclone)

This is the generic runbook for this tool. It describes the mechanism and the
config keys; account-specific values (paths, remote name, repo, retention)
belong in your own `config.conf` (see `config/config.example.conf`), never
in this doc or in this repo.

## 1. What it backs up and how

`bin/backup_staging.sh <config>` assembles a consistent point-in-time copy
under `STAGING_DIR` (wiped and rebuilt every run - keep this directory
outside any git-tracked tree so a large staging tree never gets pulled into
a git history):

- Every live sqlite database found under the configured `STAGING_DIRS` is
  exported with `sqlite3 <db> ".backup <dest>"` - **never** a plain `cp`,
  which can silently corrupt or truncate a hot WAL-mode database. The
  script discovers `*.db` files dynamically each run rather than using a
  hardcoded list, so it automatically picks up new databases your app adds
  later.
- Everything else under `STAGING_DIRS` is copied with `rsync -a`, excluding
  `__pycache__/`, `node_modules/`, `.git/`, `*/cache/`, `*/caches/`,
  `*trajectory*`, and the `*.db*` files (handled separately above), plus
  any patterns you add via `EXTRA_RSYNC_EXCLUDES`.
- Any `EXTRA_DIRS` entries (paths outside `SOURCE_ROOT`, e.g. a secrets
  vault or a bare git repo) are copied verbatim, `.git` included unless you
  exclude it - useful when an extra dir's own history is the point of
  backing it up.
- On success it prints one line:
  `backup_staging.sh: OK - <N> files, <size> staged at <path>` and exits 0.
  Any failure prints `backup_staging.sh: FAILURE: ...` and exits non-zero.

`bin/run_backup.sh <config>` is the cron entrypoint. It:

1. Checks `rclone listremotes` for the configured remote. If absent, logs
   `NOT CONFIGURED YET - skipping` and exits 0.
2. Checks the restic repo is reachable
   (`restic -r <repo> snapshots --latest 1`). If that fails (remote exists
   but repo not yet initialised, or any other reachability problem), logs
   the same NOT CONFIGURED YET line and exits 0 - so the cron line can be
   installed today, before repo init, with no alert spam and nothing
   broken.
3. Otherwise: runs `backup_staging.sh` with the same config, then
   `restic backup` of the staging dir into the repo, tagged with the
   configured `RESTIC_TAG`.
4. Retention: `restic forget` with the configured
   `--keep-hourly/--keep-daily/--keep-weekly/--keep-monthly` runs every
   invocation (cheap - just unreferences snapshots outside the policy).
   `--prune` (the expensive repack that actually reclaims disk/remote
   space) is appended only on the configured `PRUNE_DAY`.
5. On any failure at any step, it calls the configured `NOTIFY_CMD` (see
   "Pluggable notifications" below). If `NOTIFY_CMD` is unset, it logs a
   warning line instead - never fails silently, but also never assumes a
   particular notification channel.
6. Every run logs UTC-timestamped lines to stdout/stderr. Redirect these to
   a log file from your crontab line (`>> /path/to/backup.log 2>&1`).

Both scripts pass `bash -n`. Neither ever prints the restic repository
password: `run_backup.sh` only sets `RESTIC_PASSWORD_COMMAND` as an
environment variable that `restic` itself invokes as a subprocess when it
needs the password.

## 2. Pluggable notifications

This tool has no built-in notification channel. `run_backup.sh` invokes
whatever you set `NOTIFY_CMD` to, as:

```
"$NOTIFY_CMD" "<title>" "<body>" "high"
```

The command must exit 0 on success. Write a small wrapper script in your
own account/app that speaks to whatever you already use (Slack webhook,
email, PagerDuty, an internal notification ledger, etc) and point
`NOTIFY_CMD` at it. Keep that wrapper OUTSIDE this repo - it is consumer
configuration, not tooling.

## 3. Restic repository setup

Location and credentials are entirely config-driven - see
`config/config.example.conf` for `RCLONE_REMOTE_NAME`, `RESTIC_REPO`, and
`RESTIC_PASSWORD_COMMAND`. Each consuming account should use its own
rclone OAuth, restic password and destination folder - no shared
credentials across accounts/consumers.

Repository initialisation, once the rclone remote exists:

```bash
export RESTIC_PASSWORD_COMMAND="<your command from config.conf>"
restic init -r "<your RESTIC_REPO from config.conf>"
```

After that, `run_backup.sh`'s reachability check will pass and the cron
will start doing real backups on its next scheduled run.

## 4. Installing the cron line

Not installed by this tool - that is deliberately your own account's job
(review your own crontab-safety procedure before editing it). Suggested
line, adjust paths:

```
45 */2 * * * /path/to/backup-tooling/bin/run_backup.sh /path/to/your/config.conf >> /path/to/your/backup.log 2>&1
```

It is safe to install this line immediately, even before your rclone/restic
setup is finished - every run will simply log the NOT CONFIGURED YET line
and exit 0 until the remote and repo both exist.

## 5. What alerts look like

- **Quiet success:** nothing beyond an `OK` line in your log file. No
  notification fires on a normal successful run (avoids alert spam for
  something that may run every 1-2 hours).
- **Not yet configured (expected, pre-setup):** one line per run:
  `NOT CONFIGURED YET - skipping: ...`. No notification fires for this
  state - it is expected until setup completes, not a fault condition.
- **Real failure** (staging step, restic backup, or forget/prune all fail
  non-zero after the repo is live): `NOTIFY_CMD` fires with the failing
  step and the captured stdout/stderr of the failing command in the body,
  and the same detail lands in your log file.
- Check your log file's *content* (not its mtime) to confirm a scheduled
  run actually did something.

## 6. Manual restore procedure (same machine, repo already exists)

```bash
export RESTIC_PASSWORD_COMMAND="<your command from config.conf>"
restic -r "<your RESTIC_REPO>" snapshots                     # list available snapshots
restic -r "<your RESTIC_REPO>" restore latest --target /path/to/scratch-restore   # or a specific snapshot ID
# restored tree lands at /path/to/scratch-restore/<STAGING_DIR path>/...
#   source/<STAGING_DIRS entries>/...   - includes sqlite3 .backup exports for any *.db, safe to copy back directly
#   extra-<label>/...                   - each of your EXTRA_DIRS entries, restored under its label
sqlite3 /path/to/scratch-restore/.../some.db "PRAGMA integrity_check;"
# then copy the specific file(s)/db(s) you need back into your live app - back up the live version FIRST
# before overwriting anything.
rm -rf /path/to/scratch-restore   # clean up the scratch restore once done
```

## 7. Restore on a BRAND NEW machine (disaster recovery)

Use this if the original machine is gone and you're rebuilding from
scratch:

1. **Provision a new machine** with a login user.
2. **Install restic, rclone and sqlite3** (via your distro's package
   manager, or restic's/rclone's own install scripts if you want a newer
   version than your distro ships).
3. **Authorise rclone against the same remote account** (`rclone config`,
   or `rclone authorize` on a machine with a browser if the new machine is
   headless) - see `docs/GDRIVE_OAUTH_SETUP.md` for the Google Drive
   variant of this step. You do not need to redo any one-time cloud
   project/consent-screen setup, only the connection itself.
4. **Get the restic repository password** from wherever you keep your
   break-glass copy (outside this system - vault contents don't survive if
   the whole machine and cloud account access were simultaneously lost).
5. **List and restore:**
   ```bash
   export RESTIC_PASSWORD=<the repo password, entered directly since there's no vault on a fresh box yet>
   restic -r "<your RESTIC_REPO>" snapshots
   restic -r "<your RESTIC_REPO>" restore latest --target /path/to/restore
   ```
6. **Rebuild from the restored tree**, covering whatever you configured in
   `STAGING_DIRS`/`EXTRA_DIRS`. This tool only covers what you told it to
   stage - it does not know about anything else in your infrastructure
   (application installs, other repos, etc); document those separately per
   consumer.
7. Confirm restored databases with `PRAGMA integrity_check` before trusting
   them, exactly as in the drill procedure below.

## 8. Quarterly (or your own cadence) restore drill procedure

Run this periodically to prove the backup chain still works, not just that
it "ran":

```bash
export RESTIC_PASSWORD_COMMAND="<your command from config.conf>"

# 1. Confirm a recent snapshot exists
restic -r "<your RESTIC_REPO>" snapshots --latest 3

# 2. Restore latest to a scratch dir (never restore over the live app)
rm -rf /path/to/tmp-restore-drill
restic -r "<your RESTIC_REPO>" restore latest --target /path/to/tmp-restore-drill

# 3. Integrity-check every restored sqlite db
find /path/to/tmp-restore-drill -name '*.db' -print0 | \
  xargs -0 -I{} sh -c 'echo {}: $(sqlite3 {} "PRAGMA integrity_check;")'

# 4. Diff a sample of restored files against the live originals (expect
#    identical for non-db files; db files are separate .backup exports so
#    compare row counts/content, not raw bytes, against the live db)
diff -rq --exclude='*.db' /path/to/your/backup-staging /path/to/tmp-restore-drill/...

# 5. Time the restore, note the snapshot size and count, record results
#    somewhere durable in your own account's records.

# 6. Clean up
rm -rf /path/to/tmp-restore-drill
```

Record: snapshot ID and date restored from, restore duration, file
count/size, integrity_check results for every restored db, and the diff
result. A drill that silently "looks fine" without these numbers doesn't
count.

## 9. Retention policy (reference defaults)

| Tier    | Default kept | Rationale                                          |
|---------|---------------|-----------------------------------------------------|
| Hourly  | 24            | Covers a roughly one-day intraday window            |
| Daily   | 14            | Two weeks of daily granularity                       |
| Weekly  | 8             | Two months of weekly granularity                      |
| Monthly | 6             | Half a year of monthly granularity                    |

All four are config keys (`RETENTION_HOURLY` etc) - tune per consumer.
`restic forget` (unreference expired snapshots) runs every invocation;
`restic forget --prune` (actually reclaim space) runs only on the
configured `PRUNE_DAY` to keep a frequent cron cheap.

## 10. Consumers

This tool is designed to be cloned/vendored/installed once and pointed at
a different `config.conf` per consuming account, each with its own rclone
OAuth, restic repository and password - no shared credentials across
consumers. See the repo README for the consumers pattern.
