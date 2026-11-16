#!/bin/bash
#
# Build a self-contained hacktv binary for the HOST OS/architecture
# (macOS or Linux).
#
# Mirrors the dependency set of upstream inaxeon/hacktv src/build_win64.sh
# (the build the GUI downloads on Windows as "Matt's TV Barn"):
#   - hacktv: inaxeon/hacktv at a pinned commit, unmodified
#   - libusb 1.0.26, libhackrf 2023.01.1, osmo-fl2k 0.2.1: static
#   - FFmpeg 6.1.1: static, macOS frameworks only (no third-party libs)
#
# FFmpeg is built with --disable-autodetect, so nothing from the build
# machine leaks in. The result links dynamically only against the OS:
#   macOS: /usr/lib + /System/Library (bundled in the .app, lipo-merged)
#   Linux: glibc (libc/libm/libpthread/libdl/librt) + zlib
#
# Usage: scripts/build-hacktv.sh [workdir]
# Output: <workdir>/out/hacktv-<arch>  and  <workdir>/out/testsignals/
#
# Requirements on PATH: curl, git, make, cmake, pkg-config (or pkgconf),
# and nasm on x86_64 (FFmpeg assembly).

set -euo pipefail

OS="$(uname -s)"     # Darwin | Linux
ARCH="$(uname -m)"   # arm64 | x86_64 | aarch64
case "$OS" in Darwin|Linux) ;; *) echo "unsupported OS: $OS" >&2; exit 1 ;; esac
WORK="${1:-$PWD/build-macos}"
WORK="$(mkdir -p "$WORK" && cd "$WORK" && pwd)"
SRC="$WORK/src"
PREFIX="$WORK/prefix-$ARCH"
OUT="$WORK/out"
if [ "$OS" = Darwin ]; then
	JOBS="$(sysctl -n hw.ncpu)"
	export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
	MINOS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
	# libusb's macOS backend needs these frameworks when linked statically
	USB_PRIVATE_LIBS="-Wl,-framework,IOKit -Wl,-framework,CoreFoundation -Wl,-framework,Security -lobjc"
	LIBUSB_CONF=""
	# FFmpeg uses iconv (subtitles); on macOS it is libiconv, not libSystem,
	# and FFmpeg's .pc files do not list it
	HACKTV_EXTRA_LIBS="-liconv"
	FFMPEG_PLATFORM="--enable-videotoolbox --enable-audiotoolbox --enable-avfoundation --enable-securetransport --enable-bzlib"
else
	JOBS="$(nproc)"
	MINOS=""
	USB_PRIVATE_LIBS="-lpthread"
	# Without udev, libusb enumerates via netlink/sysfs: no libudev runtime dependency
	LIBUSB_CONF="--disable-udev"
	HACKTV_EXTRA_LIBS=""
	# No TLS on Linux (would add an OpenSSL runtime dependency); online
	# streams go through yt-dlp, which handles TLS itself
	FFMPEG_PLATFORM=""
fi

sha256_check() { # <sha> <file>
	if command -v shasum >/dev/null 2>&1; then echo "$1  $2" | shasum -a 256 -c - >/dev/null
	else echo "$1  $2" | sha256sum -c - >/dev/null; fi
}
fsize() { wc -c < "$1" | tr -d ' '; }

# ---- Pinned sources (bump deliberately, together with the hashes) ----------
HACKTV_REPO="https://github.com/inaxeon/hacktv.git"
HACKTV_COMMIT="7a3e30564cd35feeb1c09d9f74cce6907d177a77"   # 20260223-7a3e305
HACKTV_VERSION_EXPECT="20260223-7a3e305"

LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v1.0.26/libusb-1.0.26.tar.bz2"
LIBUSB_SHA256="12ce7a61fc9854d1d2a1ffe095f7b5fac19ddba095c259e6067a46500381b5a5"

HACKRF_URL="https://github.com/greatscottgadgets/hackrf/releases/download/v2023.01.1/hackrf-2023.01.1.tar.xz"
HACKRF_SHA256="32a03f943a30be4ba478e94bf69f14a5b7d55be6761007f4a4f5453418206a11"

FL2K_URL="https://downloads.osmocom.org/releases/osmo-fl2k/osmo-fl2k-v0.2.1.tar.bz2"
FL2K_SHA256="8e6eb129c01d42cc715bb489894489e0c6e190880dac3587f63163828f4c5994"

FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz"
FFMPEG_SHA256="8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
# ---------------------------------------------------------------------------

log() { printf '\n==> %s\n' "$*"; }

need() {
	command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found on PATH" >&2; exit 1; }
}
need curl; need git; need make; need cmake; need pkg-config
[ "$ARCH" = "x86_64" ] && need nasm
[ "$OS" = Linux ] && need readelf

