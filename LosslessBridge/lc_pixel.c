/* Bit-exact layout transforms between AVFoundation bi-planar buffers and
 * libavcodec planar frames, plus packing helpers and thumbnail conversion. */
#include "lc_internal.h"

uint16_t lc_repack_p010_to_yuv420p10(const uint8_t *y, size_t y_stride,
                                     const uint8_t *cbcr, size_t cbcr_stride,
                                     int width, int height,
                                     uint8_t *dy, size_t dy_stride,
                                     uint8_t *du, size_t du_stride,
                                     uint8_t *dv, size_t dv_stride)
{
    uint16_t acc = 0;
    const int cw = (width + 1) / 2;
    const int ch = (height + 1) / 2;

    for (int r = 0; r < height; r++) {
        const uint16_t *s = (const uint16_t *)(y + (size_t)r * y_stride);
        uint16_t *d = (uint16_t *)(dy + (size_t)r * dy_stride);
        uint16_t a = 0;
        for (int x = 0; x < width; x++) {
            uint16_t v = s[x];
            a |= v;
            d[x] = (uint16_t)(v >> 6);
        }
        acc |= a;
    }
    for (int r = 0; r < ch; r++) {
        const uint16_t *s = (const uint16_t *)(cbcr + (size_t)r * cbcr_stride);
        uint16_t *pu = (uint16_t *)(du + (size_t)r * du_stride);
        uint16_t *pv = (uint16_t *)(dv + (size_t)r * dv_stride);
        uint16_t a = 0;
        for (int x = 0; x < cw; x++) {
            uint16_t cb = s[2 * x], cr = s[2 * x + 1];
            a |= cb | cr;
            pu[x] = (uint16_t)(cb >> 6);
            pv[x] = (uint16_t)(cr >> 6);
        }
        acc |= a;
    }
    return (uint16_t)(acc & 0x3F);
}

void lc_repack_yuv420p10_to_p010(const uint8_t *y, size_t y_stride,
                                 const uint8_t *u, size_t u_stride,
                                 const uint8_t *v, size_t v_stride,
                                 int width, int height,
                                 uint8_t *dy, size_t dy_stride,
                                 uint8_t *dcbcr, size_t dcbcr_stride)
{
    const int cw = (width + 1) / 2;
    const int ch = (height + 1) / 2;
    for (int r = 0; r < height; r++) {
        const uint16_t *s = (const uint16_t *)(y + (size_t)r * y_stride);
        uint16_t *d = (uint16_t *)(dy + (size_t)r * dy_stride);
        for (int x = 0; x < width; x++) d[x] = (uint16_t)(s[x] << 6);
    }
    for (int r = 0; r < ch; r++) {
        const uint16_t *su = (const uint16_t *)(u + (size_t)r * u_stride);
        const uint16_t *sv = (const uint16_t *)(v + (size_t)r * v_stride);
        uint16_t *d = (uint16_t *)(dcbcr + (size_t)r * dcbcr_stride);
        for (int x = 0; x < cw; x++) {
            d[2 * x]     = (uint16_t)(su[x] << 6);
            d[2 * x + 1] = (uint16_t)(sv[x] << 6);
        }
    }
}

void lc_repack_nv12_to_yuv420p(const uint8_t *y, size_t y_stride,
                               const uint8_t *cbcr, size_t cbcr_stride,
                               int width, int height,
                               uint8_t *dy, size_t dy_stride,
                               uint8_t *du, size_t du_stride,
                               uint8_t *dv, size_t dv_stride)
{
    const int cw = (width + 1) / 2;
    const int ch = (height + 1) / 2;
    for (int r = 0; r < height; r++)
        memcpy(dy + (size_t)r * dy_stride, y + (size_t)r * y_stride, (size_t)width);
    for (int r = 0; r < ch; r++) {
        const uint8_t *s = cbcr + (size_t)r * cbcr_stride;
        uint8_t *pu = du + (size_t)r * du_stride;
        uint8_t *pv = dv + (size_t)r * dv_stride;
        for (int x = 0; x < cw; x++) {
            pu[x] = s[2 * x];
            pv[x] = s[2 * x + 1];
        }
    }
}

