/* FFV1 (video) + FLAC (audio) Matroska writer.
 *
 * Video frames arrive either bi-planar (straight from a locked CVPixelBuffer)
 * or planar (from a decoder); both paths end in the same yuv420p / yuv420p10le
 * AVFrame, which is bit-exact with the source samples. Audio arrives as
 * interleaved int32 with the 24-bit value top-aligned, exactly the layout
 * libavcodec's FLAC encoder consumes for 24-bit output.
 */
#include "lc_internal.h"

struct LCMkvWriter {
    LCMkvConfig cfg;
    int bps;

    AVFormatContext *fmt;
    AVStream *vst, *ast;
    AVCodecContext *venc, *aenc;
    AVFrame *vframe, *aframe;
    AVPacket *pkt;
    AVAudioFifo *fifo;

    int header_written;
    int have_origin;
    int64_t origin_pts_ns;         /* pts of the first video frame */
    int64_t frame_dur_ns;

    int64_t video_frames;
    int64_t audio_frames_committed;   /* sample frames pushed into the stream (incl. silence) */
    int64_t audio_frames_encoded;
    int64_t audio_trimmed;
    int64_t audio_silence_inserted;
    int     audio_discontinuities;
    int64_t audio_stream_start_frame;  /* position (sample frames since origin) of the first committed sample */
    int64_t audio_next_input_frame;    /* expected position of the next incoming sample */
    int     audio_started;
    LCHashState *audio_hash;
    uint16_t low_bits;

    char err[256];
};

static int write_packets(LCMkvWriter *w, AVCodecContext *enc, AVStream *st, AVRational src_tb)
{
    int ret;
    for (;;) {
        ret = avcodec_receive_packet(enc, w->pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) {
            char b[64];
            snprintf(w->err, sizeof(w->err), "receive_packet: %s", lc_averr(ret, b, sizeof(b)));
            return ret;
        }
        av_packet_rescale_ts(w->pkt, src_tb, st->time_base);
        w->pkt->stream_index = st->index;
        ret = av_interleaved_write_frame(w->fmt, w->pkt);
        av_packet_unref(w->pkt);
        if (ret < 0) {
            char b[64];
            snprintf(w->err, sizeof(w->err), "write_frame: %s", lc_averr(ret, b, sizeof(b)));
            return ret;
        }
    }
}

static void set_metadata(AVDictionary **dict, const char *const *kv)
{
    if (!kv) return;
    for (int i = 0; kv[i] && kv[i + 1]; i += 2)
        av_dict_set(dict, kv[i], kv[i + 1], 0);
}

