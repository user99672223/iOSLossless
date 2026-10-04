/* XXH64 hashing of frames and audio, using the vendored xxHash header. */
#define XXH_STATIC_LINKING_ONLY
#define XXH_IMPLEMENTATION
#define XXH_INLINE_ALL
#include "xxhash.h"

#include "lc_internal.h"

struct LCHashState {
    XXH64_state_t st;
};

LCHashState *lc_hash_create(void)
{
    LCHashState *s = (LCHashState *)calloc(1, sizeof(*s));
    if (s) XXH64_reset(&s->st, 0);
    return s;
}

void lc_hash_reset(LCHashState *s)
{
    if (s) XXH64_reset(&s->st, 0);
}

void lc_hash_update(LCHashState *s, const void *data, size_t len)
{
    if (s && len) XXH64_update(&s->st, data, len);
}

uint64_t lc_hash_digest(const LCHashState *s)
{
    return s ? (uint64_t)XXH64_digest(&s->st) : 0;
}

void lc_hash_destroy(LCHashState *s)
{
    free(s);
}

uint64_t lc_hash_bytes(const void *data, size_t len)
{
    return (uint64_t)XXH64(data, len, 0);
}

uint64_t lc_hash_biplanar(const uint8_t *y, size_t y_stride,
                          const uint8_t *cbcr, size_t cbcr_stride,
                          int width, int height, int bytes_per_sample)
{
    XXH64_state_t st;
    XXH64_reset(&st, 0);
    const size_t row_bytes = (size_t)width * (size_t)bytes_per_sample;
    const int chroma_rows = (height + 1) / 2;
    /* Chroma row: width/2 Cb + width/2 Cr samples = width samples. */
    for (int r = 0; r < height; r++)
        XXH64_update(&st, y + (size_t)r * y_stride, row_bytes);
    for (int r = 0; r < chroma_rows; r++)
        XXH64_update(&st, cbcr + (size_t)r * cbcr_stride, row_bytes);
    return (uint64_t)XXH64_digest(&st);
}

uint64_t lc_hash_planar_as_biplanar(const uint8_t *y, size_t y_stride,
                                    const uint8_t *u, size_t u_stride,
                                    const uint8_t *v, size_t v_stride,
                                    int width, int height, int bytes_per_sample,
                                    uint8_t *scratch)
{
    XXH64_state_t st;
    XXH64_reset(&st, 0);
    const size_t row_bytes = (size_t)width * (size_t)bytes_per_sample;
    const int chroma_rows = (height + 1) / 2;
    const int cw = (width + 1) / 2;

    if (bytes_per_sample == 2) {
        uint16_t *tmp = (uint16_t *)scratch;
        for (int r = 0; r < height; r++) {
            const uint16_t *src = (const uint16_t *)(y + (size_t)r * y_stride);
            for (int x = 0; x < width; x++) tmp[x] = (uint16_t)(src[x] << 6);
            XXH64_update(&st, tmp, row_bytes);
        }
        for (int r = 0; r < chroma_rows; r++) {
            const uint16_t *su = (const uint16_t *)(u + (size_t)r * u_stride);
            const uint16_t *sv = (const uint16_t *)(v + (size_t)r * v_stride);
            for (int x = 0; x < cw; x++) {
                tmp[2 * x]     = (uint16_t)(su[x] << 6);
                tmp[2 * x + 1] = (uint16_t)(sv[x] << 6);
            }
            XXH64_update(&st, tmp, row_bytes);
        }
    } else {
        for (int r = 0; r < height; r++)
            XXH64_update(&st, y + (size_t)r * y_stride, row_bytes);
        for (int r = 0; r < chroma_rows; r++) {
            const uint8_t *su = u + (size_t)r * u_stride;
            const uint8_t *sv = v + (size_t)r * v_stride;
            for (int x = 0; x < cw; x++) {
                scratch[2 * x]     = su[x];
                scratch[2 * x + 1] = sv[x];
            }
            XXH64_update(&st, scratch, row_bytes);
        }
    }
    return (uint64_t)XXH64_digest(&st);
}
