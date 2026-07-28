package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:os"
import "core:time"
import "core:strconv"
import sqlite "vendor/sqlite3"
import sdl "vendor:sdl3"
import ig "vendor/imgui"
import imn "vendor/imnodes"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"

BUF_LEN :: 4096
FileDialog :: struct {
	show: bool,
	dirty: bool,
	selected_file: i32,
	path_buffer: [BUF_LEN]u8,
	items_in_folder: [dynamic]DirectoryItem,
	arena: mem.Dynamic_Arena
}

SchemaWindow :: struct {
	show: bool,
	selected_table: i32
}

AppState :: struct {
	schema_name: string,
	schema_dirty: bool,
	schema: Schema,
	file_dialog: FileDialog,
	schema_window: SchemaWindow,
}

DirectoryItemType :: enum {
	Directory,
	File
}

DirectoryItem :: struct {
	name: cstring,
	path: cstring,
	type: DirectoryItemType
}

SQLITE_MAGIC :: [16]u8{ 0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00 }

GlobalColumnIndex :: distinct u32 // All tables will have at least one column therefore we don't need a sentinel value
GlobalForeignKeyIndex :: distinct u32 // There may be tables with no FK, but we will deal with that with a simple bool

Column :: struct {
	name: string,
	type: string,
	composite_key_index: u32,
	not_null: bool
}

Table :: struct {
	name: string,
	from_column: GlobalColumnIndex,
	to_column: GlobalColumnIndex,
	from_foreign_key: GlobalForeignKeyIndex,
	to_foreign_key: GlobalForeignKeyIndex,
	has_foreign_keys: bool
}

ForeignKey :: struct {
	from: GlobalColumnIndex,
	to: GlobalColumnIndex,
	from_column : string, // Temporary value to test that we have things working before we start doing the whole index setup
	to_table: string,
	to_column: string,
	resolved_to_index: bool
}

Schema :: struct {
	database_name: string,

	tables: [dynamic]Table,
	columns: [dynamic]Column,
	foreign_keys: [dynamic]ForeignKey,

	arena: mem.Dynamic_Arena,
	allocator: mem.Allocator
}

convert_odin_string_to_begin_and_end_cstrings :: proc(s: string) -> (begin: cstring, end: cstring) {
	return cstring(raw_data(s)), cstring(&raw_data(s)[len(s)])
}

init_file_dialog :: proc(fd: ^FileDialog) -> (err: os.Error) {
	fd.show = true // Show on startup
	fd.selected_file = -1
	mem.dynamic_arena_init(&fd.arena)
	alloc := mem.dynamic_arena_allocator(&fd.arena)
	fd.items_in_folder = make([dynamic]DirectoryItem, alloc)
	directory_path := os.get_working_directory(context.temp_allocator) or_return
	copy(fd.path_buffer[:], directory_path)
	fd.dirty = true
	return nil
}

main :: proc() {
	if len(os.args) != 2 {
		make_imgui_app()
	} else {
		filename := os.args[1]
		error := print_database_information(filename)
		fmt.printfln("Return code: %v", error)
	}
}

