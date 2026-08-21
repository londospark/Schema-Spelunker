package main

import c "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"
import gl "vendor/gl"
import ig "vendor/imgui"
import imn "vendor/imnodes"
import stbi "vendor:stb/image"


// --- Theme data structures ---

// OS backdrop material for the window (Windows 11 DWM). Picked per theme so a
// light theme can use subtle Mica while a dark theme uses solid Mica; both
// themes currently use Mica (see TODO tuning note).
BackdropType :: enum {
	Mica, // DWMSBT_MAINWINDOW — opaque tint derived from wallpaper + theme
	Acrylic, // DWMSBT_TRANSIENTWINDOW — see-through frosted glass
	None,
}

ThemeData :: struct {
	name:                 string,

	// [text]
	text_main:            ig.Vec4,
	text_muted:           ig.Vec4,

	// [background]
	bg_window:            ig.Vec4,
	bg_child:             ig.Vec4,
	bg_popup:             ig.Vec4,

	// [controls]
	ctrl_frame:           ig.Vec4,
	ctrl_frame_hover:     ig.Vec4,
	ctrl_frame_active:    ig.Vec4,

	// [title_bar]
	title_bg:             ig.Vec4,
	title_bg_focus:       ig.Vec4,
	title_bg_faded:       ig.Vec4,

	// [table_card]
	card_bg:              ig.Vec4,
	card_bg_hovered:      ig.Vec4,
	card_bg_selected:     ig.Vec4,
	card_outline:         ig.Vec4,

	// [border]
	border_main:          ig.Vec4,
	border_subtle:        ig.Vec4,

	// [diagram_grid]
	grid_bg:              ig.Vec4,
	grid_line:            ig.Vec4,

	// [accent]
	accent_colour:        ig.Vec4,

	// [glass]
	backdrop:             BackdropType, // OS backdrop material (Mica / Acrylic / None)
	backdrop_alpha:       f32, // translucency of window/chrome backdrops for OS-level blur
	popup_alpha:          f32, // menus and dropdowns stay nearer opaque for readability

	// [layout]
	corner_rounding:      f32,
	scrollbar_size:       f32,
	grab_min_size:        f32,
	item_spacing_x:       f32,
	item_spacing_y:       f32,
	item_inner_spacing_x: f32,
	item_inner_spacing_y: f32,
	window_padding_x:     f32,
	window_padding_y:     f32,
	frame_padding_x:      f32,
	frame_padding_y:      f32,
	cell_padding_x:       f32,
	cell_padding_y:       f32,
	border_width:         f32,
	frame_border_width:   f32,
	tab_border_width:     f32,
}

// --- Helpers ---

imn_col :: proc(r, g, b: f32, a: f32 = 1.0) -> u32 {
	ri := u8(clamp(r, 0.0, 1.0) * 255.0)
	gi := u8(clamp(g, 0.0, 1.0) * 255.0)
	bi := u8(clamp(b, 0.0, 1.0) * 255.0)
	ai := u8(clamp(a, 0.0, 1.0) * 255.0)
	return u32(ri) | (u32(gi) << 8) | (u32(bi) << 16) | (u32(ai) << 24)
}

