/*
 * LosslessBridge — C bridge between the Swift app and FFmpeg (libavcodec /
 * libavformat / libavutil), plus the lossless helpers that have no business
 * being in Swift: XXH64 hashing of pixel planes, bit-exact P010 <-> planar
 * repacking, the stage-1 intermediate container, the stage-2 transcoder,
 * verification and luma metrics.
 *
 * Everything here is plain C so it can be imported through a Swift bridging
 * header. No FFmpeg types leak into this header; FFmpeg enum values that
 * matter (colour metadata) are mirrored as LC_* constants and checked with
 * static assertions in the implementation.
 *
 * Thread-safety: unless stated otherwise an object may be used from one
 * thread at a time. The hash helpers and repack functions are pure and
 * reentrant. lc_lci_append_* are serialised internally so worker threads
 * may call them concurrently.
 */
#ifndef LOSSLESS_BRIDGE_H
#define LOSSLESS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Library info / logging                                                    */
/* ------------------------------------------------------------------------ */

/** Installs the FFmpeg log hook. Safe to call multiple times. */
void lc_bridge_init(void);

/** libavcodec version string, e.g. "61.19.101". */
const char *lc_ffmpeg_version_string(void);
/** FFmpeg configure line the libraries were built with. */
const char *lc_ffmpeg_configuration(void);
/** FFmpeg license string ("LGPL version 2.1 or later"). */
const char *lc_ffmpeg_license(void);

/** 1 if an encoder with this libavcodec name exists in the build. */
int lc_encoder_available(const char *name);
/** 1 if the named encoder lists the given bridge pixel format as supported. */
int lc_encoder_supports_pix_fmt(const char *name, int lc_pix_fmt);

typedef void (*LCLogFn)(void *ctx, int level, const char *message);
/** Forward FFmpeg log lines (level: 16=error, 24=warning, 32=info) to Swift. */
void lc_set_log_callback(LCLogFn fn, void *ctx);
/** Total "CRC mismatch" messages seen since init (all decoders). */
int64_t lc_total_crc_errors(void);

/* ------------------------------------------------------------------------ */
/* Pixel formats and colour constants                                        */
/* ------------------------------------------------------------------------ */

typedef enum {
    LC_PIX_YUV420P8  = 0,   /* planar 4:2:0 8-bit  (FFmpeg yuv420p)      */
    LC_PIX_YUV420P10 = 1    /* planar 4:2:0 10-bit LSB-aligned (yuv420p10le) */
} LCPixelFormat;

/* Mirrors of FFmpeg's AVCOL_* numeric values (== ISO/IEC 23001-8 codes). */
enum {
    LC_COLOR_PRI_BT709  = 1,
    LC_COLOR_PRI_BT2020 = 9,
    LC_COLOR_PRI_SMPTE432 = 12,   /* Display P3 */

    LC_COLOR_TRC_BT709       = 1,
    LC_COLOR_TRC_SMPTE2084   = 16,  /* PQ  */
    LC_COLOR_TRC_ARIB_STD_B67 = 18, /* HLG */

    LC_COLOR_SPC_BT709      = 1,
    LC_COLOR_SPC_BT2020_NCL = 9,

    LC_CHROMA_LOC_UNSPECIFIED = 0,
    LC_CHROMA_LOC_LEFT        = 1,
    LC_CHROMA_LOC_CENTER      = 2,
    LC_CHROMA_LOC_TOPLEFT     = 3,
    LC_CHROMA_LOC_TOP         = 4,
    LC_CHROMA_LOC_BOTTOMLEFT  = 5,
    LC_CHROMA_LOC_BOTTOM      = 6
};

/* ------------------------------------------------------------------------ */
/* Hashing (XXH64)                                                           */
/* ------------------------------------------------------------------------ */

typedef struct LCHashState LCHashState;

LCHashState *lc_hash_create(void);
void         lc_hash_reset(LCHashState *s);
void         lc_hash_update(LCHashState *s, const void *data, size_t len);
uint64_t     lc_hash_digest(const LCHashState *s);   /* non-destructive */
void         lc_hash_destroy(LCHashState *s);

uint64_t lc_hash_bytes(const void *data, size_t len);