make_imgui_app :: proc() {
	app_state: AppState
	sdl.SetHint("SDL_HINT_IME_SHOW_UI", "1")
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("SDL3 init failed: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()

	// OpenGL 3.3 core context — must be set before CreateWindow
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE))

	window := sdl.CreateWindow("Schema Spelunker", 1600, 900, {.OPENGL, .HIGH_PIXEL_DENSITY, .RESIZABLE})
	if window == nil {
		fmt.eprintfln("SDL3 CreateWindow failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintfln("SDL3 GL context failed: %s", sdl.GetError())
		return
	}
	defer sdl.GL_DestroyContext(gl_context)

	sdl.GL_MakeCurrent(window, gl_context)
	sdl.GL_SetSwapInterval(0)
	//@Note: adaptive vsync (swap interval -1) causes horrible input lag on
	// some GLX/EGL configurations despite being "adaptive".  We tried it.
	// Instead we run uncapped and pace the loop ourselves with a sleep.

	// Init ImGui
	ig.CreateContext()
	defer ig.DestroyContext(nil)

	imn.CreateContext()
	defer imn.DestroyContext(nil)
	if theme_data, theme_ok := parse_ssTheme("themes/paper_and_ink_light.ssTheme", context.temp_allocator); theme_ok {
		apply_theme(theme_data)
	}

	io := ig.GetIO()
	font_filename: cstring = "Roboto.ttf"

	ascii_range := [?]ig.Wchar{32, 126, 0}
	ig.FontAtlas_AddFontFromFileTTF(io.Fonts, font_filename, glyph_ranges = &ascii_range[0])

	// Init backends
	if !sdl_impl.InitForOpenGL(window, gl_context) {
		fmt.eprintln("ImGui SDL3 backend init failed")
		return
	}
	defer sdl_impl.Shutdown()

	if !gl_impl.Init("#version 330 core") {
		fmt.eprintln("ImGui OpenGL3 backend init failed")
		return
	}
	defer gl_impl.Shutdown()

	FPS_CEILING :: 240.0

	// Pick a multiple of the refresh rate closest to FPS_CEILING (max 4×),
	// then throttle down if the machine can't keep up.
	display_id := sdl.GetDisplayForWindow(window)
	mode := sdl.GetCurrentDisplayMode(display_id)
	refresh_rate := f64(max(mode.refresh_rate, 60.0))

	multiple : u32 = 1
	max_multiple : u32 = 1
	fps_target : f64 = refresh_rate
	frame_time_target : f64 = 1.0 / refresh_rate

	{
		m := clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
		multiple = m
		max_multiple = m
		t := min(refresh_rate * f64(m), FPS_CEILING)
		fps_target = t
		frame_time_target = 1.0 / t
	}

	// Frame pacing throttle: 30-frame ring buffer
	FPS_HISTORY :: 30
	fps_ring : [FPS_HISTORY]f64
	fps_idx  : u32
	fps_full := false

	if err := init_file_dialog(&app_state.file_dialog); err != nil {
		fmt.eprintfln("File dialog init failed: %v", err)
		return
	}
	defer mem.dynamic_arena_destroy(&app_state.file_dialog.arena)

	// Main loop
	event: sdl.Event
	running := true
	io.ConfigFlags |= {.DockingEnable}
	t0 := time.tick_now()
	for running {
		// 1. Drain all pending events
		for sdl.PollEvent(&event) {
			if event.type == .QUIT { running = false }
			if event.type == .WINDOW_DISPLAY_CHANGED {
				display_id = sdl.GetDisplayForWindow(window)
				mode = sdl.GetCurrentDisplayMode(display_id)
				refresh_rate = f64(max(mode.refresh_rate, 60.0))
				max_multiple = clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
				multiple = clamp(multiple, 1, max_multiple)
				fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
				frame_time_target = 1.0 / fps_target
				fps_full = false
			}
			sdl_impl.ProcessEvent(&event)
		}

		{
		// 2. Inject the absolute latest mouse position before the frame starts
		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)
		io.MousePos = ig.Vec2{mx, my}
		}

		// 3. Render one frame
		gl_impl.NewFrame()
		sdl_impl.NewFrame()
		ig.NewFrame()
		ig.DockSpaceOverViewport(viewport = ig.GetMainViewport())


		{
			defer ig.Render()
			if app_state.file_dialog.show {
				show_file_dialog(&app_state) or_continue
			}

			show_node_editor(&app_state)

			if app_state.schema_dirty {
				if schema, schema_err := extract_database_information(app_state.schema_name); schema_err == .OK {
					mem.dynamic_arena_destroy(&app_state.schema.arena)
					app_state.schema_dirty = false
					app_state.schema = schema

					for fk in schema.foreign_keys {
						fmt.printfln("%s (%d) ==> %s.%s (%d)", fk.from_column, fk.from, fk.to_table, fk.to_column, fk.to)
					}
				}
			}

			if app_state.schema_window.show do show_schema_window(&app_state)

			if ig.BeginMainMenuBar() {
				if ig.BeginMenu("File") {
					if ig.MenuItem("Open...") do app_state.file_dialog.show = true
					ig.EndMenu()
				}
				if ig.BeginMenu("Theme") {
				if ig.MenuItem("Light") {
					if theme_data, theme_ok := parse_ssTheme("themes/paper_and_ink_light.ssTheme", context.temp_allocator); theme_ok {
						apply_theme(theme_data)
					}
				}
				if ig.MenuItem("Dark") {
					if theme_data, theme_ok := parse_ssTheme("themes/paper_and_ink_dark.ssTheme", context.temp_allocator); theme_ok {
						apply_theme(theme_data)
					}
				}
					ig.EndMenu()
				}
				ig.EndMainMenuBar()
			}
		}

		gl_impl.RenderDrawData(ig.GetDrawData())

		sdl.GL_SwapWindow(window)

		// 4. Frame pace: sleep for the remaining time to hit target FPS.
		// No busy-wait — a fraction of a millisecond early is invisible.
		elapsed := time.duration_seconds(time.tick_since(t0))
		if elapsed < frame_time_target {
			remaining := frame_time_target - elapsed
			time.sleep(time.Duration(1e9 * remaining))
		}

		// 5. Record actual FPS and throttle down if needed
		{
			actual := 1.0 / max(elapsed, 1e-9)
			fps_ring[fps_idx] = actual
			fps_idx = (fps_idx + 1) % FPS_HISTORY
			if fps_idx == 0 { fps_full = true }

			if fps_full {
				avg := 0.0
				for v in fps_ring { avg += v }
				avg /= FPS_HISTORY

				if multiple > 1 && avg < fps_target * 0.8 {
					multiple -= 1
					fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
					frame_time_target = 1.0 / fps_target
					fps_full = false
				}

				if multiple < max_multiple && avg > fps_target * 0.95 {
					multiple += 1
					fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
					frame_time_target = 1.0 / fps_target
					fps_full = false
				}
			}
		}

		t0 = time.tick_now()
	}
}

