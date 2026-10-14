#!/usr/bin/env bash
set -euo pipefail
# ======================================================================
# Halo CE Universal - M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
# Fix v16: Python-Syntaxfehler (EOL) behoben + KMSDRM pkg-config
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
need "$HOST_CC" "install gcc-aarch64-linux-gnu"
need "$HOST_CXX" "install g++-aarch64-linux-gnu"
need "$GUEST_CC" "install clang-22"

"$GUEST_CC" -print-targets 2> /dev/null | grep -q aarch64_32 || die "$GUEST_CC has no arm64_32 target"

[ -n "${ANDROID_NDK:-}" ] || die "set ANDROID_NDK"
[ -d "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64" ] || die "Invalid ANDROID_NDK"
ANDROID_NDK=$(cd "$ANDROID_NDK" && pwd)

[ -n "${SYSROOT_LIB:-}" ] || die "set SYSROOT_LIB"
mkdir -p "$SYSROOT_LIB" 2>/dev/null || true
SYSROOT_LIB=$(cd "$SYSROOT_LIB" && pwd)

for module in libdrm gbm; do
  if ! pkg-config --exists "$module"; then
    die "pkg-config findet '$module' nicht. Installiere libdrm-dev und libgbm-dev."
  fi
done

for lib in /usr/aarch64-linux-gnu/lib/libdrm.so /usr/aarch64-linux-gnu/lib/libgbm.so; do
  if [ ! -e "$lib" ]; then
    die "Cross-aarch64 $lib fehlt."
  fi
done

# ======================================================================
# Fix v16: pkg-config für aarch64 konfigurieren (KEINE literalen Newlines in '')
# ======================================================================
echo "== pkg-config für aarch64 konfigurieren..."
export PKG_CONFIG_PATH=/usr/aarch64-linux-gnu/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/aarch64-linux-gnu/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/usr/aarch64-linux-gnu

if [ ! -f /usr/aarch64-linux-gnu/lib/pkgconfig/libdrm.pc ]; then
    echo "== Erstelle libdrm.pc für aarch64"
    mkdir -p /usr/aarch64-linux-gnu/lib/pkgconfig
    cat > /usr/aarch64-linux-gnu/lib/pkgconfig/libdrm.pc << 'EOF'
prefix=/usr/aarch64-linux-gnu
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: libdrm
Description: Userspace interface to kernel DRM services
Version: 2.4.107
Libs: -L${libdir} -ldrm
Cflags: -I${includedir} -I${includedir}/libdrm
EOF
fi

if [ ! -f /usr/aarch64-linux-gnu/lib/pkgconfig/gbm.pc ]; then
    echo "== Erstelle gbm.pc für aarch64"
    cat > /usr/aarch64-linux-gnu/lib/pkgconfig/gbm.pc << 'EOF'
prefix=/usr/aarch64-linux-gnu
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: gbm
Description: Generic Buffer Management
Version: 21.2.6
Libs: -L${libdir} -lgbm
Cflags: -I${includedir}
EOF
fi

if [ ! -f "$SYSROOT_LIB/libdecor-0.so.0" ]; then
  echo "== Erzeuge libdecor-0.so.0 Stub für ARM64 ..."
  $HOST_CC -shared -fPIC -Wl,-soname,libdecor-0.so.0 -o "$SYSROOT_LIB/libdecor-0.so.0" -x c - <<'DECOR_EOF' || true
void libdecor_new(void) {}
void libdecor_unref(void) {}
DECOR_EOF
fi

if ! printf '%s' "$UPSTREAM_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
  die "UPSTREAM_COMMIT ist kein 40-stelliger Hex-Hash"
fi

case "$PGO_MODE" in use|off|train) ;; *) die "PGO_MODE ungültig" ;; esac

