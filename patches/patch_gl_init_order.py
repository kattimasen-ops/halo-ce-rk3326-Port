#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py

BUGFIX: Die GL-Initialisierung in host_glthread.c lief vor SDL_GL_MakeCurrent.
Das führte dazu, dass refill() (glGenTextures etc.) ohne current context
aufgerufen wurde und auf ARMv8.0 mit SIGILL abstürzte.

Dieser Patch verschiebt die Initialisierung (refill, share_initialize,
scanout_open, builders_start) aus run_create_context nach run_make_current.
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


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    path = os.path.join(root, "port", "knulli", "host", "host_glthread.c")
    if not os.path.exists(path):
        print("[WARN] %s nicht gefunden" % path)
        sys.exit(0)

    if os.path.exists(path + ".bak"):
        print("[INFO] host_glthread.c ist bereits gepatcht (Backup existiert).")
        sys.exit(0)

    backup(path)
    content = read(path)

    # Alter run_create_context-Block (mit Init)
    old_create = (
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
    new_create = (
        "static void run_create_context(void *context)\n"
        "{\n"
        "\tstruct word_call *call = context;\n"
        "\n"
        "\tcall->result = host_sdl_gl_create_context(call->a);\n"
        "}"
    )

    # Alter run_make_current-Block (ohne Init)
    old_make = (
        "static void run_make_current(void *context)\n"
        "{\n"
        "\tstruct word_call *call = context;\n"
        "\n"
        "\tcall->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);\n"
        "}"
    )
    new_make = (
        "static void run_make_current(void *context)\n"
        "{\n"
        "\tstruct word_call *call = context;\n"
        "\tint kind;\n"
        "\n"
        "\tcall->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);\n"
        "\t/* FIX: Der GL-Kontext wird erst hier current. Vorher duerfen\n"
        "\t   keine GL-Befehle laufen - refill() ruft glGenTextures etc. auf\n"
        "\t   und loeste ohne current context SIGILL aus (x16 = -1). */\n"
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

    if old_create in content and old_make in content:
        content = content.replace(old_create, new_create, 1)
        content = content.replace(old_make, new_make, 1)
        write(path, content)
        print("[OK] host_glthread.c: GL-Init nach make_current verschoben.")
        return

    # Fallback: nur der Init-Block am Ende von run_create_context wird verschoben
    if "/* the reserve of names, now that there is a context */" in content:
        print("[WARN] exaktes Muster nicht gefunden, aber Init-Block existiert.")
        print("       Bitte host_glthread.c manuell pruefen.")
    else:
        print("[WARN] Muster nicht gefunden; moeglicherweise andere Version.")
    sys.exit(0)


if __name__ == "__main__":
    main()
