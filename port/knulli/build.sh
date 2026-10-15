#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

OUT=build/knulli
OBJ=$OUT/obj
mkdir -p "$OUT/lib" "$OUT/libs.aarch64" "$OUT/gl_include" "$OBJ"

CC=${HOST_CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
SDL2_INCLUDE=${SDL2_INCLUDE:-/usr/include/SDL2}
SYSROOT_LIB=${SYSROOT_LIB:-/usr/lib}
ANDROID_NDK=${ANDROID_NDK:-}

KHRONOS=$OUT/gl_include
rm -rf "$KHRONOS"
mkdir -p "$KHRONOS/KHR" "$KHRONOS/GLES2" "$KHRONOS/GLES3" "$KHRONOS/EGL"
KHRONOS_SRC=
if [ -n "$ANDROID_NDK" ] && [ -d "$ANDROID_NDK/toolchains/llvm/prebuilt" ]; then
    KHRONOS_SRC=$(find "$ANDROID_NDK/toolchains/llvm/prebuilt" -type d -path '*/sysroot/usr/include' 2>/dev/null | head -n 1)
fi
if [ -n "$KHRONOS_SRC" ] && [ -d "$KHRONOS_SRC/GLES3" ]; then
    cp -r "$KHRONOS_SRC/KHR/"*   "$KHRONOS/KHR/"   2>/dev/null || true
    cp -r "$KHRONOS_SRC/GLES2/"* "$KHRONOS/GLES2/" 2>/dev/null || true
    cp -r "$KHRONOS_SRC/GLES3/"* "$KHRONOS/GLES3/" 2>/dev/null || true
    cp -r "$KHRONOS_SRC/EGL/"*   "$KHRONOS/EGL/"   2>/dev/null || true
else
    echo "build.sh: using system Khronos headers" >&2
    for dir in /usr/include /usr/local/include; do
        [ -d "$dir/KHR" ]   && cp -r "$dir/KHR/"*   "$KHRONOS/KHR/"   2>/dev/null || true
        [ -d "$dir/GLES2" ] && cp -r "$dir/GLES2/"* "$KHRONOS/GLES2/" 2>/dev/null || true
        [ -d "$dir/GLES3" ] && cp -r "$dir/GLES3/"* "$KHRONOS/GLES3/" 2>/dev/null || true
        [ -d "$dir/EGL" ]   && cp -r "$dir/EGL/"*   "$KHRONOS/EGL/"   2>/dev/null || true
    done
fi

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c

unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH

# --- KNULLI SO-DEPENDENCIES ---
echo "== Kopiere Laufzeitbibliotheken nach $OUT/libs.aarch64/"
copy_runtime_lib() {
    prefix=$1
    target=$2
    src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" -type f 2>/dev/null | head -n 1)
    if [ -z "$src" ]; then
        src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" 2>/dev/null | head -n 1)
    fi
    if [ -z "$src" ]; then
        echo "  HINWEIS: keine $prefix*-Datei in SYSROOT_LIB – $target wird ausgelassen"
        return 0
    fi
    cp -L "$src" "$OUT/libs.aarch64/$target"
    echo "  $target <- $(basename "$src") ($(stat -c%s "$OUT/libs.aarch64/$target") Bytes)"
    return 0
}

copy_runtime_lib "libSDL3"   "libSDL3.so.0"
copy_runtime_lib "libSDL2"   "libSDL2-2.0.so.0"
copy_runtime_lib "libdecor"  "libdecor-0.so.0"

link_library() {
    pattern=$1
    linkname=$2
    library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -n 1)
    if [ -z "$library" ]; then
        library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" 2>/dev/null | head -n 1)
    fi
    if [ -z "$library" ]; then
        echo "build.sh: no $pattern in SYSROOT_LIB=$SYSROOT_LIB" >&2
        return 1
    fi
    rm -f "$OUT/lib/$linkname"
    ln -sf "$library" "$OUT/lib/$linkname"
    echo "  linked $linkname -> $library"
    return 0
}

link_library "libSDL2*"  "libSDL2.so"    || exit 1
link_library "libSDL3*"  "libSDL3.so"    || true
link_library "libdecor*" "libdecor.so"   || true

# ======================================================================
# libmali.so.0 Linker-Stub
# ======================================================================
if [ ! -f "$OUT/lib/libmali.so.0" ]; then
    echo "== Erzeuge libmali.so.0 Linker-Stub in $OUT/lib/"
    "$CC" -shared -fPIC -Wl,-soname,libmali.so.0 -o "$OUT/lib/libmali.so.0" -x c - <<'MALI_STUB_EOF'
/*
Linker-Stub fuer libmali.so.0. Kein Code, keine Symbole. Die echten
GLES- und EGL-Funktionen werden zur Laufzeit aus der vom Benutzer
installierten libmali in /tmp/halo-mali geladen.
*/
MALI_STUB_EOF
    ls -la "$OUT/lib/libmali.so.0"
fi

