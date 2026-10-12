#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py (v5 - Final)

Stellt den Originalzustand von host_glthread.c wieder her, damit
share_initialize() wieder aktiv ist. Die libmali-hook.so behebt die
zugrundeliegenden EGL-Probleme (XInitThreads, eglChooseConfig).
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

    # Wenn der vorherige Patch schon angewendet wurde, Backup zurückspielen
    if os.path.exists(path + ".bak"):
        shutil.copy2(path + ".bak", path)
        print("[OK] host_glthread.c aus Backup wiederhergestellt.")
        return

    # Ansonsten: Patch anwenden, um share_initialize zu reaktivieren
    content = read(path)
    if "/* FIX v3: Init laeuft erst nach make_current" in content:
        # Patch rückgängig machen
        old_make = (
            "static void run_make_current(void *context)\n"
            "{\n"
            "\tstruct word_call *call = context;\n"
            "\tint kind;\n"
            "\n"
            "\tcall->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);\n"
            "\t/* FIX v3: Init laeuft erst nach make_current. share_initialize()\n"
            "\t   wird uebersprungen, weil Mali-G31-libmali in einem der\n"
            "\t   EGL-Aufrufe (eglQueryContext / eglChooseConfig) mit SIGILL\n"
            "\t   crasht. Ohne shared context laufen die Async-Program-Builder\n"
            "\t   nicht; Shader werden im Vordergrund gebaut (kein Gameplay-\n"
            "\t   Performance-Verlust, nur erster Start etwas langsamer). */\n"
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
            "}"
        )
        new_make = (
            "static void run_make_current(void *context)\n"
            "{\n"
            "\tstruct word_call *call = context;\n"
            "\tint kind;\n"
            "\n"
            "\tcall->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);\n"
            "\t/* FIX v5: libmali-hook.so (LD_PRELOAD) behebt XInitThreads und\n"
            "\t   eglChooseConfig. Init laeuft wieder komplett. */\n"
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
        if old_make in content:
            content = content.replace(old_make, new_make, 1)
            write(path, content)
            print("[OK] host_glthread.c: share_initialize reaktiviert (FIX v5).")
            return
    print("[INFO] host_glthread.c bereits im Original-Zustand.")
