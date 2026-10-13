#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")"; pwd)

. "$ROOT_DIR/env.sh"

LIBMPV=$DEST/libmpv.so

if [ ! -f "$LIBMPV" ]; then
  echo "Missing build output: $LIBMPV" >&2
  exit 1
fi

elf_header=$("$READELF" -h "$LIBMPV")
if ! "$STRINGS" "$LIBMPV" | grep -F 'secondary-sub-scale' >/dev/null; then
  echo 'Missing independent secondary subtitle scale option' >&2
  exit 1
fi
if ! grep -F "Machine:" <<< "$elf_header" | grep -F "$ELF_MACHINE" >/dev/null; then
  echo "Wrong output architecture; expected $MPV_BUILD_ARCH ($ELF_MACHINE)" >&2
  exit 1
fi

features=$("$STRINGS" "$LIBMPV" | grep "^List of enabled features:")
configuration=$("$STRINGS" "$LIBMPV" | grep "^Configuration:")

for feature in dvdnav libarchive libbluray ohos ohaudiosuite-hoa; do
  if ! grep -Eq "(^| )$feature( |$)" <<< "$features"; then
    echo "Missing mpv feature: $feature" >&2
    exit 1
  fi
done

if ! grep -q -- "-Dgpl=true" <<< "$configuration"; then
  echo "mpv was not built with GPL support enabled" >&2
  exit 1
fi

symbols=$("$NM" -D --defined-only "$LIBMPV")
for symbol in mpv_create ohos_osd_set_global_surface; do
  if ! grep -Eq "[[:space:]]$symbol$" <<< "$symbols"; then
    echo "Missing required dynamic symbol: $symbol" >&2
    exit 1
  fi
done

dynamic_section=$("$READELF" -d "$LIBMPV")
workgroup_imports=$("$NM" -D --undefined-only "$LIBMPV")
if grep -Eq '[[:space:]](OH_AudioWorkgroup_[A-Za-z0-9_]+|OH_AudioResourceManager_(Create|Release)Workgroup|OH_AudioManager_GetAudioResourceManager)(@.*)?$' <<< "$workgroup_imports"; then
  echo "Audio workgroup APIs must remain optional runtime-resolved symbols" >&2
  exit 1
fi
if ! "$STRINGS" "$LIBMPV" | grep -F 'Audio workgroup active (%s).' >/dev/null; then
  echo "Missing default PCM/AudioSuite workgroup implementation" >&2
  exit 1
fi
bash "$ROOT_DIR/scripts/verify-ohos-http3-elf.sh" "$LIBMPV"
for marker in "[OHHTTP3] HTTP/3 response received; QUIC active" \
              "[OHHTTP3] transport failed; falling back to TCP/TLS"; do
  if ! "$STRINGS" "$LIBMPV" | grep -F "$marker" >/dev/null; then
    echo "Missing optional HTTP/3 implementation: $marker" >&2
    exit 1
  fi
done
for marker in usb-exclusive dsd-dop dsd-native dsd-mode sweetvideo.dsd_raw; do
  if ! "$STRINGS" "$LIBMPV" | grep -Fx "$marker" >/dev/null; then
    echo "Missing USB exclusive/DSD implementation: $marker" >&2
    exit 1
  fi
done
if ! "$STRINGS" "$LIBMPV" | grep -Fx "ohaudio-eac3" >/dev/null; then
  echo "Missing experimental E-AC3 output" >&2
  exit 1
fi
if ! "$STRINGS" "$LIBMPV" | grep -F -- "--enable-muxer=spdif" >/dev/null; then
  echo "Missing FFmpeg SPDIF muxer build configuration" >&2
  exit 1
fi
eac3_imports=$("$NM" -D --undefined-only "$LIBMPV")
for symbol in OH_AudioManager_GetAudioStreamManager OH_AudioStreamManager_GetDirectPlaybackSupport; do
  if grep -Eq "[[:space:]]$symbol(@.*)?$" <<< "$eac3_imports"; then
    echo "Optional E-AC3 capability query must be dynamically resolved: $symbol" >&2
    exit 1
  fi
done
if ! "$STRINGS" "$LIBMPV" | grep -Fx "ohaudio-vivid" >/dev/null; then
  echo "Missing native Audio Vivid output" >&2
  exit 1
