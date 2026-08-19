# Nexus — a local-first, cross-device personal system

Nexus is one app (Android + Debian Linux, built from a single codebase) that
lets your own devices work together directly — no cloud, no account, no
third-party server. Everything happens on your own local network by default;
you can optionally turn on **remote access** to reach your own devices over
the internet, still direct device-to-device.

So far it can:
- **Pair two devices** by scanning a QR code.
- **Send files** between paired devices with live progress, **encrypted**
  end-to-end (AES-GCM) so no one else on the network can read them.
- **Reach a paired device on another network** (optional, direct P2P — no
  relay), when the "Allow internet access" toggle is on.
- **Re-find a paired device** automatically if its local IP address changes
  (e.g. after a router reboot).
- **Run a private local AI** that is downloaded once and then runs entirely
  on the device (no API key, no cloud).
- **Understand spoken or typed commands** in the **Talk to Nexus** tab —
  create a folder, open Wi-Fi settings, or set a reminder — using fully
  on-device speech recognition (Vosk) and text-to-speech.
- **Manage** paired devices, the AI model, and preferences in a **Settings**
  tab.

---

## How it works (architecture)

1. **Device A** taps "Show my QR code." Nexus generates a random one-time
   pairing key, starts a tiny local web server on port `51820`, and displays
   a QR code containing: Device A's ID, name, local IP address, port, and
   that pairing key.
2. **Device B** taps "Scan a QR code" and scans it with the camera.
3. Device B sends a direct message over the local network straight to
   Device A's IP/port, echoing back the pairing key as proof it actually
   scanned that specific QR code (not a guess).
4. Device A checks the key matches, saves Device B as a paired device, and
   replies with its own info so Device B saves Device A too.
5. Both devices now have each other stored locally (on-device storage only)
   as a paired device, ready for future features (file transfer, task
   splitting, etc.) to use.

### File transfer (sending a file to a paired device)

1. Every device keeps a small local web server open on port `51821` while
   Nexus is running, ready to receive files.
2. When you tap a paired device and pick a file, Nexus streams the file
   straight to that device's IP/port over your Wi-Fi — the bytes never leave
   your local network.
