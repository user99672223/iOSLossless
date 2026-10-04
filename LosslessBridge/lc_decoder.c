/* Demux + decode for the players and the verifier.
 *
 * Video and audio are decoded through separate LCDecoder instances (open the
 * file twice) so that scrubbing one stream never has to discard packets of
 * the other. Frame indexing uses the container index (Matroska cues, which
 * libavformat's muxer writes for every FFV1 keyframe, or the MOV sample
 * table); when no index exists it falls back to fps arithmetic.
 */
#include "lc_internal.h"

struct LCDecoder {
    AVFormatContext *fmt;
    int vidx, aidx;
    AVCodecContext *vdec, *adec;
    AVPacket *pkt;
    AVFrame *vframe, *aframe;
    AVRational vtb, atb;
    int bps;
    LCMediaInfo info;

    /* frame index table (stream timebase) */
    int64_t *idx_ts;
    int64_t  idx_count;

    int64_t next_seq;          /* sequential counter used when no index */
    int     seeking;
    int64_t seek_target_ns;
    int     v_draining, v_eof;
    int     a_draining, a_eof;
    int     a_seeking;
    int64_t a_seek_target_ns;

    /* audio leftover (interleaved int32) */
    int32_t *a_left;
    int      a_left_frames;
    int      a_left_cap;
    int64_t  a_left_pts_ns;

    _Atomic int crc_errors;
};

