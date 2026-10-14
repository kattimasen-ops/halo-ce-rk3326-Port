#!/bin/bash
# Halo: Combat Evolved – M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# RELEASE-BUILD: PGO (use) + LTO, alle Port-Optimierungen aktiv.
#
# Der Host wird dynamisch gelinkt. Er umgeht den SIGILL (LSE-Atomics)
# durch -march=armv8-a -mno-outline-atomics.
#
# Bibliotheks-Diagnose vor dem Spielstart:
#   - ldd-Ausgabe der Host-Binary in log.txt
#   - LD_DEBUG=libs-Log in halo-libdiag.txt
#   Damit laesst sich die Bibliothek identifizieren, die einen
#   etwaigen SIGILL ausloest.
#   Abschalten: HALO_LIBDIAG=0 in die Umgebung setzen.

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

# Standardmaessig inaktiv: Diagnose-Lauf bei Bedarf mit HALO_LIBDIAG=1
export HALO_LIBDIAG="${HALO_LIBDIAG:-0}"

# ── PFADE ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    echo "FEHLER: Skript-Verzeichnis nicht ermittelbar." >&2
    exit 1
fi
GAMEDIR="$SCRIPT_DIR/halo-ce"
if [ ! -d "$GAMEDIR" ]; then
    echo "FEHLER: $GAMEDIR existiert nicht." >&2
    exit 1
fi
cd "$GAMEDIR" || exit 1

# ── LOGGING ──────────────────────────────────────────────────────────
LOG="$GAMEDIR/log.txt"
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi
if ! touch "$LOG" 2>/dev/null; then
    LOG="/tmp/halo-log.txt"
    touch "$LOG" 2>/dev/null || LOG="/dev/null"
fi
exec >> "$LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_section() {
    log ""
    log "========================================================="
    log "== $*"
    log "========================================================="
}

log_section "START"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "GAMEDIR=$GAMEDIR"
log "Kernel=$(uname -r), Arch=$(uname -m)"
log "Datum=$(date)"
log "HALO_LIBDIAG=$HALO_LIBDIAG"

# ── LOCK ─────────────────────────────────────────────────────────────
exec 9> /tmp/halo-lock 2>/dev/null || true
if [ -e /proc/self/fd/9 ]; then
    if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; } 2>/dev/null; then
        log "Halo laeuft bereits"
        exit 1
    fi
fi

# ── PORTMASTER-CONTROLS ──────────────────────────────────────────────
PM_CONTROLFOLDER=""
for candidate in \
    "/opt/system/Tools/PortMaster" \
    "/opt/tools/PortMaster" \
    "$XDG_DATA_HOME/PortMaster" \
    "/roms/ports/PortMaster"; do
    if [ -d "$candidate" ]; then
        PM_CONTROLFOLDER="$candidate"
        break
    fi
done

if [ -n "$PM_CONTROLFOLDER" ] && [ -f "$PM_CONTROLFOLDER/control.txt" ]; then
    source "$PM_CONTROLFOLDER/control.txt" 2>/dev/null || true
    if [ -n "${CFW_NAME:-}" ] && [ -f "$PM_CONTROLFOLDER/mod_${CFW_NAME}.txt" ]; then
        source "$PM_CONTROLFOLDER/mod_${CFW_NAME}.txt" 2>/dev/null || true
    fi
    if command -v get_controls >/dev/null 2>&1; then
        get_controls 2>/dev/null || true
    fi
fi

if [ -n "${sdl_controllerconfig:-}" ]; then
    export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
    log "SDL_GAMECONTROLLERCONFIG aus PortMaster gesetzt."
elif [ -f "$GAMEDIR/sdl_mapping.py" ]; then
    SDL_MAP="$(cd "$GAMEDIR" && python3 sdl_mapping.py 2>/dev/null)"
    if [ -n "$SDL_MAP" ]; then
        export SDL_GAMECONTROLLERCONFIG="$SDL_MAP"
        log "SDL_GAMECONTROLLERCONFIG aus sdl_mapping.py gesetzt."
    fi
fi

# ── SYSTEMOPTIMIERUNG ────────────────────────────────────────────────
log_section "SYSTEMOPTIMIERUNG"

cpu_governor_path=""
for candidate in \
    /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
    if [ -w "$candidate" ]; then
        cpu_governor_path="$candidate"
        break
    fi
