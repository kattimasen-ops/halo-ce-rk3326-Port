#!/usr/bin/env python3
"""
NEON/SIMD-Patch für Halo CE Universal.

Zwei Änderungen:
  1. matrix_math.c: matrix4x3_transform_point und matrix4x3_transform_vector
     laufen über NEON via Clangs nativer C-Vektor-Erweiterung (float4).
     Diese Funktionen werden pro Vertex aufgerufen (tausende pro Frame).
     WICHTIG: KEIN <arm_neon.h>! Auf dem arm64_32-apple-watchos-Target unter
     -nostdinc existiert dieser Header nicht bzw. definiert ohne Apple-SDKs
     keine Basistypen. Clangs C-Vektor-Erweiterung senkt direkt auf AArch64
     NEON-Instruktionen (fmul/fadd, vmulq_n_f32 / vaddq_f32-Aequivalent) ab.

  2. guest_string.c: memcpy/memcmp mit Clang-Vektor-Erweiterung (u8x16)
     16/64-Byte-Pfaden (vld1q_u8 / vst1q_u8-Aequivalent).
     Entfernt auch alte, fehlerhafte #include <arm_neon.h>-Zeilen.

WICHTIG: KEINE FMA-Instruktionen. Der Guest wird mit -ffp-contract=off gebaut,
weil die Xbox-Spielearithmetik keine fusionierten Mul+Add-Rundungen erwartet.
"""

import os
import re
import sys

# ── matrix_math.c ─────────────────────────────────────────────────────

def patch_matrix_math(src_root):
    path = os.path.join(src_root, "source", "math", "matrix_math.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe matrix_math.c-Patch")
        return False

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()

    # 1. Reste von <arm_neon.h> sicher entfernen
    text = re.sub(r'#if\s+defined\(__aarch64__\)\s*\n#\s*include\s*<arm_neon\.h>\s*\n#endif\s*\n', '', text)
    text = re.sub(r'#\s*include\s*<arm_neon\.h>\s*\n', '', text)

    # 2. matrix4x3_transform_point ersetzen
    pt_regex = re.compile(
        r'real_point3d\s*\*matrix4x3_transform_point\s*\(\s*'
        r'real_matrix4x3\s+const\s*\*matrix,\s*'
        r'real_point3d\s+const\s*\*point,\s*'
        r'real_point3d\s*\*result\s*\)\s*\{.*?\n\}',
        re.DOTALL
    )

    new_pt = """real_point3d *matrix4x3_transform_point(
	real_matrix4x3 const *matrix,
	real_point3d const *point,
	real_point3d *result)
{
	real x = point->x;
	real y = point->y;
	real z = point->z;

	if (matrix->scale != 1.f)
	{
		x *= matrix->scale;
		y *= matrix->scale;
		z *= matrix->scale;
	}

#if defined(__aarch64__) && defined(__clang__)
	{
		/* Clang vector extension lowering to AArch64 NEON (vmulq_n_f32 + vaddq_f32 equivalent,
		   no <arm_neon.h> needed, safe with -nostdinc on arm64_32-apple-watchos). */
		typedef float float4 __attribute__((__vector_size__(16), __aligned__(4)));
		float4 v_fwd = *(const float4 *)&matrix->forward.i;
		float4 v_left = *(const float4 *)&matrix->left.i;
		float4 v_up = *(const float4 *)&matrix->up.i;
		float4 v_pos = (float4){ matrix->position.x, matrix->position.y, matrix->position.z, 0.0f };
		float4 v_res = v_fwd * x + v_left * y + v_up * z + v_pos;
		result->x = v_res[0];
		result->y = v_res[1];
		result->z = v_res[2];
	}
#else
	result->x = matrix->up.i*z + matrix->left.i*y + matrix->forward.i*x + matrix->position.x;
	result->y = matrix->up.j*z + matrix->left.j*y + matrix->forward.j*x + matrix->position.y;
	result->z = matrix->up.k*z + matrix->left.k*y + matrix->forward.k*x + matrix->position.z;
#endif
	return result;
}"""

    if pt_regex.search(text):
        text = pt_regex.sub(new_pt, text, count=1)
        print("matrix_math.c: matrix4x3_transform_point mit Clang-Vektoren (NEON).")
    else:
        print("WARNUNG: matrix4x3_transform_point nicht gefunden.")

    # 3. matrix4x3_transform_vector ersetzen
    vec_regex = re.compile(
        r'real_vector3d\s*\*matrix4x3_transform_vector\s*\(\s*'
        r'real_matrix4x3\s+const\s*\*matrix,\s*'
        r'real_vector3d\s+const\s*\*vector,\s*'
        r'real_vector3d\s*\*result\s*\)\s*\{.*?\n\}',
        re.DOTALL
    )

    new_vec = """real_vector3d *matrix4x3_transform_vector(
	real_matrix4x3 const *matrix,
	real_vector3d const *vector,
	real_vector3d *result)
{
	real i = vector->i;
	real j = vector->j;
	real k = vector->k;

	if (matrix->scale != 1.f)
	{
		i *= matrix->scale;
		j *= matrix->scale;
		k *= matrix->scale;
	}

#if defined(__aarch64__) && defined(__clang__)
	{
		/* Clang vector extension lowering to AArch64 NEON (vmulq_n_f32 equivalent,
		   kein vfmaq_n_f32 / FMA wegen Xbox-Mul+Add-Rundung bei -ffp-contract=off). */
		typedef float float4 __attribute__((__vector_size__(16), __aligned__(4)));
		float4 v_fwd = *(const float4 *)&matrix->forward.i;
		float4 v_left = *(const float4 *)&matrix->left.i;
		float4 v_up = *(const float4 *)&matrix->up.i;
		float4 v_res = v_fwd * i + v_left * j + v_up * k;
		result->i = v_res[0];
		result->j = v_res[1];
		result->k = v_res[2];
	}
#else
	result->i = i*matrix->forward.i + j*matrix->left.i + k*matrix->up.i;
	result->j = i*matrix->forward.j + j*matrix->left.j + k*matrix->up.j;
	result->k = i*matrix->forward.k + j*matrix->left.k + k*matrix->up.k;
#endif
	return result;
}"""

    if vec_regex.search(text):
        text = vec_regex.sub(new_vec, text, count=1)
        print("matrix_math.c: matrix4x3_transform_vector mit Clang-Vektoren (NEON).")
    else:
        print("WARNUNG: matrix4x3_transform_vector nicht gefunden.")

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return True