/**
 * Canonical frame hash: XXH64 over the visible bytes of a bi-planar 4:2:0
 * frame exactly as AVFoundation delivers it (NV12 for 8-bit, P010 i.e. x420
 * for 10-bit): Y rows top to bottom (width*bps bytes each), then the
 * interleaved CbCr rows (width*bps bytes each, height/2 rows). Row padding
 * is excluded so the hash does not depend on the stride.
 */
uint64_t lc_hash_biplanar(const uint8_t *y, size_t y_stride,
                          const uint8_t *cbcr, size_t cbcr_stride,
                          int width, int height, int bytes_per_sample);

/**
 * Same canonical hash computed from a planar frame (decoder output) by
 * re-interleaving/left-aligning rows on the fly. For 10-bit input, planar
 * samples are LSB-aligned 10-bit values and are shifted left by 6 to rebuild
 * the x420 layout. `scratch` must hold at least width*bytes_per_sample bytes.
 */
uint64_t lc_hash_planar_as_biplanar(const uint8_t *y, size_t y_stride,
                                    const uint8_t *u, size_t u_stride,
                                    const uint8_t *v, size_t v_stride,
                                    int width, int height, int bytes_per_sample,
                                    uint8_t *scratch);

/* ------------------------------------------------------------------------ */
/* Bit-exact repacking                                                       */
/* ------------------------------------------------------------------------ */

/**
 * P010/x420 (16-bit words, 10-bit value in the MSBs, interleaved CbCr) ->
 * planar yuv420p10le (10-bit value in the LSBs). Returns the bitwise OR of
 * all low 6 bits encountered; 0 means the input carried pure 10-bit data and
 * the transform is exactly invertible.
 */
uint16_t lc_repack_p010_to_yuv420p10(const uint8_t *y, size_t y_stride,
                                     const uint8_t *cbcr, size_t cbcr_stride,
                                     int width, int height,
                                     uint8_t *dy, size_t dy_stride,
                                     uint8_t *du, size_t du_stride,
                                     uint8_t *dv, size_t dv_stride);

/** Inverse of the above (used for display and verification). */
void lc_repack_yuv420p10_to_p010(const uint8_t *y, size_t y_stride,
                                 const uint8_t *u, size_t u_stride,
                                 const uint8_t *v, size_t v_stride,
                                 int width, int height,
                                 uint8_t *dy, size_t dy_stride,
                                 uint8_t *dcbcr, size_t dcbcr_stride);

/** NV12 (8-bit bi-planar) -> planar yuv420p. */
void lc_repack_nv12_to_yuv420p(const uint8_t *y, size_t y_stride,
                               const uint8_t *cbcr, size_t cbcr_stride,
                               int width, int height,
                               uint8_t *dy, size_t dy_stride,
                               uint8_t *du, size_t du_stride,
                               uint8_t *dv, size_t dv_stride);

/** planar yuv420p -> NV12. */
void lc_repack_yuv420p_to_nv12(const uint8_t *y, size_t y_stride,
                               const uint8_t *u, size_t u_stride,
                               const uint8_t *v, size_t v_stride,
                               int width, int height,
                               uint8_t *dy, size_t dy_stride,
                               uint8_t *dcbcr, size_t dcbcr_stride);

/**
 * Copies the visible bytes of a bi-planar frame into one contiguous buffer
 * (Y rows then CbCr rows, no padding). Returns bytes written
 * (= width*height*bps*3/2). `dst` must be that large.
 */
size_t lc_pack_biplanar(const uint8_t *y, size_t y_stride,
                        const uint8_t *cbcr, size_t cbcr_stride,
                        int width, int height, int bytes_per_sample,
                        uint8_t *dst);

/* ------------------------------------------------------------------------ */
/* Audio sample conversion                                                   */
/* ------------------------------------------------------------------------ */

typedef enum {
    LC_AUDIO_SRC_INT16   = 1,
    LC_AUDIO_SRC_INT24   = 2,   /* packed 3-byte little-endian */
    LC_AUDIO_SRC_INT32   = 3,   /* 24 significant bits expected in the top bits */
    LC_AUDIO_SRC_FLOAT32 = 4,
    LC_AUDIO_SRC_INT24_IN_32_LOW = 5 /* 24-bit value in the low 24 bits of a 32-bit word */
} LCAudioSourceFormat;

