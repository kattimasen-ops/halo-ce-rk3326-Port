#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
patch_settings_only.py  (v5)

Änderungen seit v4:
- Bugfix: Der Hook übergibt jetzt `function_index - PC_MENU_FUNCTION_BASE`
  an pc_menu_event_function_invoke, weil die OpenCE-Dispatcher-Funktion
  einen 0-basierten Index erwartet (sonst Out-of-bounds in
  pc_menu_function_name).
- Bugfix: Obergrenze 0x9000 im Dispatcher (nur Settings-Bereich).
- Bugfix: Return-Typ der externen Deklaration von 'void' auf 'int'
  geändert (die Funktion liefert boolean zurück, was in x0 landet).
- Bugfix: Statt bare `return;` jetzt `return TRUE;` — sauber für
  den Caller, der boolean erwartet.
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


def _split_top_level(text: str, sep: str = ",") -> list:
    parts = []
    depth = 0
    current = ""
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current)
    return parts


def _extract_param_names(signature: str) -> list:
    names = []
    for p in _split_top_level(signature, ","):
        p = p.strip()
        if not p or p == "void":
            continue
        p_clean = re.sub(r"\[[^\]]*\]\s*$", "", p)
        m = re.search(r"(\w+)\s*$", p_clean)
        if m:
            names.append(m.group(1))
    return names


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

    if "PC_MENU_FUNCTION_BASE" in content:
        print("[INFO] ui_widget_event_handler_functions.c bereits gepatcht.")
        return

    func_name = "ui_widget_event_handler_function_invoke"
    idx = content.find(func_name)
    if idx == -1:
        print(f"[WARN] {func_name} nicht gefunden.")
        return

    paren_open = content.find("(", idx)
    if paren_open == -1:
        print("[WARN] keine Parameterliste gefunden.")
        return

    depth = 0
    paren_close = -1
    for i in range(paren_open, len(content)):
        if content[i] == "(":
            depth += 1
        elif content[i] == ")":
            depth -= 1
            if depth == 0:
                paren_close = i
                break
    if paren_close == -1:
        print("[WARN] keine schliessende Klammer gefunden.")
        return

    brace_open = content.find("{", paren_close)
    if brace_open == -1:
        print("[WARN] keine oeffnende Klammer gefunden.")
        return

    signature = content[paren_open + 1:paren_close]
    names = _extract_param_names(signature)
    print(f"[INFO] Erkannte Parameter: {names}")

    if len(names) < 3:
        print(f"[WARN] zu wenige Parameter: {names}")
        return

    fi_idx = -1
    for i, n in enumerate(names):
        if n == "function_index":
            fi_idx = i
            break
    if fi_idx == -1:
        print(f"[WARN] 'function_index' nicht in {names}")
        return

    others = [(i, n) for i, n in enumerate(names) if i != fi_idx]
    widget_name = others[0][1]
    event_name = others[1][1]
    fi_name = names[fi_idx]
    wd_name = others[2][1] if len(others) > 2 else None

    print(f"[INFO] widget={widget_name} event={event_name} "
          f"fi={fi_name} wd={wd_name}")

    # v5: Korrekte Deklaration mit int-Rückgabetyp (boolean in C ist int).
    # Wichtig: Zeiger-Typen als void*, damit beliebige struct-Zeiger
    # übergeben werden können.
    hook_header = (
        "\n/* PC Settings Menu Hooks - v5 (dynamische Parametererkennung) */\n"
        "#include <stdint.h>\n"
        "#ifndef PC_MENU_FUNCTION_BASE\n"
        "#define PC_MENU_FUNCTION_BASE 0x8000\n"
        "#endif\n"
        "#ifndef PC_MENU_FUNCTION_TOP\n"
        "#define PC_MENU_FUNCTION_TOP  0x9000\n"
        "#endif\n"
        "extern int pc_menu_event_function_invoke(void *widget, void *event,\n"
        "                                         long function_index,\n"
        "                                         void *widget_deleted);\n"
    )
    content = content[:idx] + hook_header + content[idx:]
    offset = len(hook_header)
    new_brace_open = brace_open + offset

    wd_arg = wd_name if wd_name else "0"

    # v5 FIXES:
    #   1) Obergrenze PC_MENU_FUNCTION_TOP (0x9000)
    #   2) function_index - PC_MENU_FUNCTION_BASE  (OpenCE erwartet 0-basiert)
    #   3) return TRUE statt bare return
    #   4) wd_arg als void* cast, falls Zeiger NULL ist
    insertion = (
        f"\n    if ({fi_name} >= PC_MENU_FUNCTION_BASE && "
        f"{fi_name} < PC_MENU_FUNCTION_TOP) {{\n"
        f"        (void)pc_menu_event_function_invoke({widget_name}, "
        f"{event_name}, {fi_name} - PC_MENU_FUNCTION_BASE, "
        f"(void *){wd_arg});\n"
        f"        return TRUE;\n"
        f"    }}"
    )
    content = content[:new_brace_open + 1] + insertion + content[new_brace_open + 1:]

    write_file_content(file_path, content)
    print("[OK] ui_widget_event_handler_functions.c gepatcht (v5).")


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

    if "pc_menu_game_data_function_invoke" in content:
        print("[INFO] ui_widget_game_data_input_functions.c bereits gepatcht.")
        return

    func_name = "ui_widget_game_data_input_function_invoke"
    idx = content.find(func_name)
    if idx == -1:
        print(f"[WARN] {func_name} nicht gefunden.")
        return

    paren_open = content.find("(", idx)
    if paren_open == -1:
        print("[WARN] keine Parameterliste gefunden.")
        return

    depth = 0
    paren_close = -1
    for i in range(paren_open, len(content)):
        if content
