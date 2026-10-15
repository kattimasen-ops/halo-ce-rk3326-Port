/*
PORT_SETTINGS_SHIM.C (v4)

v4-Änderungen:
- platform_log wird nur aufgerufen, wenn es tatsächlich vorhanden ist.
- Keine variadischen ABI-Probleme mehr.
*/
#include "cseries.h"
#include <string.h>
#include <stdlib.h>

extern char const *config_string(char const *name);

__attribute__((weak)) void platform_log(char const *format, ...);

struct widget_instance;

int config_text(char const *name, char *text, unsigned int size) {
    char const *value;
    if (!text || size == 0) return 0;
    value = config_string(name);
    if (!value) {
        text[0] = 0;
        return 0;
    }
    {
        unsigned int length = (unsigned int)strlen(value);
        if (length >= size) length = size - 1;
        memcpy(text, value, length);
        text[length] = 0;
    }
    return 1;
}

int config_write(char const *name, char const *value) {
    /* Kein platform_log-Aufruf hier: variadische Funktionen über die
       ILP32/LP64-Grenze sind nicht ABI-sicher. */
    (void)name;
    (void)value;
    return 1;
}

int config_default(char const *name, char *text, unsigned int size) {
    return config_text(name, text, size);
}

void config_folder(char *path, unsigned long size) {
    if (!path || size == 0) return;
    path[0] = '.';
    if (size > 1) path[1] = 0;
}

void platform_display_apply(void) { return; }
void platform_request_quit(void) { return; }

int platform_window_sizes(long *widths, long *heights, int maximum) {
    if (!widths || !heights || maximum <= 0) return 0;
    if (maximum >= 2) {
        widths[0] = 640; heights[0] = 480;
        widths[1] = 800; heights[1] = 480;
        return 2;
    }
    widths[0] = 640; heights[0] = 480;
    return 1;
}

int platform_display_resolutions(long *widths, long *heights, int maximum) {
    if (!widths || !heights || maximum <= 0) return 0;
    widths[0] = 640; heights[0] = 480;
    return 1;
}

int platform_audio_devices(int recording, char (*names)[128], int maximum) {
    (void)recording;
    if (!names || maximum <= 0) return 0;
    strncpy(names[0], "Default Audio Device", 127);
    names[0][127] = '\0';
    return 1;
}

void ui_widget_port_go_back(struct widget_instance *widget) {
    (void)widget;
    return;
}