/**
 * Converts source PCM into the canonical representation used throughout the
 * app: interleaved int32 with the 24-bit sample value in the top 24 bits
 * (bits 8..31), which is exactly what libavcodec's FLAC encoder consumes and
 * its decoder produces for 24-bit streams.
 *
 * `src` points to `channels` buffers when `non_interleaved` is set (one
 * pointer per channel), otherwise to a single interleaved buffer.
 * Returns the number of samples whose conversion was not exact (float input
 * that was not already quantised to 24 bits, or int32 input with non-zero
 * low byte). Integer 16/24-bit input is always exact.
 */
int64_t lc_audio_convert_to_s32_24(const void *const *src, int non_interleaved,
                                   LCAudioSourceFormat fmt, int channels,
                                   int nb_frames, int32_t *dst);

/* ------------------------------------------------------------------------ */
/* Hash list sidecar (.lchash)                                               */
/* ------------------------------------------------------------------------ */

typedef struct LCHashListWriter LCHashListWriter;

typedef struct {
    int32_t width, height;
    int32_t bit_depth;           /* 8 or 10 */
    int32_t full_range;
    int32_t fps_num, fps_den;
    int32_t audio_sample_rate;   /* 0 = no audio */
    int32_t audio_channels;
    int32_t audio_checkpoint_interval; /* in sample frames, e.g. 48000 */
} LCHashListHeader;

LCHashListWriter *lc_hashlist_open(const char *path, const LCHashListHeader *hdr,
                                   char *err, size_t errlen);
/** Reopen an existing list to append audio records (two-stage: stage 2 commits the audio). */
LCHashListWriter *lc_hashlist_open_append(const char *path, char *err, size_t errlen);
/** Writes only the audio totals record ('F') and closes. */
int lc_hashlist_close_audio(LCHashListWriter *w, int64_t total_audio_frames, uint64_t final_audio_hash);
int lc_hashlist_add_video(LCHashListWriter *w, int64_t frame_index, int64_t pts_ns, uint64_t hash);
/** Running audio-stream digest after `audio_frames_total` sample frames. */
int lc_hashlist_add_audio_checkpoint(LCHashListWriter *w, int64_t audio_frames_total,
                                     int64_t pts_ns, uint64_t running_hash);
int lc_hashlist_close(LCHashListWriter *w, int64_t total_video_frames, int64_t dropped_frames,
                      int64_t total_audio_frames, uint64_t final_audio_hash);
void lc_hashlist_abort(LCHashListWriter *w);

typedef struct {
    LCHashListHeader header;
    int64_t   video_count;
    int64_t  *video_index;      /* [video_count] */
    int64_t  *video_pts_ns;     /* [video_count] */
    uint64_t *video_hash;       /* [video_count] */
    int64_t   audio_checkpoint_count;
    int64_t  *audio_frames;     /* [audio_checkpoint_count] cumulative sample frames */
    int64_t  *audio_pts_ns;
    uint64_t *audio_hash;
    int64_t   total_video_frames;
    int64_t   dropped_frames;
    int64_t   total_audio_frames;
    uint64_t  final_audio_hash;
    int32_t   complete;         /* trailer present */
} LCHashList;

LCHashList *lc_hashlist_load(const char *path, char *err, size_t errlen);
void        lc_hashlist_free(LCHashList *l);

/* ------------------------------------------------------------------------ */
/* FFV1 / FLAC Matroska writer                                               */
/* ------------------------------------------------------------------------ */

typedef struct LCMkvWriter LCMkvWriter;

typedef struct {
    int level;      /* 3 */
    int coder;      /* 1 = range coder (forced for >8-bit anyway) */
    int context;    /* 1 = large context */
    int slices;     /* 24 */
    int slicecrc;   /* 1 */
    int threads;    /* 0 = active core count */
    int gop;        /* 1 = all intra */
} LCFfv1Params;

typedef struct {
    int width, height;
    LCPixelFormat pix_fmt;
    int full_range;
    int color_primaries, color_trc, colorspace, chroma_location;
    int fps_num, fps_den;

    LCFfv1Params ffv1;

    int audio_enabled;
    int audio_sample_rate;
    int audio_channels;
    int audio_ambisonic;        /* 1 = first-order ambisonics (ACN/SN3D), tagged in the container */
    int flac_compression_level; /* 5 */

    /* NULL-terminated array of alternating key/value strings, may be NULL. */
    const char *const *metadata;
} LCMkvConfig;

LCMkvWriter *lc_mkv_open(const char *path, const LCMkvConfig *cfg, char *err, size_t errlen);

