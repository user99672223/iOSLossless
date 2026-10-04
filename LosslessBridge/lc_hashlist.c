/* .lchash sidecar: ordered per-frame hashes + audio stream checkpoints.
 *
 * Layout (little-endian):
 *   char magic[8] = "LCHASH01"
 *   LCHashListHeader (9 x int32)
 *   records of 32 bytes: u8 type, u8 pad[7], i64 a, i64 b, u64 c
 *     'V': a = frame index, b = pts_ns, c = frame hash
 *     'A': a = cumulative audio sample frames, b = pts_ns, c = running hash
 *     'E': a = total video frames, b = dropped frames, c = 0
 *     'F': a = total audio frames, b = 0, c = final audio hash
 */
#include "lc_internal.h"
#include <unistd.h>

#define LCHASH_MAGIC "LCHASH01"

typedef struct {
    uint8_t  type;
    uint8_t  pad[7];
    int64_t  a;
    int64_t  b;
    uint64_t c;
} LCHashRecord;

struct LCHashListWriter {
    FILE *f;
    int64_t video_count;
    int64_t audio_checkpoints;
    int     append_mode;      /* opened by lc_hashlist_open_append */
    off_t   append_start;     /* size of the copied capture-time list */
    char   *part_path;        /* <list>.part being written (append mode) */
};

/* Capture-time records are flushed every this many video records so an
 * interrupted recording keeps a verifiable prefix. */
#define LCHASH_FLUSH_EVERY 64

static int write_record(FILE *f, uint8_t type, int64_t a, int64_t b, uint64_t c)
{
    LCHashRecord r;
    memset(&r, 0, sizeof(r));
    r.type = type; r.a = a; r.b = b; r.c = c;
    return fwrite(&r, sizeof(r), 1, f) == 1 ? 0 : -1;
}

LCHashListWriter *lc_hashlist_open(const char *path, const LCHashListHeader *hdr,
                                   char *err, size_t errlen)
{
    if (!path || !hdr) { lc_set_err(err, errlen, "invalid arguments"); return NULL; }
    FILE *f = fopen(path, "wb");
    if (!f) { lc_set_err(err, errlen, "cannot create %s: %s", path, strerror(errno)); return NULL; }
    setvbuf(f, NULL, _IOFBF, 1 << 16);
    if (fwrite(LCHASH_MAGIC, 1, 8, f) != 8 || fwrite(hdr, sizeof(*hdr), 1, f) != 1) {
        lc_set_err(err, errlen, "write failed: %s", strerror(errno));
        fclose(f);
        return NULL;
    }
    LCHashListWriter *w = (LCHashListWriter *)calloc(1, sizeof(*w));
    if (!w) { fclose(f); return NULL; }
    w->f = f;
    return w;
}

