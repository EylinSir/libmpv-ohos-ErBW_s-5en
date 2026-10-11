/* SPDX-License-Identifier: LGPL-2.1-or-later */
// Compile the actual patched policy/setters against a recording OHCodec API.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <stdio.h>
#define AVERROR(e) (-(e))
#define AVERROR_UNKNOWN (-2000)
#define AV_LOG_VERBOSE 1
#define AV_LOG_WARNING 2
#define AV_LOG_ERROR 3
#define AV_ERR_OK 0
#define AV_ERR_NO_MEMORY 1
#define AV_ERR_OPERATE_NOT_PERMIT 2
#define AV_ERR_INVALID_VAL 3
#define AV_ERR_TIMEOUT 5
#define AV_ERR_UNKNOWN 6
#define AV_ERR_SERVICE_DIED 7
#define AV_ERR_INVALID_STATE 8
#define AV_ERR_UNSUPPORT 9
#define AV_ERR_UNSUPPORTED_FORMAT 11
#define AV_HWDEVICE_TYPE_OHCODEC 1
#define AV_PIXEL_FORMAT_NV12 1
#define AV_PIXEL_FORMAT_SURFACE_FORMAT 2
#define OH_MD_KEY_WIDTH "width"
#define OH_MD_KEY_HEIGHT "height"
#define OH_MD_KEY_PIXEL_FORMAT "pixel-format"
typedef int OH_AVErrCode;
typedef void OHNativeWindow;
typedef struct {int type; void *hwctx;} AVHWDeviceContext;
typedef struct {OHNativeWindow *native_window; bool direct_surface;} AVOHCodecDeviceContext;
typedef struct {void *data;} AVBufferRef;
typedef enum { OH_FRAME_RETENTION_MODE_FULL,
               OH_FRAME_RETENTION_MODE_ADAPTIVE } OH_FrameRetentionMode;
typedef struct { double fps, speed; int retention, vrr; } OH_AVFormat;
typedef struct {
    double source_frame_rate, requested_playback_speed;
    bool playback_policy_pending, preroll, preserve_frames;
    bool smart_fluency_failed, smart_fluency_active, diagnostics_enabled;
    bool smart_fluency_prepared, direct_surface_output, vrr_pending, vrr_failed;
    bool output_to_window;
    int vrr_enabled, vrr_applied;
    int full_restore_error;
    int64_t policy_requested_ns;
    void *dec;
    void *dec_ref;
    struct {const char *frame_rate, *retention_mode, *decoder_speed, *enable_vrr;} keys;
} OHCodecDecContext;
typedef struct {const char *wrapper_name;} AVCodec;
typedef struct {
    const AVCodec *codec; void *priv_data; int codec_id;
    int width, height;
    AVBufferRef *hw_device_ctx;
} AVCodecContext;
static OH_AVFormat format, applied, configured[4];
static int calls, result;
static int parameter_results[4], parameter_count, parameter_index;
static int configure_results[4], configure_count, reset_calls, reset_result;
static int recreate_calls, recreate_result, unref_calls;
static bool allocation_failed;
static bool setter_failed;
static bool supported = true;
static int64_t oh_decode_perf_time_ns(void) { return 1000; }
static bool oh_decode_supports_smart_fluency(AVCodecContext *c) { (void)c; return supported; }
static const char *avcodec_get_name(int id) { (void)id; return "hevc"; }
static const char *av_hwdevice_get_type_name(int id) { (void)id; return "ohcodec"; }
static const char *av_err2str(int error) { (void)error; return "test-error"; }
static int ff_oh_err_to_ff_err(OH_AVErrCode error)
{
    if (error==AV_ERR_OK) return 0;
    if (error==AV_ERR_NO_MEMORY) return AVERROR(ENOMEM);
    return -1000-error;
}
static void av_log(void *c, int level, const char *fmt, ...)
{ (void)c; (void)level; (void)fmt; }
static OH_AVFormat *OH_AVFormat_Create(void)
{ format = (OH_AVFormat){.retention = -1, .vrr = -1}; return allocation_failed ? NULL : &format; }
static void OH_AVFormat_Destroy(OH_AVFormat *f) { (void)f; }
static bool OH_AVFormat_SetDoubleValue(OH_AVFormat *f, const char *k, double v)
{ if (setter_failed) return false; if (!strcmp(k,"fps")) f->fps=v; else f->speed=v; return true; }
static bool OH_AVFormat_SetIntValue(OH_AVFormat *f, const char *k, int v)
{ if (setter_failed) return false; if (!strcmp(k,"vrr")) f->vrr=v; else if (!strcmp(k,"retention")) f->retention=v; return true; }
static OH_AVErrCode OH_VideoDecoder_SetParameter(void *d, OH_AVFormat *f)
{
    (void)d; applied=*f; calls++;
    return parameter_index < parameter_count ? parameter_results[parameter_index++] : result;
}
static OH_AVErrCode OH_VideoDecoder_Configure(void *d, OH_AVFormat *f)
{
    (void)d;
    assert(configure_count < 4);
    configured[configure_count]=*f;
    return configure_results[configure_count++];
}
static OH_AVErrCode OH_VideoDecoder_Reset(void *d)
{ assert(d); reset_calls++; return reset_result; }
static OH_AVErrCode OH_VideoDecoder_SetSurface(void *d, OHNativeWindow *w)
{ (void)d; (void)w; return AV_ERR_OK; }
static void av_refstruct_unref(void **ref)
{ assert(*ref); *ref=NULL; unref_calls++; }
static int oh_decode_create(OHCodecDecContext *s, AVCodecContext *c)
{
    (void)c; recreate_calls++;
    if (recreate_result < 0) return recreate_result;
    s->dec=s->dec_ref=&applied;
    return 0;
}
#include "ohcodec-decode-hints.inc"