/**
 * Declares the recording origin (presentation time of the first video frame)
 * before any audio is written, so audio that precedes it is trimmed at sample
 * granularity rather than discarded per buffer. Optional: the first video
 * frame sets the origin implicitly if this was not called.
 */
void lc_mkv_set_origin(LCMkvWriter *w, int64_t first_video_pts_ns);

/** Write a bi-planar (NV12 / P010) frame; repacks internally, bit-exact. */
int lc_mkv_write_video_biplanar(LCMkvWriter *w, const uint8_t *y, size_t y_stride,
                                const uint8_t *cbcr, size_t cbcr_stride, int64_t pts_ns);
/** Write an already planar frame in the writer's pixel format. */
int lc_mkv_write_video_planar(LCMkvWriter *w, const uint8_t *y, size_t y_stride,
                              const uint8_t *u, size_t u_stride,
                              const uint8_t *v, size_t v_stride, int64_t pts_ns);
/**
 * Write interleaved int32 (24-bit top-aligned) audio. Samples that precede the
 * first video frame are trimmed (counted in lc_mkv_audio_trimmed_frames);
 * gaps larger than 2 ms are filled with digital silence and counted as
 * discontinuities. Must be called from the same thread as the video writes.
 */
int lc_mkv_write_audio(LCMkvWriter *w, const int32_t *interleaved, int nb_frames, int64_t pts_ns);
/** Flushes encoders, writes the trailer and frees the writer. */
int lc_mkv_close(LCMkvWriter *w);
/** Frees without finalising (after an error). */
void lc_mkv_abort(LCMkvWriter *w);

uint64_t lc_mkv_bytes_written(const LCMkvWriter *w);
int64_t  lc_mkv_video_frames_written(const LCMkvWriter *w);
int64_t  lc_mkv_audio_frames_written(const LCMkvWriter *w);
int64_t  lc_mkv_audio_trimmed_frames(const LCMkvWriter *w);
int      lc_mkv_audio_discontinuities(const LCMkvWriter *w);
int64_t  lc_mkv_audio_silence_frames_inserted(const LCMkvWriter *w);
uint16_t lc_mkv_low_bits_seen(const LCMkvWriter *w); /* OR of P010 padding bits */
/** Running XXH64 digest over all committed audio samples (post-trim). */
uint64_t lc_mkv_audio_running_hash(const LCMkvWriter *w);
const char *lc_mkv_last_error(const LCMkvWriter *w);

/* ------------------------------------------------------------------------ */
/* Stage-1 intermediate container (.lci)                                     */
/* ------------------------------------------------------------------------ */

typedef enum {
    LC_S1_RAW         = 1,  /* packed planes, no compression            */
    LC_S1_LZ4         = 2,  /* packed planes, LZ4 (Apple libcompression) */
    LC_S1_LZ4_SHUFFLE = 3,  /* byte-plane shuffle then LZ4              */
    LC_S1_FFV1_FAST   = 4,  /* FFV1 v3, context 0, many slices, 1 thread per worker */
    LC_S1_UTVIDEO     = 5   /* UT Video — only valid for 8-bit input    */
} LCStage1Codec;

typedef struct {
    int width, height;
    int bytes_per_sample;       /* 1 (NV12) or 2 (P010) */
    int bit_depth;              /* 8 or 10 */
    int full_range;
    int color_primaries, color_trc, colorspace, chroma_location;
    int fps_num, fps_den;
    LCStage1Codec codec;
    int audio_sample_rate;      /* 0 = none */
    int audio_channels;
    int audio_ambisonic;
} LCIntermediateConfig;

/** Human readable name of a stage-1 codec. */
const char *lc_stage1_codec_name(LCStage1Codec codec);
/** 1 if this codec can take the given sample depth in this build. */
int lc_stage1_codec_supported(LCStage1Codec codec, int bytes_per_sample);

typedef struct LCStage1Encoder LCStage1Encoder;
/** One encoder per worker thread. */
LCStage1Encoder *lc_s1_encoder_create(const LCIntermediateConfig *cfg, char *err, size_t errlen);
/**
 * Compress one bi-planar frame. On success *out points into a buffer owned by
 * the encoder (valid until the next call) and *out_size is set.
 */
