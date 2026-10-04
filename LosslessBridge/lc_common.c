/* Library init, logging hook with CRC-mismatch attribution, pixel format
 * mapping, shared FFV1 encoder configuration and LZ4 shim. */
#include "lc_internal.h"

#ifdef __APPLE__
#include <compression.h>
#include <sys/sysctl.h>
#else
#include <lz4.h>
#include <unistd.h>
#endif

/* Static checks that the LC_* mirrors match FFmpeg. */
_Static_assert(LC_COLOR_PRI_BT709 == AVCOL_PRI_BT709, "pri");
_Static_assert(LC_COLOR_PRI_BT2020 == AVCOL_PRI_BT2020, "pri");
_Static_assert(LC_COLOR_PRI_SMPTE432 == AVCOL_PRI_SMPTE432, "pri");
_Static_assert(LC_COLOR_TRC_BT709 == AVCOL_TRC_BT709, "trc");
_Static_assert(LC_COLOR_TRC_SMPTE2084 == AVCOL_TRC_SMPTE2084, "trc");
_Static_assert(LC_COLOR_TRC_ARIB_STD_B67 == AVCOL_TRC_ARIB_STD_B67, "trc");
_Static_assert(LC_COLOR_SPC_BT709 == AVCOL_SPC_BT709, "spc");
_Static_assert(LC_COLOR_SPC_BT2020_NCL == AVCOL_SPC_BT2020_NCL, "spc");
_Static_assert(LC_CHROMA_LOC_LEFT == AVCHROMA_LOC_LEFT, "loc");
_Static_assert(LC_CHROMA_LOC_CENTER == AVCHROMA_LOC_CENTER, "loc");
_Static_assert(LC_CHROMA_LOC_TOPLEFT == AVCHROMA_LOC_TOPLEFT, "loc");
_Static_assert(LC_CHROMA_LOC_TOP == AVCHROMA_LOC_TOP, "loc");
_Static_assert(LC_CHROMA_LOC_BOTTOMLEFT == AVCHROMA_LOC_BOTTOMLEFT, "loc");
_Static_assert(LC_CHROMA_LOC_BOTTOM == AVCHROMA_LOC_BOTTOM, "loc");

/* ------------------------------------------------------------------------ */
/* Logging                                                                   */
/* ------------------------------------------------------------------------ */

static LCLogFn g_log_fn = NULL;
static void *g_log_ctx = NULL;
static _Atomic int64_t g_crc_errors = 0;
static pthread_mutex_t g_reg_mutex = PTHREAD_MUTEX_INITIALIZER;

#define LC_MAX_REG 64
typedef struct { const void *avctx; _Atomic int *counter; } LCReg;
static LCReg g_regs[LC_MAX_REG];

void lc_log_register_codec_ctx(const void *avctx, _Atomic int *counter)
{
    pthread_mutex_lock(&g_reg_mutex);
    for (int i = 0; i < LC_MAX_REG; i++) {
        if (!g_regs[i].avctx) { g_regs[i].avctx = avctx; g_regs[i].counter = counter; break; }
    }
    pthread_mutex_unlock(&g_reg_mutex);
}

void lc_log_unregister_codec_ctx(const void *avctx)
{
    pthread_mutex_lock(&g_reg_mutex);
    for (int i = 0; i < LC_MAX_REG; i++) {
        if (g_regs[i].avctx == avctx) { g_regs[i].avctx = NULL; g_regs[i].counter = NULL; }
    }
    pthread_mutex_unlock(&g_reg_mutex);
}

static void lc_av_log_cb(void *avcl, int level, const char *fmt, va_list vl)
{
    if (level > AV_LOG_INFO) return;           /* skip verbose/debug */
    if (level > AV_LOG_WARNING && !g_log_fn) return;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    if (level <= AV_LOG_ERROR && strstr(buf, "CRC mismatch")) {
        atomic_fetch_add(&g_crc_errors, 1);
        pthread_mutex_lock(&g_reg_mutex);
        for (int i = 0; i < LC_MAX_REG; i++) {
            if (g_regs[i].avctx && g_regs[i].avctx == avcl && g_regs[i].counter) {
                atomic_fetch_add(g_regs[i].counter, 1);
                break;
            }
        }
        pthread_mutex_unlock(&g_reg_mutex);
    }
    if (g_log_fn && n) g_log_fn(g_log_ctx, level, buf);
}

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static void lc_do_init(void)
{
    av_log_set_level(AV_LOG_INFO);
    av_log_set_callback(lc_av_log_cb);
}

void lc_bridge_init(void)
{
    pthread_once(&g_init_once, lc_do_init);
}

void lc_set_log_callback(LCLogFn fn, void *ctx)
{
    lc_bridge_init();
    g_log_fn = fn;
    g_log_ctx = ctx;
}

int64_t lc_total_crc_errors(void)
{
    return atomic_load(&g_crc_errors);
}

/* ------------------------------------------------------------------------ */
/* Library info                                                              */
/* ------------------------------------------------------------------------ */

const char *lc_ffmpeg_version_string(void)
{
    static char buf[64];
    unsigned v = avcodec_version();
    snprintf(buf, sizeof(buf), "lavc %u.%u.%u / lavf %u.%u.%u",
             v >> 16, (v >> 8) & 0xff, v & 0xff,
             avformat_version() >> 16, (avformat_version() >> 8) & 0xff, avformat_version() & 0xff);
    return buf;
}

const char *lc_ffmpeg_configuration(void)
{
    return avcodec_configuration();
}

const char *lc_ffmpeg_license(void)
{
    return avcodec_license();
}

int lc_encoder_available(const char *name)
{
    return avcodec_find_encoder_by_name(name) != NULL;
}

