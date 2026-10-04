/* Stage-1 intermediate container (.lci) and the fast stage-1 encoders.
 *
 * File layout (little-endian):
 *   "LCI\x01" u32 header_size
 *   LCIntermediateConfig (as 16 x int32)  u32 extradata_size  u8 extradata[]
 *   chunks: LCIChunkHeader (48 bytes) + payload, in completion order
 *   trailer: "LCIX" u64 count, count x (LCIChunkHeader + u64 offset),
 *            u64 trailer_offset, "LCIE"
 * A file without trailer (crash) is recovered by scanning the chunks.
 */
#include "lc_internal.h"

#define LCI_MAGIC "LCI\x01"

typedef struct {
    int32_t width, height, bytes_per_sample, bit_depth, full_range;
    int32_t color_primaries, color_trc, colorspace, chroma_location;
    int32_t fps_num, fps_den, codec;
    int32_t audio_sample_rate, audio_channels, audio_ambisonic, reserved;
} LCIConfigOnDisk;

static void cfg_to_disk(const LCIntermediateConfig *c, LCIConfigOnDisk *d)
{
    memset(d, 0, sizeof(*d));
    d->width = c->width; d->height = c->height; d->bytes_per_sample = c->bytes_per_sample;
    d->bit_depth = c->bit_depth; d->full_range = c->full_range;
    d->color_primaries = c->color_primaries; d->color_trc = c->color_trc;
    d->colorspace = c->colorspace; d->chroma_location = c->chroma_location;
    d->fps_num = c->fps_num; d->fps_den = c->fps_den; d->codec = (int32_t)c->codec;
    d->audio_sample_rate = c->audio_sample_rate; d->audio_channels = c->audio_channels;
    d->audio_ambisonic = c->audio_ambisonic;
}

static void cfg_from_disk(const LCIConfigOnDisk *d, LCIntermediateConfig *c)
{
    memset(c, 0, sizeof(*c));
    c->width = d->width; c->height = d->height; c->bytes_per_sample = d->bytes_per_sample;
    c->bit_depth = d->bit_depth; c->full_range = d->full_range;
    c->color_primaries = d->color_primaries; c->color_trc = d->color_trc;
    c->colorspace = d->colorspace; c->chroma_location = d->chroma_location;
    c->fps_num = d->fps_num; c->fps_den = d->fps_den; c->codec = (LCStage1Codec)d->codec;
    c->audio_sample_rate = d->audio_sample_rate; c->audio_channels = d->audio_channels;
    c->audio_ambisonic = d->audio_ambisonic;
}

const char *lc_stage1_codec_name(LCStage1Codec codec)
{
    switch (codec) {
    case LC_S1_RAW: return "Raw planes (no compression)";
    case LC_S1_LZ4: return "LZ4 (libcompression)";
    case LC_S1_LZ4_SHUFFLE: return "LZ4 + byte shuffle";
    case LC_S1_FFV1_FAST: return "FFV1 fast (context 0)";
    case LC_S1_UTVIDEO: return "UT Video";
    default: return "unknown";
    }
}

