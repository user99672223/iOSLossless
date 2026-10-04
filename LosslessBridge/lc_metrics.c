/* Luma PSNR and SSIM between two frames of identical geometry. */
#include "lc_internal.h"

static inline int sample_at(const uint8_t *row, int x, int bps, int shift)
{
    if (bps == 2) return (int)(((const uint16_t *)row)[x] >> shift);
    return row[x];
}

int lc_luma_metrics(const uint8_t *a, size_t a_stride, const uint8_t *b, size_t b_stride,
                    int width, int height, int bytes_per_sample, int shift, int max_value,
                    LCLumaMetrics *out)
{
    if (!a || !b || !out || width <= 0 || height <= 0) return -1;
    if (bytes_per_sample != 2) shift = 0;

    /* MSE / PSNR */
    double se = 0.0;
    for (int y = 0; y < height; y++) {
        const uint8_t *ra = a + (size_t)y * a_stride;
        const uint8_t *rb = b + (size_t)y * b_stride;
        double rowse = 0.0;
        if (bytes_per_sample == 2) {
            const uint16_t *pa = (const uint16_t *)ra, *pb = (const uint16_t *)rb;
            for (int x = 0; x < width; x++) {
                int d = (int)(pa[x] >> shift) - (int)(pb[x] >> shift);
                rowse += (double)(d * d);
            }
        } else {
            for (int x = 0; x < width; x++) {
                int d = (int)ra[x] - (int)rb[x];
                rowse += (double)(d * d);
            }
        }
        se += rowse;
    }
    double mse = se / ((double)width * (double)height);
    out->mse = mse;
    out->psnr = mse > 0.0 ? 10.0 * log10((double)max_value * (double)max_value / mse) : INFINITY;

    /* SSIM, 8x8 windows on a 4-pixel grid */
    const double L = (double)max_value;
    const double C1 = (0.01 * L) * (0.01 * L);
    const double C2 = (0.03 * L) * (0.03 * L);
    double ssim_sum = 0.0;
    int64_t windows = 0;
    for (int wy = 0; wy + 8 <= height; wy += 4) {
        for (int wx = 0; wx + 8 <= width; wx += 4) {
            double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
            for (int y = 0; y < 8; y++) {
                const uint8_t *ra = a + (size_t)(wy + y) * a_stride;
                const uint8_t *rb = b + (size_t)(wy + y) * b_stride;
                for (int x = 0; x < 8; x++) {
                    double va = sample_at(ra, wx + x, bytes_per_sample, shift);
                    double vb = sample_at(rb, wx + x, bytes_per_sample, shift);
                    sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb;
                }
            }
            const double n = 64.0;
            double ma = sa / n, mb = sb / n;
            double va = (saa - n * ma * ma) / (n - 1.0);
            double vb = (sbb - n * mb * mb) / (n - 1.0);
            double cov = (sab - n * ma * mb) / (n - 1.0);
            double s = ((2.0 * ma * mb + C1) * (2.0 * cov + C2)) /
                       ((ma * ma + mb * mb + C1) * (va + vb + C2));
            ssim_sum += s;
            windows++;
        }
    }
    out->ssim = windows > 0 ? ssim_sum / (double)windows : 1.0;
    return 0;
}
