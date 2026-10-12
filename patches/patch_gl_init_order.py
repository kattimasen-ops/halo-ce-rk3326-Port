#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_gl_init_order.py (v7 - DIAGNOSE)

Fuegt ausschliesslich Log-Zeilen in host_glthread.c ein, um den Punkt
des SIGILL nach dem GL-Thread-Start eindeutig zu lokalisieren.

Keine Verhaltensaenderung - nur zusaetzliche host_logf-Aufrufe.
Nach dem Test kann der Patch wieder entfernt werden.
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

    # --- 1. synced_sdl_gl_create_context ---
    old = (
        "static uint32_t synced_sdl_gl_create_context(uint32_t window)\n"
        "{\n"
        "\tstruct word_call call = { window, 0, 0, 0 };\n"
        "\n"
        "\tstart();\n"
        "\tglthread_sync(run_create_context, &call);\n"
        "\treturn call.result;\n"
        "}"
    )
    new = (
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
    if old in content:
        content = content.replace(old, new, 1); changed += 1
    else:
        print("[WARN] synced_sdl_gl_create_context nicht gefunden")

    # --- 2. synced_sdl_gl_make_current ---
    old = (
        "static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)\n"
        "{\n"
        "\tstruct word_call call = { window, context, 0, 0 };\n"
        "\n"
        "\tglthread_sync(run_make_current, &call);\n"
        "\treturn (int)call.result;\n"
        "}"
    )
    new = (
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
    if old in content:
        content = content.replace(old, new, 1); changed += 1
    else:
        print("[WARN] synced_sdl_gl_make_current nicht gefunden")

    # --- 3. run_create_context ---
    old = (
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
    new = (
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
    if old in content:
        content = content.replace(old, new, 1); changed += 1
    else:
        print("[WARN] run_create_context nicht gefunden")

    # --- 4. gl_thread_main sync case ---
    old = (
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
    new = (
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
    if old in content:
        content = content.replace(old, new, 1); changed += 1
    else:
        print("[WARN] gl_thread_main sync case nicht gefunden")

    write(path, content)
    print("[OK] host_glthread.c gepatcht mit DIAG-Logs (%d/4 Stellen)." % changed)
    if changed < 4:
        print("[WARN] Nicht alle Muster gefunden.")
        print("       host_glthread.c muss im Originalzustand sein (git checkout).")


if __name__ == "__main__":
    main()