done
cpu_saved=""
if [ -n "$cpu_governor_path" ]; then
    cpu_saved=$(cat "$cpu_governor_path" 2>/dev/null)
    log "CPU-Governor: $cpu_saved -> performance"
    echo performance > "$cpu_governor_path" 2>/dev/null || true
fi
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$cpu/cpufreq/scaling_governor" ] && \
        echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
done

gpu_devfreq_path=""
for candidate in /sys/class/devfreq/ff400000.gpu /sys/class/devfreq/gpu; do
    if [ -d "$candidate" ]; then
        gpu_devfreq_path="$candidate"
        break
    fi
done
gpu_governor_saved=""; gpu_min_saved=""
if [ -n "$gpu_devfreq_path" ]; then
    [ -r "$gpu_devfreq_path/governor" ] && gpu_governor_saved=$(cat "$gpu_devfreq_path/governor" 2>/dev/null)
    log "GPU-Governor: $gpu_governor_saved -> performance"
    [ -w "$gpu_devfreq_path/governor" ] && \
        echo performance > "$gpu_devfreq_path/governor" 2>/dev/null || true
    if [ -r "$gpu_devfreq_path/available_frequencies" ] && [ -w "$gpu_devfreq_path/min_freq" ]; then
        gpu_min_saved=$(cat "$gpu_devfreq_path/min_freq" 2>/dev/null)
        max_freq=$(tr ' ' '\n' < "$gpu_devfreq_path/available_frequencies" | sort -n | tail -n 1)
        [ -n "$max_freq" ] && echo "$max_freq" > "$gpu_devfreq_path/min_freq" 2>/dev/null || true
    fi
fi

if swapon --show 2>/dev/null | grep -q zram; then
    log "ZRAM bereits aktiv."
else
    modprobe zram 2>/dev/null || true
    if [ -e /dev/zram0 ]; then
        echo 512M > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1 || true
        swapon /dev/zram0 2>/dev/null || true
        log "ZRAM aktiviert."
    fi
fi

HALO_SERVICE_STATE="/tmp/halo-ce-services.$$"
HALO_SERVICES_RESTORED=0

stop_service_if_active() {
    service="$1"
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "$service" >> "$HALO_SERVICE_STATE" 2>/dev/null || true
        log "stopping $service"
        command -v sudo >/dev/null 2>&1 && sudo -n systemctl stop "$service" 2>/dev/null || true
    fi
}

restore_services() {
    [ "$HALO_SERVICES_RESTORED" = "0" ] || return 0
    HALO_SERVICES_RESTORED=1
    if [ -f "$HALO_SERVICE_STATE" ]; then
        while IFS= read -r service; do
            [ -n "$service" ] || continue
            log "restoring $service"
            command -v sudo >/dev/null 2>&1 && sudo -n systemctl start "$service" 2>/dev/null || true
        done < "$HALO_SERVICE_STATE"
        rm -f "$HALO_SERVICE_STATE" 2>/dev/null || true
    fi
}

: > "$HALO_SERVICE_STATE" 2>/dev/null || true
stop_service_if_active tailscaled.service

saved=/tmp/halo-clocks
printf '%s|%s|%s\n' "$cpu_saved" "$gpu_governor_saved" "$gpu_min_saved" > "$saved" 2>/dev/null || true

restore() {
    log_section "RESTORE"
    if [ -f "$saved" ]; then
        IFS='|' read -r cpu_gov gpu_gov gpu_min < "$saved"
        [ -n "$cpu_gov" ] && [ -n "$cpu_governor_path" ] && [ -w "$cpu_governor_path" ] && \
            echo "$cpu_gov" > "$cpu_governor_path" 2>/dev/null || true
        if [ -n "$gpu_devfreq_path" ]; then
            [ -n "$gpu_gov" ] && [ -w "$gpu_devfreq_path/governor" ] && \
                echo "$gpu_gov" > "$gpu_devfreq_path/governor" 2>/dev/null || true
            [ -n "$gpu_min" ] && [ -w "$gpu_devfreq_path/min_freq" ] && \
                echo "$gpu_min" > "$gpu_devfreq_path/min_freq" 2>/dev/null || true
        fi
        rm -f "$saved"
    fi
    restore_services
    rm -f /var/run/battery-saver/halo.pause 2>/dev/null || true
    log "Restore abgeschlossen."
}
trap restore EXIT

mkdir -p /var/run/battery-saver 2>/dev/null && \
    touch /var/run/battery-saver/halo.pause 2>/dev/null || true

