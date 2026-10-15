/*
GUEST_HOST_STUBS.C (v8)

v8:
  - SDL_LoadFile gibt jetzt NULL bei nicht existierender Datei zurück,
    wie das Original. Das verhindert Parsing-Overflows, wenn das Spiel
    eine leere Datei als gültige Config interpretiert.
  - Alle anderen Stubs unverändert.
*/

#ifdef HALO_ARM64_GUEST

#include <stddef.h>

/* Gibt NULL zurück, wie das Original-SDL bei nicht existierender Datei.
   Ein gültiger Zeiger auf eine leere Datei führte zu Parsing-Overflows
   im TOML-Parser, wenn das Spiel eine gerade erst geschriebene Config
   liest. */
void *SDL_LoadFile(const char *file, size_t *datasize)
{
	(void)file;
	if (datasize)
		*datasize = 0;
	return NULL;
}

#endif /* HALO_ARM64_GUEST */
