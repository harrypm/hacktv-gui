#!/bin/bash
#
# Build hacktv-gui Linux packages for the HOST architecture:
#   hacktv-gui_<version>_<debarch>.deb   (installs to /opt/hacktv-gui)
#   hacktv-gui-<version>-<arch>.AppImage
#
# Both bundle a Java 21 runtime and the self-contained hacktv built by
# scripts/build-hacktv.sh, so they only need glibc, zlib and the usual
# X11/font libraries from the system.
#
# Layout (same as the macOS bundle):
#   hacktv-gui                  launcher
#   app/hacktv-gui.jar, app/lib/, app/licenses/, app/hacktv
#   share/hacktv/testsignals/
#   runtime/                    Temurin 21 JRE
#
# Usage:
#   scripts/linux/make-packages.sh --hacktv <hacktv> --testsignals <dir> \
#       --gui-target <maven target dir> --version <version> --out <dir>

set -euo pipefail

# ---- Pins ---------------------------------------------------------------------
JRE_TAG="jdk-21.0.9%2B10"
JRE_VER="21.0.9_10"
JRE_X64_SHA256="aeab55d064a1a27a3744b0880b9b414077b4ed2b1790817eea3df60aec946431"
JRE_AARCH64_SHA256="1d041073c65e834bdb4da732485a54ff829859dcd1549e7992f15bd73341be29"
APPIMAGETOOL_VER="1.9.1"
APPIMAGETOOL_X86_64_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGETOOL_AARCH64_SHA256="f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
RUNTIME_VER="20251108"
RUNTIME_X86_64_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
RUNTIME_AARCH64_SHA256="00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444"
MAINTAINER="harrypm <harrypm@users.noreply.github.com>"
# Java's X11 toolkit names the window class after the main class; the
# .desktop file must match it for proper taskbar grouping.
WM_CLASS="ie-bops-hacktvgui-Main"
# ---------------------------------------------------------------------------

HACKTV="" TESTSIGNALS="" GUI_TARGET="" VERSION="" OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--hacktv) HACKTV="$2"; shift 2 ;;
		--testsignals) TESTSIGNALS="$2"; shift 2 ;;
		--gui-target) GUI_TARGET="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done
for v in HACKTV TESTSIGNALS GUI_TARGET VERSION OUT; do
	[ -n "${!v}" ] || { echo "error: missing --$(echo $v | tr 'A-Z_' 'a-z-')" >&2; exit 1; }
done

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "run this on Linux"
ARCH="$(uname -m)"
case "$ARCH" in
	x86_64)  DEBARCH=amd64; JREARCH=x64;     JRE_SHA=$JRE_X64_SHA256
	         TOOL_SHA=$APPIMAGETOOL_X86_64_SHA256; RT_SHA=$RUNTIME_X86_64_SHA256 ;;
	aarch64) DEBARCH=arm64; JREARCH=aarch64; JRE_SHA=$JRE_AARCH64_SHA256
	         TOOL_SHA=$APPIMAGETOOL_AARCH64_SHA256; RT_SHA=$RUNTIME_AARCH64_SHA256 ;;
	*) fail "unsupported architecture $ARCH" ;;
esac

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
CACHE="$OUT/.cache"; mkdir -p "$CACHE"

fetch() { # <url> <sha256> <file>
	[ -f "$3" ] || { curl -fsSL --retry 3 -o "$3.part" "$1"; mv "$3.part" "$3"; }
	echo "$2  $3" | sha256sum -c - >/dev/null || { rm -f "$3"; fail "sha256 mismatch: $3"; }
}

[ -x "$HACKTV" ] || fail "hacktv not found or not executable: $HACKTV"
[ -f "$GUI_TARGET/hacktv-gui.jar" ] || fail "$GUI_TARGET/hacktv-gui.jar not found (run mvn package)"
[ -f "$TESTSIGNALS/pm8546g.bin" ] || fail "test signals not found in $TESTSIGNALS"

# Debian versions must start with a digit (CI builds of a commit use 0~git<hash>)
DEBVER="$VERSION"; [[ "$DEBVER" =~ ^[0-9]+\. ]] || DEBVER="0~git$VERSION"

