#!/bin/bash
#
# Assemble hacktv-gui.app (universal: Apple Silicon + Intel) and package it
# as .zip and .dmg.
#
# Bundle layout:
#   hacktv-gui.app/Contents/
#     Info.plist
#     MacOS/hacktv-gui              launcher (selects the native Java runtime)
#     Resources/hacktv-gui.icns
#     app/hacktv-gui.jar, app/lib/, app/licenses/
#     app/hacktv                    universal hacktv binary (lipo x86_64+arm64)
#     share/hacktv/testsignals/     test signal patterns
#     runtime/arm64/, runtime/x86_64/   Temurin 21 JREs
#
# hacktv-gui finds hacktv next to its jar (findHackTVPath) and the test
# signals at <hacktv dir>/../share/hacktv/testsignals (getTestSignalDir).
#
# Usage:
#   scripts/macos/make-app.sh --hacktv <universal hacktv> --testsignals <dir> \
#       --gui-target <maven target dir> --version <version> --out <dir>

set -euo pipefail

# ---- Pinned Java runtime (Temurin 21, same release as the Windows packages) --
JRE_TAG="jdk-21.0.9%2B10"
JRE_VER="21.0.9_10"
JRE_ARM64_SHA256="1f7f6506b598e85d7d8ff8b36563d98657d2d81b16bfca3cd242d7906cfbd11b"
JRE_X64_SHA256="945abc49249f1e89a2a6a008d70d63dc42b25bbe5e1711ff97aeec70063008d2"
MIN_MACOS="11.0"
BUNDLE_ID="io.github.harrypm.hacktv-gui"
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
	[ -n "${!v}" ] || { echo "error: --$(echo $v | tr 'A-Z_' 'a-z-') is required" >&2; exit 1; }
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
CACHE="$OUT/.cache"; mkdir -p "$CACHE"
APP="$OUT/hacktv-gui.app"
C="$APP/Contents"

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Inputs must be what we expect before anything is assembled.
# MAKEAPP_ALLOW_SINGLE_ARCH=1 is for local test builds on one machine only;
# CI never sets it, so release bundles are always universal.
if [ "${MAKEAPP_ALLOW_SINGLE_ARCH:-0}" = "1" ]; then
	echo "WARNING: single-architecture test build (hacktv: $(lipo -archs "$HACKTV"))"
else
	[ "$(lipo -archs "$HACKTV" | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 " ] ||
		fail "hacktv is not universal (archs: $(lipo -archs "$HACKTV"))"
fi
[ -f "$GUI_TARGET/hacktv-gui.jar" ] || fail "$GUI_TARGET/hacktv-gui.jar not found (run mvn package)"
[ -f "$TESTSIGNALS/pm8546g.bin" ] || fail "test signals not found in $TESTSIGNALS"

log "Assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/app" "$C/share/hacktv/testsignals" "$C/runtime"

cp "$GUI_TARGET/hacktv-gui.jar" "$C/app/"
cp -R "$GUI_TARGET/lib" "$C/app/lib"
[ -d "$GUI_TARGET/licenses" ] && cp -R "$GUI_TARGET/licenses" "$C/app/licenses"
cp "$HACKTV" "$C/app/hacktv"; chmod 755 "$C/app/hacktv"
cp "$TESTSIGNALS"/*.bin "$C/share/hacktv/testsignals/"

# ---- Java runtimes ----------------------------------------------------------
fetch_jre() { # <temurin arch> <sha256> <bundle arch dir>
	local a="$1" sha="$2" dest="$3"
	local f="$CACHE/OpenJDK21U-jre_${a}_mac_hotspot_${JRE_VER}.tar.gz"
	if [ ! -f "$f" ]; then
		curl -fsSL --retry 3 -o "$f.part" \
			"https://github.com/adoptium/temurin21-binaries/releases/download/${JRE_TAG}/$(basename "$f")"
		mv "$f.part" "$f"
	fi
	echo "$sha  $f" | shasum -a 256 -c - >/dev/null || { rm -f "$f"; fail "JRE sha256 mismatch ($a)"; }
	local x="$CACHE/jre-$a"; rm -rf "$x"; mkdir -p "$x"
	tar -xzf "$f" -C "$x"
	local home; home="$(find "$x" -maxdepth 4 -type d -path '*/Contents/Home' | head -1)"
	[ -x "$home/bin/java" ] || fail "no Contents/Home/bin/java in JRE ($a)"
	ditto "$home" "$C/runtime/$dest"
}
log "Java runtimes (Temurin ${JRE_VER/_/+})"
fetch_jre aarch64 "$JRE_ARM64_SHA256" arm64
fetch_jre x64 "$JRE_X64_SHA256" x86_64
[ "$(lipo -archs "$C/runtime/arm64/bin/java")" = "arm64" ] || fail "arm64 runtime has wrong arch"
[ "$(lipo -archs "$C/runtime/x86_64/bin/java")" = "x86_64" ] || fail "x86_64 runtime has wrong arch"

