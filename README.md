# Nexus — QR Pairing Module (Phase 1, Feature 1)

This is a working first piece of Nexus: two devices (Android + Debian Linux,
built from one shared codebase) can pair with each other by scanning a QR
code, entirely over the local network — no server, no internet required.

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

No cloud, no account, no third-party server is involved at any point — this
matches the "100% local, internet is an opt-in toggle" rule from the spec.

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

---

## If something goes wrong

- **"Could not pair" message:** almost always means the two devices aren't
  on the same Wi-Fi network, or a firewall is blocking port `51820`. On
  Debian, you may need to allow it: `sudo ufw allow 51820/tcp`.
- **Camera doesn't open on Android:** the app needs camera permission —
  Android should prompt for this automatically the first time; if not,
  enable it manually in Android's Settings -> Apps -> Nexus -> Permissions.
- **`flutter` command not found:** the installer usually needs you to add
  Flutter to your terminal's PATH — the official install guide (step 1
  above) walks through this for your OS.

---

## What's NOT built yet (intentionally — this is one feature at a time)

- File transfer between paired devices
- The Settings tab / internet toggle
- The local AI
- Everything else in Phases 2–4 of the spec

Next feature to build, whenever you're ready: **LAN file transfer between
paired devices** — sending a file from one device to another using the
pairing connection we just built.