# fetch <url> <sha256>: download into $SRC (cached) and verify the hash
fetch() {
	local url="$1" sha="$2" file
	file="$SRC/$(basename "$url")"
	if [ ! -f "$file" ]; then
		curl -fsSL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	sha256_check "$sha" "$file" || {
		echo "error: sha256 mismatch for $file" >&2; rm -f "$file"; exit 1; }
	echo "$file"
}

mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$OUT"
log "Building hacktv for $OS $ARCH in $WORK"

# Keep pkg-config away from anything outside our prefix (Homebrew etc.)
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH


# ---- libusb 1.0.26 (static) -----------------------------------------------
if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
	log "libusb 1.0.26"
	f="$(fetch "$LIBUSB_URL" "$LIBUSB_SHA256")"
	rm -rf "$SRC/libusb-1.0.26" && tar -xjf "$f" -C "$SRC"
	( cd "$SRC/libusb-1.0.26" &&
	  CFLAGS="-O2 $MINOS" ./configure --prefix="$PREFIX" --enable-static --disable-shared $LIBUSB_CONF >/dev/null &&
	  make -j"$JOBS" install >/dev/null )
fi

# ---- libhackrf 2023.01.1 (static) -----------------------------------------
if [ ! -f "$PREFIX/lib/libhackrf.a" ]; then
	log "libhackrf 2023.01.1"
	f="$(fetch "$HACKRF_URL" "$HACKRF_SHA256")"
	rm -rf "$SRC/hackrf-2023.01.1" && tar -xJf "$f" -C "$SRC"
	b="$SRC/hackrf-2023.01.1/host/libhackrf/build"
	mkdir -p "$b"
	# CMAKE_POLICY_VERSION_MINIMUM: the 2023 release declares a CMake minimum
	# that current CMake (4.x) refuses; this only affects the build system.
	( cd "$b" &&
	  cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
	        ${MACOSX_DEPLOYMENT_TARGET:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"} \
	        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
	        -DLIBUSB_INCLUDE_DIR="$PREFIX/include/libusb-1.0" \
	        -DLIBUSB_LIBRARIES="$PREFIX/lib/libusb-1.0.a" >/dev/null &&
	  make -j"$JOBS" hackrf-static >/dev/null )
	mkdir -p "$PREFIX/include/libhackrf"
	cp "$b/src/libhackrf.a" "$PREFIX/lib/"
	cp "$SRC/hackrf-2023.01.1/host/libhackrf/src/hackrf.h" "$PREFIX/include/libhackrf/"
fi
# .pc points at the archives directly, so -lhackrf can never pick up a dylib
cat > "$PREFIX/lib/pkgconfig/libhackrf.pc" <<EOF
Name: libhackrf
Description: libhackrf 2023.01.1 (static)
Version: 2023.01.1
Libs: $PREFIX/lib/libhackrf.a $PREFIX/lib/libusb-1.0.a $USB_PRIVATE_LIBS
Cflags: -I$PREFIX/include/libhackrf
EOF

# ---- osmo-fl2k 0.2.1 (static, library only) --------------------------------
if [ ! -f "$PREFIX/lib/libosmo-fl2k.a" ]; then
	log "osmo-fl2k 0.2.1"
	f="$(fetch "$FL2K_URL" "$FL2K_SHA256")"
	rm -rf "$SRC/osmo-fl2k-v0.2.1" && tar -xjf "$f" -C "$SRC"
	d="$SRC/osmo-fl2k-v0.2.1"
	cc -O2 $MINOS -c "$d/src/libosmo-fl2k.c" \
	   -I"$d/include" -I"$PREFIX/include/libusb-1.0" -o "$d/libosmo-fl2k.o"
	ar rcs "$PREFIX/lib/libosmo-fl2k.a" "$d/libosmo-fl2k.o"
	cp "$d/include/osmo-fl2k.h" "$d/include/osmo-fl2k_export.h" "$PREFIX/include/"
fi
cat > "$PREFIX/lib/pkgconfig/libosmo-fl2k.pc" <<EOF
Name: libosmo-fl2k
Description: osmo-fl2k 0.2.1 (static)
Version: 0.2.1
Libs: $PREFIX/lib/libosmo-fl2k.a $PREFIX/lib/libusb-1.0.a $USB_PRIVATE_LIBS
Cflags: -I$PREFIX/include
EOF

# ---- FFmpeg 6.1.1 (static, OS libraries only) ------------------------------
if [ ! -f "$PREFIX/lib/libavformat.a" ]; then
	log "FFmpeg 6.1.1"
	f="$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")"
	rm -rf "$SRC/ffmpeg-6.1.1" && tar -xJf "$f" -C "$SRC"
	# --disable-autodetect stops FFmpeg linking whatever third-party libraries
	# happen to be installed on the build machine; OS-provided libraries
	# are then enabled explicitly.
	( cd "$SRC/ffmpeg-6.1.1" &&
	  ./configure --prefix="$PREFIX" --pkg-config=pkg-config \
	        --enable-static --disable-shared --enable-pic \
	        --disable-programs --disable-doc --disable-debug \
	        --disable-autodetect \
	        --enable-zlib --enable-iconv $FFMPEG_PLATFORM \
	        --extra-cflags="$MINOS" --extra-ldflags="$MINOS" \
	        > "$WORK/ffmpeg-configure-$ARCH.log" 2>&1 ||
	  { tail -40 "$WORK/ffmpeg-configure-$ARCH.log"; tail -40 ffbuild/config.log; exit 1; }
	  make -j"$JOBS" > "$WORK/ffmpeg-make-$ARCH.log" 2>&1 ||
	  { tail -60 "$WORK/ffmpeg-make-$ARCH.log"; exit 1; }
	  make install >/dev/null )
