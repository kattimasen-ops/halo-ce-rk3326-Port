#!/usr/bin/env bash
set -euo pipefail
# ======================================================================
# Halo CE Universal - M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# Fix v23: _clang_builtin_shim-Block ENTFERNT.
#          Der vollständige clang-Resource-Include-Pfad verursachte
#          einen size_t-Konflikt mit musl. Der ursprüngliche Ansatz
#          (Shim-Ordner mit ARM-Headern) funktioniert.
# ======================================================================

PGO_MODE=${PGO_MODE:-use}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/cybersecurity/halo-ce-universal.git}
UPSTREAM_COMMIT=$(tr -d '[:space:]' < "$HERE/UPSTREAM_COMMIT")
PATCH=$HERE/patches/halo-ce-universal-knulli.patch
SDL3_TAG=release-3.2.10
SDL2_TAG=release-2.30.10
SDL2_ARCHIVE=https://github.com/libsdl-org/SDL/archive/refs/tags/$SDL2_TAG.tar.gz
GUEST_CC=${GUEST_CC:-clang-22}
HOST_CC=${HOST_CC:-aarch64-linux-gnu-gcc}
HOST_CXX=${HOST_CXX:-aarch64-linux-gnu-g++}
JOBS=${JOBS:-$(nproc)}
OPEN_CE_URL=${OPEN_CE_URL:-https://github.com/OpenCommunityEdition/OpenCE.git}

die() { echo "build.sh: $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "$1 not found: $2"; }

need git "install git"
need python3 "install python3"
need ninja "install ninja-build"
need curl "install curl"
need tar "install tar"
need cmake "install cmake"
need pkg-config "install pkg-config"
need "$HOST_CC" "install gcc-aarch64-linux-gnu, or set HOST_CC"
need "$HOST_CXX" "install g++-aarch64-linux-gnu, or set HOST_CXX"
need "$GUEST_CC" "install clang-22 from apt.llvm.org, or set GUEST_CC"

"$GUEST_CC" -print-targets 2> /dev/null | grep -q aarch64_32 ||
die "$GUEST_CC has no arm64_32 (aarch64_32) target; use clang 22 from apt.llvm.org"

[ -n "${ANDROID_NDK:-}" ] || die "set ANDROID_NDK to the Android NDK r28c folder"
[ -d "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64" ] || die "ANDROID_NDK=$ANDROID_NDK is not an Android NDK"
ANDROID_NDK=$(cd "$ANDROID_NDK" && pwd)

[ -n "${SYSROOT_LIB:-}" ] || die "set SYSROOT_LIB to the folder with the runtime libraries"
mkdir -p "$SYSROOT_LIB" 2>/dev/null || true
SYSROOT_LIB=$(cd "$SYSROOT_LIB" && pwd)

for module in libdrm gbm libudev; do
if ! pkg-config --exists "$module"; then
echo " FEHLT: $module"
exit 1
fi
done

for lib in /usr/aarch64-linux-gnu/lib/libdrm.so /usr/aarch64-linux-gnu/lib/libgbm.so; do
if [ ! -e "$lib" ]; then
die "Cross-aarch64 $lib fehlt. Der Multiarch-Schritt im Workflow legt ihn an."
fi
done

# ======================================================================
# libdrm-Include-Pfad ermitteln
# ======================================================================
LIBDRM_INCLUDE="/usr/include/libdrm"
if [ ! -d "$LIBDRM_INCLUDE" ]; then
  LIBDRM_CFLAGS=$(pkg-config --cflags libdrm 2>/dev/null || true)
  if [ -n "$LIBDRM_CFLAGS" ]; then
    FOUND_INC=$(echo "$LIBDRM_CFLAGS" | sed -n 's/.*-I\([^ ]*\).*/\1/p' | head -1)
    if [ -n "$FOUND_INC" ] && [ -d "$FOUND_INC" ]; then
      LIBDRM_INCLUDE="$FOUND_INC"
    fi
  fi
fi
echo "== LIBDRM_INCLUDE=$LIBDRM_INCLUDE"

if ! printf '%s' "$UPSTREAM_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
die "UPSTREAM_COMMIT='$UPSTREAM_COMMIT' ist kein 40-stelliger Hex-Hash"
fi

case "$PGO_MODE" in
use|off|train) ;;
*) die "PGO_MODE='$PGO_MODE' ungueltig; erlaubt: use, off, train" ;;
esac

echo "== Upstream: $UPSTREAM_URL @ $UPSTREAM_COMMIT"
echo "== PGO-Modus: $PGO_MODE"
( ldd --version 2>/dev/null || true ) | head -1 || true
echo "== Host-Compiler: $HOST_CC"
"$HOST_CC" --version 2>&1 | head -2 || true

WORK=${WORK:-$HERE/work}
DIST=${DIST:-$HERE/dist}
REJ=${REJ:-$HERE/rej}
mkdir -p "$WORK" "$DIST" "$REJ"
WORK=$(cd "$WORK" && pwd)
DIST=$(cd "$DIST" && pwd)
REJ=$(cd "$REJ" && pwd)

SRC=$WORK/halo-ce-universal

