/* ========================================================================
   gen_icons.c - one-shot icon asset generator.

   Rasterises the Windows window-control glyphs from Segoe MDL2 Assets
   (segmdl2.ttf) into assets/icons/*.png using stb_truetype + stb_image_write.

   C, not Odin: this Odin dev build (dev-2026-07) crashes on the second
   consecutive stb_truetype rasterise call through its foreign-call ABI
   (verified with both hand-rolled and vendor:stb/truetype bindings), while
   the identical sequence works in C. The generated PNGs are committed, so
   the app runtime itself stays fully cross-platform.

   Build (Windows, MSVC):
     cl /nologo /O2 /W4 /WX /I vendor/imgui /I vendor/stb tools/gen_icons.c /Fe:bin/gen_icons.exe
   Run:
     bin/gen_icons.exe
   ======================================================================== */

#define _CRT_SECURE_NO_WARNINGS
#define STB_TRUETYPE_IMPLEMENTATION
#include "imstb_truetype.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <direct.h>
#include <stdint.h>
#include <stddef.h>

typedef int8_t  i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

typedef float  f32;
typedef double f64;

typedef size_t memory_index;

#define function      static
#define internal      static
#define local_persist static
#define global        static
#define ArrayCount(Array) (sizeof(Array) / sizeof((Array)[0]))

#define ICON_SIZE 32

typedef struct icon_spec
{
    char *Name;
    i32 Codepoint;
} icon_spec;

global icon_spec GlobalSpecs[] =
{
    {"minimize", 0xE921},
    {"maximize", 0xE922},
    {"restore",  0xE923},
    {"close",    0xE8BB},
    {"folder",   0xF12B},
    {"page",     0xE7C3},
};

internal i32
RenderGlyph(stbtt_fontinfo *Font, i32 Codepoint, u8 *Canvas)
{
    i32 Glyph = stbtt_FindGlyphIndex(Font, Codepoint);
    if(!Glyph)
    {
        return(0);
    }

    f32 Scale = stbtt_ScaleForPixelHeight(Font, 22.0f);

    i32 Width = 0, Height = 0;
    u8 *Bitmap = stbtt_GetGlyphBitmap(Font, Scale, Scale, Glyph, &Width, &Height, 0, 0);
    if(!Bitmap)
    {
        return(0);
    }

    i32 Ox = (ICON_SIZE - Width) / 2;
    i32 Oy = (ICON_SIZE - Height) / 2;
    for(i32 y = 0;
        y < Height;
        ++y)
    {
        for(i32 x = 0;
            x < Width;
            ++x)
        {
            u8 Alpha = Bitmap[y*Width + x];
            if(!Alpha)
            {
                continue;
            }

            i32 Px = Ox + x;
            i32 Py = Oy + y;
            if((Px >= 0) && (Px < ICON_SIZE) && (Py >= 0) && (Py < ICON_SIZE))
            {
                u8 *Pixel = Canvas + (Py*ICON_SIZE + Px)*4;
                Pixel[0] = Pixel[1] = Pixel[2] = 255; // NOTE: white; the app tints via ImageButton tint_col
                Pixel[3] = Alpha;
            }
        }
    }

    stbtt_FreeBitmap(Bitmap, 0);
    return(1);
}

i32
main(void)
{
    char *FontPaths[] =
    {
        "C:\\Windows\\Fonts\\segmdl2.ttf",
        "C:\\Windows\\Fonts\\SegoeIcons.ttf",
    };

    FILE *In = 0;
    for(memory_index i = 0;
        i < ArrayCount(FontPaths);
        ++i)
    {
        if(fopen_s(&In, FontPaths[i], "rb") == 0)
        {
            break;
        }
    }

    if(!In)
    {
        fprintf(stderr, "gen_icons: no Segoe MDL2 Assets font found\n");
        return(1);
    }

    fseek(In, 0, SEEK_END);
    memory_index FileSize = ftell(In);
    fseek(In, 0, SEEK_SET);
    u8 *FontBuffer = malloc(FileSize);
    fread(FontBuffer, 1, FileSize, In);
    fclose(In);

    stbtt_fontinfo Font;
    if(!stbtt_InitFont(&Font, FontBuffer, stbtt_GetFontOffsetForIndex(FontBuffer, 0)))
    {
        fprintf(stderr, "gen_icons: stbtt_InitFont failed\n");
        return(1);
    }

    _mkdir("assets");
    _mkdir("assets/icons");

    for(memory_index i = 0;
        i < ArrayCount(GlobalSpecs);
        ++i)
    {
        u8 Canvas[ICON_SIZE*ICON_SIZE*4] = {0};
        if(!RenderGlyph(&Font, GlobalSpecs[i].Codepoint, Canvas))
        {
            fprintf(stderr, "gen_icons: glyph %s failed\n", GlobalSpecs[i].Name);
            continue;
        }

        char Path[256];
        snprintf(Path, sizeof(Path), "assets/icons/%s.png", GlobalSpecs[i].Name);
        if(stbi_write_png(Path, ICON_SIZE, ICON_SIZE, 4, Canvas, ICON_SIZE*4))
        {
            printf("gen_icons: wrote %s\n", Path);
        }
        else
        {
            fprintf(stderr, "gen_icons: failed to write %s\n", Path);
        }
    }

    free(FontBuffer);
    return(0);
}
