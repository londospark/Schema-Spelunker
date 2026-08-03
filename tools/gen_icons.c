// gen_icons.c — one-shot icon asset generator.
//
// Rasterises the Windows window-control glyphs from Segoe MDL2 Assets
// (segmdl2.ttf) into assets/icons/*.png using stb_truetype + stb_image_write.
//
// C, not Odin: this Odin dev build (dev-2026-07) crashes on the second
// consecutive stb_truetype rasterise call through its foreign-call ABI
// (verified with both hand-rolled and vendor:stb/truetype bindings), while the
// identical sequence works in C. The generated PNGs are committed, so the app
// runtime itself stays fully cross-platform.
//
// Build (Windows, MSVC):
//   cl /nologo /O2 /I vendor/imgui /I vendor/stb tools/gen_icons.c /Fe:bin/gen_icons.exe
// Run:
//   bin/gen_icons.exe

#define STB_TRUETYPE_IMPLEMENTATION
#include "imstb_truetype.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <direct.h>

#define ICON_SIZE 32

typedef struct {
	const char *name;
	int codepoint;
} IconSpec;

static IconSpec SPECS[] = {
	{"minimize", 0xE921},
	{"maximize", 0xE922},
	{"restore",  0xE923},
	{"close",    0xE8BB},
};

static int render_glyph(stbtt_fontinfo *font, int codepoint, unsigned char *canvas) {
	int glyph = stbtt_FindGlyphIndex(font, codepoint);
	if (!glyph) {
		return 0;
	}
	float scale = stbtt_ScaleForPixelHeight(font, 22.0f);

	int w = 0, h = 0;
	unsigned char *bmp = stbtt_GetGlyphBitmap(font, scale, scale, glyph, &w, &h, NULL, NULL);
	if (!bmp) {
		return 0;
	}

	int ox = (ICON_SIZE - w) / 2;
	int oy = (ICON_SIZE - h) / 2;
	for (int y = 0; y < h; ++y) {
		for (int x = 0; x < w; ++x) {
			int a = bmp[y * w + x];
			if (!a) {
				continue;
			}
			int px = ox + x;
			int py = oy + y;
			if (px < 0 || px >= ICON_SIZE || py < 0 || py >= ICON_SIZE) {
				continue;
			}
			unsigned char *p = canvas + (py * ICON_SIZE + px) * 4;
			p[0] = p[1] = p[2] = 255; // white; the app tints via ImageButton tint_col
			p[3] = (unsigned char)a;
		}
	}
	stbtt_FreeBitmap(bmp, NULL);
	return 1;
}

int main(void) {
	const char *paths[] = {
		"C:\\Windows\\Fonts\\segmdl2.ttf",
		"C:\\Windows\\Fonts\\SegoeIcons.ttf",
	};

	FILE *f = NULL;
	for (int i = 0; i < 2; ++i) {
		f = fopen(paths[i], "rb");
		if (f) {
			break;
		}
	}
	if (!f) {
		fprintf(stderr, "gen_icons: no Segoe MDL2 Assets font found\n");
		return 1;
	}

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *buf = malloc((size_t)sz);
	fread(buf, 1, (size_t)sz, f);
	fclose(f);

	stbtt_fontinfo font;
	if (!stbtt_InitFont(&font, buf, stbtt_GetFontOffsetForIndex(buf, 0))) {
		fprintf(stderr, "gen_icons: stbtt_InitFont failed\n");
		return 1;
	}

	_mkdir("assets");
	_mkdir("assets/icons");

	for (int i = 0; i < 4; ++i) {
		unsigned char canvas[ICON_SIZE * ICON_SIZE * 4] = {0};
		if (!render_glyph(&font, SPECS[i].codepoint, canvas)) {
			fprintf(stderr, "gen_icons: glyph %s failed\n", SPECS[i].name);
			continue;
		}
		char path[256];
		snprintf(path, sizeof(path), "assets/icons/%s.png", SPECS[i].name);
		if (stbi_write_png(path, ICON_SIZE, ICON_SIZE, 4, canvas, ICON_SIZE * 4)) {
			printf("gen_icons: wrote %s\n", path);
		} else {
			fprintf(stderr, "gen_icons: failed to write %s\n", path);
		}
	}

	free(buf);
	return 0;
}
