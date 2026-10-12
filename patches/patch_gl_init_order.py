#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py  (v3)

1. Verschiebt die GL-Initialisierung von run_create_context nach
   run_make_current (Fix v9).
2. Ueberspringt share_initialize() vollstaendig, weil eglQueryContext /
   eglChooseConfig auf der Mali-G31-libmali des M9 einen SIGILL ausloesen
   (x16 = 0xFFFFFFFFFFFFFFFF, Mali's uninitialisierter Dispatch-Slot).
   Folge: Async-Program-Builder sind aus; Shader werden im Vordergrund
   gebaut.
3. Behaelt das granulare Logging aller Init-Schritte bei.
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

    # ── 2. run_make_current: Init mit Logging, share_initialize SKIPPEN ──
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
        "\t/* FIX v3: Init laeuft erst nach make_current. share_initialize()\n"
        "\t   wird uebersprungen, weil eglQueryContext/eglChooseConfig auf\n"
        "\t   der Mali-G31-libmali einen SIGILL ausloest (x16 = -1).\n"
        "\t   Ohne shared context laufen die Async-Program-Builder nicht;\n"
        "\t   Shader werden im Vordergrund gebaut. */\n"
        "\tif (call->result)\n"
        "\t{\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill start\");\n"
        "\t\tfor (kind = 0; kind < _glthread_name_kinds; kind++)\n"
        "\t\t{\n"
        "\t\t\tif (!reserves[kind].count)\n"
        "\t\t\t\trefill(kind, RESERVE_REFILL);\n"
        "\t\t}\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: share_initialize skipped (Mali-G31 libmali)\");\n"
        "\t\tshare_context = EGL_NO_CONTEXT;\n"
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
        print("[OK] host_glthread.c: Init verschoben, share_initialize uebersprungen.")
        return

    print("[WARN] exaktes Muster nicht gefunden — bitte host_glthread.c auf")
    print("       den Original-Zustand zuruecksetzen (git checkout).")
    sys.exit(0)


if __name__ == "__main__":
    main()