fetch_opence_files() {
local opence_dir="$WORK/opence-source"
local opence_tarball="$WORK/opence-main.tar.gz"

echo ""
echo "== Hole OpenCE-Dateien (Menue-System + Assets) ..."
rm -rf "$opence_dir"

if git clone --depth 1 "$OPEN_CE_URL" "$opence_dir" > /dev/null 2>&1; then
echo "   + Git-Clone erfolgreich."
else
rm -f "$opence_tarball"
if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
-o "$opence_tarball" \
"https://github.com/OpenCommunityEdition/OpenCE/archive/refs/heads/main.tar.gz"; then
die "Konnte OpenCE nicht klonen und auch nicht als Tarball laden."
fi
mkdir -p "$opence_dir"
if ! tar -xzf "$opence_tarball" -C "$opence_dir" --strip-components=1; then
die "Konnte OpenCE-Tarball nicht entpacken."
fi
echo "   + Tarball erfolgreich."
fi

mkdir -p "$SRC/port/linux/include" "$SRC/port/linux/src" \
"$SRC/port/linux/game" "$SRC/port/third_party"

for f in \
port/linux/include/halo_menus.h \
port/linux/include/halo_keyboard.h \
port/linux/src/menu_files.c \
port/linux/src/menu_files.h \
port/linux/game/menu_tags.c \
; do
if [ -f "$opence_dir/$f" ]; then
cp "$opence_dir/$f" "$SRC/$f"
echo "   + $f"
else
die "OpenCE hat $f nicht."
fi
done

for f in port/linux/src/hud_hires.c port/linux/src/hud_hires.h; do
if [ -f "$opence_dir/$f" ]; then
cp "$opence_dir/$f" "$SRC/$f"
echo "   + $f (OpenCE-Version)"
fi
done

if [ -d "$opence_dir/port/third_party/expat" ]; then
rm -rf "$SRC/port/third_party/expat"
cp -a "$opence_dir/port/third_party/expat" "$SRC/port/third_party/"
echo "   + port/third_party/expat/"
else
die "OpenCE hat keinen port/third_party/expat-Ordner."
fi

if [ -d "$opence_dir/port/third_party/zlib" ]; then
rm -rf "$SRC/port/third_party/zlib"
cp -a "$opence_dir/port/third_party/zlib" "$SRC/port/third_party/"
echo "   + port/third_party/zlib/"
else
die "OpenCE hat keinen port/third_party/zlib-Ordner."
fi

for t in tools/ce_menus.py tools/port_settings.py; do
if [ -f "$opence_dir/$t" ]; then
cp "$opence_dir/$t" "$SRC/$t"
echo "   + $t"
fi
done

if [ -f "$opence_dir/tools/embed_assets.py" ]; then
cp "$opence_dir/tools/embed_assets.py" "$SRC/tools/embed_assets.py"
echo "   + tools/embed_assets.py (OpenCE-Version)"
fi

if [ -d "$opence_dir/port/assets/menus" ]; then
rm -rf "$SRC/port/assets/menus"
mkdir -p "$SRC/port/assets"
cp -a "$opence_dir/port/assets/menus" "$SRC/port/assets/menus"
local count
count=$(find "$SRC/port/assets/menus/ce" -name "*.xml" 2>/dev/null | wc -l)
echo "   + port/assets/menus/ ($count XML-Dateien)"
else
die "OpenCE hat keinen port/assets/menus-Ordner."
fi

rm -rf "$opence_dir" "$opence_tarball"
echo "== OpenCE-Dateien geholt."
}

# -- XML-Hunk aus dem Knulli-Patch entfernen (idempotent) ------------
echo ""
echo "== Entferne den video_settings.xml-Hunk aus dem Knulli-Patch ..."
python3 - "$PATCH" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
pattern = re.compile(
    r'diff --git a/port/assets/menus/ce/'
    r'main_menu\.settings_select\.player_setup\.player_profile_edit\.'
    r'video_settings\.xml[^\n]*\n'
    r'(?:(?!diff --git ).)*',
    re.DOTALL,
)
if not pattern.search(text):
    print("  XML-Hunk war nicht vorhanden (bereits entfernt).")
    sys.exit(0)
new_text = pattern.sub('', text)
open(path, 'w').write(new_text)
print("  XML-Hunk entfernt; Patch ist jetzt %d Bytes kleiner." % (len(text) - len(new_text)))
PYEOF

# ======================================================================
# libdecor-0.so.0 (Stub fuer GLIBC 2.30 / ArkOS4Clone)
# ======================================================================
mkdir -p "$SYSROOT_LIB"
if [ ! -f "$SYSROOT_LIB/libdecor-0.so.0" ] || readelf -s "$SYSROOT_LIB/libdecor-0.so.0" 2>/dev/null | grep -q "GLIBC_2\.3[2-9]"; then
echo "== Kompiliere libdecor-0.so.0 Stub fuer Ubuntu 20.04 ..."
$HOST_CC -shared -fPIC -Wl,-soname,libdecor-0.so.0 -o "$SYSROOT_LIB/libdecor-0.so.0" -x c - <<'DECOR_EOF' || true
void libdecor_new(void) {}
void libdecor_unref(void) {}
DECOR_EOF
fi