void lc_repack_yuv420p_to_nv12(const uint8_t *y, size_t y_stride,
                               const uint8_t *u, size_t u_stride,
                               const uint8_t *v, size_t v_stride,
                               int width, int height,
                               uint8_t *dy, size_t dy_stride,
                               uint8_t *dcbcr, size_t dcbcr_stride)
{
    const int cw = (width + 1) / 2;
    const int ch = (height + 1) / 2;
    for (int r = 0; r < height; r++)
        memcpy(dy + (size_t)r * dy_stride, y + (size_t)r * y_stride, (size_t)width);
    for (int r = 0; r < ch; r++) {
        const uint8_t *su = u + (size_t)r * u_stride;
        const uint8_t *sv = v + (size_t)r * v_stride;
        uint8_t *d = dcbcr + (size_t)r * dcbcr_stride;
        for (int x = 0; x < cw; x++) {
            d[2 * x]     = su[x];
            d[2 * x + 1] = sv[x];
        }
    }
}

size_t lc_pack_biplanar(const uint8_t *y, size_t y_stride,
                        const uint8_t *cbcr, size_t cbcr_stride,
                        int width, int height, int bytes_per_sample,
                        uint8_t *dst)
{
    const size_t row = (size_t)width * (size_t)bytes_per_sample;
    const int ch = (height + 1) / 2;
    uint8_t *d = dst;
    for (int r = 0; r < height; r++, d += row)
        memcpy(d, y + (size_t)r * y_stride, row);
    for (int r = 0; r < ch; r++, d += row)
        memcpy(d, cbcr + (size_t)r * cbcr_stride, row);
    return (size_t)(d - dst);
}

void lc_shuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps)
{
    if (bps != 2) { memcpy(dst, src, nsamples); return; }
    uint8_t *hi = dst, *lo = dst + nsamples;
    for (size_t i = 0; i < nsamples; i++) {
        lo[i] = src[2 * i];       /* little-endian: low byte first */
        hi[i] = src[2 * i + 1];
    }
}

void lc_unshuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps)
{
    if (bps != 2) { memcpy(dst, src, nsamples); return; }
    const uint8_t *hi = src, *lo = src + nsamples;
    for (size_t i = 0; i < nsamples; i++) {
        dst[2 * i]     = lo[i];
        dst[2 * i + 1] = hi[i];
    }
}

/* xorshift32 */
static inline uint32_t lc_rng(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    *s = x;
    return x;
}

void lc_fill_test_frame(uint8_t *y, size_t y_stride, uint8_t *cbcr, size_t cbcr_stride,
                        int width, int height, int bytes_per_sample, uint32_t seed)
{
    uint32_t s = seed * 2654435761u + 12345u;
    const int ch = (height + 1) / 2;
    const int cw = (width + 1) / 2;
    if (bytes_per_sample == 2) {
        for (int r = 0; r < height; r++) {
            uint16_t *d = (uint16_t *)(y + (size_t)r * y_stride);
            for (int x = 0; x < width; x++) {
                /* smooth gradient + texture + sensor-like noise, video range 64..940 */
                int g = 64 + (int)((int64_t)(x + r + (int)(seed & 255)) * 700 / (width + height));
                int tex = (int)(40.0 * sin(x * 0.021) * cos(r * 0.017));
                int n = (int)(lc_rng(&s) % 17) - 8;
                int v = g + tex + n;
                if (v < 64) v = 64; if (v > 940) v = 940;
                d[x] = (uint16_t)(v << 6);
            }
        }
        for (int r = 0; r < ch; r++) {
            uint16_t *d = (uint16_t *)(cbcr + (size_t)r * cbcr_stride);
            for (int x = 0; x < cw; x++) {
                int cb = 512 + (int)(120.0 * sin(x * 0.011 + r * 0.007)) + (int)(lc_rng(&s) % 9) - 4;
                int cr = 512 + (int)(120.0 * cos(x * 0.009 - r * 0.013)) + (int)(lc_rng(&s) % 9) - 4;
                if (cb < 64) cb = 64; if (cb > 960) cb = 960;
                if (cr < 64) cr = 64; if (cr > 960) cr = 960;
                d[2 * x]     = (uint16_t)(cb << 6);
                d[2 * x + 1] = (uint16_t)(cr << 6);
            }
        }
    } else {
        for (int r = 0; r < height; r++) {
            uint8_t *d = y + (size_t)r * y_stride;
            for (int x = 0; x < width; x++) {
                int g = 16 + (int)((int64_t)(x + r + (int)(seed & 255)) * 180 / (width + height));
                int tex = (int)(10.0 * sin(x * 0.021) * cos(r * 0.017));
                int n = (int)(lc_rng(&s) % 5) - 2;
                int v = g + tex + n;
                if (v < 16) v = 16; if (v > 235) v = 235;
                d[x] = (uint8_t)v;
            }
        }
        for (int r = 0; r < ch; r++) {
            uint8_t *d = cbcr + (size_t)r * cbcr_stride;
            for (int x = 0; x < cw; x++) {
                int cb = 128 + (int)(30.0 * sin(x * 0.011 + r * 0.007)) + (int)(lc_rng(&s) % 3) - 1;
                int cr = 128 + (int)(30.0 * cos(x * 0.009 - r * 0.013)) + (int)(lc_rng(&s) % 3) - 1;
                if (cb < 16) cb = 16; if (cb > 240) cb = 240;
                if (cr < 16) cr = 16; if (cr > 240) cr = 240;
                d[2 * x]     = (uint8_t)cb;
                d[2 * x + 1] = (uint8_t)cr;
            }
        }
    }
}

