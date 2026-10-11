# Startup and precise-seek decode demand

The decoder wrapper requests a preroll performance hint before the first
decoded picture and while a forward precise-seek target is pending. On reaching
that target it restores the normal policy. Both normal and repaired video use
the hint. It does not change playback speed, seek accuracy, timestamps, queue
sizes, or frame ownership.

OHCodec receives a frame-rate demand of at least 120 fps during preroll, or the
source rate times playback speed if that is larger. This is a best-effort
platform performance request, not a guaranteed decode throughput. Unsupported
keys or platform rejection retain the existing decode path. Actual startup
latency must be measured on device.

Adaptive frame retention is suppressed during preroll and during the existing
DTS-as-PTS repair candidate/active state. This prevents platform-level dropping
from invalidating the repair's frame count, including when the user selects a
higher playback speed. Normal video still uses the previous adaptive policy
after preroll. Setters deduplicate unchanged hints and platform updates remain
on the decoder thread.

`[Perf] codec-decode-hints` reports the requested frame rate, preroll/full-frame
flags and platform result for rate-only changes. Transitions from adaptive
retention also use the existing codec-policy diagnostics. Existing runtime
diagnostic controls apply.

The host test compiles the actual patched FFmpeg policy/setters against a
recording API. It verifies a 208-frame preroll, restoration, repeated-hint
deduplication, full-frame repair at 2x, normal adaptive playback, high source
rates, unsupported codecs/keys, and platform rejection.

## MV initialization and optional danmaku VRR policy

Configure requests ADAPTIVE plus decoder speed 1.0 on H.264/H.265/H.266 when
both optional keys exist. The runtime FULL policy must be restored before any
packet during normal/slow playback and preroll/repair. Only a suspected parameter
rejection retries Configure without smart-fluency keys, first resetting the same
decoder and recreating it once only if Reset fails. A failed baseline retry is
not called unsupported smart fluency. No callbacks or buffers exist at this point.
Configure never receives a VRR key. VRR is requested independently after Start;
first enable from the default state needs device validation.

The same host test checks preparation/unsupported keys and codecs, restoration
to FULL, VRR disable without an fps value, re-enable with the source frame rate
times effective speed, unchanged-request deduplication, and independent failure
handling. It now compiles the actual Configure and Reset/recreate helper too:
Reset success preserves the instance, Reset failure recreates once, recreation
failure/baseline failure terminates without repeated retries, and memory/service/
state errors never trigger parameter fallback or feature blacklisting.

Runtime tests inject rejected requests with successful FULL/off recovery, rejected
FULL recovery (propagate instead of assuming safe frames), VRR off rejection
(preserve last applied state), and allocation/format-builder/API failures. Runtime
policies never Reset/recreate. Source checks cover initial VRR scheduling, decoder
error propagation, and mpv's initialization/runtime hook. These checks do not
confirm actual MV output or screen refresh rate.

Source checks also verify that a failed FULL restoration remains an error on
subsequent receive calls, and is not cleared by Flush. The host test checks that
enabling VRR during preroll still restores the 120fps performance hint, without
modifying playback speed or timestamps.

Device acceptance (both direct Surface and GPU buffer): toggle a non-empty
danmaku overlay on/off, hide/show the page, enter/leave PiP, switch media and
recreate the playback core. A visible overlay should request VRR off; disabling
or hiding it should restore the request. Empty/disabled overlays do not suppress
VRR. Verify subtitles, OSD, audio sync, precise seeking and old-system fallback.
Only direct presentation is guaranteed by the current official VRR guide;
measure GPU-buffer display behavior separately. A platform OK result is not
proof that refresh rate changed or motion-vector-based selection is active.
