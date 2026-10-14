#!/bin/sh
# Builds the Knulli port into build/knulli:
#   halo            the aarch64 glibc host (the loader, SDL2, OpenGL ES)
#   halo_guest.elf  the game, the Android port's guest image
#   libs.aarch64/   die Laufzeitbibliotheken
#
# POSIX-sh-kompatibel (dash): set -eu statt set -euo pipefail.
#
# Host-Compiler: aarch64-linux-gnu-gcc (GCC 9.4 aus Ubuntu 20.04).
# GCC 9 ist von Natur aus ARMv8.0-kompatibel — er erzeugt keine
# LSE-Atomics und ruft die glibc-Pfade, die sie enthalten, nicht auf.
# Damit tritt der SIGILL auf dem Cortex-A35 nicht auf.
#
# libmali wird NICHT gelinkt (die sysroot-libmali.so.0 ist beschaedigt);
# die EGL/GLES-Symbole bleiben undefiniert und werden zur Laufzeit aus
# /tmp/halo-mali geladen.
set -eu

folder() {
    mkdir -p "$1" 2>/dev/null || true
    resolved=$(cd "$1" && pwd) || { echo "build.sh: $1: no such folder" >&2; exit 1; }
    case "$resolved" in
        *" "*) echo "build.sh: $resolved: a path with spaces is not supported" >&2; exit 1 ;;
    esac
    echo "$resolved"
}

SDL2_INCLUDE=$(folder "${SDL2_INCLUDE:?the folder that holds SDL2/SDL.h}")
SYSROOT_LIB=$(folder "${SYSROOT_LIB:?the device libraries}")
NDK=$(folder "${ANDROID_NDK:?the Android NDK (for the OpenGL ES and EGL headers)}")

cd "$(dirname "$0")/../.."
ROOT=$(folder .)
CC=${CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}
OUT=build/knulli
OBJ=$OUT/obj

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c
mkdir -p "$OBJ" "$OUT/gl_include" "$OUT/lib" "$OUT/libs.aarch64"

KHRONOS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
for name in EGL GLES2 GLES3 KHR; do
    ln -sfn "$KHRONOS/$name" "$OUT/gl_include/$name"
done

echo "== Inhalt von SYSROOT_LIB=$SYSROOT_LIB:"
ls -la "$SYSROOT_LIB" || true

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

CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -fPIC -Wall -Wno-unused-function \
        -D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \
        -DHALO_ANDROID \
        -mno-outline-atomics \
        -flto -fomit-frame-pointer -ffunction-sections -fdata-sections \
        -fno-plt -fno-semantic-interposition"

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
    -Wl,--as-needed -Wl,--gc-sections \
    -lSDL2 -lpthread -ldl -lm

if [ ! -f "$OUT/halo" ]; then
    echo "FEHLER: $OUT/halo konnte nicht erstellt werden!" >&2
    exit 1
fi

cp build/android/halo_guest.elf "$OUT/halo_guest.elf"

echo "== Host-Binary:"
if command -v file > /dev/null 2>&1; then
    file "$OUT/halo" || true
fi
ls -l "$OUT/halo"
HOST_SIZE=$(stat -c%s "$OUT/halo")
echo "  Groesse: $HOST_SIZE Bytes"

echo "== Inhalt von $OUT/libs.aarch64/:"
ls -la "$OUT/libs.aarch64/"
echo "== $OUT/halo und $OUT/halo_guest.elf:"
ls -l "$OUT/halo" "$OUT/halo_guest.elf"
