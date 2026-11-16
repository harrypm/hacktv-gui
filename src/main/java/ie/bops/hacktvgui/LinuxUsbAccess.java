/*
 * Copyright (C) 2026 harrypm
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */
package ie.bops.hacktvgui;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

/**
 * Linux USB permissions for the SDR devices hacktv uses (HackRF, FL2000).
 *
 * Without udev rules, USB device nodes are root-only, so hacktv fails with
 * "Access denied" for a normal user. Packages (.deb) install the rules; an
 * AppImage or a plain jar cannot, so the GUI detects the situation and
 * offers to install them with the system's password prompt (pkexec).
 */
final class LinuxUsbAccess {

    /** Installed rules file name (same as the .deb's). */
    static final String RULES_NAME = "60-hacktv-gui.rules";
    static final Path RULES_TARGET = Path.of("/etc/udev/rules.d", RULES_NAME);
    private static final String RULES_RESOURCE = "/ie/bops/resources/linux/" + RULES_NAME;

    private static final String[] RULES_DIRS = {
        "/etc/udev/rules.d", "/run/udev/rules.d", "/usr/lib/udev/rules.d", "/lib/udev/rules.d"
    };

    /** A known device type: vendor/product ID and a display name. */
    private record Known(String vid, String pid, String name, boolean hackrf) {}

    private static final Known[] KNOWN = {
        new Known("1d50", "6089", "HackRF One", true),
        new Known("1d50", "604b", "HackRF Jawbreaker", true),
        new Known("1d50", "cc15", "rad1o", true),
        new Known("1fc9", "000c", "HackRF in DFU (recovery) mode", true),
        new Known("1d5c", "2000", "FL2000 USB VGA adapter", false),
    };

    /** A connected device and whether this user can open it. */
    record Device(String name, String node, boolean accessible) {
        @Override
        public String toString() {
            return name + " (" + node + "): " + (accessible ? "accessible" : "NO ACCESS");
        }
    }

    /** Which rules exist on the system for each device family. */
    record RulesState(boolean ours, boolean hackrf, boolean fl2k) {
        boolean complete() {
            return ours || (hackrf && fl2k);
        }
    }

    private LinuxUsbAccess() {}

