/*
 * Off-device test for the LosslessBridge pipeline. Exercises, on the host:
 *   1. XXH64 known-answer vectors
 *   2. P010 <-> yuv420p10 repack round trip and canonical hash equality
 *   3. Stage 1 (LZ4 / LZ4-shuffle / RAW / FFV1-fast) -> .lci -> stage 2 -> MKV
 *   4. Real-time path: frames + audio straight into the MKV writer
 *   5. Verification of both MKVs against the capture-time hash list (PASS)
 *   6. Tamper test: corrupt the hash list -> verification must FAIL
 *   7. Decoder seeking by frame index and luma metrics on identical frames
 *
 * Build: scripts/test/run-bridge-tests.sh
 */
#include "LosslessBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); return 1; } } while (0)

/* internal helpers (lc_internal.h) exercised directly */
void lc_shuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps);
void lc_unshuffle_bytes(const uint8_t *src, uint8_t *dst, size_t nsamples, int bps);

static const int W = 640, H = 360, FRAMES = 12, FPS = 60;
static const int SR = 48000, CH = 4;

static void progress(void *ctx, double f, const char *phase) { (void)ctx; (void)f; (void)phase; }

static void gen_audio(int32_t *buf, int nb, int64_t start_frame)
{
    for (int i = 0; i < nb; i++) {
        for (int c = 0; c < CH; c++) {
            double t = (double)(start_frame + i) / SR;
            double v = sin(2 * M_PI * (220.0 + 110.0 * c) * t) * 0.5 + ((start_frame + i) % 7) * 1e-5;
            int32_t q = (int32_t)lrint(v * 8388607.0);
            buf[i * CH + c] = (int32_t)((uint32_t)q << 8);
        }
    }
}

