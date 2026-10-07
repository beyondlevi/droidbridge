package dev.droidbridge;

/**
 * Wire protocol between the Mac app and this server (see protocol/README.md).
 * Every message is: u8 type, u32 payload length (big-endian), payload.
 */
public final class Protocol {
    public static final int VERSION = 1;

    // Mac -> Android
    public static final int HELLO = 0x01;      // u16 protocol version
    public static final int ENTER = 0x02;      // u8 side, u16 ratio, u8 n, n x {u8 side, u16 start, u16 end}
    public static final int LEAVE = 0x03;      // empty
    public static final int MOUSE = 0x04;      // u8 buttons, i16 dx, i16 dy, i8 wheel, i8 hwheel
    public static final int KEYS = 0x05;       // 8-byte HID boot keyboard report
    public static final int CLIPBOARD = 0x06;  // utf-8 text
    public static final int PING = 0x07;       // empty
    public static final int LAYOUT = 0x08;     // utf-8 Android keyboard layout name, e.g. "english_us_intl"

    // Android -> Mac
    public static final int DEVICE = 0x81;     // u16 protocol version, u16 width, u16 height, utf-8 model
    public static final int EDGE = 0x82;       // u8 side, u16 ratio along the edge
    public static final int DEVICE_CLIPBOARD = 0x83; // utf-8 text
    public static final int PONG = 0x84;       // empty

    // Sides of the Android screen
    public static final int SIDE_NONE = -1;
    public static final int SIDE_LEFT = 0;
    public static final int SIDE_RIGHT = 1;
    public static final int SIDE_TOP = 2;
    public static final int SIDE_BOTTOM = 3;

    public static final int MAX_PAYLOAD = 1 << 20;

    private Protocol() {
    }
}
