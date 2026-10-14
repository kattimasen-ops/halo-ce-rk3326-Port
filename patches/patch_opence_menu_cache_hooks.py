#!/usr/bin/env python3
"""patch_opence_menu_cache_hooks.py — Hookt das Menü-System in cache_files.c.

Modifiziert $SRC/source/cache/cache_files.c:
  - fügt eine Datei-globale Variable `global_tag_count` ein (das Menü-System
    wächst die Tag-Tabelle über den Header hinaus)
  - ersetzt direkte `cache_file_globals.tag_header->tag_count`-Zugriffe
    in tag_loaded und tag_iterator_next durch `global_tag_count`
  - fügt cache_files_tag_instances / cache_files_set_tag_instances ein
  - ruft menu_tags_loaded() in scenario_tags_load und menu_tags_unloaded()
    in scenario_tags_unload auf

Idempotent über Marker.
"""
import os
import sys

MARKER = "port: opence-menu-cache"


def apply_patch(src_root):
    print("== Patch: cache_files.c Menü-Hooks ==")
    path = os.path.join(src_root, "source", "cache", "cache_files.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print("  cache_files.c: bereits gepatcht.")
        return

    # 1. global_tag_count neben global_tag_instances deklarieren
    anchor = 'extern struct cache_file_tag_instance *global_tag_instances;\n'
    add = anchor + (
        '/* ' + MARKER + ': Menü-Tags wachsen die Tabelle über den Header hinaus */\n'
        'static long global_tag_count;\n'
    )
    if anchor not in text:
        print("FEHLER: global_tag_instances-Anker fehlt.", file=sys.stderr)
        sys.exit(1)
    text = text.replace(anchor, add, 1)

    # 2. tag_loaded: tag_count -> global_tag_count
    text = text.replace(
        'absolute_index < cache_file_globals.tag_header->tag_count',
        'absolute_index < global_tag_count',
    )

    # 3. Accessors einfügen, vor tag_files_open
    anchor = 'void tag_files_open(\n\tvoid)\n'
    add = (
        '/* ' + MARKER + ': Tag-Tabelle für menu_tags.c bereitstellen */\n'
        'void *cache_files_tag_instances(long *count)\n'
        '{\n'
        '\t*count = cache_file_globals.tags_loaded ? global_tag_count : 0;\n'
        '\treturn cache_file_globals.tags_loaded ? global_tag_instances : NULL;\n'
        '}\n\n'
        'void cache_files_set_tag_instances(void *instances, long count)\n'
        '{\n'
        '\tglobal_tag_instances = instances;\n'
        '\tglobal_tag_count = count;\n'
        '}\n\n'
    ) + anchor
    if anchor in text:
        text = text.replace(anchor, add, 1)
    else:
        print("WARNUNG: tag_files_open-Anker fehlt.", file=sys.stderr)

    # 4. scenario_tags_unload: menu_tags_unloaded vor dem Setzen von tags_loaded = FALSE
    anchor = '\tcache_file_globals.tags_loaded = FALSE;\n'
    add = (
        '\t/* ' + MARKER + ': Menü-Tags zuerst freigeben */\n'
        '\t{\n'
        '\t\textern void menu_tags_unloaded(void);\n'
        '\t\tmenu_tags_unloaded();\n'
        '\t}\n'
        '\tglobal_tag_instances = NULL;\n'
        '\tglobal_tag_count = 0;\n'
    ) + anchor
    if anchor in text:
        text = text.replace(anchor, add, 1)

    # 5. scenario_tags_load: global_tag_count setzen und menu_tags_loaded nach tags_loaded = TRUE
    anchor = '\t\t\tcache_file_globals.tags_loaded = TRUE;\n'
    add = (
        '\t\t\tglobal_tag_count = cache_file_globals.tag_header->tag_count;\n'
        + anchor +
        '\t\t\t/* ' + MARKER + ': Menü-Tags an die Tag-Tabelle anhängen */\n'
        '\t\t\t{\n'
        '\t\t\t\textern void menu_tags_loaded(char const *map_name);\n'
        '\t\t\t\tmenu_tags_loaded(cache_file_globals.header.name);\n'
        '\t\t\t}\n'
    )
    if anchor in text:
        text = text.replace(anchor, add, 1)

    with open(path, "w") as f:
        f.write(text)
    print("  cache_files.c gepatcht.")


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
