/* Bit-exact verification: decode the final MKV, rebuild the canonical
 * AVFoundation layout of every frame, re-hash and compare with the .lchash
 * sidecar written during capture. Audio is verified as a continuous stream
 * with periodic checkpoints so a mismatch can be localised. */
#include "lc_internal.h"
#include <time.h>

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int lc_verify_recording(const char *mkv_path, const char *hashlist_path, int threads,
                        LCProgressFn progress, void *progress_ctx, volatile int *cancel,
                        LCVerifyResult *result, char *err, size_t errlen)
{
    lc_bridge_init();
    if (err && errlen) err[0] = 0;
    LCVerifyResult r;
    memset(&r, 0, sizeof(r));
    r.first_mismatch_frame = -1;
    r.audio_first_mismatch_checkpoint = -1;
    r.audio_first_mismatch_frame = -1;
    r.status = LC_VERIFY_ERROR;
    r.video_status = LC_VERIFY_ERROR;
    r.audio_status = LC_VERIFY_PASS;
    double t0 = now_sec();
    int ret = -1;

    if (lc_job_should_stop(cancel)) {
        r.status = r.video_status = r.audio_status = LC_VERIFY_CANCELLED;
        if (result) *result = r;
        return 0;
    }
    LCHashList *hl = lc_hashlist_load(hashlist_path, err, errlen);
    if (!hl) { if (result) *result = r; return -1; }
    r.frames_expected = hl->video_count;
    r.audio_frames_expected = hl->total_audio_frames;

    /* ---------------- video ---------------- */
    LCDecoder *vd = lc_decoder_open(mkv_path, 1, 0, threads, err, errlen);
    if (!vd) goto done;
    LCMediaInfo info;
    lc_decoder_get_info(vd, &info);
    if (!info.has_video || info.width != hl->header.width || info.height != hl->header.height ||
        info.bit_depth != hl->header.bit_depth) {
        lc_set_err(err, errlen, "geometry mismatch: file %dx%d/%d-bit vs hash list %dx%d/%d-bit",
                   info.width, info.height, info.bit_depth, hl->header.width, hl->header.height, hl->header.bit_depth);
        lc_decoder_close(vd);
        goto done;
    }
    r.crc_checked = 1;
    const int bps = info.bit_depth == 10 ? 2 : 1;
    uint8_t *scratch = (uint8_t *)malloc((size_t)info.width * bps + 64);
    if (!scratch) { lc_decoder_close(vd); goto done; }

    LCVideoFrame f;
    int vstatus = LC_VERIFY_PASS;
    for (;;) {
        if (lc_job_should_stop(cancel)) { vstatus = LC_VERIFY_CANCELLED; break; }
        int got = lc_decoder_next_video(vd, &f);
        if (got < 0) {
            char b[64];
            lc_set_err(err, errlen, "decode error at frame %lld: %s", (long long)r.frames_decoded, lc_averr(got, b, sizeof(b)));
            vstatus = LC_VERIFY_ERROR;
            break;
        }
        if (got == 0) break;
        int64_t i = r.frames_decoded;
        r.frames_decoded++;
        if (!hl->complete && i >= hl->video_count) {
            /* Interrupted recording: hashes past the last flushed record were lost. */
            r.frames_unverified++;
            continue;
        }
        uint64_t h = lc_hash_planar_as_biplanar(f.planes[0], f.strides[0], f.planes[1], f.strides[1],
                                                f.planes[2], f.strides[2], info.width, info.height, bps, scratch);
        if (i < hl->video_count && h == hl->video_hash[i]) {
            r.frames_matched++;
        } else if (r.first_mismatch_frame < 0) {
            r.first_mismatch_frame = i;
        }
        if (progress && (i % 8 == 0)) {
            double frac = hl->video_count > 0 ? (double)(i + 1) / (double)hl->video_count : 0.0;
            if (frac > 0.95) frac = 0.95;
            progress(progress_ctx, frac, "Verifying video");
        }
    }
    r.crc_errors = lc_decoder_crc_errors(vd);
    free(scratch);
    lc_decoder_close(vd);
    if (vstatus == LC_VERIFY_PASS) {
        const int64_t checked = r.frames_decoded - r.frames_unverified;
        /* An interrupted recording (no trailer record) may have hashed frames that never
         * reached the file (lost with the writer's last buffer) or stored frames whose
         * hashes were lost; only the overlap can be checked. */
        const int64_t expected = hl->complete ? hl->video_count : (checked < hl->video_count ? checked : hl->video_count);
        r.frames_expected = expected;
        if (checked != expected || r.frames_matched != expected || r.crc_errors > 0)
            vstatus = LC_VERIFY_FAIL;
        if (checked != expected && r.first_mismatch_frame < 0)
            r.first_mismatch_frame = checked < expected ? checked : expected;
        if (vstatus == LC_VERIFY_PASS && !hl->complete)
            lc_set_err(err, errlen, "interrupted recording: %lld frames verified; %lld stored frames have no capture hash; %lld hashed frames are not in the file",
                       (long long)r.frames_matched, (long long)r.frames_unverified,
                       (long long)(hl->video_count > checked ? hl->video_count - checked : 0));
    }
    r.video_status = vstatus;

    /* ---------------- audio ---------------- */
    if (vstatus != LC_VERIFY_CANCELLED && hl->header.audio_sample_rate > 0 && hl->header.audio_channels > 0 &&
        !hl->audio_final_present && hl->audio_checkpoint_count == 0) {
        /* Audio was captured but no committed-stream hash exists (stage 2 did not finish). */
        r.audio_status = LC_VERIFY_ERROR;
        lc_set_err(err, errlen, "no audio hash recorded for this recording (stage 2 incomplete?)");
    } else if (vstatus != LC_VERIFY_CANCELLED && hl->header.audio_sample_rate > 0 && hl->header.audio_channels > 0) {
        char aerr[256] = {0};
        LCDecoder *ad = lc_decoder_open(mkv_path, 0, 1, 1, aerr, sizeof(aerr));
        if (!ad) {
            r.audio_status = LC_VERIFY_FAIL;
            lc_set_err(err, errlen, "audio stream missing: %s", aerr);
        } else {
            LCMediaInfo ai;
            lc_decoder_get_info(ad, &ai);
            const int ch = ai.channels;
            if (!ai.has_audio || ch != hl->header.audio_channels || ai.sample_rate != hl->header.audio_sample_rate) {
                r.audio_status = LC_VERIFY_FAIL;
                lc_set_err(err, errlen, "audio format mismatch: %d ch @ %d Hz vs %d ch @ %d Hz",
                           ch, ai.sample_rate, hl->header.audio_channels, hl->header.audio_sample_rate);
            } else {
                const int chunk = 4096;
                int32_t *buf = (int32_t *)malloc((size_t)chunk * ch * sizeof(int32_t));
                LCHashState *hs = lc_hash_create();
                int astatus = LC_VERIFY_PASS;
                int64_t pos = 0;      /* sample frames consumed */
                int64_t ck = 0;       /* next checkpoint index */
                if (!buf || !hs) astatus = LC_VERIFY_ERROR;
                while (astatus == LC_VERIFY_PASS) {
                    if (lc_job_should_stop(cancel)) { astatus = LC_VERIFY_CANCELLED; break; }
                    /* Interrupted recording without a final digest: verified up to the last checkpoint. */
                    if (!hl->audio_final_present && ck >= hl->audio_checkpoint_count) break;
                    /* Feed up to the next checkpoint boundary so digests align. */
                    int want = chunk;
                    if (ck < hl->audio_checkpoint_count) {
                        int64_t to_ck = hl->audio_frames[ck] - pos;
                        if (to_ck <= 0) {
                            /* checkpoint reached */
                            uint64_t d = lc_hash_digest(hs);
                            if (d != hl->audio_hash[ck]) {
                                astatus = LC_VERIFY_FAIL;
                                r.audio_first_mismatch_checkpoint = ck;
                                r.audio_first_mismatch_frame = ck > 0 ? hl->audio_frames[ck - 1] : 0;
                                break;
                            }
                            ck++;
                            continue;
                        }
                        if (to_ck < want) want = (int)to_ck;
                    }
                    int64_t pts;
                    int n = lc_decoder_next_audio(ad, buf, want, &pts);
                    if (n < 0) { astatus = LC_VERIFY_ERROR; break; }
                    if (n == 0) break;
                    lc_hash_update(hs, buf, (size_t)n * ch * sizeof(int32_t));
                    pos += n;
                    r.audio_frames_decoded = pos;
                    if (progress && (pos % (48000 * 4) < chunk)) {
                        double frac = hl->total_audio_frames > 0 ? 0.95 + 0.05 * (double)pos / (double)hl->total_audio_frames : 0.97;
                        progress(progress_ctx, frac > 1.0 ? 1.0 : frac, "Verifying audio");
                    }
                }
                if (astatus == LC_VERIFY_PASS) {
                    /* Remaining checkpoints exactly at the end, then the final digest. */
                    while (ck < hl->audio_checkpoint_count && hl->audio_frames[ck] <= pos) {
                        if (hl->audio_frames[ck] == pos && lc_hash_digest(hs) != hl->audio_hash[ck]) {
                            astatus = LC_VERIFY_FAIL;
                            r.audio_first_mismatch_checkpoint = ck;
                            r.audio_first_mismatch_frame = ck > 0 ? hl->audio_frames[ck - 1] : 0;
                        }
                        ck++;
                    }
                    if (astatus == LC_VERIFY_PASS && hl->audio_final_present) {
                        if (pos != hl->total_audio_frames || lc_hash_digest(hs) != hl->final_audio_hash) {
                            astatus = LC_VERIFY_FAIL;
                            if (r.audio_first_mismatch_frame < 0)
                                r.audio_first_mismatch_frame = pos < hl->total_audio_frames ? pos : hl->total_audio_frames;
                        }
                    }
                }
                r.audio_status = astatus;
                free(buf);
                lc_hash_destroy(hs);
            }
            lc_decoder_close(ad);
        }
    }

    if (r.video_status == LC_VERIFY_CANCELLED || r.audio_status == LC_VERIFY_CANCELLED) r.status = LC_VERIFY_CANCELLED;
    else if (r.video_status == LC_VERIFY_ERROR || r.audio_status == LC_VERIFY_ERROR) r.status = LC_VERIFY_ERROR;
    else if (r.video_status == LC_VERIFY_FAIL || r.audio_status == LC_VERIFY_FAIL) r.status = LC_VERIFY_FAIL;
    else r.status = LC_VERIFY_PASS;
    ret = 0;

done:
    r.seconds = now_sec() - t0;
    lc_hashlist_free(hl);
    if (result) *result = r;
    if (progress && ret == 0) progress(progress_ctx, 1.0, "Done");
    return ret;
}
