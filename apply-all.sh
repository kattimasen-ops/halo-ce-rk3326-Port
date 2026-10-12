#!/bin/bash
# ==============================================================================
# apply-all.sh - Wendet ALLE Patches deterministisch auf den Upstream an
# ==============================================================================
# Fuehrt alle Schritte aus:
#   1. Knulli-Patch (Universal-Patch)
#   2. Settings-Only-Kopien (menu_functions.c, port_settings_shim.c)
#   3. Forward-Deklarationen in menu_files.c
#   4. -DHALO_ANDROID in port/knulli/build.sh
#   5. Alle Python-Patches (Memory Pools, NEON Math, Vita Opts, etc.)
#   6. Fix 4a: glUniform4f -> glUniform4fv
#   7. In-Game-Settings-Menue-Dateien regenerieren
#   8. Fix 4b: Button-Remap und Konfigurations-Defaults
# ==============================================================================

set -e

SRC="${1:-.}"
PATCHES="${2:-$(dirname "$0")/patches}"

echo "══════════════════════════════════════════════════════════════════════"
echo " Halo CE Patches anwenden (apply-all.sh)"
echo " Ziel:    $SRC"
echo " Patches: $PATCHES"
echo "══════════════════════════════════════════════════════════════════════"

# ── 1) Knulli-Patch ──────────────────────────────────────────────────
KNULLI_PATCH="$PATCHES/halo-ce-universal-knulli.patch"
if [ -f "$KNULLI_PATCH" ]; then
    echo ""
    echo "== 1. Knulli-Patch anwenden ..."
    if git -C "$SRC" apply --check "$KNULLI_PATCH" 2>/dev/null; then
        git -C "$SRC" apply "$KNULLI_PATCH"
        echo "   + Knulli-Patch erfolgreich angewendet."
    else
        echo "   [INFO] Knulli-Patch bereits angewendet oder kollidiert nicht."
    fi
else
    echo "   [WARN] $KNULLI_PATCH fehlt."
fi

# ── 2) Settings-Only Dateien kopieren ────────────────────────────────
echo ""
echo "== 2. Kopiere menu_functions.c und port_settings_shim.c ..."
if [ -f "$PATCHES/settings_only_menu_functions.c" ]; then
    cp "$PATCHES/settings_only_menu_functions.c" "$SRC/port/linux/game/menu_functions.c"
    echo "   + menu_functions.c (settings-only) kopiert"
fi
if [ -f "$PATCHES/port_settings_shim.c" ]; then
    cp "$PATCHES/port_settings_shim.c" "$SRC/port/linux/game/port_settings_shim.c"
    echo "   + port_settings_shim.c kopiert"
fi

# ── 3) menu_files.c Forward-Deklarationen ────────────────────────────
echo ""
echo "== 3. menu_files.c Forward-Deklarationen pruefen ..."
if [ -f "$SRC/port/linux/src/menu_files.c" ]; then
    python3 - "$SRC/port/linux/src/menu_files.c" <<'PYEOF'
import sys, os
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "extern void config_folder" in text and "extern void xgpu_gl_texture_deleted" in text:
    print("   + Bereits deklariert.")
    sys.exit(0)
decl = (
    "/* Forward-Deklarationen fuer Host-Funktionen */\n"
    "#ifdef HALO_ARM64_GUEST\n"
    "#ifndef MENU_FILES_HOST_FUNCS_DECLARED\n"
    "#define MENU_FILES_HOST_FUNCS_DECLARED\n"
    "extern void config_folder(char *folder, unsigned int size);\n"
    "extern void xgpu_gl_texture_deleted(unsigned int texture);\n"
    "#endif\n"
    "#endif\n"
)
with open(path, "w") as f:
    f.write(decl + "\n" + text)
print("   + Forward-Deklarationen eingefuegt.")
PYEOF
fi

# ── 4) -DHALO_ANDROID in port/knulli/build.sh ─────────────────────────
if [ -f "$SRC/port/knulli/build.sh" ]; then
    python3 - "$SRC/port/knulli/build.sh" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\'
new = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\\n        -DHALO_ANDROID \\'
if old in text:
    text = text.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(text)
    print("   + -DHALO_ANDROID in port/knulli/build.sh ergaenzt")
PYEOF
fi

# ── 5) Python-Patches ────────────────────────────────────────────────
echo ""
echo "== 5. Fuehre alle Performance- und Stabilitaets-Patches aus ..."
for script in \
    patch_memory_pools.py \
    patch_neon_math.py \
    patch_vita_optimizations.py \
    patch_button_remap.py \
    patch_index_extent_neon.py \
    patch_fps_overlay.py \
    patch_draw_framebuffer_bound.py \
    patch_settings_menu.py \
    patch_config_defaults.py \
    patch_credits.py \
    patch_gl_init_order.py; do
    if [ -f "$PATCHES/$script" ]; then
        echo "   -> python3 $script"
        python3 "$PATCHES/$script" "$SRC" || echo "   [WARN] $script ohne Aenderung"
    fi
done

# ── 6) In-Game-Settings-Menus regenerieren ───────────────────────────
echo ""
echo "== 6. Regeneriere Settings-Menues via port_settings.py ..."
if [ -f "$SRC/tools/port_settings.py" ]; then
    python3 - "$SRC" <<'PYEOF'
import os, sys
src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))
try:
    import port_settings
    if hasattr(port_settings, "settings_files"):
        for rel_path, content in port_settings.settings_files():
            full = os.path.join(src, rel_path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(content)
        print("   + Settings-Menue-Dateien erfolgreich generiert.")
except Exception as e:
    print(f"   [WARN] port_settings: {e}")
PYEOF
fi

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " Alle Patches erfolgreich angewendet!"
echo "══════════════════════════════════════════════════════════════════════"
