package dev.droidbridge;

import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.view.InputDevice;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Reads where the mouse pointer is. The shell user cannot monitor input, and the system's
 * cursor position API is internal to system_server, but the input service's dump lists each
 * device's hovering pointer in display coordinates, e.g.
 * {@code DeviceId(15):[... hoveringPointers=[Pointer(id=0, MOUSE) at (0, 1835.57)] ...]}.
 * A dump takes about 20 ms on a recent phone, so it is only taken when the pointer moves
 * toward the edge that leads back to the Mac.
 */
final class PointerProbe {
    static final class Sample {
        final float x;
        final float y;
        final int width;
        final int height;

        Sample(float x, float y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }

        @Override
        public String toString() {
            return "(" + x + ", " + y + ") in " + width + "x" + height;
        }
    }

    private static final Pattern FRAME = Pattern.compile("logicalFrame=\\[0, 0, (\\d+), (\\d+)\\]");

    private final IBinder input;
    private int deviceId = -1;

    PointerProbe() throws ReflectiveOperationException {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Method getService = serviceManager.getMethod("getService", String.class);
        input = (IBinder) getService.invoke(null, "input");
        if (input == null) {
            throw new IllegalStateException("input service not found");
        }
    }

    /** Finds the input device id the system gave to our UHID mouse. */
    boolean findDevice(String name, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        do {
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice device = InputDevice.getDevice(id);
                if (device != null && name.equals(device.getName())) {
                    deviceId = id;
                    Log.i("mouse is input device " + id);
                    return true;
                }
            }
            Thread.sleep(50);
        } while (System.currentTimeMillis() < deadline);
        return false;
    }

    /** Returns the pointer position, or null if the pointer has not moved yet. */
    Sample sample() throws IOException {
        String dump = dump();
        Matcher pointer = Pattern.compile("DeviceId\\(" + deviceId
                + "\\):\\[.*?hoveringPointers=\\[Pointer\\(id=\\d+, MOUSE\\) at \\(([-\\d.]+), ([-\\d.]+)\\)").matcher(dump);
        if (!pointer.find()) {
            return null;
        }
        int width = 0;
        int height = 0;
        int cursor = dump.indexOf("MouseCursorController");
        Matcher frame = FRAME.matcher(dump);
        if (cursor >= 0 && frame.find(cursor) || frame.find(0)) {
            width = Integer.parseInt(frame.group(1));
            height = Integer.parseInt(frame.group(2));
        }
        return new Sample(Float.parseFloat(pointer.group(1)), Float.parseFloat(pointer.group(2)), width, height);
    }

    private String dump() throws IOException {
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(256 * 1024);
        Thread reader = new Thread(() -> {
            try (InputStream in = new FileInputStream(pipe[0].getFileDescriptor())) {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    bytes.write(buf, 0, n);
                }
            } catch (IOException e) {
                Log.w("dump read: " + e.getMessage());
            }
        }, "probe-reader");
        reader.start();
        try {
            input.dump(pipe[1].getFileDescriptor(), new String[0]);
        } catch (Exception e) {
            throw new IOException("input dump failed", e);
        } finally {
            pipe[1].close();
        }
        try {
            reader.join(1000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        pipe[0].close();
        return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
    }
}
