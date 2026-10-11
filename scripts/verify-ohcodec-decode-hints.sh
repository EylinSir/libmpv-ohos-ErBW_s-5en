#!/bin/bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.."; pwd)
CHECK_DIR="$ROOT_DIR/libmpv/ohcodec-decode-hints-test"
mkdir -p "$CHECK_DIR"
python3 - "$ROOT_DIR/libmpv/ffmpeg/libavcodec/ohdec.c" "$CHECK_DIR/ohcodec-decode-hints.inc" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
configure = source[source.index('static int oh_decode_set_format'):source.index('static void oh_decode_on_err')]
assert configure.index('oh_decode_prepare_smart_fluency') < configure.index('OH_VideoDecoder_Configure')
assert 's->smart_fluency_active = smart_prepared;' in configure
assert 'smart_prepared && oh_decode_policy_rejected(err)' in configure
assert 'oh_decode_reset_for_policy_retry(s, avctx)' in configure
assert 's->vrr_failed = true' not in configure
assert 's->keys.enable_vrr' not in configure
assert 'oh_decode_set_format(s, avctx, false)' in configure
assert 'oh_decode_set_format(s, avctx, true)' in source
assert 's->vrr_applied = -1;' in source and 's->vrr_pending = true;' in source
receive = source[source.index('static int oh_decode_receive_frame'):source.index('static void oh_decode_flush')]
assert 'if (policy_ret < 0)' in receive
assert 'oh_decode_update_vrr_policy(avctx)' in receive
assert 'if (s->full_restore_error < 0)' in receive
assert receive.index('oh_decode_update_vrr_policy') < receive.index('oh_decode_update_playback_policy')
assert 'full_restore_error' not in source[source.index('static void oh_decode_flush'):source.index('int avcodec_ohcodec_set_playback_speed')]
root = pathlib.Path(sys.argv[1]).parents[2]
vd = (root / 'mpv/video/decode/vd_lavc.c').read_text()
assert vd.index('"ohcodec_vrr", mpopts->ohos_vrr') < vd.index('avcodec_open2(avctx, lavc_codec')
assert 'avcodec_ohcodec_set_vrr_enabled(ctx->avctx, *(bool *)arg)' in vd
command = (root / 'mpv/player/command.c').read_text()
assert 'opt_ptr == &opts->ohos_vrr' in command
assert 'VDCTRL_SET_VRR_ENABLED' in command
functions = []
for name in ('oh_decode_prepare_smart_fluency', 'oh_decode_policy_rejected',
             'oh_decode_reset_for_policy_retry', 'oh_decode_set_format',
             'oh_decode_policy_error', 'oh_decode_restore_full', 'oh_decode_update_vrr_policy',
             'oh_decode_update_playback_policy', 'avcodec_ohcodec_set_playback_speed',
             'avcodec_ohcodec_set_decode_hints', 'avcodec_ohcodec_set_vrr_enabled'):
    match = re.search(r'^(?:static int|static bool|int) ' + name + r'\([\s\S]+?\n\}\n', source, re.M)
    if not match:
        raise SystemExit('Missing patched function: ' + name)
    functions.append(match.group(0))
pathlib.Path(sys.argv[2]).write_text('\n'.join(functions))
PY
cc -std=c11 -O2 -Wall -Wextra -Werror -I"$CHECK_DIR" \
  "$ROOT_DIR/tests/ohcodec-decode-hints.c" -lm -o "$CHECK_DIR/hints-test"
"$CHECK_DIR/hints-test"
