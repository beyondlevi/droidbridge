# DroidBridge wire protocol (version 1)

The Mac app starts the server on the device over adb and connects to it through
`adb forward tcp:<port> localabstract:droidbridge`. Every message, in both
directions, is:

| Field | Size |
|---|---|
| type | u8 |
| payload length | u32, big-endian |
| payload | length bytes |

All integers are big-endian. `side` is a side of the Android screen:
0 left, 1 right, 2 top, 3 bottom. `ratio` is a position along that edge,
0 at the top/left end and 65535 at the other.

## Mac to Android

| Type | Name | Payload |
|---|---|---|
| 0x01 | HELLO | u16 protocol version |
| 0x02 | ENTER | u8 side, u16 ratio: put the pointer on this edge; then u8 n and n × (u8 side, u16 start, u16 end): the stretches of the device edges that lead back to the Mac (without them: the whole entry side) |
| 0x03 | LEAVE | empty: release keys and buttons, stop watching the edge |
| 0x04 | MOUSE | u8 buttons (bit 0 left, 1 right, 2 middle, 3 back, 4 forward), i16 dx, i16 dy, i8 wheel, i8 horizontal wheel |
| 0x05 | KEYS | 8-byte HID boot keyboard report (modifiers, reserved, 6 usages) |
| 0x06 | CLIPBOARD | UTF-8 text to put on the device clipboard |
| 0x07 | PING | empty |
| 0x08 | LAYOUT | UTF-8 Android keyboard layout name, e.g. `english_us_intl` (Android 15+) |

## Android to Mac

| Type | Name | Payload |
|---|---|---|
| 0x81 | DEVICE | u16 protocol version, u16 width, u16 height, UTF-8 model; sent first |
| 0x82 | EDGE | u8 side, u16 ratio: the pointer was pushed out through a return stretch |
| 0x83 | CLIPBOARD | UTF-8 text copied on the device |
| 0x84 | PONG | empty |
