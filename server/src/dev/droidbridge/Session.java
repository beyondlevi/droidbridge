package dev.droidbridge;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import com.genymobile.scrcpy.wrappers.ClipboardManager;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One connection from the Mac: a mouse and a keyboard over UHID, plus the clipboard. */
final class Session {
    static final String MOUSE_NAME = "droidbridge mouse";
    static final String KEYBOARD_NAME = "droidbridge keyboard";
    private static final int VENDOR_ID = 0x18D1;

    /** Counts pushed against the return edge, after it is reached, before control goes back. */
    private static final int PUSH_TO_LEAVE = 24;
    /** Minimum time between two pointer probes. */
    private static final long PROBE_INTERVAL_MS = 30;
    /** How close to the edge (px) counts as touching it. */
    private static final float EDGE_SLOP = 1.5f;

    private final DataInputStream in;
    private final DataOutputStream out;
    private final Uhid mouse;
    private final Uhid keyboard;
    private final PointerProbe probe;
    private final ClipboardManager clipboard;
    private final ExecutorService prober = Executors.newSingleThreadExecutor();

    private volatile int returnSide = Protocol.SIDE_NONE;
    private volatile boolean atEdge;
    private volatile float edgeRatio;
    private volatile boolean probing;
    private volatile long lastProbe;
    private int pushed;
    private boolean edgeSent;
    private int buttons;

    private final Object clipLock = new Object();
    private String lastClipFromMac;
    private String lastClipToMac;

    Session(InputStream input, OutputStream output) throws Exception {
        in = new DataInputStream(new BufferedInputStream(input));
        out = new DataOutputStream(new BufferedOutputStream(output));
        mouse = new Uhid(MOUSE_NAME, VENDOR_ID, 0x4D42, Uhid.MOUSE_DESCRIPTOR);
        keyboard = new Uhid(KEYBOARD_NAME, VENDOR_ID, 0x4B42, Uhid.KEYBOARD_DESCRIPTOR);
        probe = new PointerProbe();
        if (!probe.findDevice(MOUSE_NAME, 3000)) {
            throw new IOException("the system did not add the UHID mouse");
        }
        clipboard = ServiceManager.getClipboardManager();
    }

    void run() throws IOException {
        int[] size = displaySize();
        sendDevice(size[0], size[1]);
        if (clipboard != null) {
            // Clipboard callbacks need a looper; the main thread runs one.
            new Handler(Looper.getMainLooper()).post(() -> clipboard.addPrimaryClipChangedListener(this::onDeviceClipboard));
        } else {
            Log.w("no clipboard manager on this device");
        }
        try {
            while (true) {
                int type = in.readUnsignedByte();
                int length = in.readInt();
                if (length < 0 || length > Protocol.MAX_PAYLOAD) {
                    throw new IOException("bad payload length " + length);
                }
                byte[] payload = new byte[length];
                in.readFully(payload);
                handle(type, payload);
            }
        } catch (EOFException e) {
            Log.i("Mac disconnected");
        } finally {
            prober.shutdownNow();
            mouse.close();
            keyboard.close();
        }
    }

    private void handle(int type, byte[] p) throws IOException {
        switch (type) {
            case Protocol.HELLO:
                int version = ((p[0] & 0xFF) << 8) | (p[1] & 0xFF);
                Log.i("Mac protocol " + version);
                break;
            case Protocol.MOUSE:
                buttons = p[0] & 0x1F;
                int dx = (short) (((p[1] & 0xFF) << 8) | (p[2] & 0xFF));
                int dy = (short) (((p[3] & 0xFF) << 8) | (p[4] & 0xFF));
                moveMouse(dx, dy, p[5], p[6]);
                onMotion(dx, dy);
                break;
            case Protocol.KEYS:
                if (p.length == 8) {
                    keyboard.input(p);
                }
                break;
            case Protocol.ENTER:
                enter(p[0], (((p[1] & 0xFF) << 8) | (p[2] & 0xFF)) / 65535f);
                break;
            case Protocol.LEAVE:
                returnSide = Protocol.SIDE_NONE;
                buttons = 0;
                mouse.input(new byte[5]);
                keyboard.input(new byte[8]);
                break;
            case Protocol.CLIPBOARD:
                setDeviceClipboard(new String(p, StandardCharsets.UTF_8));
                break;
            case Protocol.PING:
                send(Protocol.PONG, new byte[0]);
                break;
            default:
                Log.w("unknown message type " + type);
        }
    }