static inline uint8_t lc_clamp8(float v)
{
    if (v <= 0.f) return 0;
    if (v >= 255.f) return 255;
    return (uint8_t)(v + 0.5f);
}

int lc_frame_to_rgba8(const LCVideoFrame *f, int full_range, int colorspace,
                      uint8_t *rgba, int out_w, int out_h, size_t out_stride)
{
    if (!f || !rgba || out_w <= 0 || out_h <= 0) return -1;
    const int bps = (f->pix_fmt == LC_PIX_YUV420P10) ? 2 : 1;
    const float maxv = bps == 2 ? 1023.f : 255.f;
    const float ymin = full_range ? 0.f : (bps == 2 ? 64.f : 16.f);
    const float yrange = full_range ? maxv : (bps == 2 ? 876.f : 219.f);
    const float crange = full_range ? maxv : (bps == 2 ? 896.f : 224.f);
    const float cmid = bps == 2 ? 512.f : 128.f;
    /* BT.2020 NCL or BT.709 YCbCr -> R'G'B' */
    float kr_c, kg_cb, kg_cr, kb_c;
    if (colorspace == LC_COLOR_SPC_BT2020_NCL) {
        kr_c = 1.4746f; kg_cb = -0.164553f; kg_cr = -0.571353f; kb_c = 1.8814f;
    } else {
        kr_c = 1.5748f; kg_cb = -0.187324f; kg_cr = -0.468124f; kb_c = 1.8556f;
    }
    for (int oy = 0; oy < out_h; oy++) {
        int sy = (int)((int64_t)oy * f->height / out_h);
        if (sy >= f->height) sy = f->height - 1;
        uint8_t *dst = rgba + (size_t)oy * out_stride;
        const uint8_t *yrow = f->planes[0] + (size_t)sy * f->strides[0];
        const uint8_t *urow = f->planes[1] + (size_t)(sy / 2) * f->strides[1];
        const uint8_t *vrow = f->planes[2] + (size_t)(sy / 2) * f->strides[2];
        for (int ox = 0; ox < out_w; ox++) {
            int sx = (int)((int64_t)ox * f->width / out_w);
            if (sx >= f->width) sx = f->width - 1;
            float Y, Cb, Cr;
            if (bps == 2) {
                Y  = ((const uint16_t *)yrow)[sx];
                Cb = ((const uint16_t *)urow)[sx / 2];
                Cr = ((const uint16_t *)vrow)[sx / 2];
            } else {
                Y = yrow[sx]; Cb = urow[sx / 2]; Cr = vrow[sx / 2];
            }
            float yn = (Y - ymin) / yrange;
            float cb = (Cb - cmid) / crange;
            float cr = (Cr - cmid) / crange;
            float r = yn + kr_c * cr;
            float g = yn + kg_cb * cb + kg_cr * cr;
            float b = yn + kb_c * cb;
            /* HLG signal viewed as SDR gamma: apply a mild boost so thumbnails
             * are not too dark. Display-referred approximation only. */
            dst[4 * ox + 0] = lc_clamp8(r * 255.f * 1.15f);
            dst[4 * ox + 1] = lc_clamp8(g * 255.f * 1.15f);
            dst[4 * ox + 2] = lc_clamp8(b * 255.f * 1.15f);
            dst[4 * ox + 3] = 255;
        }
    }
    return 0;
}