int lc_encoder_supports_pix_fmt(const char *name, int lc_pix_fmt)
{
    const AVCodec *c = avcodec_find_encoder_by_name(name);
    if (!c) return 0;
    enum AVPixelFormat want = lc_to_av_pixfmt((LCPixelFormat)lc_pix_fmt);
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(61, 13, 100)
    const enum AVPixelFormat *fmts = NULL;
    int n = 0;
    if (avcodec_get_supported_config(NULL, c, AV_CODEC_CONFIG_PIX_FORMAT, 0, (const void **)&fmts, &n) < 0 || !fmts)
        return 0;
    for (int i = 0; i < n; i++)
        if (fmts[i] == want) return 1;
    return 0;
#else
    if (!c->pix_fmts) return 0;
    for (const enum AVPixelFormat *p = c->pix_fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == want) return 1;
    return 0;
#endif
}

int lc_cpu_count(void)
{
#ifdef __APPLE__
    int n = 0;
    size_t len = sizeof(n);
    if (sysctlbyname("hw.activecpu", &n, &len, NULL, 0) == 0 && n > 0) return n;
    if (sysctlbyname("hw.ncpu", &n, &len, NULL, 0) == 0 && n > 0) return n;
    return 4;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 4;
#endif
}

enum AVPixelFormat lc_to_av_pixfmt(LCPixelFormat f)
{
    switch (f) {
    case LC_PIX_YUV420P8:  return AV_PIX_FMT_YUV420P;
    case LC_PIX_YUV420P10: return AV_PIX_FMT_YUV420P10LE;
    default: return AV_PIX_FMT_NONE;
    }
}

int lc_from_av_pixfmt(enum AVPixelFormat f, LCPixelFormat *out)
{
    switch (f) {
    case AV_PIX_FMT_YUV420P:     *out = LC_PIX_YUV420P8;  return 0;
    case AV_PIX_FMT_YUVJ420P:    *out = LC_PIX_YUV420P8;  return 0;
    case AV_PIX_FMT_YUV420P10LE: *out = LC_PIX_YUV420P10; return 0;
    default: return -1;
    }
}

/* ------------------------------------------------------------------------ */
/* FFV1 encoder configuration                                                */
/* ------------------------------------------------------------------------ */

int lc_ffv1_configure(AVCodecContext *ctx, const LCFfv1Params *p, LCPixelFormat pix,
                      int width, int height, int fps_num, int fps_den,
                      int full_range, int color_primaries, int color_trc, int colorspace,
                      int chroma_location, int global_header, char *err, size_t errlen)
{
    ctx->width = width;
    ctx->height = height;
    ctx->pix_fmt = lc_to_av_pixfmt(pix);
    ctx->time_base = LC_TB_NS;
    ctx->framerate = (AVRational){ fps_num > 0 ? fps_num : 60, fps_den > 0 ? fps_den : 1 };
    ctx->gop_size = p->gop > 0 ? p->gop : 1;
    ctx->level = p->level > 0 ? p->level : 3;
    ctx->slices = p->slices > 0 ? p->slices : 24;
    int threads = p->threads > 0 ? p->threads : lc_cpu_count();
    ctx->thread_count = threads;
    ctx->thread_type = FF_THREAD_SLICE;
    ctx->color_range = full_range ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
    ctx->color_primaries = (enum AVColorPrimaries)color_primaries;
    ctx->color_trc = (enum AVColorTransferCharacteristic)color_trc;
    ctx->colorspace = (enum AVColorSpace)colorspace;
    ctx->chroma_sample_location = (enum AVChromaLocation)chroma_location;
    if (global_header) ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    int ret;
    if ((ret = av_opt_set_int(ctx->priv_data, "coder", p->coder, 0)) < 0 ||
        (ret = av_opt_set_int(ctx->priv_data, "context", p->context ? 1 : 0, 0)) < 0 ||
        (ret = av_opt_set_int(ctx->priv_data, "slicecrc", p->slicecrc ? 1 : 0, 0)) < 0) {
        char b[64];
        lc_set_err(err, errlen, "ffv1 option: %s", lc_averr(ret, b, sizeof(b)));
        return ret;
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* LZ4 shim                                                                  */
/* ------------------------------------------------------------------------ */

size_t lc_lz4_bound(size_t src_size)
{
    /* Worst case LZ4 expansion plus Apple framing headers. */
    return src_size + src_size / 128 + 4096;
}

#ifdef __APPLE__
size_t lc_lz4_scratch_size(void)
{
    size_t e = compression_encode_scratch_buffer_size(COMPRESSION_LZ4);
    size_t d = compression_decode_scratch_buffer_size(COMPRESSION_LZ4);
    return (e > d ? e : d) + 64;
}

size_t lc_lz4_compress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch)
{
    return compression_encode_buffer(dst, dst_cap, src, src_size, scratch, COMPRESSION_LZ4);
}

size_t lc_lz4_decompress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch)
{
    return compression_decode_buffer(dst, dst_cap, src, src_size, scratch, COMPRESSION_LZ4);
}
#else
size_t lc_lz4_scratch_size(void) { return 64; }

size_t lc_lz4_compress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch)
{
    (void)scratch;
    if (src_size > (size_t)LZ4_MAX_INPUT_SIZE || dst_cap > (size_t)INT32_MAX) return 0;
    int n = LZ4_compress_default((const char *)src, (char *)dst, (int)src_size, (int)dst_cap);
    return n > 0 ? (size_t)n : 0;
}

size_t lc_lz4_decompress(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap, void *scratch)
{
    (void)scratch;
    int n = LZ4_decompress_safe((const char *)src, (char *)dst, (int)src_size, (int)dst_cap);
    return n > 0 ? (size_t)n : 0;
}
#endif
