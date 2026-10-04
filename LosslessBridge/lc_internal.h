/* Internal helpers shared by the bridge translation units. Not for Swift. */
#ifndef LC_INTERNAL_H
#define LC_INTERNAL_H

#include "LosslessBridge.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/mathematics.h>
#include <libavutil/dict.h>
#include <libavutil/log.h>
#include <libavutil/crc.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>

#define LC_NS_PER_SEC ((int64_t)1000000000)
#define LC_TB_NS ((AVRational){1, 1000000000})

static inline void lc_set_err(char *err, size_t errlen, const char *fmt, ...)
{
    if (!err || errlen == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static inline const char *lc_averr(int e, char *buf, size_t len)
{
    if (av_strerror(e, buf, len) < 0) snprintf(buf, len, "error %d", e);
    return buf;
}

int lc_cpu_count(void);

/* FFmpeg pixel format mapping. */
enum AVPixelFormat lc_to_av_pixfmt(LCPixelFormat f);
int lc_from_av_pixfmt(enum AVPixelFormat f, LCPixelFormat *out);

/* Log hook: decoder contexts register so CRC messages can be attributed. */
void lc_log_register_codec_ctx(const void *avctx, _Atomic int *counter);
void lc_log_unregister_codec_ctx(const void *avctx);

/* FFV1 encoder context shared by the MKV writer and the stage-1 encoder. */
int lc_ffv1_configure(AVCodecContext *ctx, const LCFfv1Params *p, LCPixelFormat pix,
                      int width, int height, int fps_num, int fps_den,
                      int full_range, int color_primaries, int color_trc, int colorspace,
                      int chroma_location, int global_header, char *err, size_t errlen);

/* LZ4 shim (Apple libcompression on Darwin, liblz4 elsewhere). */
size_t lc_lz4_bound(size_t src_size);
size_t lc_lz4_scratch_size(void);
size_t lc_lz4_compress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch);
size_t lc_lz4_decompress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch);

/* Intermediate container reader (used by the stage-2 transcoder). */
typedef struct {
    uint8_t  type;      /* 'V' or 'A' */
    uint8_t  flags;     /* bit0: payload stored uncompressed (codec fallback) */
    uint8_t  pad[6];
    int64_t  index;     /* video frame index / audio chunk sequence */
    int64_t  pts_ns;
    uint64_t aux;       /* video: canonical hash; audio: nb sample frames */
    uint64_t size;      /* payload bytes */
    uint64_t raw_size;  /* video: packed frame bytes */
} LCIChunkHeader;       /* 48 bytes, little-endian on all supported targets */

#define LCI_FLAG_STORED 1u

typedef struct {
    LCIChunkHeader hdr;
    uint64_t offset;    /* file offset of payload */
} LCIEntry;

typedef struct {
    LCIntermediateConfig cfg;
    uint8_t *extradata;
    size_t   extradata_size;
    LCIEntry *entries;
    size_t    count;
    FILE     *f;
    int       recovered;   /* 1 if the chunk table was rebuilt by scanning */
} LCIReader;

LCIReader *lci_reader_open(const char *path, char *err, size_t errlen);
int        lci_reader_read_payload(LCIReader *r, const LCIEntry *e, uint8_t *dst);
void       lci_reader_close(LCIReader *r);

/* Unshuffle a byte-plane-split buffer in place helper (stage 1 / 2). */
void lc_shuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps);
void lc_unshuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps);

#endif
