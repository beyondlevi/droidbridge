package dev.droidbridge;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import java.io.FileDescriptor;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/** A virtual HID device backed by /dev/uhid (Linux Documentation/hid/uhid.rst). */
final class Uhid {
    private static final int UHID_CREATE2 = 11;
    private static final int UHID_INPUT2 = 12;
    private static final short BUS_VIRTUAL = 0x06;

    static final byte[] MOUSE_DESCRIPTOR = {
        0x05, 0x01, 0x09, 0x02, (byte) 0xA1, 0x01, 0x09, 0x01, (byte) 0xA1, 0x00,
        // 5 buttons
        0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, (byte) 0x95, 0x05, 0x75, 0x01, (byte) 0x81, 0x02,
        (byte) 0x95, 0x01, 0x75, 0x03, (byte) 0x81, 0x01,
        // X, Y, wheel: relative, -127..127
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, (byte) 0x81, 0x25, 0x7F, 0x75, 0x08, (byte) 0x95, 0x03,
        (byte) 0x81, 0x06,
        // AC Pan (horizontal wheel)
        0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, (byte) 0x81, 0x25, 0x7F, 0x75, 0x08, (byte) 0x95, 0x01, (byte) 0x81, 0x06,
        (byte) 0xC0, (byte) 0xC0,
    };

    static final byte[] KEYBOARD_DESCRIPTOR = {
        0x05, 0x01, 0x09, 0x06, (byte) 0xA1, 0x01,
        // modifiers
        0x05, 0x07, 0x19, (byte) 0xE0, 0x29, (byte) 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, (byte) 0x95, 0x08,
        (byte) 0x81, 0x02,
        // reserved byte
        0x75, 0x08, (byte) 0x95, 0x01, (byte) 0x81, 0x01,
        // LEDs (output, ignored)
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x75, 0x01, (byte) 0x95, 0x05, (byte) 0x91, 0x02, 0x75, 0x03, (byte) 0x95,
        0x01, (byte) 0x91, 0x01,
        // 6 keys
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, (byte) 0x95, 0x06, (byte) 0x81, 0x00,
        (byte) 0xC0,
    };

    private final FileDescriptor fd;

    Uhid(String name, int vendorId, int productId, byte[] descriptor) throws IOException {
        try {
            fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0);
            byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
            ByteBuffer buf = ByteBuffer.allocate(280 + descriptor.length).order(ByteOrder.nativeOrder());
            buf.putInt(UHID_CREATE2);
            buf.put(nameBytes, 0, Math.min(nameBytes.length, 127));
            buf.position(4 + 256);
            buf.putShort((short) descriptor.length);
            buf.putShort(BUS_VIRTUAL);
            buf.putInt(vendorId);
            buf.putInt(productId);
            buf.putInt(0); // version
            buf.putInt(0); // country
            buf.put(descriptor);
            write(buf.array());
        } catch (ErrnoException e) {
            throw new IOException("cannot open /dev/uhid", e);
        }
    }

    void input(byte[] report) throws IOException {
        ByteBuffer buf = ByteBuffer.allocate(6 + report.length).order(ByteOrder.nativeOrder());
        buf.putInt(UHID_INPUT2);
        buf.putShort((short) report.length);
        buf.put(report);
        write(buf.array());
    }

    private void write(byte[] data) throws IOException {
        try {
            Os.write(fd, data, 0, data.length);
        } catch (ErrnoException e) {
            throw new IOException(e);
        }
    }

    /** Closing the fd destroys the device. */
    void close() {
        try {
            Os.close(fd);
        } catch (ErrnoException e) {
            Log.w("uhid close: " + e.getMessage());
        }
    }
}