static void test_initialization(void)
{
    const AVCodec codec={.wrapper_name="ohcodec"};
    const int errors[]={AV_ERR_OK, AV_ERR_INVALID_VAL, AV_ERR_UNSUPPORT,
        AV_ERR_UNSUPPORTED_FORMAT, AV_ERR_NO_MEMORY, AV_ERR_SERVICE_DIED,
        AV_ERR_INVALID_STATE, AV_ERR_UNKNOWN, AV_ERR_OPERATE_NOT_PERMIT};
    for (unsigned i=0; i<sizeof(errors)/sizeof(errors[0]); i++) {
        OHCodecDecContext s={.dec=&format, .dec_ref=&format, .source_frame_rate=60,
            .requested_playback_speed=1, .vrr_enabled=1, .vrr_pending=true,
            .keys={"fps","retention","speed","vrr"}};
        AVCodecContext c={.codec=&codec, .priv_data=&s, .width=1920, .height=1080};
        memset(configure_results, 0, sizeof(configure_results));
        configure_results[0]=errors[i];
        configure_count=reset_calls=recreate_calls=unref_calls=0;
        reset_result=recreate_result=0;
        int ret=oh_decode_set_format(&s, &c, true);
        assert(configured[0].retention==OH_FRAME_RETENTION_MODE_ADAPTIVE);
        assert(configured[0].speed==1 && configured[0].vrr==-1);
        assert(!s.vrr_failed && s.vrr_pending);
        assert(recreate_calls==0 && unref_calls==0 && s.dec==&format);
        if (oh_decode_policy_rejected(errors[i])) {
            assert(ret==0 && reset_calls==1 && configure_count==2);
            assert(configured[1].retention==-1 && configured[1].vrr==-1);
            assert(!s.smart_fluency_prepared && s.smart_fluency_failed);
        } else if (errors[i]==AV_ERR_OK) {
            assert(ret==0 && reset_calls==0 && configure_count==1);
            assert(s.smart_fluency_prepared && s.smart_fluency_active);
        } else {
            assert(ret<0 && reset_calls==0 && configure_count==1);
            assert(!s.smart_fluency_failed); // Not misreported as unsupported.
        }
    }
    for (int baseline_fails=0; baseline_fails<2; baseline_fails++) {
        OHCodecDecContext s={.dec=&format, .dec_ref=&format, .source_frame_rate=60,
            .keys={"fps","retention","speed","vrr"}};
        AVCodecContext c={.codec=&codec, .priv_data=&s, .width=1920, .height=1080};
        configure_results[0]=AV_ERR_INVALID_VAL;
        configure_results[1]=baseline_fails ? AV_ERR_INVALID_VAL : AV_ERR_OK;
        configure_count=reset_calls=recreate_calls=unref_calls=0;
        reset_result=AV_ERR_UNKNOWN;
        int ret=oh_decode_set_format(&s, &c, true);
        assert(reset_calls==1 && recreate_calls==1 && unref_calls==1 && configure_count==2);
        assert(baseline_fails ? ret<0 : ret==0);
        assert(s.smart_fluency_failed==!baseline_fails); // Baseline failure is not a feature verdict.
    }
    OHCodecDecContext s={.dec=&format, .dec_ref=&format,
        .keys={"fps","retention","speed","vrr"}};
    AVCodecContext c={.codec=&codec, .priv_data=&s, .width=1920, .height=1080};
    configure_results[0]=AV_ERR_INVALID_VAL;
    configure_count=reset_calls=recreate_calls=unref_calls=0;
    recreate_result=AVERROR(ENOMEM);
    assert(oh_decode_set_format(&s, &c, true)==AVERROR(ENOMEM));
    assert(configure_count==1 && reset_calls==1 && recreate_calls==1);
    // A local format-builder failure is not proof of unsupported decoder keys.
    s.dec=s.dec_ref=&format;
    configure_count=reset_calls=recreate_calls=unref_calls=0;
    setter_failed=true;
    assert(oh_decode_set_format(&s, &c, true)==AVERROR_UNKNOWN);
    assert(configure_count==0 && reset_calls==0 && recreate_calls==0);
    setter_failed=false;
    reset_calls=recreate_calls=unref_calls=0;
    reset_result=recreate_result=0;
}