is_sqlite_database :: proc(path: string) -> bool {
    handle, err := os.open(path)
    if err != os.ERROR_NONE do return false
    defer os.close(handle)

    buf: [16]u8
    bytes_read, read_err := os.read(handle, buf[:])
    if read_err != os.ERROR_NONE || bytes_read < 16 do return false

    return buf == SQLITE_MAGIC
}

show_file_dialog :: proc(app_state: ^AppState) -> (os_err: os.Error) {
	ig.SetNextWindowSize(ig.Vec2{300, 500}, .Appearing)
	
	// @Note: This looks pretty odd but for a window you need the end to be called regardless of the result of ig.Begin(...)
	defer ig.End()
	if ig.Begin("Open File...") {

		if app_state.file_dialog.dirty {
			mem.dynamic_arena_free_all(&app_state.file_dialog.arena)
			alloc := mem.dynamic_arena_allocator(&app_state.file_dialog.arena)
		
			directory_handle, error := os.open(string(app_state.file_dialog.path_buffer[:]))
			defer os.close(directory_handle)

			app_state.file_dialog.items_in_folder = make([dynamic]DirectoryItem, alloc)

			if error == os.ERROR_NONE {

				files := os.read_dir(directory_handle, -1, context.temp_allocator) or_return
				defer os.file_info_slice_delete(files, context.temp_allocator)

				parent_path, path_alloc_error := os.clean_path(fmt.aprintf("%s%r..", cstring(&app_state.file_dialog.path_buffer[0]), os.Path_Separator, allocator=alloc), alloc)
				if path_alloc_error == .None {
					append(&app_state.file_dialog.items_in_folder, DirectoryItem{
						name = "../",
						path = strings.clone_to_cstring(parent_path, alloc),
						type = .Directory
					})
				}

				for f in files {
					item: DirectoryItem
					item.name = strings.clone_to_cstring(f.name, alloc)
					path := fmt.aprintf("%s%r%s", cstring(&app_state.file_dialog.path_buffer[0]), os.Path_Separator, item.name, allocator=alloc)
					cleaned, err := os.clean_path(path, alloc)
					
					if err == .None {
						item.path = strings.clone_to_cstring(cleaned, alloc)
					} else {
						item.path = strings.clone_to_cstring(path, alloc)
					}

					if f.type == .Directory {
						item.type = .Directory
					} else {
						item.type = .File
					}

					if item.type == .Directory || is_sqlite_database(string(item.path)) {
						append(&app_state.file_dialog.items_in_folder, item)
					}
				}
			}
			app_state.file_dialog.dirty = false
		}

	
		style := ig.GetStyle()
		ig.PushItemWidth(ig.GetContentRegionAvail().x)
		if ig.InputText("##path", cstring(&app_state.file_dialog.path_buffer[0]), BUF_LEN) do app_state.file_dialog.dirty = true
		ig.PopItemWidth()
	
		avail := ig.GetContentRegionAvail()
		listbox_height := avail.y - ig.GetFrameHeightWithSpacing() - style.ItemSpacing.y
		if ig.BeginListBox("##folder", ig.Vec2{avail.x, listbox_height}) {

			// @Todo: Should we do something to have the folders come first?
			for item, i in app_state.file_dialog.items_in_folder {
				is_selected := i32(i) == app_state.file_dialog.selected_file
				switch item.type {
				case .File:
					
					if ig.SelectableBoolPtr(item.name, &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							delete(app_state.schema_name)
							fmt.printfln("OPEN: %s", item.path)
							app_state.schema_name = strings.clone(string(item.path))
							app_state.schema_dirty = true
							app_state.schema_window.show = true
						} else {
							app_state.file_dialog.selected_file = i32(i)
						}
					}

				case .Directory:
					if ig.SelectableBoolPtr(fmt.ctprint("[DIR]", item.name), &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							app_state.file_dialog.dirty = true
							app_state.file_dialog.path_buffer = {}
							copy(app_state.file_dialog.path_buffer[:], string(item.path))
						} else {
							app_state.file_dialog.selected_file = i32(i)
						}
					}
				}
				if is_selected {
					ig.SetItemDefaultFocus()
				}
			}
			ig.EndListBox()
		}
	
		if ig.Button("Cancel") do app_state.file_dialog.show = false
		ig.SameLine()
		ig.Button("Open")
	}

	return
}