int lc_s1_encoder_compress(LCStage1Encoder *e, const uint8_t *y, size_t y_stride,
                           const uint8_t *cbcr, size_t cbcr_stride,
                           const uint8_t **out, size_t *out_size);
/** Codec extradata (FFV1 fast) or empty. */
const uint8_t *lc_s1_encoder_extradata(const LCStage1Encoder *e, size_t *size);
void lc_s1_encoder_destroy(LCStage1Encoder *e);

typedef struct LCIntermediateWriter LCIntermediateWriter;
LCIntermediateWriter *lc_lci_open(const char *path, const LCIntermediateConfig *cfg,
                                  const uint8_t *extradata, size_t extradata_size,
                                  char *err, size_t errlen);
/** Thread-safe. `raw_size` is the packed frame size (for stats). */
int lc_lci_append_video(LCIntermediateWriter *w, int64_t frame_index, int64_t pts_ns,
                        uint64_t hash, const uint8_t *data, size_t size, size_t raw_size);
/** Thread-safe. Interleaved int32 top-aligned 24-bit samples. */
int lc_lci_append_audio(LCIntermediateWriter *w, int64_t pts_ns,
                        const int32_t *samples, int nb_frames);
int lc_lci_close(LCIntermediateWriter *w);
void lc_lci_abort(LCIntermediateWriter *w);
uint64_t lc_lci_bytes_written(const LCIntermediateWriter *w);
uint64_t lc_lci_raw_bytes(const LCIntermediateWriter *w);

/* ------------------------------------------------------------------------ */
/* Stage 2: intermediate -> final MKV                                        */
/* ------------------------------------------------------------------------ */

typedef void (*LCProgressFn)(void *ctx, double fraction, const char *phase);

typedef struct {
    int64_t frames_in, frames_out;
    int64_t audio_frames_in, audio_frames_out;
    int64_t audio_trimmed_frames;
    int64_t audio_silence_frames_inserted;
    int     audio_discontinuities;
    uint64_t bytes_out;
    uint64_t audio_hash;
    uint16_t low_bits_seen;
    int     recovered_without_trailer;
    int64_t intermediate_hash_mismatches; /* stage-1 payloads whose decoded hash differed from capture */
} LCTranscodeStats;

/**
 * When `hashlist_path` is non-NULL the audio stream checkpoints and the final
 * audio hash of the committed FLAC stream are appended to that hash list
 * (every `audio_checkpoint_interval` sample frames, 48000 if <= 0).
 */
int lc_transcode_intermediate(const char *lci_path, const char *mkv_path,
                              const LCFfv1Params *ffv1, int flac_compression_level,
                              const char *const *metadata,
                              const char *hashlist_path, int audio_checkpoint_interval,
                              LCProgressFn progress, void *progress_ctx,
                              volatile int *cancel,
                              LCTranscodeStats *stats, char *err, size_t errlen);

/* ------------------------------------------------------------------------ */
/* Verification                                                              */
/* ------------------------------------------------------------------------ */

typedef enum {
    LC_VERIFY_PASS = 0,
    LC_VERIFY_FAIL = 1,
    LC_VERIFY_ERROR = 2,
    LC_VERIFY_CANCELLED = 3
} LCVerifyStatus;

typedef struct {
    int     status;                 /* LCVerifyStatus for the whole recording */
    int     video_status;
    int     audio_status;           /* LC_VERIFY_PASS if no audio */
    int64_t frames_expected;
    int64_t frames_decoded;
    int64_t frames_matched;
    int64_t first_mismatch_frame;   /* -1 if none */
    int64_t audio_frames_expected;
    int64_t audio_frames_decoded;
    int64_t audio_first_mismatch_checkpoint; /* -1 if none; index into checkpoint list */
    int64_t audio_first_mismatch_frame;      /* approximate sample frame position */
    int     crc_errors;             /* FFV1 slice CRC mismatches reported by the decoder */
    int     crc_checked;            /* 1 if the decoder was run with CRC checking */
    double  seconds;
} LCVerifyResult;

int lc_verify_recording(const char *mkv_path, const char *hashlist_path, int threads,
                        LCProgressFn progress, void *progress_ctx, volatile int *cancel,
                        LCVerifyResult *result, char *err, size_t errlen);

/* ------------------------------------------------------------------------ */
/* Decoder (MKV/FFV1, MOV/HEVC, FLAC)                                        */
/* ------------------------------------------------------------------------ */

