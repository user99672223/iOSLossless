#!/usr/bin/env bash
# Reproducible LGPL FFmpeg build for LosslessCam.
#
# Default: cross-compiles static libraries for iOS arm64 (device only) with a
# minimal component set, merges them into ThirdParty/ffmpeg/lib/libffmpeg.a and
# installs the public headers into ThirdParty/ffmpeg/include.
#
# Host mode (LC_FFMPEG_HOST_BUILD=1): builds the same component set natively
# (Linux or macOS) so the C bridge can be compiled and exercised off-device.
#
# The FFmpeg source is pinned to a release tag and the expected commit SHA is
# verified after checkout. No GPL or non-free components are enabled, so the
# resulting libraries are LGPL v2.1+.
set -euo pipefail

FFMPEG_TAG="${LC_FFMPEG_TAG:-n7.1.5}"
FFMPEG_COMMIT="${LC_FFMPEG_COMMIT:-3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587}"
FFMPEG_GIT_URL="${LC_FFMPEG_GIT_URL:-https://github.com/FFmpeg/FFmpeg.git}"
IOS_MIN_VERSION="${LC_IOS_MIN_VERSION:-18.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${LC_FFMPEG_OUT:-$ROOT/ThirdParty/ffmpeg}"
WORK_DIR="${LC_FFMPEG_WORK:-$ROOT/build/ffmpeg}"
HOST_BUILD="${LC_FFMPEG_HOST_BUILD:-0}"
SRC_DIR="${LC_FFMPEG_SRC:-$WORK_DIR/src}"
PREFIX="$WORK_DIR/install"