imn_col :: proc(r, g, b: f32, a: f32 = 1.0) -> u32 {
	ri := u8(clamp(r, 0.0, 1.0) * 255.0)
	gi := u8(clamp(g, 0.0, 1.0) * 255.0)
	bi := u8(clamp(b, 0.0, 1.0) * 255.0)
	ai := u8(clamp(a, 0.0, 1.0) * 255.0)
	return u32(ri) | (u32(gi) << 8) | (u32(bi) << 16) | (u32(ai) << 24)
}

show_node_editor :: proc(app_state: ^AppState) {
	ig.SetNextWindowSize(ig.Vec2{600, 400}, .Appearing)
	defer ig.End()
	if ig.Begin("Diagram") {
		ig.Button("One Degree")
		ig.SameLine()
		ig.Button("Two Degrees")
		imn.BeginNodeEditor()

		for table, i in app_state.schema.tables {
			imn.BeginNode(i32(i))
			imn.BeginNodeTitleBar()
			ig.TextUnformatted(convert_odin_string_to_begin_and_end_cstrings(table.name))
			imn.EndNodeTitleBar()

			for column in app_state.schema.columns[table.from_column:table.to_column] {
				ig.TextUnformatted(convert_odin_string_to_begin_and_end_cstrings(column.name))
			}
			imn.EndNode()
		}

		imn.EndNodeEditor()
	}
}

show_schema_window :: proc(app_state: ^AppState) {
	schema := app_state.schema
	ig.SetNextWindowSize(ig.Vec2{800, 600}, .Appearing)
	defer ig.End()
	if ig.Begin(strings.clone_to_cstring(schema.database_name, context.temp_allocator)) {
		avail := ig.GetContentRegionAvail()

		is_selected := false
		if ig.BeginListBox("##folder", avail) {
			for table, i in schema.tables {
				is_selected = i32(i) == app_state.schema_window.selected_table
				if ig.SelectableBoolPtr(strings.clone_to_cstring(table.name, context.temp_allocator), &is_selected) {
					app_state.schema_window.selected_table = i32(i)
				}
			}
			ig.EndListBox()
		}
	}
}

// --- Theme loader (file-based .ssTheme) ---

