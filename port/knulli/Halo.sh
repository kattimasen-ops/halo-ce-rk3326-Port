# ── MALI-SYMLINKS ────────────────────────────────────────────────────
SYSTEM_MALI=""
for candidate in \
    /usr/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so \
    /usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so \
    /usr/lib/aarch64-linux-gnu/libmali.so.1 \
    /usr/lib/aarch64-linux-gnu/libmali.so \
    /usr/lib/libmali.so \
    /usr/lib/aarch64-linux-gnu/libEGL.so.1; do
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
    export LD_LIBRARY_PATH="/tmp/halo-mali:$GAMEDIR/libs.aarch64:$GAMEDIR"
    log "Mali-Symlinks in /tmp/halo-mali erstellt aus $SYSTEM_MALI"
else
    log "WARNUNG: Kein bekannter Mali-Blob gefunden - nutze System-Libraries."
    export LD_LIBRARY_PATH="$GAMEDIR/libs.aarch64:$GAMEDIR"
fi