log() { printf '\033[1;34m[build-ffmpeg]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Source checkout (pinned tag + commit verification)
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
  log "Cloning FFmpeg $FFMPEG_TAG from $FFMPEG_GIT_URL"
  git clone --quiet --depth 1 --branch "$FFMPEG_TAG" "$FFMPEG_GIT_URL" "$SRC_DIR"
fi
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$FFMPEG_COMMIT" ]; then
  echo "ERROR: FFmpeg checkout is $ACTUAL_COMMIT, expected $FFMPEG_COMMIT (tag $FFMPEG_TAG)" >&2
  exit 1
fi
log "FFmpeg source at $ACTUAL_COMMIT ($FFMPEG_TAG)"

# ---------------------------------------------------------------------------
# 2. Component selection (identical for device and host builds)
# ---------------------------------------------------------------------------
COMPONENT_FLAGS=(
  --disable-everything
  # Lossless video + reference decode
  --enable-decoder=ffv1,utvideo,hevc
  --enable-encoder=ffv1,utvideo
  # Lossless audio
  --enable-decoder=flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be
  --enable-encoder=flac,pcm_s16le,pcm_s24le,pcm_s32le
  # Containers
  --enable-muxer=matroska
  --enable-demuxer=matroska,mov
  # Parsers / bitstream filters required by the above
  --enable-parser=hevc,flac
  --enable-bsf=hevc_mp4toannexb,extract_extradata
  --enable-protocol=file
)

COMMON_FLAGS=(
  --enable-static --disable-shared
  --disable-programs --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-postproc
  --disable-network --disable-autodetect --disable-hwaccels
  --disable-iconv --disable-zlib --disable-bzlib --disable-lzma --disable-sdl2 --disable-xlib
  --disable-debug --disable-stripping
  --enable-pic
  --disable-gpl --disable-nonfree
)

# ---------------------------------------------------------------------------
# 3. Toolchain flags
# ---------------------------------------------------------------------------
TARGET_FLAGS=()
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [ "$HOST_BUILD" = "1" ]; then
  log "Host build (for off-device testing)"
  # x86 SIMD needs nasm/yasm; the host build only exists to exercise the C
  # bridge, so plain C is fine there.
  TARGET_FLAGS+=(--prefix="$PREFIX" --disable-x86asm)
else
  command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found; iOS builds require Xcode" >&2; exit 1; }
  SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
  CC_PATH="$(xcrun --sdk iphoneos --find clang)"
  AR_PATH="$(xcrun --sdk iphoneos --find ar)"
  RANLIB_PATH="$(xcrun --sdk iphoneos --find ranlib)"
  NM_PATH="$(xcrun --sdk iphoneos --find nm)"
  STRIP_PATH="$(xcrun --sdk iphoneos --find strip)"
  log "iOS SDK: $SDK_PATH"
  log "clang:   $CC_PATH"
  ARCH_FLAGS="-arch arm64 -miphoneos-version-min=$IOS_MIN_VERSION -isysroot $SDK_PATH -fno-stack-check"
  TARGET_FLAGS+=(
    --prefix="$PREFIX"
    --enable-cross-compile
    --target-os=darwin
    --arch=arm64
    --cc="$CC_PATH"
    --ar="$AR_PATH"
    --ranlib="$RANLIB_PATH"
    --nm="$NM_PATH"
    --strip="$STRIP_PATH"
    --sysroot="$SDK_PATH"
    --extra-cflags="$ARCH_FLAGS -O3 -fno-common"
    --extra-ldflags="$ARCH_FLAGS"
    --disable-videotoolbox --disable-audiotoolbox --disable-coreimage --disable-avfoundation --disable-appkit --disable-securetransport
  )
fi

# ---------------------------------------------------------------------------
# 4. Configure + build
# ---------------------------------------------------------------------------
cd "$SRC_DIR"
log "Configuring"
if ! ./configure "${TARGET_FLAGS[@]}" "${COMMON_FLAGS[@]}" "${COMPONENT_FLAGS[@]}" > "$WORK_DIR/configure.log" 2>&1; then
  echo "ERROR: configure failed. Last 60 lines of configure.log:" >&2
  tail -60 "$WORK_DIR/configure.log" >&2
  echo "--- ffbuild/config.log tail ---" >&2
  tail -60 ffbuild/config.log >&2 || true
  exit 1
fi
tail -5 "$WORK_DIR/configure.log"

log "Building with $JOBS jobs"
make -j"$JOBS" > "$WORK_DIR/make.log" 2>&1 || { tail -80 "$WORK_DIR/make.log" >&2; exit 1; }
rm -rf "$PREFIX"
make install > "$WORK_DIR/install.log" 2>&1 || { tail -40 "$WORK_DIR/install.log" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Package output: headers + merged static library
# ---------------------------------------------------------------------------
rm -rf "$OUT_DIR/include" "$OUT_DIR/lib"
mkdir -p "$OUT_DIR/include" "$OUT_DIR/lib"
cp -R "$PREFIX/include/." "$OUT_DIR/include/"

LIBS=("$PREFIX/lib/libavformat.a" "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavutil.a")
for l in "${LIBS[@]}"; do [ -f "$l" ] || { echo "ERROR: missing $l" >&2; exit 1; }; done

if [ "$HOST_BUILD" = "1" ]; then
  cp "${LIBS[@]}" "$OUT_DIR/lib/"
else
  # Apple libtool merges static archives (no GNU ar MRI scripts on macOS).
  xcrun --sdk iphoneos libtool -static -o "$OUT_DIR/lib/libffmpeg.a" "${LIBS[@]}"
  cp "${LIBS[@]}" "$OUT_DIR/lib/"
fi

{
  echo "FFmpeg tag:    $FFMPEG_TAG"
  echo "FFmpeg commit: $ACTUAL_COMMIT"
  echo "Built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Host build:    $HOST_BUILD"
  if [ "$HOST_BUILD" != "1" ]; then
    echo "iOS min:       $IOS_MIN_VERSION"
    echo "SDK:           $(xcrun --sdk iphoneos --show-sdk-version)"
    echo "Xcode:         $(xcodebuild -version | tr '\n' ' ')"
  fi
  echo "License:       LGPL v2.1 or later (no GPL / non-free components enabled)"
  echo "Configure:"
  printf '  %s\n' "${TARGET_FLAGS[@]}" "${COMMON_FLAGS[@]}" "${COMPONENT_FLAGS[@]}"
} > "$OUT_DIR/BUILD_INFO.txt"

log "Done. Output in $OUT_DIR"
ls -la "$OUT_DIR/lib"
