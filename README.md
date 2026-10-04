# LosslessCam

Lossless video capture, verification and comparison for iPhone (built for the
iPhone Air / A19 Pro, deployment target iOS 18.0).

LosslessCam takes the camera's post-ISP frames and the microphone's PCM exactly
as AVFoundation delivers them, stores them with **zero compression loss** as
**FFV1 version 3 video + FLAC 24-bit audio in Matroska**, proves bit-exactness
by hashing every frame and every audio sample on the way in and again after
decoding the finished file, and records **Apple's own HEVC Dolby Vision / HLG
file from the same session** as a reference. An in-app player (FFV1/MKV is not
natively playable on iOS) and a two-video comparison player with PSNR/SSIM
complete the tool.

CI (`.github/workflows/build-ipa.yml`) builds an **unsigned IPA** on a macOS
runner for sideloading and attaches it to GitHub Releases on `v*` tags.

---

## Contents

1. [What the app does](#what-the-app-does)
2. [Codec and container decisions](#codec-and-container-decisions)
3. [Capture pipeline](#capture-pipeline)
4. [Verification](#verification)
5. [Players](#players)
6. [Settings explained](#settings-explained)
7. [Expected throughput and file sizes](#expected-throughput-and-file-sizes)
8. [Getting files off the device](#getting-files-off-the-device)
9. [Building and sideloading](#building-and-sideloading)
10. [Repository layout](#repository-layout)
11. [Troubleshooting](#troubleshooting)
12. [Known limitations](#known-limitations)
13. [Deviations](#deviations)
14. [Licensing](#licensing)

---

## What the app does

* **Capture** tab: live preview, two quick presets (**Fancy** / **Neutral**),
  one-tap resolution / frame rate / HDR toggles, record button, and a live
  telemetry panel while recording (fps achieved and delivered, dropped frames,
  ring-buffer fill, write throughput, compression ratio, thermal state, free
  storage, estimated remaining time, audio format, memory warnings).
* **Default capture preset: 4K (3840×2160) at 60 fps, 10-bit HLG BT.2020**
  (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`, 'x420'). The app selects
  this format directly; lower modes are options.
* **Two lossless paths**: *two-stage* (default for 4K60: a fast lossless stage-1
  codec during capture, FFV1/FLAC transcode after stop with a progress UI) and
  *real-time FFV1* (final format written live).
* **Parallel HEVC reference**: `AVCaptureMovieFileOutput` in the same session
  (HEVC with Dolby Vision 8.4 / HLG as produced by iOS), with an automatic
  fallback to an `AVAssetWriter` + VideoToolbox HEVC Main10 HLG path fed with
  the very same sample buffers. The active path is shown in the UI and stored
  in the recording's metadata.
* **Verification**: XXH64 hash of every delivered frame's plane bytes and a
  running hash over the audio stream, compared against the decoded MKV.
  PASS/FAIL badge per recording with the first mismatching frame index, FFV1
  slice-CRC status from the decoder, manual re-verification.
* **Library**: thumbnails, resolution, fps, timeline duration and frame count,
  size, codecs, dropped-frame badge, verification badge, paired HEVC reference
  indicator, full metadata, delete. Recordings interrupted by a crash are
  adopted automatically (see [Interrupted recordings](#interrupted-recordings)).
* **Diagnostics** (Settings → Diagnostics): a persistent log of session
  errors with their AVFoundation error codes, caught exceptions, recovery
  steps and per-recording summaries, viewable, copyable and shareable; stored
  only on the device.
* **Player**: FFV1 decode through libavcodec on a background thread, HDR display
  through a Metal/EDR pipeline (HLG BT.2100 layer), FLAC audio through
  AVAudioEngine (4-channel ambisonic content is rendered as a stereo decode and
  the channel count is shown), play/pause, scrub, frame step, speed, pinch zoom
  and pan, frame counter + timestamp, 10-bit Y/Cb/Cr pixel inspector, decode
  fps readout.
* **Comparison player**: lossless MKV vs. its HEVC reference (or any two
  recordings), frame-synced by presentation time with manual/auto frame offset;
  side-by-side, A/B flip (tap to swap, hold to peek), split wipe with draggable
  divider, amplified luma-difference heat map with adjustable gain; locked zoom
  and pan; per-frame and running-average luma PSNR and SSIM; frame step and
  scrub apply to both.
* **Benchmark** (Settings → Lossless pipeline): measures every stage-1 codec at
  4K60 10-bit on the device (codec only, then codec + flash writes through the
  real intermediate writer) and auto-picks the fastest option that sustains
  the frame rate, with a manual override.

---

## Codec and container decisions

| Component | Choice | Why |
|---|---|---|
| Video codec | **FFV1 version 3**, `yuv420p10le` (or `yuv420p` for SDR), level 3, range coder (coder 1), context 1, GOP 1 (all intra), 24 slices, slice CRCs on, threads = active cores | Mathematically lossless, open, well specified (IETF RFC 9043), archival grade. Intra-only makes every frame seekable, so frame stepping is exact. Slice CRCs detect corruption on decode. 24 slices (a 4×6 grid) is the spec'd value and gives slice-level threading on A19 Pro. |
| Audio codec | **FLAC**, 24-bit, native sample rate (48 kHz on the iPhone video audio session), compression level 5, channel count from capture | Lossless, universally supported, cheap to decode. 24-bit covers the microphone path's precision. |
| Container | **Matroska (.mkv)** | Carries FFV1 + FLAC, colour metadata (primaries, transfer, matrix, range, chroma siting), per-track tags, cues for every keyframe (so the player can seek by frame index), and arbitrary metadata. |
| HDR tagging | `color_primaries=bt2020`, `color_trc=arib-std-b67` (HLG), `colorspace=bt2020nc`, `range=tv` (or `pc` when the camera delivers a full-range format), chroma siting `left` | Written to the Matroska Colour element from the capture device's active colour space, so external players (mpv, VLC, FFmpeg) interpret the file as HLG BT.2020. The lossless file contains **no Dolby Vision metadata** (see limitations); HLG is self-contained. |
| Audio layout | 4-channel **first-order ambisonics** (ACN order, SN3D) when `AVCaptureDeviceInput.multichannelAudioMode = .firstOrderAmbisonics` is supported, otherwise stereo | The four FOA channels are stored **exactly as delivered**. FLAC has no ambisonic channel assignment, so the Matroska track is tagged `AMBISONIC_ORDER=1`, `AMBISONIC_CHANNEL_ORDER=ACN`, `AMBISONIC_NORMALIZATION=SN3D`, `CHANNEL_LAYOUT=ambisonic 1 (W Y Z X)` and the codec parameters carry FFmpeg's ambisonic layout. Players that ignore the tags treat it as 4-channel audio. |
| Stage-1 codec (two-stage mode) | **LZ4 + byte shuffle** (Apple `libcompression`) by default; also plain LZ4, raw planes, FFV1 fast (context 0), UT Video (8-bit only) — benchmarked on device | UT Video was the primary candidate, but **FFmpeg's `utvideo` encoder only accepts 8-bit input** (`yuv420p`, `yuv422p`, `yuv444p`, `gbrp`, `gbrap`), so for the 10-bit HLG path the app uses the spec's fallbacks. FFV1 with `coder=0` is not possible above 8 bits either (the encoder forces the range coder), so the "FFV1 fast" candidate is range coder + context 0. See [Deviations](#deviations). |
| Frame hash | **XXH64** (vendored xxHash 0.8.3) over the visible bytes of each plane, row by row | ~10 GB/s per core on Apple silicon, so hashing never limits the 1.5 GB/s 4K60 10-bit stream; 64-bit collision resistance is ample for detecting any accidental alteration (an adversarial collision is not the threat model). SHA-256 would cost 3–5× more CPU per frame. |

### Why the hash and the FFV1 input are both "the AVFoundation bytes"

AVFoundation delivers 10-bit frames as **P010-layout bi-planar buffers**
('x420': 16-bit little-endian words with the 10-bit value in the most
significant bits, interleaved CbCr plane). FFV1 encodes **planar**
`yuv420p10le` (10-bit value in the least significant bits). The repacking
between the two is a pure memory-layout transform (`>> 6` and de-interleave),
exactly invertible, and the bridge records the OR of all padding bits so a
non-zero padding would be flagged. Verification decodes the FFV1 frame,
rebuilds the x420 layout and hashes it — so the comparison is against the
bytes the camera delivered, not against an intermediate representation. No
chroma subsampling change, bit-depth change or colour conversion happens
anywhere; the ISP's output is stored sample for sample.

---

## Capture pipeline

```
AVCaptureSession (inputPriority, device format chosen from AVCaptureDevice.formats)
 ├─ AVCaptureVideoDataOutput  native pixel format (x420 / xf20 / 420v / 420f), full-size buffers
 │     │  alwaysDiscardsLateVideoFrames = false; every drop is reported via didDrop
 │     ▼
 │   FrameRingBuffer (RAM)  sized from os_proc_available_memory(), shrinks on memory warnings
 │     │  camera buffers are retained while ≤2 are in flight, otherwise copied into a private pool
 │     ▼
 │   two-stage: N worker threads ─ XXH64 + stage-1 compress ─▶ .lci intermediate (chunked, crash-recoverable)
 │   real-time: 1 encode thread  ─ XXH64 + FFV1 (slice threads) + FLAC ─▶ .mkv
 ├─ AVCaptureAudioDataOutput  PCM → int32 (24-bit top-aligned) ─▶ .lci / FLAC
 └─ AVCaptureMovieFileOutput  HEVC Dolby Vision/HLG reference  ─▶ _HEVC.mov   (or AVAssetWriter fallback)

after stop (two-stage): Stage 2 = .lci ─▶ FFV1 v3 + FLAC ─▶ .mkv, progress UI
then: verification = decode .mkv, rehash, compare with .lchash → PASS / FAIL
      the .lci intermediate is deleted only after a PASS
```

* **Never silent**: frames rejected by a full ring buffer and frames dropped
  by AVFoundation are counted separately, shown live and stored in the
  recording's metadata. While frames are being dropped a full-width warning
  shows the share kept; after the take a summary states kept/delivered frames,
  the timeline and the throughput the pipeline sustained. A storage failure
  (e.g. full flash) stops the recording with a message instead of discarding
  frames unnoticed.
* **Timeline with gaps**: every kept frame keeps its AVFoundation timestamp,
  so a take whose storage path could not keep up still spans its **real
  duration**, with gaps where frames are missing. The Library shows the
  timeline and the number of frames (and, when they differ, the footage
  length = frames ÷ fps and the share of frames kept); the players hold the
  last frame across a gap and the audio track stays continuous.
* **Timestamps**: video frames and audio buffers are muxed with their
  AVFoundation presentation timestamps relative to the first video frame.
  Matroska's fixed 1 ms timestamp scale (libavformat) rounds each time stamp
  to the nearest millisecond; the nanosecond-exact PTS of every frame is kept
  in the `.lchash` sidecar. Audio that precedes the first video frame is
  trimmed at sample granularity (counted), gaps > 2 ms are filled with digital
  silence (counted as discontinuities) so A/V sync is preserved.
* **Memory**: the ring buffer takes ~45 % of the memory the kernel reports as
  available (`os_proc_available_memory`), at most 3 GB / 480 frames; each
  memory warning trims a quarter of its capacity (never below 8 frames) and
  returns the freed pool buffers to the system. A frame's buffer is released
  the moment its worker has written it. At 4K60 10-bit a frame is 24.9 MB, so
  the buffer absorbs bursts of a few seconds — it smooths jitter, it cannot fix
  a sustained deficit (which then shows up as counted drops).
* **Thermals**: `ProcessInfo.thermalState` is part of the telemetry; the app
  does not throttle on its own.
* **Stage 2 and recording do not compete**: stage-2 transcodes and
  verifications of earlier takes pause while a recording is in progress and
  continue when it stops. The stage-1 workers write their chunks with
  positional writes, so no worker waits for another's 15–25 MB write.
* **Stage 2 in the background**: iOS grants ~30 s of background time. When it
  runs out the job stops cleanly at a frame boundary and continues as soon as
  the app is active again (the `.lci` container has a trailer index and is
  scan-recoverable without it; stage 2 can be re-run any number of times).

### Session recovery and safe mode

AVFoundation rejects an impossible configuration either by raising an
Objective-C exception (which would terminate a Swift app) or by posting a
runtime error ("Cannot Record") after the session starts. LosslessCam handles
both:

1. Every configuration setter runs inside an Objective-C exception boundary.
   A rejected multichannel audio mode falls back FOA → stereo → device
   default; a format whose frame duration or colour space is rejected is
   skipped for the next best one; white-balance conversions are range-checked.
2. A runtime error shortly after a configuration change walks a recovery
   ladder that removes **one suspect at a time** from what the failing graph
   actually uses: the in-session HEVC encoder (`AVCaptureMovieFileOutput`,
   replaced by the `AVAssetWriter` path fed with the same stabilized frames),
   stabilization, the spatial/stereo microphone mode; then pairs of them, then
   all, then the microphone input. So a conflict caused by one feature costs
   only that feature. Each step is shown in the UI and logged with the
   AVFoundation error domain, code and underlying error. Errors posted for an
   older configuration are ignored, a late isolated error first restarts the
   session, an error during a recording applies the next step once the
   recording stops, and a configuration that ran cleanly is remembered.
3. If the app ever terminates while configuring the camera, the next launch
   starts in **safe mode** (level 1: no multichannel audio mode and no
   MovieFileOutput; level 2: also no stabilization; level 3: also no
   microphone). Safe mode is shown on the Capture screen and can be left from
   Settings.

### Interrupted recordings

If the app is terminated during a recording (crash, jetsam, battery), the
Library adopts what reached the flash: a two-stage `.lci` intermediate becomes
a pending recording and stage 2 builds the MKV from it; an unfinalised
real-time `.mkv` (no Cues, no duration) gets its frame index rebuilt by
scanning. Intermediate chunks are written payload-first, header-last, so a
crash can never expose a chunk whose data is incomplete; an undecodable tail
of a recovered intermediate ends the video at the last good frame (counted)
instead of failing stage 2. The capture hash list is flushed every 64 frames,
so verification checks every frame that has a hash and reports the few at the
end that do not; for such recordings the intermediate is kept.

Stage 2 never destroys what is already proven: it writes `<base>.mkv.part`
and `<base>.lchash.part` and moves both into place only after a complete
transcode, so a cancelled, failed or interrupted rebuild leaves the previous
MKV and its hashes untouched.

---

## Verification

During capture every frame's visible plane bytes (Y rows, then interleaved
CbCr rows; stride padding excluded) are hashed with XXH64. Audio is converted
to the canonical 24-bit representation and hashed as **one continuous
stream**, with the running digest stored every second (checkpoints); in
two-stage mode the audio hashes are committed by stage 2, which is where
trimming and gap handling are decided. All of it is written to
`<base>.lchash` together with the nanosecond PTS of each frame.

After stage 2 (or right after a real-time recording) the app decodes the final
MKV with libavcodec (`AV_EF_CRCCHECK` enabled so FFV1 slice CRCs are enforced),
repacks every frame to the capture layout, rehashes and compares in order, and
streams the decoded FLAC through the same running hash, comparing at every
checkpoint and at the end. The result (PASS / FAIL, frames checked, first
mismatching frame, first mismatching audio checkpoint, slice-CRC error count,
duration) is shown as a badge in the Library and in detail in the recording
view. Verification can be re-run at any time from the recording view.

The verifier is exercised off-device by `scripts/test/run-bridge-tests.sh`
(also run in CI on Linux): synthetic P010 frames and 24-bit audio go through
every stage-1 codec, stage 2 and the real-time writer, must verify PASS, and a
deliberately corrupted hash must be reported as FAIL at the right frame.

---

## Players

Both players use the same Metal renderer: the decoded frame is wrapped in an
IOSurface-backed CVPixelBuffer in the capture layout (x420 / 420v) tagged with
BT.2020/HLG (or BT.709) colour attachments, bound as `r16Unorm` + `rg16Unorm`
textures, converted to R'G'B' in a fragment shader and drawn into an
`rgba16Float` `CAMetalLayer` with `wantsExtendedDynamicRangeContent`,
`CAEDRMetadata.hlg` and the ITU-R BT.2100 HLG colour space, so the display
pipeline applies the HLG system gamma and EDR headroom. SDR recordings use a
BT.709 layer.

* **Single player**: libavcodec FFV1 decode (slice threads) on a dedicated
  thread. Playback is paced by **presentation timestamps**, so gaps left by
  dropped frames are held and the audio stays in sync. Three pacing modes:
  *every frame* (each frame at its timestamp, slow-motion if 4K60 cannot be
  decoded in real time — frame stepping and scrubbing stay exact), *real time*
  (follows the audio clock, skips frames when decode is slow) and *compact*
  (frames back to back, gaps collapsed). The overlay shows frame index,
  timestamp / timeline length, the length of the gap after the current frame,
  decode fps/ms; it hides itself during playback and can be switched off.
  Two-finger hold shows the 10-bit codes under the finger.
* **Comparison player**: A drives the timeline; B is matched by presentation
  time plus an offset (`Auto-align` searches ±6 frames for the best PSNR). The
  HEVC reference is decoded by AVAssetReader (hardware) into the same x420
  layout, so both sides share the shader path; metrics are computed in C on
  the 10-bit luma planes (PSNR with peak 1023; SSIM on 8×8 windows at a
  4-pixel step, constants scaled to the bit depth).

---

## Settings explained

| Setting | Options | Notes |
|---|---|---|
| Resolution | 1080p / 4K | Greyed out and marked "(not offered)" when the camera has no matching format for the current fps/HDR choice (the closest supported format is then used and a warning is shown). |
| Frame rate | 24 / 30 / 60 | Sets `activeVideoMin/MaxFrameDuration` to a value inside the chosen format's supported range; if the format cannot do the requested rate, its highest rate is used and shown. |
| Stabilization | off / standard / cinematic | Applied on the data-output connection (and the reference's connection). Stabilization happens in the ISP before delivery; the stored frames are the stabilized ones. If the session reports a runtime error with stabilization on, the recovery ladder first moves the reference to AVAssetWriter and only then turns stabilization off; the active state is shown in the format line. |
| HDR video | on / off | On = 10-bit 'x420' format with `activeColorSpace = .HLG_BT2020`. Off = the camera's 8-bit 4:2:0 SDR format (stored losslessly as yuv420p, BT.709). |
| Exposure | auto / locked (shutter + ISO sliders) | `setExposureModeCustom`, clamped to the format's limits. |
| White balance | auto / locked (temperature + tint) | Converted to device gains and clamped to `maxWhiteBalanceGain`. |
| Focus | continuous / locked lens position | `setFocusModeLocked(lensPosition:)`. |
| Audio | spatial / stereo | Spatial = `.firstOrderAmbisonics` (4 ch) when supported by the device, otherwise stereo; the active mode is shown. |
| Capture mode | two-stage / real-time FFV1 | See pipeline. |
| Stage-1 codec | auto (benchmark pick) or explicit | The automatic pick uses benchmark results measured at the bit depth being recorded. UT Video is listed but marked unsupported for 10-bit input; a codec that cannot take the bit depth falls back to LZ4 + shuffle. |
| HEVC reference | auto / MovieFileOutput / AssetWriter / off | Auto prefers MovieFileOutput and falls back to AssetWriter when the session rejects it or reports a runtime error. |
| Presets | **Fancy**: cinematic stabilization, HDR on, exposure/WB/focus auto. **Neutral**: stabilization off, HDR off, exposure/WB/focus locked at the current values. | Presets only set the toggles. |

---

## Expected throughput and file sizes

Raw (uncompressed) data rates of the formats, which the stage-1 path must
hash, compress and write in real time:

| Mode | Bytes / frame | Raw rate | Raw per minute |
|---|---|---|---|
| 4K60 10-bit (x420) | 24.9 MB | **1.49 GB/s** | 89 GB |
| 4K30 10-bit | 24.9 MB | 746 MB/s | 45 GB |
| 4K24 10-bit | 24.9 MB | 597 MB/s | 36 GB |
| 1080p60 10-bit | 6.2 MB | 373 MB/s | 22 GB |
| 1080p30 10-bit | 6.2 MB | 187 MB/s | 11 GB |
| 4K60 8-bit (420v) | 12.4 MB | 746 MB/s | 45 GB |

Typical compression of camera footage (sensor noise in the low bits limits
every lossless codec):

| Codec | Ratio on camera content | Final file at 4K60 10-bit |
|---|---|---|
| FFV1 v3 (final) | ≈ 1.8–2.5× | ≈ 35–50 GB per minute |
| LZ4 + shuffle (stage 1) | ≈ 1.3–1.6× | intermediate, deleted after the MKV verifies |
| LZ4 (stage 1) | ≈ 1.1–1.3× | — |
| Raw planes (stage 1) | 1.0× | — |
| FLAC 24-bit 4 ch 48 kHz | ≈ 1.5–2× | ≈ 200–300 MB per hour |
| HEVC reference (Apple) | lossy | ≈ 0.4–0.9 GB per minute |

**Honest expectation for 4K60 10-bit**: 1.49 GB/s of input exceeds what a
phone can write to flash after compression unless the stage-1 codec and the
NAND cooperate; the on-device benchmark reports exactly what the device
sustains. Run it (Settings → Lossless pipeline → Benchmark) before relying on
4K60; when nothing sustains the target, the app still records, and every frame
that could not be kept is counted and reported after the recording. 4K30 and
1080p modes are comfortably within reach of the LZ4 path, and real-time FFV1
is realistic for 1080p. Verification of a 4K60 clip takes roughly the clip's
duration × (60 / FFV1 decode fps); FFV1 decode on the A19 Pro is in the order
of 20–40 fps at 4K 10-bit with slice threads.

---

## Getting files off the device

All files live in the app's Documents directory (`UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` are set):

* **Files app** → On My iPhone → LosslessCam.
* **USB**: Finder (macOS) or iTunes/Apple Devices (Windows) → device → Files →
  LosslessCam; drag the files out. Expect tens of GB per minute of 4K60.
* Each recording consists of
  `LosslessCam_<timestamp>_<preset>_<mode>.mkv` (final lossless file),
  `…_HEVC.mov` (Apple's reference, same base name), `….lchash` (hash list),
  `….json` (metadata, telemetry, verification) and, until the MKV has
  verified, `….lci` (intermediate).
* `LosslessCam_diagnostics.log` is the diagnostics log (also viewable in
  Settings → Diagnostics).

Playing the MKV elsewhere: `mpv`, VLC and `ffplay` play FFV1/FLAC/MKV with
correct HLG interpretation; `ffprobe -show_streams` shows
`color_transfer=arib-std-b67`, `color_primaries=bt2020`,
`color_space=bt2020nc`, `pix_fmt=yuv420p10le`.

---

## Building and sideloading

### CI

`.github/workflows/build-ipa.yml` runs on every push, on manual dispatch and
on `v*` tags:

1. `macos-15` runner, newest release (non-beta) Xcode present on the image;
   the job runs only after the bridge tests pass.
2. `brew install xcodegen` and `xcodegen generate` (the `.xcodeproj` is
   generated from `project.yml`; it is not committed).
3. `scripts/build-ffmpeg.sh`: clones FFmpeg at the pinned tag (`n7.1.5`,
   commit verified), configures a minimal **LGPL** static build for iOS arm64
   (FFV1, UT Video, FLAC, HEVC decode, Matroska mux/demux, MOV demux, PCM, the
   required parsers; no GPL/non-free, no programs/docs), merges the libraries
   into `ThirdParty/ffmpeg/lib/libffmpeg.a` with headers in
   `ThirdParty/ffmpeg/include`. The result is cached by `actions/cache`, keyed
   on the script and the Xcode version.
4. `xcodebuild archive` for `generic/platform=iOS` with
   `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
5. The `.app` is placed in `Payload/` and zipped as `LosslessCam.ipa`,
   uploaded as a workflow artifact (`LosslessCam.ipa`) and attached to the
   GitHub Release when a tag was pushed.

A first job builds FFmpeg natively on Ubuntu and runs the C bridge test
suite (`scripts/test/run-bridge-tests.sh`) twice, the second time under
AddressSanitizer and UndefinedBehaviorSanitizer. It covers every stage-1
codec, stage 2 (including repeated, cancelled and paused runs), the real-time
writer, verification and tamper detection, dropped-frame gaps, recovery of an
unfinalised file and of an intermediate, and audio conversion edge cases.

### Local build

```sh
brew install xcodegen
scripts/build-ffmpeg.sh          # needs Xcode; ~5 min
xcodegen generate
open LosslessCam.xcodeproj       # set your team to run on a device, or archive unsigned as CI does
```

### Sideloading the unsigned IPA

The IPA is unsigned; sign it with your own Apple ID (free accounts: 7-day
certificates, 3 apps) or a paid developer certificate:

* **AltStore** (https://altstore.io): install AltServer on your Mac/PC, AltStore
  on the phone, then *My Apps → + → LosslessCam.ipa*. AltServer re-signs
  weekly while the phone is on the same Wi‑Fi.
* **Sideloadly** (https://sideloadly.io): connect the phone, drag the IPA in,
  enter your Apple ID, *Start*.
* **Xcode / Apple Configurator**: re-sign with your team and install, or open
  the project and run on the device.

After installation: Settings → General → VPN & Device Management → trust the
developer profile. Camera and microphone permission prompts appear on first
launch. The app needs iOS 18 and an arm64 device with a camera.

---

## Repository layout

```
LosslessCam/            Swift + SwiftUI app
  App/                  entry point, root tab view
  Capture/              AVCaptureSession management, recovery ladder, format catalogue, HEVC reference recorder
  Diagnostics/          persistent diagnostics log
  Pipeline/             ring buffer, recording pipeline, stage-2/verification runner, benchmark, telemetry
  Library/              Documents scanning, sidecar metadata, thumbnails
  Player/               frame sources (FFV1 via libavcodec, HEVC via AVAssetReader), Metal HDR renderer, audio, models
  Views/                Capture, Settings, Benchmark, Library, Player, Comparison screens
  Assets.xcassets, Info.plist, bridging header
LosslessBridge/         C bridge (static library target): FFmpeg calls, hashing, repacking,
                        .lci intermediate container, stage-2 transcoder, verifier, PSNR/SSIM,
                        and the Objective-C exception boundary used around AVFoundation setters
ThirdParty/xxhash/      vendored xxHash (BSD-2)
ThirdParty/ffmpeg/      build output of scripts/build-ffmpeg.sh (not committed, cached in CI)
scripts/build-ffmpeg.sh reproducible FFmpeg build (iOS cross-compile or host build for tests)
scripts/test/           off-device bridge test harness
project.yml             XcodeGen project definition (app + bridge targets)
.github/workflows/      CI: bridge tests on Linux, unsigned IPA on macOS, release attachment
LICENSE                 MIT for this code; FFmpeg LGPL-2.1+ and xxHash BSD-2 notices
```

---

## Troubleshooting

* **A performance panel (OS, GPU, CPU figures) appears over the video.** That
  is iOS's Metal performance HUD, not part of the app. It is switched on in
  Settings → Developer → Graphics HUD (the Developer menu exists because
  Developer Mode is enabled for sideloading). Turn it off there. The app also
  sets `MetalHudEnabled = NO` in its Info.plist.
* **The app closed itself when the camera was set up.** Open it again: the
  crash-loop guard starts it in safe mode, and Settings → Diagnostics shows
  which step failed. Share the log (Diagnostics → ⋯ → Share log file) when
  reporting the problem, then try *Leave safe mode* in Settings.
* **"Camera session error … Cannot Record".** The message now carries the
  AVFoundation error code and the step the recovery ladder took (for example
  "MovieFileOutput removed; HEVC reference now encoded by AVAssetWriter").
  The session keeps running with the relaxed configuration.
* **The lossless file is shorter than the HEVC reference.** It is not: both
  span the same timeline. When the storage path cannot sustain the mode, the
  lossless file has gaps (dropped frames, counted and shown during and after
  the take) while Apple's lossy encoder keeps every frame. The Library row
  shows the timeline, the frame count and the share of frames kept. To keep
  every frame, run the stage-1 benchmark, use a lower frame rate or 1080p,
  free flash space, and let earlier stage-2 jobs finish (they pause while
  recording, but still use flash bandwidth).
* **Stage 2 stopped when I left the app.** iOS allows only a short background
  time. The job continues automatically when the app is open again.

---

## Known limitations

* **No Deep Fusion / Photonic Engine / computational photography** in the
  lossless file: the data is the ISP's real-time video output, exactly what the
  camera delivers to any video app.
* **No Dolby Vision metadata in the lossless file.** Dolby Vision 8.4 is an
  HEVC-specific RPU; FFV1/Matroska carries the HLG colour signalling only,
  which is the self-contained part of DV 8.4. The paired HEVC reference keeps
  Apple's DV metadata.
* **No Apple Log on iPhone Air** (Log is a Pro-camera feature); the HDR path
  is HLG BT.2020.
* **1 ms timestamp granularity in Matroska** (libavformat writes a fixed
  TimestampScale); exact nanosecond PTS are in the `.lchash` sidecar.
* **4K60 FFV1 playback is not real time** on device; the default pacing shows
  every frame at its timestamp and slows down when decode cannot keep up, and
  remains frame-exact.
* **Audio bit depth**: the microphone path delivers 16-bit or 32-bit float PCM
  depending on iOS and the audio mode; see Deviations for how this maps to
  24-bit FLAC.
* **Simultaneous MovieFileOutput + VideoDataOutput** depends on iOS, the format
  and the stabilization mode; when the session rejects the combination or
  reports a runtime error, the AssetWriter fallback is used and labelled.
* **AVAssetWriter reference audio** is a stereo AAC monitor track; with spatial
  (4-channel) capture the fallback reference has no audio (the lossless file
  keeps all four channels).
* **The end of an interrupted recording** (about 0.1 s held in the muxer's
  queue, plus frames still in the RAM ring buffer) is lost when the app is
  terminated mid-take.
* **Storage**: 4K60 lossless is ~40–50 GB per minute after FFV1; the app shows
  remaining time at the current write rate. iOS may purge the app's Documents
  only through the Files app or app deletion — move files off regularly.
* **Background**: stage 2 and verification need the app in the foreground;
  they stop cleanly when background time runs out and resume when the app is
  active.
* **File-size limits**: none in Matroska; the Files app and USB transfer handle
  >4 GB files.

---

## Deviations

Where the specification could not be met exactly, the closest fully lossless
alternative is implemented:

1. **UT Video for 10-bit stage 1.** FFmpeg's `utvideo` encoder only supports
   8-bit pixel formats (checked at runtime with `avcodec_get_supported_config`
   and shown as "unsupported" in the benchmark). As the spec allows, the 10-bit
   stage-1 candidates are FFV1 fast and a custom LZ4 path (plain LZ4, and
   LZ4 with a byte-plane shuffle that separates the noisy low bytes from the
   high bytes). UT Video is available for 8-bit (SDR) captures.
2. **FFV1 "coder=0, context=0" for stage 1.** FFV1 forces the range coder for
   bit depths above 8 (`bits_per_raw_sample > 8, forcing range coder`), so the
   10-bit fast variant is range coder + context 0 + 24 slices, one encoder
   per worker thread.
3. **"Never convert pixel formats in software."** No *conversion* happens;
   the only transform is the lossless, exactly invertible repacking of the
   bi-planar MSB-aligned P010 layout into FFV1's planar LSB-aligned
   `yuv420p10le`, with the padding bits checked to be zero. The hash is
   computed over the original bytes, and the verifier reconstructs them.
4. **Audio bit depth.** The spec requires 24-bit FLAC and sample-exact storage.
   AVCaptureAudioDataOutput's format is not configurable on iOS. Integer
   16-bit input is stored as 24-bit with eight zero LSBs (exact and
   reversible); packed 24-bit and 24-in-32 integer input is exact; 32-bit
   float input is quantised to 24-bit fixed point (2⁻²³ full scale, far below
   the microphone noise floor) and the app counts samples whose conversion was
   not exact and shows the count. The hash list covers the committed 24-bit
   samples, so the FLAC round-trip is still verified bit-exactly.
5. **Sample rate.** No resampling is ever applied: FLAC is written at the rate
   AVFoundation delivers (48 kHz on the video audio session; shown in the UI).
6. **Audio before the first video frame** is pre-roll and is trimmed (counted
   as "trimmed frames"); the recording starts with the first video frame.
   Gaps in the audio timeline are filled with silence and counted.
7. **Matroska timestamps** are rounded to 1 ms by libavformat; nanosecond PTS
   per frame are stored in the sidecar.
8. **Xcode project** is generated by XcodeGen from `project.yml` rather than
   committed as a `.xcodeproj`, keeping the project definition reviewable and
   the CI deterministic.
9. **Dolby Vision in the reference**: `AVCaptureMovieFileOutput` adds Dolby
   Vision 8.4 metadata itself on devices/formats where iOS does so (10-bit HLG
   formats); the AssetWriter fallback requests HEVC Main10 with HLG colour
   properties and `kVTCompressionPropertyKey_HDRMetadataInsertionMode = Auto`.
   Whether a given file carries DV RPUs depends on iOS.

---

## Licensing

* LosslessCam sources: MIT (see `LICENSE`).
* FFmpeg (libavcodec/libavformat/libavutil): **LGPL v2.1 or later**; built from
  the pinned upstream tag with `--disable-gpl --disable-nonfree`. The configure
  line is recorded in `ThirdParty/ffmpeg/BUILD_INFO.txt` and shown in the app
  (Settings → About). The app links FFmpeg statically; the corresponding source
  is the tagged upstream release and relinking is possible by rebuilding from
  this repository, as the LGPL requires.
* xxHash: BSD 2-Clause.