hex_digit :: proc(c: u8) -> u8 {
	switch {
	case '0' <= c && c <= '9':
		return c - '0'
	case 'a' <= c && c <= 'f':
		return c - 'a' + 10
	case 'A' <= c && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}

hex_to_vec4 :: proc(s: string) -> (col: ig.Vec4, ok: bool) {
	if len(s) == 0 || s[0] != '#' {
		fmt.eprintfln("theme parse: bad colour \"%s\"", s)
		return {}, false
	}
	hex := s[1:]
	if len(hex) != 6 && len(hex) != 8 {
		fmt.eprintfln("theme parse: bad colour \"%s\" (expected #RRGGBB or #RRGGBBAA)", s)
		return {}, false
	}
	r := f32(hex_digit(hex[0]) << 4 | hex_digit(hex[1])) / 255.0
	g := f32(hex_digit(hex[2]) << 4 | hex_digit(hex[3])) / 255.0
	b := f32(hex_digit(hex[4]) << 4 | hex_digit(hex[5])) / 255.0
	a := f32(1.0)
	if len(hex) == 8 {
		a = f32(hex_digit(hex[6]) << 4 | hex_digit(hex[7])) / 255.0
	}
	return {r, g, b, a}, true
}

vec4_with_alpha :: proc(c: ig.Vec4, a: f32) -> ig.Vec4 {
	return {c.x, c.y, c.z, a}
}

// --- Default theme ---

default_theme_data :: proc() -> ThemeData {
	return {
		name = "Default",
		text_main = {0.12, 0.12, 0.12, 1.00},
		text_muted = {0.55, 0.55, 0.55, 1.00},
		bg_window = {0.96, 0.96, 0.94, 1.00},
		bg_child = {0.96, 0.96, 0.94, 1.00},
		bg_popup = {1.00, 1.00, 1.00, 1.00},
		ctrl_frame = {1.00, 1.00, 1.00, 1.00},
		ctrl_frame_hover = {0.90, 0.92, 0.95, 1.00},
		ctrl_frame_active = {0.85, 0.88, 0.92, 1.00},
		title_bg = {0.92, 0.92, 0.90, 1.00},
		title_bg_focus = {0.88, 0.88, 0.86, 1.00},
		title_bg_faded = {0.92, 0.92, 0.90, 0.75},
		card_bg = {1.00, 1.00, 1.00, 1.00},
		card_bg_hovered = {0.98, 0.98, 0.95, 1.00},
		card_bg_selected = {0.96, 0.96, 0.93, 1.00},
		card_outline = {0.75, 0.75, 0.72, 1.00},
		border_main = {0.75, 0.75, 0.72, 1.00},
		border_subtle = {0.85, 0.85, 0.82, 1.00},
		grid_bg = {0.96, 0.96, 0.94, 1.00},
		grid_line = {0.85, 0.85, 0.82, 1.00},
		accent_colour = {0.17, 0.34, 0.59, 1.00},
		backdrop = .Mica,
		backdrop_alpha = 1.0,
		popup_alpha = 1.0,
		corner_rounding = 2.0,
		scrollbar_size = 14.0,
		grab_min_size = 12.0,
		item_spacing_x = 8.0,
		item_spacing_y = 6.0,
		item_inner_spacing_x = 6.0,
		item_inner_spacing_y = 4.0,
		window_padding_x = 12.0,
		window_padding_y = 12.0,
		frame_padding_x = 6.0,
		frame_padding_y = 4.0,
		cell_padding_x = 6.0,
		cell_padding_y = 4.0,
		border_width = 1.0,
		frame_border_width = 1.0,
		tab_border_width = 1.0,
	}
}

// --- .ssTheme parser ---

parse_ssTheme :: proc(filename: string, allocator: mem.Allocator) -> (ThemeData, bool) {
	data := default_theme_data()

	file_bytes, err := os.read_entire_file(filename, allocator)
	if err != os.ERROR_NONE {return data, false}
	defer delete(file_bytes, allocator)

	content := string(file_bytes)
	current_section: string

	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {continue}
		if trimmed[0] == '#' {continue}

		if trimmed[0] == '[' {
			close := strings.index_byte(trimmed, ']')
			if close > 1 {
				current_section = strings.trim_space(trimmed[1:close])
			}
			continue
		}

		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {continue}

		key := strings.trim_space(trimmed[:eq])
		raw_val := strings.trim_space(trimmed[eq + 1:])

		comment_start := -1
		in_quotes := raw_val[0] == '"'
		if !in_quotes {
			comment_start = strings.index_byte(raw_val, '#')
		} else {
			close_quote := strings.index_byte(raw_val[1:], '"')
			if close_quote >= 0 {
				after := strings.trim_space(raw_val[close_quote + 2:])
				if len(after) > 0 && after[0] == '#' {
					comment_start = close_quote + 2
				}
			}
		}
		if comment_start >= 0 {
			raw_val = strings.trim_space(raw_val[:comment_start])
		}

		if len(raw_val) >= 2 && raw_val[0] == '"' {
			raw_val = raw_val[1:len(raw_val) - 1]
		}

		// Parse value based on section + key
		switch current_section {
		case "":
			switch key {
			case "name":
				data.name = strings.clone(raw_val, allocator)
			}
		case "text":
			switch key {
			case "main":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.text_main = v}
			case "muted":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.text_muted = v}
			}
		case "background":
			switch key {
			case "window":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.bg_window = v}
			case "child":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.bg_child = v}
			case "popup":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.bg_popup = v}
			}
		case "controls":
			switch key {
			case "frame":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.ctrl_frame = v}
			case "frame_hover":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.ctrl_frame_hover = v}
			case "frame_active":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.ctrl_frame_active = v}
			}
		case "title_bar":
			switch key {
			case "background":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.title_bg = v}
			case "background_focus":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.title_bg_focus = v}
			case "background_faded":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.title_bg_faded = v}
			}
		case "table_card":
			switch key {
			case "background":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.card_bg = v}
			case "background_hovered":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.card_bg_hovered = v}
			case "background_selected":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.card_bg_selected = v}
			case "outline":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.card_outline = v}
			}
		case "border":
			switch key {
			case "main":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.border_main = v}
			case "subtle":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.border_subtle = v}
			}
		case "diagram_grid":
			switch key {
			case "background":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.grid_bg = v}
			case "line":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.grid_line = v}
			}
		case "accent":
			switch key {
			case "colour":
				if v, v_ok := hex_to_vec4(raw_val); v_ok {data.accent_colour = v}
			}
		case "glass":
			switch key {
			case "backdrop":
				switch strings.trim_space(strings.to_lower(raw_val, context.temp_allocator)) {
				case "mica":
					data.backdrop = .Mica
				case "acrylic":
					data.backdrop = .Acrylic
				case "none":
					data.backdrop = .None
				}
			case "backdrop_alpha":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.backdrop_alpha = v}
			case "popup_alpha":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.popup_alpha = v}
			}
		case "layout":
			switch key {
			case "corner_rounding":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.corner_rounding = v}
			case "scrollbar_size":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.scrollbar_size = v}
			case "grab_min_size":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.grab_min_size = v}
			case "item_spacing":
				if x, y, p_ok := parse_axis_pair(raw_val); p_ok {
					data.item_spacing_x = f32(x)
					data.item_spacing_y = f32(y)
				}
			case "item_inner_spacing":
				if x, y, p_ok := parse_axis_pair(raw_val); p_ok {
					data.item_inner_spacing_x = f32(x)
					data.item_inner_spacing_y = f32(y)
				}
			case "window_padding":
				if x, y, p_ok := parse_axis_pair(raw_val); p_ok {
					data.window_padding_x = f32(x)
					data.window_padding_y = f32(y)
				}
			case "frame_padding":
				if x, y, p_ok := parse_axis_pair(raw_val); p_ok {
					data.frame_padding_x = f32(x)
					data.frame_padding_y = f32(y)
				}
			case "cell_padding":
				if x, y, p_ok := parse_axis_pair(raw_val); p_ok {
					data.cell_padding_x = f32(x)
					data.cell_padding_y = f32(y)
				}
			case "border_width":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.border_width = v}
			case "frame_border_width":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.frame_border_width = v}
			case "tab_border_width":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok {data.tab_border_width = v}
			}
		}
	}

	return data, true
}

