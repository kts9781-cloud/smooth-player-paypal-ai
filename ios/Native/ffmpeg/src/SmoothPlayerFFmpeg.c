#include "SmoothPlayerFFmpeg.h"
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <TargetConditionals.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

struct sp_ff_decoder {
    AVFormatContext *format;
    AVIOContext *io;
    AVIOContext *file_io;
    AVCodecContext *video, *audio;
    AVBufferRef *hardware;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *scale;
    SwrContext *resample, *focus_resample;
    float focus, target_focus;
    int capture_reference, reference_samples;
    uint8_t *focus_bytes, *reference_bytes;
    unsigned focus_capacity, reference_capacity;
    AVChannelLayout input_layout;
    int input_rate, input_format;
    int video_stream, audio_stream, pending, packet_loaded, eof, video_flushed, audio_flushed, audio_resampled;
    int awaiting_video_keyframe;
    int last_video_error;
    int subtitle_stream, subtitle_packet_borrowed;
    uint8_t *video_bytes, *audio_bytes;
    unsigned video_capacity, audio_capacity;
    double origin, next_video_pts, next_audio_pts, seek_target;
    sp_ff_info info;
    void *opaque;
    sp_ff_read_callback read;
    sp_ff_seek_callback seek;
    atomic_int cancelled;
};

static int interrupted(void *opaque) { return atomic_load(&((sp_ff_decoder *)opaque)->cancelled); }
static int open_selected_file(AVFormatContext *format, AVIOContext **io, const char *url,
                              int flags, AVDictionary **options) {
    // A movie may contain external file/playlist references. Only the original
    // user-selected file is authorized; NAS uses the already-authorized custom IO.
    (void)format; (void)io; (void)url; (void)flags; (void)options;
    return AVERROR(EACCES);
}
static int read_io(void *opaque, uint8_t *buffer, int capacity) {
    sp_ff_decoder *d = opaque;
    if (interrupted(d)) return AVERROR_EXIT;
    int result = d->read(d->opaque, buffer, capacity);
    if (interrupted(d)) return AVERROR_EXIT;
    if (result > capacity) return AVERROR(EINVAL);
    return result == 0 ? AVERROR_EOF : result < 0 ? AVERROR(EIO) : result;
}
static int64_t seek_io(void *opaque, int64_t offset, int whence) {
    sp_ff_decoder *d = opaque;
    if (interrupted(d)) return AVERROR_EXIT;
    int64_t result = d->seek(d->opaque, offset, whence & ~AVSEEK_FORCE);
    if (interrupted(d)) return AVERROR_EXIT;
    return result < 0 ? AVERROR(EIO) : result;
}
static enum AVPixelFormat choose_format(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    sp_ff_decoder *d = codec->opaque;
    if (d->hardware) {
        for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(*p);
        if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return AV_PIX_FMT_NONE;
}
static int open_codec(sp_ff_decoder *d, int index, int hardware, AVCodecContext **output) {
    AVStream *stream = d->format->streams[index];
    const AVCodec *codec = stream->codecpar->codec_id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : NULL;
    if (!codec) codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) return AVERROR(ENOMEM);
    int result = avcodec_parameters_to_context(context, stream->codecpar);
    if (result < 0) { avcodec_free_context(&context); return result; }
    context->pkt_timebase = stream->time_base;
    context->thread_count = 4;
    context->max_pixels = 8192LL * 8192;
    context->opaque = d;
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        context->get_format = choose_format;
        if (hardware) {
#if TARGET_OS_IOS && __IPHONE_OS_VERSION_MAX_ALLOWED >= 260200
            // FFmpeg 7.1 registers supplemental VP9 only on macOS. iOS 26.2 added
            // the public opt-in too; without it a supported iPad silently falls
            // back to CPU VP9 decoding and full-resolution BGRA conversion.
            if (stream->codecpar->codec_id == AV_CODEC_ID_VP9) {
                if (__builtin_available(iOS 26.2, *)) {
                    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
                }
            }
#endif
            for (int i = 0;; i++) {
                const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
                if (!config) break;
                if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
                    if (av_hwdevice_ctx_create(&d->hardware, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0)
                        context->hw_device_ctx = av_buffer_ref(d->hardware);
                    break;
                }
            }
        }
    }
    result = avcodec_open2(context, codec, NULL);
    if (result < 0) {
        avcodec_free_context(&context);
        if (hardware && d->hardware) { av_buffer_unref(&d->hardware); return open_codec(d, index, 0, output); }
        return result;
    }
    *output = context;
    return 0;
}