static int64_t ts_to_ns(int64_t ts, AVRational tb)
{
    if (ts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(ts, tb, LC_TB_NS);
}

static int64_t ns_to_ts(int64_t ns, AVRational tb)
{
    return av_rescale_q(ns, LC_TB_NS, tb);
}

static void build_index(LCDecoder *d)
{
    AVStream *st = d->fmt->streams[d->vidx];
    int n = avformat_index_get_entries_count(st);
    if (n <= 0) return;
    int64_t *ts = (int64_t *)malloc((size_t)n * sizeof(int64_t));
    if (!ts) return;
    int m = 0;
    int64_t last = INT64_MIN;
    for (int i = 0; i < n; i++) {
        const AVIndexEntry *e = avformat_index_get_entry(st, i);
        if (!e) continue;
        if (e->timestamp == last) continue;   /* duplicate cue for the same frame */
        ts[m++] = e->timestamp;
        last = e->timestamp;
    }
    d->idx_ts = ts;
    d->idx_count = m;
}

static int64_t index_lookup(const LCDecoder *d, int64_t ts)
{
    /* nearest entry by binary search */
    int64_t lo = 0, hi = d->idx_count - 1;
    while (lo < hi) {
        int64_t mid = (lo + hi) / 2;
        if (d->idx_ts[mid] < ts) lo = mid + 1; else hi = mid;
    }
    if (lo > 0 && llabs(d->idx_ts[lo - 1] - ts) < llabs(d->idx_ts[lo] - ts)) lo--;
    return lo;
}

LCDecoder *lc_decoder_open(const char *path, int want_video, int want_audio, int threads,
                           char *err, size_t errlen)
{
    lc_bridge_init();
    char b[64];
    int ret;
    LCDecoder *d = (LCDecoder *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->vidx = d->aidx = -1;

    ret = avformat_open_input(&d->fmt, path, NULL, NULL);
    if (ret < 0) { lc_set_err(err, errlen, "open: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
    ret = avformat_find_stream_info(d->fmt, NULL);
    if (ret < 0) { lc_set_err(err, errlen, "stream info: %s", lc_averr(ret, b, sizeof(b))); goto fail; }

    snprintf(d->info.container, sizeof(d->info.container), "%s", d->fmt->iformat->name);
    d->info.duration_ns = d->fmt->duration > 0 ? av_rescale_q(d->fmt->duration, AV_TIME_BASE_Q, LC_TB_NS) : 0;

    if (want_video) {
        d->vidx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (d->vidx >= 0) {
            AVStream *st = d->fmt->streams[d->vidx];
            const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
            if (!codec) { lc_set_err(err, errlen, "no decoder for video codec id %d", st->codecpar->codec_id); goto fail; }
            d->vdec = avcodec_alloc_context3(codec);
            if (!d->vdec) goto fail;
            ret = avcodec_parameters_to_context(d->vdec, st->codecpar);
            if (ret < 0) goto fail;
            d->vdec->pkt_timebase = st->time_base;
            d->vdec->thread_count = threads > 0 ? threads : lc_cpu_count();
            d->vdec->thread_type = (codec->id == AV_CODEC_ID_FFV1) ? FF_THREAD_SLICE : (FF_THREAD_FRAME | FF_THREAD_SLICE);
            d->vdec->err_recognition |= AV_EF_CRCCHECK;
            ret = avcodec_open2(d->vdec, codec, NULL);
            if (ret < 0) { lc_set_err(err, errlen, "video decoder: %s", lc_averr(ret, b, sizeof(b))); goto fail; }
            lc_log_register_codec_ctx(d->vdec, &d->crc_errors);
            d->vtb = st->time_base;
            d->vframe = av_frame_alloc();

            d->info.has_video = 1;
            d->info.width = st->codecpar->width;
            d->info.height = st->codecpar->height;
            snprintf(d->info.video_codec, sizeof(d->info.video_codec), "%s", codec->name);
            enum AVPixelFormat pf = (enum AVPixelFormat)st->codecpar->format;
            if (pf == AV_PIX_FMT_NONE) pf = d->vdec->pix_fmt;
            LCPixelFormat lcpf;
            if (lc_from_av_pixfmt(pf, &lcpf) < 0) {
                lc_set_err(err, errlen, "unsupported pixel format %s (only 4:2:0 8/10-bit)",
                           av_get_pix_fmt_name(pf) ? av_get_pix_fmt_name(pf) : "?");
                goto fail;
            }
            d->info.pix_fmt = lcpf;
            d->info.bit_depth = lcpf == LC_PIX_YUV420P10 ? 10 : 8;
            d->bps = lcpf == LC_PIX_YUV420P10 ? 2 : 1;
            d->info.full_range = st->codecpar->color_range == AVCOL_RANGE_JPEG || pf == AV_PIX_FMT_YUVJ420P;
            d->info.color_primaries = st->codecpar->color_primaries;
            d->info.color_trc = st->codecpar->color_trc;
            d->info.colorspace = st->codecpar->color_space;
            d->info.chroma_location = st->codecpar->chroma_location;
            AVRational fr = av_guess_frame_rate(d->fmt, st, NULL);
            if (fr.num <= 0 || fr.den <= 0) fr = st->avg_frame_rate;
            if (fr.num <= 0 || fr.den <= 0) fr = (AVRational){30, 1};
            d->info.fps_num = fr.num;
            d->info.fps_den = fr.den;
            if (st->duration > 0 && st->duration != AV_NOPTS_VALUE)
                d->info.duration_ns = ts_to_ns(st->duration, st->time_base);

            /* The Matroska demuxer defers Cues parsing until the first seek;
             * seeking to the start forces the index to materialise. */
            if (av_seek_frame(d->fmt, d->vidx, 0, AVSEEK_FLAG_BACKWARD) >= 0)
                avcodec_flush_buffers(d->vdec);
            build_index(d);
            if (d->idx_count > 0) {
                d->info.frame_count = d->idx_count;
                d->info.frame_count_exact = 1;
            } else if (st->nb_frames > 0) {
                d->info.frame_count = st->nb_frames;
                d->info.frame_count_exact = 1;
            } else {
                d->info.frame_count = (int64_t)llround((double)d->info.duration_ns / 1e9 * fr.num / fr.den);
                d->info.frame_count_exact = 0;
            }
            if (codec->id == AV_CODEC_ID_FFV1) {
                /* FFV1 >= v3 appends a CRC-32 to the configuration record, so the
                 * CRC over the whole extradata is zero exactly for version 3+. */
                if (st->codecpar->extradata_size > 4) {
                    uint32_t crc = av_crc(av_crc_get_table(AV_CRC_32_IEEE), 0,
                                          st->codecpar->extradata, (size_t)st->codecpar->extradata_size);
                    d->info.ffv1_version = crc == 0 ? 3 : 2;
                } else {
                    d->info.ffv1_version = 1;
                }
                d->info.ffv1_slicecrc = d->info.ffv1_version >= 3 ? 1 : 0;
            }
        }
    }

    if (want_audio) {
        d->aidx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
        if (d->aidx >= 0) {
            AVStream *st = d->fmt->streams[d->aidx];
            const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
            if (codec) {
                d->adec = avcodec_alloc_context3(codec);
                if (!d->adec) goto fail;
                ret = avcodec_parameters_to_context(d->adec, st->codecpar);
                if (ret < 0) goto fail;
                d->adec->pkt_timebase = st->time_base;
                ret = avcodec_open2(d->adec, codec, NULL);
                if (ret < 0) { avcodec_free_context(&d->adec); d->aidx = -1; }
                else {
                    d->atb = st->time_base;
                    d->aframe = av_frame_alloc();
                    d->info.has_audio = 1;
                    snprintf(d->info.audio_codec, sizeof(d->info.audio_codec), "%s", codec->name);
                    d->info.sample_rate = st->codecpar->sample_rate;
                    d->info.channels = st->codecpar->ch_layout.nb_channels;
                    d->info.bits_per_sample = st->codecpar->bits_per_raw_sample > 0 ? st->codecpar->bits_per_raw_sample :
                                              av_get_bytes_per_sample((enum AVSampleFormat)st->codecpar->format) * 8;
                    d->info.audio_ambisonic = st->codecpar->ch_layout.order == AV_CHANNEL_ORDER_AMBISONIC;
                    if (!d->info.audio_ambisonic) {
                        AVDictionaryEntry *e = av_dict_get(st->metadata, "AMBISONIC_ORDER", NULL, 0);
                        if (e && atoi(e->value) == 1 && d->info.channels == 4) d->info.audio_ambisonic = 1;
                    }
                    if (!d->info.has_video && d->info.duration_ns == 0 && st->duration > 0)
                        d->info.duration_ns = ts_to_ns(st->duration, st->time_base);
                }
            } else {
                d->aidx = -1;
            }
        }
    }

    /* Discard streams we do not decode so the demuxer drops them early. */
    for (unsigned i = 0; i < d->fmt->nb_streams; i++) {
        if ((int)i != d->vidx && (int)i != d->aidx)
            d->fmt->streams[i]->discard = AVDISCARD_ALL;
    }

    d->pkt = av_packet_alloc();
    if (!d->pkt) goto fail;
    if (!d->info.has_video && !d->info.has_audio) {
        lc_set_err(err, errlen, "no decodable streams");
        goto fail;
    }
    return d;

fail:
    if (err && errlen && !err[0]) lc_set_err(err, errlen, "decoder setup failed");
    lc_decoder_close(d);
    return NULL;
}

void lc_decoder_get_info(const LCDecoder *d, LCMediaInfo *info)
{
    if (d && info) *info = d->info;
}

/* Reads packets until one for `stream` is queued into the decoder. Returns
 * 0 if a packet was sent, 1 if the decoder was switched to draining, <0 error. */
static int feed_decoder(LCDecoder *d, AVCodecContext *dec, int stream, int *draining)
{
    for (;;) {
        int ret = av_read_frame(d->fmt, d->pkt);
        if (ret == AVERROR_EOF) {
            *draining = 1;
            avcodec_send_packet(dec, NULL);
            return 1;
        }
        if (ret < 0) return ret;
        if (d->pkt->stream_index != stream) { av_packet_unref(d->pkt); continue; }
        ret = avcodec_send_packet(dec, d->pkt);
        av_packet_unref(d->pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) return ret;
        return 0;
    }
}

int lc_decoder_next_video(LCDecoder *d, LCVideoFrame *out)
{
    if (!d || !d->vdec || !out) return -1;
    if (d->v_eof) return 0;
    for (;;) {
        int ret = avcodec_receive_frame(d->vdec, d->vframe);
        if (ret == 0) {
            int64_t pts = d->vframe->best_effort_timestamp != AV_NOPTS_VALUE ? d->vframe->best_effort_timestamp : d->vframe->pts;
            int64_t pts_ns = ts_to_ns(pts, d->vtb);
            if (d->seeking) {
                int64_t frame_ns = (int64_t)(1e9 * d->info.fps_den / (double)d->info.fps_num);
                if (pts_ns != AV_NOPTS_VALUE && pts_ns < d->seek_target_ns - frame_ns / 4) {
                    av_frame_unref(d->vframe);
                    continue;
                }
                d->seeking = 0;
            }
            LCPixelFormat lcpf;
            if (lc_from_av_pixfmt((enum AVPixelFormat)d->vframe->format, &lcpf) < 0) {
                av_frame_unref(d->vframe);
                return AVERROR(EINVAL);
            }
            out->planes[0] = d->vframe->data[0];
            out->planes[1] = d->vframe->data[1];
            out->planes[2] = d->vframe->data[2];
            out->strides[0] = (size_t)d->vframe->linesize[0];
            out->strides[1] = (size_t)d->vframe->linesize[1];
            out->strides[2] = (size_t)d->vframe->linesize[2];
            out->width = d->vframe->width;
            out->height = d->vframe->height;
            out->pix_fmt = lcpf;
            out->pts_ns = pts_ns;
            if (d->idx_count > 0 && pts != AV_NOPTS_VALUE) {
                out->index = index_lookup(d, pts);
                d->next_seq = out->index + 1;
            } else {
                out->index = d->next_seq++;
            }
            return 1;
        }
        if (ret == AVERROR_EOF) { d->v_eof = 1; return 0; }
        if (ret != AVERROR(EAGAIN)) return ret;
        if (d->v_draining) { d->v_eof = 1; return 0; }
        ret = feed_decoder(d, d->vdec, d->vidx, &d->v_draining);
        if (ret < 0) return ret;
    }
}

static int do_seek(LCDecoder *d, int stream, int64_t ts)
{
    int ret = av_seek_frame(d->fmt, stream, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) ret = av_seek_frame(d->fmt, stream, ts, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY);
    return ret;
}

int lc_decoder_seek_time(LCDecoder *d, int64_t pts_ns)
{
    if (!d || !d->vdec) return -1;
    if (pts_ns < 0) pts_ns = 0;
    int ret = do_seek(d, d->vidx, ns_to_ts(pts_ns, d->vtb));
    if (ret < 0) return ret;
    avcodec_flush_buffers(d->vdec);
    d->seeking = 1;
    d->seek_target_ns = pts_ns;
    d->v_draining = 0;
    d->v_eof = 0;
    if (d->idx_count == 0) d->next_seq = lc_decoder_frame_index_for_pts(d, pts_ns);
    return 0;
}

int lc_decoder_seek_frame(LCDecoder *d, int64_t frame_index)
{
    if (!d || !d->vdec) return -1;
    if (frame_index < 0) frame_index = 0;
    int64_t target_ns = lc_decoder_frame_pts(d, frame_index);
    int ret = lc_decoder_seek_time(d, target_ns);
    if (ret < 0) return ret;
    if (d->idx_count == 0) d->next_seq = frame_index;
    return 0;
}

int64_t lc_decoder_frame_pts(const LCDecoder *d, int64_t frame_index)
{
    if (!d || !d->vdec) return 0;
    if (d->idx_count > 0) {
        if (frame_index >= d->idx_count) frame_index = d->idx_count - 1;
        if (frame_index < 0) frame_index = 0;
        return ts_to_ns(d->idx_ts[frame_index], d->vtb);
    }
    return (int64_t)llround((double)frame_index * 1e9 * d->info.fps_den / (double)d->info.fps_num);
}

int64_t lc_decoder_frame_index_for_pts(const LCDecoder *d, int64_t pts_ns)
{
    if (!d || !d->vdec) return 0;
    if (d->idx_count > 0) return index_lookup(d, ns_to_ts(pts_ns, d->vtb));
    double fi = (double)pts_ns / 1e9 * d->info.fps_num / (double)d->info.fps_den;
    int64_t idx = (int64_t)llround(fi);
    return idx < 0 ? 0 : idx;
}

/* Convert a decoded audio frame to interleaved int32 top-aligned 24-bit. */
static int convert_audio_frame(const AVFrame *f, int32_t *dst)
{
    const int ch = f->ch_layout.nb_channels;
    const int n = f->nb_samples;
    switch (f->format) {
    case AV_SAMPLE_FMT_S32:
        memcpy(dst, f->data[0], (size_t)n * ch * sizeof(int32_t));
        return 0;
    case AV_SAMPLE_FMT_S32P:
        for (int c = 0; c < ch; c++) {
            const int32_t *s = (const int32_t *)f->data[c];
            for (int i = 0; i < n; i++) dst[(size_t)i * ch + c] = s[i];
        }
        return 0;
    case AV_SAMPLE_FMT_S16: {
        const int16_t *s = (const int16_t *)f->data[0];
        for (size_t i = 0; i < (size_t)n * ch; i++) dst[i] = (int32_t)((uint32_t)(uint16_t)s[i] << 16);
        return 0;
    }
    case AV_SAMPLE_FMT_S16P:
        for (int c = 0; c < ch; c++) {
            const int16_t *s = (const int16_t *)f->data[c];
            for (int i = 0; i < n; i++) dst[(size_t)i * ch + c] = (int32_t)((uint32_t)(uint16_t)s[i] << 16);
        }
        return 0;
    case AV_SAMPLE_FMT_FLT: {
        const float *s = (const float *)f->data[0];
        for (size_t i = 0; i < (size_t)n * ch; i++) {
            double q = rint((double)s[i] * 8388608.0);
            if (q > 8388607.0) q = 8388607.0; if (q < -8388608.0) q = -8388608.0;
            dst[i] = (int32_t)((uint32_t)(int32_t)q << 8);
        }
        return 0;
    }
    case AV_SAMPLE_FMT_FLTP:
        for (int c = 0; c < ch; c++) {
            const float *s = (const float *)f->data[c];
            for (int i = 0; i < n; i++) {
                double q = rint((double)s[i] * 8388608.0);
                if (q > 8388607.0) q = 8388607.0; if (q < -8388608.0) q = -8388608.0;
                dst[(size_t)i * ch + c] = (int32_t)((uint32_t)(int32_t)q << 8);
            }
        }
        return 0;
    default:
        return AVERROR(ENOSYS);
    }
}

int lc_decoder_next_audio(LCDecoder *d, int32_t *out, int max_frames, int64_t *pts_ns)
{
    if (!d || !d->adec || !out || max_frames <= 0) return -1;
    const int ch = d->info.channels;
    int produced = 0;
    int64_t first_pts = AV_NOPTS_VALUE;

    while (produced < max_frames) {
        if (d->a_left_frames > 0) {
            int n = d->a_left_frames < (max_frames - produced) ? d->a_left_frames : (max_frames - produced);
            if (first_pts == AV_NOPTS_VALUE) first_pts = d->a_left_pts_ns;
            memcpy(out + (size_t)produced * ch, d->a_left, (size_t)n * ch * sizeof(int32_t));
            produced += n;
            d->a_left_frames -= n;
            if (d->a_left_frames > 0) {
                memmove(d->a_left, d->a_left + (size_t)n * ch, (size_t)d->a_left_frames * ch * sizeof(int32_t));
                d->a_left_pts_ns += (int64_t)n * LC_NS_PER_SEC / d->info.sample_rate;
            }
            continue;
        }
        if (d->a_eof) break;
        int ret = avcodec_receive_frame(d->adec, d->aframe);
        if (ret == 0) {
            int n = d->aframe->nb_samples;
            if (n * ch > d->a_left_cap) {
                int32_t *nb = (int32_t *)realloc(d->a_left, (size_t)n * ch * sizeof(int32_t));
                if (!nb) { av_frame_unref(d->aframe); return AVERROR(ENOMEM); }
                d->a_left = nb;
                d->a_left_cap = n * ch;
            }
            ret = convert_audio_frame(d->aframe, d->a_left);
            int64_t fpts = d->aframe->pts != AV_NOPTS_VALUE ? ts_to_ns(d->aframe->pts, d->atb) : AV_NOPTS_VALUE;
            av_frame_unref(d->aframe);
            if (ret < 0) return ret;
            d->a_left_frames = n;
            d->a_left_pts_ns = fpts;
            if (d->a_seeking && fpts != AV_NOPTS_VALUE && fpts < d->a_seek_target_ns) {
                /* trim samples before the seek target */
                int64_t skip = (d->a_seek_target_ns - fpts) * d->info.sample_rate / LC_NS_PER_SEC;
                if (skip >= n) { d->a_left_frames = 0; continue; }
                if (skip > 0) {
                    memmove(d->a_left, d->a_left + skip * ch, (size_t)(n - skip) * ch * sizeof(int32_t));
                    d->a_left_frames = n - (int)skip;
                    d->a_left_pts_ns = fpts + skip * LC_NS_PER_SEC / d->info.sample_rate;
                }
            }
            d->a_seeking = 0;
            continue;
        }
        if (ret == AVERROR_EOF) { d->a_eof = 1; break; }
        if (ret != AVERROR(EAGAIN)) return ret;
        if (d->a_draining) { d->a_eof = 1; break; }
        ret = feed_decoder(d, d->adec, d->aidx, &d->a_draining);
        if (ret < 0) return ret;
    }
    if (pts_ns) *pts_ns = first_pts;
    return produced;
}

int lc_decoder_seek_audio(LCDecoder *d, int64_t pts_ns)
{
    if (!d || !d->adec) return -1;
    if (pts_ns < 0) pts_ns = 0;
    int ret = do_seek(d, d->aidx, ns_to_ts(pts_ns, d->atb));
    if (ret < 0) return ret;
    avcodec_flush_buffers(d->adec);
    d->a_left_frames = 0;
    d->a_draining = 0;
    d->a_eof = 0;
    d->a_seeking = 1;
    d->a_seek_target_ns = pts_ns;
    return 0;
}

int lc_decoder_crc_errors(const LCDecoder *d)
{
    return d ? atomic_load(&((LCDecoder *)d)->crc_errors) : 0;
}

void lc_decoder_close(LCDecoder *d)
{
    if (!d) return;
    if (d->vdec) lc_log_unregister_codec_ctx(d->vdec);
    av_frame_free(&d->vframe);
    av_frame_free(&d->aframe);
    av_packet_free(&d->pkt);
    avcodec_free_context(&d->vdec);
    avcodec_free_context(&d->adec);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d->idx_ts);
    free(d->a_left);
    free(d);
}