fi

# ---- hacktv (inaxeon fork, pinned, unmodified) -----------------------------
log "hacktv $HACKTV_COMMIT"
H="$SRC/hacktv"
if [ ! -d "$H/.git" ]; then
	git clone -q "$HACKTV_REPO" "$H"
fi
git -C "$H" fetch -q origin
git -C "$H" checkout -q --force "$HACKTV_COMMIT"
git -C "$H" submodule update --init --recursive -q
git -C "$H" clean -qfdx src
# The tree must be pristine: the version string must not say -dirty
if [ -n "$(git -C "$H" status --porcelain --ignore-submodules=none)" ]; then
	echo "error: hacktv source tree is not clean" >&2; git -C "$H" status --short; exit 1
fi

make -C "$H/src" -j"$JOBS" \
	PKGCONF="pkg-config --static" \
	EXTRA_CFLAGS="$MINOS" \
	EXTRA_LDFLAGS="$MINOS $HACKTV_EXTRA_LIBS" \
	> "$WORK/hacktv-make-$ARCH.log" 2>&1 || { tail -60 "$WORK/hacktv-make-$ARCH.log"; exit 1; }

BIN="$OUT/hacktv-$ARCH"
cp -f "$H/src/hacktv" "$BIN"
rm -rf "$OUT/testsignals" && mkdir -p "$OUT/testsignals"
cp "$H"/testsignals/*.bin "$OUT/testsignals/"

# ---- Verification ----------------------------------------------------------
log "Verifying $BIN"
fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

if [ "$OS" = Darwin ]; then
	[ "$(lipo -archs "$BIN")" = "$ARCH" ] || fail "architecture is $(lipo -archs "$BIN"), expected $ARCH"
	# Only system libraries may be linked dynamically
	bad="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)"
	[ -z "$bad" ] || fail "non-system dynamic libraries: $bad"
else
	m="$(readelf -h "$BIN" | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')"
	case "$ARCH:$m" in
		x86_64:*X86-64*|aarch64:*AArch64*) ;;
		*) fail "ELF machine '$m' does not match $ARCH" ;;
	esac
	# Only glibc and zlib may be linked dynamically
	bad="$(readelf -d "$BIN" | awk '/NEEDED/{gsub(/[\[\]]/,"",$5); print $5}' |
		grep -v -E '^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libz\.so\.1|ld-linux.*)$' || true)"
	[ -z "$bad" ] || fail "unexpected dynamic libraries: $bad"
	echo "glibc requirement: $(objdump -T "$BIN" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
fi

grep -q "HAVE_HACKRF" "$WORK/hacktv-make-$ARCH.log" || fail "built without HackRF support"
grep -q "HAVE_FL2K" "$WORK/hacktv-make-$ARCH.log" || fail "built without FL2K support"

v="$(strings -a "$BIN" | grep -E '^[0-9]{8}-[0-9a-f]{7}' | head -1)"
[ "$v" = "$HACKTV_VERSION_EXPECT" ] || fail "version string '$v', expected $HACKTV_VERSION_EXPECT"

"$BIN" --help 2>&1 | grep -q "Usage: hacktv" || fail "--help did not run"
[ "$(ls "$OUT/testsignals" | wc -l)" -ge 19 ] || fail "test signals missing"
[ "$(fsize "$OUT/testsignals/pm8546g.bin")" = "32768" ] || fail "pm8546g.bin is not 32768 bytes"

# Functional test: render PAL colour bars to a baseband file for ~2 seconds
# (perl alarm = portable timeout; hacktv does not trap SIGALRM)
t="$WORK/selftest-$ARCH.bin"; rm -f "$t"
( perl -e 'alarm shift; exec @ARGV' 2 "$BIN" -m pal -s 13500000 -o "$t" test >/dev/null 2>&1 ) 2>/dev/null || true
sz="$( [ -f "$t" ] && fsize "$t" || echo 0)"
[ "$sz" -gt 1000000 ] || fail "baseband self-test produced $sz bytes"
rm -f "$t"

[ "$OS" = Darwin ] && echo "minos: $(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
echo "OK: $BIN ($v, $OS $ARCH, self-test $sz bytes)"