    /** Sends a relative move as UHID reports, each axis limited to -127..127 per report. */
    private void moveMouse(int dx, int dy, int wheel, int hwheel) throws IOException {
        do {
            int sx = clamp(dx);
            int sy = clamp(dy);
            mouse.input(new byte[] {(byte) buttons, (byte) sx, (byte) sy, (byte) wheel, (byte) hwheel});
            dx -= sx;
            dy -= sy;
            wheel = 0;
            hwheel = 0;
        } while (dx != 0 || dy != 0);
    }

    private static int clamp(int v) {
        return Math.max(-127, Math.min(127, v));
    }

    /**
     * Puts the pointer on the entry edge at the given ratio. The mouse is relative and Android
     * accelerates it, so: push into the corner, then walk along the edge and measure.
     */
    private void enter(int side, float ratio) throws IOException {
        Log.i("enter side=" + side + " ratio=" + ratio);
        returnSide = Protocol.SIDE_NONE;
        boolean horizontalEdge = side == Protocol.SIDE_TOP || side == Protocol.SIDE_BOTTOM;
        int intoX = side == Protocol.SIDE_RIGHT ? 1 : -1;
        int intoY = side == Protocol.SIDE_BOTTOM ? 1 : -1;
        // Into the corner: the entry edge, at the start of the axis along it.
        for (int i = 0; i < 40; i++) {
            mouse.input(new byte[] {0, (byte) (horizontalEdge ? -127 : 127 * intoX), (byte) (horizontalEdge ? 127 * intoY : -127), 0, 0});
        }
        sleep(15);
        PointerProbe.Sample s = probe.sample();
        if (s != null && s.width > 0) {
            float length = horizontalEdge ? s.width - 1 : s.height - 1;
            float target = ratio * length;
            float gain = 0;
            for (int attempt = 0; attempt < 4; attempt++) {
                float now = horizontalEdge ? s.x : s.y;
                float error = target - now;
                if (Math.abs(error) < 12) {
                    break;
                }
                int counts = gain > 0 ? Math.round(error / gain) : (int) Math.signum(error) * 60;
                walk(horizontalEdge, counts);
                sleep(15);
                PointerProbe.Sample next = probe.sample();
                if (next == null) {
                    break;
                }
                float moved = (horizontalEdge ? next.x : next.y) - now;
                if (counts != 0 && moved * counts > 0) {
                    gain = moved / counts;
                }
                s = next;
            }
            Log.i("entered at " + s + ", target " + target);
        }
        atEdge = true;
        edgeRatio = ratio;
        pushed = 0;
        edgeSent = false;
        returnSide = side;
    }

    /** Moves along one axis in small steps, so acceleration stays predictable. */
    private void walk(boolean horizontal, int counts) throws IOException {
        int step = counts > 0 ? 10 : -10;
        while (counts != 0) {
            int s = Math.abs(counts) < Math.abs(step) ? counts : step;
            mouse.input(new byte[] {0, (byte) (horizontal ? s : 0), (byte) (horizontal ? 0 : s), 0, 0});
            counts -= s;
            sleep(2);
        }
    }

