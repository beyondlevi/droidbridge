<p align="center"><img src="assets/logo.png" alt="DroidBridge" width="480"></p>

# DroidBridge

Use your Mac's mouse and keyboard on an Android phone or tablet. Push the pointer past the edge
of your Mac's screen and it shows up on the Android device; push it back and you're on the Mac.
The text clipboard is shared both ways. An open-source take on DeskDock, for macOS.

- Real Android pointer and keyboard: the device sees a USB mouse and keyboard (UHID).
- Nothing to install on the device: the Mac starts a small server over adb.
- Text clipboard sync in both directions.
- Works with several displays: arrange the device against one or two of them, as in System
  Settings > Displays; only the stretches it touches lead to it.
- Follows the device when it turns, and foldables when they switch screens (e.g. a Galaxy Z Fold
  closed, on its cover screen).
- Several Android devices on adb: pick the one to use in the menu.
- English and Brazilian Portuguese.

Status: early (0.2). USB only for now; Wi-Fi and file drag-and-drop are planned.

## Requirements

- macOS 13 or later.
- Android 8.1 or later with **USB debugging** on (Settings > About phone > tap Build number 7 times,
  then Settings > Developer options > USB debugging).
- `adb` (Android platform-tools): `brew install android-platform-tools`.

## Use

1. Connect the device by USB and accept the debugging prompt on it.
2. Open DroidBridge. It lives in the menu bar.
3. Allow it in System Settings > Privacy & Security > Accessibility.
4. In the menu, open **Arrange Screens…** and drag the Android device against the edge of a display.
   The pointer passes only through the highlighted stretch; the size slider makes it longer or shorter.
5. Push the pointer through that stretch.

Back to the Mac: push the pointer against the device edge facing the Mac, or press **⌃⌥⌘B**.

By default Command acts as Ctrl on Android, so ⌘C / ⌘V / ⌘A work as expected (Control becomes Meta).
Turn it off in the menu to keep Command as Meta.

The Android keyboard layout follows the Mac's (for example US International - PC becomes
"English (US), International style"), so dead keys and accents type the same. This needs Android 15 or later.

## Build

```sh
# Android server (needs ANDROID_HOME with platforms/android-36 and build-tools/36.0.0, JDK 17+)
server/build.sh
# Mac app (Xcode 15+), tests, and the .app bundle in mac/dist/
cd mac && swift test && scripts/build-app.sh
```

Ad-hoc signed builds lose the Accessibility permission each time they are rebuilt.
`mac/scripts/create-signing-identity.sh` creates a local signing identity that keeps it.

`tools/devtest.py` drives the server on a connected device without the Mac app.

## How it works

See [docs/architecture.md](docs/architecture.md) and the [wire protocol](protocol/README.md).

## License

Apache License 2.0. Includes the scrcpy server sources (Apache 2.0), see [NOTICE](NOTICE).