# ── guest_string.c ────────────────────────────────────────────────────

def patch_guest_string(src_root):
    path = os.path.join(src_root, "port", "android", "guest", "runtime",
                        "guest_string.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – ueberspringe guest_string.c-Patch")
        return False

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()

    # 1. Reste von <arm_neon.h> entfernen
    text = re.sub(r'#\s*include\s*<arm_neon\.h>\s*\n', '', text)

    # 2. memcmp ersetzen
    memcmp_regex = re.compile(
        r'__attribute__\(\(no_builtin\)\)\s+int\s+memcmp\s*\(\s*const\s+void\s*\*left,\s*const\s+void\s*\*right,\s*size_t\s+size\s*\)\s*\{.*?\n\}',
        re.DOTALL
    )

    new_memcmp = """__attribute__((no_builtin)) int memcmp(const void *left, const void *right, size_t size)
{
	const unsigned char *l = left, *r = right;

#if defined(__aarch64__) && defined(__clang__)
	/* (port/android): 16 Bytes auf einmal ueber Clang-Vektoren (vld1q_u8 / veorq_u8 Aequivalent).
	   Kein <arm_neon.h> noetig; funktioniert unter -nostdinc. */
	typedef uint8_t u8x16 __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));
	typedef uint64_t u64x2 __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));

	for (; size >= 16; size -= 16, l += 16, r += 16)
	{
		u8x16 a = *(const u8x16 *)l;
		u8x16 b = *(const u8x16 *)r;
		u64x2 diff = (u64x2)(a ^ b);
		uint64_t lo = diff[0];
		uint64_t hi = diff[1];

		if (lo | hi)
		{
			uint64_t first_diff = lo ? lo : hi;
			unsigned int byte = (unsigned int)__builtin_ctzll(first_diff) >> 3;
			if (!lo)
				byte += 8;
			return (int)l[byte] - (int)r[byte];
		}
	}
#endif

	for (; size >= 8; size -= 8, l += 8, r += 8)
	{
		uint64_t a = *(const unaligned_u64 *)l, b = *(const unaligned_u64 *)r;

		if (a != b)
		{
			/* little-endian: the lowest byte that differs is the first */
			unsigned int shift = (unsigned int)__builtin_ctzll(a ^ b) & ~7u;

			return (int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff);
		}
	}

	for (; size && *l == *r; size--, l++, r++)
		;

	return size ? *l - *r : 0;
}"""

    if memcmp_regex.search(text):
        text = memcmp_regex.sub(new_memcmp, text, count=1)
        print("guest_string.c: memcmp mit Clang-Vektoren (NEON 16-Byte).")
    else:
        print("WARNUNG: memcmp nicht gefunden.")

    # 3. memcpy ersetzen
    memcpy_regex = re.compile(
        r'__attribute__\(\(no_builtin\)\)\s+void\s*\*memcpy\s*\(\s*void\s*\*restrict\s+destination,\s*const\s+void\s*\*restrict\s+source,\s*size_t\s+size\s*\)\s*\{.*?\n\}',
        re.DOTALL
    )

    new_memcpy = """__attribute__((no_builtin)) void *memcpy(void *restrict destination, const void *restrict source, size_t size)
{
	unsigned char *d = destination;
	const unsigned char *s = source;

#if defined(__aarch64__) && defined(__clang__)
	/* (port/android): 64 Bytes pro Schleifendurchlauf ueber Clang-Vektoren (vld1q_u8 / vst1q_u8 Aequivalent).
	   Cortex-A35 hat zwei 128-Bit-Ladeports; kein <arm_neon.h> noetig. */
	typedef uint8_t u8x16 __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));

	for (; size >= 64; size -= 64, d += 64, s += 64)
	{
		u8x16 v0 = *(const u8x16 *)(s + 0);
		u8x16 v1 = *(const u8x16 *)(s + 16);
		u8x16 v2 = *(const u8x16 *)(s + 32);
		u8x16 v3 = *(const u8x16 *)(s + 48);
		*(u8x16 *)(d + 0) = v0;
		*(u8x16 *)(d + 16) = v1;
		*(u8x16 *)(d + 32) = v2;
		*(u8x16 *)(d + 48) = v3;
	}

	for (; size >= 16; size -= 16, d += 16, s += 16)
	{
		*(u8x16 *)d = *(const u8x16 *)s;
	}
#else
	for (; size >= 16; size -= 16, d += 16, s += 16)
	{
		uint64_t a = ((const unaligned_u64 *)s)[0], b = ((const unaligned_u64 *)s)[1];

		((unaligned_u64 *)d)[0] = a;
		((unaligned_u64 *)d)[1] = b;
	}
#endif

	if (size >= 8)
	{
		*(unaligned_u64 *)d = *(const unaligned_u64 *)s;
		size -= 8;
		d += 8;
		s += 8;
	}

	for (; size; size--)
		*d++ = *s++;

	return destination;
}"""

    if memcpy_regex.search(text):
        text = memcpy_regex.sub(new_memcpy, text, count=1)
        print("guest_string.c: memcpy mit Clang-Vektoren (NEON 64-Byte).")
    else:
        print("WARNUNG: memcpy nicht gefunden.")

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return True


def apply_patch(src_root):
    print("== Patch 2: NEON/SIMD (Clang C Vector Extension, no arm_neon.h) ==")
    ok_a = patch_matrix_math(src_root)
    ok_b = patch_guest_string(src_root)
    if not (ok_a or ok_b):
        print("FEHLER: keine der Aenderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