# ── SAVE-VERZEICHNISSE ───────────────────────────────────────────────
mkdir -p "$GAMEDIR/save" \
         "$GAMEDIR/save/z" \
         "$GAMEDIR/save/saved" \
         "$GAMEDIR/save/saved/player_profiles" \
         "$GAMEDIR/save/saved/player_profiles/default_profile" \
         "$GAMEDIR/save/saved/playlists" \
         "$GAMEDIR/save/saved/playlists/default_playlist" \
         "$GAMEDIR/save/saved/recordings" \
         "$GAMEDIR/save/saved/recordings/last_recording" 2>/dev/null || true

# ── DRI-RECHTE ───────────────────────────────────────────────────────
for node in /dev/dri/card0 /dev/dri/renderD128 /dev/fb0; do
    if [ -e "$node" ] && { [ ! -r "$node" ] || [ ! -w "$node" ]; }; then
        sudo -n chmod 666 "$node" 2>/dev/null || true
    fi
done

# ── MALI-SYMLINKS ────────────────────────────────────────────────────
SYSTEM_MALI=""
for candidate in \
    /usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so \
    /usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so \
    /usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-wayland-gbm.so \
    /usr/lib/aarch64-linux-gnu/libmali-midgard-t76x-r14p0-r0p0.so \
    /usr/lib/aarch64-linux-gnu/mali/libmali.so \
    /usr/lib/mali/libmali.so \
    /usr/lib/aarch64-linux-gnu/libmali.so.1 \
    /usr/lib/aarch64-linux-gnu/libmali.so \
    /usr/lib/libmali.so \
    /usr/local/lib/libmali.so \
    /usr/lib/aarch64-linux-gnu/libEGL.so.1 \
    /usr/lib/aarch64-linux-gnu/libEGL.so \
    /usr/lib/libEGL.so.1 \
    /usr/lib/libEGL.so; do
    if [ -f "$candidate" ]; then
        SYSTEM_MALI="$candidate"
        break
    fi
done

if [ -n "$SYSTEM_MALI" ] && [ -f "$SYSTEM_MALI" ]; then
    rm -rf /tmp/halo-mali
    mkdir -p /tmp/halo-mali
    for name in libmali.so.0 libmali.so.1 libmali.so libgbm.so.1 libgbm.so.1.0.0 libgbm.so libEGL.so.1 libEGL.so libGLESv2.so.2 libGLESv2.so libGLESv1_CM.so.1 libGLESv1_CM.so; do
        ln -sf "$SYSTEM_MALI" "/tmp/halo-mali/$name"
    done
    export LD_LIBRARY_PATH="/tmp/halo-mali:$GAMEDIR/libs.aarch64:$GAMEDIR:/roms/ports/libs:/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
    log "Mali-Symlinks in /tmp/halo-mali erstellt aus $SYSTEM_MALI"
else
    log "WARNUNG: Kein bekannter Mali-Blob gefunden - nutze System-Libraries."
    export LD_LIBRARY_PATH="$GAMEDIR/libs.aarch64:$GAMEDIR:/roms/ports/libs:/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
fi

# ── ALSA aufraeumen ──────────────────────────────────────────────────
ASOUNDRC="$HOME/.asoundrc"
if [ -f "$ASOUNDRC" ]; then
    HALO_ASOUNDRC_EXPECTED="$(printf 'pcm.!default { type hw; card 0; device 0 }\nctl.!default { type hw; card 0 }\n')"
    if [ "$(cat "$ASOUNDRC" 2>/dev/null)" = "$HALO_ASOUNDRC_EXPECTED" ]; then
        mv -f "$ASOUNDRC" "$ASOUNDRC.halo-backup" 2>/dev/null || rm -f "$ASOUNDRC" 2>/dev/null || true
        log "Alte .asoundrc (von einer frueheren Halo-Version) entfernt und gesichert."
    else
        log "Vorhandene .asoundrc stammt nicht von Halo - unangetastet."
    fi
fi

# ── SDL-UMGEBUNG ─────────────────────────────────────────────────────
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}"
unset SDL_AUDIODRIVER
unset AUDIODEV

# ── HALO-PFADE ───────────────────────────────────────────────────────
log_section "HALO-PFADE"
export HALO_DATA_ROOT="$GAMEDIR"
export HALO_SAVE_ROOT="$GAMEDIR/save"
log "HALO_DATA_ROOT=$HALO_DATA_ROOT"
log "HALO_SAVE_ROOT=$HALO_SAVE_ROOT"

# ── PERFORMANCE- & RUNTIME-TUNING ───────────────────────────────────
log_section "PERFORMANCE- & RUNTIME-TUNING"