    /** Watches for the pointer being pushed against the edge that leads back to the Mac. */
    private void onMotion(int dx, int dy) throws IOException {
        int side = returnSide;
        if (side == Protocol.SIDE_NONE || buttons != 0) {
            return;
        }
        int toward;
        switch (side) {
            case Protocol.SIDE_LEFT: toward = -dx; break;
            case Protocol.SIDE_RIGHT: toward = dx; break;
            case Protocol.SIDE_TOP: toward = -dy; break;
            default: toward = dy; break;
        }
        if (toward <= 0) {
            if (dx != 0 || dy != 0) {
                atEdge = false;
                pushed = 0;
            }
            return;
        }
        if (atEdge) {
            pushed += toward;
            if (pushed >= PUSH_TO_LEAVE && !edgeSent) {
                edgeSent = true;
                int r = Math.round(Math.max(0, Math.min(1, edgeRatio)) * 65535);
                send(Protocol.EDGE, new byte[] {(byte) side, (byte) (r >> 8), (byte) r});
                Log.i("edge reached, back to the Mac (ratio " + edgeRatio + ")");
            }
            // Keep confirming while pushing: the pointer may have slid along the edge.
        }
        long now = System.currentTimeMillis();
        if (!probing && now - lastProbe >= PROBE_INTERVAL_MS) {
            probing = true;
            lastProbe = now;
            prober.execute(() -> {
                try {
                    PointerProbe.Sample s = probe.sample();
                    if (s != null && s.width > 0) {
                        boolean touching;
                        float ratio;
                        switch (side) {
                            case Protocol.SIDE_LEFT: touching = s.x <= EDGE_SLOP; ratio = s.y / (s.height - 1); break;
                            case Protocol.SIDE_RIGHT: touching = s.x >= s.width - 1 - EDGE_SLOP; ratio = s.y / (s.height - 1); break;
                            case Protocol.SIDE_TOP: touching = s.y <= EDGE_SLOP; ratio = s.x / (s.width - 1); break;
                            default: touching = s.y >= s.height - 1 - EDGE_SLOP; ratio = s.x / (s.width - 1); break;
                        }
                        edgeRatio = ratio;
                        atEdge = touching;
                    }
                } catch (IOException e) {
                    Log.w("probe: " + e.getMessage());
                } finally {
                    probing = false;
                }
            });
        }
    }

    private void setDeviceClipboard(String text) {
        if (clipboard == null) {
            return;
        }
        synchronized (clipLock) {
            lastClipFromMac = text;
        }
        clipboard.setText(text);
    }

    private void onDeviceClipboard() {
        CharSequence cs = clipboard.getText();
        if (cs == null) {
            return;
        }
        String text = cs.toString();
        synchronized (clipLock) {
            if (text.equals(lastClipFromMac) || text.equals(lastClipToMac)) {
                return;
            }
            lastClipToMac = text;
        }
        try {
            send(Protocol.DEVICE_CLIPBOARD, text.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Log.w("clipboard send: " + e.getMessage());
        }
    }

    private void sendDevice(int width, int height) throws IOException {
        byte[] model = (Build.MANUFACTURER + " " + Build.MODEL).getBytes(StandardCharsets.UTF_8);
        byte[] p = new byte[6 + model.length];
        p[0] = (byte) (Protocol.VERSION >> 8);
        p[1] = (byte) Protocol.VERSION;
        p[2] = (byte) (width >> 8);
        p[3] = (byte) width;
        p[4] = (byte) (height >> 8);
        p[5] = (byte) height;
        System.arraycopy(model, 0, p, 6, model.length);
        send(Protocol.DEVICE, p);
    }

    private synchronized void send(int type, byte[] payload) throws IOException {
        out.writeByte(type);
        out.writeInt(payload.length);
        out.write(payload);
        out.flush();
    }

    private int[] displaySize() {
        android.util.DisplayMetrics m = new android.util.DisplayMetrics();
        try {
            android.view.Display d = ((android.hardware.display.DisplayManager) com.genymobile.scrcpy.FakeContext.get()
                    .getSystemService(android.content.Context.DISPLAY_SERVICE)).getDisplay(0);
            d.getRealMetrics(m);
            return new int[] {m.widthPixels, m.heightPixels};
        } catch (RuntimeException e) {
            Log.w("display size: " + e.getMessage());
            return new int[] {0, 0};
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
