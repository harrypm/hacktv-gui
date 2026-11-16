// CI check for ie.bops.hacktvgui.LinuxUsbAccess on a real Linux system.
// Usage: java -cp hacktv-gui.jar scripts/linux/UsbAccessCheck.java <expect-ours: true|false>
import java.lang.reflect.Method;

public class UsbAccessCheck {
    public static void main(String[] a) throws Exception {
        boolean expectOurs = Boolean.parseBoolean(a[0]);
        Class<?> c = Class.forName("ie.bops.hacktvgui.LinuxUsbAccess");
        Object state = call(c, "rulesState");
        Method oursM = state.getClass().getDeclaredMethod("ours");
        oursM.setAccessible(true);
        boolean ours = (boolean) oursM.invoke(state);
        System.out.println("isLinux=" + call(c, "isLinux") + " udev=" + call(c, "udevAvailable"));
        System.out.println("rules=" + state);
        System.out.println("devices=" + call(c, "connectedDevices"));
        System.out.println("pkexec=" + call(c, "pkexecAvailable"));
        String rules = (String) call(c, "rulesText");
        if (!rules.contains("1d50") || !rules.contains("uaccess")) throw new AssertionError("bad rules resource");
        if (!(boolean) call(c, "isLinux")) throw new AssertionError("isLinux false on Linux");
        if (ours != expectOurs) throw new AssertionError("rulesState().ours=" + ours + ", expected " + expectOurs);
        System.out.println("OK");
    }

    private static Object call(Class<?> c, String name) throws Exception {
        Method m = c.getDeclaredMethod(name);
        m.setAccessible(true);
        return m.invoke(null);
    }
}