LCHashListWriter *lc_hashlist_open_append(const char *path, char *err, size_t errlen)
{
    FILE *src = fopen(path, "rb");
    if (!src) { lc_set_err(err, errlen, "cannot open %s: %s", path, strerror(errno)); return NULL; }
    char magic[8];
    LCHashListHeader hdr;
    if (fread(magic, 1, 8, src) != 8 || memcmp(magic, LCHASH_MAGIC, 8) != 0 || fread(&hdr, sizeof(hdr), 1, src) != 1) {
        lc_set_err(err, errlen, "not a LosslessCam hash list: %s", path);
        fclose(src);
        return NULL;
    }
    /* The capture-time list ends with its 'E' record and the 'F' record that
     * follows it; anything after that belongs to an earlier stage 2 and is not
     * copied. The committed list itself is left untouched until the new MKV is
     * in place (lc_hashlist_commit_append). */
    off_t cut = -1;
    int seen_e = 0;
    LCHashRecord r;
    for (;;) {
        off_t at = ftello(src);
        if (fread(&r, sizeof(r), 1, src) != 1) { if (cut < 0) cut = at; break; }
        if (!seen_e) {
            if (r.type == 'E') seen_e = 1;
        } else if (cut < 0) {
            cut = (r.type == 'F') ? ftello(src) : at;
            break;
        }
    }
    if (cut < 0) cut = ftello(src);
    /* A trailing partial record (crash while writing) is not copied either. */
    const off_t head = 8 + (off_t)sizeof(hdr);
    if (cut > head) cut = head + ((cut - head) / (off_t)sizeof(LCHashRecord)) * (off_t)sizeof(LCHashRecord);

    size_t plen = strlen(path) + 6;
    char *part = (char *)malloc(plen);
    if (!part) { fclose(src); return NULL; }
    snprintf(part, plen, "%s.part", path);
    FILE *f = fopen(part, "wb");
    if (!f) { lc_set_err(err, errlen, "cannot create %s: %s", part, strerror(errno)); free(part); fclose(src); return NULL; }
    setvbuf(f, NULL, _IOFBF, 1 << 16);
    int ok = fseeko(src, 0, SEEK_SET) == 0;
    char buf[1 << 15];
    off_t left = cut;
    while (ok && left > 0) {
        size_t n = (size_t)(left < (off_t)sizeof(buf) ? left : (off_t)sizeof(buf));
        if (fread(buf, 1, n, src) != n || fwrite(buf, 1, n, f) != n) ok = 0;
        left -= (off_t)n;
    }
    fclose(src);
    if (!ok) {
        lc_set_err(err, errlen, "cannot copy %s: %s", path, strerror(errno));
        fclose(f); remove(part); free(part);
        return NULL;
    }
    LCHashListWriter *w = (LCHashListWriter *)calloc(1, sizeof(*w));
    if (!w) { fclose(f); remove(part); free(part); return NULL; }
    w->f = f;
    w->append_mode = 1;
    w->append_start = cut;
    w->part_path = part;
    return w;
}

int lc_hashlist_commit_append(const char *path)
{
    if (!path) return -1;
    size_t plen = strlen(path) + 6;
    char *part = (char *)malloc(plen);
    if (!part) return -1;
    snprintf(part, plen, "%s.part", path);
    int ret = rename(part, path) == 0 ? 0 : -1;
    free(part);
    return ret;
}

int lc_hashlist_close_audio(LCHashListWriter *w, int64_t total_audio_frames, uint64_t final_audio_hash)
{
    if (!w) return -1;
    int ret = 0;
    if (write_record(w->f, 'F', total_audio_frames, 0, final_audio_hash) < 0) ret = -1;
    if (fflush(w->f) != 0) ret = -1;
    if (fsync(fileno(w->f)) != 0) ret = -1;
    if (fclose(w->f) != 0) ret = -1;
    if (ret != 0 && w->part_path) remove(w->part_path);
    free(w->part_path);
    free(w);
    return ret;
}

int lc_hashlist_add_video(LCHashListWriter *w, int64_t frame_index, int64_t pts_ns, uint64_t hash)
{
    if (!w) return -1;
    w->video_count++;
    int ret = write_record(w->f, 'V', frame_index, pts_ns, hash);
    if (ret == 0 && w->video_count % LCHASH_FLUSH_EVERY == 0 && fflush(w->f) != 0) ret = -1;
    return ret;
}

int lc_hashlist_add_audio_checkpoint(LCHashListWriter *w, int64_t audio_frames_total,
                                     int64_t pts_ns, uint64_t running_hash)
{
    if (!w) return -1;
    w->audio_checkpoints++;
    int ret = write_record(w->f, 'A', audio_frames_total, pts_ns, running_hash);
    if (ret == 0 && !w->append_mode && fflush(w->f) != 0) ret = -1;
    return ret;
}

int lc_hashlist_close(LCHashListWriter *w, int64_t total_video_frames, int64_t dropped_frames,
                      int64_t total_audio_frames, uint64_t final_audio_hash)
{
    if (!w) return -1;
    int ret = 0;
    if (write_record(w->f, 'E', total_video_frames, dropped_frames, 0) < 0) ret = -1;
    if (write_record(w->f, 'F', total_audio_frames, 0, final_audio_hash) < 0) ret = -1;
    if (fflush(w->f) != 0) ret = -1;
    if (fclose(w->f) != 0) ret = -1;
    free(w);
    return ret;
}

