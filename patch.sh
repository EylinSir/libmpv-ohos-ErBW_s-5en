#!/bin/bash

set -eu

PATCHES=(patches/*)
ROOT=$(pwd)

# The public AVS+ integration also contains an unrelated DRA decoder. Import
# only the three libcavs files, then let our FFmpeg 8.1 patch wire them into
# the build and apply the OpenHarmony portability fixes.
CAVS_PATCH=$ROOT/libmpv/ffmpeg_cavs_dra/ffmpeg-7.1.2_cavs_dra.patch
if [ ! -f "$CAVS_PATCH" ]; then
  echo "Missing pinned AVS+ decoder patch: $CAVS_PATCH" >&2
  exit 1
fi

echo "Importing AVS+ decoder source into FFmpeg..."
git -C ./libmpv/ffmpeg apply -p2 --recount \
  --ignore-space-change --ignore-whitespace \
  --include=libavcodec/libcavs.c \
  --include=libavcodec/libcavs.h \
  --include=libavcodec/libcavsdec.c \
  "$CAVS_PATCH"

# The upstream patch stores these added files with CRLF line endings. Normalize
# them before applying our LF-based FFmpeg 8.1/OpenHarmony compatibility patch;
# otherwise git apply fails on Linux runners even though the source is intact.
sed -i 's/\r$//' \
  ./libmpv/ffmpeg/libavcodec/libcavs.c \
  ./libmpv/ffmpeg/libavcodec/libcavs.h \
  ./libmpv/ffmpeg/libavcodec/libcavsdec.c

# libcavs decrements this state below zero when refilling its arithmetic
# decoder.  Plain char is unsigned on AArch64, which makes the decrement wrap
# and allows optimized builds to eliminate cavs_cabac_start_decoding.
if ! grep -Fq 'char bits_to_go;' ./libmpv/ffmpeg/libavcodec/libcavs.c; then
  echo "Missing expected libcavs bits_to_go declaration" >&2
  exit 1
fi
sed -i 's/char bits_to_go;/int8_t bits_to_go;/' \
  ./libmpv/ffmpeg/libavcodec/libcavs.c

for dep_path in "${PATCHES[@]}"; do
  if [ -d "$dep_path" ]; then
    patches=($dep_path/*)
    dep=${dep_path#*/}
    pushd ./libmpv/$dep
    echo "Patching $dep..."
    for patch in "${patches[@]}"; do
      echo "Applying $patch..."
      git apply "$ROOT/$patch"
    done
    popd
  fi
done

"$ROOT/scripts/verify-ohos-osd-source.sh"
bash "$ROOT/scripts/verify-vpe-adapter.sh"
bash "$ROOT/scripts/verify-ohaudio-clock.sh"
bash "$ROOT/scripts/verify-audio-output-timeline.sh"
bash "$ROOT/scripts/verify-osd-font-worker.sh"
bash "$ROOT/scripts/verify-dts-pts-repair.sh"
bash "$ROOT/scripts/verify-ohcodec-decode-hints.sh"
bash "$ROOT/scripts/verify-ohaudio-vivid.sh"
bash "$ROOT/scripts/verify-ohaudio-eac3.sh"
bash "$ROOT/scripts/verify-usb-audio.sh"
bash "$ROOT/scripts/verify-dsd-decoders.sh"
bash "$ROOT/scripts/verify-ohos-http3-source.sh"
bash "$ROOT/scripts/verify-maleoon-gpu.sh"
bash "$ROOT/scripts/verify-ohaudio-workgroup.sh"
bash "$ROOT/scripts/verify-secondary-subtitle.sh"
