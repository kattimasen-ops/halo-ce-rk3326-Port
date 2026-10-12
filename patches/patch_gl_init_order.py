#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py (v8 - DYNAMISCHES EGL + PBUFFER-FALLBACK + DIAGNOSE)

Behebt den SIGILL-Absturz in share_initialize auf RK3326/Mali-G31 (ArkOS4Clone).
- Loest alle EGL-Funktionen zur Laufzeit dynamisch auf (dlopen/dlsym/SDL_GL_GetProcAddress).
- Verhindert Spruenge ueber unaufgeloeste GOT-Eintraege (-fno-plt).
- Fuegt 1x1 PBuffer-Fallback fuer Treiber ohne EGL_KHR_surfaceless_context ein.
- Fuegt DIAG-Logs ein fuer lueckenlose Verifikation im Build-Log.
"""
import os, shutil, sys


def backup(path):
    if os.path.exists(path) and not os.path.exists(path + ".bak"):
        shutil.copy2(path, path + ".bak")


def read(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def write(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    path = os.path.join(root, "port", "knulli", "host", "host_glthread.c")
    if not os.path.exists(path):
        print("[WARN] %s nicht gefunden" % path)
        sys.exit(0)
    if os.path.exists(path + ".bak"):
        print("[INFO] host_glthread.c bereits gepatcht (Backup existiert).")
        sys.exit(0)

    backup(path)
    content = read(path)
    changed = 0

    # --- 0. dlfcn.h Include ---
    if "#include <dlfcn.h>" not in content:
        if "#include <EGL/egl.h>" in content:
            content = content.replace("#include <EGL/egl.h>", "#include <EGL/egl.h>\n#include <dlfcn.h>", 1)
            print("[OK] dlfcn.h Include hinzugefuegt")

    # --- 1. Dynamische EGL-Aufloesung und share_initialize ---
    if "pfn_eglGetCurrentDisplay" not in content:
        old_share = (
            "/* on the GL thread, once its context is made */\n"
            "static void share_initialize(void)\n"
            "{\n"
            "\tEGLint config_id = 0, version = 3, count = 0;\n"
            "\tEGLint config_attributes[] = { EGL_CONFIG_ID, 0, EGL_NONE };\n"
            "\n"
            "\tshare_display = eglGetCurrentDisplay();\n"
            "\tshare_context = eglGetCurrentContext();\n"
            "\teglQueryContext(share_display, share_context, EGL_CONFIG_ID, &config_id);\n"
            "\teglQueryContext(share_display, share_context, EGL_CONTEXT_CLIENT_VERSION, &version);\n"
            "\tconfig_attributes[1] = config_id;\n"
            "\tshare_attributes[1] = version;\n"
            "\tif (!eglChooseConfig(share_display, config_attributes, &share_config, 1, &count) || count != 1)\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "}\n"
            "\n"
            "/* a context that shares the GL thread's objects, or EGL_NO_CONTEXT */\n"
            "static EGLContext share_new(void)\n"
            "{\n"
            "\treturn share_context == EGL_NO_CONTEXT ? EGL_NO_CONTEXT :\n"
            "\t\teglCreateContext(share_display, share_config, share_context, share_attributes);\n"
            "}\n"
            "\n"
            "/* such a context current on the calling thread, without a surface\n"
            "(EGL_KHR_surfaceless_context): whether it is */\n"
            "static int share_make_current(EGLContext context)\n"
            "{\n"
            "\treturn context != EGL_NO_CONTEXT && eglMakeCurrent(share_display, EGL_NO_SURFACE, EGL_NO_SURFACE, context);\n"
            "}"
        )
        new_share = (
            "typedef EGLDisplay (*pfn_eglGetCurrentDisplay)(void);\n"
            "typedef EGLContext (*pfn_eglGetCurrentContext)(void);\n"
            "typedef EGLBoolean (*pfn_eglQueryContext)(EGLDisplay, EGLContext, EGLint, EGLint *);\n"
            "typedef EGLBoolean (*pfn_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);\n"
            "typedef EGLContext (*pfn_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);\n"
            "typedef EGLSurface (*pfn_eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);\n"
            "typedef EGLBoolean (*pfn_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);\n"
            "typedef EGLint     (*pfn_eglGetError)(void);\n"
            "\n"
            "static pfn_eglGetCurrentDisplay    p_eglGetCurrentDisplay;\n"
            "static pfn_eglGetCurrentContext    p_eglGetCurrentContext;\n"
            "static pfn_eglQueryContext        p_eglQueryContext;\n"
            "static pfn_eglChooseConfig        p_eglChooseConfig;\n"
            "static pfn_eglCreateContext       p_eglCreateContext;\n"
            "static pfn_eglCreatePbufferSurface p_eglCreatePbufferSurface;\n"
            "static pfn_eglMakeCurrent         p_eglMakeCurrent;\n"
            "static pfn_eglGetError            p_eglGetError;\n"
            "static void *egl_lib_handle;\n"
            "static int egl_funcs_resolved;\n"
            "static EGLSurface share_pbuffer = EGL_NO_SURFACE;\n"
            "\n"
            "extern void *SDL_GL_GetProcAddress(const char *proc);\n"
            "\n"
            "static void resolve_egl_functions(void)\n"
            "{\n"
            "\tif (egl_funcs_resolved)\n"
            "\t\treturn;\n"
            "\tegl_funcs_resolved = 1;\n"
            "\n"
            "\tif (!egl_lib_handle)\n"
            "\t\tegl_lib_handle = dlopen(\"libmali.so.0\", RTLD_NOW | RTLD_GLOBAL);\n"
            "\tif (!egl_lib_handle)\n"
            "\t\tegl_lib_handle = dlopen(\"libEGL.so.1\", RTLD_NOW | RTLD_GLOBAL);\n"
            "\tif (!egl_lib_handle)\n"
            "\t\tegl_lib_handle = dlopen(\"/usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so\", RTLD_NOW | RTLD_GLOBAL);\n"
            "\n"
            "#define RESOLVE_EGL(fn) do { \\\n"
            "\tif (egl_lib_handle) p_##fn = (pfn_##fn)dlsym(egl_lib_handle, #fn); \\\n"
            "\tif (!p_##fn) p_##fn = (pfn_##fn)SDL_GL_GetProcAddress(#fn); \\\n"
            "\tif (!p_##fn) p_##fn = (pfn_##fn)dlsym(RTLD_DEFAULT, #fn); \\\n"
            "} while (0)\n"
            "\n"
            "\tRESOLVE_EGL(eglGetCurrentDisplay);\n"
            "\tRESOLVE_EGL(eglGetCurrentContext);\n"
            "\tRESOLVE_EGL(eglQueryContext);\n"
            "\tRESOLVE_EGL(eglChooseConfig);\n"
            "\tRESOLVE_EGL(eglCreateContext);\n"
            "\tRESOLVE_EGL(eglCreatePbufferSurface);\n"
            "\tRESOLVE_EGL(eglMakeCurrent);\n"
            "\tRESOLVE_EGL(eglGetError);\n"
            "#undef RESOLVE_EGL\n"
            "}\n"
            "\n"
            "/* on the GL thread, once its context is made */\n"
            "static void share_initialize(void)\n"
            "{\n"
            "\tEGLint config_id = 0, version = 3, count = 0;\n"
            "\tEGLint config_attributes[] = { EGL_CONFIG_ID, 0, EGL_NONE };\n"
            "\n"
            "\tresolve_egl_functions();\n"
            "\n"
            "\tif (!p_eglGetCurrentDisplay || !p_eglGetCurrentContext ||\n"
            "\t    !p_eglQueryContext || !p_eglChooseConfig || !p_eglCreateContext || !p_eglMakeCurrent)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: dynamic EGL symbols unavailable; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\tshare_display = p_eglGetCurrentDisplay();\n"
            "\tif (share_display == EGL_NO_DISPLAY || !share_display)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: no active EGL display; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\tshare_context = p_eglGetCurrentContext();\n"
            "\tif (share_context == EGL_NO_CONTEXT || !share_context)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: no active EGL context; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\tif (!p_eglQueryContext(share_display, share_context, EGL_CONFIG_ID, &config_id) ||\n"
            "\t    !p_eglQueryContext(share_display, share_context, EGL_CONTEXT_CLIENT_VERSION, &version))\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: eglQueryContext failed; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\tconfig_attributes[1] = config_id;\n"
            "\tshare_attributes[1] = version;\n"
            "\tif (!p_eglChooseConfig(share_display, config_attributes, &share_config, 1, &count) || count != 1)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: eglChooseConfig failed; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\thost_logf(HOST_LOG_INFO, \"EGL share: initialized successfully (config %d, version %d)\", config_id, version);\n"
            "}\n"
            "\n"
            "/* a context that shares the GL thread's objects, or EGL_NO_CONTEXT */\n"
            "static EGLContext share_new(void)\n"
            "{\n"
            "\treturn (share_context == EGL_NO_CONTEXT || !p_eglCreateContext) ? EGL_NO_CONTEXT :\n"
            "\t\tp_eglCreateContext(share_display, share_config, share_context, share_attributes);\n"
            "}\n"
            "\n"
            "/* such a context current on the calling thread, without a surface\n"
            "(EGL_KHR_surfaceless_context), with 1x1 pbuffer fallback if surfaceless unsupported */\n"
            "static int share_make_current(EGLContext context)\n"
            "{\n"
            "\tif (context == EGL_NO_CONTEXT || !p_eglMakeCurrent)\n"
            "\t\treturn 0;\n"
            "\tif (p_eglMakeCurrent(share_display, EGL_NO_SURFACE, EGL_NO_SURFACE, context))\n"
            "\t\treturn 1;\n"
            "\tif (share_pbuffer == EGL_NO_SURFACE && p_eglCreatePbufferSurface)\n"
            "\t{\n"
            "\t\tEGLint pbuffer_attribs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };\n"
            "\t\tshare_pbuffer = p_eglCreatePbufferSurface(share_display, share_config, pbuffer_attribs);\n"
            "\t}\n"
            "\tif (share_pbuffer != EGL_NO_SURFACE)\n"
            "\t\treturn p_eglMakeCurrent(share_display, share_pbuffer, share_pbuffer, context);\n"
            "\treturn 0;\n"
            "}"
        )
        if old_share in content:
            content = content.replace(old_share, new_share, 1)
            print("[OK] Dynamische EGL-Aufloesung und PBuffer-Fallback eingefuegt")

        # eglGetError-Aufruf in builders_start sicherstellen
        if "eglGetError()" in content:
            content = content.replace("eglGetError()", "p_eglGetError ? p_eglGetError() : 0", 1)
            print("[OK] eglGetError() abgesichert")

    # --- 2. synced_sdl_gl_create_context ---
    old_sync_create = (
        "static uint32_t synced_sdl_gl_create_context(uint32_t window)\n"
        "{\n"
        "\tstruct word_call call = { window, 0, 0, 0 };\n"
        "\n"
        "\tstart();\n"
        "\tglthread_sync(run_create_context, &call);\n"
        "\treturn call.result;\n"
        "}"
    )
    new_sync_create = (
        "static uint32_t synced_sdl_gl_create_context(uint32_t window)\n"
        "{\n"
        "\tstruct word_call call = { window, 0, 0, 0 };\n"
        "\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: sync-create ENTER (main)\");\n"
        "\tstart();\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: sync-create after start() (main)\");\n"
        "\tglthread_sync(run_create_context, &call);\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: sync-create EXIT (main) result=%u\", call.result);\n"
        "\treturn call.result;\n"
        "}"
    )
    if old_sync_create in content:
        content = content.replace(old_sync_create, new_sync_create, 1); changed += 1
    elif "DIAG: sync-create ENTER" in content:
        changed += 1

    # --- 3. synced_sdl_gl_make_current ---
    old_sync_make = (
        "static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tstruct word_call call = { window, context, 0, 0 };\n"
        "\n"
        "\tglthread_sync(run_make_current, &call);\n"
        "\treturn (int)call.result;\n"
        "}"
    )
    new_sync_make = (
        "static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tstruct word_call call = { window, context, 0, 0 };\n"
        "\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: sync-make ENTER (main)\");\n"
        "\tglthread_sync(run_make_current, &call);\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: sync-make EXIT (main) result=%d\", call.result);\n"
        "\treturn (int)call.result;\n"
        "}"
    )
    if old_sync_make in content:
        content = content.replace(old_sync_make, new_sync_make, 1); changed += 1
    elif "DIAG: sync-make ENTER" in content:
        changed += 1

    # --- 4. run_create_context ---
    old_run_create = (
        "static void run_create_context(void *context)\n"
        "{\n"
        "\tstruct word_call *call = context;\n"
        "\tint kind;\n"
        "\n"
        "\tcall->result = host_sdl_gl_create_context(call->a);\n"
        "\t/* the reserve of names, now that there is a context */\n"
        "\tif (call->result)\n"
        "\t{\n"
        "\t\tfor (kind = 0; kind < _glthread_name_kinds; kind++)\n"
        "\t\t{\n"
        "\t\t\tif (!reserves[kind].count)\n"
        "\t\t\t\trefill(kind, RESERVE_REFILL);\n"
        "\t\t}\n"
        "\t\tshare_initialize();\n"
        "\t\tscanout_open();\n"
        "\t\tbuilders_start();\n"
        "\t}\n"
        "}"
    )
    new_run_create = (
        "static void run_create_context(void *context)\n"
        "{\n"
        "\tstruct word_call *call = context;\n"
        "\tint kind;\n"
        "\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: run-create ENTER (gl)\");\n"
        "\tcall->result = host_sdl_gl_create_context(call->a);\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: run-create after create result=%u\", call->result);\n"
        "\t/* the reserve of names, now that there is a context */\n"
        "\tif (call->result)\n"
        "\t{\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: refill start\");\n"
        "\t\tfor (kind = 0; kind < _glthread_name_kinds; kind++)\n"
        "\t\t{\n"
        "\t\t\tif (!reserves[kind].count)\n"
        "\t\t\t\trefill(kind, RESERVE_REFILL);\n"
        "\t\t}\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: refill done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize start\");\n"
        "\t\tshare_initialize();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: scanout_open start\");\n"
        "\t\tscanout_open();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: scanout_open done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: builders_start start\");\n"
        "\t\tbuilders_start();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"DIAG: builders_start done\");\n"
        "\t}\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: run-create EXIT (gl)\");\n"
        "}"
    )
    if old_run_create in content:
        content = content.replace(old_run_create, new_run_create, 1); changed += 1
    elif "DIAG: run-create ENTER" in content:
        changed += 1

    # --- 5. gl_thread_main sync case ---
    old_sync_case = (
        "\t\t\tcase _command_sync:\n"
        "\t\t\t{\n"
        "\t\t\t\tconst struct sync_call *call = (const struct sync_call *)(command + 1);\n"
        "\t\t\t\tuint32_t *done = call->done;\n"
        "\t\t\t\tuint64_t start = command_start();\n"
        "\n"
        "\t\t\t\tcall->run(call->context);\n"
        "\t\t\t\tif (start)\n"
        "\t\t\t\t\thitch_command(_slow_sync, 0, NULL, host_monotonic_ns() - start);\n"
        "\t\t\t\t__atomic_store_n(done, 1, __ATOMIC_SEQ_CST);\n"
        "\t\t\t\tfutex_wake(done);\n"
        "\t\t\t\tbreak;\n"
        "\t\t\t}"
    )
    new_sync_case = (
        "\t\t\tcase _command_sync:\n"
        "\t\t\t{\n"
        "\t\t\t\tconst struct sync_call *call = (const struct sync_call *)(command + 1);\n"
        "\t\t\t\tuint32_t *done = call->done;\n"
        "\t\t\t\tuint64_t start = command_start();\n"
        "\n"
        "\t\t\t\thost_logf(HOST_LOG_INFO, \"DIAG: gl sync handler ENTER (done=%p)\", (void *)done);\n"
        "\t\t\t\tcall->run(call->context);\n"
        "\t\t\t\thost_logf(HOST_LOG_INFO, \"DIAG: gl sync handler after run\");\n"
        "\t\t\t\tif (start)\n"
        "\t\t\t\t\thitch_command(_slow_sync, 0, NULL, host_monotonic_ns() - start);\n"
        "\t\t\t\t__atomic_store_n(done, 1, __ATOMIC_SEQ_CST);\n"
        "\t\t\t\tfutex_wake(done);\n"
        "\t\t\t\thost_logf(HOST_LOG_INFO, \"DIAG: gl sync handler done flag set\");\n"
        "\t\t\t\tbreak;\n"
        "\t\t\t}"
    )
    if old_sync_case in content:
        content = content.replace(old_sync_case, new_sync_case, 1); changed += 1
    elif "DIAG: gl sync handler ENTER" in content:
        changed += 1

    write(path, content)
    print("[OK] host_glthread.c gepatcht mit DIAG-Logs (%d/4 Stellen)." % changed)


if __name__ == "__main__":
    main()
