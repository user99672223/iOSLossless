#!/usr/bin/env bash
# Builds the C bridge against a host FFmpeg build and runs the off-device
# pipeline tests. Requires a host build of FFmpeg produced by
#   LC_FFMPEG_HOST_BUILD=1 LC_FFMPEG_OUT=<dir> scripts/build-ffmpeg.sh
# and liblz4 (apt install liblz4-dev) on Linux. On macOS libcompression is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FF="${LC_FFMPEG_OUT:-$ROOT/build/ffmpeg-host}"
OUT="${LC_TEST_OUT:-$ROOT/build/bridge-test}"
mkdir -p "$OUT"

CC="${CC:-cc}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
CFLAGS=($EXTRA_CFLAGS -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-unused-function
        -I"$ROOT/LosslessBridge/include" -I"$ROOT/LosslessBridge" -I"$ROOT/ThirdParty/xxhash" -I"$FF/include")
LDFLAGS=("$FF/lib/libavformat.a" "$FF/lib/libavcodec.a" "$FF/lib/libavutil.a" -lm -lpthread)
if [ "$(uname -s)" = "Darwin" ]; then
  LDFLAGS+=(-lcompression -framework CoreFoundation)
else
  LDFLAGS+=(-llz4)
fi

echo "Compiling bridge..."
OBJS=()
for src in "$ROOT"/LosslessBridge/*.c; do
  obj="$OUT/$(basename "${src%.c}").o"
  "$CC" "${CFLAGS[@]}" -c "$src" -o "$obj"
  OBJS+=("$obj")
done
"$CC" "${CFLAGS[@]}" -c "$ROOT/scripts/test/bridge_test.c" -o "$OUT/bridge_test.o"
"$CC" $EXTRA_CFLAGS -o "$OUT/bridge_test" "$OUT/bridge_test.o" "${OBJS[@]}" "${LDFLAGS[@]}"
echo "Running tests (output in $OUT)..."
"$OUT/bridge_test" "$OUT"