ThemeData :: struct {
	name: string,

	// [text]
	text_main:     ig.Vec4,  // 0.12, 0.12, 0.12, 1.00 → #1F1F1F
	text_muted:    ig.Vec4,  // #8C8C8C

	// [background]
	bg_window:     ig.Vec4,  // #F5F5F0
	bg_child:      ig.Vec4,  // #F5F5F0
	bg_popup:      ig.Vec4,  // #FFFFFF

	// [controls]
	ctrl_frame:         ig.Vec4,  // #FFFFFF
	ctrl_frame_hover:   ig.Vec4,  // #E5EAF2
	ctrl_frame_active:  ig.Vec4,  // #D9E0EB

	// [title_bar]
	title_bg:         ig.Vec4,  // #EBEBE6
	title_bg_focus:   ig.Vec4,  // #E0E0DB
	title_bg_faded:   ig.Vec4,  // #EBEBE6 with A=0.75

	// [table_card]
	card_bg:          ig.Vec4,  // #FFFFFF
	card_bg_hovered:  ig.Vec4,  // #F9F9F2
	card_bg_selected: ig.Vec4,  // #F4F4ED
	card_outline:     ig.Vec4,  // #BFBFB8

	// [border]
	border_main:   ig.Vec4,  // #BFBFB8
	border_subtle: ig.Vec4,  // #D9D9D1

	// [diagram_grid]
	grid_bg:   ig.Vec4,  // #F5F5F0
	grid_line: ig.Vec4,  // #D9D9D1

	// [accent]
	accent_colour: ig.Vec4,  // #2C5796

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

hex_digit :: proc(c: u8) -> u8 {
	switch {
	case '0' <= c && c <= '9': return c - '0'
	case 'a' <= c && c <= 'f': return c - 'a' + 10
	case 'A' <= c && c <= 'F': return c - 'A' + 10
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

default_theme_data :: proc() -> ThemeData {
	return {
		name = "Default",

		text_main       = {0.12, 0.12, 0.12, 1.00},
		text_muted      = {0.55, 0.55, 0.55, 1.00},

		bg_window       = {0.96, 0.96, 0.94, 1.00},
		bg_child        = {0.96, 0.96, 0.94, 1.00},
		bg_popup        = {1.00, 1.00, 1.00, 1.00},

		ctrl_frame         = {1.00, 1.00, 1.00, 1.00},
		ctrl_frame_hover   = {0.90, 0.92, 0.95, 1.00},
		ctrl_frame_active  = {0.85, 0.88, 0.92, 1.00},

		title_bg         = {0.92, 0.92, 0.90, 1.00},
		title_bg_focus   = {0.88, 0.88, 0.86, 1.00},
		title_bg_faded   = {0.92, 0.92, 0.90, 0.75},

		card_bg          = {1.00, 1.00, 1.00, 1.00},
		card_bg_hovered  = {0.98, 0.98, 0.95, 1.00},
		card_bg_selected = {0.96, 0.96, 0.93, 1.00},
		card_outline     = {0.75, 0.75, 0.72, 1.00},

		border_main   = {0.75, 0.75, 0.72, 1.00},
		border_subtle = {0.85, 0.85, 0.82, 1.00},

		grid_bg   = {0.96, 0.96, 0.94, 1.00},
		grid_line = {0.85, 0.85, 0.82, 1.00},

		accent_colour = {0.17, 0.34, 0.59, 1.00},

		corner_rounding      = 2.0,
		scrollbar_size       = 14.0,
		grab_min_size        = 12.0,
		item_spacing_x       = 8.0,
		item_spacing_y       = 6.0,
		item_inner_spacing_x = 6.0,
		item_inner_spacing_y = 4.0,
		window_padding_x     = 12.0,
		window_padding_y     = 12.0,
		frame_padding_x      = 6.0,
		frame_padding_y      = 4.0,
		cell_padding_x       = 6.0,
		cell_padding_y       = 4.0,
		border_width         = 1.0,
		frame_border_width   = 1.0,
		tab_border_width     = 1.0,
	}
}

parse_ssTheme :: proc(filename: string, allocator: mem.Allocator) -> (ThemeData, bool) {
	data := default_theme_data()

	file_bytes, err := os.read_entire_file(filename, allocator)
	if err != os.ERROR_NONE { return data, false }
	defer delete(file_bytes, allocator)

	content := string(file_bytes)
	current_section: string

	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 { continue }
		if trimmed[0] == '#' { continue }

		if trimmed[0] == '[' {
			close := strings.index_byte(trimmed, ']')
			if close > 1 {
				current_section = strings.trim_space(trimmed[1:close])
			}
			continue
		}

		eq := strings.index_byte(trimmed, '=')
		if eq < 0 { continue }

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
			case "name": data.name = strings.clone(raw_val, allocator)
			}
		case "text":
			switch key {
			case "main":  if v, v_ok := hex_to_vec4(raw_val); v_ok { data.text_main = v }
			case "muted": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.text_muted = v }
			}
		case "background":
			switch key {
			case "window": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.bg_window = v }
			case "child":  if v, v_ok := hex_to_vec4(raw_val); v_ok { data.bg_child = v }
			case "popup":  if v, v_ok := hex_to_vec4(raw_val); v_ok { data.bg_popup = v }
			}
		case "controls":
			switch key {
			case "frame":        if v, v_ok := hex_to_vec4(raw_val); v_ok { data.ctrl_frame = v }
			case "frame_hover":   if v, v_ok := hex_to_vec4(raw_val); v_ok { data.ctrl_frame_hover = v }
			case "frame_active":  if v, v_ok := hex_to_vec4(raw_val); v_ok { data.ctrl_frame_active = v }
			}
		case "title_bar":
			switch key {
			case "background":       if v, v_ok := hex_to_vec4(raw_val); v_ok { data.title_bg = v }
			case "background_focus": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.title_bg_focus = v }
			case "background_faded": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.title_bg_faded = v }
			}
		case "table_card":
			switch key {
			case "background":          if v, v_ok := hex_to_vec4(raw_val); v_ok { data.card_bg = v }
			case "background_hovered":   if v, v_ok := hex_to_vec4(raw_val); v_ok { data.card_bg_hovered = v }
			case "background_selected":  if v, v_ok := hex_to_vec4(raw_val); v_ok { data.card_bg_selected = v }
			case "outline":             if v, v_ok := hex_to_vec4(raw_val); v_ok { data.card_outline = v }
			}
		case "border":
			switch key {
			case "main":   if v, v_ok := hex_to_vec4(raw_val); v_ok { data.border_main = v }
			case "subtle": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.border_subtle = v }
			}
		case "diagram_grid":
			switch key {
			case "background": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.grid_bg = v }
			case "line":       if v, v_ok := hex_to_vec4(raw_val); v_ok { data.grid_line = v }
			}
		case "accent":
			switch key {
			case "colour": if v, v_ok := hex_to_vec4(raw_val); v_ok { data.accent_colour = v }
			}
		case "layout":
			switch key {
			case "corner_rounding":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.corner_rounding = v }
			case "scrollbar_size":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.scrollbar_size = v }
			case "grab_min_size":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.grab_min_size = v }
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
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.border_width = v }
			case "frame_border_width":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.frame_border_width = v }
			case "tab_border_width":
				if v, v_ok := strconv.parse_f32(raw_val); v_ok { data.tab_border_width = v }
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
		if colon < 0 { continue }
		key := strings.trim_space(trimmed[:colon])
		val_str := strings.trim_space(trimmed[colon + 1:])
		val, v_ok := strconv.parse_i64(val_str)
		if !v_ok { continue }
		switch key {
		case "horizontal": x = int(val); found_x = true
		case "vertical":   y = int(val); found_y = true
		}
	}
	return x, y, found_x && found_y
}

