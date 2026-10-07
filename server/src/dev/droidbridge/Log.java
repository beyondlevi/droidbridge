package dev.droidbridge;

/** Logs to logcat (tag "droidbridge") and to stdout, which the Mac app keeps. */
final class Log {
    private static final String TAG = "droidbridge";

    private Log() {
    }

    static void i(String msg) {
        android.util.Log.i(TAG, msg);
        System.out.println("I " + msg);
    }

    static void w(String msg) {
        android.util.Log.w(TAG, msg);
        System.out.println("W " + msg);
    }

    static void e(String msg, Throwable t) {
        android.util.Log.e(TAG, msg, t);
        System.out.println("E " + msg + (t != null ? ": " + t : ""));
    }
}
