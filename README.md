# offsite-backup

A small, account-agnostic offsite backup tool: stages a consistent
point-in-time copy of a set of directories (safely exporting live sqlite
databases rather than copying them), then pushes it to a remote via
[restic](https://restic.net/) over [rclone](https://rclone.org/) (Google
Drive by default, anything rclone supports in practice), with a configurable
retention policy and a pluggable failure-notification hook.

It was split out of a single account's ops workspace so the backup
mechanism itself could be developed once and reused, unmodified, by every
account that needs the same restic+rclone pattern - each with its own
config, its own cloud OAuth, and its own restic repository. No credentials
or account-specific detail live in this repo; all of that lives in a
`config.conf` you keep outside the repo.

## Quickstart

1. Clone this repo (or vendor it into your own tooling however you like).
2. Copy `config/config.example.conf` to a `config.conf` of your own,
   outside this repo (e.g. alongside your app's other private config), and
   fill in your paths, rclone remote name, restic repo path, retention and
   notifier.
3. Set up rclone against your remote (`docs/GDRIVE_OAUTH_SETUP.md` walks
   through the Google Drive case; any other rclone-supported remote works
   the same way from the `RCLONE_REMOTE_NAME`/`RESTIC_REPO` config keys
   onward).
4. Initialise the restic repository once setup is done (see
   `docs/BACKUP_RUNBOOK.md` section 3).
5. Test staging on its own first:
   ```bash
   bin/backup_staging.sh /path/to/your/config.conf
   ```
   This is safe to run repeatedly - it only writes to your configured
   `STAGING_DIR`, wiping and rebuilding it each time, and touches nothing
   remote.
6. Once staging looks right and the restic repo exists, wire up the cron
   entrypoint:
   ```bash
   bin/run_backup.sh /path/to/your/config.conf
   ```
   Add it to your crontab on whatever schedule suits you (a suggested line
   is in `docs/BACKUP_RUNBOOK.md` section 4). Before the rclone remote and
   restic repo both exist, `run_backup.sh` just logs a
   `NOT CONFIGURED YET` line and exits 0, so it is safe to install the cron
   line ahead of finishing setup.

## Layout

```
bin/
  backup_staging.sh   # stages a point-in-time copy under STAGING_DIR
  run_backup.sh        # cron entrypoint: staging + restic backup + retention
config/
  config.example.conf  # documented template - copy it, don't edit it in place
docs/
  BACKUP_RUNBOOK.md         # mechanism, config keys, restore/DR procedures
  GDRIVE_OAUTH_SETUP.md     # walkthrough for the Google Drive rclone remote
```

## Config reference

See `config/config.example.conf` for the full, commented list of keys.
Summary:

| Key | What it controls |
|---|---|
| `SOURCE_ROOT`, `STAGING_DIRS` | What gets staged from your app's own tree |
| `EXTRA_DIRS` | Extra paths outside `SOURCE_ROOT` staged verbatim (e.g. a secrets vault, a bare git repo) |
| `EXTRA_RSYNC_EXCLUDES` | Extra rsync exclude patterns on top of the built-in defaults |
| `STAGING_DIR` | Where the staging tree is rebuilt each run |
| `RCLONE_REMOTE_NAME`, `RESTIC_REPO` | Where the backup goes |
| `RESTIC_PASSWORD_COMMAND` | Command that prints the restic repo password at runtime - never a plain value in the config |
| `RESTIC_TAG` | Tag applied to each snapshot |
| `RETENTION_HOURLY/DAILY/WEEKLY/MONTHLY`, `PRUNE_DAY` | Retention policy |
| `NOTIFY_CMD` | Path to a script invoked as `"$NOTIFY_CMD" "<title>" "<body>" "<priority>"` on failure; blank = log-only, no-op |

## Notifications

This tool has no built-in notification channel by design - every consuming
account already has its own (Discord, Slack, email, a paging system,
nothing at all). `run_backup.sh` calls whatever `NOTIFY_CMD` points to on
any failure and otherwise stays out of the way. Write a thin wrapper script
in your own app/account that speaks to your existing notification path and
point the config at it. Keep that wrapper out of this repo - it is
consumer configuration, not tooling, and it is the one place that is
allowed to know about your account's internals.

## The consumers pattern

This tool is meant to be used by more than one account without any of them
sharing credentials or coupling to each other:

- Each consumer keeps its own `config.conf` (outside this repo) with its
  own paths, its own rclone remote/OAuth, its own restic repository and
  password, and its own retention policy.
- Each consumer supplies its own `NOTIFY_CMD` wrapper if it wants failure
  alerts routed anywhere beyond the log file.
- This repo stays generic: no account names, hostnames, remote names or
  paths belonging to any specific consumer, only placeholders and neutral
  examples.

## Licence

Not yet set - ask before redistributing.