fi
vivid_imports=$("$NM" -D --undefined-only "$LIBMPV")
for symbol in OH_AudioStreamBuilder_SetWriteDataWithMetadataCallback OH_MD_KEY_AUDIO_VIVID_METADATA OH_AudioRenderer_SetSpeed OH_AudioRenderer_GetSpeed; do
  if ! grep -Eq "[[:space:]]$symbol(@.*)?$" <<< "$vivid_imports"; then
    echo "Missing Audio Vivid transport/rendering import: $symbol" >&2
    exit 1
  fi
done
if ! grep -Eq "NEEDED.*libvideo_processing\.so" <<< "$dynamic_section"; then
  echo "Super resolution is not linked to the video processing engine" >&2
  exit 1
fi
if ! "$STRINGS" "$LIBMPV" | grep -Fx "ohos-super-resolution" >/dev/null; then
  echo "Missing super-resolution option in libmpv" >&2
  exit 1
fi
if ! grep -Eq "NEEDED.*libGLESv2\.so" <<< "$dynamic_section"; then
  echo "Direct OSD renderer is not linked to GLESv2" >&2
  exit 1
fi
if grep -Eq "NEEDED.*libohaudiosuite\.so" <<< "$dynamic_section"; then
  echo "AudioSuite must be optional, not a DT_NEEDED dependency" >&2
  exit 1
fi
if "$NM" -D --undefined-only "$LIBMPV" | grep -Eq 'OH_AudioSuite(Engine|NodeBuilder)_'; then
  echo "AudioSuite calls must use runtime symbol lookup" >&2
  exit 1
fi
if grep -Eq "NEEDED.*lib(dvd|bluray|archive)" <<< "$dynamic_section"; then
  echo "Optical-media dependencies must be linked statically" >&2
  exit 1
fi

# FreeType is built before HarfBuzz so its optional auto-hinter integration
# must stay disabled.  Otherwise FreeType emits a runtime dlopen probe for
# libharfbuzz.so.0 on every shaping operation, even though libass links the
# later HarfBuzz build statically.
if "$STRINGS" "$LIBMPV" | grep -Fxq "libharfbuzz.so.0"; then
  echo "FreeType runtime HarfBuzz probing is still enabled" >&2
  exit 1
fi

for marker in vvc_ohcodec video/vvc vvc_mp4toannexb; do
  if ! "$STRINGS" "$LIBMPV" | grep -Fx "$marker" >/dev/null; then
    echo "Missing VVC OHCodec marker: $marker" >&2
    exit 1
  fi
done

for symbol in mpv_ohos_report_vsync mpv_ohos_reset_vsync; do
  if grep -Eq "[[:space:]]$symbol$" <<< "$symbols"; then
    echo "Removed OHOS VSYNC symbol is still exported: $symbol" >&2
    exit 1
  fi
done

# mpv discovers FFmpeg decoders at runtime, so this decoder description is a
# direct check that the AVS1-P16 capable libcavs implementation reached the
# final statically linked libmpv rather than FFmpeg's AVS1-P2-only decoder.
if ! "$STRINGS" "$LIBMPV" | grep -F "AVS1-P16, Guangdian profile" >/dev/null; then
  echo "Missing AVS+ (AVS1-P16) software decoder" >&2
  exit 1
fi

# libcavs' arithmetic decoder decrements bits_to_go below zero to refill its
# byte buffer.  On AArch64, plain char is unsigned; leaving this state as char
# makes the decrement wrap to 255 and lets optimization remove the decoder
# initializer entirely.  Its exported symbol then aliases the next function,
# which crashes as soon as AVS+ AEC decoding starts.
cavs_start_addr=$(awk '$3 == "cavs_cabac_start_decoding" { print $1; exit }' <<< "$symbols")
cavs_stuffing_addr=$(awk '$3 == "cavs_biari_decode_stuffing_bit" { print $1; exit }' <<< "$symbols")
if [ -z "$cavs_start_addr" ] || [ -z "$cavs_stuffing_addr" ]; then
  echo "Missing AVS+ arithmetic decoder symbols" >&2
  exit 1
fi
if [ "$cavs_start_addr" = "$cavs_stuffing_addr" ]; then
  echo "AVS+ arithmetic decoder initializer was optimized to zero length" >&2
  exit 1
fi