static int run_two_stage(LCStage1Codec codec, const char *dir, const char *tag, int *frames_out)
{
    char lci[512], mkv[512], hashp[512], err[256] = {0};
    snprintf(lci, sizeof(lci), "%s/%s.lci", dir, tag);
    snprintf(mkv, sizeof(mkv), "%s/%s.mkv", dir, tag);
    snprintf(hashp, sizeof(hashp), "%s/%s.lchash", dir, tag);

    LCIntermediateConfig cfg = {
        .width = W, .height = H, .bytes_per_sample = 2, .bit_depth = 10, .full_range = 0,
        .color_primaries = LC_COLOR_PRI_BT2020, .color_trc = LC_COLOR_TRC_ARIB_STD_B67,
        .colorspace = LC_COLOR_SPC_BT2020_NCL, .chroma_location = LC_CHROMA_LOC_LEFT,
        .fps_num = FPS, .fps_den = 1, .codec = codec,
        .audio_sample_rate = SR, .audio_channels = CH, .audio_ambisonic = 1,
    };
    CHECK(lc_stage1_codec_supported(codec, 2), "codec %s unsupported", lc_stage1_codec_name(codec));
    LCStage1Encoder *enc = lc_s1_encoder_create(&cfg, err, sizeof(err));
    CHECK(enc, "encoder create: %s", err);
    size_t xs = 0;
    const uint8_t *xd = lc_s1_encoder_extradata(enc, &xs);
    LCIntermediateWriter *lw = lc_lci_open(lci, &cfg, xd, xs, err, sizeof(err));
    CHECK(lw, "lci open: %s", err);

    LCHashListHeader hh = { .width = W, .height = H, .bit_depth = 10, .full_range = 0, .fps_num = FPS, .fps_den = 1,
                            .audio_sample_rate = SR, .audio_channels = CH, .audio_checkpoint_interval = 4800 };
    LCHashListWriter *hw = lc_hashlist_open(hashp, &hh, err, sizeof(err));
    CHECK(hw, "hashlist open: %s", err);

    const size_t ys = (size_t)W * 2 + 64;   /* padded stride like a CVPixelBuffer */
    uint8_t *y = malloc(ys * H), *c = malloc(ys * (H / 2));
    int32_t *audio = malloc(sizeof(int32_t) * 1024 * CH);
    LCHashState *ah = lc_hash_create();
    int64_t audio_pos = 0;       /* sample frames committed */
    int64_t next_ck = 4800;
    const int64_t origin = 1234567890LL;     /* arbitrary session clock origin */
    const int64_t frame_ns = 1000000000LL / FPS;

    /* audio arrives slightly before the first frame to exercise trimming */
    int64_t audio_t = origin - 200 * 1000000000LL / SR;  /* 200 frames early */
    int64_t audio_src_frame = -200;

    for (int i = 0; i < FRAMES; i++) {
        lc_fill_test_frame(y, ys, c, ys, W, H, 2, (uint32_t)i);
        int64_t pts = origin + i * frame_ns;
        uint64_t h = lc_hash_biplanar(y, ys, c, ys, W, H, 2);
        const uint8_t *out; size_t n;
        int rc = lc_s1_encoder_compress(enc, y, ys, c, ys, &out, &n);
        CHECK(rc >= 0, "compress failed %d", rc);
        CHECK(lc_lci_append_video(lw, i, pts, h, out, n, (size_t)W * H * 3) == 0, "append video");
        CHECK(lc_hashlist_add_video(hw, i, pts, h) == 0, "hashlist add");
        /* ~1 frame worth of audio in 2 buffers */
        for (int k = 0; k < 2; k++) {
            int nb = 400;
            gen_audio(audio, nb, audio_src_frame);
            CHECK(lc_lci_append_audio(lw, audio_t, audio, nb) == 0, "append audio");
            /* reference count of committed samples: only samples at/after origin survive trimming;
             * the audio hash itself is committed by stage 2 (as in the app). */
            for (int s = 0; s < nb; s++) {
                int64_t sf = audio_src_frame + s;
                if (sf < 0) continue;
                lc_hash_update(ah, audio + s * CH, sizeof(int32_t) * CH);
                audio_pos++;
            }
            (void)next_ck;
            audio_src_frame += nb;
            audio_t += (int64_t)nb * 1000000000LL / SR;
        }
    }
    CHECK(lc_lci_close(lw) == 0, "lci close");
    CHECK(lc_hashlist_close(hw, FRAMES, 0, 0, 0) == 0, "hashlist close");   /* audio totals filled by stage 2 */
    uint64_t expected_audio_hash = lc_hash_digest(ah);
    lc_s1_encoder_destroy(enc);
    lc_hash_destroy(ah);
    free(y); free(c); free(audio);

    LCFfv1Params p = { .level = 3, .coder = 1, .context = 1, .slices = 24, .slicecrc = 1, .threads = 0, .gop = 1 };
    LCTranscodeStats st;
    volatile int cancel = 0;
    const char *meta[] = { "LOSSLESSCAM_TEST", "1", NULL };
    int rc = lc_transcode_intermediate(lci, mkv, &p, 5, meta, hashp, 4800, progress, NULL, &cancel, &st, err, sizeof(err));
    CHECK(rc == 0, "transcode (%s): %s", tag, err);
    CHECK(st.frames_out == FRAMES, "frames_out=%lld", (long long)st.frames_out);
    CHECK(st.intermediate_hash_mismatches == 0, "intermediate hash mismatches %lld", (long long)st.intermediate_hash_mismatches);
    CHECK(st.audio_trimmed_frames == 200, "trimmed=%lld", (long long)st.audio_trimmed_frames);
    CHECK(st.audio_frames_out == audio_pos, "audio out %lld vs %lld", (long long)st.audio_frames_out, (long long)audio_pos);
    CHECK(st.low_bits_seen == 0, "low bits %u", st.low_bits_seen);
    CHECK(st.audio_hash == expected_audio_hash, "stage-2 audio hash differs from the capture-side reference");
    printf("  [%s] stage1 %s -> MKV %llu bytes (raw %zu), audio %lld frames, %d discontinuities\n",
           tag, lc_stage1_codec_name(codec), (unsigned long long)st.bytes_out, (size_t)W * H * 3 * FRAMES,
           (long long)st.audio_frames_out, st.audio_discontinuities);

    LCVerifyResult vr;
    rc = lc_verify_recording(mkv, hashp, 0, progress, NULL, &cancel, &vr, err, sizeof(err));
    CHECK(rc == 0, "verify run failed: %s", err);
    CHECK(vr.video_status == LC_VERIFY_PASS, "video verify status %d first mismatch %lld (decoded %lld matched %lld)",
          vr.video_status, (long long)vr.first_mismatch_frame, (long long)vr.frames_decoded, (long long)vr.frames_matched);
    CHECK(vr.audio_status == LC_VERIFY_PASS, "audio verify status %d (ck %lld, frame %lld, decoded %lld expected %lld): %s",
          vr.audio_status, (long long)vr.audio_first_mismatch_checkpoint, (long long)vr.audio_first_mismatch_frame,
          (long long)vr.audio_frames_decoded, (long long)vr.audio_frames_expected, err);
    CHECK(vr.status == LC_VERIFY_PASS, "overall %d", vr.status);
    CHECK(vr.crc_errors == 0, "crc errors %d", vr.crc_errors);
    printf("  [%s] verify PASS: %lld frames, %lld audio frames, %.2fs\n", tag, (long long)vr.frames_matched,
           (long long)vr.audio_frames_decoded, vr.seconds);
    *frames_out = (int)vr.frames_matched;

    /* Tamper: flip a bit in a stored hash -> must fail at that frame. */
    {
        FILE *f = fopen(hashp, "r+b");
        CHECK(f, "reopen hashlist");
        long off = 8 + 36 + 5 * 32 + 24;   /* record 5, hash field */
        fseek(f, off, SEEK_SET);
        uint64_t hv; fread(&hv, 8, 1, f); hv ^= 1; fseek(f, off, SEEK_SET); fwrite(&hv, 8, 1, f); fclose(f);
        rc = lc_verify_recording(mkv, hashp, 0, progress, NULL, &cancel, &vr, err, sizeof(err));
        CHECK(rc == 0 && vr.video_status == LC_VERIFY_FAIL && vr.first_mismatch_frame == 5,
              "tamper not detected: status %d first %lld", vr.video_status, (long long)vr.first_mismatch_frame);
        printf("  [%s] tamper detected at frame %lld as expected\n", tag, (long long)vr.first_mismatch_frame);
    }
    return 0;
}