apply_theme :: proc(data: ThemeData) {
	accent := data.accent_colour
	style := ig.GetStyle()

	// Layout
	style.WindowPadding        = {data.window_padding_x, data.window_padding_y}
	style.FramePadding         = {data.frame_padding_x, data.frame_padding_y}
	style.CellPadding          = {data.cell_padding_x, data.cell_padding_y}
	style.ItemSpacing          = {data.item_spacing_x, data.item_spacing_y}
	style.ItemInnerSpacing     = {data.item_inner_spacing_x, data.item_inner_spacing_y}
	style.ScrollbarSize        = data.scrollbar_size
	style.GrabMinSize          = data.grab_min_size
	style.WindowRounding       = data.corner_rounding
	style.ChildRounding        = data.corner_rounding
	style.FrameRounding        = data.corner_rounding
	style.PopupRounding        = data.corner_rounding
	style.ScrollbarRounding    = 12.0
	style.GrabRounding         = data.corner_rounding
	style.TabRounding          = data.corner_rounding
	style.WindowBorderSize     = data.border_width
	style.ChildBorderSize      = data.border_width
	style.PopupBorderSize       = data.border_width
	style.FrameBorderSize      = data.frame_border_width
	style.TabBorderSize        = data.tab_border_width

	// ImGui colours
	// Text
	style.Colors[ig.Col.Text]         = data.text_main
	style.Colors[ig.Col.TextDisabled] = data.text_muted

	// Backgrounds
	style.Colors[ig.Col.WindowBg]         = data.bg_window
	style.Colors[ig.Col.ChildBg]          = data.bg_child
	style.Colors[ig.Col.PopupBg]          = data.bg_popup
	style.Colors[ig.Col.MenuBarBg]        = data.title_bg
	style.Colors[ig.Col.DockingEmptyBg]   = data.bg_window

	// Borders
	style.Colors[ig.Col.Border]            = data.border_main
	style.Colors[ig.Col.BorderShadow]      = {0, 0, 0, 0}
	style.Colors[ig.Col.Separator]         = data.border_subtle
	style.Colors[ig.Col.TableBorderStrong] = data.border_main
	style.Colors[ig.Col.TableBorderLight]  = data.border_subtle

	// Controls
	style.Colors[ig.Col.FrameBg]         = data.ctrl_frame
	style.Colors[ig.Col.FrameBgHovered]  = data.ctrl_frame_hover
	style.Colors[ig.Col.FrameBgActive]   = data.ctrl_frame_active

	// Title bars
	style.Colors[ig.Col.TitleBg]          = data.title_bg
	style.Colors[ig.Col.TitleBgActive]   = data.title_bg_focus
	style.Colors[ig.Col.TitleBgCollapsed] = data.title_bg_faded

	// Accent-derived colours (alpha table from format spec)
	style.Colors[ig.Col.CheckMark]         = accent
	style.Colors[ig.Col.SliderGrab]        = vec4_with_alpha(accent, 0.70)
	style.Colors[ig.Col.SliderGrabActive]  = accent
	style.Colors[ig.Col.Button]            = vec4_with_alpha(accent, 0.08)
	style.Colors[ig.Col.ButtonHovered]     = vec4_with_alpha(accent, 0.20)
	style.Colors[ig.Col.ButtonActive]      = vec4_with_alpha(accent, 0.35)
	style.Colors[ig.Col.Header]            = vec4_with_alpha(accent, 0.12)
	style.Colors[ig.Col.HeaderHovered]     = vec4_with_alpha(accent, 0.25)
	style.Colors[ig.Col.HeaderActive]      = vec4_with_alpha(accent, 0.40)
	style.Colors[ig.Col.SeparatorHovered]  = vec4_with_alpha(accent, 0.78)
	style.Colors[ig.Col.SeparatorActive]   = accent
	style.Colors[ig.Col.PlotLines]         = accent
	style.Colors[ig.Col.PlotHistogram]     = accent
	style.Colors[ig.Col.TextSelectedBg]    = vec4_with_alpha(accent, 0.25)
	style.Colors[ig.Col.DragDropTarget]    = vec4_with_alpha(accent, 0.90)
	style.Colors[ig.Col.NavCursor]         = accent
	style.Colors[ig.Col.DockingPreview]    = vec4_with_alpha(accent, 0.40)
	style.Colors[ig.Col.ModalWindowDimBg]  = {0, 0, 0, 0.50}

	// Scrollbars
	style.Colors[ig.Col.ScrollbarBg]          = data.bg_window
	style.Colors[ig.Col.ScrollbarGrab]        = data.border_subtle
	style.Colors[ig.Col.ScrollbarGrabHovered] = vec4_with_alpha(data.border_main, 0.87)
	style.Colors[ig.Col.ScrollbarGrabActive]  = vec4_with_alpha(data.border_main, 0.75)

	// Tables
	style.Colors[ig.Col.TableHeaderBg]     = data.title_bg
	style.Colors[ig.Col.TableRowBg]        = {0, 0, 0, 0}
	style.Colors[ig.Col.TableRowBgAlt]     = {0, 0, 0, 0.03}

	// Tabs
	style.Colors[ig.Col.Tab]               = data.title_bg
	style.Colors[ig.Col.TabHovered]        = data.ctrl_frame
	style.Colors[ig.Col.TabSelected]       = data.ctrl_frame
	style.Colors[ig.Col.TabDimmed]         = data.title_bg
	style.Colors[ig.Col.TabDimmedSelected] = data.bg_window

	// ImNodes
	imn.StyleColorsLight()
	imn_style := imn.GetStyle()
	v := data.card_bg
	imn_style.colors[imn.Col.NodeBackground]             = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_bg_hovered
	imn_style.colors[imn.Col.NodeBackgroundHovered]      = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_bg_selected
	imn_style.colors[imn.Col.NodeBackgroundSelected]     = imn_col(v.x, v.y, v.z, v.w)
	v = data.card_outline
	imn_style.colors[imn.Col.NodeOutline]                = imn_col(v.x, v.y, v.z, v.w)

	v = data.title_bg
	imn_style.colors[imn.Col.TitleBar]                   = imn_col(v.x, v.y, v.z, v.w)
	v = data.title_bg_focus
	imn_style.colors[imn.Col.TitleBarHovered]            = imn_col(v.x, v.y, v.z, v.w)
	imn_style.colors[imn.Col.TitleBarSelected]           = imn_col(v.x, v.y, v.z, v.w)

	v = accent
	imn_style.colors[imn.Col.Link]                       = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.85)
	imn_style.colors[imn.Col.LinkHovered]                = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.72)
	imn_style.colors[imn.Col.LinkSelected]               = imn_col(v.x, v.y, v.z, v.w)
	imn_style.colors[imn.Col.Pin]                        = imn_col(accent.x, accent.y, accent.z, accent.w)
	v = vec4_with_alpha(accent, 0.85)
	imn_style.colors[imn.Col.PinHovered]                 = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.30)
	imn_style.colors[imn.Col.BoxSelector]                = imn_col(v.x, v.y, v.z, v.w)
	v = vec4_with_alpha(accent, 0.80)
	imn_style.colors[imn.Col.BoxSelectorOutline]         = imn_col(v.x, v.y, v.z, v.w)

	v = data.grid_bg
	imn_style.colors[imn.Col.GridBackground]             = imn_col(v.x, v.y, v.z, v.w)
	v = data.grid_line
	imn_style.colors[imn.Col.GridLine]                   = imn_col(v.x, v.y, v.z, v.w)
	v = data.border_main
	imn_style.colors[imn.Col.GridLinePrimary]            = imn_col(v.x, v.y, v.z, v.w)
}