# ---- Launcher ---------------------------------------------------------------
cat > "$C/MacOS/hacktv-gui" <<'EOF'
#!/bin/sh
# hacktv-gui launcher: run the bundled Java runtime that is native to this Mac.
# hw.optional.arm64 is 1 on Apple Silicon even if this script runs translated.
C="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
	ARCH=arm64
else
	ARCH=x86_64
fi
JAVA="$C/runtime/$ARCH/bin/java"
# Apps started from Finder get a minimal PATH; add the usual locations so
# yt-dlp/ffmpeg installed by the user (Homebrew etc.) can still be found.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/usr/local/bin"
cd "$C/app" || exit 1
exec "$JAVA" \
	-Xdock:name=hacktv-gui \
	-Xdock:icon="$C/Resources/hacktv-gui.icns" \
	-Dapple.awt.application.name=hacktv-gui \
	-jar "$C/app/hacktv-gui.jar" "$@"
EOF
chmod 755 "$C/MacOS/hacktv-gui"

# ---- Icon -------------------------------------------------------------------
log "Icon"
ICON_SRC="$REPO/src/main/resources/ie/bops/resources/ebubars.png"
SET="$CACHE/hacktv-gui.iconset"; rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256; do
	sips -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
	d=$((s * 2)); [ $d -le 256 ] && sips -z $d $d "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$C/Resources/hacktv-gui.icns"

# ---- Info.plist --------------------------------------------------------------
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>hacktv-gui</string>
	<key>CFBundleDisplayName</key><string>hacktv-gui</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>hacktv-gui</string>
	<key>CFBundleIconFile</key><string>hacktv-gui</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF
plutil -lint "$C/Info.plist" >/dev/null || fail "Info.plist invalid"

# ---- Signing (ad-hoc) ----------------------------------------------------------
# Apple Silicon refuses to run unsigned arm64 code; lipo output must be
# re-signed. The Temurin runtimes keep their own (Adoptium) signatures.
# Not notarized: downloaded copies need the quarantine flag cleared once.
log "Ad-hoc signing"
codesign --force --sign - "$C/app/hacktv"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" || fail "bundle signature does not verify"
codesign --verify "$C/app/hacktv" || fail "hacktv signature does not verify"

# ---- Verification ----------------------------------------------------------
log "Verifying bundle"
HOST="$(uname -m)"
"$C/runtime/$HOST/bin/java" -version 2>&1 | grep -q '"21\.' || fail "bundled $HOST Java does not run"
"$C/app/hacktv" --help 2>&1 | grep -q "Usage: hacktv" || fail "bundled hacktv does not run on $HOST"
unzip -p "$C/app/hacktv-gui.jar" META-INF/MANIFEST.MF | grep -q "Main-Class: ie.bops.hacktvgui.Main" ||
	fail "jar has no Main-Class"
[ "$(ls "$C/share/hacktv/testsignals" | wc -l)" -ge 19 ] || fail "test signals missing from bundle"

# ---- Packaging ---------------------------------------------------------------
NAME="hacktv-gui-${VERSION}-macos-universal"
log "Packaging $NAME"
rm -f "$OUT/$NAME.zip" "$OUT/$NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
STAGE="$CACHE/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/hacktv-gui.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "hacktv-gui" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg"
rm -rf "$STAGE"
( cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME.sha256" )

du -sh "$APP" "$OUT/$NAME.zip" "$OUT/$NAME.dmg"
cat "$OUT/$NAME.sha256"
echo "OK: $APP"
