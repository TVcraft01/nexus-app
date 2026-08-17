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

No cloud, no account, no third-party server is involved at any point — this
matches the "100% local, internet is an opt-in toggle" rule from the spec.

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

### 9. The Talk tab (commands + voice)
- Tap **Talk** in the bottom bar and either type a command or tap the mic and
  speak (see the examples above).
- The first time you use the mic, Nexus downloads the offline speech model
  (~41 MB); on Android also allow microphone permission when asked.
- The first time you set a reminder on Android 13+, allow the notification
  permission when Nexus asks — reminders can't show without it.

### 10. The local AI model (optional, recommended)
- The first time you open Nexus it explains which model fits your device and
  offers to download it (the Compact model is ~941 MB). You can decline and
  stay in command mode, or change tiers later in **Settings -> Local
  assistant**.
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

Note: the "Allow internet access" and "Auto-update" toggles in Settings are
stored on-device but don't change behaviour yet — they're placeholders for
features planned in a later phase.
