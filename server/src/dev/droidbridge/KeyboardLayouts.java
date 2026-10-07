package dev.droidbridge;

import android.os.IBinder;
import android.view.InputDevice;

import java.lang.reflect.Method;

/**
 * Sets the Android keyboard layout of our UHID keyboard, so dead keys and symbols match the Mac's
 * layout. Uses IInputManager.setKeyboardLayoutOverrideForInputDevice (Android 15+, allowed to the
 * shell user through SET_KEYBOARD_LAYOUT).
 */
final class KeyboardLayouts {
    private static final String PREFIX = "com.android.inputdevices/com.android.inputdevices.InputDeviceReceiver/keyboard_layout_";

    private KeyboardLayouts() {
    }

    /** {@code layout} is the suffix of an Android layout descriptor, e.g. "english_us_intl". */
    static boolean apply(String deviceName, String layout) {
        if (!layout.matches("[a-z_]+")) {
            Log.w("bad layout name " + layout);
            return false;
        }
        try {
            InputDevice device = null;
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (d != null && deviceName.equals(d.getName())) {
                    device = d;
                }
            }
            if (device == null) {
                Log.w("keyboard not found for layout");
                return false;
            }
            Object identifier = InputDevice.class.getMethod("getIdentifier").invoke(device);
            Class<?> sm = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, "input");
            Object im = Class.forName("android.hardware.input.IInputManager$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
            Method set = im.getClass().getMethod("setKeyboardLayoutOverrideForInputDevice", identifier.getClass(), String.class);
            set.invoke(im, identifier, PREFIX + layout);
            Log.i("keyboard layout " + layout);
            return true;
        } catch (ReflectiveOperationException | RuntimeException e) {
            Log.e("cannot set keyboard layout " + layout, e);
            return false;
        }
    }
}