static void test_runtime_errors(void)
{
    const AVCodec codec={.wrapper_name="ohcodec"};
    const int faults[]={AV_ERR_NO_MEMORY, AV_ERR_SERVICE_DIED, AV_ERR_INVALID_STATE,
        AV_ERR_UNKNOWN, AV_ERR_TIMEOUT, AV_ERR_OPERATE_NOT_PERMIT};
    for (unsigned i=0; i<sizeof(faults)/sizeof(faults[0]); i++) {
        OHCodecDecContext s={.dec=&format, .source_frame_rate=60, .requested_playback_speed=2,
            .smart_fluency_prepared=true, .playback_policy_pending=true,
            .vrr_pending=true, .vrr_enabled=1, .vrr_applied=-1,
            .keys={"fps","retention","speed","vrr"}};
        AVCodecContext c={.codec=&codec, .priv_data=&s};
        result=faults[i];
        assert(oh_decode_update_playback_policy(&c)<0 && !s.smart_fluency_failed);
        assert(oh_decode_update_vrr_policy(&c)<0 && !s.vrr_failed);
        assert(reset_calls==0 && recreate_calls==0);
    }
    OHCodecDecContext s={.dec=&format, .source_frame_rate=60, .requested_playback_speed=2,
        .smart_fluency_prepared=true, .smart_fluency_active=true,
        .playback_policy_pending=true, .vrr_pending=true, .vrr_enabled=1, .vrr_applied=-1,
        .keys={"fps","retention","speed","vrr"}};
    AVCodecContext c={.codec=&codec, .priv_data=&s};
    parameter_count=2; parameter_index=0;
    parameter_results[0]=AV_ERR_INVALID_VAL; parameter_results[1]=AV_ERR_OK;
    assert(oh_decode_update_playback_policy(&c)==0);
    assert(s.smart_fluency_failed && !s.smart_fluency_active && !s.vrr_failed);
    assert(applied.retention==OH_FRAME_RETENTION_MODE_FULL && applied.fps==0);
    parameter_index=0;
    assert(oh_decode_update_vrr_policy(&c)==0);
    assert(s.vrr_failed && s.vrr_applied==0 && applied.vrr==0);
    assert(reset_calls==0 && recreate_calls==0);
    // If FULL cannot be restored, don't claim dropping stopped or continue repair.
    s.smart_fluency_failed=false; s.smart_fluency_active=true; s.playback_policy_pending=true;
    parameter_index=0; parameter_results[1]=AV_ERR_INVALID_VAL;
    assert(oh_decode_update_playback_policy(&c)<0 && s.smart_fluency_active);
    assert(s.full_restore_error<0); // Later receive calls cannot resume unsafe frames.
    // If optional VRR off is rejected, retain the last known state, without a restart.
    s.vrr_failed=false; s.vrr_applied=1; s.vrr_enabled=0; s.vrr_pending=true;
    parameter_index=0;
    assert(oh_decode_update_vrr_policy(&c)==0 && s.vrr_failed && s.vrr_applied==1);
    assert(reset_calls==0 && recreate_calls==0);
    parameter_count=parameter_index=0; result=AV_ERR_OK;
    // A VRR enable must not overwrite the 120fps preroll performance hint.
    s.full_restore_error=0; // Independent healthy-context scenario.
    s.vrr_failed=false; s.vrr_enabled=1; s.vrr_pending=true; s.preroll=true;
    s.smart_fluency_active=false;
    assert(oh_decode_update_vrr_policy(&c)==0 && s.playback_policy_pending);
    assert(oh_decode_update_playback_policy(&c)==0 && applied.fps==120);
    allocation_failed=true;
    s.vrr_failed=false; s.vrr_pending=true;
    assert(oh_decode_update_vrr_policy(&c)==AVERROR(ENOMEM) && !s.vrr_failed);
    allocation_failed=false;
    setter_failed=true;
    s.vrr_pending=true;
    assert(oh_decode_update_vrr_policy(&c)<0 && !s.vrr_failed);
    setter_failed=false;
}

