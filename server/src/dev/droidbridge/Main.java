package dev.droidbridge;

import android.annotation.SuppressLint;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Looper;
import android.system.Os;

import com.genymobile.scrcpy.Workarounds;

import java.lang.reflect.Field;

/**
 * Entry point, started by the Mac app as the shell user:
 * {@code CLASSPATH=/data/local/tmp/droidbridge-server.jar app_process / dev.droidbridge.Main <version>}
 * Listens on the abstract socket "droidbridge" (reached through {@code adb forward}) for one connection.
 */
public final class Main {
    public static final String VERSION = BuildInfo.VERSION;

    private Main() {
    }

    public static void main(String... args) {
        int status = 0;
        try {
            run(args);
        } catch (Throwable t) {
            Log.e("fatal", t);
            status = 1;
        } finally {
            // The Android runtime may leave non-daemon threads behind.
            System.exit(status);
        }
    }

    private static void run(String... args) throws Exception {
        if (args.length < 1 || !VERSION.equals(args[0])) {
            throw new IllegalArgumentException("server is " + VERSION + ", client asked for " + (args.length > 0 ? args[0] : "nothing"));
        }
        if (Os.getuid() == 0) {
            Os.setuid(2000); // the clipboard does not work as root
        }
        prepareMainLooper();
        Workarounds.apply();

        LocalSocket socket;
        try (LocalServerSocket server = new LocalServerSocket("droidbridge")) {
            Log.i("droidbridge " + VERSION + " waiting for the Mac");
            System.out.println("READY");
            socket = server.accept();
        }
        Session session = new Session(socket.getInputStream(), socket.getOutputStream());
        Thread worker = new Thread(() -> {
            try {
                session.run();
            } catch (Throwable t) {
                Log.e("session ended", t);
            } finally {
                Looper.getMainLooper().quitSafely();
            }
        }, "session");
        worker.start();
        Looper.loop();
        socket.close();
    }

    private static void prepareMainLooper() throws ReflectiveOperationException {
        // Like Looper.prepareMainLooper(), but the loop may quit.
        Looper.prepare();
        synchronized (Looper.class) {
            @SuppressLint("DiscouragedPrivateApi")
            Field field = Looper.class.getDeclaredField("sMainLooper");
            field.setAccessible(true);
            field.set(null, Looper.myLooper());
        }
    }
}