parse_axis_pair :: proc(s: string) -> (x, y: int, ok: bool) {
	parts := strings.split(s, ",")
	defer delete(parts)
	found_x, found_y := false, false
	for part in parts {
		trimmed := strings.trim_space(part)
		colon := strings.index_byte(trimmed, ':')
		if colon < 0 {continue}
		key := strings.trim_space(trimmed[:colon])
		val_str := strings.trim_space(trimmed[colon + 1:])
		val, v_ok := strconv.parse_i64(val_str)
		if !v_ok {continue}
		switch key {
		case "horizontal":
			x = int(val); found_x = true
		case "vertical":
			y = int(val); found_y = true
		}
	}
	return x, y, found_x && found_y
}

// --- Theme discovery ---

THEMES_DIR :: "assets/themes"

ThemeFileInfo :: struct {
	name: string, // Display name from the file's `name` tag (falls back to the file stem).
	path: string, // Path relative to the working directory, ready for parse_ssTheme.
}

// Scan THEMES_DIR for .ssTheme files, reading each file's `name` tag as its
// display name. Sorted by name so the menu order is stable. Unreadable files
// are skipped, and a missing folder yields an empty list — dropping a new
// .ssTheme into the folder is all it takes to extend the theme menu.
discover_themes :: proc(allocator: mem.Allocator) -> (themes: [dynamic]ThemeFileInfo) {
	themes = make([dynamic]ThemeFileInfo, allocator)

	directory_handle, open_err := os.open(THEMES_DIR)
	if open_err != os.ERROR_NONE {return}
	defer os.close(directory_handle)

	files, read_err := os.read_dir(directory_handle, -1, allocator)
	if read_err != os.ERROR_NONE {return}
	defer os.file_info_slice_delete(files, allocator)

	for file in files {
		lower_name := strings.to_lower(file.name, allocator)
		if !strings.has_suffix(lower_name, ".sstheme") do continue

		path := strings.concatenate({THEMES_DIR, "/", file.name}, allocator)
		name := file.name
		if theme_data, theme_ok := parse_ssTheme(path, allocator);
		   theme_ok && len(theme_data.name) > 0 {
			name = theme_data.name
		} else {
			name = strings.trim_suffix(file.name, ".ssTheme")
		}

		append(&themes, ThemeFileInfo{name = strings.clone(name, allocator), path = path})
	}

	sort.quick_sort_proc(themes[:], proc(a, b: ThemeFileInfo) -> int {
		return strings.compare(a.name, b.name)
	})
	return
}