# GL-Thread & async Program-Kompilierung
export HALO_SWAP_INTERVAL=0
export HALO_NO_VSYNC=1
export HALO_GL_THREAD="${HALO_GL_THREAD:-1}"
export HALO_GL_THREAD_FRAMES="${HALO_GL_THREAD_FRAMES:-1}"
export HALO_ASYNC_PROGRAMS="${HALO_ASYNC_PROGRAMS:-0}"
export HALO_BUTTON_REMAP=1

# Glibc Allocator Tuning (verhindert Page-Thrashing und Memory-Fragmentation auf 1GB RAM)
export MALLOC_TRIM_THRESHOLD_=131072
export MALLOC_MMAP_THRESHOLD_=131072

# Mali-G31 GPU / DDK Buffer Tuning & Pipelining
export MALI_MAX_ASYNC_BUFFER_COUNT=2
export MALI_BUFFER_PREALLOC=1

# Vita / Low-Spec Engine Optimierungen & Fallbacks
export HALO_PREVENT_CPU_SLEEP=1
export HALO_DISABLE_DEBUG_DRAWS=1
export HALO_FAST_ANIMATION_LOD=1

log "VSync AUS (HALO_SWAP_INTERVAL=0, HALO_NO_VSYNC=1)."
log "GL-Thread=1, Mali Async-Buffers=2, Allocator-Trim=128k, CPU Sleep Bypass=1."
log "Bild- und Detail-Einstellungen kommen aus config.toml & OpenCE Ingame-Menue."

# Debug- und Profiling-Logs sauber deaktivieren (verhindert I/O-Hänger)
unset HALO_DEBUG_LOGS 2>/dev/null || true
unset HALO_GPU_STATS 2>/dev/null || true
unset HALO_GL_TIMING 2>/dev/null || true
unset HALO_HITCH_LOG 2>/dev/null || true
unset HALO_FPS_LOG 2>/dev/null || true
unset HALO_PERF_LOG 2>/dev/null || true
unset HALO_MEMORY_STATS 2>/dev/null || true
unset HALO_SAMPLE 2>/dev/null || true
unset HALO_DEBUG_DRAW_CALLERS 2>/dev/null || true
unset HALO_DEBUG_FREEZE 2>/dev/null || true
unset HALO_DEBUG_LOD_BIAS 2>/dev/null || true
unset HALO_GL_FRAME_LOG 2>/dev/null || true
unset HALO_PACING_LOG 2>/dev/null || true
unset HALO_GPU_PASS_TIMING 2>/dev/null || true
unset HALO_GPU_TRACE_PASSES_AT 2>/dev/null || true
unset HALO_GPU_TRACE_PASSES_FRAMES 2>/dev/null || true
unset HALO_DEBUG_SKIP_GL 2>/dev/null || true

# ── MAPS-CHECK ───────────────────────────────────────────────────────
if [ ! -s "$GAMEDIR/maps/ui.map" ]; then
    log "FEHLER: $GAMEDIR/maps/ui.map fehlt."
    echo "FEHLER: maps/ui.map fehlt." >&2
    exit 1
fi

if [ ! -x ./halo ]; then
    log "FEHLER: ./halo fehlt oder nicht ausfuehrbar."
    echo "FEHLER: ./halo fehlt." >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════
# HOST-BIBLIOTHEKEN (Diagnose)
# ══════════════════════════════════════════════════════════════════════
log_section "HOST-BIBLIOTHEKEN"

if command -v file > /dev/null 2>&1; then
    log "file ./halo:"
    file ./halo 2>&1 | while IFS= read -r line; do log "  $line"; done
fi

if command -v readelf > /dev/null 2>&1; then
    log "readelf -d ./halo | grep NEEDED:"
    readelf -d ./halo 2>/dev/null | grep NEEDED | while IFS= read -r line; do log "  $line"; done || log "  (keine NEEDED)"
fi

if command -v ldd > /dev/null 2>&1; then
    log "ldd ./halo:"
    ldd ./halo 2>&1 | while IFS= read -r line; do log "  $line"; done || true
fi

log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
log "SDL_VIDEODRIVER=$SDL_VIDEODRIVER"

