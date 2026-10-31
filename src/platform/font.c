/* FreeType/HarfBuzz boundary. No SDL resources or calls live here. */
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb-ft.h>
#include <stdlib.h>
#include <stdint.h>
#include <limits.h>
typedef struct { FT_Library library; FT_Face face; hb_font_t *font; hb_buffer_t *buffer; float space; } ZidFont;
typedef struct { uint32_t index; int32_t x_advance, y_advance, x_offset, y_offset; } ZidPosition;
typedef struct { const uint8_t *pixels; int width, height, pitch, left, top, gray; } ZidBitmap;
void zid_font_close(ZidFont *f) { if(!f)return; if(f->buffer)hb_buffer_destroy(f->buffer); if(f->font)hb_font_destroy(f->font); if(f->face)FT_Done_Face(f->face); if(f->library)FT_Done_FreeType(f->library); free(f); }
ZidFont *zid_font_open(const uint8_t *data,size_t len,unsigned pixels) { ZidFont*f=calloc(1,sizeof(*f)); if(!f)return NULL; if(len>LONG_MAX || FT_Init_FreeType(&f->library)||FT_New_Memory_Face(f->library,data,(FT_Long)len,0,&f->face)||FT_Set_Pixel_Sizes(f->face,0,pixels))goto fail; f->font=hb_ft_font_create_referenced(f->face);f->buffer=hb_buffer_create();if(!f->font||!f->buffer||!hb_buffer_allocation_successful(f->buffer)||FT_Load_Char(f->face,' ',FT_LOAD_DEFAULT))goto fail;f->space=(float)f->face->glyph->advance.x/64.f;if(f->space<=0)goto fail;return f;fail:zid_font_close(f);return NULL; }
float zid_font_space(ZidFont*f){return f->space;}
int zid_font_shape(ZidFont*f,const char*s,size_t len){if(len>INT_MAX)return 0;hb_buffer_reset(f->buffer);hb_buffer_add_utf8(f->buffer,s,(int)len,0,(int)len);hb_buffer_guess_segment_properties(f->buffer);hb_feature_t feature={HB_TAG('l','i','g','a'),0,0,HB_FEATURE_GLOBAL_END};hb_shape(f->font,f->buffer,&feature,1);return hb_buffer_allocation_successful(f->buffer);}
unsigned zid_font_count(ZidFont*f){return hb_buffer_get_length(f->buffer);}
ZidPosition zid_font_position(ZidFont*f,unsigned i){unsigned n;hb_glyph_info_t*a=hb_buffer_get_glyph_infos(f->buffer,&n);hb_glyph_position_t*p=hb_buffer_get_glyph_positions(f->buffer,&n);return (ZidPosition){a[i].codepoint,p[i].x_advance,p[i].y_advance,p[i].x_offset,p[i].y_offset};}
int zid_font_bitmap(ZidFont*f,unsigned index,ZidBitmap*out){if(FT_Load_Glyph(f->face,index,FT_LOAD_RENDER|FT_LOAD_TARGET_LIGHT))return 0;FT_GlyphSlot g=f->face->glyph;*out=(ZidBitmap){g->bitmap.buffer,(int)g->bitmap.width,(int)g->bitmap.rows,g->bitmap.pitch,g->bitmap_left,g->bitmap_top,g->bitmap.pixel_mode==FT_PIXEL_MODE_GRAY};return 1;}

/* NanoSVG is a zlib-licensed parser/rasterizer, used here only for icon masks. */
#include <stdio.h>
#include <string.h>
#include <math.h>
#define NANOSVG_IMPLEMENTATION
#include "../gfx/c/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "../gfx/c/nanosvgrast.h"
int zid_svg_alpha(const char *src, size_t len, int size, unsigned char *alpha) {
    if (len > 1048576 || size < 1 || size > 32) return 0;
    char *buf = malloc(len + 1);
    if (!buf) return 0;
    memcpy(buf, src, len); buf[len] = 0;
    NSVGimage *img = nsvgParse(buf, "px", 96);
    free(buf);
    if (!img || img->width <= 0 || img->height <= 0) { if (img) nsvgDelete(img); return 0; }
    /* Supersample 4x4 and box-filter: nanosvg's own AA is coarse at 16px. */
    enum { SS = 4 };
    int big = size * SS;
    NSVGrasterizer *rast = nsvgCreateRasterizer();
    unsigned char *rgba = calloc((size_t)big * big, 4);
    if (!rast || !rgba) { if (rast) nsvgDeleteRasterizer(rast); free(rgba); nsvgDelete(img); return 0; }
    float scale = fminf(big / img->width, big / img->height);
    nsvgRasterize(rast, img, (big-img->width*scale)*.5f, (big-img->height*scale)*.5f, scale, rgba, big, big, big*4);
    for (int y=0; y<size; y++) for (int x=0; x<size; x++) {
        unsigned sum = 0;
        for (int sy=0; sy<SS; sy++) for (int sx=0; sx<SS; sx++) sum += rgba[((size_t)(y*SS+sy)*big + (x*SS+sx))*4+3];
        alpha[y*size+x] = (unsigned char)((sum + SS*SS/2) / (SS*SS));
    }
    free(rgba); nsvgDeleteRasterizer(rast); nsvgDelete(img); return 1;
}

/* Multi-color icons: same parse, limits and 4x4 supersampling as zid_svg_alpha,
   but output premultiplied RGBA. NanoSVG emits straight alpha, so each subsample
   is premultiplied before averaging; averaging premultiplied channels keeps
   every output channel <= its alpha. */
int zid_svg_rgba(const char *src, size_t len, int size, unsigned char *rgba_out) {
    if (len > 1048576 || size < 1 || size > 32) return 0;
    char *buf = malloc(len + 1);
    if (!buf) return 0;
    memcpy(buf, src, len); buf[len] = 0;
    NSVGimage *img = nsvgParse(buf, "px", 96);
    free(buf);
    if (!img || img->width <= 0 || img->height <= 0) { if (img) nsvgDelete(img); return 0; }
    enum { SS = 4 };
    int big = size * SS;
    NSVGrasterizer *rast = nsvgCreateRasterizer();
    unsigned char *rgba = calloc((size_t)big * big, 4);
    if (!rast || !rgba) { if (rast) nsvgDeleteRasterizer(rast); free(rgba); nsvgDelete(img); return 0; }
    float scale = fminf(big / img->width, big / img->height);
    nsvgRasterize(rast, img, (big-img->width*scale)*.5f, (big-img->height*scale)*.5f, scale, rgba, big, big, big*4);
    for (int y=0; y<size; y++) for (int x=0; x<size; x++) {
        unsigned sum[4] = {0, 0, 0, 0};
        for (int sy=0; sy<SS; sy++) for (int sx=0; sx<SS; sx++) {
            const unsigned char *p = &rgba[((size_t)(y*SS+sy)*big + (x*SS+sx))*4];
            unsigned a = p[3];
            sum[0] += (p[0]*a + 127) / 255;
            sum[1] += (p[1]*a + 127) / 255;
            sum[2] += (p[2]*a + 127) / 255;
            sum[3] += a;
        }
        unsigned char *out = rgba_out + ((size_t)y*size + x)*4;
        for (int c=0; c<4; c++) out[c] = (unsigned char)((sum[c] + SS*SS/2) / (SS*SS));
    }
    free(rgba); nsvgDeleteRasterizer(rast); nsvgDelete(img); return 1;
}