echo "== Upstream: $UPSTREAM_URL @ $UPSTREAM_COMMIT"
echo "== PGO-Modus: $PGO_MODE"
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
  echo "== Hole OpenCE-Dateien ..."
  rm -rf "$opence_dir"
  if git clone --depth 1 "$OPEN_CE_URL" "$opence_dir" > /dev/null 2>&1; then
    echo "   + Git-Clone erfolgreich."
  else
    rm -f "$opence_tarball"
    curl -fsSL --retry 3 -o "$opence_tarball" "https://github.com/OpenCommunityEdition/OpenCE/archive/refs/heads/main.tar.gz" || die "OpenCE Download fehlgeschlagen"
    mkdir -p "$opence_dir"
    tar -xzf "$opence_tarball" -C "$opence_dir" --strip-components=1 || die "OpenCE Entpacken fehlgeschlagen"
    echo "   + Tarball erfolgreich."
  fi

  mkdir -p "$SRC/port/linux/include" "$SRC/port/linux/src" "$SRC/port/linux/game" "$SRC/port/third_party"
  for f in port/linux/include/halo_menus.h port/linux/include/halo_keyboard.h port/linux/src/menu_files.c port/linux/src/menu_files.h port/linux/game/menu_tags.c; do
    [ -f "$opence_dir/$f" ] && cp "$opence_dir/$f" "$SRC/$f" && echo "   + $f" || die "OpenCE hat $f nicht."
  done
  for f in port/linux/src/hud_hires.c port/linux/src/hud_hires.h; do
    [ -f "$opence_dir/$f" ] && cp "$opence_dir/$f" "$SRC/$f" && echo "   + $f (OpenCE)"
  done
  for dir in expat zlib; do
    [ -d "$opence_dir/port/third_party/$dir" ] && { rm -rf "$SRC/port/third_party/$dir"; cp -a "$opence_dir/port/third_party/$dir" "$SRC/port/third_party/"; echo "   + port/third_party/$dir/"; } || die "OpenCE hat kein $dir"
  done
  for t in tools/ce_menus.py tools/port_settings.py; do
    [ -f "$opence_dir/$t" ] && cp "$opence_dir/$t" "$SRC/$t" && echo "   + $t"
  done
  [ -f "$opence_dir/tools/embed_assets.py" ] && cp "$opence_dir/tools/embed_assets.py" "$SRC/tools/embed_assets.py" && echo "   + tools/embed_assets.py"
  if [ -d "$opence_dir/port/assets/menus" ]; then
    rm -rf "$SRC/port/assets/menus"
    mkdir -p "$SRC/port/assets"
    cp -a "$opence_dir/port/assets/menus" "$SRC/port/assets/menus"
    echo "   + port/assets/menus/ ($(find "$SRC/port/assets/menus/ce" -name "*.xml" 2>/dev/null | wc -l) XML-Dateien)"
  else
    die "OpenCE hat keinen port/assets/menus-Ordner."
  fi
  rm -rf "$opence_dir" "$opence_tarball"
}

