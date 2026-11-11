#include "SmoothPlayerSubtitles.h"
#include <ass/ass.h>
#include <libavcodec/avcodec.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define SP_SUB_MAX_BYTES (32 * 1024 * 1024)
#define SP_SUB_MAX_INPUT (8 * 1024 * 1024)
#define SP_SUB_MAX_IMAGES 256
#define SP_SUB_MAX_EVENTS 100000

struct sp_sub_renderer {
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
    AVCodecContext *decoder;
    sp_sub_image *images;
    int image_count, width, height, rendered, force_changed;
};

static void quiet_log(int level, const char *format, va_list args, void *opaque) {
    // Never emit subtitle text, attachment names, media paths or font metadata.
    (void)level; (void)format; (void)args; (void)opaque;
}
static void free_images(sp_sub_image *images, int count) {
    if (images) { for (int i=0;i<count;i++) free((void*)images[i].rgba); free(images); }
}
static void clear_snapshot(sp_sub_renderer *s) {
    free_images(s->images,s->image_count); s->images=NULL; s->image_count=0;
    s->rendered=0; s->force_changed=1;
}
static void clear_track(sp_sub_renderer *s) {
    if (s->track) { ass_free_track(s->track); s->track=NULL; }
    avcodec_free_context(&s->decoder); clear_snapshot(s);
}
int sp_sub_resize(sp_sub_renderer *s,int width,int height) {
    if(!s || width<=0 || height<=0 || width>8192 || height>8192 || (int64_t)width*height>33554432) return -EINVAL;
    s->width=width;s->height=height;
    ass_set_frame_size(s->renderer,width,height);ass_set_storage_size(s->renderer,width,height);
    s->force_changed=1;return 0;
}
sp_sub_renderer *sp_sub_open(int width,int height,int *error) {
    if(error)*error=-ENOMEM;
    sp_sub_renderer *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->library=ass_library_init();if(!s->library)goto fail;
    ass_set_message_cb(s->library,quiet_log,NULL);
    s->renderer=ass_renderer_init(s->library);if(!s->renderer)goto fail;
    int result=sp_sub_resize(s,width,height);if(result<0){if(error)*error=result;goto fail;}
    // CoreText resolves installed fonts without loading a whole font directory.
    ass_set_fonts(s->renderer,NULL,"sans-serif",ASS_FONTPROVIDER_CORETEXT,NULL,1);
    if(error)*error=0;return s;
fail: sp_sub_close(s);return NULL;
}
int sp_sub_set_codec(sp_sub_renderer *s,int codec_id,const uint8_t *extra,int extra_size) {
    if(!s || extra_size<0 || extra_size>SP_SUB_MAX_INPUT || (extra_size&&!extra))return -EINVAL;
    const AVCodecDescriptor *descriptor=avcodec_descriptor_get(codec_id);
    const AVCodec *codec=avcodec_find_decoder(codec_id);
    if(!codec || codec->type!=AVMEDIA_TYPE_SUBTITLE || !descriptor || !(descriptor->props&AV_CODEC_PROP_TEXT_SUB))return -ENOTSUP;
    clear_track(s);
    s->track=ass_new_track(s->library);if(!s->track)return -ENOMEM;
    s->decoder=avcodec_alloc_context3(codec);if(!s->decoder)return -ENOMEM;
    if(extra_size) {
        s->decoder->extradata=av_mallocz((size_t)extra_size+AV_INPUT_BUFFER_PADDING_SIZE);
        if(!s->decoder->extradata)return -ENOMEM;
        memcpy(s->decoder->extradata,extra,(size_t)extra_size);s->decoder->extradata_size=extra_size;
    }
    s->decoder->pkt_timebase=(AVRational){1,1000000};
    int result=avcodec_open2(s->decoder,codec,NULL);if(result<0){clear_track(s);return result;}
    if(s->decoder->subtitle_header && s->decoder->subtitle_header_size>0)
        ass_process_codec_private(s->track,(char*)s->decoder->subtitle_header,s->decoder->subtitle_header_size);
    return 0;
}
int sp_sub_load_ass(sp_sub_renderer *s,const uint8_t *utf8,int size) {
    if(!s || !utf8 || size<=0 || size>SP_SUB_MAX_INPUT)return -EINVAL;
    char *copy=malloc((size_t)size+1);if(!copy)return -ENOMEM;
    memcpy(copy,utf8,(size_t)size);copy[size]=0;
    ASS_Track *track=ass_read_memory(s->library,copy,(size_t)size,"UTF-8");free(copy);
    if(!track)return -EINVAL;
    if(track->n_events>SP_SUB_MAX_EVENTS){ass_free_track(track);return -EFBIG;}
    clear_track(s);s->track=track;return 0;
}
int sp_sub_feed(sp_sub_renderer *s,const uint8_t *bytes,int size,int64_t pts_us,int64_t duration_us) {
    if(!s || !s->decoder || !s->track || !bytes || size<=0 || size>SP_SUB_MAX_INPUT)return -EINVAL;
    if((pts_us!=AV_NOPTS_VALUE && (pts_us< -10000000000000000LL || pts_us>10000000000000000LL)) ||
       duration_us<0 || duration_us>10000000000000000LL)return -EINVAL;
    if(s->track->n_events>=SP_SUB_MAX_EVENTS)return -EFBIG;
    AVPacket *packet=av_packet_alloc();if(!packet)return -ENOMEM;
    int result=av_new_packet(packet,size);if(result<0){av_packet_free(&packet);return result;}
    memcpy(packet->data,bytes,(size_t)size);packet->pts=pts_us;packet->duration=duration_us;
    AVSubtitle subtitle={0};int got=0;
    result=avcodec_decode_subtitle2(s->decoder,&subtitle,&got,packet);
    if(result>=0&&got) {
        int64_t start=(pts_us==AV_NOPTS_VALUE?0:pts_us/1000)+subtitle.start_display_time;
        int64_t duration=subtitle.end_display_time>subtitle.start_display_time?
            (int64_t)subtitle.end_display_time-subtitle.start_display_time:duration_us>0?duration_us/1000:3000;
        if(duration>86400000)duration=86400000;
        for(unsigned i=0;i<subtitle.num_rects;i++) {
            AVSubtitleRect *r=subtitle.rects[i];
            if(r->type==SUBTITLE_ASS&&r->ass) {
                size_t length=strnlen(r->ass,SP_SUB_MAX_INPUT+1);
                if(length>SP_SUB_MAX_INPUT || s->track->n_events>=SP_SUB_MAX_EVENTS){result=-EFBIG;break;}
                ass_process_chunk(s->track,r->ass,(int)length,start,duration);
            }
        }
    }
    avsubtitle_free(&subtitle);av_packet_free(&packet);
    return result<0?result:0;
}
int sp_sub_render(sp_sub_renderer *s,int64_t time_us,sp_sub_snapshot *output) {
    if(!s || !output)return -EINVAL;
    memset(output,0,sizeof(*output));output->width=s->width;output->height=s->height;output->current_line_start_us=-1;
    int changed=0;ASS_Image *images=s->track?ass_render_frame(s->renderer,s->track,time_us/1000,&changed):NULL;
    if(s->force_changed || !s->rendered)changed=1;
    if(changed) {
        int count=0;size_t total=0;
        for(ASS_Image *im=images;im;im=im->next) {
            if(im->w<=0||im->h<=0)continue;
            if(!im->bitmap||im->stride<im->w||im->w>8192||im->h>8192)return -EINVAL;
            size_t bytes=(size_t)im->w*im->h*4;
            if(++count>SP_SUB_MAX_IMAGES || bytes>SP_SUB_MAX_BYTES || total>SP_SUB_MAX_BYTES-bytes)return -EFBIG;
            total+=bytes;
        }
        sp_sub_image *next=count?calloc((size_t)count,sizeof(*next)):NULL;
        if(count&&!next)return -ENOMEM;
        int index=0;
        for(ASS_Image *im=images;im;im=im->next) {
            if(im->w<=0||im->h<=0)continue;
            sp_sub_image *dst=&next[index++];
            dst->x=im->dst_x;dst->y=im->dst_y;dst->width=im->w;dst->height=im->h;dst->stride=im->w*4;
            uint8_t *pixels=malloc((size_t)im->w*im->h*4);dst->rgba=pixels;
            if(!pixels){free_images(next,index);return -ENOMEM;}
            unsigned r=im->color>>24,g=(im->color>>16)&255,b=(im->color>>8)&255,a=255-(im->color&255);
            for(int y=0;y<im->h;y++)for(int x=0;x<im->w;x++) {
                unsigned alpha=im->bitmap[(size_t)y*im->stride+x]*a/255;
                size_t offset=((size_t)y*im->w+x)*4;
                pixels[offset]=r*alpha/255;pixels[offset+1]=g*alpha/255;pixels[offset+2]=b*alpha/255;pixels[offset+3]=alpha;
            }
        }
        free_images(s->images,s->image_count);s->images=next;s->image_count=count;s->rendered=1;s->force_changed=0;
    }
    if(s->track)for(int i=0;i<s->track->n_events;i++) {
        ASS_Event *event=&s->track->events[i];int64_t ms=time_us/1000;
        if(event->Start>=0 && event->Start<=INT64_MAX/1000 && event->Start<=ms &&
           event->Duration>0 && ms-event->Start<event->Duration &&
           (output->current_line_start_us<0 || event->Start*1000<output->current_line_start_us))output->current_line_start_us=event->Start*1000;
    }
    output->changed=!!changed;output->images=s->images;output->image_count=s->image_count;return 0;
}
void sp_sub_set_style(sp_sub_renderer *s,double scale,int outline) {
    if(!s)return;
    ass_set_font_scale(s->renderer,isfinite(scale)?fmax(.5,fmin(3,scale)):1);
    ASS_Style style={0};char name[]="Default",font[]="sans-serif";
    style.Name=name;style.FontName=font;style.BorderStyle=1;style.Outline=0;style.Shadow=0;
    ass_set_selective_style_override(s->renderer,&style);
    ass_set_selective_style_override_enabled(s->renderer,outline?ASS_OVERRIDE_DEFAULT:ASS_OVERRIDE_BIT_BORDER);
    s->force_changed=1;
}
void sp_sub_clear_events(sp_sub_renderer *s) {
    if(!s)return;
    if(s->track)ass_flush_events(s->track);
    if(s->decoder)avcodec_flush_buffers(s->decoder);
    clear_snapshot(s);
}
void sp_sub_close(sp_sub_renderer *s) {
    if(!s)return;
    clear_track(s);
    if(s->renderer)ass_renderer_done(s->renderer);
    if(s->library)ass_library_done(s->library);
    free(s);
}
