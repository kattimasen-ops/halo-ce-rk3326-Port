#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_settings_only.py (v6 - FINALE)

BUGFIX: Der Dispatcher-Bereich war leer (>= 0x8000 UND < 0x8000 ist
immer falsch). Die Obergrenze ist jetzt PC_MENU_FUNCTION_TOP = 0x9000.
Zusätzlich: function_index - PC_MENU_FUNCTION_BASE (0-basiert),
Rückgabetyp int, und return TRUE statt bare return.
"""
import os, re, shutil, sys

def create_backup(file_path):
    if os.path.exists(file_path) and not os.path.exists(file_path + ".bak"):
        shutil.copy2(file_path, file_path + ".bak")
        print(f"[BACKUP] Kopie erstellt: {file_path}.bak")

def read_file_content(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()

def write_file_content(path, content):
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

def _split_top_level(text, sep=","):
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch in "([": depth += 1
        elif ch in ")]": depth -= 1
        if ch == sep and depth == 0:
            parts.append(current); current = ""
        else:
            current += ch
    if current.strip(): parts.append(current)
    return parts

def _extract_param_names(signature):
    names = []
    for p in _split_top_level(signature, ","):
        p = p.strip()
        if not p or p == "void": continue
        p_clean = re.sub(r"\[[^\]]*\]\s*$", "", p)
        m = re.search(r"(\w+)\s*$", p_clean)
        if m: names.append(m.group(1))
    return names

def patch_ui_widget(base_dir):
    file_path = os.path.join(base_dir, "source", "interface", "ui_widget.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "ui_widget.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget.c nicht gefunden."); return
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

def patch_event_dispatcher(base_dir):
    file_path = os.path.join(base_dir, "source", "interface",
                              "ui_widget_event_handler_functions.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "ui_widget_event_handler_functions.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget_event_handler_functions.c nicht gefunden."); return

    create_backup(file_path)
    content = read_file_content(file_path)

    # Falls die Datei schon eine falsche Version hat: den leeren Bereich
    # "< 0x8000" entfernen und durch korrekte v6-Version ersetzen.
    # Wir prüfen auf "< 0x8000" und ersetzen die gesamte if-Bedingung.
    bad_pattern = re.compile(
        r"if\s*\(\s*function_index\s*>=\s*PC_MENU_FUNCTION_BASE\s*&&\s*function_index\s*<\s*0x8000\s*\)\s*\{"
        r"(.*?)\}"
        r"\s*(?:/\*.*?\*/\s*)?",
        re.DOTALL,
    )
    if bad_pattern.search(content):
        def repl(m):
            inner = m.group(1)
            return (
                "if (function_index >= PC_MENU_FUNCTION_BASE && "
                "function_index < PC_MENU_FUNCTION_TOP) {" + inner + "}"
            )
        content = bad_pattern.sub(repl, content, count=1)
        if "PC_MENU_FUNCTION_TOP" not in content:
            top_def = (
                "#ifndef PC_MENU_FUNCTION_TOP\n"
                "#define PC_MENU_FUNCTION_TOP 0x9000\n"
                "#endif\n"
            )
            content = content.replace(
                "if (function_index >= PC_MENU_FUNCTION_BASE",
                top_def + "if (function_index >= PC_MENU_FUNCTION_BASE",
                1,
            )
        write_file_content(file_path, content)
        print("[OK] ui_widget_event_handler_functions.c: Bereich auf 0x9000 korrigiert.")
        return

    if "PC_MENU_FUNCTION_TOP" in content or \
       "function_index < 0x9000" in content or \
       "function_index < 0x8FFF" in content:
        print("[INFO] ui_widget_event_handler_functions.c bereits korrekt."); return

    if "PC_MENU_FUNCTION_BASE" in content:
        content = content.replace(
            "if (function_index >= PC_MENU_FUNCTION_BASE)",
            "if (function_index >= PC_MENU_FUNCTION_BASE && "
            "function_index < PC_MENU_FUNCTION_TOP)", 1)
        if "PC_MENU_FUNCTION_TOP" not in content:
            content = content.replace(
                "#define PC_MENU_FUNCTION_BASE 0x8000",
                "#define PC_MENU_FUNCTION_BASE 0x8000\n"
                "#define PC_MENU_FUNCTION_TOP 0x9000", 1)
        write_file_content(file_path, content)
        print("[OK] ui_widget_event_handler_functions.c gepatcht."); return

    # Erster Patch (Datei noch nicht gepatcht): mit korrekter v6-Logik
    func_name = "ui_widget_event_handler_function_invoke"
    idx = content.find(func_name)
    if idx == -1:
        print(f"[WARN] {func_name} nicht gefunden."); return
    paren_open = content.find("(", idx)
    depth = 0; paren_close = -1
    for i in range(paren_open, len(content)):
        if content[i] == "(": depth += 1
        elif content[i] == ")":
            depth -= 1
            if depth == 0: paren_close = i; break
    brace_open = content.find("{", paren_close)
    signature = content[paren_open + 1:paren_close]
    names = _extract_param_names(signature)
    fi_idx = -1
    for i, n in enumerate(names):
        if n == "function_index": fi_idx = i; break
    if fi_idx == -1 or len(names) < 3:
        print(f"[WARN] Parameter nicht erkannt: {names}"); return
    others = [(i, n) for i, n in enumerate(names) if i != fi_idx]
    widget_name = others[0][1]
    event_name = others[1][1]
    fi_name = names[fi_idx]
    wd_name = others[2][1] if len(others) > 2 else None

    hook_header = (
        "\n/* PC Settings Menu Hooks - v6 */\n"
        "#include <stdint.h>\n"
        "#ifndef PC_MENU_FUNCTION_BASE\n"
        "#define PC_MENU_FUNCTION_BASE 0x8000\n"
        "#endif\n"
        "#ifndef PC_MENU_FUNCTION_TOP\n"
        "#define PC_MENU_FUNCTION_TOP 0x9000\n"
        "#endif\n"
        "extern int pc_menu_event_function_invoke(void *widget, void *event,\n"
        "                                          long function_index,\n"
        "                                          void *widget_deleted);\n"
    )
    content = content[:idx] + hook_header + content[idx:]
    offset = len(hook_header)
    new_brace_open = brace_open + offset
    wd_arg = wd_name if wd_name else "0"

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
    print("[OK] ui_widget_event_handler_functions.c gepatcht (v6).")

def patch_game_data_dispatcher(base_dir):
    file_path = os.path.join(base_dir, "source", "interface",
                              "ui_widget_game_data_input_functions.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir,
                                  "ui_widget_game_data_input_functions.c")
    if not os.path.exists(file_path):
        print("[WARN] ui_widget_game_data_input_functions.c nicht gefunden."); return
    create_backup(file_path)
    content = read_file_content(file_path)
    if "pc_menu_game_data_function_invoke" in content:
        print("[INFO] ui_widget_game_data_input_functions.c bereits gepatcht."); return
    func_name = "ui_widget_game_data_input_function_invoke"
    idx = content.find(func_name)
    if idx == -1:
        print(f"[WARN] {func_name} nicht gefunden."); return
    paren_open = content.find("(", idx)
    depth = 0; paren_close = -1
    for i in range(paren_open, len(content)):
        if content[i] == "(": depth += 1
        elif content[i] == ")":
            depth -= 1
            if depth == 0: paren_close = i; break
    brace_open = content.find("{", paren_close)
    signature = content[paren_open + 1:paren_close]
    names = _extract_param_names(signature)
    fi_idx = -1
    for i, n in enumerate(names):
        if n == "function_index": fi_idx = i; break
    if fi_idx == -1 or len(names) < 2:
        print(f"[WARN] Parameter nicht erkannt: {names}"); return
    others = [(i, n) for i, n in enumerate(names) if i != fi_idx]
    widget_name = others[0][1]
    fi_name = names[fi_idx]
    hook_header = (
        "\n/* PC Settings Menu Hooks - game data (v6) */\n"
        "#include <stdint.h>\n"
        "#ifndef PC_MENU_GAME_DATA_BASE\n"
        "#define PC_MENU_GAME_DATA_BASE 0x8000\n"
        "#endif\n"
        "#ifndef PC_MENU_GAME_DATA_TOP\n"
        "#define PC_MENU_GAME_DATA_TOP 0x9000\n"
        "#endif\n"
        "extern void pc_menu_game_data_function_invoke(void *widget,\n"
        "                                              long function_index);\n"
    )
    content = content[:idx] + hook_header + content[idx:]
    offset = len(hook_header)
    new_brace_open = brace_open + offset
    insertion = (
        f"\n    if ({fi_name} >= PC_MENU_GAME_DATA_BASE && "
        f"{fi_name} < PC_MENU_GAME_DATA_TOP) {{\n"
        f"        pc_menu_game_data_function_invoke({widget_name}, "
        f"{fi_name} - PC_MENU_GAME_DATA_BASE);\n"
        f"        return;\n"
        f"    }}"
    )
    content = content[:new_brace_open + 1] + insertion + content[new_brace_open + 1:]
    write_file_content(file_path, content)
    print("[OK] ui_widget_game_data_input_functions.c gepatcht (v6).")

def patch_cache_files(base_dir):
    file_path = os.path.join(base_dir, "source", "cache", "cache_files.c")
    if not os.path.exists(file_path):
        file_path = os.path.join(base_dir, "cache_files.c")
    if not os.path.exists(file_path):
        print("[WARN] cache_files.c nicht gefunden."); return
    create_backup(file_path)
    content = read_file_content(file_path)
    if "menu_tags_loaded" not in content:
        decl = ("\nextern void menu_tags_loaded(void);\n"
                "extern void menu_tags_unloaded(void);\n")
        content = decl + content
        content = re.sub(
            r"(cache_file_load\s*\([^)]*\)\s*\{)",
            r"\1\n    menu_tags_loaded();", content, count=1)
        content = re.sub(
            r"(cache_file_unload\s*\([^)]*\)\s*\{)",
            r"\1\n    menu_tags_unloaded();", content, count=1)
        write_file_content(file_path, content)
        print("[OK] cache_files.c gepatcht.")

def patch_buildsystem_and_shim(root_dir, patches_dir):
    shim_src = os.path.join(patches_dir, "port_settings_shim.c")
    target_dir = os.path.join(root_dir, "port", "linux", "game")
    if os.path.exists(shim_src) and os.path.exists(target_dir):
        shutil.copy2(shim_src, os.path.join(target_dir, "port_settings_shim.c"))
        print(f"[OK] port_settings_shim.c nach {target_dir} kopiert.")
    json_path = os.path.join(root_dir, "port.json")
    if os.path.exists(json_path):
        create_backup(json_path)
        content = read_file_content(json_path)
        if '"dl"' not in content:
            content = content.replace('"libs": [', '"libs": [\n    "dl",')
            write_file_content(json_path, content)

def main():
    root_dir = os.getcwd()
    patches_dir = os.getcwd()
    if len(sys.argv) > 1: root_dir = sys.argv[1]
    if len(sys.argv) > 2: patches_dir = sys.argv[2]
    print(f"=== patch_settings_only.py v6 ===")
    patch_ui_widget(root_dir)
    patch_event_dispatcher(root_dir)
    patch_game_data_dispatcher(root_dir)
    patch_cache_files(root_dir)
    patch_buildsystem_and_shim(root_dir, patches_dir)
    print("=== fertig ===")

if __name__ == "__main__":
    main()