# ======================================================================
# WICHTIG: -mno-outline-atomics verhindert SIGILL auf Cortex-A35.
# Ohne diesen Flag emittiert GCC LSE-Atomics (ARMv8.1), die der A35
# nicht unterstuetzt. Der Host-Crash bei glGetString war eine direkte
# Folge dieser Instruktionen.
# ======================================================================
CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -mno-outline-atomics -fPIC \
        -Wall -Wno-unused-function \
        -D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \
        -DHALO_ANDROID \
        -fomit-frame-pointer -ffunction-sections -fdata-sections \
        -fno-semantic-interposition"

CFLAGS="$CFLAGS -ffile-prefix-map=$ROOT=. -ffile-prefix-map=$SDL2_INCLUDE=sdl2"
INCLUDES="-Iport/knulli/compat -Iport/knulli/host -Iport/android/include \
          -Iport/android/host -Iport/linux/src -Iport/third_party/tomlc17 \
          -I$OUT/gl_include -I$SDL2_INCLUDE"
MINIUPNPC="-Iport/third_party/miniupnpc/include -Iport/third_party/miniupnpc/src \
           -DMINIUPNP_STATICLIB -DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR \
           -D_BSD_SOURCE -D_DEFAULT_SOURCE -w"

FLAGS=$OUT/flags
printf '%s\n' "$CC $CFLAGS $INCLUDES $MINIUPNPC" > "$FLAGS.new"
cmp -s "$FLAGS.new" "$FLAGS" || mv "$FLAGS.new" "$FLAGS"
rm -f "$FLAGS.new"

objects=""
stale() {
    object=$1
    [ ! -f "$object" ] || [ ! -f "$object.d" ] || [ "$0" -nt "$object" ] || [ "$FLAGS" -nt "$object" ] && return 0
    dependencies=$(sed -e 's/^[^:]*://' -e 's/\\$//' "$object.d") || return 0
    for dependency in $dependencies; do
        [ -f "$dependency" ] || return 0
        [ "$dependency" -nt "$object" ] && return 0
    done
    return 1
}

compile() {
    source=$1
    shift
    object=$OBJ/$(echo "$source" | tr / _).o
    if stale "$object"; then
        echo "CC $source"
        $CC $CFLAGS $INCLUDES "$@" -MMD -MF "$object.d" -c "$source" -o "$object"
    fi
    objects="$objects $object"
}

for source in host_debug host_gl host_loader host_memory host_syscall host_thread; do
    compile port/android/host/$source.c
done
compile port/knulli/host/host_main.c
compile port/knulli/host/host_sdl2.c
compile port/knulli/host/host_profile.c
compile port/knulli/host/host_gl_timing.c
compile port/knulli/host/host_gl_timing.S

python3 port/knulli/glthread_gen.py build/android/guest/gen/gl_imports.list \
    "$KHRONOS/GLES3/gl32.h" \
    "$OUT/host_glthread_gen.c.new"
cmp -s "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c" || \
    mv "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c"
rm -f "$OUT/host_glthread_gen.c.new"

compile port/knulli/host/host_glthread.c
compile "$OUT/host_glthread_gen.c"
compile port/knulli/host/host_sdl3_events.c -Ibuild/android/third_party/SDL3/include
compile port/linux/src/posix_files.c
compile port/linux/src/posix_net.c
compile port/linux/src/posix_upnp.c $MINIUPNPC
for source in port/third_party/miniupnpc/src/*.c; do
    compile "$source" $MINIUPNPC
done
compile port/third_party/tomlc17/tomlc17.c -w
compile build/android/host/host_import_table.c

echo "LINK $OUT/halo (dynamisch, GCC 9)"
$CC $CFLAGS -o "$OUT/halo" $objects \
    -L"$OUT/lib" \
    -Wl,-rpath-link,"$OUT/lib" \
    -Wl,--allow-shlib-undefined \
    -Wl,--unresolved-symbols=ignore-all \
    -Wl,--as-needed -lSDL2 -lpthread -ldl -lm \
    -Wl,--no-as-needed -l:libmali.so.0 \
    -Wl,--gc-sections

if [ ! -f "$OUT/halo" ]; then
    echo "FEHLER: $OUT/halo konnte nicht erstellt werden!" >&2
    exit 1
fi

cp build/android/halo_guest.elf "$OUT/halo_guest.elf"

echo "== Host-Binary:"
if command -v file > /dev/null 2>&1; then
    file "$OUT/halo"
fi
ls -lh "$OUT/halo"

echo "== NEEDED-Eintraege in $OUT/halo:"
if command -v readelf > /dev/null 2>&1; then
    readelf -d "$OUT/halo" 2>/dev/null | grep NEEDED || true
    echo "== Pruefe libmali.so.0:"
    if readelf -d "$OUT/halo" 2>/dev/null | grep -q "libmali.so.0"; then
        echo "  OK: libmali.so.0 ist in NEEDED"
    else
        echo "  FEHLER: libmali.so.0 fehlt in NEEDED"
        echo "         Der Linker hat den Stub nicht eingetragen."
        echo "         Pruefe die --no-as-needed-Option in der Link-Zeile."
        exit 1
    fi
else
    echo "  (readelf nicht verfuegbar)"
fi
