# libmpv-ohos-build

Build scripts of [libmpv](https://github.com/mpv-player/mpv) for OpenHarmony ARM64 and x86_64.

CI builds ARM64 only. The `artifact` download contains `libmpv_aarch64.zip`
with its `libmpv.so`; CI does not build or package x86_64.

For a local Linux/macOS build, run `MPV_BUILD_ARCH=arm64 ./bundle.sh` (default) or
`MPV_BUILD_ARCH=x86_64 ./bundle.sh`. Do not use `TARGET_ARCH`: GNU Make treats
that variable as compiler flags. Use a **separate fresh checkout per architecture**:
dependency source directories contain in-tree build caches and cannot be shared
between architectures. Outputs go to `libmpv/<architecture>-build/`.
Install NASM for x86_64 assembly. ARM here means ARM64, not 32-bit ARM.
The emulator also needs x86_64 app-side native libraries; hardware decoding,
HDR and VPE availability depend on its system image and GPU capabilities.
The AudioSuite integration requires API 23+, with HOA rendering requiring API 26.
Linux CI uses the pinned HarmonyOS 7.0 Release public NDK `26.0.0.38`
(`20260829` archive, verified by SHA-256). Its AudioSuite base and engine headers
are identical to the local DevEco `26.0.0.105` SDK headers.
The SDK preflight checks version, API 26 AVCodec declarations, and the HOA node;
the final binary check also requires the `ohaudiosuite-hoa` feature.

Scripts are compatible with macOS, Linux and WSL, Windows is not supported.

This tree is based on the `20260715` mpv-arkts binary baseline and pins
`ErBWs/mpv` to commit `6edeee00a07b9b76f197aa71eee3d029fb090de4`.

## Experimental optional HTTP/3

HTTPS GET connections automatically try RCP QUIC / nghttp3 after the original
server advertises same-host, same-port `h3` in Alt-Svc. The first ordinary request
is unchanged. Plain HTTP IPTV, UDP/RTP, RTSP and local playback are unaffected.
No application setting or URL rewrite is required. Both video output modes use
the same network layer; actual improvement requires an HTTP/3-enabled source.

QUIC APIs are dynamically resolved and nghttp3 1.18.0 is statically linked.
Neither the application nor libmpv may require a system QUIC library at load
time. Missing capabilities, unsupported TLS/proxy configuration or failed H3
setup use existing TCP/TLS. Failed endpoints back off for five minutes. HLS can
reuse eight requests per connection before a bounded-state rotation. This is
not a full multi-player connection pool. TLS verification policy is preserved;
custom client certificates and alternative H3 authorities are not supported.

Successful H3 response parsing logs `[OHHTTP3] HTTP/3 response received; QUIC active`.
This is different from an attempt or mere API availability. Phone/tablet/2in1/TV
API 26 coverage is documented, but each real device still needs library, TLS,
cancel/close and weak-network validation. See `tests/ohos-http3-integration.md`.
CI runs host protocol regressions after the target build and verifies optional
dependencies in the final libmpv. Host mocks do not prove on-device QUIC works.

The FFmpeg patch exports `ohos_http3_extralibs` through `avformat_extralibs`,
so the installed static `libavformat.pc` carries nghttp3 to mpv's final link.
The build checks that metadata after installation and rejects all unresolved
`nghttp3_*` imports in the final ELF, not merely a shared-library dependency.
The same check can audit a library extracted from a HAP with
`bash scripts/verify-ohos-http3-elf.sh /path/to/libmpv.so` (set `NM`/`READELF`
to the SDK tools when needed). This prevents a network feature's missing static
dependency from breaking the shared native module and both player engines.

## Default optional audio workgroup

The `ohaudio` PCM output automatically probes all seven API 20 audio-workgroup
symbols in the already-used `libohaudio.so`. Both ordinary PCM copying and
AudioSuite rendering share the same per-callback scheduling scope. No UI or mpv
option, new processing thread, extra audio queue, or mandatory new symbol is
added. Unsupported systems and operation failures keep the original output.

Groups are created outside callbacks. The actual callback thread registers once
(again only if its kernel thread ID changes); successful Start calls are paired
with Stop. Scheduling timestamps use system-clock epoch milliseconds, separate
from mpv's A/V-sync clock. The requested output duration gives a conservative
budget with a 10%/minimum-1ms handoff margin, capped at 100ms; sub-2ms requests
skip workgroup hints. This is an estimate, not a measured hardware deadline.

An off-callback log distinguishes `ready` from `Audio workgroup active (PCM).`
or `Audio workgroup active (AudioSuite).` Runtime failure is reported once and
disables further scheduling calls for that AO. Teardown releases the renderer
before workgroup members/group/library; unconfirmed teardown pins optional
resources instead of unloading live code. Existing buffering, music route
policy, AudioSuite optional loading and A/V timing remain unchanged.

Host fault-injection/concurrency tests run during patch verification; final ELF
verification rejects mandatory workgroup imports. See
[workgroup acceptance and limitations](tests/ohaudio-workgroup-integration.md).
Passing these tests does not demonstrate lower device underruns or power use.
Native Vivid, compressed E-AC3, USB-exclusive and system AVPlayer outputs are
separate paths and are not changed by this integration.

## Audio Vivid speed policy

The dedicated OHAudio Vivid output retains PCM/metadata frame pairing. Playback
speed is delegated to the system renderer (0.25–4x), not mpv tempo/resampling
filters. A rate is accepted only when the setter and readback agree. Rejection
keeps the old rate and native Vivid; there is no automatic PCM downgrade.
Readiness failures and device rejection are reported to the caller. Device
acceptance is still required; API availability alone does not prove Vivid speed
support. See `tests/audio-native-integration.md` for verification scope.

## OHCodec Surface output

The `patches/mpv/support-ohcodec-surface-osd.patch` patch adds the
`ohcodec-osd` video output:

- decoded OHCodec frames are presented directly to the Surface passed through
  `--wid`;
- mpv/libass subtitles and OSD are rendered into a second transparent BGRA
  Surface;
- the embedding library supplies or replaces that second Surface with
  `ohos_osd_set_global_surface(surface_id, width, height)`;
- the OSD Surface may be supplied before or after `mpv_initialize()`.

The two ArkUI surfaces must have the same on-screen bounds, with the transparent
OSD XComponent above the video XComponent. The application remains responsible
for making the upper XComponent transparent.

The existing `gpu-next` OHCodec OpenGL/Vulkan path remains available as buffer
mode. `ohcodec-osd` is the direct Surface mode: it avoids a video-frame copy,
but mpv GPU shaders such as Anime4K do not run on the direct video plane.
Subtitles and normal mpv OSD remain available through the separate OSD plane.

The OHCodec buffer path treats NativeImage as a single mutable external image.
It therefore disables temporal frame mixing and requests one decoder frame at
a time. This keeps the zero-copy path short and prevents playback-speed changes
from exhausting the decoder output pool. Spatial GPU shaders remain available;
software-decoded video is unaffected and may still use temporal interpolation.

## System video super resolution

SDR-to-HDR takes priority over super resolution. When `ohos-sdr-to-hdr` is
`pq` or `hlg`, VPE is bypassed even if `ohos-super-resolution=yes`. Changing
SDR-to-HDR recreates the video output so an existing VPE chain is removed;
turning it off allows the requested super resolution setting to apply again.

`--ohos-super-resolution=yes` enables VPE detail enhancement at fixed HIGH
quality. The default is `no`. There are no selectable quality levels. The same
option covers direct OHCodec Surface output, GPU hardware decoding, and software
decoding, including both OpenGL and Vulkan GPU contexts. GPU processing enhances
the rendered output; direct decoding feeds the VPE input Surface before display.
Direct-mode subtitles remain on their separate OSD Surface.

Changing the option recreates the video output and decoder through mpv's normal
VO update path, restoring the current playback position. The VPE input remains
alive until its producer is released. Unsupported initialization uses normal
output; asynchronous processing errors switch the live option off and rebuild
normal output. Logs use the `[SuperResolution]` prefix. Device support and visual
quality require on-device testing; VPE is not guaranteed to match AVPlayer's SR.

VPE output callbacks enqueue buffer tokens for an application-owned worker;
they never call back into VPE rendering. Once frame submission begins, missing
the first output for three seconds requests normal output and wakes the VO.
This guard does not count file loading time or require performance statistics.
Successful buffer submission is logged once; it does not prove physical display.

`scripts/verify-vpe-adapter.sh` exercises initialization failures, fixed HIGH
quality, output callbacks, resize, fallback, and failed vendor destruction.
`verify.sh` requires the final binary to include the option and VPE dependency.

## Runtime performance diagnostics

The performance patches add debug-level `[Perf]` records for packet/frame calls,
OHCodec queue waits and policy changes, direct Surface submission and OSD work,
and OHAudio hardware-clock queries/underflows. Request `debug` through
`mpv_request_log_messages()` to enable them and `info` to disable them without
rebuilding or restarting the core. FFmpeg instrumentation follows the decoder's
runtime log level via `avcodec_ohcodec_set_diagnostics()`; no audio callback logs
or per-callback timing counters are introduced. `verify.sh` checks the markers
in the built library.

The SweetVideo bridge adds 250ms property summaries and a hidden `mpvDiagnostics`
boolean Want parameter, with separate bounded frame-log and ordinary-log budgets.
New instrumentation requires one updated core build; subsequent toggles are
runtime-only. API call timings measure host-side work and waiting, not physical
screen presentation or hardware execution time. Missing/limited log records
must not be interpreted as dropped video frames.

## Automatic OHCodec playback policy

Both OHCodec output paths automatically pass the source frame rate to the
decoder and request decoder-side variable refresh rate support. Playback-speed
changes are forwarded internally to OHCodec: on systems exposing the API 26
smart-fluency keys, Configure first requests ADAPTIVE (and a valid 1x speed) to
prepare hardware motion-vector output. Before submitting packets, normal/slow
playback restores FULL; speeds above 1x use ADAPTIVE. Preroll and timestamp
repair always preserve full frames. Only a parameter/format rejection triggers
an initialization retry without smart-fluency keys: first Reset the same decoder,
and recreate it once only if Reset fails. A failed baseline retry or memory,
service/state error is handled as a decoder error, not a feature-support verdict.
VRR is independent: Configure contains no VRR key; the first decoder-thread
policy update after Start sends the requested VRR state via SetParameter.

The internal `ohos-vrr` boolean (default yes) lets an embedding application
disable decoder VRR analysis when a visible, non-empty danmaku overlay is
enabled, and restore it when the overlay is disabled/hidden. It is set before
decoder creation and updated on the decoder thread without a seek or restart.
SweetVideo follows its existing danmaku state; no additional UI setting or
N-API symbol is required. Older libmpv builds without this hook keep playing.

Policy results are emitted automatically with the `[OHCodecPolicy]` prefix at
warning level so hosts using the default mpv warning log level can diagnose the
feature without a user-facing setting. A successful decoder request reports
`vrr=requested ... set-parameter=0` with `mode=direct-surface` or `mode=gpu-buffer`;
smart fluency reports `smart-fluency=adaptive ... set-parameter=ok` and reports
`smart-fluency=full` when playback returns to 1x. `smart-fluency=prepared` means
MV output was requested at initialization, not proof the hardware supplies MV.
Dynamic VRR logs report `requested`/`disabled` and the platform result, never
claim that the display rate changed. Parameter rejection stops updates only for
the corresponding enhancement: smart fluency requests FULL, and a rejected VRR
enable makes one best-effort off request. Neither resets nor recreates a running
decoder. If FULL cannot be restored, or an API returns a memory/service/state
error, the existing decode error path is used instead of assuming normal frames.
A failed FULL restoration blocks further frame output until context recreation;
it does not run an unbounded parameter-retry loop. VRR initialization/re-enable
also preserves the existing preroll decode-rate floor.
A rejected VRR off keeps the last known applied state in the log; it is never
reported as successfully disabled. Current official VRR documentation only
guarantees hardware-decoded direct presentation. Retaining a request in the GPU
buffer path does not establish that final display presentation benefits from it.

See Huawei's [smart fluency guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/video-smart-fluency-decoding)
and [VRR guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/video-variable-refreshrate).

The API 26 SDK declarations and official `OH_FrameRetentionMode` values are
used at compile time, while optional metadata-key symbols are resolved with
`dlsym` and are never hard-linked. Older HarmonyOS releases therefore keep the
normal playback path without requiring an application target-SDK change or
user-facing settings.

The build also adds:

- AVS+ / AVS1-P16 software decoding through FFmpeg's `cavs` decoder
- DVD navigation and CSS support (`libdvdnav`, `libdvdread`, `libdvdcss`)
- Blu-ray support (`libbluray`)
- archive/ISO9660 support (`libarchive`)
- an ISO9660 file lookup fallback when a DVD image has unreadable UDF metadata
- a fix for calculating the combined size of split VOB/AOB title files

The optical-media dependencies are linked statically into `libmpv.so`.
Enabling libdvdnav and libdvdcss changes the resulting combined work to GPL.

AVS+ support is based on the public
[`ffmpeg_cavs_dra`](https://github.com/maliwen2015/ffmpeg_cavs_dra)
implementation pinned in `download/deps-version.sh`. The build imports only
its `libcavs` video decoder files into FFmpeg 8.1.2; the DRA audio decoder is
not included. mpv selects the resulting `cavs` decoder automatically for CAVS
streams, including AVS1-P16 broadcast TS files, with no player-side option.

The output follows the current `mpv-arkts` native ABI. It does not restore the
old SweetVideo buffer-overlay renderer; the new OSD plane uses mpv's current
libass/OSD bitmap pipeline.

`libdvdcss` is included for CSS-encrypted DVDs. Blu-ray navigation is included,
but BD-J, `libaacs` and `libbdplus` are not; encrypted Blu-ray images therefore
still require an external decryption solution.

OHAudio translates the hardware CLOCK_MONOTONIC timestamp into mpv's timebase
before calculating queued audio. A coherent atomic snapshot lets the audio
callback read clock updates without waiting for the background query thread.
Audio callbacks have no performance timing counters or periodic statistics;
clock availability and AudioSuite errors are reported on state changes by the
background thread. The patch stage tests timestamp conversion, stale samples,
stream epochs, and concurrent snapshot publication on the build host.
After start/seek, a hardware sample that still reports zero played frames is
treated as stationary. Its cached timestamp must not be extrapolated into
fictional playback progress, followed by a video wait when the hardware clock
starts advancing. Normal interpolation resumes at the first positive frame
position. The `audio-clock` diagnostic includes `zeroHold` for this state, and
the patch stage tests stale zero samples and normal advancing samples.

OHAudio PCM playback tracks each queued audio frame's actual speed and timestamp.
Both the playback clock and video scheduling use this timeline when a speed
change leaves old- and new-speed audio in the output queue. This avoids clock
jumps on acceleration and restoration without flushing buffered audio. Missing
timestamps and unavailable history retain mpv's existing timing fallback. The
patch stage runs regression tests for both speed-change directions, rapid
switching, timestamp gaps, and bounded history.

Runtime debug diagnostics include `[Perf] audio-timeline` every 250 ms. OHCodec
queue/policy diagnostics use FFmpeg's verbose level, which maps to mpv debug,
so the existing hidden diagnostics switch also enables these records.

Decoder throughput now stays high until queued faster audio has drained when
speed is restored. Video sync projections and frame durations also follow the
queued timeline, avoiding false frame-drop requests during transitions.
OHCodec starts background font preparation for the built-in OSD and first
external ASS overlay. Video does not wait for these font scans. Until fonts
are ready, text overlays are deferred and incoming overlay content is retained;
size queries use provisional metrics. The worker uses a private OSD/config
snapshot, then transfers independently owned renderers under a short lock.
OSD destruction joins the worker before releasing its global context.
Additional external overlays retain their normal on-demand setup.
Debug records `osd-font-async`, `osd-font-preload async-ready`, `font-setup`,
and `osd-font-reuse` distinguish preparation from display. The patch stage
tests that a blocked font provider does not block startup or the playback OSD
lock, and checks renderer ownership with and without a pending overlay.

## Experimental E-AC3 passthrough

The optional `ohaudio-eac3` backend is disabled by default. Applications must
set `ohaudio-eac3-enabled=yes` before requesting `audio-spdif=eac3`. Only complete
48 kHz E-AC3 access units are accepted; the active route must report bitstream
support. Missing capability APIs, initialization errors, route changes and
transport errors fall back to PCM. Capability functions are resolved dynamically
from `libohaudio.so`; no additional system library dependency is introduced.
FFmpeg's `spdif` muxer is enabled for this path. Ordinary OHAudio rejects
compressed formats instead of treating them as PCM.

This is an unverified experimental transport, not a device compatibility claim.
Its raw E-AC3 callback framing and timestamp assumptions still require vendor or
device confirmation. See [scope, assumptions and device checks](tests/audio-passthrough-integration.md).
The patch stage runs `scripts/verify-ohaudio-eac3.sh`; packet tests and local
compilation do not establish actual receiver passthrough.

## Experimental USB exclusive audio

`ao=usb-exclusive` accepts a USBManager-authorized descriptor using
`usb-exclusive-fd`. It bypasses OHAudio/system mixing and never changes system
volume. Supported UAC1/UAC2 DACs negotiate the source rate with lossless integer
PCM packing; unsupported formats stop rather than resample. `ao-volume` controls
the DAC's master Feature Unit where available.

`audio-spdif=dop` plus `usb-exclusive-dsd-mode=dop` preserves raw DSD, DST and
DSD WavPack as DoP; the DAC must explicitly support DoP. The legacy
`usb-exclusive-dop=yes` option remains compatible. `audio-spdif=native-dsd` plus
`usb-exclusive-dsd-mode=native` enables experimental native U32 DSD for known
USB device IDs/alternate settings (including the listed XMOS devices and known
Amanero firmware revisions). Unknown devices/revisions are rejected. This does
not implement every vendor-specific mode switch or U8/U16 native transport.
DST/WavPack use an opt-in FFmpeg `dsd_raw` decoder option; normal playback keeps
its existing PCM decoder output. Compressed DSD is unpacked losslessly before
DoP/native framing, without a DSD-to-PCM step. PCM WavPack remains PCM.
The current implementation supports mono
and stereo integer PCM, direct UAC2 clocks and explicit asynchronous feedback;
float decoded audio, implicit feedback and complex clock topologies are rejected.

The application must probe backend options before opening USB output, disable
effects/rate conversion, retain its authorized descriptor during playback, and
keep normal AVSession/background playback management. No additional system
shared-library dependency is introduced. USBManager availability does not imply
usbfs transfer permission on every commercial device.

See [USB acceptance tests and limitations](tests/usb-audio-integration.md).
The patch stage runs host-only DST/WavPack byte-exact decoder tests in a separate
temporary build; target build caches and dependency versions are not changed.
Protocol tests and cross-compilation do not establish bit-perfect device playback
or screen-off reliability; both require real DAC testing.

## Default GPU optimizations

`zz-maleoon-artcnn-workgroup.patch` detects Maleoon from the actual GLES renderer
or Vulkan device name. Opted-in ArtCNN assets use 8x8 (64-thread) workgroups on
supported devices, retaining the output-block/invocation ratio, shared barriers,
coefficients and original FP16-extension/FP32 fallback. Unmarked custom shaders
and non-Maleoon devices retain their original metadata. Assets opt in with an
ordinary `// @sweetvideo-maleoon-artcnn-8x8` GLSL comment in each compute body;
older libraries accept the assets unchanged, but do not apply the optimization.
No new platform library or UI setting is introduced. The patch stage runs a
host-only policy/output-coverage test; this does not establish faster device
rendering or pixel-equivalent GPU output.

The matching SweetVideo native wrapper enables the existing gpu-next disk cache
in the application's private cache directory, applies a validated shader list in
one property update and skips unchanged lists. Its danmaku renderer uploads one
vertex batch per frame, packs bounded atlases with extruded gutters, and merges
adjacent draws only (preserving transparent sprite order). See
[GPU acceptance and audit](tests/maleoon-gpu-acceptance.md) before making
performance claims. Native wrapper/application changes live in SweetVideo and
its libmpvnative submodule, not in this build repository.

## Build Dependencies

- git
- make
- python3
- pkg-config
- gperf
- meson

ohos sdk is automatically downloaded on Linux / WSL, but you need to manually download DevEco Studio on your mac.

## Build

Secondary subtitle positioning uses `secondary-sub-pos`. The downstream
`secondary-sub-scale` option independently scales text/ASS and bitmap secondary
subtitles without following the primary `sub-scale`. SweetVideo's independent
secondary size controls require a library rebuilt with this patch; updating
only `libmpvnative.so` is insufficient. `patch.sh` checks the source and
`verify.sh` checks that the option is included in the resulting library.

```shell
chmod +x *.sh */*.sh
./bundle.sh
```

`bundle.sh` validates the enabled mpv features, public libmpv API,
static optical-media linkage, dynamic dependencies, and SHA-256 before creating
`libmpv/arm64-build/libmpv_aarch64.zip`.