    static boolean isLinux() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ENGLISH).contains("linux");
    }

    /** True when udev is running (not in a container or a udev-less system). */
    static boolean udevAvailable() {
        return Files.isDirectory(Path.of("/run/udev"));
    }

    /**
     * Looks through the udev rules directories for our rules file, and for
     * any other rules (e.g. a distribution's hackrf package) that cover
     * HackRF and FL2000 devices.
     */
    static RulesState rulesState() {
        boolean ours = false, hackrf = false, fl2k = false;
        for (String d : RULES_DIRS) {
            Path dir = Path.of(d);
            if (!Files.isDirectory(dir)) continue;
            try (DirectoryStream<Path> ds = Files.newDirectoryStream(dir, "*.rules")) {
                for (Path p : ds) {
                    if (p.getFileName().toString().equals(RULES_NAME)) ours = true;
                    String s;
                    try {
                        s = Files.readString(p, StandardCharsets.UTF_8).toLowerCase(Locale.ENGLISH);
                    } catch (IOException | RuntimeException e) {
                        continue;   // unreadable or not UTF-8
                    }
                    if (s.contains("1d50") && s.contains("6089")) hackrf = true;
                    if (s.contains("1d5c") && s.contains("2000")) fl2k = true;
                }
            } catch (IOException e) {
                // unreadable directory: ignore
            }
        }
        return new RulesState(ours, hackrf, fl2k);
    }

    /** Connected HackRF / FL2000 devices, from sysfs. */
    static List<Device> connectedDevices() {
        var out = new ArrayList<Device>();
        Path usb = Path.of("/sys/bus/usb/devices");
        if (!Files.isDirectory(usb)) return out;
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(usb)) {
            for (Path dev : ds) {
                String vid = read(dev.resolve("idVendor"));
                String pid = read(dev.resolve("idProduct"));
                if (vid == null || pid == null) continue;   // interfaces, hubs' ports
                for (Known k : KNOWN) {
                    if (!k.vid.equals(vid) || !k.pid.equals(pid)) continue;
                    String bus = read(dev.resolve("busnum"));
                    String num = read(dev.resolve("devnum"));
                    if (bus == null || num == null) break;
                    try {
                        String node = String.format("/dev/bus/usb/%03d/%03d",
                                Integer.parseInt(bus), Integer.parseInt(num));
                        Path n = Path.of(node);
                        out.add(new Device(k.name, node, Files.isReadable(n) && Files.isWritable(n)));
                    } catch (NumberFormatException e) {
                        // malformed sysfs entry: skip
                    }
                    break;
                }
            }
        } catch (IOException e) {
            // no sysfs access: report nothing
        }
        return out;
    }

    /** True if a HackRF/FL2000 is plugged in but this user cannot open it. */
    static boolean hasInaccessibleDevice() {
        return connectedDevices().stream().anyMatch(d -> !d.accessible());
    }

    /** The rules file text shipped in the jar. */
    static String rulesText() throws IOException {
        try (InputStream in = LinuxUsbAccess.class.getResourceAsStream(RULES_RESOURCE)) {
            if (in == null) throw new IOException("rules resource missing from jar: " + RULES_RESOURCE);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    /**
     * Saves a copy of the rules where the user can find it, for installing
     * by hand.
     */
    static Path saveUserCopy() throws IOException {
        String base = System.getenv("XDG_DATA_HOME");
        Path dir = (base == null || base.isBlank())
                ? Path.of(System.getProperty("user.home"), ".local", "share", "hacktv-gui")
                : Path.of(base, "hacktv-gui");
        Files.createDirectories(dir);
        Path p = dir.resolve(RULES_NAME);
        Files.writeString(p, rulesText(), StandardCharsets.UTF_8);
        return p;
    }

    /** Commands to install the rules by hand from a saved copy. */
    static String manualCommands(Path copy) {
        return "sudo install -m 644 '" + copy + "' " + RULES_TARGET + "\n"
             + "sudo udevadm control --reload-rules\n"
             + "sudo udevadm trigger --action=add --subsystem-match=usb\n";
    }

    static boolean pkexecAvailable() {
        for (String d : System.getenv().getOrDefault("PATH", "/usr/bin:/bin").split(":")) {
            if (!d.isEmpty() && Files.isExecutable(Path.of(d, "pkexec"))) return true;
        }
        return Files.isExecutable(Path.of("/usr/bin/pkexec"));
    }

    /** Result of an install attempt. */
    record InstallResult(boolean ok, boolean cancelled, String output) {}

    /**
     * Installs the rules with pkexec (the desktop's password prompt), then
     * reloads udev and re-applies rules to devices already plugged in.
     * Blocks until the user has answered the prompt; call off the EDT.
     */
    static InstallResult install() throws IOException, InterruptedException {
        Path tmp = Files.createTempFile("hacktv-gui-udev-", ".rules");
        try {
            Files.writeString(tmp, rulesText(), StandardCharsets.UTF_8);
            var pb = new ProcessBuilder("pkexec", "/bin/sh", "-c",
                    "install -m 644 \"$1\" '" + RULES_TARGET + "'"
                    + " && udevadm control --reload-rules"
                    + " && udevadm trigger --action=add --subsystem-match=usb",
                    "sh", tmp.toString());
            pb.redirectErrorStream(true);
            Process p = pb.start();
            String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
            if (!p.waitFor(5, TimeUnit.MINUTES)) {
                p.destroy();
                return new InstallResult(false, true, "timed out waiting for authentication");
            }
            int rc = p.exitValue();
            // pkexec: 126 = dialog dismissed / not authorised, 127 = auth failed
            return new InstallResult(rc == 0, rc == 126 || rc == 127, out);
        } finally {
            Files.deleteIfExists(tmp);
        }
    }

    /**
     * After installing, udev applies the rules asynchronously; wait briefly
     * for connected devices to become accessible.
     */
    static List<Device> waitForAccess(long timeoutMs) throws InterruptedException {
        long end = System.currentTimeMillis() + timeoutMs;
        List<Device> devs = connectedDevices();
        while (devs.stream().anyMatch(d -> !d.accessible()) && System.currentTimeMillis() < end) {
            Thread.sleep(250);
            devs = connectedDevices();
        }
        return devs;
    }

    /** True if the user is in the plugdev group (fallback when uaccess is absent). */
    static boolean inPlugdevGroup() {
        try {
            Process p = new ProcessBuilder("id", "-Gn").redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            p.waitFor(5, TimeUnit.SECONDS);
            for (String g : out.trim().split("\\s+")) if (g.equals("plugdev")) return true;
        } catch (IOException e) {
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return false;
    }

    private static String read(Path p) {
        try {
            return Files.readString(p, StandardCharsets.US_ASCII).trim().toLowerCase(Locale.ENGLISH);
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }
}