# ======================================================================
# SDL3 (nur bauen, wenn .so fehlt)
# ======================================================================
if [ ! -f "$SYSROOT_LIB/libSDL3.so.0" ]; then
echo "== SDL3 $SDL3_TAG: kompiliere aus dem Quellcode (GCC, shared)"
SDL3_SRC=$WORK/SDL3-${SDL3_TAG#release-}
SDL3_BUILD=$WORK/sdl3-build
SDL3_INSTALL=$WORK/sdl3-install

if [ ! -d "$SDL3_SRC" ]; then
curl -L -o "$WORK/sdl3.tar.gz" \
"https://github.com/libsdl-org/SDL/releases/download/$SDL3_TAG/SDL3-${SDL3_TAG#release-}.tar.gz"
tar -xzf "$WORK/sdl3.tar.gz" -C "$WORK"
fi

echo "== SDL3 KMSDRM: libdrm-2.4.110-Kompatibilitaet anwenden"
python3 - "$SDL3_SRC/src/video/kmsdrm/SDL_kmsdrmsym.h" <<'KMSDRM_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "extern const char *drmModeGetConnectorTypeName" in text:
    print("  SDL3 KMSDRM: Kompatibilitaets-Deklaration bereits vorhanden.")
    sys.exit(0)
decl = (
    "/* SDL3 on libdrm < 2.4.112: drmModeGetConnectorTypeName fehlt in den\n"
    "   libdrm-Headern von Ubuntu 20.04 (2.4.110). Diese Deklaration\n"
    "   macht den Header fuer GCC gueltig; SDL3 laedt das Symbol zur\n"
    "   Laufzeit und akzeptiert ein fehlendes (SDL_KMSDRM_SYM_OPT). */\n"
    "extern const char *drmModeGetConnectorTypeName(uint32_t connector_type);\n"
    "\n"
)
text = decl + text
with open(path, 'w') as f:
    f.write(text)
print("  SDL3 KMSDRM: Kompatibilitaets-Deklaration hinzugefuegt.")
KMSDRM_EOF

rm -rf "$SDL3_BUILD" "$SDL3_INSTALL"
mkdir -p "$SDL3_BUILD" "$SDL3_INSTALL"

cmake -S "$SDL3_SRC" -B "$SDL3_BUILD" \
-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
-DCMAKE_C_COMPILER="$HOST_CC" \
-DCMAKE_CXX_COMPILER="$HOST_CXX" \
-DCMAKE_C_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_CXX_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
-DCMAKE_BUILD_TYPE=Release \
-DSDL_SHARED=ON -DSDL_STATIC=OFF \
-DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
-DSDL_INSTALL_TESTS=OFF -DSDL_WERROR=OFF -DSDL_UNIX_CONSOLE_BUILD=ON \
-DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON \
-DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
-DCMAKE_INSTALL_PREFIX="$SDL3_INSTALL"

cmake --build "$SDL3_BUILD" -j "$JOBS"
cmake --install "$SDL3_BUILD"

SDL3_LIB=$(find "$SDL3_INSTALL" -name "libSDL3.so.0*" -type f | head -n 1)
[ -n "$SDL3_LIB" ] || die "libSDL3.so.0 nicht gefunden"
cp -L "$SDL3_LIB" "$SYSROOT_LIB/libSDL3.so.0"
echo "== SDL3 kompiliert: $(stat -c%s "$SYSROOT_LIB/libSDL3.so.0") Bytes"
else
echo "== libSDL3.so.0 bereits vorhanden"
fi

# ======================================================================
# SDL2 mit KMSDRM + Pageflip-Patch
# ======================================================================
SDL2_SRC=$WORK/SDL2-src
SDL2_BUILD=$WORK/sdl2-build
SDL2_INSTALL=$WORK/sdl2-install

if [ -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
if command -v aarch64-linux-gnu-readelf >/dev/null 2>&1 && \
aarch64-linux-gnu-readelf -d "$SYSROOT_LIB/libSDL2-2.0.so.0" 2>/dev/null | grep -E -q "libX11|libpulse"; then
echo "== Inkompatible sysroot libSDL2 (X11/Pulse) erkannt, loesche und baue sauber neu..."
rm -f "$SYSROOT_LIB/libSDL2-2.0.so.0"
fi
fi

if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
echo "== SDL2 $SDL2_TAG: Quellcode holen und mit GCC bauen (shared)"
rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"

curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

echo "== SDL2 KMSDRM Pageflip-Patch fuer Mali-G31 anwenden"
python3 - "$SDL2_SRC/src/video/kmsdrm/SDL_kmsdrmopengles.c" <<'PATCH_EOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = (
    '    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,\n'
    'fb_info->fb_id, flip_flags, &windata->waiting_for_flip);\n'
    'if (ret == 0) {\n'
    'windata->waiting_for_flip = SDL_TRUE;\n'
    '} else {\n'
    'SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);\n'
    '}'
)
new = (
    '    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,\n'
    'fb_info->fb_id, flip_flags, &windata->waiting_for_flip);\n'
    'if (ret != 0 && (flip_flags & DRM_MODE_PAGE_FLIP_ASYNC)) {\n'
    'viddata->async_pageflip_support = SDL_FALSE;\n'
    'flip_flags &= ~DRM_MODE_PAGE_FLIP_ASYNC;\n'
    'ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,\n'
    'fb_info->fb_id, flip_flags, &windata->waiting_for_flip);\n'
    'if (ret == 0) {\n'
    'SDL_LogInfo(SDL_LOG_CATEGORY_VIDEO,\n'
    '"Async pageflip rejected by the driver; using synchronous flips.");\n'
    '}\n'
    '}\n'
    'if (ret == 0) {\n'
    'windata->waiting_for_flip = SDL_TRUE;\n'
    '} else {\n'
    'SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);\n'
    '}'
)
if old not in text:
    pattern = re.compile(
        r'(ret = KMSDRM_drmModePageFlip\(viddata->drm_fd, dispdata->crtc->crtc_id,\s*'
        r'\s*fb_info->fb_id, flip_flags, &windata->waiting_for_flip\);\s*'
        r'\s*if \(ret == 0\) \{\s*'
        r'\s*windata->waiting_for_flip = SDL_TRUE;\s*'
        r'\s*\} else \{\s*'
        r'\s*SDL_LogError\(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret\);\s*'
        r'\s*\})'
    )
    match = pattern.search(text)
    if not match:
        print("FEHLER: Pageflip-Code nicht gefunden", file=sys.stderr)
        sys.exit(1)
    text = text[:match.start()] + new + text[match.end():]
else:
    text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("SDL2 KMSDRM Pageflip-Patch angewendet")
PATCH_EOF

cmake -S "$SDL2_SRC" -B "$SDL2_BUILD" \
-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
-DCMAKE_C_COMPILER="$HOST_CC" \
-DCMAKE_CXX_COMPILER="$HOST_CXX" \
-DCMAKE_C_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_CXX_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
-DCMAKE_BUILD_TYPE=Release \
-DSDL_SHARED=ON -DSDL_STATIC=OFF \
-DSDL_TESTS=OFF \
-DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON \
-DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
-DCMAKE_INSTALL_PREFIX="$SDL2_INSTALL"

cmake --build "$SDL2_BUILD" -j "$JOBS"
cmake --install "$SDL2_BUILD"

SDL2_LIB=$(find "$SDL2_INSTALL" -name "libSDL2-2.0.so.0*" -type f | head -n 1)
[ -n "$SDL2_LIB" ] || die "libSDL2-2.0.so.0 nicht gefunden"
cp -L "$SDL2_LIB" "$SYSROOT_LIB/libSDL2-2.0.so.0"
echo "== SDL2 nach sysroot kopiert: $(stat -c%s "$SYSROOT_LIB/libSDL2-2.0.so.0") Bytes"
else
echo "== libSDL2-2.0.so.0 bereits in sysroot"
fi

if [ ! -d "$SDL2_INSTALL/include/SDL2" ]; then
echo "== SDL2-Header fehlen, SDL2 neu bauen ..."
rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"

curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

cmake -S "$SDL2_SRC" -B "$SDL2_BUILD" \
-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
-DCMAKE_C_COMPILER="$HOST_CC" \
-DCMAKE_CXX_COMPILER="$HOST_CXX" \
-DCMAKE_C_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_CXX_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -I$LIBDRM_INCLUDE" \
-DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
-DCMAKE_BUILD_TYPE=Release \
-DSDL_SHARED=ON -DSDL_STATIC=OFF \
-DSDL_TESTS=OFF \
-DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON \
-DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
-DCMAKE_INSTALL_PREFIX="$SDL2_INSTALL"

cmake --build "$SDL2_BUILD" -j "$JOBS"
cmake --install "$SDL2_BUILD"
fi

export SDL2_INCLUDE="$SDL2_INSTALL/include"
[ -f "$SDL2_INCLUDE/SDL2/SDL.h" ] || die "SDL2_INCLUDE=$SDL2_INCLUDE enthaelt kein SDL2/SDL.h"
echo "== SDL2_INCLUDE=$SDL2_INCLUDE"

export SDL2_LIB_DIR="$SDL2_INSTALL/lib"
echo "== SDL2_LIB_DIR=$SDL2_LIB_DIR"

# ======================================================================
# Upstream klonen + Knulli-Patch + OpenCE-Dateien
# ======================================================================
if [ ! -d "$SRC/.git" ]; then
echo "== Klone Upstream in $SRC ..."
git init -q "$SRC"
git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi

if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
echo "== fetching $UPSTREAM_COMMIT"
git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" ||
git -C "$SRC" fetch -q origin
fi

git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null ||
die "commit $UPSTREAM_COMMIT not in $UPSTREAM_URL"

tree_is_patched() {
[ "$(git -C "$SRC" rev-parse HEAD 2> /dev/null || true)" = "$UPSTREAM_COMMIT" ] &&
cmp -s <(git -C "$SRC" diff HEAD | grep -v '^index ') <(grep -v '^index ' "$PATCH")
}

if ! tree_is_patched; then
echo ""
echo "== Setze Upstream auf $UPSTREAM_COMMIT zurueck ..."
git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
git -C "$SRC" reset -q --hard
git -C "$SRC" clean -q -fd -e work -e dist -e rej

fetch_opence_files

echo ""
echo "== Pruefe und wende Knulli-Patch an ..."
if ! git -C "$SRC" apply --check "$PATCH" 2>&1; then
die "Knulli-Patch kann auf $UPSTREAM_COMMIT NICHT sauber angewendet werden."
fi
git -C "$SRC" apply "$PATCH"
git -C "$SRC" apply --summary "$PATCH" | awk '$1 == "create" { print $4 }' | xargs -r git -C "$SRC" add -N --
echo "== Knulli-Patch angewendet."

echo ""
echo "== Kopiere menu_functions.c und port_settings_shim.c (NACH dem Patch) ..."
if [ -f "$HERE/patches/settings_only_menu_functions.c" ]; then
cp "$HERE/patches/settings_only_menu_functions.c" \
"$SRC/port/linux/game/menu_functions.c"
echo "   + menu_functions.c (settings-only)"
else
die "patches/settings_only_menu_functions.c fehlt."
fi

if [ -f "$HERE/patches/port_settings_shim.c" ]; then
cp "$HERE/patches/port_settings_shim.c" \
"$SRC/port/linux/game/port_settings_shim.c"
echo "   + port_settings_shim.c"
else
die "patches/port_settings_shim.c fehlt."
fi

echo ""
echo "== Fuege menu_files.c Forward-Deklarationen hinzu ..."
python3 - "$SRC/port/linux/src/menu_files.c" <<'PYEOF'
import sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print("   [WARN] %s nicht gefunden." % path)
    sys.exit(0)
with open(path) as f:
    text = f.read()
if "extern void config_folder" in text and "extern void xgpu_gl_texture_deleted" in text:
    print("   + menu_files.c: Forward-Deklarationen bereits vorhanden.")
    sys.exit(0)
decl = (
    "/* Forward-Deklarationen fuer Host-Funktionen, die menu_files.c\n"
    "   aufruft, deren Header im Guest-Build aber nicht eingebunden wird. */\n"
    "#ifdef HALO_ARM64_GUEST\n"
    "#ifndef MENU_FILES_HOST_FUNCS_DECLARED\n"
    "#define MENU_FILES_HOST_FUNCS_DECLARED\n"
    "extern void config_folder(char *folder, unsigned int size);\n"
    "extern void xgpu_gl_texture_deleted(unsigned int texture);\n"
    "#endif\n"
    "#endif\n"
)
text = decl + "\n" + text
with open(path, "w") as f:
    f.write(text)
print("   + menu_files.c: Forward-Deklarationen eingefuegt.")
PYEOF

echo ""
echo "== Setze Menue-Hooks und Build-Registrierung ..."
if [ -f "$HERE/patches/patch_settings_only.py" ]; then
python3 "$HERE/patches/patch_settings_only.py" "$SRC" "$HERE/patches"
else
die "patches/patch_settings_only.py fehlt."
fi

echo ""
echo "== Patch android_build.py (Expat/Zlib/HALO_ARM64_GUEST) ..."
if [ -f "$HERE/patches/patch_android_build_hybrid.py" ]; then
python3 "$HERE/patches/patch_android_build_hybrid.py" "$SRC"
else
die "patches/patch_android_build_hybrid.py fehlt."
fi

echo ""
echo "== Fuege fehlende C-Funktionen hinzu ..."
if [ -f "$HERE/patches/patch_missing_functions.py" ]; then
python3 "$HERE/patches/patch_missing_functions.py" "$SRC"
else
die "patches/patch_missing_functions.py fehlt."
fi

echo ""
echo "== Kopiere guest_host_stubs.c nach port/linux/src/ ..."
if [ -f "$HERE/patches/guest_host_stubs.c" ]; then
cp "$HERE/patches/guest_host_stubs.c" "$SRC/port/linux/src/guest_host_stubs.c"
echo "   + guest_host_stubs.c"
else
die "patches/guest_host_stubs.c fehlt."
fi
fi

# ======================================================================
# PGO
# ======================================================================
PGO_FLAG="--pgo=off"
PGO_EXTRA_ARGS=""
LTO_FLAG="--lto=full"

if [ "$PGO_MODE" = "use" ]; then
LOCAL_PGO="$HERE/pgo/halo_linux.profdata"
PGO_LINUX_URL="https://raw.githubusercontent.com/cybersecurity/halo-ce-universal/main/pgo/halo_linux.profdata"
PGO_FALLBACK_URL="https://raw.githubusercontent.com/Andiweli/HaloCE-Android-AAOS/main/pgo/halo_linux.profdata"

if [ -f "$LOCAL_PGO" ]; then
echo "== PGO: use (lokales Linux-Profil)"
PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $LOCAL_PGO"
elif curl -fsSL --retry 2 --connect-timeout 30 -o "$WORK/halo_linux.profdata" "$PGO_LINUX_URL" 2>/dev/null; then
echo "== PGO: use (Upstream-Linux-Profil)"
PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
elif curl -fsSL --retry 2 --connect-timeout 30 -o "$WORK/halo_linux.profdata" "$PGO_FALLBACK_URL" 2>/dev/null; then
echo "== PGO: use (Fallback)"
PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
else
echo "== PGO: kein Profil gefunden, --pgo=off"
PGO_FLAG="--pgo=off"
fi
elif [ "$PGO_MODE" = "off" ]; then
echo "== PGO: aus"
elif [ "$PGO_MODE" = "train" ]; then
echo "== PGO: Trainings-Build (kein LTO)"
LTO_FLAG="--lto=off"
fi

# ======================================================================
# Fix 1: APCs in xbox_kernel.c
# ======================================================================
python3 - "$SRC/port/linux/src/xbox_kernel.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()

wait_old = (
    '\tif (milliseconds == INFINITE)\n'
    '\t\t{\n'
    '\t\t\tpthread_cond_wait(&handle->condition, &handle->lock);\n'
    '\t\t}\n'
    '\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)\n'
    '\t\t{\n'
    '\t\t\tif (!handle_try_acquire(handle))\n'
    '\t\t\t\tresult = WAIT_TIMEOUT;\n'
    '\t\t\tbreak;\n'
    '\t\t}'
)
wait_new = (
    '\tif (alertable && platform_run_apcs())\n'
    '\t\t{\n'
    '\t\t\tpthread_mutex_unlock(&handle->lock);\n'
    '\t\t\treturn WAIT_IO_COMPLETION;\n'
    '\t\t}\n'
    '\t\tif (milliseconds == INFINITE)\n'
    '\t\t{\n'
    '\t\t\tstruct timespec short_wait;\n'
    '\t\t\tclock_gettime(CLOCK_REALTIME, &short_wait);\n'
    '\t\t\tshort_wait.tv_nsec += 10000000;\n'
    '\t\t\tif (short_wait.tv_nsec >= 1000000000L)\n'
    '\t\t\t{\n'
    '\t\t\t\tshort_wait.tv_sec++;\n'
    '\t\t\t\tshort_wait.tv_nsec -= 1000000000L;\n'
    '\t\t\t}\n'
    '\t\t\tpthread_cond_timedwait(&handle->condition, &handle->lock, &short_wait);\n'
    '\t\t}\n'
    '\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)\n'
    '\t\t{\n'
    '\t\t\tif (alertable && platform_run_apcs())\n'
    '\t\t\t{\n'
    '\t\t\t\tpthread_mutex_unlock(&handle->lock);\n'
    '\t\t\t\treturn WAIT_IO_COMPLETION;\n'
    '\t\t\t}\n'
    '\t\t\tif (!handle_try_acquire(handle))\n'
    '\t\t\t\tresult = WAIT_TIMEOUT;\n'
    '\t\t\tbreak;\n'
    '\t\t}'
)
if wait_old not in text:
    print("WARNUNG: WaitForSingleObjectEx-Muster nicht gefunden.")
else:
    text = text.replace(wait_old, wait_new, 1)

sleep_old = (
    '\tif (milliseconds == INFINITE)\n'
    '\t{\n'
    '\t\tfor (;;)\n'
    '\t\t\tpause();\n'
    '\t}\n'
    '\tduration.tv_sec = milliseconds / 1000;\n'
    '\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;\n'
    '\twhile (nanosleep(&duration, &duration) == -1 && errno == EINTR)\n'
    '\t\t;\n'
    '\tif (alertable && platform_run_apcs())\n'
    '\t\treturn WAIT_IO_COMPLETION;\n'
    '\treturn 0;'
)
sleep_new = (
    '\tif (milliseconds == INFINITE)\n'
    '\t{\n'
    '\t\tfor (;;)\n'
    '\t\t{\n'
    '\t\t\tif (alertable && platform_run_apcs())\n'
    '\t\t\t\treturn WAIT_IO_COMPLETION;\n'
    '\t\t\tpause();\n'
    '\t\t}\n'
    '\t}\n'
    '\tduration.tv_sec = milliseconds / 1000;\n'
    '\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;\n'
    '\twhile (duration.tv_sec > 0 || duration.tv_nsec > 0)\n'
    '\t{\n'
    '\t\tstruct timespec step;\n'
    '\t\tstep.tv_sec = duration.tv_sec > 0 ? 1 : 0;\n'
    '\t\tstep.tv_nsec = duration.tv_sec > 0 ? 0 : (duration.tv_nsec > 10000000L ? 10000000L : duration.tv_nsec);\n'
    '\t\tif (nanosleep(&step, NULL) == -1 && errno != EINTR)\n'
    '\t\t\tbreak;\n'
    '\t\tif (step.tv_sec == 0 && step.tv_nsec == 10000000L)\n'
    '\t\t\tduration.tv_nsec -= 10000000L;\n'
    '\t\telse if (step.tv_sec == 1)\n'
    '\t\t\tduration.tv_sec--;\n'
    '\t\telse\n'
    '\t\t\tduration.tv_nsec = 0;\n'
    '\t\tif (alertable && platform_run_apcs())\n'
    '\t\t\treturn WAIT_IO_COMPLETION;\n'
    '\t}\n'
    '\treturn 0;'
)
if sleep_old not in text:
    print("WARNUNG: SleepEx-Muster nicht gefunden.")
else:
    text = text.replace(sleep_old, sleep_new, 1)

with open(path, 'w') as f:
    f.write(text)
print("xbox_kernel.c geprueft")
PYEOF

# ======================================================================
# Fix 2: android_build.py - Compiler-Flags
# ======================================================================
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()

old_mcpu = '"-mcpu=cortex-a53"'
new_mcpu = '"-mcpu=cortex-a35",\n"-mtune=cortex-a35"'
if text.count(old_mcpu) > 0:
    text = text.replace(old_mcpu, new_mcpu)
    print("android_build.py: mcpu=cortex-a53 -> cortex-a35")

old_flags = '"-ffp-contract=off",\n"-O2",'
new_flags = (
    '"-ffp-contract=off",\n'
    '"-O3",\n'
    '"-fomit-frame-pointer",\n'
    '"-funroll-loops",\n'
    '"-fno-math-errno",\n'
    '"-fno-trapping-math",\n'
    '"-fmerge-all-constants",\n'
    '"-fno-strict-aliasing",'
)
if old_flags in text:
    text = text.replace(old_flags, new_flags, 1)
    print("android_build.py: O2 -> O3 + Flags")

if '"-fno-omit-frame-pointer"' in text:
    text = text.replace('    "-fno-omit-frame-pointer",\n', '')

with open(path, 'w') as f:
    f.write(text)
PYEOF

python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if '"-DHALO_ANDROID"' in text:
    sys.exit(0)
anchor = '"-DHALO_RELEASE"'
if anchor in text:
    text = text.replace(anchor, '"-DHALO_ANDROID",\n"-DHALO_RELEASE"', 1)
with open(path, 'w') as f:
    f.write(text)
print("android_build.py: -DHALO_ANDROID")
PYEOF

# ======================================================================
# Fix v23: _clang_builtin_shim-Block ENTFERNT
# ======================================================================
# Der ursprüngliche _clang_builtin_shim in android_build.py (aus build 30)
# kopierte nur 5 ARM-Header in einen Shim-Ordner und gab diesen zurück.
# Das funktionierte. Der neue Block, der den kompletten Resource-Pfad
# zurückgab, verursachte einen size_t-Konflikt mit musl.
# → Block entfernt, ursprünglicher Ansatz bleibt aktiv.

if [ "$PGO_MODE" = "train" ]; then
python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-fprofile-instr-generate" in text:
    sys.exit(0)
for old in ('"-O3",', '"-O3"'):
    if old in text:
        text = text.replace(old, old.replace('"-O3"', '"-O3",\n"-fprofile-instr-generate"'), 1)
with open(path, 'w') as f:
    f.write(text)
print("android_build.py: -fprofile-instr-generate")
sys.exit(0)
PYEOF

python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "guest_profile_runtime" in text:
    sys.exit(0)
old = (
    '    n.rule(\n'
    '        name="android_guest_link",\n'
    '        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "\n'
    '                 f"-Map $out.map -o $out @$out.rsp {libguestc} "\n'
    '                 "$$($android_host_cc -print-libgcc-file-name)"),'
)
new = (
    '    guest_profile_runtime = ""\n'
    '    for _cc_candidate in (guest_cc, str(ndk_bin / "clang")):\n'
    '        if not _cc_candidate:\n'
    '            continue\n'
    '        try:\n'
    '            _rd = subprocess.run([_cc_candidate, "-print-resource-dir"],\n'
    '                                 capture_output=True, text=True, check=True).stdout.strip()\n'
    '        except Exception:\n'
    '            continue\n'
    '        for _name in ("libclang_rt.profile-aarch64-android.a", "libclang_rt.profile-aarch64.a"):\n'
    '            _candidate = Path(_rd) / "lib" / "linux" / _name\n'
    '            if _candidate.is_file():\n'
    '                guest_profile_runtime = str(_candidate)\n'
    '                print(f"== profile runtime: {guest_profile_runtime}")\n'
    '                break\n'
    '        if guest_profile_runtime:\n'
    '            break\n'
    '\n'
    '    n.rule(\n'
    '        name="android_guest_link",\n'
    '        command=(f"$android_ndk_bin/ld.lld -m aarch64linux -static -nostdlib -T {linker_script} "\n'
    '                 f"-Map $out.map -o $out @$out.rsp {libguestc} {guest_profile_runtime} "\n'
    '                 "$$($android_host_cc -print-libgcc-file-name)"),'
)
if old in text:
    text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("android_build.py: Profiling-Runtime zum Link")
PYEOF
fi

# ======================================================================
# Fix 3: linux_build.py - nur Compiler-Flags
# ======================================================================
python3 - "$SRC/tools/linux_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if 'OPTIMISATION = "-O3"' not in text:
    text = text.replace('OPTIMISATION = "-O2"', 'OPTIMISATION = "-O3"')
old_abi = '"-ffp-contract=off",\nOPTIMISATION,'
new_abi = (
    '"-ffp-contract=off",\n'
    '"-funroll-loops",\n'
    '"-fno-math-errno",\n'
    '"-fno-trapping-math",\n'
    '"-fmerge-all-constants",\n'
    '"-fno-strict-aliasing",\n'
    'OPTIMISATION,'
)
if old_abi in text:
    text = text.replace(old_abi, new_abi, 1)
with open(path, "w") as f:
    f.write(text)
print("linux_build.py geprueft")
PYEOF

# ======================================================================
# port/knulli kopieren
# ======================================================================
echo ""
echo "== Kopiere port/knulli in den Quellbaum ..."
if [ ! -d "$HERE/port/knulli" ]; then
die "port/knulli/ existiert nicht im Repo"
fi
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"
chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true

# ======================================================================
# DIAGNOSE: Logging in host_glthread.c einfuegen
# ======================================================================
if [ -f "$HERE/patches/patch_gl_init_order.py" ]; then
echo ""
echo "== DIAGNOSE: Logging in host_glthread.c einfuegen ..."
python3 "$HERE/patches/patch_gl_init_order.py" "$SRC" || \
echo "WARNUNG: patch_gl_init_order.py fehlgeschlagen."
else
echo ""
echo "WARNUNG: patches/patch_gl_init_order.py fehlt - Diagnose uebersprungen!"
fi

# ======================================================================
# Restliche Python-Patches
# ======================================================================
echo ""
echo "== Wende restliche Patch-Skripte an ..."
for patch_script in \
patch_opence_menu_cache_hooks.py \
patch_memory_pools.py patch_neon_math.py \
patch_vita_optimizations.py patch_button_remap.py \
patch_index_extent_neon.py patch_fps_overlay.py \
patch_draw_framebuffer_bound.py patch_mali_subdata.py \
patch_shader_prewarm.py patch_aggressive_culling.py \
patch_state_batching.py patch_texture_prewarm.py \
patch_settings_menu.py patch_config_defaults.py \
patch_credits.py patch_forward_declarations.py \
patch_config_changes.py patch_terminal_buffer.py; do
if [ -f "$HERE/patches/$patch_script" ]; then
echo "== $patch_script"
if ! python3 "$HERE/patches/$patch_script" "$SRC"; then
echo "WARNUNG: $patch_script fehlgeschlagen"
fi
fi
done

if [ -f "$SRC/port/linux/src/d3d8_gl.c" ]; then
python3 - "$SRC/port/linux/src/d3d8_gl.c" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "fps_overlay_enabled" not in text:
    sys.exit(0)
pattern = re.compile(r'glUniform4f\(\s*fps_overlay_color\s*,\s*([^;]+?)\s*\)\s*;')
new_text = pattern.sub(
    lambda m: '{ const float overlay_color[4] = { ' + m.group(1).strip() + ' }; '
              'glUniform4fv(fps_overlay_color, 1, overlay_color); }',
    text)
if new_text != text:
    with open(path, "w") as f:
        f.write(new_text)
    print("d3d8_gl.c: glUniform4f -> glUniform4fv")
PYEOF
fi

echo ""
echo "== Regeneriere die In-Game-Settings-Menues ..."
python3 - "$SRC" <<'PYEOF'
import os, sys
src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))
try:
    import port_settings
