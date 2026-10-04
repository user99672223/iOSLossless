/* Stage 2: intermediate (.lci) -> final FFV1 + FLAC Matroska. */
#include "lc_internal.h"

static int cmp_video(const void *pa, const void *pb)
{
    const LCIEntry *a = (const LCIEntry *)pa, *b = (const LCIEntry *)pb;
    if (a->hdr.index < b->hdr.index) return -1;
    if (a->hdr.index > b->hdr.index) return 1;
    return 0;
}

static int cmp_pts(const void *pa, const void *pb)
{
    const LCIEntry *a = (const LCIEntry *)pa, *b = (const LCIEntry *)pb;
    if (a->hdr.pts_ns < b->hdr.pts_ns) return -1;
    if (a->hdr.pts_ns > b->hdr.pts_ns) return 1;
    if (a->hdr.index < b->hdr.index) return -1;
    if (a->hdr.index > b->hdr.index) return 1;
    return 0;
}

int lc_transcode_intermediate(const char *lci_path, const char *mkv_path,
                              const LCFfv1Params *ffv1, int flac_compression_level,
                              const char *const *metadata,
                              const char *hashlist_path, int audio_checkpoint_interval,
                              LCProgressFn progress, void *progress_ctx,
                              volatile int *cancel,
                              LCTranscodeStats *stats, char *err, size_t errlen)
{
    lc_bridge_init();
    if (err && errlen) err[0] = 0;
    LCTranscodeStats st;
    memset(&st, 0, sizeof(st));
    int ret = 0;
    char b[64];

    LCIReader *r = lci_reader_open(lci_path, err, errlen);
    if (!r) return -1;
    st.recovered_without_trailer = r->recovered;
    const LCIntermediateConfig *c = &r->cfg;
    const int bps = c->bytes_per_sample;

    /* Split and order entries. */
    size_t nv = 0, na = 0;
    for (size_t i = 0; i < r->count; i++) {
        if (r->entries[i].hdr.type == 'V') nv++;
        else if (r->entries[i].hdr.type == 'A') na++;
    }
    LCIEntry *vids = (LCIEntry *)malloc((nv + 1) * sizeof(LCIEntry));
    LCIEntry *auds = (LCIEntry *)malloc((na + 1) * sizeof(LCIEntry));
    if (!vids || !auds) { ret = AVERROR(ENOMEM); lc_set_err(err, errlen, "out of memory"); goto done_lists; }
    nv = na = 0;
    for (size_t i = 0; i < r->count; i++) {
        if (r->entries[i].hdr.type == 'V') vids[nv++] = r->entries[i];
        else if (r->entries[i].hdr.type == 'A') auds[na++] = r->entries[i];
    }
    qsort(vids, nv, sizeof(LCIEntry), cmp_video);
    qsort(auds, na, sizeof(LCIEntry), cmp_pts);
    if (nv == 0) { ret = -1; lc_set_err(err, errlen, "intermediate file contains no video frames"); goto done_lists; }

    /* Writer configuration from the intermediate header. */
    LCMkvConfig mc;
    memset(&mc, 0, sizeof(mc));
    mc.width = c->width; mc.height = c->height;
    mc.pix_fmt = bps == 2 ? LC_PIX_YUV420P10 : LC_PIX_YUV420P8;
    mc.full_range = c->full_range;
    mc.color_primaries = c->color_primaries; mc.color_trc = c->color_trc;
    mc.colorspace = c->colorspace; mc.chroma_location = c->chroma_location;
    mc.fps_num = c->fps_num; mc.fps_den = c->fps_den;
    mc.ffv1 = *ffv1;
    mc.audio_enabled = c->audio_sample_rate > 0 && c->audio_channels > 0;
    mc.audio_sample_rate = c->audio_sample_rate;
    mc.audio_channels = c->audio_channels;
    mc.audio_ambisonic = c->audio_ambisonic;
    mc.flac_compression_level = flac_compression_level;
    mc.metadata = metadata;

    LCMkvWriter *w = lc_mkv_open(mkv_path, &mc, err, errlen);
    if (!w) { ret = -1; goto done_lists; }
    /* The recording starts at the first video frame; audio before it is pre-roll. */
    lc_mkv_set_origin(w, vids[0].hdr.pts_ns);

    LCHashListWriter *hlw = NULL;
    int64_t ck_interval = audio_checkpoint_interval > 0 ? audio_checkpoint_interval : 48000;
    int64_t next_ck = ck_interval;
    if (hashlist_path && mc.audio_enabled) {
        char herr[128] = {0};
        hlw = lc_hashlist_open_append(hashlist_path, herr, sizeof(herr));
        if (!hlw) { ret = -1; lc_set_err(err, errlen, "hash list: %s", herr); lc_mkv_abort(w); w = NULL; goto done_lists; }
    }

    /* Decoder / decompressor for the stage-1 payloads. */
    AVCodecContext *dec = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL;
    uint8_t *payload = NULL, *packed = NULL, *unshuf = NULL, *scratch = NULL;
    size_t payload_cap = 0;
    const size_t packed_size = (size_t)c->width * c->height * bps * 3 / 2;
    uint8_t *hash_scratch = (uint8_t *)malloc((size_t)c->width * bps + 64);
    if (!hash_scratch) { ret = AVERROR(ENOMEM); goto done; }

    if (c->codec == LC_S1_FFV1_FAST || c->codec == LC_S1_UTVIDEO) {
        const AVCodec *codec = avcodec_find_decoder(c->codec == LC_S1_UTVIDEO ? AV_CODEC_ID_UTVIDEO : AV_CODEC_ID_FFV1);
        if (!codec) { ret = -1; lc_set_err(err, errlen, "stage-1 decoder unavailable"); goto done; }
        dec = avcodec_alloc_context3(codec);
        pkt = av_packet_alloc();
        frame = av_frame_alloc();
        if (!dec || !pkt || !frame) { ret = AVERROR(ENOMEM); goto done; }
        dec->width = c->width;
        dec->height = c->height;
        dec->pix_fmt = lc_to_av_pixfmt(mc.pix_fmt);
        dec->thread_count = lc_cpu_count();
        dec->thread_type = FF_THREAD_SLICE;
        if (r->extradata_size) {
            dec->extradata = (uint8_t *)av_mallocz(r->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!dec->extradata) { ret = AVERROR(ENOMEM); goto done; }
            memcpy(dec->extradata, r->extradata, r->extradata_size);
            dec->extradata_size = (int)r->extradata_size;
        }
        ret = avcodec_open2(dec, codec, NULL);
        if (ret < 0) { lc_set_err(err, errlen, "stage-1 decoder open: %s", lc_averr(ret, b, sizeof(b))); goto done; }
    } else {
        packed = (uint8_t *)malloc(packed_size);
        scratch = (uint8_t *)malloc(lc_lz4_scratch_size());
        if (!packed || !scratch) { ret = AVERROR(ENOMEM); goto done; }
        if (c->codec == LC_S1_LZ4_SHUFFLE) {
            unshuf = (uint8_t *)malloc(packed_size);
            if (!unshuf) { ret = AVERROR(ENOMEM); goto done; }
        }
    }

    const size_t total = nv + na;
    size_t done_items = 0;
    size_t ai = 0;
    const size_t row = (size_t)c->width * bps;
    const size_t ysize = row * (size_t)c->height;

    for (size_t vi = 0; vi < nv; vi++) {
        if (cancel && *cancel) { ret = AVERROR_EXIT; lc_set_err(err, errlen, "cancelled"); goto done; }
        const LCIEntry *e = &vids[vi];

        /* Audio chunks that precede this frame go first. */
        while (ai < na && auds[ai].hdr.pts_ns <= e->hdr.pts_ns) {
            const LCIEntry *ae = &auds[ai];
            if (ae->hdr.size > payload_cap) {
                uint8_t *np = (uint8_t *)realloc(payload, (size_t)ae->hdr.size + AV_INPUT_BUFFER_PADDING_SIZE);
                if (!np) { ret = AVERROR(ENOMEM); goto done; }
                payload = np; payload_cap = (size_t)ae->hdr.size;
            }
            if (lci_reader_read_payload(r, ae, payload) < 0) { ret = -1; lc_set_err(err, errlen, "read error in intermediate"); goto done; }
            int nb = (int)ae->hdr.aux;
            st.audio_frames_in += nb;
            ret = lc_mkv_write_audio(w, (const int32_t *)payload, nb, ae->hdr.pts_ns);
            if (ret < 0) { lc_set_err(err, errlen, "audio write: %s", lc_mkv_last_error(w)); goto done; }
            if (hlw) {
                int64_t committed = lc_mkv_audio_frames_written(w);
                while (committed >= next_ck) {
                    lc_hashlist_add_audio_checkpoint(hlw, committed, ae->hdr.pts_ns, lc_mkv_audio_running_hash(w));
                    next_ck = committed + ck_interval;
                }
            }
            ai++;
            done_items++;
        }

        if (e->hdr.size > payload_cap) {
            uint8_t *np = (uint8_t *)realloc(payload, (size_t)e->hdr.size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!np) { ret = AVERROR(ENOMEM); goto done; }
            payload = np; payload_cap = (size_t)e->hdr.size;
        }
        if (lci_reader_read_payload(r, e, payload) < 0) { ret = -1; lc_set_err(err, errlen, "read error in intermediate"); goto done; }
        memset(payload + e->hdr.size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        st.frames_in++;

        if (dec) {
            pkt->data = payload;
            pkt->size = (int)e->hdr.size;
            pkt->pts = e->hdr.index;
            pkt->flags |= AV_PKT_FLAG_KEY;
            ret = avcodec_send_packet(dec, pkt);
            if (ret < 0) { lc_set_err(err, errlen, "stage-1 decode: %s", lc_averr(ret, b, sizeof(b))); goto done; }
            ret = avcodec_receive_frame(dec, frame);
            if (ret < 0) { lc_set_err(err, errlen, "stage-1 decode (no frame): %s", lc_averr(ret, b, sizeof(b))); goto done; }
            uint64_t h = lc_hash_planar_as_biplanar(frame->data[0], (size_t)frame->linesize[0],
                                                    frame->data[1], (size_t)frame->linesize[1],
                                                    frame->data[2], (size_t)frame->linesize[2],
                                                    c->width, c->height, bps, hash_scratch);
            if (h != e->hdr.aux) st.intermediate_hash_mismatches++;
            ret = lc_mkv_write_video_planar(w, frame->data[0], (size_t)frame->linesize[0],
                                            frame->data[1], (size_t)frame->linesize[1],
                                            frame->data[2], (size_t)frame->linesize[2], e->hdr.pts_ns);
            av_frame_unref(frame);
            if (ret < 0) { lc_set_err(err, errlen, "video write: %s", lc_mkv_last_error(w)); goto done; }
        } else {
            const uint8_t *src;
            if (e->hdr.flags & LCI_FLAG_STORED || c->codec == LC_S1_RAW) {
                if (e->hdr.size != packed_size) { ret = -1; lc_set_err(err, errlen, "stored frame has wrong size"); goto done; }
                src = payload;
            } else {
                size_t n = lc_lz4_decompress(payload, (size_t)e->hdr.size, packed, packed_size, scratch);
                if (n != packed_size) { ret = -1; lc_set_err(err, errlen, "LZ4 decode failed on frame %lld", (long long)e->hdr.index); goto done; }
                src = packed;
            }
            if (c->codec == LC_S1_LZ4_SHUFFLE && bps == 2) {
                lc_unshuffle_bytes(src, unshuf, packed_size / 2, 2);
                src = unshuf;
            }
            uint64_t h = lc_hash_biplanar(src, row, src + ysize, row, c->width, c->height, bps);
            if (h != e->hdr.aux) st.intermediate_hash_mismatches++;
            ret = lc_mkv_write_video_biplanar(w, src, row, src + ysize, row, e->hdr.pts_ns);
            if (ret < 0) { lc_set_err(err, errlen, "video write: %s", lc_mkv_last_error(w)); goto done; }
        }
        st.frames_out++;
        done_items++;
        if (progress && (vi % 4 == 0 || vi + 1 == nv))
            progress(progress_ctx, (double)done_items / (double)(total ? total : 1), "Encoding FFV1");
    }
    /* Trailing audio. */
    while (ai < na) {
        if (cancel && *cancel) { ret = AVERROR_EXIT; lc_set_err(err, errlen, "cancelled"); goto done; }
        const LCIEntry *ae = &auds[ai];
        if (ae->hdr.size > payload_cap) {
            uint8_t *np = (uint8_t *)realloc(payload, (size_t)ae->hdr.size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!np) { ret = AVERROR(ENOMEM); goto done; }
            payload = np; payload_cap = (size_t)ae->hdr.size;
        }
        if (lci_reader_read_payload(r, ae, payload) < 0) { ret = -1; lc_set_err(err, errlen, "read error in intermediate"); goto done; }
        int nb = (int)ae->hdr.aux;
        st.audio_frames_in += nb;
        ret = lc_mkv_write_audio(w, (const int32_t *)payload, nb, ae->hdr.pts_ns);
        if (ret < 0) { lc_set_err(err, errlen, "audio write: %s", lc_mkv_last_error(w)); goto done; }
        if (hlw) {
            int64_t committed = lc_mkv_audio_frames_written(w);
            while (committed >= next_ck) {
                lc_hashlist_add_audio_checkpoint(hlw, committed, ae->hdr.pts_ns, lc_mkv_audio_running_hash(w));
                next_ck = committed + ck_interval;
            }
        }
        ai++;
        done_items++;
    }
    if (progress) progress(progress_ctx, 0.999, "Finalising");
    ret = 0;

done:
    st.audio_frames_out = lc_mkv_audio_frames_written(w);
    st.audio_trimmed_frames = lc_mkv_audio_trimmed_frames(w);
    st.audio_silence_frames_inserted = lc_mkv_audio_silence_frames_inserted(w);
    st.audio_discontinuities = lc_mkv_audio_discontinuities(w);
    st.audio_hash = lc_mkv_audio_running_hash(w);
    st.low_bits_seen = lc_mkv_low_bits_seen(w);
    if (hlw) {
        if (ret == 0) lc_hashlist_close_audio(hlw, st.audio_frames_out, st.audio_hash);
        else lc_hashlist_abort(hlw);
        hlw = NULL;
    }
    if (ret == 0) {
        int cr = lc_mkv_close(w);
        if (cr < 0) { ret = cr; lc_set_err(err, errlen, "finalising MKV failed: %s", lc_averr(cr, b, sizeof(b))); }
        else {
            FILE *f = fopen(mkv_path, "rb");
            if (f) { fseeko(f, 0, SEEK_END); st.bytes_out = (uint64_t)ftello(f); fclose(f); }
        }
    } else {
        lc_mkv_abort(w);
    }
    if (dec) avcodec_free_context(&dec);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    free(payload); free(packed); free(unshuf); free(scratch); free(hash_scratch);
done_lists:
    free(vids); free(auds);
    lci_reader_close(r);
    if (stats) *stats = st;
    if (progress && ret == 0) progress(progress_ctx, 1.0, "Done");
    return ret;
}
