#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_debug_gl.py

TEMPORÄRE Debug-Patches für die Diagnose des SIGILL im GL-Setup-Pfad.

Fügt Log-Zeilen in host_glthread.c und host_sdl2.c ein, damit wir sehen,
welche Host-Funktion der Guest zuletzt aufruft, bevor der Prozess mit
SIGILL stirbt.

Nach der Diagnose das Skript und die zwei Zeilen in build.sh wieder
entfernen. Es ändert KEINE Logik, nur zusätzliche host_logf-Aufrufe.
"""

import os
import shutil
import sys


def backup(path):
    if os.path.exists(path) and not os.path.exists(path + ".bak"):
        shutil.copy2(path, path + ".bak")


def read(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def write(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def patch_host_glthread(root):
    path = os.path.join(root, "port", "knulli", "host", "host_glthread.c")
    if not os.path.exists(path):
        print("[WARN] %s nicht gefunden" % path)
        return False
    backup(path)
    content = read(path)

    marker = '/* DIAG-GL */ host_logf(HOST_LOG_INFO, "import: %s -> %p", name ? name : "(null)", function);'
    if marker in content:
        print("[INFO] host_glthread.c bereits gepatcht.")
        return True

    needle = "void *host_import_wrap(const char *name, void *function)\n{"
    if needle not in content:
        print("[WARN] host_import_wrap nicht gefunden in host_glthread.c")
        return False

    replacement = needle + "\n\t" + marker
    content = content.replace(needle, replacement, 1)
    write(path, content)
    print("[OK] host_glthread.c gepatcht (host_import_wrap loggt jetzt).")
    return True


def patch_host_sdl2(root):
    path = os.path.join(root, "port", "knulli", "host", "host_sdl2.c")
    if not os.path.exists(path):
        print("[WARN] %s nicht gefunden" % path)
        return False
    backup(path)
    content = read(path)

    # host_sdl_gl_create_context: Log vor und nach SDL_GL_CreateContext
    old_create = (
        "\tSDL_Window *object = handle_get(window, _handle_window);\n"
        "\tSDL_GLContext context;\n"
        "\n"
        "\tif (!object)\n"
        "\t\treturn 0;\n"
        "\tcontext = SDL_GL_CreateContext(object);\n"
        "\tif (!context)\n"
    )
    new_create = (
        "\tSDL_Window *object = handle_get(window, _handle_window);\n"
        "\tSDL_GLContext context;\n"
        "\n"
        '\t/* DIAG-GL */ host_logf(HOST_LOG_INFO, "sdl_create_context ENTER window=%u object=%p", window, (void *)object);\n'
        "\tif (!object)\n"
        "\t\treturn 0;\n"
        "\tcontext = SDL_GL_CreateContext(object);\n"
        '\t/* DIAG-GL */ host_logf(HOST_LOG_INFO, "SDL_GL_CreateContext returned %p (%s)", (void *)context, context ? "OK" : SDL_GetError());\n'
        "\tif (!context)\n"
    )
    if old_create in content:
        content = content.replace(old_create, new_create, 1)
        print("[OK] host_sdl2.c host_sdl_gl_create_context gepatcht.")
    elif "sdl_create_context ENTER" in content:
        print("[INFO] host_sdl_gl_create_context bereits gepatcht.")
    else:
        print("[WARN] host_sdl_gl_create_context Pattern nicht gefunden.")

    # host_sdl_gl_make_current: Log nach dem Aufruf
    old_make = (
        "int host_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\treturn SDL_GL_MakeCurrent(handle_get(window, _handle_window), handle_get(context, _handle_context)) == 0;\n"
        "}"
    )
    new_make = (
        "int host_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tint _diag_result = SDL_GL_MakeCurrent(handle_get(window, _handle_window), handle_get(context, _handle_context)) == 0;\n"
        '\t/* DIAG-GL */ host_logf(HOST_LOG_INFO, "sdl_make_current window=%u context=%u -> %d (%s)", window, context, _diag_result, _diag_result ? "OK" : SDL_GetError());\n'
        "\treturn _diag_result;\n"
        "}"
    )
    if old_make in content:
        content = content.replace(old_make, new_make, 1)
        print("[OK] host_sdl2.c host_sdl_gl_make_current gepatcht.")
    elif "sdl_make_current" in content:
        print("[INFO] host_sdl_gl_make_current bereits gepatcht.")
    else:
        print("[WARN] host_sdl_gl_make_current Pattern nicht gefunden.")

    write(path, content)
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    print("=== patch_debug_gl.py in %s ===" % root)
    patch_host_glthread(root)
    patch_host_sdl2(root)
    print("=== fertig ===")


if __name__ == "__main__":
    main()