3. The receiving device checks that the sender knows the secret pairing key
   (so strangers on your network can't drop files on you), then decrypts the
   file and saves it to a `Nexus` folder, showing a "File received" message.
4. File contents are encrypted with AES-GCM using a key derived from that
   pairing secret (via HKDF), so even someone who can watch your Wi-Fi
   traffic can't read what you're sending. Tampered or truncated transfers
   are detected and rejected.
5. If a paired device's IP address has changed, Nexus first checks whether
   the old address still answers; if not, it scans your local network for
   that device and updates its address automatically before sending.
6. Progress is shown live on the sending device.
7. Every transfer (sent or received) is logged to the **Files** tab — the
   file name, direction, other device, size, and timestamp — stored on-device
   in SharedPreferences (most recent first). Tapping an entry opens the file
   with your platform's default app (or reveals its folder).

No cloud, no account, no third-party server is involved at any point — this
matches the "100% local, internet is an opt-in toggle" rule from the spec.

### Remote access (reach a device on another network)

The "Allow internet access" toggle in Settings is **off by default**, and when
off Nexus is fully LAN-only (exactly as before). Turning it on enables direct
remote connections between paired devices, with **no relay server and no
third-party server ever handling your files, commands, or messages**:

1. Each device discovers its **public IP address** using Google's public STUN
   server (`stun.l.google.com:19302`). STUN sees only bare connection
   metadata — the public IP and a port number — **never** file contents,
   commands, or any other user data.
2. Each device then asks its router to forward its local receive port using
   **UPnP IGD** or **NAT-PMP**, giving it a reachable public `ip:port`.
3. That public endpoint is shared with a paired device the next time the two
   connect (piggybacked on an existing transfer), so they can reach each
   other later.
4. When you send a file, Nexus always tries the **local network first**, then
   the stored public endpoint — the LAN path is never skipped.

Known limitation: this works on common home routers that expose UPnP/NAT-PMP
(or a cone NAT), but **symmetric NAT and routers with UPnP disabled** can't be
reached this way. When that happens Nexus says "Can't reach … remotely right
now — you'll need to be on the same network" rather than hanging. There is **no
relay fallback yet** (a relay would have to be your own self-hosted server — a
separate future decision).

### Remote dev tasks (the dev bridge)

Nexus can hand a text prompt from your **phone** to a **paired PC** over the
same encrypted channel as file transfer, have the PC run a coding task, and
send the **report + any build artifact (e.g. the APK)** back to the phone —
still encrypted, still direct device-to-device.

Safety model (this is the most powerful feature in the app — it can run code
on the PC):

- **"Allow remote dev tasks" is OFF by default** and separate from "Allow
  internet access". Turning it on requires an explicit confirmation dialog.
  Requests are rejected with a clear message while it's off.
- Only **already-paired devices** can submit tasks — the prompt travels
  AES-GCM-encrypted with the pairing-key-derived key, exactly like file
  transfer, and the request is authenticated by the pairing secret.
- **One task at a time.** A second request while one is running is rejected
  with a clear message (no queueing).
- The prompt is fed to a **user-configured command** (editable in Settings ->
  Developer bridge), never executed directly. A task that runs longer than
  **30 minutes** is killed.
- Port forwarding / reachability follows the same rules as remote access
  (see above): LAN first, then the opt-in remote path. The artifact is sent
  back over the *existing* encrypted `/receive` file-transfer path.

**The Freebuff limitation (why the command is configurable):** Freebuff's CLI
(currently) has **no clean non-interactive mode**. Its `--help` exposes only
`login`, `--continue`, and `--cwd`; piping a prompt via stdin is ignored (the
binary opens its interactive TUI, falling back to `/dev/tty` when stdin isn't a
TTY); and there is no `-p`/`--prompt`/`--batch`/`--headless` flag. So Nexus
won't scrape a live terminal session — instead the dev bridge runs whatever
command you configure, which is exactly where a future headless Freebuff (or
any other agent CLI) plugs in.

To set it up on the PC: open **Settings -> Developer bridge**, turn on
"Allow remote dev tasks", set the **working directory** to the repo path, and
set the **task command**, e.g.:

```sh
bash /home/you/nexus-app/devtask.sh "{prompt}"
```

`{prompt}` is replaced with the prompt text (quote it yourself) and
`{promptFile}` with the path of a file containing the prompt (prefer this to
avoid shell-quoting issues). A minimal `devtask.sh` that writes the prompt to
a file for a headless agent to pick up:

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"
cp "$2" /tmp/nexus_pending_prompt.txt 2>/dev/null || printf '%s' "$1" > /tmp/nexus_pending_prompt.txt
# Invoke your agent headlessly here (once Freebuff supports it):
#   freebuff --cwd "$PWD" --run "$1"
echo "Prompt received and staged for the dev task."
```

(Adjust paths; the default command is a harmless placeholder that explains
this.) When the task finishes, Nexus looks for a build artifact under
`build/` (newest APK, or the Linux release bundle packed into a `.tar.gz`)
and pushes it to your phone, where the Remote dev task screen shows a
"Open / Install" button.

### Talk to Nexus (the offline assistant)

The **Talk** tab accepts typed or **spoken** commands and answers aloud using
the device's own text-to-speech engine. Everything runs on-device — no audio
and no text ever leaves your device. Try:

- "create a folder" or "create a folder named Photos"
- "open Wi-Fi settings"
- "remind me to call Sam at 7 pm" or "remind me in 30 minutes"

Voice input uses **Vosk**, a free, fully-offline speech recognizer. The first
time you tap the mic, Nexus downloads a small English model (~41 MB) from
vosk's official site and stores it locally — after that it never talks to the
network again. On Android you'll be asked for microphone permission; on Linux,
capturing the microphone needs `pulseaudio-utils` installed (see the notes
below).

Reminders appear as a normal notification: on Android they are scheduled
with the OS (so they fire even if the app is closed), while Linux's
notification system has no scheduler, so there Nexus uses an in-app timer
and the app must stay open.

### The local AI model (adaptive tiers)

On first run Nexus measures your device and offers the largest model it can
comfortably run — it never forces a one-size-fits-all choice:

| Tier | Model | Download | Needs (free RAM) |
| --- | --- | --- | --- |
| Compact | Qwen2.5 1.5B (quantized) | ~941 MB | ~3 GB |
| Balanced | Qwen2.5 3B (quantized) | ~1.8 GB | ~4 GB |
| Large | Qwen2.5 7B (quantized) | ~4.4 GB | ~7 GB |

- Models are open-weight (Apache-2.0), downloaded once from Hugging Face
  (the `bartowski` community conversions), and stored in the app's private
  storage — they are fetched only once and never re-downloaded.
- You can **pick a different tier** or **delete the model** at any time in
  **Settings -> Local assistant**.
- If the model can't be loaded (or your device is too small for even the
  Compact tier), Nexus automatically falls back to its built-in keyword
  command mode, which works on any hardware.
- Model downloads are the only network access Nexus uses, and it is download
  only: your conversations are never sent anywhere.

---

## Get the Android app from your phone (no computer needed)

Every push to `main` is built and tested automatically by GitHub Actions, so
you can download a fresh APK straight from your phone's browser without a PC:

1. Open the repository on GitHub and tap the **Actions** tab (this works fine
   in a phone browser).
2. Open the most recent workflow run — wait for it to show a green check,
   which means `flutter analyze`, the tests, and the build all passed.
3. Scroll to the **Artifacts** section and tap **nexus-app-debug-apk** to
   download it. Artifacts download as a `.zip` containing the `.apk`.
4. Open the zip (your phone's file manager can do this, or any free zip app),
   then tap `app-debug.apk` inside it.
5. Android asks you to allow installing apps from that source the first time —
   confirm, then tap **Install**.

The same run also uploads a **nexus-app-linux** bundle you can download the
same way on a computer.

---

## What you need before running this (one-time setup)

Since I can't install anything on your physical devices remotely, here's
exactly what to do, step by step. This only needs to be done once.

### 1. Install Flutter (the toolkit this app is built with)
- Go to **docs.flutter.dev/get-started/install** and pick your operating
  system.
- Follow their installer — it also installs Dart automatically.
- This is free and made by Google; it's how one codebase produces both the
  Android app and the Debian Linux app.

### 2. Get this project onto your computer
- Copy the whole `nexus_app` folder (everything I built) onto your Debian
  machine.

### 3. Open a terminal in the `nexus_app` folder and run:
```
flutter pub get
```
This downloads the small number of free libraries the app depends on (QR
generation, QR scanning, local networking, local storage).

### 4. Run it on Debian Linux:
```
flutter config --enable-linux-desktop
flutter run -d linux
```

### 5. Run it on Android:
- Plug your Android phone in with a USB cable, or start an Android
  emulator.
- Enable "Developer Options" -> "USB debugging" on the phone (search that
  exact phrase + your phone model if you're unsure how — it's a standard
  Android setting, not a Nexus-specific step).
- In the terminal:
```
flutter run -d android
```

### 6. Test the pairing
- With the app open on both devices (same Wi-Fi network), on one device tap
  **+ -> Show my QR code**, and on the other tap **+ -> Scan a QR code**.
- Point the camera at the first screen. You should see "Paired with..." on
  both devices within a couple seconds.

### 7. Send a file
- Make sure Nexus is open on both devices and they are paired.
- On the sending device, tap the paired device in the list, then tap the
  file card to choose a file, and tap **Send file**.
- You'll see a progress bar while it transfers, and the other device shows a
  "File received" message when it's done.
- Received files are saved in a `Nexus` folder — on Linux that's inside your
  Downloads folder; on Android it's the app's own storage (see **Settings ->
  Received files** for the exact location).

### 8. The Settings tab
- Tap **Settings** at the bottom of the app.
- **Allow internet access** is **off by default** (LAN only). Turn it on to
  enable remote access (see "Remote access" above). **Auto-update** is still
  a reserved placeholder.
- The **Remote access** section shows, per paired device, whether it was last
  reached over the **Local network**, **Remote (direct)**, or is currently
  **Unreachable** — plus this device's own public endpoint when one is open.
- **Paired devices** lists every device you've paired with; tap the trash icon
  next to one to **forget** it.
- **Received files** shows files other devices have sent you, including where
  each one was saved.

### 9. The Talk tab (commands + voice)
- Tap **Talk** in the bottom bar and either type a command or tap the mic and
  speak (see the examples above).
- The **?** icon in the top-right opens "What can I say?" — the list of
  commands Nexus currently understands, with the exact phrasings the offline
  keyword parser matches on.
- The first time you use the mic, Nexus downloads the offline speech model
  (~41 MB); on Android also allow microphone permission when asked.
- The first time you set a reminder on Android 13+, allow the notification
  permission when Nexus asks — reminders can't show without it.

### 10. The local AI model (optional, recommended)
- The first time you open Nexus it explains which model fits your device and
  offers to download it (the Compact model is ~941 MB). You can decline and
  stay in command mode, or change tiers later in **Settings -> Local
  assistant**.
- **"Not now" snoozes the prompt for a few days** — Nexus won't re-ask on
  every launch, but you can still set up a model at any time from
  **Settings -> Local assistant** (the manual path ignores the snooze).
- The download shows progress and can be cancelled. It needs free disk space
  of about 1.5x the model size.
- Linux desktops often have the most free memory, so they may be offered the
  Balanced or Large tier; phones typically get the Compact tier.

---

## If something goes wrong

- **"Could not pair" message:** almost always means the two devices aren't
  on the same Wi-Fi network, or a firewall is blocking ports `51820` (QR
  pairing) and `51821` (file transfer). On Debian, you may need to allow
  them: `sudo ufw allow 51820/tcp && sudo ufw allow 51821/tcp`.
- **File won't send:** make sure both devices are on the same Wi-Fi and Nexus
  is open on the receiving device. If a device's IP changed, Nexus re-finds
  it automatically; if that fails you'll see "Couldn't reach … — try
  re-pairing", in which case pair the two devices again.
- **Can't reach a device remotely:** both devices need "Allow internet access"
  on and to have connected once before (so they learned each other's public
  address). Some routers (symmetric NAT, or UPnP disabled) don't support
  direct remote connections — there's no relay fallback yet, so those devices
  stay LAN-only.
- **Reminder didn't fire on Linux:** Linux can't schedule notifications while
  the app is closed — keep Nexus open, or set the reminder on Android.
- **No spoken replies on Linux:** make sure a text-to-speech engine is
  installed (for example `sudo apt install speech-dispatcher`). Replies are
  always shown as text regardless.
- **Mic does nothing / errors on Linux:** voice capture uses `parecord`, which
  comes with PulseAudio. Install it with `sudo apt install pulseaudio-utils`
  (most Debian desktops already have it).
- **Model download fails:** Nexus needs a working internet connection for the
  one-time download and enough free disk space (about 1.5x the model size).
  You can retry or pick a smaller tier in **Settings -> Local assistant**.
- **Camera doesn't open on Android:** the app needs camera permission —
  Android should prompt for this automatically the first time; if not,
  enable it manually in Android's Settings -> Apps -> Nexus -> Permissions.
- **`flutter` command not found:** the installer usually needs you to add
  Flutter to your terminal's PATH — the official install guide (step 1
  above) walks through this for your OS.

---

## What's NOT built yet (intentionally)

- Distributed task-splitting across devices
- Sleep-cycle features
- A larger, even-smarter local model (the current tiers go up to 7B; bigger
  models or GPU-accelerated inference can be added later)
- (These come later, once they're designed properly.)

Note: the "Auto-update" toggle in Settings is stored on-device but doesn't
change behaviour yet — it's a placeholder for a feature planned in a later
phase.
