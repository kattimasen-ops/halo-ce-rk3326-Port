#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
patch_settings_only.py
Automatisches Skript zur sauberen Injektion des PC-Einstellungsmenüs.

NICHT MEHR dabei: die Expat/Zlib-Include-Pfad-Injektion in
tools/android_build.py bzw. tools/linux_build.py. Diese hat den
Ninja-Build gebrochen, weil die Zeichenkette "port/third_party/tomlc17"
im Upstream AUCH zur Konstruktion des Quellpfades verwendet wird
(Path(*GUEST_DIRS) / "tomlc17.c"). Sobald die Liste mehr als einen
Eintrag hat, entsteht ein verketteter Pfad wie
  port/third_party/tomlc17/port/third_party/expat/lib/.../tomlc17.c
und ninja findet die Datei nicht.

Die Include-Pfade werden jetzt stattdessen über die Umgebungsvariable
CPATH in build.sh gesetzt. Sowohl clang als auch gcc suchen Header in
den dort eingetragenen Verzeichnissen, ohne dass die Build-Dateien
angefasst werden müssen.
"""

import os
import re
import shutil
import sys


def create_backup(file_path: str) -> None:
    if os.path.exists(file_path) and not os.path.exists(file_path + ".bak"):
        shutil.copy2(file_path, file_path + ".bak")
        print(f"[BACKUP] Kopie erstellt: {file_path}.bak")


def read_file_content(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def write_file_content(path: str, content: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def patch_ui_widget(base_dir: str) -> None:
    file_path = os.path.join(base_dir, "source", "interface", "ui_widget.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "ui_widget.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget.c nicht gefunden.")
        return

    create_backup(file_path)
    content = read_file_content(file_path)

    hook_decl = (
        "\n/* PC Settings Menu Hooks - Typensicher */\n"
        "#include <stdint.h>\n"
        "#include <stdbool.h>\n"
        "extern bool pc_menu_tag(int32_t tag_index);\n"
    )

    if "pc_menu_tag" not in content:
        last_include = content.rfind("#include")
        if last_include != -1:
            end_line = content.find("\n", last_include) + 1
            content = content[:end_line] + hook_decl + content[end_line:]
        else:
            content = hook_decl + content

        write_file_content(file_path, content)
        print("[OK] ui_widget.c gepatcht.")


def patch_event_dispatcher(base_dir: str) -> None:
    file_path = os.path.join(base_dir, "source", "interface",
                              "ui_widget_event_handler_functions.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "ui_widget_event_handler_functions.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget_event_handler_functions.c nicht gefunden.")
        return

    create_backup(file_path)
    content = read_file_content(file_path)

    hook_header = (
        "\n#include <stdint.h>\n"
        "#ifndef PC_MENU_FUNCTION_BASE\n"
        "#define PC_MENU_FUNCTION_BASE 0x8000\n"
        "extern uint32_t pc_menu_event_function_invoke(int32_t function_index, "
        "int32_t widget_index, void *event_data);\n"
        "#endif\n"
    )

    if "PC_MENU_FUNCTION_BASE" not in content:
        content = hook_header + content

        pattern = r"(ui_widget_event_handler_function_invoke\s*\([^)]*\)\s*\{)"
        replacement = (
            r"\1\n"
            r"    if (function_index >= PC_MENU_FUNCTION_BASE) {\n"
            r"        return pc_menu_event_function_invoke((int32_t)function_index, "
            r"(int32_t)widget_index, event_data);\n"
            r"    }\n"
        )
        content, count = re.subn(pattern, replacement, content, count=1)

        if count > 0:
            write_file_content(file_path, content)
            print("[OK] ui_widget_event_handler_functions.c gepatcht.")
        else:
            print("[WARN] ui_widget_event_handler_function_invoke nicht gefunden.")


def patch_game_data_dispatcher(base_dir: str) -> None:
    file_path = os.path.join(base_dir, "source", "interface",
                              "ui_widget_game_data_input_functions.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir,
                                  "ui_widget_game_data_input_functions.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget_game_data_input_functions.c nicht gefunden.")
        return

    create_backup(file_path)
    content = read_file_content(file_path)

    hook_header = (
        "\n#include <stdint.h>\n"
        "extern void pc_menu_game_data_function_invoke(int32_t function_index, "
        "int32_t widget_index, void *data);\n"
    )

    if "pc_menu_game_data_function_invoke" not in content:
        content = hook_header + content

        pattern = r"(ui_widget_game_data_input_function_invoke\s*\([^)]*\)\s*\{)"
        replacement = (
            r"\1\n"
            r"    if (function_index >= 0x8000) {\n"
            r"        pc_menu_game_data_function_invoke((int32_t)function_index, "
            r"(int32_t)widget_index, data);\n"
            r"        return;\n"
            r"    }\n"
        )
        content, count = re.subn(pattern, replacement, content, count=1)

        if count > 0:
            write_file_content(file_path, content)
            print("[OK] ui_widget_game_data_input_functions.c gepatcht.")


def patch_cache_files(base_dir: str) -> None:
    file_path = os.path.join(base_dir, "source", "cache", "cache_files.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "cache_files.c")
    if not os.path.exists(file_path):
        print("[WARN] cache_files.c nicht gefunden.")
        return

    create_backup(file_path)
    content = read_file_content(file_path)

    if "menu_tags_loaded" not in content:
        decl = ("\nextern void menu_tags_loaded(void);\n"
                "extern void menu_tags_unloaded(void);\n")
        content = decl + content

        content = re.sub(
            r"(cache_file_load\s*\([^)]*\)\s*\{)",
            r"\1\n    menu_tags_loaded();",
            content,
            count=1,
        )
        content = re.sub(
            r"(cache_file_unload\s*\([^)]*\)\s*\{)",
            r"\1\n    menu_tags_unloaded();",
            content,
            count=1,
        )

        write_file_content(file_path, content)
        print("[OK] cache_files.c gepatcht.")


def patch_buildsystem_and_shim(root_dir: str, patches_dir: str) -> None:
    """Kopiert port_settings_shim.c aus patches/ in den Quellbaum und
    trägt libdl in port.json ein."""
    shim_src = os.path.join(patches_dir, "port_settings_shim.c")
    target_dir = os.path.join(root_dir, "port", "linux", "game")

    if os.path.exists(shim_src) and os.path.exists(target_dir):
        shutil.copy2(shim_src, os.path.join(target_dir, "port_settings_shim.c"))
        print(f"[OK] port_settings_shim.c nach {target_dir} kopiert.")
    else:
        if not os.path.exists(shim_src):
            print(f"[WARN] {shim_src} nicht gefunden.")
        if not os.path.exists(target_dir):
            print(f"[WARN] Zielordner {target_dir} nicht gefunden.")

    json_path = os.path.join(root_dir, "port.json")
    if os.path.exists(json_path):
        create_backup(json_path)
        content = read_file_content(json_path)
        if '"dl"' not in content:
            content = content.replace('"libs": [', '"libs": [\n    "dl",')
            write_file_content(json_path, content)
            print("[OK] port.json aktualisiert (libdl hinzugefügt).")


def main():
    root_dir = os.getcwd()
    patches_dir = os.getcwd()
    if len(sys.argv) > 1:
        root_dir = sys.argv[1]
    if len(sys.argv) > 2:
        patches_dir = sys.argv[2]

    print(f"=== Starte Patch-Vorgang in: {root_dir} ===")
    print(f"=== Patches-Verzeichnis: {patches_dir} ===")

    patch_ui_widget(root_dir)
    patch_event_dispatcher(root_dir)
    patch_game_data_dispatcher(root_dir)
    patch_cache_files(root_dir)
    patch_buildsystem_and_shim(root_dir, patches_dir)

    print("=== Patch-Vorgang abgeschlossen! ===")


if __name__ == "__main__":
    main()
