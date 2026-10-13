#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.."; pwd)
MPV_SOURCE=${MPV_SOURCE:-$ROOT/libmpv/mpv}
grep -Fq '"secondary-sub-scale", OPT_FLOAT(secondary_sub_scale)' "$MPV_SOURCE/options/options.c"
grep -Fq '.secondary_sub_scale = 1.0' "$MPV_SOURCE/options/options.c"
grep -Fq 'float secondary_sub_scale;' "$MPV_SOURCE/options/options.h"
for source in sub/sd_ass.c sub/sd_lavc.c; do
    grep -Fq 'sd->order == 1 ? shared_opts->secondary_sub_scale :' "$MPV_SOURCE/$source"
done
echo 'Independent secondary subtitle scale source checks passed'