echo "== Entferne den video_settings.xml-Hunk aus dem Knulli-Patch ..."
python3 - "$PATCH" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
# KORRIGIERT: \n explizit statt literaler Newline in ''
pattern = re.compile(
    r'diff --git a/port/assets/menus/ce/'
    r'main_menu\.settings_select\.player_profile_edit\.'
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

mkdir -p "$SYSROOT_LIB"
if [ ! -f "$SYSROOT_LIB/libdecor-0.so.0" ] || readelf -s "$SYSROOT_LIB/libdecor-0.so.0" 2>/dev/null | grep -q "GLIBC_2\.3[2-9]"; then
  echo "== Kompiliere libdecor-0.so.0 Stub für Ubuntu 20.04 ..."
  $HOST_CC -shared -fPIC -Wl,-soname,libdecor-0.so.0 -o "$SYSROOT_LIB/libdecor-0.so.0" -x c - <<'DECOR_EOF' || true
void libdecor_new(void) {}
void libdecor_unref(void) {}
DECOR_EOF
fi

if [ ! -f "$SYSROOT_LIB/libSDL3.so.0" ]; then
  echo "== SDL3 $SDL3_TAG: kompiliere aus dem Quellcode"
  SDL3_SRC=$WORK/SDL3-${SDL3_TAG#release-}
  SDL3_BUILD=$WORK/sdl3-build
  SDL3_INSTALL=$WORK/sdl3-install
  [ -d "$SDL3_SRC" ] || { curl -L -o "$WORK/sdl3.tar.gz" "https://github.com/libsdl-org/SDL/releases/download/$SDL3_TAG/SDL3-${SDL3_TAG#release-}.tar.gz"; tar -xzf "$WORK/sdl3.tar.gz" -C "$WORK"; }
  
  echo "== SDL3 KMSDRM: libdrm-2.4.110-Kompatibilität anwenden"
  python3 - "$SDL3_SRC/src/video/kmsdrm/SDL_kmsdrmsym.h" <<'KMSDRM_EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "extern const char *drmModeGetConnectorTypeName" in text:
    print("  SDL3 KMSDRM: Kompatibilitäts-Deklaration bereits vorhanden.")
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
print("  SDL3 KMSDRM: Kompatibilitäts-Deklaration hinzugefügt.")
KMSDRM_EOF

  rm -rf "$SDL3_BUILD" "$SDL3_INSTALL"
  mkdir -p "$SDL3_BUILD" "$SDL3_INSTALL"
  cmake -S "$SDL3_SRC" -B "$SDL3_BUILD" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DCMAKE_C_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35" \
    -DCMAKE_CXX_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35" \
    -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_TESTS=OFF -DSDL_WERROR=OFF -DSDL_UNIX_CONSOLE_BUILD=ON \
    -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON -DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
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

SDL2_SRC=$WORK/SDL2-src
SDL2_BUILD=$WORK/sdl2-build
SDL2_INSTALL=$WORK/sdl2-install

if [ -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
  if command -v aarch64-linux-gnu-readelf >/dev/null 2>&1 && aarch64-linux-gnu-readelf -d "$SYSROOT_LIB/libSDL2-2.0.so.0" 2>/dev/null | grep -E -q "libX11|libpulse"; then
    echo "== Inkompatible sysroot libSDL2 (X11/Pulse) erkannt, lösche..."
    rm -f "$SYSROOT_LIB/libSDL2-2.0.so.0"
  fi
fi

if [ ! -f "$SYSROOT_LIB/libSDL2-2.0.so.0" ]; then
  echo "== SDL2 $SDL2_TAG: Quellcode holen und mit GCC bauen (shared)"
  rm -rf "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
  mkdir -p "$SDL2_SRC" "$SDL2_BUILD" "$SDL2_INSTALL"
  curl -L -o "$WORK/sdl2.tar.gz" "$SDL2_ARCHIVE"
  tar -xzf "$WORK/sdl2.tar.gz" -C "$SDL2_SRC" --strip-components=1

  echo "== SDL2 KMSDRM Pageflip-Patch für Mali-G31 anwenden"
  python3 - "$SDL2_SRC/src/video/kmsdrm/SDL_kmsdrmopengles.c" <<'PATCH_EOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '''    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
if (ret == 0) {
windata->waiting_for_flip = SDL_TRUE;
} else {
SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);
}'''
new = '''    ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
if (ret != 0 && (flip_flags & DRM_MODE_PAGE_FLIP_ASYNC)) {
viddata->async_pageflip_support = SDL_FALSE;
flip_flags &= ~DRM_MODE_PAGE_FLIP_ASYNC;
ret = KMSDRM_drmModePageFlip(viddata->drm_fd, dispdata->crtc->crtc_id,
fb_info->fb_id, flip_flags, &windata->waiting_for_flip);
if (ret == 0) {
SDL_LogInfo(SDL_LOG_CATEGORY_VIDEO, "Async pageflip rejected by the driver; using synchronous flips.");
}
}
if (ret == 0) {
windata->waiting_for_flip = SDL_TRUE;
} else {
SDL_LogError(SDL_LOG_CATEGORY_VIDEO, "Could not queue pageflip: %d", ret);
}'''
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
    -DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DCMAKE_C_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35" \
    -DCMAKE_CXX_FLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35" \
    -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
    -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON -DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
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
    -DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DCMAKE_FIND_ROOT_PATH=/usr/aarch64-linux-gnu \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
    -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=ON -DSDL_OPENGLES=ON -DSDL_OPENGL=OFF \
    -DCMAKE_INSTALL_PREFIX="$SDL2_INSTALL"
  cmake --build "$SDL2_BUILD" -j "$JOBS"
  cmake --install "$SDL2_BUILD"
fi

export SDL2_INCLUDE="$SDL2_INSTALL/include"
[ -f "$SDL2_INCLUDE/SDL2/SDL.h" ] || die "SDL2_INCLUDE enthält kein SDL2/SDL.h"
export SDL2_LIB_DIR="$SDL2_INSTALL/lib"

if [ ! -d "$SRC/.git" ]; then
  echo "== Klone Upstream in $SRC ..."
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi

if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
  echo "== fetching $UPSTREAM_COMMIT"
  git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT" || git -C "$SRC" fetch -q origin
fi

git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null || die "commit nicht gefunden"

tree_is_patched() {
  [ "$(git -C "$SRC" rev-parse HEAD 2> /dev/null || true)" = "$UPSTREAM_COMMIT" ] &&
  cmp -s <(git -C "$SRC" diff HEAD | grep -v '^index ') <(grep -v '^index ' "$PATCH")
}

if ! tree_is_patched; then
  echo "== Setze Upstream auf $UPSTREAM_COMMIT zurück ..."
  git -C "$SRC" checkout -q --force --detach "$UPSTREAM_COMMIT"
  git -C "$SRC" reset -q --hard
  git -C "$SRC" clean -q -fd -e work -e dist -e rej
  fetch_opence_files

  echo "== Prüfe und wende Knulli-Patch an ..."
  git -C "$SRC" apply --check "$PATCH" 2>&1 || die "Knulli-Patch kann NICHT sauber angewendet werden."
  git -C "$SRC" apply "$PATCH"
  git -C "$SRC" apply --summary "$PATCH" | awk '$1 == "create" { print $4 }' | xargs -r git -C "$SRC" add -N --
  echo "== Knulli-Patch angewendet."

  echo "== Kopiere menu_functions.c und port_settings_shim.c ..."
  [ -f "$HERE/patches/settings_only_menu_functions.c" ] && cp "$HERE/patches/settings_only_menu_functions.c" "$SRC/port/linux/game/menu_functions.c" && echo "   + menu_functions.c" || die "patches/settings_only_menu_functions.c fehlt."
  [ -f "$HERE/patches/port_settings_shim.c" ] && cp "$HERE/patches/port_settings_shim.c" "$SRC/port/linux/game/port_settings_shim.c" && echo "   + port_settings_shim.c" || die "patches/port_settings_shim.c fehlt."

  echo "== Füge menu_files.c Forward-Deklarationen hinzu ..."
  python3 - "$SRC/port/linux/src/menu_files.c" <<'PYEOF'
import sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print(f"   [WARN] {path} nicht gefunden.")
    sys.exit(0)
with open(path) as f:
    text = f.read()
if "extern void config_folder" in text and "extern void xgpu_gl_texture_deleted" in text:
    print("   + menu_files.c: Forward-Deklarationen bereits vorhanden.")
    sys.exit(0)
decl = (
    "/* Fix v5: Forward-Deklarationen fuer Host-Funktionen, die menu_files.c\n"
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
print("   + menu_files.c: Forward-Deklarationen eingefügt.")
PYEOF

  echo "== Setze Menü-Hooks und Build-Registrierung ..."
  [ -f "$HERE/patches/patch_settings_only.py" ] && python3 "$HERE/patches/patch_settings_only.py" "$SRC" "$HERE/patches" || die "patch_settings_only.py fehlt."
  [ -f "$HERE/patches/patch_android_build_hybrid.py" ] && python3 "$HERE/patches/patch_android_build_hybrid.py" "$SRC" || die "patch_android_build_hybrid.py fehlt."
  [ -f "$HERE/patches/patch_missing_functions.py" ] && python3 "$HERE/patches/patch_missing_functions.py" "$SRC" || die "patch_missing_functions.py fehlt."
  [ -f "$HERE/patches/guest_host_stubs.c" ] && cp "$HERE/patches/guest_host_stubs.c" "$SRC/port/linux/src/guest_host_stubs.c" && echo "   + guest_host_stubs.c" || die "guest_host_stubs.c fehlt."
fi

PGO_FLAG="--pgo=off"
PGO_EXTRA_ARGS=""
LTO_FLAG="--lto=full"
if [ "$PGO_MODE" = "use" ]; then
  LOCAL_PGO="$HERE/pgo/halo_linux.profdata"
  PGO_LINUX_URL="https://raw.githubusercontent.com/cybersecurity/halo-ce-universal/main/pgo/halo_linux.profdata"
  if [ -f "$LOCAL_PGO" ]; then
    PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $LOCAL_PGO"
  elif curl -fsSL --retry 2 -o "$WORK/halo_linux.profdata" "$PGO_LINUX_URL" 2>/dev/null; then
    PGO_FLAG="--pgo=use"; PGO_EXTRA_ARGS="--pgo-profile $WORK/halo_linux.profdata"
  else
    echo "== PGO: kein Profil gefunden, --pgo=off"
  fi
elif [ "$PGO_MODE" = "train" ]; then
  LTO_FLAG="--lto=off"
fi

python3 - "$SRC/port/linux/src/xbox_kernel.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
wait_old = '''\tif (milliseconds == INFINITE)
\t\t{
\t\t\tpthread_cond_wait(&handle->condition, &handle->lock);
\t\t}
\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)
\t\t{
\t\t\tif (!handle_try_acquire(handle))
\t\t\t\tresult = WAIT_TIMEOUT;
\t\t\tbreak;
\t\t}'''
wait_new = '''\tif (alertable && platform_run_apcs())
\t\t{
\t\t\tpthread_mutex_unlock(&handle->lock);
\t\t\treturn WAIT_IO_COMPLETION;
\t\t}
\t\tif (milliseconds == INFINITE)
\t\t{
\t\t\tstruct timespec short_wait;
\t\t\tclock_gettime(CLOCK_REALTIME, &short_wait);
\t\t\tshort_wait.tv_nsec += 10000000;
\t\t\tif (short_wait.tv_nsec >= 1000000000L)
\t\t\t{
\t\t\t\tshort_wait.tv_sec++;
\t\t\t\tshort_wait.tv_nsec -= 1000000000L;
\t\t\t}
\t\t\tpthread_cond_timedwait(&handle->condition, &handle->lock, &short_wait);
\t\t}
\t\telse if (pthread_cond_timedwait(&handle->condition, &handle->lock, &deadline) == ETIMEDOUT)
\t\t{
\t\t\tif (alertable && platform_run_apcs())
\t\t\t{
\t\t\t\tpthread_mutex_unlock(&handle->lock);
\t\t\t\treturn WAIT_IO_COMPLETION;
\t\t\t}
\t\t\tif (!handle_try_acquire(handle))
\t\t\t\tresult = WAIT_TIMEOUT;
\t\t\tbreak;
\t\t}'''
if wait_old in text: text = text.replace(wait_old, wait_new, 1)

sleep_old = '''\tif (milliseconds == INFINITE)
\t{
\t\tfor (;;)
\t\t\tpause();
\t}
\tduration.tv_sec = milliseconds / 1000;
\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
\twhile (nanosleep(&duration, &duration) == -1 && errno == EINTR)
\t\t;
\tif (alertable && platform_run_apcs())
\t\treturn WAIT_IO_COMPLETION;
\treturn 0;'''
sleep_new = '''\tif (milliseconds == INFINITE)
\t{
\t\tfor (;;)
\t\t{
\t\t\tif (alertable && platform_run_apcs())
\t\t\t\treturn WAIT_IO_COMPLETION;
\t\t\tpause();
\t\t}
\t}
\tduration.tv_sec = milliseconds / 1000;
\tduration.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
\twhile (duration.tv_sec > 0 || duration.tv_nsec > 0)
\t{
\t\tstruct timespec step;
\t\tstep.tv_sec = duration.tv_sec > 0 ? 1 : 0;
\t\tstep.tv_nsec = duration.tv_sec > 0 ? 0 : (duration.tv_nsec > 10000000L ? 10000000L : duration.tv_nsec);
\t\tif (nanosleep(&step, NULL) == -1 && errno != EINTR)
\t\t\tbreak;
\t\tif (step.tv_sec == 0 && step.tv_nsec == 10000000L)
\t\t\tduration.tv_nsec -= 10000000L;
\t\telse if (step.tv_sec == 1)
\t\t\tduration.tv_sec--;
\t\telse
\t\t\tduration.tv_nsec = 0;
\t\tif (alertable && platform_run_apcs())
\t\t\treturn WAIT_IO_COMPLETION;
\t}
\treturn 0;'''
if sleep_old in text: text = text.replace(sleep_old, sleep_new, 1)
with open(path, 'w') as f:
    f.write(text)
print("xbox_kernel.c geprüft")
PYEOF

python3 - "$SRC/tools/android_build.py" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if '"-mcpu=cortex-a53"' in text:
    text = text.replace('"-mcpu=cortex-a53"', '"-mcpu=cortex-a35",\n"-mtune=cortex-a35"')
    print("android_build.py: mcpu=cortex-a53 -> cortex-a35")
old_flags = '"-ffp-contract=off",\n"-O2",'
new_flags = '''"-ffp-contract=off",\n"-O3",\n"-fomit-frame-pointer",\n"-funroll-loops",\n"-fno-math-errno",\n"-fno-trapping-math",\n"-fmerge-all-constants",\n"-fno-strict-aliasing",'''
if old_flags in text:
    text = text.replace(old_flags, new_flags, 1)
    print("android_build.py: O2 -> O3 + Flags")
if '"-fno-omit-frame-pointer"' in text:
    text = text.replace('    "-fno-omit-frame-pointer",\n', '')
if '"-DHALO_RELEASE"' in text and '"-DHALO_ANDROID"' not in text:
    text = text.replace('"-DHALO_RELEASE"', '"-DHALO_ANDROID",\n"-DHALO_RELEASE"', 1)
    print("android_build.py: -DHALO_ANDROID")
with open(path, 'w') as f:
    f.write(text)
PYEOF

python3 - "$SRC/tools/linux_build.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if 'OPTIMISATION = "-O3"' not in text:
    text = text.replace('OPTIMISATION = "-O2"', 'OPTIMISATION = "-O3"')
old_abi = '"-ffp-contract=off",\nOPTIMISATION,'
new_abi = '''"-ffp-contract=off",\n"-funroll-loops",\n"-fno-math-errno",\n"-fno-trapping-math",\n"-fmerge-all-constants",\n"-fno-strict-aliasing",\nOPTIMISATION,'''
if old_abi in text:
    text = text.replace(old_abi, new_abi, 1)
with open(path, "w") as f:
    f.write(text)
print("linux_build.py geprüft")
PYEOF

echo "== Kopiere port/knulli in den Quellbaum ..."
[ -d "$HERE/port/knulli" ] || die "port/knulli/ existiert nicht"
rm -rf "$SRC/port/knulli"
cp -a "$HERE/port/knulli" "$SRC/port/knulli"
rm -rf "$SRC/port/knulli/__pycache__"
chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true

if [ -f "$HERE/patches/patch_gl_init_order.py" ]; then
  echo "== DIAGNOSE: Logging in host_glthread.c einfügen ..."
  python3 "$HERE/patches/patch_gl_init_order.py" "$SRC" || echo "WARNUNG: patch_gl_init_order.py fehlgeschlagen."
fi

echo "== Wende restliche Patch-Skripte an ..."
for patch_script in patch_opence_menu_cache_hooks.py patch_memory_pools.py patch_neon_math.py patch_vita_optimizations.py patch_button_remap.py patch_index_extent_neon.py patch_fps_overlay.py patch_draw_framebuffer_bound.py patch_mali_subdata.py patch_shader_prewarm.py patch_aggressive_culling.py patch_state_batching.py patch_texture_prewarm.py patch_settings_menu.py patch_config_defaults.py patch_credits.py patch_forward_declarations.py patch_config_changes.py patch_terminal_buffer.py; do
  [ -f "$HERE/patches/$patch_script" ] && python3 "$HERE/patches/$patch_script" "$SRC" || true
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
new_text = pattern.sub(lambda m: '{ const float overlay_color[4] = { ' + m.group(1).strip() + ' }; glUniform4fv(fps_overlay_color, 1, overlay_color); }', text)
if new_text != text:
    with open(path, "w") as f:
        f.write(new_text)
    print("d3d8_gl.c: glUniform4f -> glUniform4fv")
PYEOF
fi

echo "== Regeneriere die In-Game-Settings-Menüs ..."
python3 - "$SRC" <<'PYEOF'
import os, sys
src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))
try:
    import port_settings
except ImportError:
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
    print(f"  geschrieben: {name}")
PYEOF

[ -f "$HERE/patches/patch_credits_xml.py" ] && python3 "$HERE/patches/patch_credits_xml.py" "$SRC"

echo "== Verifiziere Patch-Ergebnisse ..."
verification_failed=0
check_patch() {
  grep -q -- "$2" "$SRC/$1" 2>/dev/null && echo "   OK: $3" || { echo "   FEHLT: $3 ($1)"; verification_failed=1; }
}
check_file() {
  [ -f "$SRC/$1" ] && echo "   OK: $2" || { echo "   FEHLT: $2 ($1)"; verification_failed=1; }
}
check_patch "source/cseries/cseries.h" "HALO_DEBUG_ALLOCATOR" "cseries.h Debug-Allocator"
check_patch "source/math/matrix_math.c" "vmulq_n_f32" "matrix_math.c NEON"
check_patch "port/linux/src/port_config.c" "HALO_SOUND_OBSTRUCTION_TICKS" "port_config.c Sound"
check_patch "port/linux/src/xinput_sdl.c" "button_remap" "xinput_sdl.c Remap"
check_patch "port/linux/src/d3d8_gl.c" "fps_overlay_enabled" "d3d8_gl.c FPS-Overlay"
check_file "port/linux/game/menu_functions.c" "menu_functions.c"
check_file "port/linux/game/port_settings_shim.c" "port_settings_shim.c"
if [ "$verification_failed" -ne 0 ]; then echo "== Verifikation meldete Fehler, fahre trotzdem fort."; fi

CPATH_GUEST="$SRC/port/third_party/expat/lib:$SRC/port/third_party/expat:$SRC/port/third_party/zlib"
export CPATH="$CPATH_GUEST${CPATH:+:$CPATH}"

stamp=$({
  cat "$PATCH"
  for p in patch_settings_only.py patch_android_build_hybrid.py patch_missing_functions.py patch_gl_init_order.py settings_only_menu_functions.c port_settings_shim.c guest_host_stubs.c; do
    cat "$HERE/patches/$p" 2>/dev/null || true
  done
  echo "pgo-mode=$PGO_MODE"
  echo "gcc9-host-dynamic=v16-python-syntax-fix"
  (cd "$HERE/port/knulli" && find . -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 cat)
} | sha256sum | cut -d' ' -f1)
echo "$stamp" > "$SRC/.port-stamp"

export ANDROID_NDK SYSROOT_LIB SDL2_INCLUDE SDL2_LIB_DIR GUEST_CC HOST_CC JOBS
cd "$SRC"

echo "== Konfiguriere mit $LTO_FLAG $PGO_FLAG $PGO_EXTRA_ARGS ..."
python3 configure.py --release "$LTO_FLAG" "$PGO_FLAG" $PGO_EXTRA_ARGS --android-ndk "$ANDROID_NDK" --android-guest-cc "$GUEST_CC"

echo "== Baue Guest-ELF (halo_guest.elf) ..."
ninja -j "$JOBS" -k 0 build/android/halo_guest.elf || true

echo "== Baue Host-Binary (halo, dynamisch, GCC 9) über port/knulli/build.sh ..."
bash "$SRC/port/knulli/build.sh"

echo "== copying the build into $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
[ -f "$SRC/build/knulli/halo" ] && cp "$SRC/build/knulli/halo" "$DIST/halo" && chmod +x "$DIST/halo" 2>/dev/null || { echo "FEHLER: Host-Binary wurde nicht gebaut!" >&2; exit 1; }
for candidate in "$SRC/build/knulli/halo_guest.elf" "$SRC/build/android/halo_guest.elf"; do
  [ -f "$candidate" ] && cp "$candidate" "$DIST/halo_guest.elf" && break
done
[ -f "$SRC/port/knulli/Halo.sh" ] && cp "$SRC/port/knulli/Halo.sh" "$DIST/Halo.sh"
[ -f "$SRC/port/knulli/halo_extract.py" ] && cp "$SRC/port/knulli/halo_extract.py" "$DIST/halo_extract.py"
[ -f "$SRC/port/knulli/halo_screen.py" ] && cp "$SRC/port/knulli/halo_screen.py" "$DIST/halo_screen.py"
[ -f "$SRC/port/knulli/sdl_mapping.py" ] && cp "$SRC/port/knulli/sdl_mapping.py" "$DIST/sdl_mapping.py"
[ -d "$SRC/build/knulli/libs.aarch64" ] && { mkdir -p "$DIST/libs.aarch64"; cp -a "$SRC/build/knulli/libs.aarch64/." "$DIST/libs.aarch64/"; }

chmod +x "$DIST/Halo.sh" 2>/dev/null || true
if [ -f "$DIST/halo_guest.elf" ]; then echo "== halo_guest.elf: $(stat -c%s "$DIST/halo_guest.elf") Bytes"; fi
if [ -f "$DIST/halo" ]; then echo "== halo: $(stat -c%s "$DIST/halo") Bytes"; readelf -n "$DIST/halo" 2>/dev/null | grep -A2 "Build ID" | tail -1 || true; fi

cat <<'RELEASE'
--------------------------------------------------------------------
BUILD v16 - Python Syntax Fix + KMSDRM pkg-config
--------------------------------------------------------------------
RELEASE