int main(void)
{
    test_initialization();
    test_runtime_errors();
    calls=0;
    const AVCodec codec = {.wrapper_name="ohcodec"};
    OHCodecDecContext s = {.source_frame_rate=25, .requested_playback_speed=1,
        .dec=&format, .smart_fluency_prepared=true,
        .keys={"fps","retention","speed","vrr"}};
    AVCodecContext c = {.codec=&codec, .priv_data=&s};
    // Configure must request MV at 1x; runtime immediately restores FULL.
    OH_AVFormat *initial = OH_AVFormat_Create();
    assert(oh_decode_prepare_smart_fluency(&s, &c, initial));
    assert(initial->retention==OH_FRAME_RETENTION_MODE_ADAPTIVE && initial->speed==1);
    s.smart_fluency_active=true;
    s.playback_policy_pending=true;
    oh_decode_update_playback_policy(&c);
    assert(!s.smart_fluency_active && applied.retention==OH_FRAME_RETENTION_MODE_FULL);
    avcodec_ohcodec_set_playback_speed(&c, 0.5);
    oh_decode_update_playback_policy(&c);
    assert(!s.smart_fluency_active && applied.fps==25);
    avcodec_ohcodec_set_playback_speed(&c, 1.0);
    oh_decode_update_playback_policy(&c);
    calls=0;
    // Long resume: raise decoding demand, retain every frame, keep 1x media.
    assert(avcodec_ohcodec_set_decode_hints(&c, 1, 1) == 0);
    oh_decode_update_playback_policy(&c);
    assert(calls==1 && applied.fps==120 && !s.smart_fluency_active);
    assert(s.requested_playback_speed==1);
    for (int i=0; i<208; i++) {
        avcodec_ohcodec_set_decode_hints(&c, 1, 1);
        oh_decode_update_playback_policy(&c);
    }
    assert(calls==1); // No platform call per preroll frame.
    avcodec_ohcodec_set_decode_hints(&c, 0, 1);
    oh_decode_update_playback_policy(&c);
    assert(applied.fps==25 && calls==2);
    // Repair must not accidentally lose frames when the user holds 2x.
    avcodec_ohcodec_set_playback_speed(&c, 2);
    oh_decode_update_playback_policy(&c);
    assert(applied.fps==50 && !s.smart_fluency_active);
    // Normal media retains the previous adaptive-speed behavior.
    avcodec_ohcodec_set_decode_hints(&c, 0, 0);
    oh_decode_update_playback_policy(&c);
    assert(s.smart_fluency_active && applied.retention==OH_FRAME_RETENTION_MODE_ADAPTIVE);
    avcodec_ohcodec_set_decode_hints(&c, 1, 0);
    oh_decode_update_playback_policy(&c);
    assert(!s.smart_fluency_active && applied.retention==OH_FRAME_RETENTION_MODE_FULL);
    assert(applied.fps==120);
    avcodec_ohcodec_set_decode_hints(&c, 0, 0);
    oh_decode_update_playback_policy(&c);
    assert(s.smart_fluency_active && applied.fps==50);
    // A high source/playback rate must never be reduced by the preroll floor.
    s.source_frame_rate=120;
    avcodec_ohcodec_set_decode_hints(&c, 1, 0);
    oh_decode_update_playback_policy(&c);
    assert(applied.fps==240);
    // Unsupported codecs/keys and rejected hints do not fail decoding.
    assert(avcodec_ohcodec_set_decode_hints(NULL, 1, 0)==AVERROR(ENOSYS));
    const AVCodec software = {0};
    c.codec=&software;
    assert(avcodec_ohcodec_set_decode_hints(&c, 1, 0)==AVERROR(ENOSYS));
    c.codec=&codec;
    s.keys.retention_mode=NULL; s.keys.decoder_speed=NULL;
    result=AV_ERR_INVALID_VAL;
    avcodec_ohcodec_set_decode_hints(&c, 0, 1);
    oh_decode_update_playback_policy(&c);
    assert(!s.playback_policy_pending);
    // Dynamic VRR is independent of smart fluency and decoder output path.
    result=AV_ERR_OK;
    s.vrr_enabled=1; s.vrr_applied=1;
    s.source_frame_rate=60; s.requested_playback_speed=2;
    int before=calls;
    assert(avcodec_ohcodec_set_vrr_enabled(&c, 0)==0);
    oh_decode_update_vrr_policy(&c);
    assert(calls==before+1 && applied.vrr==0 && applied.fps==0 && s.vrr_applied==0);
    avcodec_ohcodec_set_vrr_enabled(&c, 0);
    oh_decode_update_vrr_policy(&c);
    assert(calls==before+1); // No per-frame/per-monitor platform requests.
    avcodec_ohcodec_set_vrr_enabled(&c, 1);
    oh_decode_update_vrr_policy(&c);
    assert(applied.vrr==1 && applied.fps==120 && s.vrr_applied==1);
    s.source_frame_rate=0;
    avcodec_ohcodec_set_vrr_enabled(&c, 0);
    oh_decode_update_vrr_policy(&c);
    assert(applied.vrr==0); // Disabling works even without source fps.
    before=calls;
    avcodec_ohcodec_set_vrr_enabled(&c, 1);
    oh_decode_update_vrr_policy(&c);
    assert(calls==before && s.vrr_applied==0); // Unknown fps never enables VRR.
    s.source_frame_rate=60;
    s.keys.enable_vrr=NULL;
    s.vrr_pending=true;
    oh_decode_update_vrr_policy(&c);
    assert(calls==before);
    s.keys.enable_vrr="vrr";
    s.vrr_pending=true;
    result=AV_ERR_INVALID_VAL;
    oh_decode_update_vrr_policy(&c);
    assert(s.vrr_failed && s.vrr_applied==0 && !s.smart_fluency_failed);
    before=calls;
    s.vrr_pending=true;
    oh_decode_update_vrr_policy(&c);
    assert(calls==before); // Unsupported runtime request safely stops retrying.
    assert(avcodec_ohcodec_set_vrr_enabled(NULL, 0)==AVERROR(ENOSYS));
    c.codec=&software;
    assert(avcodec_ohcodec_set_vrr_enabled(&c, 0)==AVERROR(ENOSYS));
    c.codec=&codec;
    s.keys.retention_mode="retention"; s.keys.decoder_speed="speed";
    supported=false;
    assert(!oh_decode_prepare_smart_fluency(&s, &c, OH_AVFormat_Create()));
    supported=true;
    s.keys.decoder_speed=NULL;
    assert(!oh_decode_prepare_smart_fluency(&s, &c, OH_AVFormat_Create()));
    puts("OHCodec Reset-first configuration, independent VRR and runtime fault tests passed");
    return 0;
}
