# vaultsync

Git-based Obsidian vault sync. Replaces Obsidian Sync with plain git.

Your vault stays a folder of Markdown files on disk. vaultsync watches for
changes, auto-commits, and pushes to a private GitHub repo. Every 5 minutes
it pulls with rebase — and if there's a conflict, it **never** overwrites
your notes.

## Quick start

```bash
# 1. Create a private GitHub repo (empty, no README)
#    GitHub → New repository → Private → don't initialize

# 2. Clone or point vaultsync at your vault
cd vaultsync
npm install

# 3. Init your vault
node vaultsync.js init ~/MyVault git@github.com:you/myvault.git

# 4. Start syncing
node vaultsync.js start
```

## Commands

| Command | What it does |
|---------|-------------|
| `vaultsync init <path> [repo-url]` | Git-init the vault, install .gitignore, set remote, initial commit |
| `vaultsync start [path]` | Start watcher + pull loop (runs in foreground) |
| `vaultsync stop` | Kill the running vaultsync process |
| `vaultsync status [path]` | Show last push/pull, uncommitted changes, conflict files |

If you omit `<path>`, vaultsync uses the last vault you ran `init` or `start` on.

## How it works

### Auto-commit (watcher)

vaultsync watches your vault with chokidar. After **30 seconds of no
changes**, it:

1. `git add .`
2. `git commit -m "vaultsync: auto-commit N file(s)"`
3. `git push`

If the push is rejected (diverged history), it does `git pull --rebase`
automatically, then pushes again.

### Pull loop (syncer)

Every **5 minutes** (and once on start), vaultsync runs:

```
git pull --rebase origin <branch>
```

If the rebase succeeds cleanly → done.

If there's a **merge conflict** → vaultsync resolves it safely:
- Your version stays in place (the original file).
- The incoming version is written as `<name>.conflict-YYYY-MM-DD.md`.
  For example, if `meeting-notes.md` conflicts, you get:
  - `meeting-notes.md` — your version (unchanged)
  - `meeting-notes.conflict-2026-08-22.md` — their version
- The conflict is logged to `~/.vaultsync/conflict.log`.
- The rebase is completed so future pulls work.

You review the conflict files manually, merge what you need, then delete
the `.conflict-*` files.

## .gitignore

vaultsync installs a `.gitignore` that excludes:

- `.obsidian/workspace*` — device-local open tabs, scroll positions
- `.obsidian/cache*` — search cache, graph cache
- `.obsidian/plugins/` — install on each machine
- `.obsidian/themes/` — install on each machine
- `.trash/` — Obsidian's trash folder
- `*.conflict-*.md` — conflict files (you decide when to delete them)

This prevents device-local state from ping-ponging between machines.

## Second-machine setup

On your second machine (desktop, laptop, etc.):

```bash
# 1. Clone the vault repo
git clone git@github.com:you/myvault.git ~/MyVault

# 2. Open it in Obsidian
#    Obsidian → Open folder as vault → ~/MyVault

# 3. Install your plugins/themes manually
#    (they're excluded from git on purpose)

# 4. Start vaultsync (optional — you can just pull manually)
cd vaultsync
npm install
node vaultsync.js start ~/MyVault
```

Or skip vaultsync and just `git pull --rebase` manually whenever you want.

## Conflict-file convention

When a pull rebase hits a conflict:

```
original-note.md              ← your version (safe, unchanged)
original-note.conflict-2026-08-22.md  ← their version (from the other machine)
```

Rules:
- **Never delete data.** Both versions survive on disk.
- **Date in filename** so you can have multiple conflict rounds.
- **`.conflict-*` is gitignored** — it won't ping-pong between machines.
- When you've merged the content, delete the `.conflict-*` file.
- Check `~/.vaultsync/conflict.log` for a history of all conflicts.

## Authentication

vaultsync uses your system git credential helper. Options:

- **SSH keys** (recommended): `git@github.com:you/myvault.git`
- **GitHub CLI**: `gh auth login` sets up the credential helper
- **Personal access token**: store in `.env` or use `git credential store`

No accounts beyond GitHub. No telemetry. Notes stay plain Markdown on disk.

## Running as a service (optional)

### systemd (Linux)

```ini
# ~/.config/systemd/user/vaultsync.service
[Unit]
Description=vaultsync — Obsidian vault sync
After=network-online.target

[Service]
ExecStart=/path/to/node /path/to/vaultsync/vaultsync.js start /path/to/vault
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now vaultsync
```

### launchd (macOS)

```xml
<!-- ~/Library/LaunchAgents/com.vaultsync.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vaultsync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>/path/to/vaultsync/vaultsync.js</string>
    <string>start</string>
    <string>/path/to/vault</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.vaultsync.plist
```

## Mobile

Don't use vaultsync on mobile. Use a native git client:

### iOS — Working Copy

1. Install [Working Copy](https://workingcopy.app/) ($9.99 Pro for push).
2. Clone your repo: `git@github.com:you/myvault.git`
3. Enable "External editing" in Working Copy settings.
4. In Obsidian (iOS), install the **Obsidian Git** community plugin or use
   the "Open from Working Copy" integration.

### Android — MGit

1. Install [MGit](https://github.com/michaelhly/mgit) from F-Droid/Play Store.
2. Clone your repo.
3. In Obsidian (Android), point it at the MGit working copy directory.

### Conflict files on mobile

If your phone creates a conflict (edit the same note from two devices), the
conflict file lands in the repo. When you get back to a machine with vaultsync,
it'll be in the vault as `<name>.conflict-<date>.md` — merge and delete.

## Out of scope

- **Encrypted vault workflow** — your repo is private, notes are plain text
- **Version-history UI** — use `git log` and `git diff`
- **End-to-end encryption** — if you need this, look at Obsidian Encrypt or
  aCryptMin before committing