// --- Theme application ---

apply_theme :: proc(data: ThemeData) {
	accent := data.accent_colour
	style := ig.GetStyle()

	backdrop_alpha := clamp(data.backdrop_alpha, 0.0, 1.0)
	popup_alpha := clamp(data.popup_alpha, 0.0, 1.0)

	// Layout
	style.WindowPadding = {data.window_padding_x, data.window_padding_y}
	style.FramePadding = {data.frame_padding_x, data.frame_padding_y}
	style.CellPadding = {data.cell_padding_x, data.cell_padding_y}
	style.ItemSpacing = {data.item_spacing_x, data.item_spacing_y}
	style.ItemInnerSpacing = {data.item_inner_spacing_x, data.item_inner_spacing_y}
	style.ScrollbarSize = data.scrollbar_size
	style.GrabMinSize = data.grab_min_size
	style.WindowRounding = data.corner_rounding
	style.ChildRounding = data.corner_rounding
	style.FrameRounding = data.corner_rounding
	style.PopupRounding = data.corner_rounding
	style.ScrollbarRounding = 12.0
	style.GrabRounding = data.corner_rounding
	style.TabRounding = data.corner_rounding
	style.WindowBorderSize = data.border_width
	style.ChildBorderSize = data.border_width
	style.PopupBorderSize = data.border_width
	style.FrameBorderSize = data.frame_border_width
	style.TabBorderSize = data.tab_border_width

	// ImGui colours
	// Text
	style.Colors[ig.Col.Text] = data.text_main
	style.Colors[ig.Col.TextDisabled] = data.text_muted

	// Backgrounds
	style.Colors[ig.Col.WindowBg] = vec4_with_alpha(data.bg_window, backdrop_alpha)
	style.Colors[ig.Col.ChildBg] = vec4_with_alpha(data.bg_child, backdrop_alpha)
	style.Colors[ig.Col.PopupBg] = vec4_with_alpha(data.bg_popup, popup_alpha)
	style.Colors[ig.Col.MenuBarBg] = vec4_with_alpha(data.title_bg, backdrop_alpha)
	style.Colors[ig.Col.DockingEmptyBg] = vec4_with_alpha(data.bg_window, backdrop_alpha)

	// Borders
	style.Colors[ig.Col.Border] = data.border_main
	style.Colors[ig.Col.BorderShadow] = {0, 0, 0, 0}
	style.Colors[ig.Col.Separator] = data.border_subtle
	style.Colors[ig.Col.TableBorderStrong] = data.border_main
	style.Colors[ig.Col.TableBorderLight] = data.border_subtle

	// Controls
	style.Colors[ig.Col.FrameBg] = data.ctrl_frame
	style.Colors[ig.Col.FrameBgHovered] = data.ctrl_frame_hover
	style.Colors[ig.Col.FrameBgActive] = data.ctrl_frame_active

	// Title bars
	style.Colors[ig.Col.TitleBg] = vec4_with_alpha(data.title_bg, backdrop_alpha)
	style.Colors[ig.Col.TitleBgActive] = vec4_with_alpha(data.title_bg_focus, backdrop_alpha)
	style.Colors[ig.Col.TitleBgCollapsed] = vec4_with_alpha(data.title_bg_faded, backdrop_alpha)

	// Accent-derived colours (alpha table from format spec)
	style.Colors[ig.Col.CheckMark] = accent
	style.Colors[ig.Col.SliderGrab] = vec4_with_alpha(accent, 0.70)
	style.Colors[ig.Col.SliderGrabActive] = accent
	style.Colors[ig.Col.Button] = vec4_with_alpha(accent, 0.08)
	style.Colors[ig.Col.ButtonHovered] = vec4_with_alpha(accent, 0.20)
	style.Colors[ig.Col.ButtonActive] = vec4_with_alpha(accent, 0.35)
	style.Colors[ig.Col.Header] = vec4_with_alpha(accent, 0.12)
	style.Colors[ig.Col.HeaderHovered] = vec4_with_alpha(accent, 0.25)
	style.Colors[ig.Col.HeaderActive] = vec4_with_alpha(accent, 0.40)
	style.Colors[ig.Col.SeparatorHovered] = vec4_with_alpha(accent, 0.78)
	style.Colors[ig.Col.SeparatorActive] = accent
	style.Colors[ig.Col.PlotLines] = accent
	style.Colors[ig.Col.PlotHistogram] = accent
	style.Colors[ig.Col.TextSelectedBg] = vec4_with_alpha(accent, 0.25)
	style.Colors[ig.Col.DragDropTarget] = vec4_with_alpha(accent, 0.90)
	style.Colors[ig.Col.NavCursor] = accent
	style.Colors[ig.Col.DockingPreview] = vec4_with_alpha(accent, 0.40)
	style.Colors[ig.Col.ModalWindowDimBg] = {0, 0, 0, 0.50}

	// Scrollbars
	style.Colors[ig.Col.ScrollbarBg] = vec4_with_alpha(data.bg_window, backdrop_alpha)
	style.Colors[ig.Col.ScrollbarGrab] = data.border_subtle
	style.Colors[ig.Col.ScrollbarGrabHovered] = vec4_with_alpha(data.border_main, 0.87)
	style.Colors[ig.Col.ScrollbarGrabActive] = vec4_with_alpha(data.border_main, 0.75)

	// Tables
	style.Colors[ig.Col.TableHeaderBg] = vec4_with_alpha(data.title_bg, backdrop_alpha)
	style.Colors[ig.Col.TableRowBg] = {0, 0, 0, 0}
	style.Colors[ig.Col.TableRowBgAlt] = {0, 0, 0, 0.03}

	// Tabs
	style.Colors[ig.Col.Tab] = vec4_with_alpha(data.title_bg, backdrop_alpha)
	style.Colors[ig.Col.TabHovered] = data.ctrl_frame
	style.Colors[ig.Col.TabSelected] = data.ctrl_frame
	style.Colors[ig.Col.TabDimmed] = vec4_with_alpha(data.title_bg, backdrop_alpha)
	style.Colors[ig.Col.TabDimmedSelected] = vec4_with_alpha(data.bg_window, backdrop_alpha)

	// ImNodes
	imn.StyleColorsLight()
	imn_style := imn.GetStyle()
	v := data.card_bg
	imn_style.colors[imn.Col.NodeBackground] = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_bg_hovered
	imn_style.colors[imn.Col.NodeBackgroundHovered] = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_bg_selected
	imn_style.colors[imn.Col.NodeBackgroundSelected] = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_outline
	imn_style.colors[imn.Col.NodeOutline] = imn_col(v.x, v.y, v.z, v.w)

	v = data.title_bg
	imn_style.colors[imn.Col.TitleBar] = imn_col(v.x, v.y, v.z, v.w)
	v = data.title_bg_focus
	imn_style.colors[imn.Col.TitleBarHovered] = imn_col(v.x, v.y, v.z, v.w)
	imn_style.colors[imn.Col.TitleBarSelected] = imn_col(v.x, v.y, v.z, v.w)

	v = accent
	imn_style.colors[imn.Col.Link] = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.85)
	imn_style.colors[imn.Col.LinkHovered] = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.72)
	imn_style.colors[imn.Col.LinkSelected] = imn_col(v.x, v.y, v.z, v.w)
	imn_style.colors[imn.Col.Pin] = imn_col(accent.x, accent.y, accent.z, accent.w)
	v = vec4_with_alpha(accent, 0.85)
	imn_style.colors[imn.Col.PinHovered] = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.30)
	imn_style.colors[imn.Col.BoxSelector] = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.80)
	imn_style.colors[imn.Col.BoxSelectorOutline] = imn_col(v.x, v.y, v.z, v.w)

	v = vec4_with_alpha(data.grid_bg, backdrop_alpha)
	imn_style.colors[imn.Col.GridBackground] = imn_col(v.x, v.y, v.z, v.w)
	v = data.grid_line
	imn_style.colors[imn.Col.GridLine] = imn_col(v.x, v.y, v.z, v.w)
	v = data.border_main
	imn_style.colors[imn.Col.GridLinePrimary] = imn_col(v.x, v.y, v.z, v.w)
}

load_icon_texture :: proc(path: string) -> (tex: ig.TextureRef, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != os.ERROR_NONE {
		return {}, false
	}
	defer delete(data)

	w, h, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil {
		return {}, false
	}
	defer stbi.image_free(pixels)

	if w <= 0 || h <= 0 {
		return {}, false
	}

	id: u32
	gl.GenTextures(1, &id)
	if id == 0 {
		return {}, false
	}

	gl.BindTexture(gl.GL_TEXTURE_2D, id)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE)
	gl.PixelStorei(gl.GL_UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.GL_TEXTURE_2D,
		0,
		gl.GL_RGBA8,
		w,
		h,
		0,
		gl.GL_RGBA,
		gl.GL_UNSIGNED_BYTE,
		pixels,
	)

	return ig.TextureRef{_TexID = ig.TextureID(u64(id))}, true
}
