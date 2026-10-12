/*
GUEST_HOST_STUBS.C

Stubs fuer Host-Funktionen, die im Guest-Build (HALO_ARM64_GUEST)
nicht verfuegbar sind. Sie werden in die Bibliothek aufgenommen und
verhindern Linker-Fehler.

Fix v6: cseries.h wird NICHT mehr eingebunden. Die Deklaration
`long strnlen(const char *, long)` in cseries.h kollidiert mit der
musl-Deklaration `size_t strnlen(const char *, size_t)`, die im
Guest-Build ueber <string.h> sichtbar ist. Da diese Datei strnlen
nicht verwendet, wird cseries.h nicht benoetigt.

Diese Datei wird von build.sh nach port/linux/src/ kopiert und dort
automatisch kompiliert.
*/

#ifdef HALO_ARM64_GUEST

#include <stddef.h>

/* config_folder: im Host-Build liefert diese Funktion den Pfad zum
   Konfigurationsordner. Im Guest-Build wird der Pfad nicht benoetigt. */
void config_folder(char *folder, unsigned int size)
{
	if (folder && size > 0)
		folder[0] = 0;
}

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
