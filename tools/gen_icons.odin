// gen_icons.odin — one-shot icon asset generator.
//
// Rasterises the Windows window-control glyphs from Segoe MDL2 Assets
// (segmdl2.ttf) into assets/icons/*.png using vendor:stb/truetype and
// vendor:stb/image write_png. The generated PNGs are committed, so the app
// runtime stays fully cross-platform.
//
// Was C: the dev-2026-07 Odin build crashed on consecutive stb_truetype
// rasterise calls through its foreign-call ABI. Verified fixed on
// dev-2026-08 (6 consecutive rasterise calls complete cleanly), so the tool
// now lives in the same language as the app. Glyph source is still
// Windows-only (Segoe MDL2 font); the committed PNGs hide that from runtime.
//
// Build (Windows):
//   build_icons.bat

package main

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

ICON_SIZE :: 32

IconSpec :: struct {
	name:      string,
	codepoint: rune,
}

GLOBAL_SPECS := []IconSpec{
	{name = "minimize", codepoint = 0xE921},
	{name = "maximize", codepoint = 0xE922},
	{name = "restore",  codepoint = 0xE923},
	{name = "close",    codepoint = 0xE8BB},
	{name = "folder",   codepoint = 0xF12B},
	{name = "page",     codepoint = 0xE7C3},
}

render_glyph :: proc(font: ^stbtt.fontinfo, codepoint: rune, canvas: []u8) -> bool {
	glyph := stbtt.FindGlyphIndex(font, codepoint)
	if glyph == 0 {
		return false
	}

	scale := stbtt.ScaleForPixelHeight(font, 22.0)
	width, height: c.int
	bitmap := stbtt.GetGlyphBitmap(font, scale, scale, glyph, &width, &height, nil, nil)
	if bitmap == nil {
		return false
	}
	defer stbtt.FreeBitmap(bitmap, nil)

	ox := (ICON_SIZE - int(width)) / 2
	oy := (ICON_SIZE - int(height)) / 2
	for y in 0 ..< int(height) {
		for x in 0 ..< int(width) {
			alpha := bitmap[y * int(width) + x]
			if alpha == 0 {
				continue
			}

			px := ox + x
			py := oy + y
			if px >= 0 && px < ICON_SIZE && py >= 0 && py < ICON_SIZE {
				offset := (py * ICON_SIZE + px) * 4
				canvas[offset + 0] = 255
				canvas[offset + 1] = 255
				canvas[offset + 2] = 255
				canvas[offset + 3] = alpha
			}
		}
	}
	return true
}

main :: proc() {
	font_paths := []string{
		"C:\\Windows\\Fonts\\segmdl2.ttf",
		"C:\\Windows\\Fonts\\SegoeIcons.ttf",
	}

	font_data: []u8
	for path in font_paths {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err == nil {
			font_data = data
			break
		}
	}
	if font_data == nil {
		fmt.eprintln("gen_icons: no Segoe MDL2 Assets font found")
		return
	}
	defer delete(font_data)

	font: stbtt.fontinfo
	if !stbtt.InitFont(&font, raw_data(font_data), stbtt.GetFontOffsetForIndex(raw_data(font_data), 0)) {
		fmt.eprintln("gen_icons: InitFont failed")
		return
	}

	if err := os.make_directory_all("assets/icons"); err != nil {
		fmt.eprintf("gen_icons: failed to create assets/icons: %v\n", err)
		return
	}

	for spec in GLOBAL_SPECS {
		canvas: [ICON_SIZE * ICON_SIZE * 4]u8
		if !render_glyph(&font, spec.codepoint, canvas[:]) {
			fmt.eprintf("gen_icons: glyph %s failed\n", spec.name)
			continue
		}

		path := fmt.ctprintf("assets/icons/%s.png", spec.name)
		if stbi.write_png(path, ICON_SIZE, ICON_SIZE, 4, &canvas[0], ICON_SIZE * 4) != 0 {
			fmt.printf("gen_icons: wrote %s\n", path)
		} else {
			fmt.eprintf("gen_icons: failed to write %s\n", path)
		}
	}
}
