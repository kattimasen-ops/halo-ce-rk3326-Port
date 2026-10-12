#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
patch_android_build_hybrid.py  (v6)

Erweitert tools/android_build.py im Upstream um:
1. Expat- und Zlib-Definitionen und -Quellen.
2. HALO_ARM64_GUEST=1 in den Guest-Flags.
3. Include-Pfade -I{EXPAT_DIR} und -I{ZLIB_DIR}.
4. -mno-outline-atomics in GUEST_ABI_FLAGS, damit Clang 22 auf dem
   Cortex-A35 (ARMv8.0) keine LSE-Atomics generiert (SIGILL-Fix).
"""

import os
import sys


def patch_android_build(path):
    if not os.path.exists(path):
        print(f"[WARN] {path} nicht gefunden.")
        return

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()

    changed = False

    # 1. EXPAT_DIR und ZLIB_DIR nach TOML_DIR einfuegen
    if "EXPAT_DIR" not in text:
        anchor = 'TOML_DIR = Path("port/third_party/tomlc17")'
        if anchor in text:
            addition = (
                anchor + "\n"
                "# Expat (port/third_party/expat): the menus' XML parser, used by\n"
                "# menu_files.c. Included only in the guest build.\n"
                'EXPAT_DIR = Path("port/third_party/expat")\n'
                'EXPAT_SOURCES = ("xmlparse.c", "xmlrole.c", "xmltok.c")\n'
                "# Zlib (port/third_party/zlib): what inflates the maps, the\n"
                "# menus' and the HUD's PNGs. Names prefixed (z_) so the\n"
                "# game's own zlib keeps its own names.\n"
                'ZLIB_DIR = Path("port/third_party/zlib")\n'
                'ZLIB_SOURCES = ("adler32.c", "crc32.c", "inffast.c", "inflate.c",\n'
                '                "inftrees.c", "uncompr.c", "zutil.c")\n'
                'ZLIB_DEFINES = ("-DZ_PREFIX", "-Dz_errmsg=z_port_errmsg")'
            )
            text = text.replace(anchor, addition, 1)
            changed = True
            print("[OK] EXPAT_DIR/ZLIB_DIR eingefuegt.")
        else:
            print("[WARN] TOML_DIR-Anker nicht gefunden.")
    else:
        print("[INFO] EXPAT_DIR bereits vorhanden.")

    # 2. HALO_ARM64_GUEST und -mno-outline-atomics in GUEST_ABI_FLAGS
    if "-mno-outline-atomics" not in text:
        anchor = '"-DHALO_ANDROID=1",'
        if anchor in text:
            text = text.replace(
                anchor,
                '"' + '-DHALO_ARM64_GUEST=1",\n    '
                '"-mno-outline-atomics",\n    ' + anchor,
                1)
            changed = True
            print("[OK] -mno-outline-atomics in GUEST_ABI_FLAGS.")
        else:
            print("[WARN] -DHALO_ANDROID=1-Anker nicht gefunden.")
    else:
        print("[INFO] -mno-outline-atomics bereits vorhanden.")

    # 3. -I{EXPAT_DIR}, -I{ZLIB_DIR} in platform_cflags
    if 'f"-I{EXPAT_DIR}"' not in text and "-I{EXPAT_DIR}" not in text:
        anchor = 'f"-I{TOML_DIR}", f"-I{KCP_DIR}", "-Isource -Isource/cseries",'
        replacement = ('f"-I{TOML_DIR}", f"-I{EXPAT_DIR}", f"-I{KCP_DIR}", '
                       'f"-I{ZLIB_DIR}", "-Isource -Isource/cseries",')
        if anchor in text:
            text = text.replace(anchor, replacement, 1)
            changed = True
            print("[OK] platform_cflags erweitert um EXPAT/ZLIB includes.")
        else:
            print("[WARN] platform_cflags-Anker nicht gefunden.")
    else:
        print("[INFO] EXPAT/ZLIB includes bereits vorhanden.")

    # 4. Expat-Objekte hinzufuegen
    if "for name in EXPAT_SOURCES:" not in text:
        anchor = 'objects.append(guest_object(TOML_DIR / "tomlc17.c", platform_cflags))'
        if anchor in text:
            addition = (
                anchor + "\n"
                "    # the menus' XML parser (port/third_party/expat; menu_files.c)\n"
                "    for name in EXPAT_SOURCES:\n"
                "        objects.append(guest_object(EXPAT_DIR / name, platform_cflags))"
            )
            text = text.replace(anchor, addition, 1)
            changed = True
            print("[OK] Expat-Objekte hinzugefuegt.")
        else:
            print("[WARN] tomlc17-Objekt-Anker nicht gefunden.")
    else:
        print("[INFO] Expat-Objekte bereits vorhanden.")

    # 5. Zlib-Objekte hinzufuegen
    if "for name in ZLIB_SOURCES:" not in text:
        anchor = 'objects.append(guest_object(KCP_DIR / "ikcp.c", platform_cflags))'
        if anchor in text:
            addition = (
                anchor + "\n"
                "    # the port's zlib (port/third_party/zlib)\n"
                "    for name in ZLIB_SOURCES:\n"
                "        objects.append(guest_object(ZLIB_DIR / name, "
                '" ".join([platform_cflags, *ZLIB_DEFINES,\n'
                '                                                               "-U__ARM_FEATURE_CRC32"])))'
            )
            text = text.replace(anchor, addition, 1)
            changed = True
            print("[OK] Zlib-Objekte hinzugefuegt.")
        else:
            print("[WARN] ikcp-Objekt-Anker nicht gefunden.")
    else:
        print("[INFO] Zlib-Objekte bereits vorhanden.")

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"[OK] {path} gepatcht.")
    else:
        print(f"[INFO] {path} unveraendert.")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    patch_android_build(os.path.join(root, "tools", "android_build.py"))
    print("=== Fertig ===")


if __name__ == "__main__":
    main()
