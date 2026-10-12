#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py  (v2)

BUGFIX + DIAGNOSE:
1. Verschiebt die GL-Initialisierung (refill, share_initialize,
   scanout_open, builders_start) von run_create_context nach
   run_make_current, damit GL-Befehle erst nach SDL_GL_MakeCurrent
   laufen.
2. Loggt vor und nach jedem der vier Schritte, damit im Fehlerfall
   sichtbar ist, welcher Aufruf den SIGILL ausloest.

Nach der Diagnose kann das Logging entfernt werden; die Verschiebung
selbst bleibt bestehen.
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

    # ── 1. run_create_context: Init-Block entfernen ──
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

    # ── 2. run_make_current: Init-Block MIT Logging einfuegen ──
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
        "\t/* FIX + DIAGNOSE: Der GL-Kontext ist jetzt current. Die Init\n"
        "\t   laeuft hier statt in run_create_context. Jeder Schritt loggt\n"
        "\t   vorher und nachher, damit der SIGILL lokalisierbar ist. */\n"
        "\tif (call->result)\n"
        "\t{\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill start\");\n"
        "\t\tfor (kind = 0; kind < _glthread_name_kinds; kind++)\n"
        "\t\t{\n"
        "\t\t\tif (!reserves[kind].count)\n"
        "\t\t\t\trefill(kind, RESERVE_REFILL);\n"
        "\t\t}\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: share_initialize start\");\n"
        "\t\tshare_initialize();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: share_initialize done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: scanout_open start\");\n"
        "\t\tscanout_open();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: scanout_open done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: builders_start start\");\n"
        "\t\tbuilders_start();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: builders_start done\");\n"
        "\t}\n"
        "}"
    )

    if old_create in content and old_make in content:
        content = content.replace(old_create, new_create, 1)
        content = content.replace(old_make, new_make, 1)
        write(path, content)
        print("[OK] host_glthread.c: GL-Init nach make_current + Logging.")
        return

    print("[WARN] exaktes Muster nicht gefunden — bitte host_glthread.c pruefen.")
    print("       Erwartet: ungepatchter Original-Zustand.")
    sys.exit(0)


if __name__ == "__main__":
    main()
