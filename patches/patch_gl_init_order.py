#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py (v6)

Zwei Aenderungen gegenueber v3:
  1. share_initialize() bleibt uebersprungen (v3-Verhalten).
  2. Zwei zusaetzliche Log-Zeilen, um den Crash NACH der Init zu
     lokalisieren:
       - eine am Ende von run_make_current (GL-Thread)
       - eine in synced_sdl_gl_make_current vor und nach glthread_sync
         (Haupt-Thread)
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
        print("[INFO] host_glthread.c ist bereits gepatcht.")
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

    # ── 2. run_make_current: Init + Logs ──
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
        "\t/* FIX v6: Init laeuft erst nach make_current. share_initialize()\n"
        "\t   wird uebersprungen, weil Mali-G31-libmali in einem der\n"
        "\t   EGL-Aufrufe (eglQueryContext / eglChooseConfig) mit SIGILL\n"
        "\t   crasht. Zusaetzliche Logs lokalisieren den weiteren Ablauf. */\n"
        "\tif (call->result)\n"
        "\t{\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill start\");\n"
        "\t\tfor (kind = 0; kind < _glthread_name_kinds; kind++)\n"
        "\t\t{\n"
        "\t\t\tif (!reserves[kind].count)\n"
        "\t\t\t\trefill(kind, RESERVE_REFILL);\n"
        "\t\t}\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: refill done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: share_initialize skipped (Mali-G31)\");\n"
        "\t\tshare_context = EGL_NO_CONTEXT;\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: scanout_open start\");\n"
        "\t\tscanout_open();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: scanout_open done\");\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: builders_start start\");\n"
        "\t\tbuilders_start();\n"
        "\t\thost_logf(HOST_LOG_INFO, \"gl-init: builders_start done\");\n"
        "\t}\n"
        "\thost_logf(HOST_LOG_INFO, \"gl-init: run_make_current RETURNING\");\n"
        "}"
    )

    # ── 3. synced_sdl_gl_make_current: Logs vor/nach glthread_sync ──
    old_sync = (
        "static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tstruct word_call call = { window, context, 0, 0 };\n"
        "\n"
        "\tglthread_sync(run_make_current, &call);\n"
        "\treturn (int)call.result;\n"
        "}"
    )
    new_sync = (
        "static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tstruct word_call call = { window, context, 0, 0 };\n"
        "\n"
        "\thost_logf(HOST_LOG_INFO, \"sync-make-current: ENTER (Hauptthread)\");\n"
        "\tglthread_sync(run_make_current, &call);\n"
        "\thost_logf(HOST_LOG_INFO, \"sync-make-current: EXIT result=%d\", call.result);\n"
        "\treturn (int)call.result;\n"
        "}"
    )

    changed = 0
    if old_create in content:
        content = content.replace(old_create, new_create, 1)
        changed += 1
    if old_make in content:
        content = content.replace(old_make, new_make, 1)
        changed += 1
    if old_sync in content:
        content = content.replace(old_sync, new_sync, 1)
        changed += 1

    if changed >= 2:
        write(path, content)
        print("[OK] host_glthread.c gepatcht (%d Stellen geaendert)." % changed)
        return

    print("[WARN] Muster nicht gefunden.")
    print("       host_glthread.c auf Original zuruecksetzen:")
    print("       git checkout port/knulli/host/host_glthread.c")
    sys.exit(1)


if __name__ == "__main__":
    main()
