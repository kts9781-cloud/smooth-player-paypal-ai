#ifndef SMOOTH_PLAYER_SUBTITLES_H
#define SMOOTH_PLAYER_SUBTITLES_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct sp_sub_renderer sp_sub_renderer;
typedef struct {
    int x, y, width, height, stride;
    const uint8_t *rgba; // Premultiplied RGBA; borrowed until the next render/reset/close.
} sp_sub_image;
typedef struct {
    int changed, width, height, image_count;
    const sp_sub_image *images;
    int64_t current_line_start_us; // -1 outside a cue.
} sp_sub_snapshot;

// Every method is serial-worker-only. No borrowed pointer may cross an async boundary.
sp_sub_renderer *sp_sub_open(int width, int height, int *error);
int sp_sub_resize(sp_sub_renderer *, int width, int height);
// codec_id uses the same pinned FFmpeg build as SmoothPlayerFFmpeg. This clears prior events.
int sp_sub_set_codec(sp_sub_renderer *, int codec_id, const uint8_t *extra, int extra_size);
int sp_sub_load_ass(sp_sub_renderer *, const uint8_t *utf8, int size);
int sp_sub_feed(sp_sub_renderer *, const uint8_t *bytes, int size, int64_t pts_us, int64_t duration_us);
int sp_sub_render(sp_sub_renderer *, int64_t time_us, sp_sub_snapshot *output);
void sp_sub_set_style(sp_sub_renderer *, double scale, int outline);
void sp_sub_clear_events(sp_sub_renderer *);
void sp_sub_close(sp_sub_renderer *);
#ifdef __cplusplus
}
#endif
#endif
