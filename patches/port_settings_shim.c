/*
PORT_SETTINGS_SHIM.C (v2)

v2-Änderungen:
- config_write: loggt jetzt jeden Schreibversuch mit platform_log,
  damit man sieht, was die Settings-Screens zu speichern versuchen.
  Der Rückgabewert ist weiterhin 1 (success), aber ehrlich darüber,
  dass nur geloggt wird.
- Neue Funktion ui_widget_port_realloc_hint als Stub, falls vom
  Settings-Code aufgerufen.
- Null-Pointer-Guards in config_text.
*/

#include "cseries.h"

#include <string.h>
#include <stdlib.h>

/* ---------- Knulli-Konfigurations-API ---------- */

extern char const *config_string(char const *name);

/* ---------- Logging ---------- */

/* Schwache Referenz: wenn der Host platform_log nicht exportiert,
   läuft der Stub ohne Logging weiter. */
__attribute__((weak)) void platform_log(char const *format, ...);

/* ---------- ui_widget.c: struct widget_instance ---------- */

struct widget_instance;

/* ══════════════════════════════════════════════════════════════════════
   OpenCE-Konfigurations-API, auf Knulli gemappt
   ══════════════════════════════════════════════════════════════════════ */

int config_text(char const *name, char *text, unsigned int size)
{
	char const *value;

	if (!text || size == 0)
		return 0;
	value = config_string(name);
	if (!value)
	{
		text[0] = 0;
		return 0;
	}
	{
		unsigned int length = (unsigned int)strlen(value);
		if (length >= size)
			length = size - 1;
		memcpy(text, value, length);
		text[length] = 0;
	}
	return 1;
}

int config_write(char const *name, char const *value)
{
	/* v2: Der Knulli-Port hat kein beschreibbares config.toml-Backend
	   für den Guest-Kontext. Wir loggen den Versuch und geben Erfolg
	   zurück, damit die Menüs nicht abbrechen. Der eigentliche
	   Schreibvorgang müsste vom Host-Handler übernommen werden. */
	if (platform_log && name && value)
		platform_log("shim: setting %s = %s (not persisted)", name, value);
	return 1;
}

int config_default(char const *name, char *text, unsigned int size)
{
	return config_text(name, text, size);
}

void config_folder(char *path, unsigned long size)
{
	if (!path || size == 0)
		return;
	path[0] = '.';
	if (size > 1)
		path[1] = 0;
}

/* ══════════════════════════════════════════════════════════════════════
   OpenCE-Plattform-API, Stubs
   ══════════════════════════════════════════════════════════════════════ */

void platform_display_apply(void)
{
	return;
}

void platform_request_quit(void)
{
	return;
}

int platform_window_sizes(long *widths, long *heights, int maximum)
{
	if (!widths || !heights || maximum <= 0)
		return 0;
	if (maximum >= 2)
	{
		widths[0] = 640; heights[0] = 480;
		widths[1] = 800; heights[1] = 480;
		return 2;
	}
	widths[0] = 640; heights[0] = 480;
	return 1;
}

int platform_display_resolutions(long *widths, long *heights, int maximum)
{
	if (!widths || !heights || maximum <= 0)
		return 0;
	widths[0] = 640; heights[0] = 480;
	return 1;
}

int platform_audio_devices(char *names, int maximum, int name_size)
{
	const char *default_device = "Default Audio Device";
	int length;

	if (maximum <= 0 || name_size <= 0 || names == NULL)
		return 0;

	length = (int)strlen(default_device) + 1;
	if (length > name_size)
		length = name_size;

	memcpy(names, default_device, length - 1);
	names[length - 1] = '\0';

	return 1;
}

/* ══════════════════════════════════════════════════════════════════════
   ui_widget_port_go_back
   ══════════════════════════════════════════════════════════════════════ */

void ui_widget_port_go_back(struct widget_instance *widget)
{
	(void)widget;
	return;
}
