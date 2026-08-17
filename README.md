# Nexus — a local-first, cross-device personal system

Nexus is one app (Android + Debian Linux, built from a single codebase) that
lets your own devices work together directly — no cloud, no account, no
third-party server. Everything happens on your own local network.

So far it can:
- **Pair two devices** by scanning a QR code.
- **Send files** between paired devices with live progress, **encrypted**
  end-to-end (AES-GCM) so no one else on the network can read them.
- **Re-find a paired device** automatically if its local IP address changes
  (e.g. after a router reboot).
- **Take simple commands** in the **Talk to Nexus** tab — create a folder,
  open Wi-Fi settings, or set a reminder — answered with on-device
  text-to-speech.
- **Manage** paired devices and preferences in a **Settings** tab.

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

No cloud, no account, no third-party server is involved at any point — this
matches the "100% local, internet is an opt-in toggle" rule from the spec.

### Talk to Nexus (the offline assistant)

The **Talk** tab accepts simple typed commands and answers aloud using the
device's own text-to-speech engine. Everything runs on-device — nothing is
sent anywhere. Try:

- "create a folder" or "create a folder named Photos"
- "open Wi-Fi settings"
- "remind me to call Sam at 7 pm" or "remind me in 30 minutes"

Reminders appear as a normal notification: on Android they are scheduled
with the OS (so they fire even if the app is closed), while Linux's
notification system has no scheduler, so there Nexus uses an in-app timer
and the app must stay open.

**Why no voice input yet:** the standard Android speech-to-text package
hands your voice to Google's cloud recognizer, which would break the
"nothing leaves your device" rule. Nexus keeps text input for now; a fully
on-device speech engine (like Vosk) can be added later without changing the
rest of the app.

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
- **Allow internet access** and **Auto-update** are both **off by default**,
  and stored on your device only. They don't change anything yet — they're
  ready for features coming in a later phase.
- **Paired devices** lists every device you've paired with; tap the trash icon
  next to one to **forget** it.
- **Received files** shows files other devices have sent you, including where
  each one was saved.

### 9. The Talk tab
- Tap **Talk** in the bottom bar and type a command (see the examples above).
- The first time you set a reminder on Android 13+, allow the notification
  permission when Nexus asks — reminders can't show without it.

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
- **Reminder didn't fire on Linux:** Linux can't schedule notifications while
  the app is closed — keep Nexus open, or set the reminder on Android.
- **No spoken replies on Linux:** make sure a text-to-speech engine is
  installed (for example `sudo apt install speech-dispatcher`). Replies are
  always shown as text regardless.
- **Camera doesn't open on Android:** the app needs camera permission —
  Android should prompt for this automatically the first time; if not,
  enable it manually in Android's Settings -> Apps -> Nexus -> Permissions.
- **`flutter` command not found:** the installer usually needs you to add
  Flutter to your terminal's PATH — the official install guide (step 1
  above) walks through this for your OS.

---

## What's NOT built yet (intentionally)

- A real on-device language model and full voice input (the current assistant
  is a small offline keyword parser — the groundwork is in place to swap in a
  local LLM later).
- Distributed task-splitting across devices
- Sleep-cycle features
- (These come later, once they're designed properly.)

Note: the "Allow internet access" and "Auto-update" toggles in Settings are
stored on-device but don't change behaviour yet — they're placeholders for
features planned in a later phase.