# ---- Stage the application tree ----------------------------------------------
log "Staging hacktv-gui $VERSION ($ARCH)"
TREE="$CACHE/tree"; rm -rf "$TREE"; mkdir -p "$TREE/app" "$TREE/share/hacktv/testsignals" "$TREE/runtime"
cp "$GUI_TARGET/hacktv-gui.jar" "$TREE/app/"
cp -R "$GUI_TARGET/lib" "$TREE/app/lib"
[ -d "$GUI_TARGET/licenses" ] && cp -R "$GUI_TARGET/licenses" "$TREE/app/licenses"
install -m 755 "$HACKTV" "$TREE/app/hacktv"
cp "$TESTSIGNALS"/*.bin "$TREE/share/hacktv/testsignals/"

JRE_TGZ="$CACHE/OpenJDK21U-jre_${JREARCH}_linux_hotspot_${JRE_VER}.tar.gz"
fetch "https://github.com/adoptium/temurin21-binaries/releases/download/${JRE_TAG}/$(basename "$JRE_TGZ")" "$JRE_SHA" "$JRE_TGZ"
tar -xzf "$JRE_TGZ" -C "$TREE/runtime" --strip-components=1
[ -x "$TREE/runtime/bin/java" ] || fail "JRE has no bin/java"

cat > "$TREE/hacktv-gui" <<'EOF'
#!/bin/sh
# hacktv-gui launcher: run the bundled Java runtime.
D="$(dirname "$(readlink -f "$0")")"
cd "$D/app" || exit 1
exec "$D/runtime/bin/java" \
	-Dawt.useSystemAAFontSettings=on \
	-jar "$D/app/hacktv-gui.jar" "$@"
EOF
chmod 755 "$TREE/hacktv-gui"

ICON="$REPO/src/main/resources/ie/bops/resources/ebubars.png"

desktop_file() { # <Exec> <Icon>
	cat <<EOF
[Desktop Entry]
Type=Application
Name=hacktv-gui
GenericName=Analogue TV transmitter
Comment=GUI frontend for hacktv (HackRF, HackDAC and FL2K output)
Exec=$1 %f
Icon=$2
Terminal=false
Categories=AudioVideo;Video;HamRadio;
StartupWMClass=$WM_CLASS
MimeType=application/x-hacktv-gui;
EOF
}

# HackRF (incl. HackDAC firmware) and FL2K access for the desktop user:
# uaccess grants the logged-in seat user access, plugdev keeps the
# traditional group working. Must sort before 73-seat-late.rules.
UDEV_RULES='# hacktv-gui: USB access for HackRF and FL2000 (osmo-fl2k) devices
# HackRF One / Jawbreaker / rad1o, and the NXP DFU loader used for recovery
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="6089", MODE="660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="604b", MODE="660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="cc15", MODE="660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="1fc9", ATTR{idProduct}=="000c", MODE="660", GROUP="plugdev", TAG+="uaccess"
# FL2000 USB VGA adapters (as in osmo-fl2k.rules)
SUBSYSTEM=="usb", ATTR{idVendor}=="1d5c", ATTR{idProduct}=="2000", MODE="660", GROUP="plugdev", TAG+="uaccess"'

# ---- .deb ---------------------------------------------------------------------
DEB="$OUT/hacktv-gui_${DEBVER}_${DEBARCH}.deb"
log "Building $(basename "$DEB")"
R="$CACHE/deb"; rm -rf "$R"
mkdir -p "$R/DEBIAN" "$R/opt" "$R/usr/bin" "$R/usr/share/applications" \
	"$R/usr/share/icons/hicolor/256x256/apps" "$R/usr/lib/udev/rules.d" "$R/usr/share/doc/hacktv-gui"
cp -a "$TREE" "$R/opt/hacktv-gui"
ln -s /opt/hacktv-gui/hacktv-gui "$R/usr/bin/hacktv-gui"
desktop_file /usr/bin/hacktv-gui hacktv-gui > "$R/usr/share/applications/hacktv-gui.desktop"
install -m 644 "$ICON" "$R/usr/share/icons/hicolor/256x256/apps/hacktv-gui.png"
printf '%s\n' "$UDEV_RULES" > "$R/usr/lib/udev/rules.d/60-hacktv-gui.rules"
# .htv settings files open in hacktv-gui (matches MimeType in the .desktop)
mkdir -p "$R/usr/share/mime/packages"
cat > "$R/usr/share/mime/packages/hacktv-gui.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-hacktv-gui">
    <comment>hacktv-gui configuration file</comment>
    <glob pattern="*.htv"/>
  </mime-type>
</mime-info>
EOF
[ -f "$GUI_TARGET/licenses/LICENSE.txt" ] && cp "$GUI_TARGET/licenses/LICENSE.txt" "$R/usr/share/doc/hacktv-gui/copyright"

# Minimum glibc = highest GLIBC_ symbol version used by hacktv or the JRE
GLIBC_MIN="$(find "$R/opt/hacktv-gui" -type f \( -name 'hacktv' -o -name '*.so' -o -path '*/bin/*' \) \
	-exec objdump -T {} + 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
INSTALLED_KB="$(du -sk "$R/opt" | cut -f1)"
cat > "$R/DEBIAN/control" <<EOF
Package: hacktv-gui
Version: $DEBVER
Architecture: $DEBARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_KB
Depends: libc6 (>= $GLIBC_MIN), zlib1g, libx11-6, libxext6, libxrender1, libxtst6, libxi6, libfreetype6, libfontconfig1
Recommends: yt-dlp
Section: hamradio
Priority: optional
Homepage: https://github.com/harrypm/hacktv-gui
Description: GUI frontend for hacktv analogue TV transmitter
 hacktv-gui runs hacktv without the command line: HackRF RF output,
 HackDAC baseband output, FL2000 (osmo-fl2k) and file output.
 .
 Bundles hacktv (inaxeon/hacktv with HackDAC support), its test signals
 and a Java 21 runtime under /opt/hacktv-gui.
EOF
cat > "$R/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules || true
		udevadm trigger --subsystem-match=usb || true
	fi
	command -v update-mime-database >/dev/null 2>&1 && update-mime-database /usr/share/mime || true
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
	command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
exit 0
EOF
cat > "$R/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
	command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules || true
fi
exit 0
EOF
chmod 755 "$R/DEBIAN/postinst" "$R/DEBIAN/postrm"
dpkg-deb --root-owner-group -Zxz --build "$R" "$DEB" >/dev/null
dpkg-deb --info "$DEB" | sed -n '/Package:/,/Description:/p'

# ---- AppImage -----------------------------------------------------------------
APPIMAGE="$OUT/hacktv-gui-${VERSION}-${ARCH}.AppImage"
log "Building $(basename "$APPIMAGE")"
A="$CACHE/AppDir"; rm -rf "$A"; mkdir -p "$A/usr/share/applications" "$A/usr/share/icons/hicolor/256x256/apps"
cp -a "$TREE" "$A/opt-hacktv-gui"
cat > "$A/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/opt-hacktv-gui/hacktv-gui" "$@"
EOF
chmod 755 "$A/AppRun"
desktop_file hacktv-gui hacktv-gui > "$A/hacktv-gui.desktop"
cp "$A/hacktv-gui.desktop" "$A/usr/share/applications/"
install -m 644 "$ICON" "$A/hacktv-gui.png"
install -m 644 "$ICON" "$A/usr/share/icons/hicolor/256x256/apps/hacktv-gui.png"

TOOL="$CACHE/appimagetool-$ARCH.AppImage"
RT="$CACHE/runtime-$ARCH"
fetch "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VER/appimagetool-$ARCH.AppImage" "$TOOL_SHA" "$TOOL"
fetch "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VER/runtime-$ARCH" "$RT_SHA" "$RT"
chmod 755 "$TOOL"
# Extract-and-run: CI runners have no FUSE. --runtime-file pins the runtime
# instead of letting appimagetool download the moving "continuous" one.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$TOOL" --no-appstream --runtime-file "$RT" "$A" "$APPIMAGE" >"$CACHE/appimagetool.log" 2>&1 ||
	{ tail -30 "$CACHE/appimagetool.log"; fail "appimagetool failed"; }
chmod 755 "$APPIMAGE"

# ---- Verification ----------------------------------------------------------
log "Verifying"
grep -q '"21\.' <<< "$("$TREE/runtime/bin/java" -version 2>&1)" || fail "bundled Java does not run"
grep -q "Usage: hacktv" <<< "$("$TREE/app/hacktv" --help 2>&1)" || fail "bundled hacktv does not run"
# Capture output first: grep -q exits early and, under pipefail, the
# writer's SIGPIPE would fail the check even when the match is found.
DEBLIST="$(dpkg-deb --contents "$DEB")"
grep -q './opt/hacktv-gui/app/hacktv$' <<< "$DEBLIST" || fail ".deb is missing hacktv"
grep -q 'share/hacktv/testsignals/pm8546g.bin' <<< "$DEBLIST" || fail ".deb is missing test signals"
# The AppImage must contain the same tree
( cd "$CACHE" && rm -rf squashfs-root && APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" --appimage-extract >/dev/null 2>&1 )
[ -x "$CACHE/squashfs-root/opt-hacktv-gui/app/hacktv" ] || fail "AppImage is missing hacktv"
grep -q "Usage: hacktv" <<< "$("$CACHE/squashfs-root/opt-hacktv-gui/app/hacktv" --help 2>&1)" || fail "AppImage hacktv does not run"
rm -rf "$CACHE/squashfs-root"

( cd "$OUT" && sha256sum "$(basename "$DEB")" "$(basename "$APPIMAGE")" > "hacktv-gui-${VERSION}-linux-${ARCH}.sha256" )
ls -la "$DEB" "$APPIMAGE"
cat "$OUT/hacktv-gui-${VERSION}-linux-${ARCH}.sha256"
echo "OK"