typedef struct LCDecoder LCDecoder;

typedef struct {
    int has_video, has_audio;
    int width, height;
    int bit_depth;
    LCPixelFormat pix_fmt;
    int full_range;
    int color_primaries, color_trc, colorspace, chroma_location;
    int fps_num, fps_den;
    int64_t duration_ns;
    int64_t frame_count;        /* exact when frame_count_exact, else estimated */
    int frame_count_exact;
    char video_codec[32];
    char audio_codec[32];
    char container[32];
    int sample_rate, channels, bits_per_sample;
    int audio_ambisonic;
    int ffv1_version;           /* 0 if not FFV1 / unknown */
    int ffv1_slicecrc;          /* 1 if the stream carries slice CRCs (FFV1 v3 default) */
} LCMediaInfo;

typedef struct {
    const uint8_t *planes[3];
    size_t strides[3];
    int width, height;
    LCPixelFormat pix_fmt;
    int64_t pts_ns;
    int64_t index;              /* frame index in decode order, from the stream index when known */
} LCVideoFrame;

LCDecoder *lc_decoder_open(const char *path, int want_video, int want_audio, int threads,
                           char *err, size_t errlen);
void lc_decoder_get_info(const LCDecoder *d, LCMediaInfo *info);
/** Returns 1 and fills `out` (valid until the next call) / 0 on EOF / <0 error. */
int lc_decoder_next_video(LCDecoder *d, LCVideoFrame *out);
/** Position so the next video frame returned is `frame_index`. */
int lc_decoder_seek_frame(LCDecoder *d, int64_t frame_index);
/** Position so the next video frame returned is the one at/after pts_ns. */
int lc_decoder_seek_time(LCDecoder *d, int64_t pts_ns);
/** Presentation time of a frame index (exact when an index exists, else fps-based). */
int64_t lc_decoder_frame_pts(const LCDecoder *d, int64_t frame_index);
/** Nearest frame index for a presentation time. */
int64_t lc_decoder_frame_index_for_pts(const LCDecoder *d, int64_t pts_ns);
/**
 * Decode audio into `out` (interleaved int32 top-aligned 24-bit, capacity
 * `max_frames` sample frames). Returns frames produced, 0 at EOF, <0 error.
 * *pts_ns receives the timestamp of the first returned sample frame.
 */
int lc_decoder_next_audio(LCDecoder *d, int32_t *out, int max_frames, int64_t *pts_ns);
int lc_decoder_seek_audio(LCDecoder *d, int64_t pts_ns);
int lc_decoder_crc_errors(const LCDecoder *d);
void lc_decoder_close(LCDecoder *d);

/**
 * Nearest-neighbour downscale + YCbCr->RGB (display-referred approximation,
 * HLG treated as a gamma curve) into 8-bit RGBA for thumbnails.
 */
int lc_frame_to_rgba8(const LCVideoFrame *f, int full_range, int colorspace,
                      uint8_t *rgba, int out_w, int out_h, size_t out_stride);

/* ------------------------------------------------------------------------ */
/* Metrics                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
    double mse;
    double psnr;    /* dB, INFINITY when identical */
    double ssim;
} LCLumaMetrics;

/**
 * PSNR / SSIM on the luma plane of two frames with identical geometry.
 * `shift` is applied (>>) to each 16-bit sample before use (6 for P010 to
 * obtain 10-bit codes, 0 for planar LSB data); ignored for 8-bit. `max_value`
 * is the peak code (1023 or 255). SSIM uses 8x8 windows on a 4-pixel grid
 * (x264 / FFmpeg convention) with constants scaled to the bit depth.
 */
int lc_luma_metrics(const uint8_t *a, size_t a_stride, const uint8_t *b, size_t b_stride,
                    int width, int height, int bytes_per_sample, int shift, int max_value,
                    LCLumaMetrics *out);

/* ------------------------------------------------------------------------ */
/* Benchmark helpers                                                         */
/* ------------------------------------------------------------------------ */

/** Fills a packed test frame with camera-like content (gradient + noise). */
void lc_fill_test_frame(uint8_t *y, size_t y_stride, uint8_t *cbcr, size_t cbcr_stride,
                        int width, int height, int bytes_per_sample, uint32_t seed);

#ifdef __cplusplus
}
#endif
#endif /* LOSSLESS_BRIDGE_H */
