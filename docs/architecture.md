# How DroidBridge works

## The device side

There is no app to install on the phone. The Mac pushes `droidbridge-server.jar` to
`/data/local/tmp` and runs it with `app_process` as the adb shell user, like scrcpy does.
The shell user may create input devices through `/dev/uhid` (Android 8.1 and later), so the
server registers a real USB-HID mouse and keyboard. Android then draws its own pointer,
accelerates it with its own settings, and treats keys exactly like a physical keyboard
(all characters, the IME, the hardware keyboard layout).

The shell user can also read and write the clipboard in the background, which apps can't do
since Android 10.

## Coming back to the Mac

The mouse is relative and Android accelerates it, so the Mac can't compute where the pointer
is. The shell user can't monitor input events, and the system's cursor-position API is internal
to `system_server`. What the shell user can do is ask the input service for a dump: it lists each
device's hovering pointer in display coordinates, e.g.
`DeviceId(15):[... hoveringPointers=[Pointer(id=0, MOUSE) at (0, 1835.57)]]`. Those
coordinates are the display's unrotated (physical) ones, while the frame next to them is the rotated
one, so the server turns them using the display orientation from the same dump. A dump takes
about 20 ms on a recent phone, so the server only takes one (at most every 30 ms) while the pointer
moves toward the edge that leads back to the Mac. Once the pointer touches that edge and keeps
being pushed against it, the server tells the Mac, with the position along the edge.

Measured on a Galaxy Z Fold (Android 17), 2026-10-07:

- UHID relative mouse: real pointer, class `CURSOR`.
- UHID absolute (X/Y) mouse: Android ignores the device. Not usable.
- Injected events (`InputManager.injectInputEvent`, as scrcpy's "SDK" mouse): exact position but
  no pointer is drawn.

## Entering the device

When the Mac cursor is pushed out of a free screen edge, the Mac freezes its cursor
(`CGAssociateMouseAndMouseCursorPosition(false)`), hides it and sends `ENTER` with the position
along the edge. The server pushes the pointer into the corner of the entry edge, then walks it along
the edge, measuring with the dump, until it is within about 12 px of the matching position
(0.1-0.2 s; the pixels-per-count gain of each axis is learned on earlier entries). When the
screen turns or a foldable switches screens, the server sends the new size again and the Mac
reshapes the device in its arrangement, keeping the sides that touch displays. From then on the Mac forwards raw mouse deltas (times the speed setting), buttons,
scrolling and keys, and swallows them locally through a `CGEventTap`.

## The Mac side

A menu-bar app (Swift, no Xcode project: Swift Package Manager plus `mac/scripts/build-app.sh`).

- `DroidBridgeCore`: wire protocol, screen-edge geometry (multiple displays: only edges that don't
  lead to another display count), macOS key code to HID usage table. Unit-tested.
- `DroidBridge`: event tap, cursor hiding, adb link with reconnection, clipboard polling, menu.

Permissions: Accessibility (to swallow events). Hiding the cursor from a background app is not
possible on recent macOS, so the app comes to the front while the pointer is on the device and gives
the focus back to the previous app on return.