init_schema :: proc(schema: ^Schema) {
	mem.dynamic_arena_init(&schema.arena)
	schema.allocator = mem.dynamic_arena_allocator(&schema.arena)
}

print_database_information :: proc(filename: string) -> sqlite.SQLiteError {
	schema := extract_database_information(filename) or_return
	defer mem.dynamic_arena_destroy(&schema.arena)

	for table in schema.tables {
		fmt.printfln("TABLE: %v", table.name)

		for column in schema.columns[table.from_column:table.to_column] {
			not_null: string
			pk: string
			if column.not_null || column.composite_key_index > 0 do not_null = "NOT_NULL"
			if column.composite_key_index > 0 do pk = fmt.tprintf("PRIMARY KEY INDEX: %v", column.composite_key_index)
			fmt.printfln("- %v OF %v %s %s", column.name, column.type, not_null, pk)
		}
	}
	return .OK
}

extract_database_information :: proc(filename: string) -> (schema: Schema, error: sqlite.SQLiteError) {
	cfilename := strings.clone_to_cstring(filename, context.temp_allocator)
	db := sqlite.open(cfilename) or_return
	defer sqlite.close(db)
	
	table_stmt := sqlite.prepare(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';") or_return
	defer sqlite.finalize(table_stmt)

	// We have a database, no point initialising the struct before here as we might not have anything in there, so no need to alloc

	init_schema(&schema)
	defer if error != .OK { mem.dynamic_arena_destroy(&schema.arena) }

	old_allocator := context.allocator
	context.allocator = schema.allocator
	defer context.allocator = old_allocator

	schema.database_name = strings.clone(filename)

	current_column: GlobalColumnIndex = 0
	current_fk: GlobalForeignKeyIndex = 0

	col_indices := make(map[[2]string]GlobalColumnIndex, context.temp_allocator)

	for sqlite.step(table_stmt) == .ROW {
		table: Table

		table.name = sqlite.column_string(table_stmt, 0)
		table.from_column = current_column

		column_stmt := sqlite.prepare(db, "SELECT * FROM pragma_table_info(?)") or_return
		defer sqlite.finalize(column_stmt)

		sqlite.bind_text(column_stmt, 1, strings.clone_to_cstring(table.name, context.temp_allocator)) or_return

		for sqlite.step(column_stmt) == .ROW {
			column: Column
			column.name = sqlite.column_string(column_stmt, 1)
			column.type = sqlite.column_string(column_stmt, 2)
			column.not_null = sqlite.column_bool(column_stmt, 3)
			column.composite_key_index = sqlite.column_u32(column_stmt, 5)

			append(&schema.columns, column)
			col_indices[[2]string{table.name, column.name}] = current_column
			current_column += 1
		}

		table.to_column = current_column

		fk_stmt := sqlite.prepare(db, "SELECT * FROM pragma_foreign_key_list(?)") or_return
		defer sqlite.finalize(fk_stmt)

		sqlite.bind_text(fk_stmt, 1, strings.clone_to_cstring(table.name, context.temp_allocator)) or_return

		for sqlite.step(fk_stmt) == .ROW {
			if !table.has_foreign_keys {
				table.has_foreign_keys = true
				table.from_foreign_key = current_fk
			}

			fk: ForeignKey
			ok: bool
			fk.from_column = sqlite.column_string(fk_stmt, 3)
			fk.to_table = sqlite.column_string(fk_stmt, 2)
			fk.to_column = sqlite.column_string(fk_stmt, 4)
			fk.from, ok = col_indices[[2]string{table.name, fk.from_column}]

			if !ok {
				fmt.eprintfln("No column index found for %s.%s", table.name, fk.from_column)
			}

			append(&schema.foreign_keys, fk)
			current_fk += 1
		}

		if table.has_foreign_keys do table.to_foreign_key = current_fk

		append(&schema.tables, table)
	}

	for &fk in schema.foreign_keys {
		fk.to = col_indices[[2]string{fk.to_table, fk.to_column}] or_continue
		fk.resolved_to_index = true
	}

	return schema, .OK
}