int lc_stage1_codec_supported(LCStage1Codec codec, int bytes_per_sample)
{
    switch (codec) {
    case LC_S1_RAW:
    case LC_S1_LZ4:
    case LC_S1_LZ4_SHUFFLE:
        return 1;
    case LC_S1_FFV1_FAST:
        return lc_encoder_supports_pix_fmt("ffv1", bytes_per_sample == 2 ? LC_PIX_YUV420P10 : LC_PIX_YUV420P8);
    case LC_S1_UTVIDEO:
        return lc_encoder_supports_pix_fmt("utvideo", bytes_per_sample == 2 ? LC_PIX_YUV420P10 : LC_PIX_YUV420P8);
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------------ */
/* Stage-1 encoder                                                           */
/* ------------------------------------------------------------------------ */

struct LCStage1Encoder {
    LCIntermediateConfig cfg;
    size_t packed_size;
    uint8_t *packed;       /* packed (and possibly shuffled) frame */
    uint8_t *out;
    size_t out_cap;
    void *scratch;
    AVCodecContext *enc;
    AVFrame *frame;
    AVPacket *pkt;
};

LCStage1Encoder *lc_s1_encoder_create(const LCIntermediateConfig *cfg, char *err, size_t errlen)
{
    lc_bridge_init();
    if (!cfg || cfg->width <= 0 || cfg->height <= 0 || (cfg->bytes_per_sample != 1 && cfg->bytes_per_sample != 2)) {
        lc_set_err(err, errlen, "invalid stage-1 configuration");
        return NULL;
    }
    char b[64];
    LCStage1Encoder *e = (LCStage1Encoder *)calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->cfg = *cfg;
    e->packed_size = (size_t)cfg->width * cfg->height * cfg->bytes_per_sample * 3 / 2;

    switch (cfg->codec) {
    case LC_S1_RAW:
        e->packed = (uint8_t *)malloc(e->packed_size);
        if (!e->packed) goto fail;
        break;
    case LC_S1_LZ4:
    case LC_S1_LZ4_SHUFFLE:
        e->packed = (uint8_t *)malloc(e->packed_size);
        e->out_cap = lc_lz4_bound(e->packed_size);
        e->out = (uint8_t *)malloc(e->out_cap);
        e->scratch = malloc(lc_lz4_scratch_size());
        if (!e->packed || !e->out || !e->scratch) goto fail;
        break;
    case LC_S1_FFV1_FAST:
    case LC_S1_UTVIDEO: {
        LCPixelFormat pix = cfg->bytes_per_sample == 2 ? LC_PIX_YUV420P10 : LC_PIX_YUV420P8;
        const AVCodec *codec = avcodec_find_encoder(cfg->codec == LC_S1_UTVIDEO ? AV_CODEC_ID_UTVIDEO : AV_CODEC_ID_FFV1);
        if (!codec) { lc_set_err(err, errlen, "encoder not available in this build"); goto fail; }
        if (!lc_encoder_supports_pix_fmt(codec->name, pix)) {
            lc_set_err(err, errlen, "%s cannot encode %s", codec->name, pix == LC_PIX_YUV420P10 ? "yuv420p10le" : "yuv420p");
            goto fail;
        }
        e->enc = avcodec_alloc_context3(codec);
        if (!e->enc) goto fail;
        int ret;
        if (cfg->codec == LC_S1_FFV1_FAST) {
            LCFfv1Params p = { .level = 3, .coder = 1, .context = 0, .slices = 24, .slicecrc = 0, .threads = 1, .gop = 1 };
            ret = lc_ffv1_configure(e->enc, &p, pix, cfg->width, cfg->height, cfg->fps_num, cfg->fps_den,
                                    cfg->full_range, cfg->color_primaries, cfg->color_trc, cfg->colorspace,
                                    cfg->chroma_location, 0, err, errlen);
            if (ret < 0) goto fail;
        } else {
            e->enc->width = cfg->width;
            e->enc->height = cfg->height;
            e->enc->pix_fmt = lc_to_av_pixfmt(pix);
            e->enc->time_base = LC_TB_NS;
            e->enc->thread_count = 1;
        }
        ret = avcodec_open2(e->enc, codec, NULL);
        if (ret < 0) { lc_set_err(err, errlen, "stage-1 encoder open: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
        e->frame = av_frame_alloc();
        e->pkt = av_packet_alloc();
        if (!e->frame || !e->pkt) goto fail;
        e->frame->format = e->enc->pix_fmt;
        e->frame->width = cfg->width;
        e->frame->height = cfg->height;
        ret = av_frame_get_buffer(e->frame, 64);
        if (ret < 0) goto fail;
        break;
    }
    default:
        lc_set_err(err, errlen, "unknown stage-1 codec %d", (int)cfg->codec);
        goto fail;
    }
    return e;
fail:
    if (err && errlen && !err[0]) lc_set_err(err, errlen, "stage-1 encoder allocation failed");
    lc_s1_encoder_destroy(e);
    return NULL;
}

int lc_s1_encoder_compress(LCStage1Encoder *e, const uint8_t *y, size_t y_stride,
                           const uint8_t *cbcr, size_t cbcr_stride,
                           const uint8_t **out, size_t *out_size)
{
    if (!e || !y || !cbcr || !out || !out_size) return -1;
    const LCIntermediateConfig *c = &e->cfg;
    switch (c->codec) {
    case LC_S1_RAW:
        lc_pack_biplanar(y, y_stride, cbcr, cbcr_stride, c->width, c->height, c->bytes_per_sample, e->packed);
        *out = e->packed;
        *out_size = e->packed_size;
        return 0;
    case LC_S1_LZ4:
    case LC_S1_LZ4_SHUFFLE: {
        uint8_t *src = e->packed;
        if (c->codec == LC_S1_LZ4_SHUFFLE && c->bytes_per_sample == 2) {
            /* pack into `out` first, shuffle into `packed`, compress from there */
            lc_pack_biplanar(y, y_stride, cbcr, cbcr_stride, c->width, c->height, c->bytes_per_sample, e->out);
            lc_shuffle_bytes(e->out, e->packed, e->packed_size / 2, 2);
        } else {
            lc_pack_biplanar(y, y_stride, cbcr, cbcr_stride, c->width, c->height, c->bytes_per_sample, e->packed);
        }
        size_t n = lc_lz4_compress(src, e->packed_size, e->out, e->out_cap, e->scratch);
        if (n == 0 || n >= e->packed_size) {
            /* Incompressible: store (caller sees size == packed_size and sets the stored flag). */
            *out = e->packed;
            *out_size = e->packed_size;
            return 1;   /* 1 = stored uncompressed */
        }
        *out = e->out;
        *out_size = n;
        return 0;
    }
    case LC_S1_FFV1_FAST:
    case LC_S1_UTVIDEO: {
        av_packet_unref(e->pkt);
        int ret = av_frame_make_writable(e->frame);
        if (ret < 0) return ret;
        AVFrame *f = e->frame;
        if (c->bytes_per_sample == 2)
            lc_repack_p010_to_yuv420p10(y, y_stride, cbcr, cbcr_stride, c->width, c->height,
                                        f->data[0], (size_t)f->linesize[0], f->data[1], (size_t)f->linesize[1],
                                        f->data[2], (size_t)f->linesize[2]);
        else
            lc_repack_nv12_to_yuv420p(y, y_stride, cbcr, cbcr_stride, c->width, c->height,
                                      f->data[0], (size_t)f->linesize[0], f->data[1], (size_t)f->linesize[1],
                                      f->data[2], (size_t)f->linesize[2]);
        f->pts = 0;
        ret = avcodec_send_frame(e->enc, f);
        if (ret < 0) return ret;
        ret = avcodec_receive_packet(e->enc, e->pkt);
        if (ret < 0) return ret;  /* intra encoders emit one packet per frame */
        *out = e->pkt->data;
        *out_size = (size_t)e->pkt->size;
        return 0;
    }
    default:
        return -1;
    }
}

const uint8_t *lc_s1_encoder_extradata(const LCStage1Encoder *e, size_t *size)
{
    if (!e || !e->enc || !e->enc->extradata) { if (size) *size = 0; return NULL; }
    if (size) *size = (size_t)e->enc->extradata_size;
    return e->enc->extradata;
}

void lc_s1_encoder_destroy(LCStage1Encoder *e)
{
    if (!e) return;
    free(e->packed);
    free(e->out);
    free(e->scratch);
    av_frame_free(&e->frame);
    av_packet_free(&e->pkt);
    avcodec_free_context(&e->enc);
    free(e);
}

/* ------------------------------------------------------------------------ */
/* Writer                                                                    */
/* ------------------------------------------------------------------------ */

struct LCIntermediateWriter {
    FILE *f;
    pthread_mutex_t mu;
    LCIEntry *entries;
    size_t count, cap;
    uint64_t pos;
    uint64_t raw_bytes;
    int64_t audio_seq;
    int channels;
    int failed;
};

LCIntermediateWriter *lc_lci_open(const char *path, const LCIntermediateConfig *cfg,
                                  const uint8_t *extradata, size_t extradata_size,
                                  char *err, size_t errlen)
{
    if (!path || !cfg) { lc_set_err(err, errlen, "invalid arguments"); return NULL; }
    FILE *f = fopen(path, "wb");
    if (!f) { lc_set_err(err, errlen, "cannot create %s: %s", path, strerror(errno)); return NULL; }
    setvbuf(f, NULL, _IOFBF, 4 << 20);
    LCIConfigOnDisk d;
    cfg_to_disk(cfg, &d);
    uint32_t hdr_size = (uint32_t)(4 + 4 + sizeof(d) + 4 + extradata_size);
    uint32_t xs = (uint32_t)extradata_size;
    if (fwrite(LCI_MAGIC, 1, 4, f) != 4 || fwrite(&hdr_size, 4, 1, f) != 1 ||
        fwrite(&d, sizeof(d), 1, f) != 1 || fwrite(&xs, 4, 1, f) != 1 ||
        (extradata_size && fwrite(extradata, 1, extradata_size, f) != extradata_size)) {
        lc_set_err(err, errlen, "write failed: %s", strerror(errno));
        fclose(f);
        return NULL;
    }
    LCIntermediateWriter *w = (LCIntermediateWriter *)calloc(1, sizeof(*w));
    if (!w) { fclose(f); return NULL; }
    w->f = f;
    w->pos = hdr_size;
    w->channels = cfg->audio_channels;
    pthread_mutex_init(&w->mu, NULL);
    return w;
}

static int append_chunk(LCIntermediateWriter *w, const LCIChunkHeader *h, const void *payload)
{
    pthread_mutex_lock(&w->mu);
    int ret = 0;
    if (w->failed) { pthread_mutex_unlock(&w->mu); return -1; }
    if (w->count == w->cap) {
        size_t ncap = w->cap ? w->cap * 2 : 4096;
        LCIEntry *ne = (LCIEntry *)realloc(w->entries, ncap * sizeof(LCIEntry));
        if (!ne) { w->failed = 1; pthread_mutex_unlock(&w->mu); return -1; }
        w->entries = ne;
        w->cap = ncap;
    }
    if (fwrite(h, sizeof(*h), 1, w->f) != 1 || (h->size && fwrite(payload, 1, (size_t)h->size, w->f) != h->size)) {
        w->failed = 1;
        ret = -1;
    } else {
        w->entries[w->count].hdr = *h;
        w->entries[w->count].offset = w->pos + sizeof(*h);
        w->count++;
        w->pos += sizeof(*h) + h->size;
        w->raw_bytes += h->raw_size;
    }
    pthread_mutex_unlock(&w->mu);
    return ret;
}

int lc_lci_append_video(LCIntermediateWriter *w, int64_t frame_index, int64_t pts_ns,
                        uint64_t hash, const uint8_t *data, size_t size, size_t raw_size)
{
    if (!w || !data) return -1;
    LCIChunkHeader h;
    memset(&h, 0, sizeof(h));
    h.type = 'V';
    h.flags = (size == raw_size) ? LCI_FLAG_STORED : 0;
    h.index = frame_index;
    h.pts_ns = pts_ns;
    h.aux = hash;
    h.size = size;
    h.raw_size = raw_size;
    return append_chunk(w, &h, data);
}

int lc_lci_append_audio(LCIntermediateWriter *w, int64_t pts_ns, const int32_t *samples, int nb_frames)
{
    if (!w || !samples || nb_frames <= 0 || w->channels <= 0) return -1;
    LCIChunkHeader h;
    memset(&h, 0, sizeof(h));
    h.type = 'A';
    pthread_mutex_lock(&w->mu);
    h.index = w->audio_seq++;
    pthread_mutex_unlock(&w->mu);
    h.pts_ns = pts_ns;
    h.aux = (uint64_t)nb_frames;
    h.size = (uint64_t)nb_frames * (uint64_t)w->channels * sizeof(int32_t);
    h.raw_size = h.size;
    return append_chunk(w, &h, samples);
}

int lc_lci_close(LCIntermediateWriter *w)
{
    if (!w) return -1;
    int ret = 0;
    pthread_mutex_lock(&w->mu);
    if (!w->failed) {
        uint64_t trailer_off = w->pos;
        uint64_t count = w->count;
        if (fwrite("LCIX", 1, 4, w->f) != 4 || fwrite(&count, 8, 1, w->f) != 1) ret = -1;
        for (size_t i = 0; i < w->count && ret == 0; i++) {
            if (fwrite(&w->entries[i].hdr, sizeof(LCIChunkHeader), 1, w->f) != 1 ||
                fwrite(&w->entries[i].offset, 8, 1, w->f) != 1) ret = -1;
        }
        if (ret == 0 && (fwrite(&trailer_off, 8, 1, w->f) != 1 || fwrite("LCIE", 1, 4, w->f) != 4)) ret = -1;
    } else {
        ret = -1;
    }
    if (fflush(w->f) != 0) ret = -1;
    if (fclose(w->f) != 0) ret = -1;
    pthread_mutex_unlock(&w->mu);
    pthread_mutex_destroy(&w->mu);
    free(w->entries);
    free(w);
    return ret;
}

void lc_lci_abort(LCIntermediateWriter *w)
{
    if (!w) return;
    fclose(w->f);
    pthread_mutex_destroy(&w->mu);
    free(w->entries);
    free(w);
}

uint64_t lc_lci_bytes_written(const LCIntermediateWriter *w) { return w ? w->pos : 0; }
uint64_t lc_lci_raw_bytes(const LCIntermediateWriter *w) { return w ? w->raw_bytes : 0; }

/* ------------------------------------------------------------------------ */
/* Reader                                                                    */
/* ------------------------------------------------------------------------ */

static int reader_scan(LCIReader *r, uint64_t start, uint64_t file_size)
{
    uint64_t pos = start;
    size_t cap = 0;
    r->count = 0;
    while (pos + sizeof(LCIChunkHeader) <= file_size) {
        LCIChunkHeader h;
        if (fseeko(r->f, (off_t)pos, SEEK_SET) != 0) break;
        if (fread(&h, sizeof(h), 1, r->f) != 1) break;
        if (h.type != 'V' && h.type != 'A') break;   /* trailer or garbage */
        if (pos + sizeof(h) + h.size > file_size) break; /* truncated chunk */
        if (r->count == cap) {
            size_t ncap = cap ? cap * 2 : 4096;
            LCIEntry *ne = (LCIEntry *)realloc(r->entries, ncap * sizeof(LCIEntry));
            if (!ne) return -1;
            r->entries = ne;
            cap = ncap;
        }
        r->entries[r->count].hdr = h;
        r->entries[r->count].offset = pos + sizeof(h);
        r->count++;
        pos += sizeof(h) + h.size;
    }
    r->recovered = 1;
    return 0;
}

LCIReader *lci_reader_open(const char *path, char *err, size_t errlen)
{
    FILE *f = fopen(path, "rb");
    if (!f) { lc_set_err(err, errlen, "cannot open %s: %s", path, strerror(errno)); return NULL; }
    LCIReader *r = (LCIReader *)calloc(1, sizeof(*r));
    if (!r) { fclose(f); return NULL; }
    r->f = f;
    char magic[4];
    uint32_t hdr_size = 0, xs = 0;
    LCIConfigOnDisk d;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, LCI_MAGIC, 4) != 0 || fread(&hdr_size, 4, 1, f) != 1 ||
        fread(&d, sizeof(d), 1, f) != 1 || fread(&xs, 4, 1, f) != 1) {
        lc_set_err(err, errlen, "not a LosslessCam intermediate file");
        goto fail;
    }
    cfg_from_disk(&d, &r->cfg);
    if (xs > 0) {
        if (xs > (1u << 20)) { lc_set_err(err, errlen, "corrupt extradata size"); goto fail; }
        r->extradata = (uint8_t *)malloc(xs + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!r->extradata || fread(r->extradata, 1, xs, f) != xs) { lc_set_err(err, errlen, "truncated header"); goto fail; }
        memset(r->extradata + xs, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        r->extradata_size = xs;
    }
    if (fseeko(f, 0, SEEK_END) != 0) goto fail;
    uint64_t file_size = (uint64_t)ftello(f);

    /* Try the trailer first. */
    int have_trailer = 0;
    if (file_size >= hdr_size + 12) {
        char tail[4];
        uint64_t trailer_off = 0;
        fseeko(f, (off_t)(file_size - 12), SEEK_SET);
        if (fread(&trailer_off, 8, 1, f) == 1 && fread(tail, 1, 4, f) == 4 && memcmp(tail, "LCIE", 4) == 0 &&
            trailer_off >= hdr_size && trailer_off < file_size) {
            char tm[4];
            uint64_t count = 0;
            fseeko(f, (off_t)trailer_off, SEEK_SET);
            if (fread(tm, 1, 4, f) == 4 && memcmp(tm, "LCIX", 4) == 0 && fread(&count, 8, 1, f) == 1 &&
                count < (1u << 26)) {
                r->entries = (LCIEntry *)malloc(((size_t)count + 1) * sizeof(LCIEntry));
                if (!r->entries) goto fail;
                size_t i;
                for (i = 0; i < count; i++) {
                    if (fread(&r->entries[i].hdr, sizeof(LCIChunkHeader), 1, f) != 1 ||
                        fread(&r->entries[i].offset, 8, 1, f) != 1) break;
                }
                if (i == count) { r->count = count; have_trailer = 1; }
            }
        }
    }
    if (!have_trailer) {
        if (reader_scan(r, hdr_size, file_size) < 0) goto fail;
    }
    return r;
fail:
    if (err && errlen && !err[0]) lc_set_err(err, errlen, "intermediate file open failed");
    lci_reader_close(r);
    return NULL;
}

int lci_reader_read_payload(LCIReader *r, const LCIEntry *e, uint8_t *dst)
{
    if (!r || !e || !dst) return -1;
    if (fseeko(r->f, (off_t)e->offset, SEEK_SET) != 0) return -1;
    if (e->hdr.size && fread(dst, 1, (size_t)e->hdr.size, r->f) != e->hdr.size) return -1;
    return 0;
}

void lci_reader_close(LCIReader *r)
{
    if (!r) return;
    if (r->f) fclose(r->f);
    free(r->extradata);
    free(r->entries);
    free(r);
}
