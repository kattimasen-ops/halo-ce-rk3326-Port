#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
patch_missing_functions.py

Fuegt drei C-Funktionen in den Upstream ein, die von den OpenCE-Dateien
menu_tags.c, menu_files.c und hud_hires.c benoetigt werden, im Upstream
aber fehlen:

1. cache_files_tag_instances / cache_files_set_tag_instances
   (menu_tags.c) -> source/cache/cache_files.c
2. ui_widget_event_handler_function_name
   (menu_tags.c) -> source/interface/ui_widget_event_handler_functions.c
3. xgpu_gl_texture_deleted
   (menu_files.c) -> port/linux/src/d3d8_gl.c und port/linux/src/xgpu.h
"""

import os
import sys


def read(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def write(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def patch_cache_files(path):
    if not os.path.exists(path):
        print(f"[WARN] {path} nicht gefunden.")
        return

    text = read(path)

    if "cache_files_tag_instances" in text:
        print(f"[INFO] {path}: cache_files_tag_instances bereits vorhanden.")
        return

    addition = (
        "\n\n/* Port (Hybrid): die Menues (menu_tags.c) greifen auf die Liste der\n"
        "   geladenen Tag-Instanzen zu, um ihre eigenen Tags hinzuzufuegen. */\n"
        "void *cache_files_tag_instances(\n"
        "\tlong *count)\n"
        "{\n"
        "\tif (count)\n"
        "\t\t*count = cache_file_globals.tags_loaded ? "
        "cache_file_globals.tag_header->tag_count : 0;\n"
        "\treturn cache_file_globals.tags_loaded ? global_tag_instances : NULL;\n"
        "}\n"
        "\n"
        "void cache_files_set_tag_instances(\n"
        "\tvoid *instances,\n"
        "\tlong count)\n"
        "{\n"
        "\tglobal_tag_instances = instances;\n"
        "\t(void)count;\n"
        "}\n"
    )
    write(path, text + addition)
    print(f"[OK] {path}: cache_files_tag_instances hinzugefuegt.")


def patch_ui_widget_event_handler(path):
    if not os.path.exists(path):
        print(f"[WARN] {path} nicht gefunden.")
        return

    text = read(path)

    if "ui_widget_event_handler_function_name" in text:
        print(f"[INFO] {path}: ui_widget_event_handler_function_name bereits vorhanden.")
        return

    addition = (
        "\n\n/* Port (Hybrid): der Name einer Event-Handler-Funktion anhand ihres\n"
        "   Index. Wird von menu_tags.c (OpenCE) benoetigt. */\n"
        "char const *ui_widget_event_handler_function_name(\n"
        "\tlong function_index)\n"
        "{\n"
        "\treturn function_index >= 0 && "
        "function_index < (long)NUMBEROF(event_handler_function_list.names) ?\n"
        "\t\tevent_handler_function_list.names[function_index] : NULL;\n"
        "}\n"
    )
    write(path, text + addition)
    print(f"[OK] {path}: ui_widget_event_handler_function_name hinzugefuegt.")


def patch_d3d8_gl(path):
    if not os.path.exists(path):
        print(f"[WARN] {path} nicht gefunden.")
        return

    text = read(path)

    if "xgpu_gl_texture_deleted" in text:
        print(f"[INFO] {path}: xgpu_gl_texture_deleted bereits vorhanden.")
        return

    addition = (
        "\n\n/* Port (Hybrid): menu_files.c ruft diese Funktion auf, wenn es eine\n"
        "   Textur verwirft. Im Host-Build raeumt sie den GL-Textur-Cache auf;\n"
        "   im Upstream gibt es keinen solchen Aufruf. Damit menu_files.c\n"
        "   gelinkt werden kann, liefert diese Implementierung einen No-op,\n"
        "   weil der Textur-Cache bereits beim Frame-Wechsel aufgeraeumt wird. */\n"
        "void xgpu_gl_texture_deleted(unsigned int texture)\n"
        "{\n"
        "\t(void)texture;\n"
        "}\n"
    )
    write(path, text + addition)
    print(f"[OK] {path}: xgpu_gl_texture_deleted hinzugefuegt.")


def patch_xgpu_h(path):
    if not os.path.exists(path):
        print(f"[WARN] {path} nicht gefunden.")
        return

    text = read(path)

    if "xgpu_gl_texture_deleted" in text:
        print(f"[INFO] {path}: xgpu_gl_texture_deleted bereits deklariert.")
        return

    anchor = "void xgpu_texture_cache_begin_frame(void);"
    if anchor in text:
        text = text.replace(
            anchor,
            anchor + "\n/* Port (Hybrid): eine Textur wurde verworfen (menu_files.c) */\n"
                     "void xgpu_gl_texture_deleted(unsigned int texture);",
            1
        )
        write(path, text)
        print(f"[OK] {path}: xgpu_gl_texture_deleted deklariert.")
    else:
        write(path, text + "\nvoid xgpu_gl_texture_deleted(unsigned int texture);\n")
        print(f"[OK] {path}: xgpu_gl_texture_deleted (am Ende) deklariert.")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    patch_cache_files(os.path.join(root, "source", "cache", "cache_files.c"))
    patch_ui_widget_event_handler(
        os.path.join(root, "source", "interface", "ui_widget_event_handler_functions.c"))
    patch_d3d8_gl(os.path.join(root, "port", "linux", "src", "d3d8_gl.c"))
    patch_xgpu_h(os.path.join(root, "port", "linux", "src", "xgpu.h"))
    print("=== Fertig ===")


if __name__ == "__main__":
    main()