# Optional OHCodec metadata keys are resolved with dlsym at runtime so the
# same libmpv remains loadable on older HarmonyOS releases.
undefined_symbols=$("$NM" -D --undefined-only "$LIBMPV")
if grep -Eq "[[:space:]]OH_NativeWindow_NativeWindowAbortBuffer$" \
    <<< "$undefined_symbols"; then
  echo "Legacy OSD NativeWindow AbortBuffer path is still linked" >&2
  exit 1
fi
for symbol in OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR \
              OH_MD_KEY_VIDEO_DECODER_FRAME_RETENTION_MODE \
              OH_MD_KEY_VIDEO_DECODER_SPEED; do
  if grep -Eq "[[:space:]]$symbol$" <<< "$undefined_symbols"; then
    echo "OHCodec optional key must not be hard-linked: $symbol" >&2
    exit 1
  fi
done

for marker in OH_MD_KEY_VIDEO_DECODER_OUTPUT_ENABLE_VRR \
              OH_MD_KEY_VIDEO_DECODER_FRAME_RETENTION_MODE \
              OH_MD_KEY_VIDEO_DECODER_SPEED; do
  if ! "$STRINGS" "$LIBMPV" | grep -Fx "$marker" >/dev/null; then
    echo "Missing OHCodec runtime key marker: $marker" >&2
    exit 1
  fi
done

if ! "$STRINGS" "$LIBMPV" | grep -F "[OHCodecPolicy]" >/dev/null; then
  echo "Missing OHCodec playback-policy diagnostic marker" >&2
  exit 1
fi

if ! "$STRINGS" "$LIBMPV" | grep -F \
    "OHCodec mutable-image interop: temporal mixing unavailable" \
    >/dev/null; then
  echo "Missing OHCodec temporal-mixing safety marker" >&2
  exit 1
fi

if ! "$STRINGS" "$LIBMPV" | grep -F \
    "Failed to resize NativeWindow buffers" >/dev/null; then
  echo "Missing OHOS NativeWindow resize synchronization" >&2
  exit 1
fi

for marker in "[OSDGLES]" "OSD GLES Surface attached" \
              "waiting for a new Surface generation"; do
  if ! "$STRINGS" "$LIBMPV" | grep -F "$marker" >/dev/null; then
    echo "Missing direct GLES OSD lifecycle marker: $marker" >&2
    exit 1
  fi
done

for marker in "[SuperResolution] submitted input=" \
              "[SuperResolution] configured input/output=" \
              "[SuperResolution] VPE high quality started after Surface configuration" \
              "[SuperResolution] Bypassed: SDR-to-HDR takes priority" \
              "[SuperResolution] No first output; requesting normal output"; do
  if ! "$STRINGS" "$LIBMPV" | grep -F "$marker" >/dev/null; then
    echo "Missing VPE pipeline marker: $marker" >&2
    exit 1
  fi
done

if ! "$STRINGS" "$LIBMPV" | grep -F "OHAudio clock unavailable:" >/dev/null; then
  echo "Missing OHAudio clock state diagnostics" >&2
  exit 1
fi
if "$STRINGS" "$LIBMPV" | grep -F "OHAudio 10s: cb=" >/dev/null; then
  echo "Unexpected OHAudio performance statistics" >&2
  exit 1
fi
if ! "$STRINGS" "$LIBMPV" | grep -F \
    "AudioSuite real-time effect enabled" >/dev/null; then
  echo "Missing OHAudioSuite real-time pipeline" >&2
  exit 1
fi

for marker in "[Perf] decode-send" "[Perf] decode-receive" \
              "[Perf] surface-draw" "[Perf] surface-submit" \
              "[Perf] audio-clock" "[Perf] codec-policy" \
              "[Perf] codec-input" "[Perf] codec-output" \
              "[Perf] audio-timeline" "[Perf] decode-demand" \
              "[Perf] osd-prewarm" "[Perf] font-setup" "[Perf] osd-prepare" \
              "[Perf] osd-font-preload" "[Perf] osd-font-reuse" \
              "[Perf] osd-font-async" "zeroHold="; do
  if ! "$STRINGS" "$LIBMPV" | grep -F "$marker" >/dev/null; then
    echo "Missing runtime performance diagnostics: $marker" >&2
    exit 1
  fi
done

echo "$features"
echo "$configuration"
grep -E "NEEDED|SONAME" <<< "$dynamic_section"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$LIBMPV"
else
  shasum -a 256 "$LIBMPV"
fi
