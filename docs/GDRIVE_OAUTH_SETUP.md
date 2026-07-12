# Setting up Google Drive for offsite backups (about 15 minutes)

This is a generic walkthrough for connecting `rclone` to a Google Drive
account so this backup tool can copy encrypted snapshots there. Each
consuming account should do this once, with its own Google account - no
sharing credentials across consumers.

You will do two things: a few clicks in a Google account, and getting the
resulting connection detail into the machine that will run the backups.
Two ways to do the second part are given below.

## Why this matters: "Testing" vs "Production"

When you create a Google Cloud project, Google puts it in "Testing" status
by default. In Testing status, the access token that lets a server talk to
the Drive account expires every 7 days, so someone has to manually
reconnect it weekly forever. Switching the project to "Production" status
removes that 7-day expiry, so the connection just keeps working. This is
the single most important step below, and it is easy to miss because
Google does not make it obvious.

Publishing to Production at this small scale does not require Google's
review process or make anything public. It is only visible to the Google
account that owns the project.

## Part 1: Google Cloud project

1. Go to https://console.cloud.google.com/ and sign in with the Google
   account whose Drive you want backups stored in.
2. If you already have a project you are happy to reuse, select it.
   Otherwise click "New Project", give it any name (e.g.
   "offsite-backups"), and create it.
3. In the search bar at the top, search for **"Google Drive API"** and
   open it.
4. Click **"Enable"** (skip this if it already shows as enabled).

## Part 2: OAuth consent screen

1. In the left-hand menu, go to **APIs & Services > OAuth consent
   screen**.
2. Choose **"External"** as the user type (this is normal for a personal
   Google account project) and click Create.
3. Fill in the required fields: an app name (anything descriptive), your
   email address as the support email, and your email address again under
   developer contact information. You can leave the optional fields
   blank.
4. Save and continue through the "Scopes" step without adding anything
   (the defaults are fine).
5. Save and continue through the "Test users" step too.
6. Back on the OAuth consent screen's summary page, find the **Publishing
   status** section and click **"Publish App"**, then confirm. This moves
   it from Testing to Production. This is the step from the "Why this
   matters" section above. Do not skip it.

## Part 3: Create the OAuth client ID

1. Still under **APIs & Services**, go to **Credentials**.
2. Click **"Create Credentials" > "OAuth client ID"**.
3. For **Application type**, choose **"Desktop app"** (this is the correct
   type for rclone, even though the backups typically run on a server, not
   a desktop).
4. Give it any name and click Create.
5. Google will show you a **Client ID** and a **Client Secret**. Keep this
   pop-up open, or copy both values somewhere safe for a minute. Treat the
   Client Secret like a password: do not post it anywhere public, and only
   share it over channels you already trust with credentials.

You now have everything Google-side. The rest happens on the machine that
will run the backups, and there are two ways to finish it.

## Part 4: Connect the backup machine to the Drive account

### Option A: run the `rclone config` walkthrough directly on the machine

If the machine has a browser available (or you're at its console), run
`rclone config` and answer its prompts like this:

```
n) New remote
name> <pick a remote name, e.g. mybackups - matches RCLONE_REMOTE_NAME in your config.conf>
Storage> drive          (Google Drive)
client_id>  <paste the Client ID from Part 3>
client_secret> <paste the Client Secret from Part 3>
scope> 1                (Full access to all files)
root_folder_id> <leave blank>
service_account_file> <leave blank>
Edit advanced config?> n
Use auto config?> depends: if the machine has no browser access (normal for a
                  headless server), rclone gives you a link to open on ANY
                  machine with a browser, followed by a short code to paste
                  back into the terminal. Open that link, sign in with the
                  same Google account, approve access, and paste the code
                  back.
```

### Option B: authorise on a separate machine with a browser, then paste the result in

If you would rather not run the config walkthrough on the backup machine
itself:

1. Install rclone on any machine with a browser
   (https://rclone.org/downloads/).
2. Open a terminal and run:
   ```
   rclone authorize "drive" "<Client ID from Part 3>" "<Client Secret from Part 3>"
   ```
3. A browser window opens. Sign in with the same Google account, approve
   access.
4. The terminal prints a block of text starting with something like
   `{"access_token":"...","token_type":"Bearer",...}`. Copy that whole
   block.
5. On the backup machine, run `rclone config`, choose the same remote
   name/type/client ID/client secret as above, and when prompted for
   "Use auto config?", answer no and paste the token block when asked -
   the remote is then live with no further browser step needed on the
   backup machine itself.

Either way, once this is done the remote name you chose (matching
`RCLONE_REMOTE_NAME` in your `config.conf`) is ready to use.

## What happens after setup

Once the rclone remote exists:

1. Initialise the encrypted backup repository (see
   `docs/BACKUP_RUNBOOK.md` section 3).
2. Run a first real backup and confirm it lands in the repo.
3. Run a full restore drill (`docs/BACKUP_RUNBOOK.md` section 8),
   restoring to a scratch folder and checking every database comes back
   intact, so you have proof the whole chain works before relying on it.
4. Install the scheduled cron line (`docs/BACKUP_RUNBOOK.md` section 4).

After that the backup runs unattended on its configured schedule.