static int run_realtime(const char *dir)
{
    char mkv[512], hashp[512], err[256] = {0};
    snprintf(mkv, sizeof(mkv), "%s/realtime.mkv", dir);
    snprintf(hashp, sizeof(hashp), "%s/realtime.lchash", dir);
    LCMkvConfig mc = {
        .width = W, .height = H, .pix_fmt = LC_PIX_YUV420P10, .full_range = 0,
        .color_primaries = LC_COLOR_PRI_BT2020, .color_trc = LC_COLOR_TRC_ARIB_STD_B67,
        .colorspace = LC_COLOR_SPC_BT2020_NCL, .chroma_location = LC_CHROMA_LOC_LEFT,
        .fps_num = FPS, .fps_den = 1,
        .ffv1 = { .level = 3, .coder = 1, .context = 1, .slices = 24, .slicecrc = 1, .threads = 0, .gop = 1 },
        .audio_enabled = 1, .audio_sample_rate = SR, .audio_channels = 2, .audio_ambisonic = 0,
        .flac_compression_level = 5, .metadata = NULL,
    };
    LCMkvWriter *w = lc_mkv_open(mkv, &mc, err, sizeof(err));
    CHECK(w, "mkv open: %s", err);
    LCHashListHeader hh = { .width = W, .height = H, .bit_depth = 10, .fps_num = FPS, .fps_den = 1,
                            .audio_sample_rate = SR, .audio_channels = 2, .audio_checkpoint_interval = 4800 };
    LCHashListWriter *hw = lc_hashlist_open(hashp, &hh, err, sizeof(err));
    CHECK(hw, "hashlist: %s", err);
    const size_t ys = (size_t)W * 2;
    uint8_t *y = malloc(ys * H), *c = malloc(ys * (H / 2));
    int32_t *audio = malloc(sizeof(int32_t) * 2048 * 2);
    const int64_t frame_ns = 1000000000LL / FPS;
    int64_t audio_t = 0, audio_frames = 0;
    for (int i = 0; i < FRAMES; i++) {
        lc_fill_test_frame(y, ys, c, ys, W, H, 2, 100u + (uint32_t)i);
        int64_t pts = (int64_t)i * frame_ns;
        uint64_t h = lc_hash_biplanar(y, ys, c, ys, W, H, 2);
        CHECK(lc_mkv_write_video_biplanar(w, y, ys, c, ys, pts) == 0, "write video: %s", lc_mkv_last_error(w));
        lc_hashlist_add_video(hw, i, pts, h);
        int nb = 800;
        for (int s = 0; s < nb; s++) { audio[2 * s] = (int32_t)((uint32_t)(int32_t)((s * 977) % 8388607) << 8); audio[2 * s + 1] = -audio[2 * s]; }
        CHECK(lc_mkv_write_audio(w, audio, nb, audio_t) == 0, "write audio: %s", lc_mkv_last_error(w));
        audio_t += (int64_t)nb * 1000000000LL / SR;
        audio_frames += nb;
        if (audio_frames % 4800 == 0)
            lc_hashlist_add_audio_checkpoint(hw, audio_frames, audio_t, lc_mkv_audio_running_hash(w));
    }
    uint64_t final_hash = lc_mkv_audio_running_hash(w);
    CHECK(lc_mkv_audio_frames_written(w) == audio_frames, "audio count");
    CHECK(lc_mkv_close(w) == 0, "mkv close");
    CHECK(lc_hashlist_close(hw, FRAMES, 0, audio_frames, final_hash) == 0, "hashlist close");
    free(y); free(c); free(audio);

    LCVerifyResult vr; volatile int cancel = 0;
    int rc = lc_verify_recording(mkv, hashp, 0, progress, NULL, &cancel, &vr, err, sizeof(err));
    CHECK(rc == 0 && vr.status == LC_VERIFY_PASS, "realtime verify failed: status %d video %d audio %d (%s) first %lld",
          vr.status, vr.video_status, vr.audio_status, err, (long long)vr.first_mismatch_frame);
    printf("  [realtime] verify PASS (%lld frames, %lld audio frames)\n", (long long)vr.frames_matched, (long long)vr.audio_frames_decoded);

    /* Decoder: info, seek, metrics. */
    LCDecoder *d = lc_decoder_open(mkv, 1, 0, 2, err, sizeof(err));
    CHECK(d, "decoder open: %s", err);
    LCMediaInfo info; lc_decoder_get_info(d, &info);
    CHECK(info.width == W && info.height == H && info.bit_depth == 10, "info");
    CHECK(info.frame_count == FRAMES && info.frame_count_exact, "frame count %lld exact %d", (long long)info.frame_count, info.frame_count_exact);
    CHECK(info.color_trc == LC_COLOR_TRC_ARIB_STD_B67 && info.color_primaries == LC_COLOR_PRI_BT2020 && info.colorspace == LC_COLOR_SPC_BT2020_NCL,
          "colour metadata not preserved: pri %d trc %d spc %d", info.color_primaries, info.color_trc, info.colorspace);
    CHECK(info.ffv1_version == 3, "ffv1 version %d", info.ffv1_version);
    printf("  [decoder] %s %dx%d %d-bit %d/%d fps, %lld frames, codec %s, container %s, ffv1 v%d\n", info.video_codec,
           info.width, info.height, info.bit_depth, info.fps_num, info.fps_den, (long long)info.frame_count,
           info.video_codec, info.container, info.ffv1_version);
    LCVideoFrame f;
    CHECK(lc_decoder_seek_frame(d, 7) == 0, "seek");
    CHECK(lc_decoder_next_video(d, &f) == 1, "frame after seek");
    CHECK(f.index == 7, "seek landed on %lld", (long long)f.index);
    /* Frame 7 must equal regenerated frame 7 (compare via metrics = identical). */
    uint8_t *ry = malloc(ys * H), *rc2 = malloc(ys * (H / 2));
    lc_fill_test_frame(ry, ys, rc2, ys, W, H, 2, 107u);
    uint8_t *py = malloc(ys * H), *pc = malloc(ys * (H / 2));
    lc_repack_yuv420p10_to_p010(f.planes[0], f.strides[0], f.planes[1], f.strides[1], f.planes[2], f.strides[2], W, H, py, ys, pc, ys);
    CHECK(memcmp(py, ry, ys * H) == 0 && memcmp(pc, rc2, ys * (H / 2)) == 0, "seeked frame content mismatch");
    LCLumaMetrics m;
    CHECK(lc_luma_metrics(py, ys, ry, ys, W, H, 2, 6, 1023, &m) == 0, "metrics");
    CHECK(isinf(m.psnr) && fabs(m.ssim - 1.0) < 1e-9, "identical frames metrics psnr %f ssim %f", m.psnr, m.ssim);
    lc_fill_test_frame(ry, ys, rc2, ys, W, H, 2, 108u);
    CHECK(lc_luma_metrics(py, ys, ry, ys, W, H, 2, 6, 1023, &m) == 0, "metrics2");
    printf("  [metrics] frame7 vs frame8: PSNR %.2f dB SSIM %.4f\n", m.psnr, m.ssim);
    CHECK(m.psnr > 20 && m.psnr < 80 && m.ssim < 1.0, "metrics implausible");
    /* step back then forward across the whole file */
    CHECK(lc_decoder_seek_frame(d, 0) == 0, "seek 0");
    int n = 0; while (lc_decoder_next_video(d, &f) == 1) { CHECK(f.index == n, "index %lld != %d", (long long)f.index, n); n++; }
    CHECK(n == FRAMES, "sequential count %d", n);
    /* thumbnail */
    uint8_t *rgba = malloc(64 * 36 * 4);
    CHECK(lc_decoder_seek_frame(d, 3) == 0 && lc_decoder_next_video(d, &f) == 1, "seek 3");
    CHECK(lc_frame_to_rgba8(&f, 0, info.colorspace, rgba, 64, 36, 64 * 4) == 0, "thumb");
    free(rgba); free(ry); free(rc2); free(py); free(pc);
    lc_decoder_close(d);

    /* Audio decoder: seek + read. */
    LCDecoder *ad = lc_decoder_open(mkv, 0, 1, 1, err, sizeof(err));
    CHECK(ad, "audio decoder: %s", err);
    lc_decoder_get_info(ad, &info);
    CHECK(info.has_audio && info.channels == 2 && info.sample_rate == SR && info.bits_per_sample == 24, "audio info ch %d sr %d bps %d", info.channels, info.sample_rate, info.bits_per_sample);
    int32_t abuf[1024 * 2]; int64_t apts;
    CHECK(lc_decoder_seek_audio(ad, 100000000LL) == 0, "audio seek");
    int got = lc_decoder_next_audio(ad, abuf, 1024, &apts);
    CHECK(got > 0, "audio read %d", got);
    printf("  [audio] codec %s, read %d frames after seek, pts %.3f ms\n", info.audio_codec, got, apts / 1e6);
    lc_decoder_close(ad);
    return 0;
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    lc_bridge_init();
    printf("LosslessBridge test — FFmpeg %s (%s)\n", lc_ffmpeg_version_string(), lc_ffmpeg_license());

    /* 1. xxHash KATs (seed 0) */
    CHECK(lc_hash_bytes("", 0) == 0xEF46DB3751D8E999ULL, "xxh64 empty");
    CHECK(lc_hash_bytes("a", 1) == 0xD24EC4F1A98C6E5BULL, "xxh64 'a'");
    CHECK(lc_hash_bytes("abc", 3) == 0x44BC2CF5AD770999ULL, "xxh64 'abc'");
    {
        LCHashState *s = lc_hash_create();
        lc_hash_update(s, "ab", 2); lc_hash_update(s, "c", 1);
        CHECK(lc_hash_digest(s) == 0x44BC2CF5AD770999ULL, "streaming xxh64");
        lc_hash_destroy(s);
    }
    printf("  [hash] XXH64 known answers OK\n");

    /* 2. repack round trip */
    {
        size_t ys = (size_t)W * 2 + 128;
        uint8_t *y = malloc(ys * H), *c = malloc(ys * (H / 2));
        lc_fill_test_frame(y, ys, c, ys, W, H, 2, 7);
        uint16_t *py = malloc(W * H * 2), *pu = malloc(W * H / 2), *pv = malloc(W * H / 2);
        uint16_t low = lc_repack_p010_to_yuv420p10(y, ys, c, ys, W, H, (uint8_t *)py, W * 2, (uint8_t *)pu, W, (uint8_t *)pv, W);
        CHECK(low == 0, "low bits %u", low);
        uint8_t *ry = malloc(ys * H), *rc = malloc(ys * (H / 2));
        lc_repack_yuv420p10_to_p010((uint8_t *)py, W * 2, (uint8_t *)pu, W, (uint8_t *)pv, W, W, H, ry, ys, rc, ys);
        for (int r = 0; r < H; r++) CHECK(memcmp(ry + r * ys, y + r * ys, W * 2) == 0, "Y row %d", r);
        for (int r = 0; r < H / 2; r++) CHECK(memcmp(rc + r * ys, c + r * ys, W * 2) == 0, "C row %d", r);
        uint64_t h1 = lc_hash_biplanar(y, ys, c, ys, W, H, 2);
        uint8_t scratch[W * 2 + 64];
        uint64_t h2 = lc_hash_planar_as_biplanar((uint8_t *)py, W * 2, (uint8_t *)pu, W, (uint8_t *)pv, W, W, H, 2, scratch);
        CHECK(h1 == h2, "planar-as-biplanar hash differs");
        /* shuffle round trip */
        size_t packed = (size_t)W * H * 3;
        uint8_t *pk = malloc(packed), *sh = malloc(packed), *un = malloc(packed);
        lc_pack_biplanar(y, ys, c, ys, W, H, 2, pk);
        lc_shuffle_bytes(pk, sh, packed / 2, 2);
        lc_unshuffle_bytes(sh, un, packed / 2, 2);
        CHECK(memcmp(pk, un, packed) == 0, "shuffle round trip");
        /* audio conversion exactness */
        float fl[4] = { 0.5f, -0.25f, 0.3f, 1.0f / 8388608.0f };
        int16_t s16[2] = { 1234, -5678 };
        int32_t out[4];
        const void *src[1] = { fl };
        int64_t inexact = lc_audio_convert_to_s32_24(src, 0, LC_AUDIO_SRC_FLOAT32, 1, 4, out);
        CHECK(inexact == 1, "float inexact count %lld", (long long)inexact);   /* 0.3 is not representable */
        CHECK(out[0] == (int32_t)(4194304u << 8), "0.5 -> %d", out[0]);
        src[0] = s16;
        CHECK(lc_audio_convert_to_s32_24(src, 0, LC_AUDIO_SRC_INT16, 1, 2, out) == 0 && out[0] == 1234 << 16 && out[1] == -5678 * 65536, "s16 convert");
        free(y); free(c); free(py); free(pu); free(pv); free(ry); free(rc); free(pk); free(sh); free(un);
        printf("  [repack] P010<->planar round trip, shuffle, audio conversion OK\n");
    }

    /* 3./5./6. two-stage pipelines */
    int frames;
    CHECK(run_two_stage(LC_S1_LZ4, dir, "lz4", &frames) == 0, "lz4 pipeline");
    CHECK(run_two_stage(LC_S1_LZ4_SHUFFLE, dir, "lz4shuffle", &frames) == 0, "lz4 shuffle pipeline");
    CHECK(run_two_stage(LC_S1_RAW, dir, "raw", &frames) == 0, "raw pipeline");
    CHECK(run_two_stage(LC_S1_FFV1_FAST, dir, "ffv1fast", &frames) == 0, "ffv1 fast pipeline");
    printf("  [stage1] utvideo 10-bit supported: %d (expected 0: FFmpeg's encoder is 8-bit only)\n",
           lc_stage1_codec_supported(LC_S1_UTVIDEO, 2));
    CHECK(lc_stage1_codec_supported(LC_S1_UTVIDEO, 1) == 1, "utvideo 8-bit should be available");

    /* 4./7. real-time path + decoder */
    CHECK(run_realtime(dir) == 0, "realtime");

    printf("ALL BRIDGE TESTS PASSED\n");
    return 0;
}