LCMkvWriter *lc_mkv_open(const char *path, const LCMkvConfig *cfg, char *err, size_t errlen)
{
    lc_bridge_init();
    if (!path || !cfg || cfg->width <= 0 || cfg->height <= 0) {
        lc_set_err(err, errlen, "invalid writer configuration");
        return NULL;
    }
    char b[64];
    int ret;
    LCMkvWriter *w = (LCMkvWriter *)calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->cfg = *cfg;
    w->cfg.metadata = NULL;
    w->bps = cfg->pix_fmt == LC_PIX_YUV420P10 ? 2 : 1;
    int fps_num = cfg->fps_num > 0 ? cfg->fps_num : 60;
    int fps_den = cfg->fps_den > 0 ? cfg->fps_den : 1;
    w->frame_dur_ns = (int64_t)llround(1e9 * (double)fps_den / (double)fps_num);

    ret = avformat_alloc_output_context2(&w->fmt, NULL, "matroska", path);
    if (ret < 0 || !w->fmt) {
        lc_set_err(err, errlen, "matroska muxer unavailable: %s", lc_averr(ret, b, sizeof(b)));
        goto fail;
    }
    int global_header = (w->fmt->oformat->flags & AVFMT_GLOBALHEADER) != 0;

    /* ---- video ---- */
    const AVCodec *vcodec = avcodec_find_encoder(AV_CODEC_ID_FFV1);
    if (!vcodec) { lc_set_err(err, errlen, "FFV1 encoder not available"); goto fail; }
    w->vst = avformat_new_stream(w->fmt, NULL);
    w->venc = avcodec_alloc_context3(vcodec);
    if (!w->vst || !w->venc) { lc_set_err(err, errlen, "alloc failed"); goto fail; }
    ret = lc_ffv1_configure(w->venc, &cfg->ffv1, cfg->pix_fmt, cfg->width, cfg->height,
                            fps_num, fps_den, cfg->full_range, cfg->color_primaries,
                            cfg->color_trc, cfg->colorspace, cfg->chroma_location,
                            global_header, err, errlen);
    if (ret < 0) goto fail;
    ret = avcodec_open2(w->venc, vcodec, NULL);
    if (ret < 0) { lc_set_err(err, errlen, "FFV1 open: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
    ret = avcodec_parameters_from_context(w->vst->codecpar, w->venc);
    if (ret < 0) { lc_set_err(err, errlen, "codecpar: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
    w->vst->time_base = (AVRational){1, 1000};
    w->vst->avg_frame_rate = w->venc->framerate;
    w->vst->r_frame_rate = w->venc->framerate;
    av_dict_set(&w->vst->metadata, "title", "LosslessCam FFV1 video", 0);

    w->vframe = av_frame_alloc();
    if (!w->vframe) goto fail;
    w->vframe->format = w->venc->pix_fmt;
    w->vframe->width = cfg->width;
    w->vframe->height = cfg->height;
    ret = av_frame_get_buffer(w->vframe, 64);
    if (ret < 0) { lc_set_err(err, errlen, "frame alloc: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
    w->vframe->color_range = w->venc->color_range;
    w->vframe->color_primaries = w->venc->color_primaries;
    w->vframe->color_trc = w->venc->color_trc;
    w->vframe->colorspace = w->venc->colorspace;
    w->vframe->chroma_location = w->venc->chroma_sample_location;

    /* ---- audio ---- */
    if (cfg->audio_enabled && cfg->audio_sample_rate > 0 && cfg->audio_channels > 0) {
        const AVCodec *acodec = avcodec_find_encoder(AV_CODEC_ID_FLAC);
        if (!acodec) { lc_set_err(err, errlen, "FLAC encoder not available"); goto fail; }
        w->ast = avformat_new_stream(w->fmt, NULL);
        w->aenc = avcodec_alloc_context3(acodec);
        if (!w->ast || !w->aenc) goto fail;
        w->aenc->sample_fmt = AV_SAMPLE_FMT_S32;
        w->aenc->bits_per_raw_sample = 24;
        w->aenc->sample_rate = cfg->audio_sample_rate;
        w->aenc->time_base = (AVRational){1, cfg->audio_sample_rate};
        w->aenc->compression_level = cfg->flac_compression_level >= 0 ? cfg->flac_compression_level : 5;
        if (cfg->audio_ambisonic && cfg->audio_channels == 4) {
            /* FLAC has no ambisonic channel assignment; keep the encoder on an
             * unspecified 4-channel layout and tag the Matroska track instead. */
            av_channel_layout_uninit(&w->aenc->ch_layout);
            w->aenc->ch_layout.order = AV_CHANNEL_ORDER_UNSPEC;
            w->aenc->ch_layout.nb_channels = 4;
        } else if (cfg->audio_channels == 2) {
            AVChannelLayout st = AV_CHANNEL_LAYOUT_STEREO;
            av_channel_layout_copy(&w->aenc->ch_layout, &st);
        } else if (cfg->audio_channels == 1) {
            AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
            av_channel_layout_copy(&w->aenc->ch_layout, &mono);
        } else {
            av_channel_layout_default(&w->aenc->ch_layout, cfg->audio_channels);
        }
        if (global_header) w->aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        ret = avcodec_open2(w->aenc, acodec, NULL);
        if (ret < 0) { lc_set_err(err, errlen, "FLAC open: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
        ret = avcodec_parameters_from_context(w->ast->codecpar, w->aenc);
        if (ret < 0) goto fail;
        if (cfg->audio_ambisonic && cfg->audio_channels == 4) {
            AVChannelLayout amb = AV_CHANNEL_LAYOUT_AMBISONIC_FIRST_ORDER;
            av_channel_layout_uninit(&w->ast->codecpar->ch_layout);
            av_channel_layout_copy(&w->ast->codecpar->ch_layout, &amb);
            av_dict_set(&w->ast->metadata, "AMBISONIC_ORDER", "1", 0);
            av_dict_set(&w->ast->metadata, "AMBISONIC_CHANNEL_ORDER", "ACN", 0);
            av_dict_set(&w->ast->metadata, "AMBISONIC_NORMALIZATION", "SN3D", 0);
            av_dict_set(&w->ast->metadata, "CHANNEL_LAYOUT", "ambisonic 1 (W Y Z X)", 0);
            av_dict_set(&w->ast->metadata, "title", "LosslessCam FLAC first-order ambisonics", 0);
        } else {
            av_dict_set(&w->ast->metadata, "title", "LosslessCam FLAC audio", 0);
        }
        w->ast->time_base = w->aenc->time_base;

        w->aframe = av_frame_alloc();
        if (!w->aframe) goto fail;
        w->aframe->format = AV_SAMPLE_FMT_S32;
        w->aframe->sample_rate = cfg->audio_sample_rate;
        w->aframe->nb_samples = w->aenc->frame_size > 0 ? w->aenc->frame_size : 4096;
        av_channel_layout_copy(&w->aframe->ch_layout, &w->aenc->ch_layout);
        ret = av_frame_get_buffer(w->aframe, 0);
        if (ret < 0) { lc_set_err(err, errlen, "audio frame alloc: %s", lc_averr(ret, b, sizeof(b))); goto fail; }

        w->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_S32, cfg->audio_channels, w->aframe->nb_samples * 4);
        if (!w->fifo) goto fail;
        w->audio_hash = lc_hash_create();
    }

    w->pkt = av_packet_alloc();
    if (!w->pkt) goto fail;

    /* ---- container metadata ---- */
    av_dict_set(&w->fmt->metadata, "title", "LosslessCam recording", 0);
    set_metadata(&w->fmt->metadata, cfg->metadata);

    ret = avio_open(&w->fmt->pb, path, AVIO_FLAG_WRITE);
    if (ret < 0) { lc_set_err(err, errlen, "cannot create %s: %s", path, lc_averr(ret, b, sizeof(b))); goto fail; }
    ret = avformat_write_header(w->fmt, NULL);
    if (ret < 0) { lc_set_err(err, errlen, "write_header: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
    w->header_written = 1;
    return w;

fail:
    if (err && errlen && !err[0]) lc_set_err(err, errlen, "writer setup failed");
    lc_mkv_abort(w);
    return NULL;
}

void lc_mkv_set_origin(LCMkvWriter *w, int64_t first_video_pts_ns)
{
    if (!w || w->have_origin) return;
    w->origin_pts_ns = first_video_pts_ns;
    w->have_origin = 1;
}

static int encode_video_frame(LCMkvWriter *w, int64_t pts_ns)
{
    if (!w->have_origin) {
        w->origin_pts_ns = pts_ns;
        w->have_origin = 1;
    }
    w->vframe->pts = pts_ns - w->origin_pts_ns;
    w->vframe->duration = w->frame_dur_ns;
    int ret = avcodec_send_frame(w->venc, w->vframe);
    if (ret < 0) {
        char b[64];
        snprintf(w->err, sizeof(w->err), "send_frame: %s", lc_averr(ret, b, sizeof(b)));
        return ret;
    }
    w->video_frames++;
    return write_packets(w, w->venc, w->vst, w->venc->time_base);
}

int lc_mkv_write_video_biplanar(LCMkvWriter *w, const uint8_t *y, size_t y_stride,
                                const uint8_t *cbcr, size_t cbcr_stride, int64_t pts_ns)
{
    if (!w || !y || !cbcr) return -1;
    int ret = av_frame_make_writable(w->vframe);
    if (ret < 0) return ret;
    AVFrame *f = w->vframe;
    if (w->bps == 2) {
        uint16_t low = lc_repack_p010_to_yuv420p10(y, y_stride, cbcr, cbcr_stride, w->cfg.width, w->cfg.height,
                                                   f->data[0], (size_t)f->linesize[0],
                                                   f->data[1], (size_t)f->linesize[1],
                                                   f->data[2], (size_t)f->linesize[2]);
        w->low_bits |= low;
    } else {
        lc_repack_nv12_to_yuv420p(y, y_stride, cbcr, cbcr_stride, w->cfg.width, w->cfg.height,
                                  f->data[0], (size_t)f->linesize[0],
                                  f->data[1], (size_t)f->linesize[1],
                                  f->data[2], (size_t)f->linesize[2]);
    }
    return encode_video_frame(w, pts_ns);
}

int lc_mkv_write_video_planar(LCMkvWriter *w, const uint8_t *y, size_t y_stride,
                              const uint8_t *u, size_t u_stride,
                              const uint8_t *v, size_t v_stride, int64_t pts_ns)
{
    if (!w || !y || !u || !v) return -1;
    int ret = av_frame_make_writable(w->vframe);
    if (ret < 0) return ret;
    AVFrame *f = w->vframe;
    const size_t row = (size_t)w->cfg.width * (size_t)w->bps;
    const size_t crow = (size_t)((w->cfg.width + 1) / 2) * (size_t)w->bps;
    const int ch = (w->cfg.height + 1) / 2;
    for (int r = 0; r < w->cfg.height; r++)
        memcpy(f->data[0] + (size_t)r * f->linesize[0], y + (size_t)r * y_stride, row);
    for (int r = 0; r < ch; r++) {
        memcpy(f->data[1] + (size_t)r * f->linesize[1], u + (size_t)r * u_stride, crow);
        memcpy(f->data[2] + (size_t)r * f->linesize[2], v + (size_t)r * v_stride, crow);
    }
    return encode_video_frame(w, pts_ns);
}

/* Push interleaved samples into the FIFO, hash them and encode full blocks. */
static int audio_commit(LCMkvWriter *w, const int32_t *samples, int nb_frames)
{
    if (nb_frames <= 0) return 0;
    const int ch = w->cfg.audio_channels;
    lc_hash_update(w->audio_hash, samples, (size_t)nb_frames * ch * sizeof(int32_t));
    void *data[1] = { (void *)samples };
    int ret = av_audio_fifo_write(w->fifo, data, nb_frames);
    if (ret < nb_frames) return ret < 0 ? ret : -1;
    w->audio_frames_committed += nb_frames;

    const int block = w->aframe->nb_samples;
    while (av_audio_fifo_size(w->fifo) >= block) {
        ret = av_frame_make_writable(w->aframe);
        if (ret < 0) return ret;
        w->aframe->nb_samples = block;
        ret = av_audio_fifo_read(w->fifo, (void **)w->aframe->data, block);
        if (ret < block) return ret < 0 ? ret : -1;
        w->aframe->pts = w->audio_stream_start_frame + w->audio_frames_encoded;
        ret = avcodec_send_frame(w->aenc, w->aframe);
        if (ret < 0) {
            char b[64];
            snprintf(w->err, sizeof(w->err), "flac send_frame: %s", lc_averr(ret, b, sizeof(b)));
            return ret;
        }
        w->audio_frames_encoded += block;
        ret = write_packets(w, w->aenc, w->ast, w->aenc->time_base);
        if (ret < 0) return ret;
    }
    return 0;
}

static int audio_insert_silence(LCMkvWriter *w, int64_t frames)
{
    const int ch = w->cfg.audio_channels;
    int32_t *zeros = (int32_t *)calloc((size_t)4096 * ch, sizeof(int32_t));
    if (!zeros) return AVERROR(ENOMEM);
    int ret = 0;
    while (frames > 0 && ret == 0) {
        int n = frames > 4096 ? 4096 : (int)frames;
        ret = audio_commit(w, zeros, n);
        frames -= n;
        w->audio_silence_inserted += n;
    }
    free(zeros);
    return ret;
}

int lc_mkv_write_audio(LCMkvWriter *w, const int32_t *interleaved, int nb_frames, int64_t pts_ns)
{
    if (!w || !interleaved || nb_frames <= 0) return -1;
    if (!w->aenc) return 0;   /* audio disabled */
    const int ch = w->cfg.audio_channels;
    const int64_t sr = w->cfg.audio_sample_rate;

    if (!w->have_origin) {
        /* No video yet: this is pre-roll, discard and account for it. */
        w->audio_trimmed += nb_frames;
        return 0;
    }
    int64_t rel_ns = pts_ns - w->origin_pts_ns;
    if (rel_ns < 0) {
        int64_t skip = (-rel_ns * sr + LC_NS_PER_SEC - 1) / LC_NS_PER_SEC;
        if (skip >= nb_frames) { w->audio_trimmed += nb_frames; return 0; }
        interleaved += skip * ch;
        nb_frames -= (int)skip;
        w->audio_trimmed += skip;
        rel_ns += skip * LC_NS_PER_SEC / sr;
    }
    int64_t pos = (int64_t)llround((double)rel_ns * (double)sr / 1e9);  /* sample frames since origin */

    if (!w->audio_started) {
        w->audio_started = 1;
        w->audio_stream_start_frame = pos;
        w->audio_next_input_frame = pos;
    } else {
        int64_t diff = pos - w->audio_next_input_frame;
        const int64_t tol = sr * 2 / 1000;  /* 2 ms */
        if (diff > tol) {
            w->audio_discontinuities++;
            int ret = audio_insert_silence(w, diff);
            if (ret < 0) return ret;
            w->audio_next_input_frame += diff;
        } else if (diff < -tol) {
            /* Overlapping timestamps: keep every delivered sample, note it. */
            w->audio_discontinuities++;
        }
    }
    int ret = audio_commit(w, interleaved, nb_frames);
    if (ret < 0) return ret;
    w->audio_next_input_frame += nb_frames;
    return 0;
}

static int flush_audio(LCMkvWriter *w)
{
    if (!w->aenc) return 0;
    int ret;
    int remaining = av_audio_fifo_size(w->fifo);
    if (remaining > 0) {
        ret = av_frame_make_writable(w->aframe);
        if (ret < 0) return ret;
        w->aframe->nb_samples = remaining;
        ret = av_audio_fifo_read(w->fifo, (void **)w->aframe->data, remaining);
        if (ret < remaining) return ret < 0 ? ret : -1;
        w->aframe->pts = w->audio_stream_start_frame + w->audio_frames_encoded;
        ret = avcodec_send_frame(w->aenc, w->aframe);
        if (ret < 0) return ret;
        w->audio_frames_encoded += remaining;
        ret = write_packets(w, w->aenc, w->ast, w->aenc->time_base);
        if (ret < 0) return ret;
    }
    ret = avcodec_send_frame(w->aenc, NULL);
    if (ret < 0 && ret != AVERROR_EOF) return ret;
    return write_packets(w, w->aenc, w->ast, w->aenc->time_base);
}

int lc_mkv_close(LCMkvWriter *w)
{
    if (!w) return -1;
    int ret = 0, r;
    if (w->header_written) {
        r = avcodec_send_frame(w->venc, NULL);
        if (r < 0 && r != AVERROR_EOF) ret = r;
        r = write_packets(w, w->venc, w->vst, w->venc->time_base);
        if (r < 0) ret = r;
        r = flush_audio(w);
        if (r < 0) ret = r;
        r = av_write_trailer(w->fmt);
        if (r < 0) ret = r;
    }
    if (w->fmt && w->fmt->pb) avio_closep(&w->fmt->pb);
    lc_mkv_abort(w);
    return ret;
}

void lc_mkv_abort(LCMkvWriter *w)
{
    if (!w) return;
    if (w->fmt && w->fmt->pb) avio_closep(&w->fmt->pb);
    av_audio_fifo_free(w->fifo);
    av_frame_free(&w->vframe);
    av_frame_free(&w->aframe);
    av_packet_free(&w->pkt);
    avcodec_free_context(&w->venc);
    avcodec_free_context(&w->aenc);
    avformat_free_context(w->fmt);
    lc_hash_destroy(w->audio_hash);
    free(w);
}

uint64_t lc_mkv_bytes_written(const LCMkvWriter *w)
{
    if (!w || !w->fmt || !w->fmt->pb) return 0;
    int64_t pos = avio_tell(w->fmt->pb);
    return pos > 0 ? (uint64_t)pos : 0;
}
int64_t lc_mkv_video_frames_written(const LCMkvWriter *w) { return w ? w->video_frames : 0; }
int64_t lc_mkv_audio_frames_written(const LCMkvWriter *w) { return w ? w->audio_frames_committed : 0; }
int64_t lc_mkv_audio_trimmed_frames(const LCMkvWriter *w) { return w ? w->audio_trimmed : 0; }
int lc_mkv_audio_discontinuities(const LCMkvWriter *w) { return w ? w->audio_discontinuities : 0; }
int64_t lc_mkv_audio_silence_frames_inserted(const LCMkvWriter *w) { return w ? w->audio_silence_inserted : 0; }
uint16_t lc_mkv_low_bits_seen(const LCMkvWriter *w) { return w ? w->low_bits : 0; }
uint64_t lc_mkv_audio_running_hash(const LCMkvWriter *w) { return (w && w->audio_hash) ? lc_hash_digest(w->audio_hash) : 0; }
const char *lc_mkv_last_error(const LCMkvWriter *w) { return w ? w->err : ""; }