# ══════════════════════════════════════════════════════════════════════
# LD_DEBUG-Diagnose (HALO_LIBDIAG=1, Default)
# ══════════════════════════════════════════════════════════════════════
LIBDIAG_LOG="$GAMEDIR/halo-libdiag.txt"
if [ "${HALO_LIBDIAG:-0}" = "1" ]; then
    log ""
    log "HALO_LIBDIAG=1: LD_DEBUG=libs Diagnose-Lauf (max. 5 Sekunden) ..."
    : > "$LIBDIAG_LOG"

    if command -v timeout > /dev/null 2>&1; then
        # timeout ist vorhanden (coreutils)
        ( LD_DEBUG=libs timeout 5 ./halo ) > /dev/null 2>> "$LIBDIAG_LOG" || true
    else
        # Fallback ohne timeout: Hintergrund-Job + sleep + kill
        ( LD_DEBUG=libs ./halo ) > /dev/null 2>> "$LIBDIAG_LOG" &
        DIAG_PID=$!
        ( sleep 5 && kill -TERM "$DIAG_PID" 2>/dev/null ) &
        KILLER_PID=$!
        wait "$DIAG_PID" 2>/dev/null || true
        kill -TERM "$KILLER_PID" 2>/dev/null || true
        wait "$KILLER_PID" 2>/dev/null || true
    fi

    if [ -s "$LIBDIAG_LOG" ]; then
        head -200 "$LIBDIAG_LOG" > "$LIBDIAG_LOG.head"
        mv -f "$LIBDIAG_LOG.head" "$LIBDIAG_LOG"
        log "  $LIBDIAG_LOG geschrieben ($(wc -l < "$LIBDIAG_LOG") Zeilen)"
        log "  Erste 40 Zeilen (auch hier im Log):"
        head -40 "$LIBDIAG_LOG" | while IFS= read -r line; do log "    $line"; done
    else
        log "  WARNUNG: LD_DEBUG hat nichts geschrieben."
        log "  Pruefe: existiert ./halo? ist es ausfuehrbar?"
        ls -la ./halo 2>&1 | while IFS= read -r line; do log "    $line"; done
    fi
else
    log ""
    log "HALO_LIBDIAG=$HALO_LIBDIAG (Diagnose uebersprungen)."
    log "Zum Aktivieren: HALO_LIBDIAG=1 in die Umgebung setzen oder"
    log "die Zeile 'export HALO_LIBDIAG=1' oben in Halo.sh eintragen."
fi

# ══════════════════════════════════════════════════════════════════════
# SPIELSTART
# ══════════════════════════════════════════════════════════════════════
log_section "SPIELSTART"

GUEST_SIZE=$(stat -c%s ./halo_guest.elf 2>/dev/null || echo 0)
if [ "$GUEST_SIZE" -gt 0 ]; then
    GUEST_SIZE_MB=$((GUEST_SIZE / 1048576))
    log "halo_guest.elf: $GUEST_SIZE Bytes (~${GUEST_SIZE_MB} MB)"
fi

HALO_STDOUT="$GAMEDIR/halo-stdout.txt"
HALO_STDERR="$GAMEDIR/halo-stderr.txt"
: > "$HALO_STDOUT"
: > "$HALO_STDERR"

GPTOKEYB_PID=""
if [ -n "$PM_CONTROLFOLDER" ] && command -v gptokeyb >/dev/null 2>&1; then
    gptokeyb "./halo" >/dev/null 2>&1 &
    GPTOKEYB_PID=$!
fi
cleanup_gptokeyb() {
    [ -n "$GPTOKEYB_PID" ] && kill -0 "$GPTOKEYB_PID" 2>/dev/null && \
        kill -TERM "$GPTOKEYB_PID" 2>/dev/null || true
}
cleanup_all() {
    cleanup_gptokeyb
    restore
}
trap cleanup_all EXIT

log "Starte: ./halo"
./halo > "$HALO_STDOUT" 2> "$HALO_STDERR" &
HALO_PID=$!
log "PID=$HALO_PID"

forward_signal() {
    [ -n "$HALO_PID" ] && kill -0 "$HALO_PID" 2>/dev/null && \
        kill -TERM "$HALO_PID" 2>/dev/null || true
}
trap forward_signal TERM INT HUP

wait "$HALO_PID"
HALO_STATUS=$?

[ -n "$GPTOKEYB_PID" ] && kill -0 "$GPTOKEYB_PID" 2>/dev/null && {
    kill -TERM "$GPTOKEYB_PID" 2>/dev/null || true
    wait "$GPTOKEYB_PID" 2>/dev/null || true
}

log "halo beendet mit Status $HALO_STATUS"

log_section "ENDE"
sync
exit "$HALO_STATUS"