static sp_ff_decoder *open_common(const char *path, void *opaque, sp_ff_read_callback read,
                                  sp_ff_seek_callback seek, int hardware, int audio_only, int *error) {
    int result = AVERROR(EINVAL);
    if (error) *error = result;
    if ((!path || !*path) && (!read || !seek)) return NULL;
    sp_ff_decoder *d = av_mallocz(sizeof(*d));
    if (!d) { if (error) *error = AVERROR(ENOMEM); return NULL; }
    atomic_init(&d->cancelled, 0);
    d->video_stream = d->audio_stream = d->subtitle_stream = -1;
    d->input_format = -1;
    d->seek_target = -1;
    d->opaque = opaque; d->read = read; d->seek = seek;
    av_log_set_level(AV_LOG_QUIET); // Library diagnostics must not expose media URLs or credentials.
    d->format = avformat_alloc_context();
    d->packet = av_packet_alloc(); d->frame = av_frame_alloc();
    if (!d->format || !d->packet || !d->frame) { result = AVERROR(ENOMEM); goto fail; }
    d->format->interrupt_callback = (AVIOInterruptCB){interrupted, d};
    d->format->opaque = d;
    d->format->io_open = open_selected_file;
    // Nested demuxers such as concat create another format context instead of
    // inheriting io_open, but they do inherit this protocol whitelist.
    d->format->protocol_whitelist = av_strdup("none");
    if (!d->format->protocol_whitelist) { result = AVERROR(ENOMEM); goto fail; }
    d->format->probesize = 8 * 1024 * 1024;
    d->format->max_analyze_duration = 5 * AV_TIME_BASE;
    if (read) {
        uint8_t *buffer = av_malloc(64 * 1024);
        if (!buffer) { result = AVERROR(ENOMEM); goto fail; }
        d->io = avio_alloc_context(buffer, 64 * 1024, 0, d, read_io, NULL, seek_io);
        if (!d->io) { av_free(buffer); result = AVERROR(ENOMEM); goto fail; }
        d->format->pb = d->io;
        d->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    } else {
        AVDictionary *options = NULL;
        av_dict_set(&options, "protocol_whitelist", "file", 0);
        result = avio_open2(&d->file_io, path, AVIO_FLAG_READ, &d->format->interrupt_callback, &options);
        av_dict_free(&options);
        if (result < 0) goto fail;
        d->format->pb = d->file_io;
        d->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    }
    result = avformat_open_input(&d->format, path, NULL, NULL);
    if (result < 0) goto fail;
    result = avformat_find_stream_info(d->format, NULL);
    if (result < 0) goto fail;
    d->origin = d->format->start_time == AV_NOPTS_VALUE ? 0 : (double)d->format->start_time / AV_TIME_BASE;
    d->info.duration_seconds = d->format->duration > 0 ? (double)d->format->duration / AV_TIME_BASE : 0;
    d->video_stream = audio_only ? -1 : av_find_best_stream(d->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    d->audio_stream = av_find_best_stream(d->format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (d->video_stream < 0 && d->audio_stream < 0) { result = AVERROR_STREAM_NOT_FOUND; goto fail; }
    if (d->video_stream >= 0) {
        result = open_codec(d, d->video_stream, hardware, &d->video);
        if (result < 0) goto fail;
        AVStream *stream = d->format->streams[d->video_stream];
        d->info.has_video = 1; d->info.width = d->video->width; d->info.height = d->video->height;
        d->info.is_hdr = stream->codecpar->color_trc == AVCOL_TRC_SMPTE2084 ||
                         stream->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67;
        AVRational rate = av_guess_frame_rate(d->format, stream, NULL);
        d->info.frames_per_second = rate.num > 0 && rate.den > 0 ? av_q2d(rate) : 0;
        AVRational aspect = av_guess_sample_aspect_ratio(d->format, stream, NULL);
        d->info.sample_aspect_ratio = aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1;
        const AVPacketSideData *matrix = av_packet_side_data_get(stream->codecpar->coded_side_data,
            stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (matrix && matrix->size >= 9 * sizeof(int32_t)) {
            double rotation = av_display_rotation_get((const int32_t *)matrix->data);
            if (isfinite(rotation)) d->info.rotation_degrees = -rotation;
        }
        snprintf(d->info.video_codec, sizeof(d->info.video_codec), "%s", avcodec_get_name(stream->codecpar->codec_id));
    }
    if (d->audio_stream >= 0) {
        result = open_codec(d, d->audio_stream, 0, &d->audio);
        if (result < 0) goto fail;
        d->info.has_audio = 1; d->info.audio_sample_rate = 48000; d->info.audio_channels = 2;
        snprintf(d->info.audio_codec, sizeof(d->info.audio_codec), "%s", avcodec_get_name(d->audio->codec_id));
    }
    if (error) *error = 0;
    return d;
fail:
    if (error) *error = result;
    sp_ff_close(d);
    return NULL;
}

sp_ff_decoder *sp_ff_open_file(const char *path, int hardware, int *error) { return open_common(path, NULL, NULL, NULL, hardware, 0, error); }
sp_ff_decoder *sp_ff_open_io(void *opaque, sp_ff_read_callback read, sp_ff_seek_callback seek, int hardware, int *error) {
    return open_common(NULL, opaque, read, seek, hardware, 0, error);
}
// Independent audio cursor for manual A/V alignment. Video packets stay compressed
// and are skipped; no second video decoder or additional decoded-frame window.
sp_ff_decoder *sp_ff_open_audio_file(const char *path, int *error) {
    return open_common(path, NULL, NULL, NULL, 0, 1, error);
}
sp_ff_decoder *sp_ff_open_audio_io(void *opaque, sp_ff_read_callback read, sp_ff_seek_callback seek, int *error) {
    return open_common(NULL, opaque, read, seek, 0, 1, error);
}
int sp_ff_get_info(sp_ff_decoder *d, sp_ff_info *info) { if (!d || !info) return AVERROR(EINVAL); *info = d->info; return 0; }
int sp_ff_enhancement_sdr(sp_ff_decoder *d) {
    if (!d || d->video_stream < 0 || d->info.is_hdr) return 0;
    AVStream *st = d->format->streams[d->video_stream];
    AVCodecParameters *par = st->codecpar;
    const int trc = par->color_trc;
    const int sdr = trc == AVCOL_TRC_BT709 || trc == AVCOL_TRC_SMPTE170M ||
        trc == AVCOL_TRC_IEC61966_2_1 || trc == AVCOL_TRC_GAMMA22 || trc == AVCOL_TRC_GAMMA28;
    AVRational sar = av_guess_sample_aspect_ratio(d->format, st, NULL);
    return sdr && par->field_order == AV_FIELD_PROGRESSIVE && par->color_space != AVCOL_SPC_UNSPECIFIED &&
        sar.num > 0 && sar.num == sar.den && isfinite(d->info.rotation_degrees) &&
        fabs(remainder(d->info.rotation_degrees, 90)) < 0.01;
}
double sp_ff_timeline_origin(sp_ff_decoder *d) { return d ? d->origin : NAN; }

int sp_ff_subtitle_count(sp_ff_decoder *d) {
    if (!d) return AVERROR(EINVAL);
    int count=0;
    for (unsigned i=0;i<d->format->nb_streams;i++)
        if (d->format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE) count++;
    return count;
}
int sp_ff_subtitle_get(sp_ff_decoder *d, int ordinal, sp_ff_subtitle_track *out) {
    if (!d || !out || ordinal<0) return AVERROR(EINVAL);
    memset(out,0,sizeof(*out));
    for (unsigned i=0;i<d->format->nb_streams;i++) {
        AVStream *stream=d->format->streams[i];
        if (stream->codecpar->codec_type!=AVMEDIA_TYPE_SUBTITLE || ordinal--) continue;
        const AVCodecParameters *parameters=stream->codecpar;
        const AVCodecDescriptor *descriptor=avcodec_descriptor_get(parameters->codec_id);
        out->stream_index=(int)i;out->codec_id=parameters->codec_id;
        out->supported_text=descriptor && (descriptor->props&AV_CODEC_PROP_TEXT_SUB) &&
            avcodec_find_decoder(parameters->codec_id) && parameters->extradata_size<=8*1024*1024;
        out->is_default=!!(stream->disposition&AV_DISPOSITION_DEFAULT);
        out->is_forced=!!(stream->disposition&AV_DISPOSITION_FORCED);
        AVDictionaryEntry *language=av_dict_get(stream->metadata,"language",NULL,0);
        AVDictionaryEntry *title=av_dict_get(stream->metadata,"title",NULL,0);
        snprintf(out->language,sizeof(out->language),"%s",language?language->value:"");
        snprintf(out->title,sizeof(out->title),"%s",title?title->value:"");
        snprintf(out->codec_name,sizeof(out->codec_name),"%s",avcodec_get_name(parameters->codec_id));
        if (out->supported_text) {out->extradata=parameters->extradata;out->extradata_size=parameters->extradata_size;}
        return 0;
    }
    return AVERROR_STREAM_NOT_FOUND;
}
int sp_ff_subtitle_select(sp_ff_decoder *d,int index) {
    if (!d || index< -1) return AVERROR(EINVAL);
    if (interrupted(d)) return AVERROR_EXIT;
    if (index>=0) {
        int valid=0;
        for(int i=0;i<sp_ff_subtitle_count(d);i++) {
            sp_ff_subtitle_track track;
            if (sp_ff_subtitle_get(d,i,&track)==0 && track.stream_index==index && track.supported_text) {valid=1;break;}
        }
        if(!valid)return AVERROR(EINVAL);
    }
    if(d->subtitle_packet_borrowed){av_packet_unref(d->packet);d->packet_loaded=0;d->subtitle_packet_borrowed=0;}
    d->subtitle_stream=index;return 0;
}

static double frame_pts(sp_ff_decoder *d, AVFrame *frame, int stream, double fallback) {
    int64_t value = frame->best_effort_timestamp;
    if (value == AV_NOPTS_VALUE) value = frame->pts;
    double result = value == AV_NOPTS_VALUE ? fallback : value * av_q2d(d->format->streams[stream]->time_base) - d->origin;
    return isfinite(result) ? result : fallback;
}
static int video_frame(sp_ff_decoder *d, sp_ff_frame *output) {
    AVFrame *frame = d->frame;
    if (frame->width <= 0 || frame->height <= 0 || frame->width > 8192 || frame->height > 8192) return AVERROR(EINVAL);
    d->info.hardware_decoding = frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
    if (frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67)
        d->info.is_hdr = 1;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        // FFmpeg's VideoToolbox AVFrame owns this CVPixelBuffer through its AVBufferRef.
        // Keep that frame alive until the next decoder operation; the caller retains the
        // pixel buffer itself before passing it to another queue. No CPU readback is needed.
        CVPixelBufferRef pixels = (CVPixelBufferRef)frame->data[3];
        if (!pixels || CVPixelBufferGetWidth(pixels) != (size_t)frame->width ||
            CVPixelBufferGetHeight(pixels) != (size_t)frame->height ||
            CVPixelBufferGetDataSize(pixels) > 256 * 1024 * 1024) return AVERROR(EINVAL);
        output->kind = SP_FF_VIDEO; output->cv_pixelbuffer = pixels;
        output->width = frame->width; output->height = frame->height;
        goto timestamps;
    }
    int bytes = av_image_get_buffer_size(AV_PIX_FMT_BGRA, frame->width, frame->height, 1);
    if (bytes <= 0 || bytes > 256 * 1024 * 1024) return AVERROR(EINVAL);
    av_fast_malloc(&d->video_bytes, &d->video_capacity, (size_t)bytes);
    if (!d->video_bytes) return AVERROR(ENOMEM);
    d->scale = sws_getCachedContext(d->scale, frame->width, frame->height, frame->format,
        frame->width, frame->height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!d->scale) return AVERROR(ENOMEM);
    int color = frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
        frame->colorspace == AVCOL_SPC_BT2020_NCL || frame->colorspace == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020 : SWS_CS_ITU601;
    sws_setColorspaceDetails(d->scale, sws_getCoefficients(color), frame->color_range == AVCOL_RANGE_JPEG,
                            sws_getCoefficients(color), 1, 0, 1 << 16, 1 << 16);
    uint8_t *planes[4] = {d->video_bytes, NULL, NULL, NULL};
    int strides[4] = {frame->width * 4, 0, 0, 0};
    int result = sws_scale(d->scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
    if (result < 0) return result;
    output->kind = SP_FF_VIDEO; output->data = d->video_bytes; output->data_bytes = bytes;
    output->width = frame->width; output->height = frame->height; output->stride = strides[0];
timestamps:
    output->pts_seconds = frame_pts(d, frame, d->video_stream, d->next_video_pts);
    output->duration_seconds = frame->duration > 0 ? frame->duration * av_q2d(d->format->streams[d->video_stream]->time_base) :
        d->info.frames_per_second > 0 ? 1 / d->info.frames_per_second : 1.0 / 30;
    d->next_video_pts = output->pts_seconds + output->duration_seconds;
    return SP_FF_VIDEO;
}

static int audio_frame(sp_ff_decoder *d, AVFrame *frame, sp_ff_frame *output) {
    if (frame) {
        if (frame->sample_rate <= 0 || frame->sample_rate > 768000 || frame->nb_samples < 0) return AVERROR(EINVAL);
        if (!d->resample || d->input_rate != frame->sample_rate || d->input_format != frame->format ||
            av_channel_layout_compare(&d->input_layout, &frame->ch_layout)) {
            swr_free(&d->resample); swr_free(&d->focus_resample); av_channel_layout_uninit(&d->input_layout);
            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
            int result = swr_alloc_set_opts2(&d->resample, &stereo, AV_SAMPLE_FMT_FLT, 48000,
                &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
            if (result < 0) return result;
            // Float output otherwise leaves multichannel downmix coefficients
            // unnormalised: correlated 5.1/7.1 content can exceed full scale and
            // clip at the speaker. Preserve channel ratios with a bounded matrix.
            result = av_opt_set_double(d->resample, "rematrix_maxval", 1.0, 0);
            if (result < 0 || (result = swr_init(d->resample)) < 0) return result;
            if (av_channel_layout_copy(&d->input_layout, &frame->ch_layout) < 0) return AVERROR(ENOMEM);
            d->input_rate = frame->sample_rate; d->input_format = frame->format;
            if (frame->ch_layout.nb_channels > 2 && frame->ch_layout.nb_channels <= 64 &&
                av_channel_layout_index_from_channel(&frame->ch_layout, AV_CHAN_FRONT_CENTER) >= 0) {
                result = swr_alloc_set_opts2(&d->focus_resample, &stereo, AV_SAMPLE_FMT_FLT, 48000,
                    &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
                if (result < 0) return result;
                double matrix[64 * 64] = {0};
                result = swr_build_matrix2(&frame->ch_layout, &stereo, sqrt(2.0), sqrt(0.5), 0.0,
                    1.0, 1.0, matrix, 64, AV_MATRIX_ENCODING_NONE, NULL);
                if (result < 0 || (result = swr_set_matrix(d->focus_resample, matrix, 64)) < 0 ||
                    (result = swr_init(d->focus_resample)) < 0) return result;
            }
            d->focus = 0;

        }
    }
    if (!d->resample) return 0;
    int64_t delay = swr_get_delay(d->resample, d->input_rate);
    int64_t count = av_rescale_rnd(delay + (frame ? frame->nb_samples : 0), 48000, d->input_rate, AV_ROUND_UP);
    if (count < 0 || count > 48000 * 10) return AVERROR(EINVAL);
    if (!count) return 0;
    av_fast_malloc(&d->audio_bytes, &d->audio_capacity, (size_t)count * 2 * sizeof(float));
    if (!d->audio_bytes) return AVERROR(ENOMEM);
    uint8_t *planes[1] = {d->audio_bytes};
    int samples = swr_convert(d->resample, planes, (int)count, frame ? (const uint8_t **)frame->extended_data : NULL, frame ? frame->nb_samples : 0);
    d->reference_samples = 0;
    // Clock both downmixes even at focus=0, including resampler drain at EOF.
    if (d->focus_resample) {
        av_fast_malloc(&d->focus_bytes, &d->focus_capacity, (size_t)count * 2 * sizeof(float));
        if (!d->focus_bytes) return AVERROR(ENOMEM);
        uint8_t *focused[1] = {d->focus_bytes};
        int n = swr_convert(d->focus_resample, focused, (int)count,
            frame ? (const uint8_t **)frame->extended_data : NULL, frame ? frame->nb_samples : 0);
        if (n != samples) return n < 0 ? n : AVERROR(EINVAL);
    }
    if (samples <= 0) return samples;
    if (d->capture_reference) {
        av_fast_malloc(&d->reference_bytes, &d->reference_capacity, (size_t)samples * 2 * sizeof(float));
        if (!d->reference_bytes) return AVERROR(ENOMEM);
        memcpy(d->reference_bytes, d->audio_bytes, (size_t)samples * 2 * sizeof(float));
        d->reference_samples = samples * 2;
    }
    if (d->focus_resample) {
        float *pcm = (float *)d->audio_bytes, *focused = (float *)d->focus_bytes;
        const float ramp = 1.0f / (48000 * 0.025f);
        for (int i = 0; i < samples; ++i) {
            d->focus += fmaxf(-ramp, fminf(ramp, d->target_focus - d->focus));
            if (d->focus == 0) continue;
            for (int ch = 0; ch < 2; ++ch) {
                int at = i * 2 + ch;
                pcm[at] += (focused[at] - pcm[at]) * d->focus;
            }
        }
    }
    output->kind = SP_FF_AUDIO; output->data = d->audio_bytes; output->data_bytes = samples * 2 * (int)sizeof(float);
    output->audio_frames = samples; output->audio_sample_rate = 48000; output->audio_channels = 2;
    output->pts_seconds = frame ? frame_pts(d, frame, d->audio_stream, d->next_audio_pts) - (double)delay / d->input_rate : d->next_audio_pts;
    output->duration_seconds = (double)samples / 48000;
    d->next_audio_pts = output->pts_seconds + output->duration_seconds;
    return SP_FF_AUDIO;
}

void sp_ff_set_sound_options(sp_ff_decoder *d, float focus, int reference) {
    if (!d) return;
    d->target_focus = isfinite(focus) ? fmaxf(0, fminf(1, focus)) : 0;
    d->capture_reference = reference != 0;
}
const float *sp_ff_unfocused_audio(sp_ff_decoder *d, int *sample_count) {
    if (sample_count) *sample_count = d ? d->reference_samples : 0;
    return d && d->reference_samples ? (const float *)d->reference_bytes : NULL;
}

int sp_ff_next(sp_ff_decoder *d, sp_ff_frame *output) {
    if (!d || !output) return AVERROR(EINVAL);
    d->last_video_error = 0; d->reference_samples = 0;
    if (d->video_stream >= 0 && !d->video) return AVERROR(EIO);
    memset(output, 0, sizeof(*output));
    if(d->subtitle_packet_borrowed){av_packet_unref(d->packet);d->packet_loaded=0;d->subtitle_packet_borrowed=0;}
    for (;;) {
        if (interrupted(d)) return AVERROR_EXIT;
        if (d->pending) {
            AVCodecContext *codec = d->pending == SP_FF_VIDEO ? d->video : d->audio;
            av_frame_unref(d->frame);
            int result = avcodec_receive_frame(codec, d->frame);
            if (result == 0) {
                // Seek preroll can skip events of another kind in this same next() call.
                // Never leave a stale hardware pointer or software data on the next event.
                memset(output, 0, sizeof(*output));
                result = d->pending == SP_FF_VIDEO ? video_frame(d, output) : audio_frame(d, d->frame, output);
                if (result <= 0) {
                    if (result < 0) { if (d->pending == SP_FF_VIDEO) d->last_video_error = result; return result; }
                    continue;
                }
                if (output->pts_seconds + output->duration_seconds <= d->seek_target) continue;
                if (result == SP_FF_AUDIO && output->pts_seconds < d->seek_target) {
                    int trim = (int)ceil((d->seek_target - output->pts_seconds) * 48000);
                    if (trim >= output->audio_frames) continue;
                    output->data += trim * 2 * sizeof(float); output->data_bytes -= trim * 2 * (int)sizeof(float);
                    if (d->reference_samples) {
                        d->reference_samples -= trim * 2;
                        memmove(d->reference_bytes, d->reference_bytes + trim * 2 * sizeof(float),
                            (size_t)d->reference_samples * sizeof(float));
                    }
                    output->audio_frames -= trim; output->pts_seconds += (double)trim / 48000;
                    output->duration_seconds = (double)output->audio_frames / 48000;
                }
                return result;
            }
            if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
                if (d->pending == SP_FF_VIDEO) d->last_video_error = result;
                return result;
            }
            d->pending = 0;
        }
        if (d->eof) {
            if (d->video && !d->video_flushed) { d->video_flushed = 1; avcodec_send_packet(d->video, NULL); d->pending = SP_FF_VIDEO; continue; }
            if (d->audio && !d->audio_flushed) { d->audio_flushed = 1; avcodec_send_packet(d->audio, NULL); d->pending = SP_FF_AUDIO; continue; }
            if (d->audio && !d->audio_resampled) { d->audio_resampled = 1; int result = audio_frame(d, NULL, output); if (result) return result; }
            return SP_FF_EOF;
        }
        if (!d->packet_loaded) {
            int result = av_read_frame(d->format, d->packet);
            if (result == AVERROR_EOF) { d->eof = 1; continue; }
            if (result < 0) return result;
            d->packet_loaded = 1;
        }
        int kind = d->packet->stream_index == d->video_stream ? SP_FF_VIDEO : d->packet->stream_index == d->audio_stream ? SP_FF_AUDIO : 0;
        if(d->packet->stream_index==d->subtitle_stream && d->packet->size>0 && d->packet->size<=8*1024*1024) {
            AVStream *stream=d->format->streams[d->subtitle_stream];
            int64_t pts=d->packet->pts==AV_NOPTS_VALUE?d->packet->dts:d->packet->pts;
            // A text packet without any timing cannot be shown in sync. Skip it.
            if(pts!=AV_NOPTS_VALUE) {
                memset(output,0,sizeof(*output));
                output->kind=SP_FF_SUBTITLE;output->subtitle_stream=d->subtitle_stream;
                output->data=d->packet->data;output->data_bytes=d->packet->size;
                output->pts_seconds=pts*av_q2d(stream->time_base)-d->origin;
                output->duration_seconds=d->packet->duration>0?d->packet->duration*av_q2d(stream->time_base):0;
                d->subtitle_packet_borrowed=1;return SP_FF_SUBTITLE;
            }
        }
        if (!kind) { av_packet_unref(d->packet); d->packet_loaded = 0; continue; }
        if (kind == SP_FF_VIDEO && d->awaiting_video_keyframe) {
            // Timestamp seeks in unindexed TS can land on dependent pictures. Software
            // concealment may tolerate those, but VideoToolbox reports missing references.
            // Start the flushed decoder only from a random-access packet.
            if (!(d->packet->flags & AV_PKT_FLAG_KEY)) { av_packet_unref(d->packet); d->packet_loaded = 0; continue; }
            d->awaiting_video_keyframe = 0;
        }
        int result = avcodec_send_packet(kind == SP_FF_VIDEO ? d->video : d->audio, d->packet);
        if (result != AVERROR(EAGAIN)) { av_packet_unref(d->packet); d->packet_loaded = 0; }
        if (result < 0 && result != AVERROR(EAGAIN)) {
            if (kind == SP_FF_VIDEO) d->last_video_error = result;
            return result;
        }
        d->pending = kind;
    }
}

int sp_ff_seek(sp_ff_decoder *d, double seconds) {
    if (!d || !isfinite(seconds) || seconds < 0 || seconds > (double)INT64_MAX / AV_TIME_BASE - fabs(d->origin)) return AVERROR(EINVAL);
    if (interrupted(d)) return AVERROR_EXIT;
    // TS may interleave the audio covering a video keyframe before that keyframe's
    // byte position. Keep one second of demux preroll, then discard/trim decoded
    // events against the user's exact requested time below.
    double demux_seconds = fmax(0, seconds - 1.0);
    int64_t target = (int64_t)((demux_seconds + d->origin) * AV_TIME_BASE);
    // Start no later than the requested timestamp, then decode/discard forward.
    // Allowing a later demux position can skip preceding interleaved audio in TS.
    int result;
    if (demux_seconds == 0 && !strcmp(d->format->iformat->name, "mpegts")) {
        // A TS timestamp seek to its first video keyframe can still skip initial
        // audio PES packets. Restart from byte zero for this bounded preroll.
        result = av_seek_frame(d->format, -1, 0, AVSEEK_FLAG_BYTE);
    } else if(d->subtitle_stream>=0) {
        // Ask the selected text stream's index for its preceding cue first. This
        // preserves long cues spanning a seek when the container indexes them.
        AVStream *subtitle=d->format->streams[d->subtitle_stream];
        int64_t cue_target=av_rescale_q((int64_t)((seconds+d->origin)*AV_TIME_BASE),AV_TIME_BASE_Q,subtitle->time_base);
        result=avformat_seek_file(d->format,d->subtitle_stream,INT64_MIN,cue_target,cue_target,0);
        if(result<0)result=avformat_seek_file(d->format,-1,INT64_MIN,target,target,0);
    } else {
        result = avformat_seek_file(d->format, -1, INT64_MIN, target, target, 0);
    }
    if (result < 0) return result;
    if (d->video) avcodec_flush_buffers(d->video);
    if (d->audio) avcodec_flush_buffers(d->audio);
    if (d->resample) { swr_close(d->resample); result = swr_init(d->resample); if (result < 0) return result; }
    if (d->focus_resample) { swr_close(d->focus_resample); result = swr_init(d->focus_resample); if (result < 0) return result; }
    d->focus = 0; d->reference_samples = 0;
    av_packet_unref(d->packet); av_frame_unref(d->frame);
    d->pending = d->packet_loaded = d->eof = d->video_flushed = d->audio_flushed = d->audio_resampled = 0;
    d->subtitle_packet_borrowed=0;
    d->awaiting_video_keyframe = d->video != NULL;
    d->last_video_error = 0;
    d->seek_target = seconds; d->next_video_pts = d->next_audio_pts = seconds;
    return 0;
}
int sp_ff_is_hardware_error(sp_ff_decoder *d, int error) {
    return d && d->video && d->hardware && d->last_video_error == error &&
        (error == AVERROR_UNKNOWN || error == AVERROR_EXTERNAL) &&
        (d->video->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX || d->info.hardware_decoding);
}
int sp_ff_recover_video(sp_ff_decoder *d, double seconds, int hardware) {
    if (!d || d->video_stream < 0 || !isfinite(seconds) || seconds < 0 ||
        seconds > (double)INT64_MAX / AV_TIME_BASE - fabs(d->origin)) return AVERROR(EINVAL);
    if (interrupted(d)) return AVERROR_EXIT;
    // Old video references may still be held by the UI. They own CVPixelBuffers,
    // independent of this AVFrame/context, and must never be reused or mutated here.
    av_frame_unref(d->frame); av_packet_unref(d->packet);
    d->pending = d->packet_loaded = d->eof = d->video_flushed = d->audio_flushed = d->audio_resampled = 0;
    d->subtitle_packet_borrowed=0;
    d->last_video_error = 0;
    avcodec_free_context(&d->video); av_buffer_unref(&d->hardware);
    d->info.hardware_decoding = 0;
    int result = open_codec(d, d->video_stream, hardware != 0, &d->video);
    if (result < 0) return result;
    return sp_ff_seek(d, seconds);
}
void sp_ff_cancel(sp_ff_decoder *d) { if (d) atomic_store(&d->cancelled, 1); }
void sp_ff_close(sp_ff_decoder *d) {
    if (!d) return;
    avcodec_free_context(&d->video); avcodec_free_context(&d->audio); av_buffer_unref(&d->hardware);
    avformat_close_input(&d->format);
    avio_closep(&d->file_io);
    if (d->io) { av_freep(&d->io->buffer); avio_context_free(&d->io); }
    av_packet_free(&d->packet); av_frame_free(&d->frame);
    sws_freeContext(d->scale); swr_free(&d->resample); swr_free(&d->focus_resample); av_channel_layout_uninit(&d->input_layout);
    av_free(d->video_bytes); av_free(d->audio_bytes); av_free(d->focus_bytes); av_free(d->reference_bytes); av_free(d);
}
void sp_ff_error_string(int error, char *buffer, int capacity) { if (buffer && capacity > 0) av_strerror(error, buffer, (size_t)capacity); }
const char *sp_ff_license(void) { return avcodec_license(); }
