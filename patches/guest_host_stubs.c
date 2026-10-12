/*
GUEST_HOST_STUBS.C

Stubs fuer Host-Funktionen, die im Guest-Build (HALO_ARM64_GUEST)
nicht verfuegbar sind. Sie werden in die Bibliothek aufgenommen und
verhindern Linker-Fehler.

Fix v6:
  - cseries.h wird NICHT mehr eingebunden (strnlen-Konflikt mit musl).
  - config_folder wird NICHT mehr definiert: port_settings_shim.c
    enthaelt bereits eine Implementierung, und zwei Definitionen
    desselben Symbols in libguestc.a lehnt der Linker ab.
  - Nur noch SDL_LoadFile wird bereitgestellt.

Diese Datei wird von build.sh nach port/linux/src/ kopiert und dort
automatisch kompiliert.
*/

#ifdef HALO_ARM64_GUEST

#include <stddef.h>

/* SDL_LoadFile: im Host-Build liest diese Funktion eine Datei in den
   Speicher. Im Guest-Build wird sie von menu_files.c aufgerufen, aber
   SDL3 wird im Guest-Build nicht gelinkt. */
void *SDL_LoadFile(const char *file, size_t *datasize)
{
	(void)file;
	if (datasize)
		*datasize = 0;
	return NULL;
}

#endif /* HALO_ARM64_GUEST */
