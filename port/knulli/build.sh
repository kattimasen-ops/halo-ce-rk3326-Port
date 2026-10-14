#!/bin/sh
set -eu
# ======================================================================
# Halo CE Universal - port/knulli/build.sh
# Host-Binary (halo, dynamisch, GCC 9) für RK3326 / Mali-G31
#
# Fix v22: libmali.so.0 Stub mit echten GL/EGL-Symbol-Deklarationen.
#          Der leere Stub exportierte keine Symbole, dadurch blieben
#          die GOT-Eintraege fuer glGetString etc. ungueltig -> SIGILL.
# ======================================================================

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=build/knulli
OBJ=$OUT/obj
mkdir -p "$OUT/lib" "$OUT/libs.aarch64" "$OUT/gl_include" "$OBJ"

# Compiler: aus HOST_CC, das die aeussere build.sh exportiert. Nicht CC,
# damit ein im Container gesetztes CC=gcc den Cross-GCC nicht ueberschreibt.
CC=${HOST_CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
SDL2_INCLUDE=${SDL2_INCLUDE:-/usr/include/SDL2}
SYSROOT_LIB=${SYSROOT_LIB:-/usr/lib}
ANDROID_NDK=${ANDROID_NDK:-}
KHRONOS=$OUT/gl_include
rm -rf "$KHRONOS"
mkdir -p "$KHRONOS/KHR" "$KHRONOS/GLES2" "$KHRONOS/GLES3" "$KHRONOS/EGL"

# ======================================================================
# Khronos-GL-Header sammeln (fuer den Host-Build)
# ======================================================================
if [ -n "$ANDROID_NDK" ] && [ -d "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" ]; then
    echo "build.sh: using NDK Khronos headers" >&2
    NDK_INC="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
    [ -d "$NDK_INC/KHR" ] && cp -r "$NDK_INC/KHR/"* "$KHRONOS/KHR/" 2>/dev/null || true
    [ -d "$NDK_INC/GLES2" ] && cp -r "$NDK_INC/GLES2/"* "$KHRONOS/GLES2/" 2>/dev/null || true
    [ -d "$NDK_INC/GLES3" ] && cp -r "$NDK_INC/GLES3/"* "$KHRONOS/GLES3/" 2>/dev/null || true
    [ -d "$NDK_INC/EGL" ] && cp -r "$NDK_INC/EGL/"* "$KHRONOS/EGL/" 2>/dev/null || true
else
    echo "build.sh: using system Khronos headers" >&2
    for dir in /usr/include /usr/local/include; do
        [ -d "$dir/KHR" ] && cp -r "$dir/KHR/"* "$KHRONOS/KHR/" 2>/dev/null || true
        [ -d "$dir/GLES2" ] && cp -r "$dir/GLES2/"* "$KHRONOS/GLES2/" 2>/dev/null || true
        [ -d "$dir/GLES3" ] && cp -r "$dir/GLES3/"* "$KHRONOS/GLES3/" 2>/dev/null || true
        [ -d "$dir/EGL" ] && cp -r "$dir/EGL/"* "$KHRONOS/EGL/" 2>/dev/null || true
    done
fi

# ======================================================================
# Fix v22: libmali.so.0 Linker-Stub mit echten GL/EGL-Symbolen
# ----------------------------------------------------------------------
# Der Stub MUSS die GL/EGL-Symbole exportieren, damit der Linker
# korrekte GOT-Eintraege mit dynamischen Relocations erzeugt.
# Zur Laufzeit werden diese Symbole von der echten libmali.so.0
# (in /tmp/halo-mali/) ueberschrieben.
# ======================================================================
echo "== Erzeuge libmali.so.0 Linker-Stub mit GL/EGL-Symbolen in $OUT/lib/"
cat > "$OUT/lib/mali_stub.c" << 'MALI_STUB_EOF'
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* GLES2 / GLES3 Kern-Funktionen                                       */
/* ------------------------------------------------------------------ */
const char *glGetString(uint32_t name) { return (const char *)0; }
const char *glGetStringi(uint32_t name, uint32_t index) { return (const char *)0; }
void glGetIntegerv(uint32_t pname, int32_t *params) { }
void glGetBooleanv(uint32_t pname, uint8_t *params) { }
void glGetFloatv(uint32_t pname, float *params) { }
int32_t glGetError(void) { return 0; }
void glEnable(uint32_t cap) { }
void glDisable(uint32_t cap) { }
uint8_t glIsEnabled(uint32_t cap) { return 0; }
void glClear(uint32_t mask) { }
void glClearColor(float r, float g, float b, float a) { }
void glClearDepthf(float d) { }
void glClearStencil(int32_t s) { }
void glViewport(int32_t x, int32_t y, int32_t w, int32_t h) { }
void glScissor(int32_t x, int32_t y, int32_t w, int32_t h) { }
void glDepthRangef(float n, float f) { }
void glFinish(void) { }
void glFlush(void) { }
void glHint(uint32_t target, uint32_t mode) { }
void glPixelStorei(uint32_t pname, int32_t param) { }

/* Draw */
void glDrawArrays(uint32_t mode, int32_t first, int32_t count) { }
void glDrawElements(uint32_t mode, int32_t count, uint32_t type, const void *indices) { }
void glDrawArraysInstanced(uint32_t mode, int32_t first, int32_t count, int32_t instancecount) { }
void glDrawElementsInstanced(uint32_t mode, int32_t count, uint32_t type, const void *indices, int32_t instancecount) { }
void glVertexAttribDivisor(uint32_t index, uint32_t divisor) { }

/* Textures */
void glGenTextures(int32_t n, uint32_t *textures) { }
void glDeleteTextures(int32_t n, const uint32_t *textures) { }
void glBindTexture(uint32_t target, uint32_t texture) { }
uint8_t glIsTexture(uint32_t texture) { return 0; }
void glTexImage2D(uint32_t target, int32_t level, int32_t internalformat, int32_t width, int32_t height, int32_t border, uint32_t format, uint32_t type, const void *pixels) { }
void glTexSubImage2D(uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, uint32_t type, const void *pixels) { }
void glCompressedTexImage2D(uint32_t target, int32_t level, uint32_t internalformat, int32_t width, int32_t height, int32_t border, int32_t imageSize, const void *data) { }
void glCompressedTexSubImage2D(uint32_t target, int32_t level, int32_t xoffset, int32_t yoffset, int32_t width, int32_t height, uint32_t format, int32_t imageSize, const void *data) { }
void glTexParameteri(uint32_t target, uint32_t pname, int32_t param) { }
void glTexParameterf(uint32_t target, uint32_t pname, float param) { }
void glActiveTexture(uint32_t texture) { }
void glGenerateMipmap(uint32_t target) { }

/* Buffers */
void glGenBuffers(int32_t n, uint32_t *buffers) { }
void glDeleteBuffers(int32_t n, const uint32_t *buffers) { }
void glBindBuffer(uint32_t target, uint32_t buffer) { }
void glBufferData(uint32_t target, int64_t size, const void *data, uint32_t usage) { }
void glBufferSubData(uint32_t target, int64_t offset, int64_t size, const void *data) { }
void *glMapBufferRange(uint32_t target, int64_t offset, int64_t length, uint32_t access) { return (void *)0; }
uint8_t glUnmapBuffer(uint32_t target) { return 0; }

/* Shaders & Programs */
uint32_t glCreateProgram(void) { return 0; }
void glDeleteProgram(uint32_t program) { }
void glUseProgram(uint32_t program) { }
void glLinkProgram(uint32_t program) { }
void glGetProgramiv(uint32_t program, uint32_t pname, int32_t *params) { }
void glGetProgramInfoLog(uint32_t program, int32_t bufSize, int32_t *length, char *infoLog) { }
void glProgramBinary(uint32_t program, uint32_t binaryFormat, const void *binary, int32_t length) { }
void glGetProgramBinary(uint32_t program, int32_t bufSize, int32_t *length, uint32_t *binaryFormat, void *binary) { }
uint32_t glCreateShader(uint32_t type) { return 0; }
void glDeleteShader(uint32_t shader) { }
void glShaderSource(uint32_t shader, int32_t count, const char **string, const int32_t *length) { }
void glCompileShader(uint32_t shader) { }
void glGetShaderiv(uint32_t shader, uint32_t pname, int32_t *params) { }
void glGetShaderInfoLog(uint32_t shader, int32_t bufSize, int32_t *length, char *infoLog) { }
void glAttachShader(uint32_t program, uint32_t shader) { }
void glDetachShader(uint32_t program, uint32_t shader) { }
void glBindAttribLocation(uint32_t program, uint32_t index, const char *name) { }
int32_t glGetAttribLocation(uint32_t program, const char *name) { return -1; }
int32_t glGetUniformLocation(uint32_t program, const char *name) { return -1; }

/* Uniforms */
void glUniform1i(int32_t location, int32_t v0) { }
void glUniform1f(int32_t location, float v0) { }
void glUniform2f(int32_t location, float v0, float v1) { }
void glUniform3f(int32_t location, float v0, float v1, float v2) { }
void glUniform4f(int32_t location, float v0, float v1, float v2, float v3) { }
void glUniform1fv(int32_t location, int32_t count, const float *value) { }
void glUniform2fv(int32_t location, int32_t count, const float *value) { }
void glUniform3fv(int32_t location, int32_t count, const float *value) { }
void glUniform4fv(int32_t location, int32_t count, const float *value) { }
void glUniform1iv(int32_t location, int32_t count, const int32_t *value) { }
void glUniformMatrix2fv(int32_t location, int32_t count, uint8_t transpose, const float *value) { }
void glUniformMatrix3fv(int32_t location, int32_t count, uint8_t transpose, const float *value) { }
void glUniformMatrix4fv(int32_t location, int32_t count, uint8_t transpose, const float *value) { }

/* Vertex Attribs */
void glVertexAttribPointer(uint32_t index, int32_t size, uint32_t type, uint8_t normalized, int32_t stride, const void *pointer) { }
void glVertexAttribIPointer(uint32_t index, int32_t size, uint32_t type, int32_t stride, const void *pointer) { }
void glEnableVertexAttribArray(uint32_t index) { }
void glDisableVertexAttribArray(uint32_t index) { }

/* State */
void glBlendFunc(uint32_t sfactor, uint32_t dfactor) { }
void glBlendFuncSeparate(uint32_t srcRGB, uint32_t dstRGB, uint32_t srcAlpha, uint32_t dstAlpha) { }
void glBlendEquation(uint32_t mode) { }
void glBlendColor(float r, float g, float b, float a) { }
void glDepthFunc(uint32_t func) { }
void glDepthMask(uint8_t flag) { }
void glColorMask(uint8_t r, uint8_t g, uint8_t b, uint8_t a) { }
void glStencilFunc(uint32_t func, int32_t ref, uint32_t mask) { }
void glStencilFuncSeparate(uint32_t face, uint32_t func, int32_t ref, uint32_t mask) { }
void glStencilOp(uint32_t fail, uint32_t zfail, uint32_t zpass) { }
void glStencilOpSeparate(uint32_t face, uint32_t fail, uint32_t zfail, uint32_t zpass) { }
void glStencilMask(uint32_t mask) { }
void glStencilMaskSeparate(uint32_t face, uint32_t mask) { }
void glLineWidth(float width) { }
void glPolygonOffset(float factor, float units) { }
void glCullFace(uint32_t mode) { }
void glFrontFace(uint32_t mode) { }

/* Framebuffers & Renderbuffers */
void glGenFramebuffers(int32_t n, uint32_t *framebuffers) { }
void glDeleteFramebuffers(int32_t n, const uint32_t *framebuffers) { }
void glBindFramebuffer(uint32_t target, uint32_t framebuffer) { }
uint32_t glCheckFramebufferStatus(uint32_t target) { return 0; }
void glFramebufferTexture2D(uint32_t target, uint32_t attachment, uint32_t textarget, uint32_t texture, int32_t level) { }
void glFramebufferRenderbuffer(uint32_t target, uint32_t attachment, uint32_t renderbuffertarget, uint32_t renderbuffer) { }
void glGenRenderbuffers(int32_t n, uint32_t *renderbuffers) { }
void glDeleteRenderbuffers(int32_t n, const uint32_t *renderbuffers) { }
void glBindRenderbuffer(uint32_t target, uint32_t renderbuffer) { }
void glRenderbufferStorage(uint32_t target, uint32_t internalformat, int32_t width, int32_t height) { }
void glReadBuffer(uint32_t src) { }
void glBlitFramebuffer(int32_t srcX0, int32_t srcY0, int32_t srcX1, int32_t srcY1, int32_t dstX0, int32_t dstY0, int32_t dstX1, int32_t dstY1, uint32_t mask, uint32_t filter) { }

/* Read */
void glReadPixels(int32_t x, int32_t y, int32_t width, int32_t height, uint32_t format, uint32_t type, void *pixels) { }

/* Sync (GLES3) */
void *glFenceSync(uint32_t condition, uint32_t flags) { return (void *)0; }
void glDeleteSync(void *sync) { }
uint32_t glClientWaitSync(void *sync, uint32_t flags, uint64_t timeout) { return 0; }
void glWaitSync(void *sync, uint32_t flags, uint64_t timeout) { }

/* ------------------------------------------------------------------ */
/* EGL-Funktionen                                                      */
/* ------------------------------------------------------------------ */
void *eglGetDisplay(void *native_display) { return (void *)0; }
void *eglGetPlatformDisplay(uint32_t platform, void *native_display, const int *attrib_list) { return (void *)0; }
int eglInitialize(void *display, int *major, int *minor) { return 0; }
int eglTerminate(void *display) { return 0; }
const char *eglQueryString(void *display, int name) { return (const char *)0; }
int eglGetError(void) { return 0; }
int eglChooseConfig(void *display, const int *attrib_list, void **configs, int config_size, int *num_config) { return 0; }
int eglGetConfigs(void *display, void **configs, int config_size, int *num_config) { return 0; }
int eglGetConfigAttrib(void *display, void *config, int attribute, int *value) { return 0; }
void *eglCreateContext(void *display, void *config, void *share_context, const int *attrib_list) { return (void *)0; }
int eglDestroyContext(void *display, void *ctx) { return 0; }
void *eglCreateWindowSurface(void *display, void *config, void *native_window, const int *attrib_list) { return (void *)0; }
void *eglCreatePbufferSurface(void *display, void *config, const int *attrib_list) { return (void *)0; }
int eglDestroySurface(void *display, void *surface) { return 0; }
int eglMakeCurrent(void *display, void *draw, void *read, void *ctx) { return 0; }
void *eglGetCurrentContext(void) { return (void *)0; }
void *eglGetCurrentSurface(int readdraw) { return (void *)0; }
int eglSwapBuffers(void *display, void *surface) { return 0; }
int eglSwapInterval(void *display, int interval) { return 0; }
int eglQuerySurface(void *display, void *surface, int attribute, int *value) { return 0; }
int eglSurfaceAttrib(void *display, void *surface, int attribute, int value) { return 0; }
int eglWaitGL(void) { return 0; }
int eglWaitNative(int engine) { return 0; }
int eglBindAPI(uint32_t api) { return 0; }
uint32_t eglQueryAPI(void) { return 0; }
void *eglGetProcAddress(const char *procname) { return (void *)0; }
int eglReleaseThread(void) { return 0; }
void *eglCreateImage(void *display, void *ctx, uint32_t target, void *buffer, const int *attrib_list) { return (void *)0; }
int eglDestroyImage(void *display, void *image) { return 0; }
MALI_STUB_EOF

"$CC" -shared -fPIC -Wl,-soname,libmali.so.0 \
    -o "$OUT/lib/libmali.so.0" "$OUT/lib/mali_stub.c"
rm -f "$OUT/lib/mali_stub.c"

# Verifikation: Der Stub MUSS die GL-Symbole exportieren
if ! readelf -s "$OUT/lib/libmali.so.0" 2>/dev/null | grep -q glGetString; then
    echo "FEHLER: libmali-Stub exportiert glGetString nicht" >&2
    exit 1
fi
if ! readelf -s "$OUT/lib/libmali.so.0" 2>/dev/null | grep -q eglMakeCurrent; then
    echo "FEHLER: libmali-Stub exportiert eglMakeCurrent nicht" >&2
    exit 1
fi
echo "  OK: libmali.so.0 Stub exportiert GL/EGL-Symbole"

# ======================================================================
# Host-Quellen kompilieren
# ======================================================================
compile() {
    src="$1"; shift
    base=$(basename "$src")
    obj="$OBJ/${base%.c}.o"
    echo "  CC $src"
    "$CC" $CFLAGS -I"$KHRONOS" -I"$SDL2_INCLUDE" -Iport/knulli/host \
        -Iport/android/host -Iport/linux/include -Ibuild/android/third_party/SDL3/include \
        "$@" -c "$src" -o "$obj"
}

CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -fPIC -Wall -Wno-unused-function \
-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \
-DHALO_ANDROID \
-fomit-frame-pointer -ffunction-sections -fdata-sections \
-fno-semantic-interposition"

# WICHTIG: KEIN -fno-plt hier. Mit -fno-plt laedt der Compiler die
# Funktion direkt aus dem GOT; ist der GOT-Eintrag noch ungueltig,
# springt blr x16 auf die ELF-Header -> SIGILL.

echo "== Generiere host_glthread_gen.c"
python3 port/knulli/host/glthread_gen.py > "$OUT/host_glthread_gen.c.new"
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

# ======================================================================
# Link
# ======================================================================
echo "LINK $OUT/halo (dynamisch, GCC 9)"
"$CC" -o "$OUT/halo" "$OBJ/"*.o \
    -L"$OUT/lib" \
    -L"$SYSROOT_LIB" \
    -Wl,--as-needed -lSDL2 -lpthread -ldl -lm \
    -Wl,--no-as-needed -l:libmali.so.0 \
    -Wl,--gc-sections \
    -Wl,--allow-shlib-undefined \
    -Wl,-rpath-link,"$OUT/lib" \
    -Wl,-rpath-link,"$SYSROOT_LIB"

# ======================================================================
# Verifikation: libmali.so.0 MUSS in NEEDED sein
# ======================================================================
echo "== Verifiziere NEEDED-Eintraege von $OUT/halo"
if readelf -d "$OUT/halo" 2>/dev/null | grep -q "libmali.so.0"; then
    echo "  OK: libmali.so.0 ist in NEEDED"
else
    echo "  FEHLER: libmali.so.0 fehlt in NEEDED" >&2
    exit 1
fi

# ======================================================================
# Laufzeitbibliotheken kopieren
# ======================================================================
echo "== Kopiere Laufzeitbibliotheken nach $OUT/libs.aarch64/"
for lib in "$SYSROOT_LIB"/libSDL2-2.0.so.0 "$SYSROOT_LIB"/libSDL3.so.0 "$SYSROOT_LIB"/libdecor-0.so.0; do
    if [ -f "$lib" ]; then
        cp -a "$lib" "$OUT/libs.aarch64/"
        echo "  + $(basename "$lib")"
    fi
done

echo "== port/knulli/build.sh fertig"
