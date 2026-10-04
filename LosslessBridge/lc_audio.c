/* PCM -> canonical int32 (24-bit value in bits 8..31) conversion. */
#include "lc_internal.h"

int64_t lc_audio_convert_to_s32_24(const void *const *src, int non_interleaved,
                                   LCAudioSourceFormat fmt, int channels,
                                   int nb_frames, int32_t *dst)
{
    int64_t inexact = 0;
    if (!src || !dst || channels <= 0 || nb_frames <= 0) return 0;

    for (int ch = 0; ch < channels; ch++) {
        /* Pointer to the first sample of this channel and the step between
         * consecutive frames, in samples. */
        const uint8_t *base;
        size_t step_samples;
        if (non_interleaved) {
            base = (const uint8_t *)src[ch];
            step_samples = 1;
        } else {
            base = (const uint8_t *)src[0];
            step_samples = (size_t)channels;
        }
        if (!base) continue;

        switch (fmt) {
        case LC_AUDIO_SRC_INT16: {
            const int16_t *s = (const int16_t *)base + (non_interleaved ? 0 : ch);
            for (int i = 0; i < nb_frames; i++)
                dst[(size_t)i * channels + ch] = (int32_t)((uint32_t)(uint16_t)s[i * step_samples] << 16);
            break;
        }
        case LC_AUDIO_SRC_INT24: {
            const uint8_t *s = base + (non_interleaved ? 0 : (size_t)ch * 3);
            size_t step = step_samples * 3;
            for (int i = 0; i < nb_frames; i++) {
                const uint8_t *p = s + (size_t)i * step;
                uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
                dst[(size_t)i * channels + ch] = (int32_t)(v << 8);
            }
            break;
        }
        case LC_AUDIO_SRC_INT32: {
            const int32_t *s = (const int32_t *)base + (non_interleaved ? 0 : ch);
            for (int i = 0; i < nb_frames; i++) {
                int32_t v = s[i * step_samples];
                if (v & 0xFF) { inexact++; v &= (int32_t)0xFFFFFF00; }
                dst[(size_t)i * channels + ch] = v;
            }
            break;
        }
        case LC_AUDIO_SRC_INT24_IN_32_LOW: {
            const int32_t *s = (const int32_t *)base + (non_interleaved ? 0 : ch);
            for (int i = 0; i < nb_frames; i++) {
                uint32_t v = (uint32_t)s[i * step_samples] & 0xFFFFFFu;
                dst[(size_t)i * channels + ch] = (int32_t)(v << 8);
            }
            break;
        }
        case LC_AUDIO_SRC_FLOAT32: {
            const float *s = (const float *)base + (non_interleaved ? 0 : ch);
            for (int i = 0; i < nb_frames; i++) {
                float f = s[i * step_samples];
                float c = f;
                if (c != c) { c = 0.0f; inexact++; }   /* NaN: store silence, count it */
                if (c > 1.0f) c = 1.0f;
                if (c < -1.0f) c = -1.0f;
                double q = rint((double)c * 8388608.0);
                if (q > 8388607.0) q = 8388607.0;
                if (q < -8388608.0) q = -8388608.0;
                int32_t qi = (int32_t)q;
                /* Exact iff the float was already a 24-bit fixed-point value. */
                if (f == f && (float)((double)qi / 8388608.0) != f) inexact++;
                dst[(size_t)i * channels + ch] = (int32_t)((uint32_t)qi << 8);
            }
            break;
        }
        default:
            return -1;
        }
    }
    return inexact;
}
