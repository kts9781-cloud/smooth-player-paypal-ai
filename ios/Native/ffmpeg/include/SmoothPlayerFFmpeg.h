#ifndef SMOOTH_PLAYER_FFMPEG_H
#define SMOOTH_PLAYER_FFMPEG_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct sp_ff_decoder sp_ff_decoder;
enum { SP_FF_EOF = 0, SP_FF_VIDEO = 1, SP_FF_AUDIO = 2, SP_FF_SUBTITLE = 3, SP_FF_SEEK_SIZE = 0x10000 };
// Called synchronously on the decoder worker. Read: bytes read, 0 EOF, negative failure.
// Seek: absolute resulting position; SEEK_SET/CUR/END or SP_FF_SEEK_SIZE for file length.
// These callbacks must never dispatch synchronously to the same worker or the main actor.
typedef int (*sp_ff_read_callback)(void *opaque, uint8_t *buffer, int capacity);
typedef int64_t (*sp_ff_seek_callback)(void *opaque, int64_t offset, int whence);

typedef struct {
    double duration_seconds;
    double frames_per_second;
    int width, height;
    int has_video, has_audio;
    int audio_sample_rate, audio_channels;
    double rotation_degrees;
    double sample_aspect_ratio;
    char video_codec[64], audio_codec[64];
    int is_hdr; // PQ/HLG transfer metadata; BGRA output does not perform HDR tone mapping.
    int hardware_decoding; // 1 after the latest returned video frame used VideoToolbox; initially 0.
} sp_ff_info;

typedef struct {
    int kind; // SP_FF_VIDEO, SP_FF_AUDIO or SP_FF_SUBTITLE
    double pts_seconds, duration_seconds;
    const uint8_t *data; // Software BGRA/audio only. Borrowed until next/seek/close; copy before returning to caller.
    int data_bytes;
    int width, height, stride; // Software video: top-down BGRA8; opaque sources have alpha 255.
    int audio_frames, audio_sample_rate, audio_channels; // Audio: native Float32 interleaved, 48000 Hz stereo.
    // VideoToolbox video: borrowed CVPixelBufferRef in its original pixel format, with
    // original color attachments. Valid until next/seek/close. Retain before crossing
    // the decoder worker boundary, release that retain when done. Treat pixels as immutable.
    // When non-NULL, data/data_bytes/stride are zero; no CPU transfer or BGRA copy occurs.
    void *cv_pixelbuffer;
    int subtitle_stream; // Subtitle only. data is the original compressed packet, borrowed until the next operation.
} sp_ff_frame;

typedef struct {
    int stream_index, codec_id, supported_text, is_default, is_forced;
    char language[64], title[256], codec_name[64];
    // Borrowed until close. Copy on the decoder worker before crossing a queue.
    const uint8_t *extradata;
    int extradata_size;
} sp_ff_subtitle_track;

// All operations except cancel must run on one serial worker. The caller owns opaque and keeps it alive through close.
// prefer_hardware uses VideoToolbox when available; failure to create/open it falls back to software.
sp_ff_decoder *sp_ff_open_file(const char *path, int prefer_hardware, int *error);
sp_ff_decoder *sp_ff_open_io(void *opaque, sp_ff_read_callback read, sp_ff_seek_callback seek,
                           int prefer_hardware, int *error);
// Audio-only cursor over the same authorized input, for bounded-memory A/V alignment.
sp_ff_decoder *sp_ff_open_audio_file(const char *path, int *error);
sp_ff_decoder *sp_ff_open_audio_io(void *opaque, sp_ff_read_callback read, sp_ff_seek_callback seek, int *error);
int sp_ff_get_info(sp_ff_decoder *decoder, sp_ff_info *info);
// Additive getter: explicit progressive SDR + square pixels; unknown metadata returns 0.
int sp_ff_enhancement_sdr(sp_ff_decoder *decoder);
// Container timestamp subtracted by frame_pts/seek. Read on the decoder worker;
// NAN for a null handle. Additive getter keeps sp_ff_info's existing ABI intact.
double sp_ff_timeline_origin(sp_ff_decoder *decoder);
int sp_ff_subtitle_count(sp_ff_decoder *decoder);
int sp_ff_subtitle_get(sp_ff_decoder *decoder, int ordinal, sp_ff_subtitle_track *track);
// -1 disables packets. Selection itself does not seek or reset the playback clock.
int sp_ff_subtitle_select(sp_ff_decoder *decoder, int stream_index);
// Serial decoder-worker only. Both paths share a sample clock; selection never seeks.
void sp_ff_set_sound_options(sp_ff_decoder *decoder, float focus, int capture_reference);
const float *sp_ff_unfocused_audio(sp_ff_decoder *decoder, int *sample_count);
int sp_ff_next(sp_ff_decoder *decoder, sp_ff_frame *frame); // event kind, 0 EOF, negative FFmpeg error
int sp_ff_seek(sp_ff_decoder *decoder, double seconds);
// Only true for a hardware VIDEO decode failure from the latest next() call.
// Demux/network/audio/cancellation failures must not be retried as video failures.
int sp_ff_is_hardware_error(sp_ff_decoder *decoder, int error);
// Explicit caller-controlled recovery. Pause the presentation/audio clock and discard
// queued output first. Recreates the video decoder, then resets both streams via seek.
// Retained CVPixelBuffers remain valid. Caller bounds retry count and resumes at seconds.
int sp_ff_recover_video(sp_ff_decoder *decoder, double seconds, int prefer_hardware);
void sp_ff_cancel(sp_ff_decoder *decoder); // Cancellation flag only; safe from another thread while decoder remains alive.
void sp_ff_close(sp_ff_decoder *decoder);
void sp_ff_error_string(int error, char *buffer, int capacity); // No filenames, URLs, or credentials.
const char *sp_ff_license(void);

#ifdef __cplusplus
}
#endif
#endif
