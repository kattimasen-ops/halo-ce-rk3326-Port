/*
GUEST_HOST_STUBS.C (v7)

v7:
  - SDL_LoadFile jetzt mit korrektem Rückgabeverhalten. Liefert
    eine kleine statische leere Datei statt NULL, damit Caller, die
    den Rückgabewert ungeprüft nutzen, nicht sofort crashen.
  - Alle anderen Stubs unverändert.
*/

#ifdef HALO_ARM64_GUEST

#include <stddef.h>

/* Ein einziges Null-Byte als "leere Datei". Caller, die den Inhalt
   lesen wollen, bekommen einen gültigen Zeiger auf 1 Byte. */
static const unsigned char empty_file[1] = { 0 };

void *SDL_LoadFile(const char *file, size_t *datasize)
{
	(void)file;
	if (datasize)
		*datasize = 0;
	return (void *)empty_file;
}

#endif /* HALO_ARM64_GUEST */
