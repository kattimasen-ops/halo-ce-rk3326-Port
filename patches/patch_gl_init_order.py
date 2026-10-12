#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py (v8 - DYNAMISCHES EGL + PBUFFER-FALLBACK + DIAGNOSE)

Behebt den SIGILL-Absturz in share_initialize auf RK3326/Mali-G31 (ArkOS4Clone).
- Loest alle EGL-Funktionen zur Laufzeit dynamisch auf (dlopen/dlsym ohne SDL_GL_GetProcAddress).
- Verhindert Spruenge ueber unaufgeloeste GOT-Eintraege.
- Fuegt 1x1 PBuffer-Fallback fuer Treiber ohne EGL_KHR_surfaceless_context ein.
- Fuegt DIAG-Logs ein fuer lueckenlose Verifikation im Build- und Runtime-Log.
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
            "static void resolve_egl_functions(void)\n"
            "{\n"
            "\tif (egl_funcs_resolved)\n"
            "\t\treturn;\n"
            "\tegl_funcs_resolved = 1;\n"
            "\n"
            "\tstatic const char *const lib_candidates[] = {\n"
            "\t\t\"/tmp/halo-mali/libmali.so.0\",\n"
            "\t\t\"/tmp/halo-mali/libEGL.so.1\",\n"
            "\t\t\"/usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so\",\n"
            "\t\t\"/usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so\",\n"
            "\t\t\"libmali.so.1\",\n"
            "\t\t\"libmali.so.0\",\n"
            "\t\t\"libmali.so\",\n"
            "\t\t\"libEGL.so.1\",\n"
            "\t\t\"libEGL.so\",\n"
            "\t\t\"/usr/lib/aarch64-linux-gnu/libmali.so.1\",\n"
            "\t\t\"/usr/lib/aarch64-linux-gnu/libmali.so\",\n"
            "\t\t\"/usr/lib/libmali.so\",\n"
            "\t\t\"/usr/lib/aarch64-linux-gnu/libEGL.so.1\",\n"
            "\t\tNULL\n"
            "\t};\n"
            "\n"
            "\tfor (int i = 0; lib_candidates[i] && !egl_lib_handle; i++)\n"
            "\t{\n"
            "\t\tegl_lib_handle = dlopen(lib_candidates[i], RTLD_NOW | RTLD_GLOBAL);\n"
            "\t}\n"
            "\n"
            "#define RESOLVE_EGL(fn) do { \\\n"
            "\tif (egl_lib_handle) p_##fn = (pfn_##fn)dlsym(egl_lib_handle, #fn); \\\n"
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
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize entering resolve\");\n"
            "\tresolve_egl_functions();\n"
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize resolved, handle=%p\", egl_lib_handle);\n"
            "\n"
            "\tif (!p_eglGetCurrentDisplay || !p_eglGetCurrentContext ||\n"
            "\t    !p_eglQueryContext || !p_eglChooseConfig || !p_eglCreateContext || !p_eglMakeCurrent)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: dynamic EGL symbols unavailable; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize calling eglGetCurrentDisplay\");\n"
            "\tshare_display = p_eglGetCurrentDisplay();\n"
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_display=%p\", (void *)share_display);\n"
            "\tif (share_display == EGL_NO_DISPLAY || !share_display)\n"
            "\t{\n"
            "\t\thost_logf(HOST_LOG_INFO, \"EGL share: no active EGL display; building on GL thread\");\n"
            "\t\tshare_context = EGL_NO_CONTEXT;\n"
            "\t\treturn;\n"
            "\t}\n"
            "\n"
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize calling eglGetCurrentContext\");\n"
            "\tshare_context = p_eglGetCurrentContext();\n"
            "\thost_logf(HOST_LOG_INFO, \"DIAG: share_context=%p\", (void *)share_context);\n"
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
            print("[OK] Dynamische EGL-Aufloesung + share_initialize ersetzt")
        else:
            print("[WARN] old_share Block nicht gefunden - pruefe alternative Signatur")

    # --- 2. DIAG-Logs in run_create_context ---
    old_create = (
        "static void run_create_context(struct queue_cmd *cmd)\n"
        "{\n"
        "\tcmd->args.create_context.thread->context = scanout_open(&cmd->args.create_context.attr);\n"
        "\tcmd->args.create_context.thread->state = HOST_GLTHREAD_STATE_READY;\n"
        "\tshare_initialize();\n"
        "}"
    )
    new_create = (
        "static void run_create_context(struct queue_cmd *cmd)\n"
        "{\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: run_create_context ENTER\");\n"
        "\tcmd->args.create_context.thread->context = scanout_open(&cmd->args.create_context.attr);\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: scanout_open returned context=%p\", (void *)cmd->args.create_context.thread->context);\n"
        "\tcmd->args.create_context.thread->state = HOST_GLTHREAD_STATE_READY;\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: calling share_initialize\");\n"
        "\tshare_initialize();\n"
        "\thost_logf(HOST_LOG_INFO, \"DIAG: share_initialize completed\");\n"
        "}"
    )
    if old_create in content:
        content = content.replace(old_create, new_create, 1)
        print("[OK] DIAG-Logs in run_create_context eingefuegt")

    write(path, content)
    print("[SUCCESS] patch_gl_init_order.py erfolgreich ausgefuehrt.")


if __name__ == "__main__":
    main()
