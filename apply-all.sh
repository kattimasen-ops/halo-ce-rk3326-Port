#!/usr/bin/env bash
#
# Wendet den kompletten M9 Pro (RK3326) Patch-Satz auf einen
# Halo CE Universal Source-Baum an.
#
#   ./apply_all.sh <source-root>
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${1:?usage: apply_all.sh <source-root>}
OPEN_CE_URL=${OPEN_CE_URL:-https://github.com/OpenCommunityEdition/OpenCE.git}
OPEN_CE_TARBALL_URL=${OPEN_CE_TARBALL_URL:-https://github.com/OpenCommunityEdition/OpenCE/archive/refs/heads/main.tar.gz}

[ -d "$SRC" ] || { echo "FEHLER: $SRC ist kein Verzeichnis" >&2; exit 1; }
SRC=$(cd "$SRC" && pwd)

PATCHES=$HERE/patches
MAIN_PATCH=$PATCHES/halo-ce-universal-knulli.patch
WORK_TMP=$(mktemp -d)
trap 'rm -rf "$WORK_TMP"' EXIT

# ── 1) OpenCE-Dateien holen ─────────────────────────────────────────
fetch_opence_files() {
    local opence_dir="$WORK_TMP/opence-source"
    local opence_tarball="$WORK_TMP/opence-main.tar.gz"

    echo "== Hole OpenCE-Dateien (port_settings.py + Menue-Ordner) ..."
    rm -rf "$opence_dir"

    if git clone --depth 1 "$OPEN_CE_URL" "$opence_dir" > /dev/null 2>&1; then
        echo "   + Git-Clone erfolgreich."
    else
        echo "   Git-Clone fehlgeschlagen, versuche Tarball ..."
        rm -f "$opence_tarball"
        if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
            -o "$opence_tarball" "$OPEN_CE_TARBALL_URL"; then
            echo "FEHLER: Konnte OpenCE nicht klonen und auch nicht als Tarball laden." >&2
            exit 1
        fi
        mkdir -p "$opence_dir"
        if ! tar -xzf "$opence_tarball" -C "$opence_dir" --strip-components=1; then
            echo "FEHLER: Konnte OpenCE-Tarball nicht entpacken." >&2
            exit 1
        fi
        echo "   + Tarball erfolgreich."
    fi

    if [ -f "$opence_dir/tools/port_settings.py" ]; then
        mkdir -p "$SRC/tools"
        cp "$opence_dir/tools/port_settings.py" "$SRC/tools/"
        echo "   + tools/port_settings.py"
    else
        echo "FEHLER: OpenCE hat keine tools/port_settings.py." >&2
        exit 1
    fi

    if [ -f "$opence_dir/tools/ce_menus.py" ]; then
        cp "$opence_dir/tools/ce_menus.py" "$SRC/tools/"
        echo "   + tools/ce_menus.py"
    fi

    if [ -d "$opence_dir/port/assets/menus/ce" ]; then
        mkdir -p "$SRC/port/assets/menus"
        rm -rf "$SRC/port/assets/menus/ce"
        cp -a "$opence_dir/port/assets/menus/ce" "$SRC/port/assets/menus/"
        count=$(find "$SRC/port/assets/menus/ce" -name "*.xml" | wc -l)
        echo "   + port/assets/menus/ce/ ($count XML-Dateien)"
    else
        echo "FEHLER: OpenCE hat keinen port/assets/menus/ce Ordner." >&2
        exit 1
    fi

    for extra in port/assets/menus/port_svg port/assets/menus/strings; do
        if [ -d "$opence_dir/$extra" ]; then
            cp -a "$opence_dir/$extra" "$SRC/$(dirname "$extra")/"
            echo "   + $extra"
        fi
    done

    for t in tools/menu_art.py tools/menu_files.py; do
        if [ -f "$opence_dir/$t" ]; then
            cp "$opence_dir/$t" "$SRC/tools/"
            echo "   + $t"
        fi
    done

    rm -rf "$opence_dir" "$opence_tarball"
    echo "== OpenCE-Dateien geholt."
}

# ── 2) Knulli-Patch (mit XML-Hunk-Entfernung) ────────────────────────
if [ ! -f "$MAIN_PATCH" ]; then
    echo "FEHLER: $MAIN_PATCH fehlt" >&2
    exit 1
fi

echo "== Entferne den video_settings.xml-Hunk aus dem Knulli-Patch (einmalig) ..."
python3 - "$MAIN_PATCH" <<'PYEOF'
import re
import sys
path = sys.argv[1]
text = open(path).read()
pattern = re.compile(
    r'diff --git a/port/assets/menus/ce/'
    r'main_menu\.settings_select\.player_setup\.player_profile_edit\.'
    r'video_settings\.xml[^\n]*\n'
    r'(?:(?!diff --git ).)*',
    re.DOTALL,
)
if not pattern.search(text):
    print("  XML-Hunk war nicht vorhanden.")
    sys.exit(0)
new_text = pattern.sub('', text)
open(path, 'w').write(new_text)
print("  XML-Hunk entfernt.")
PYEOF

fetch_opence_files

if git -C "$SRC" rev-parse --git-dir > /dev/null 2>&1; then
    if git -C "$SRC" apply --check --reverse "$MAIN_PATCH" > /dev/null 2>&1; then
        echo "== $MAIN_PATCH ist bereits angewendet - ueberspringe"
    else
        echo "== Pruefe, ob der Knulli-Patch auf den OpenCE-Dateien laeuft ..."
        if ! git -C "$SRC" apply --check "$MAIN_PATCH" 2>&1; then
            echo "FEHLER: Knulli-Patch kann auf den OpenCE-Dateien NICHT sauber angewendet werden." >&2
            exit 1
        fi
        echo "== git apply $(basename "$MAIN_PATCH")"
        git -C "$SRC" apply --whitespace=nowarn "$MAIN_PATCH"
    fi
else
    echo "== git apply --directory (kein .git gefunden)"
    git apply --whitespace=nowarn --directory="$SRC" "$MAIN_PATCH"
fi

# ── 3) port/knulli kopieren ──────────────────────────────────────────
if [ -d "$HERE/port/knulli" ]; then
    echo "== Kopiere port/knulli in den Quellbaum ..."
    rm -rf "$SRC/port/knulli"
    cp -a "$HERE/port/knulli" "$SRC/port/knulli"
    rm -rf "$SRC/port/knulli/__pycache__"
    chmod +x "$SRC/port/knulli/build.sh" 2>/dev/null || true
else
    echo "== port/knulli im Repo nicht vorhanden - ueberspringe"
fi

# ── 4) Fix 3b: -DHALO_ANDROID in port/knulli/build.sh ────────────────
if [ -f "$SRC/port/knulli/build.sh" ]; then
    if grep -q -- "-DHALO_ANDROID" "$SRC/port/knulli/build.sh"; then
        echo "port/knulli/build.sh: -DHALO_ANDROID bereits vorhanden"
    else
        python3 - "$SRC/port/knulli/build.sh" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "-DHALO_ANDROID" in text:
    sys.exit(0)
old = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\'
new = '-D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \\\n        -DHALO_ANDROID \\'
if old not in text:
    sys.exit(0)
text = text.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(text)
print("port/knulli/build.sh: -DHALO_ANDROID in CFLAGS")
PYEOF
    fi
fi

# ── 5) Python-Patches ────────────────────────────────────────────────
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
    if [ ! -f "$PATCHES/$script" ]; then
        echo "== $script nicht vorhanden - ueberspringe"
        continue
    fi
    echo "== python3 $script"
    if ! python3 "$PATCHES/$script" "$SRC"; then
        echo "WARNUNG: $script hat nichts geaendert" >&2
    fi
done

# ── 6) Fix 4a: glUniform4f -> glUniform4fv ───────────────────────────
if [ -f "$SRC/port/linux/src/d3d8_gl.c" ]; then
    python3 - "$SRC/port/linux/src/d3d8_gl.c" <<'PYEOF'
import re
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
if "fps_overlay_enabled" not in text:
    sys.exit(0)
pattern = re.compile(r'glUniform4f\(\s*fps_overlay_color\s*,\s*([^;]+?)\s*\)\s*;')
def repl(match):
    args = match.group(1).strip()
    return '{ const float overlay_color[4] = { ' + args + ' }; glUniform4fv(fps_overlay_color, 1, overlay_color); }'
new_text = pattern.sub(repl, text)
if new_text != text:
    open(path, "w").write(new_text)
    print("d3d8_gl.c: glUniform4f -> glUniform4fv")
PYEOF
fi

# ── 7) In-Game-Settings-Menus regenerieren ───────────────────────────
echo ""
echo "== Regeneriere die In-Game-Settings-Menus aus port_settings.py ..."
python3 - "$SRC" <<'PYEOF'
import os
import sys
src = sys.argv[1]
sys.path.insert(0, os.path.join(src, "tools"))
try:
    import port_settings
except ImportError as e:
    print(f"  HINWEIS: port_settings.py nicht importierbar ({e}).")
    sys.exit(0)
if not hasattr(port_settings, "settings_files"):
    print("  WARNUNG: settings_files() fehlt.")
    sys.exit(0)
files = port_settings.settings_files()
target = os.path.join(src, "port", "assets", "menus", "ce")
os.makedirs(target, exist_ok=True)
for name, lines in files.items():
    path = os.path.join(target, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("\n".join(lines))
    print(f"  geschrieben: {name}")
PYEOF

# ── 8) Credits-Wasserzeichen in statische Menue-XMLs ─────────────────
echo ""
echo "== Injiziere das Credits-Wasserzeichen in die statischen Menue-XMLs ..."
if [ -f "$PATCHES/patch_credits_xml.py" ]; then
    python3 "$PATCHES/patch_credits_xml.py" "$SRC"
else
    echo "  WARNUNG: patch_credits_xml.py nicht vorhanden"
fi

# ── 9) Verifikation ──────────────────────────────────────────────────
echo ""
echo "== Verifiziere Patch-Ergebnisse ..."
failed=0
check() {
    local file="$1" pattern="$2" name="$3"
    if [ -f "$SRC/$file" ] && grep -q -- "$pattern" "$SRC/$file"; then
        echo "   OK: $name"
    else
        echo "   FEHLT: $name ($file)"
        failed=1
    fi
}
check "source/cseries/cseries.h"                  "HALO_DEBUG_ALLOCATOR"                    "cseries.h Debug-Allocator"
check "source/effects/decals.c"                   "static __thread long surface_queue"      "decals.c __thread-Arrays"
check "source/math/matrix_math.c"                 "vmulq_n_f32"                             "matrix_math.c NEON"
check "port/android/guest/runtime/guest_string.c" "vld1q_u8"                                "guest_string.c NEON"
check "source/sound/game_sound.c"                 "obstruction_interval_value"              "game_sound.c Sound-Occlusion"
check "source/render/render_objects.c"            "HALO_MIN_OBJECT_PIXELS"                  "render_objects.c Distant"
check "source/render/render_objects.c"            "HALO_LIGHTING_REFRESH_DIVISOR"           "render_objects.c Lighting"
check "port/linux/src/port_config.c"              "HALO_SOUND_OBSTRUCTION_TICKS"            "port_config.c Sound"
check "port/linux/src/port_config.c"              "HALO_MIN_OBJECT_PIXELS"                  "port_config.c Distant"
check "port/linux/src/port_config.c"              "HALO_LIGHTING_REFRESH_DIVISOR"           "port_config.c Lighting"
check "port/linux/src/port_config.c"              "HALO_FPS_OVERLAY_CORNER"                 "port_config.c FPS"
check "port/linux/src/port_config.c"              "HALO_FAST_SHADERS"                       "port_config.c Knulli"
check "port/linux/src/port_config.c"              'display.model_detail", _config_real, "0.35"' "port_config.c model_detail"
check "port/linux/src/port_config.c"              'lighting_refresh_divisor", _config_integer, "2"' "port_config.c lighting"
check "port/linux/src/xinput_sdl.c"               "button_remap"                            "xinput_sdl.c Button-Remap"
check "port/linux/src/d3d8_gl.c"                  "__builtin_elementwise_min"               "d3d8_gl.c index_extent"
check "port/linux/src/d3d8_gl.c"                  "fps_overlay_enabled"                     "d3d8_gl.c FPS-Overlay"
check "port/linux/src/d3d8_gl.c"                  "static int draw_framebuffer_bound(void)" "d3d8_gl.c framebuffer_bound"
check "port/linux/src/d3d8_gl.c"                  "if (draw_framebuffer_bound())"           "d3d8_gl.c Discard"
check "source/main/main.c"                        "St0len-One"                              "main.c Credits"

if [ -f "$SRC/tools/port_settings.py" ]; then
    check "tools/port_settings.py" "display.fast_shaders" "port_settings.py Video-Rows"
    check "tools/port_settings.py" "button_top"           "port_settings.py button_top"
    check "tools/port_settings.py" "credits_watermark"    "port_settings.py Credits"
else
    echo "   HINWEIS: tools/port_settings.py fehlt."
fi

if [ -f "$SRC/port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" ]; then
    check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
        "op_fast_shaders" "video_settings.xml op_fast_shaders"
    check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
        "op_alpha_test_elision" "video_settings.xml op_alpha_test_elision"
    check "port/assets/menus/ce/main_menu.settings_select.player_setup.player_profile_edit.video_settings.xml" \
        "credits_watermark" "video_settings.xml Wasserzeichen"
else
    echo "   HINWEIS: video_settings.xml fehlt."
fi

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "FEHLER: Einige Optimierungen fehlen."
    exit 1
fi
echo ""
echo "== Alle Optimierungen sauber angewendet."