except ImportError as e:
    print("  HINWEIS: port_settings.py nicht importierbar (%s)." % e)
    sys.exit(0)
if not hasattr(port_settings, "settings_files"):
    sys.exit(0)
files = port_settings.settings_files()
target_dir = os.path.join(src, "port", "assets", "menus", "ce")
os.makedirs(target_dir, exist_ok=True)
for name, lines in files.items():
    path = os.path.join(target_dir, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print("  geschrieben: %s" % name)
PYEOF

if [ -f "$HERE/patches/patch_credits_xml.py" ]; then
echo ""
echo "== Credits-Wasserzeichen in Menue-XMLs ..."
python3 "$HERE/patches/patch_credits_xml.py" "$SRC"
fi

# ======================================================================
# Verifikation
# ======================================================================
echo ""
echo "== Verifiziere Patch-Ergebnisse ..."
verification_failed=0

check_patch() {
local file="$1" pattern="$2" name="$3"
if grep -q -- "$pattern" "$SRC/$file" 2>/dev/null; then
echo "   OK: $name"
else
echo "   FEHLT: $name ($file)"
verification_failed=1
fi
}

check_file() {
local file="$1" name="$2"
if [ -f "$SRC/$file" ]; then
echo "   OK: $name"
else
echo "   FEHLT: $name ($file)"
verification_failed=1
fi
}

check_patch "source/cseries/cseries.h"          "HALO_DEBUG_ALLOCATOR"          "cseries.h Debug-Allocator"
check_patch "source/effects/decals.c"           "static __thread long surface_queue" "decals.c __thread"
check_patch "source/math/matrix_math.c"         "vmulq_n_f32"                   "matrix_math.c NEON"
check_patch "source/sound/game_sound.c"         "obstruction_interval_value"    "game_sound.c Sound"
check_patch "source/render/render_objects.c"    "HALO_MIN_OBJECT_PIXELS"        "render_objects.c Distant"
check_patch "source/render/render_objects.c"    "HALO_LIGHTING_REFRESH_DIVISOR" "render_objects.c Lighting"
check_patch "source/render/render_objects.c"    "aggressive_culling_guard"      "render_objects.c Culling"
check_patch "port/linux/src/port_config.c"      "HALO_SOUND_OBSTRUCTION_TICKS"  "port_config.c Sound"
check_patch "port/linux/src/port_config.c"      "HALO_MIN_OBJECT_PIXELS"        "port_config.c Distant"
check_patch "port/linux/src/port_config.c"      "HALO_LIGHTING_REFRESH_DIVISOR" "port_config.c Lighting"
check_patch "port/linux/src/port_config.c"      "HALO_FPS_OVERLAY_CORNER"       "port_config.c FPS"
check_patch "port/linux/src/port_config.c"      "HALO_FAST_SHADERS"             "port_config.c Knulli"
check_patch "port/linux/src/port_config.c"      "settings_only: config_changes_impl" "port_config.c config_changes()"
check_patch "port/linux/src/hud_hires.c"        "settings_only: config_changes_hud"  "hud_hires.c config_changes decl"
check_patch "port/linux/src/xinput_sdl.c"       "button_remap"                  "xinput_sdl.c Remap"
check_patch "port/linux/src/d3d8_gl.c"          "__builtin_elementwise_min"     "d3d8_gl.c index_extent"
check_patch "port/linux/src/d3d8_gl.c"          "fps_overlay_enabled"           "d3d8_gl.c FPS-Overlay"
check_patch "port/linux/src/d3d8_gl.c"          "mali_subdata_guard"            "d3d8_gl.c Mali-Subdata"
check_patch "port/linux/src/d3d8_gl.c"          "shader_prewarm_guard"          "d3d8_gl.c Shader-Prewarm"
check_patch "port/linux/src/d3d8_gl.c"          "state_batching_guard"          "d3d8_gl.c State-Batching"
check_patch "port/linux/src/d3d8_gl.c"          "shader_prewarm_fwd_decl"       "d3d8_gl.c Fwd-Decl"
check_patch "port/linux/src/d3d8_gl.c"          "xgpu_gl_texture_deleted"       "d3d8_gl.c xgpu_gl_texture_deleted"
check_patch "port/linux/src/xgpu.h"             "xgpu_gl_texture_deleted"       "xgpu.h xgpu_gl_texture_deleted decl"
check_patch "port/linux/src/xbox_textures.c"    "texture_prewarm_guard"         "xbox_textures.c Prewarm"
check_patch "tools/android_build.py"            '"-DHALO_ANDROID"'              "android_build.py HALO_ANDROID"
check_patch "tools/android_build.py"            '"-DHALO_ARM64_GUEST=1"'        "android_build.py HALO_ARM64_GUEST"
check_patch "tools/android_build.py"            'EXPAT_DIR = Path'              "android_build.py EXPAT_DIR"
check_patch "tools/android_build.py"            'ZLIB_DIR = Path'               "android_build.py ZLIB_DIR"
check_patch "source/main/main.c"                "St0len-One"                    "main.c Credits"
check_file  "port/linux/include/halo_menus.h"                                   "halo_menus.h"
check_file  "port/linux/src/menu_files.c"                                       "menu_files.c"
check_file  "port/linux/game/menu_tags.c"                                       "menu_tags.c"
check_file  "port/linux/game/menu_functions.c"                                  "menu_functions.c"
check_file  "port/linux/game/port_settings_shim.c"                              "port_settings_shim.c"
check_file  "port/linux/src/guest_host_stubs.c"                                 "guest_host_stubs.c"
check_file  "port/third_party/expat/expat.h"                                    "expat.h"
check_file  "port/third_party/zlib/zlib_prefixed.h"                             "zlib_prefixed.h (OpenCE)"
check_file  "port/linux/src/hud_hires.c"                                        "hud_hires.c (OpenCE)"
check_file  "port/linux/src/hud_hires.h"                                        "hud_hires.h (OpenCE)"
check_patch "source/interface/ui_widget.c"      "pc_menu_tag"                   "ui_widget.c pc_menu_tag extern"
check_patch "source/interface/ui_widget_event_handler_functions.c" "PC_MENU_FUNCTION_BASE" "ui_widget_event_handler_functions.c Dispatcher"
check_patch "source/interface/ui_widget_event_handler_functions.c" "PC_MENU_FUNCTION_TOP" "ui_widget_event_handler_functions.c Bereichs-Obergrenze"
check_patch "source/interface/ui_widget_event_handler_functions.c" "ui_widget_event_handler_function_name" "ui_widget_event_handler_functions.c function_name"
check_patch "source/cache/cache_files.c"        "cache_files_tag_instances"     "cache_files.c cache_files_tag_instances"
check_patch "source/cache/cache_files.c"        "menu_tags_loaded"              "cache_files.c Menue-Hooks"
check_patch "port/linux/src/menu_files.c"       "MENU_FILES_HOST_FUNCS_DECLARED" "menu_files.c Forward-Deklarationen"

if [ -f "$HERE/patches/patch_gl_init_order.py" ]; then
check_patch "port/knulli/host/host_glthread.c" "DIAG: sync-create ENTER" "host_glthread.c DIAG-Logs eingefuegt"
fi

if grep -q "settings_only: game data dispatcher" \
"$SRC/source/interface/ui_widget_game_data_input_functions.c" 2>/dev/null; then
echo "   OK: ui_widget_game_data_input_functions.c Dispatcher"
else
echo "   HINWEIS: ui_widget_game_data_input_functions.c Dispatcher fehlt (nicht kritisch)."
fi

if [ -f "$SRC/tools/port_settings.py" ]; then
check_patch "tools/port_settings.py" "display.fast_shaders"  "port_settings.py Video-Rows"
fi

if [ "$verification_failed" -ne 0 ]; then
echo ""
echo "== Verifikation meldete Fehler, fahre trotzdem fort."
fi

echo "== Verifikation abgeschlossen."

# ======================================================================
# CPATH
# ======================================================================
CPATH_GUEST="$SRC/port/third_party/expat/lib:$SRC/port/third_party/expat:$SRC/port/third_party/zlib"
export CPATH="$CPATH_GUEST${CPATH:+:$CPATH}"
echo "== CPATH=$CPATH"

# ======================================================================
# Stamp
# ======================================================================
stamp=$({
cat "$PATCH"
for p in patch_opence_menu_cache_hooks.py \
patch_memory_pools.py patch_neon_math.py \
patch_vita_optimizations.py patch_button_remap.py \
patch_index_extent_neon.py patch_fps_overlay.py \
patch_draw_framebuffer_bound.py patch_mali_subdata.py \
patch_shader_prewarm.py patch_aggressive_culling.py \
patch_state_batching.py patch_texture_prewarm.py \
patch_settings_menu.py patch_config_defaults.py \
patch_credits.py patch_credits_xml.py \
patch_forward_declarations.py patch_settings_only.py \
patch_android_build_hybrid.py patch_missing_functions.py \
patch_config_changes.py patch_terminal_buffer.py \
patch_gl_init_order.py \
settings_only_menu_functions.c port_settings_shim.c \
guest_host_stubs.c; do
cat "$HERE/patches/$p" 2>/dev/null || true
done
[ -f "$HERE/pgo/halo_linux.profdata" ] && sha256sum "$HERE/pgo/halo_linux.profdata" | cut -d' ' -f1
echo "pgo-mode=$PGO_MODE"
echo "gcc9-host-dynamic=v23-clang-builtin-shim-removed"
(cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 cat)
} | sha256sum | cut -d' ' -f1)

echo "$stamp" > "$SRC/.port-stamp"

# ======================================================================
# Build
# ======================================================================
export ANDROID_NDK SYSROOT_LIB SDL2_INCLUDE SDL2_LIB_DIR GUEST_CC HOST_CC JOBS
cd "$SRC"

echo "== Konfiguriere mit $LTO_FLAG $PGO_FLAG $PGO_EXTRA_ARGS ..."
python3 configure.py --release "$LTO_FLAG" "$PGO_FLAG" $PGO_EXTRA_ARGS \
--android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"

echo "== Baue Guest-ELF (halo_guest.elf) ..."
ninja -j "$JOBS" -k 0 build/android/halo_guest.elf || true

echo "== Baue Host-Binary (halo, dynamisch, GCC 9) ueber port/knulli/build.sh ..."
bash "$SRC/port/knulli/build.sh"

# ======================================================================
# Distribution
# ======================================================================
echo "== copying the build into $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

if [ -f "$SRC/build/knulli/halo" ]; then
cp "$SRC/build/knulli/halo" "$DIST/halo"
chmod +x "$DIST/halo" 2>/dev/null || true
else
echo "FEHLER: Host-Binary ($SRC/build/knulli/halo) wurde nicht gebaut!" >&2
exit 1
fi

for candidate in \
"$SRC/build/knulli/halo_guest.elf" \
"$SRC/build/android/halo_guest.elf"; do
if [ -f "$candidate" ]; then
cp "$candidate" "$DIST/halo_guest.elf"
echo "== halo_guest.elf aus $candidate kopiert"
break
fi
done

[ -f "$SRC/port/knulli/Halo.sh" ] && cp "$SRC/port/knulli/Halo.sh" "$DIST/Halo.sh"
[ -f "$SRC/port/knulli/halo_extract.py" ] && cp "$SRC/port/knulli/halo_extract.py" "$DIST/halo_extract.py"
[ -f "$SRC/port/knulli/halo_screen.py" ] && cp "$SRC/port/knulli/halo_screen.py" "$DIST/halo_screen.py"
[ -f "$SRC/port/knulli/sdl_mapping.py" ] && cp "$SRC/port/knulli/sdl_mapping.py" "$DIST/sdl_mapping.py"

if [ -d "$SRC/build/knulli/libs.aarch64" ]; then
mkdir -p "$DIST/libs.aarch64"
cp -a "$SRC/build/knulli/libs.aarch64/." "$DIST/libs.aarch64/"
fi

chmod +x "$DIST/Halo.sh" 2>/dev/null || true

if [ -f "$DIST/halo_guest.elf" ]; then
GUEST_SIZE=$(stat -c%s "$DIST/halo_guest.elf")
GUEST_MB=$((GUEST_SIZE / 1048576))
echo "== halo_guest.elf: $GUEST_SIZE Bytes (~${GUEST_MB} MB)"
else
echo "== halo_guest.elf: FEHLT (Build nicht komplett)"
fi

if [ -f "$DIST/halo" ]; then
HOST_SIZE=$(stat -c%s "$DIST/halo")
echo "== halo: $HOST_SIZE Bytes"
command -v file > /dev/null 2>&1 && file "$DIST/halo" || true
echo "== halo BuildID:"
readelf -n "$DIST/halo" 2>/dev/null | grep -A2 "Build ID" | tail -1 || true
fi

cat <<'RELEASE'
--------------------------------------------------------------------
BUILD v23 - _clang_builtin_shim-Block entfernt (size_t-Konflikt)
--------------------------------------------------------------------
Installation auf M9 Pro:
1. dist/Halo.sh           nach /roms/ports/Halo.sh
2. dist/halo_guest.elf    nach /roms/ports/halo-ce/halo_guest.elf
3. dist/halo              nach /roms/ports/halo-ce/halo
4. dist/libs.aarch64/     nach /roms/ports/halo-ce/libs.aarch64/

FERTIG.
--------------------------------------------------------------------
RELEASE