void lc_hashlist_abort(LCHashListWriter *w)
{
    if (!w) return;
    fclose(w->f);
    /* A failed or cancelled stage 2 leaves the committed list exactly as it was. */
    if (w->part_path) remove(w->part_path);
    free(w->part_path);
    free(w);
}

/* Grows three parallel arrays (two int64, one uint64) to hold `need` items. */
static int grow3(int64_t **a, int64_t **b, uint64_t **c, int64_t *cap, int64_t need)
{
    if (need <= *cap) return 0;
    int64_t ncap = *cap ? *cap * 2 : 1024;
    while (ncap < need) ncap *= 2;
    int64_t *na = (int64_t *)realloc(*a, (size_t)ncap * sizeof(int64_t));
    if (!na) return -1;
    *a = na;
    int64_t *nb = (int64_t *)realloc(*b, (size_t)ncap * sizeof(int64_t));
    if (!nb) return -1;
    *b = nb;
    uint64_t *nc = (uint64_t *)realloc(*c, (size_t)ncap * sizeof(uint64_t));
    if (!nc) return -1;
    *c = nc;
    *cap = ncap;
    return 0;
}

LCHashList *lc_hashlist_load(const char *path, char *err, size_t errlen)
{
    FILE *f = fopen(path, "rb");
    if (!f) { lc_set_err(err, errlen, "cannot open %s: %s", path, strerror(errno)); return NULL; }
    char magic[8];
    LCHashList *l = (LCHashList *)calloc(1, sizeof(*l));
    if (!l) { fclose(f); return NULL; }
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, LCHASH_MAGIC, 8) != 0 ||
        fread(&l->header, sizeof(l->header), 1, f) != 1) {
        lc_set_err(err, errlen, "not a LosslessCam hash list: %s", path);
        fclose(f); free(l);
        return NULL;
    }
    int64_t vcap = 0, acap = 0;
    LCHashRecord r;
    while (fread(&r, sizeof(r), 1, f) == 1) {
        switch (r.type) {
        case 'V':
            if (grow3(&l->video_index, &l->video_pts_ns, &l->video_hash, &vcap, l->video_count + 1) < 0) goto oom;
            l->video_index[l->video_count] = r.a;
            l->video_pts_ns[l->video_count] = r.b;
            l->video_hash[l->video_count] = r.c;
            l->video_count++;
            break;
        case 'A':
            /* A non-increasing position starts a new series (a repeated stage 2
             * in a list written before truncation existed): keep only the latest. */
            if (l->audio_checkpoint_count > 0 && r.a <= l->audio_frames[l->audio_checkpoint_count - 1])
                l->audio_checkpoint_count = 0;
            if (grow3(&l->audio_frames, &l->audio_pts_ns, &l->audio_hash, &acap, l->audio_checkpoint_count + 1) < 0) goto oom;
            l->audio_frames[l->audio_checkpoint_count] = r.a;
            l->audio_pts_ns[l->audio_checkpoint_count] = r.b;
            l->audio_hash[l->audio_checkpoint_count] = r.c;
            l->audio_checkpoint_count++;
            break;
        case 'E':
            l->total_video_frames = r.a;
            l->dropped_frames = r.b;
            l->complete = 1;
            break;
        case 'F':
            l->total_audio_frames = r.a;
            l->final_audio_hash = r.c;
            /* Stage 1 of a two-stage recording writes a placeholder F(0, 0); a committed
             * stream always has a non-zero XXH64 digest (even when empty). */
            l->audio_final_present = r.c != 0;
            break;
        default:
            break;
        }
    }
    fclose(f);
    if (!l->complete) l->total_video_frames = l->video_count;
    return l;
oom:
    fclose(f);
    lc_hashlist_free(l);
    lc_set_err(err, errlen, "out of memory loading hash list");
    return NULL;
}

void lc_hashlist_free(LCHashList *l)
{
    if (!l) return;
    free(l->video_index);
    free(l->video_pts_ns);
    free(l->video_hash);
    free(l->audio_frames);
    free(l->audio_pts_ns);
    free(l->audio_hash);
    free(l);
}
