package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:os"
import "core:time"
import "core:c"
import sqlite "vendor/sqlite3"
import sdl "vendor:sdl3"
import ig "vendor/imgui"
import imn "vendor/imnodes"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"
import gl "vendor/gl"

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
	diagram_state: DiagramState
}

DiagramState :: struct {
	seed_table: GlobalTableIndex,
	show_from_seed_table: bool,
	degrees: u8,
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
GlobalTableIndex :: distinct u32

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

// -1 is the sentinel value, having a bool as well provides no real benefit at the moment, that is something that might change
// if we want to use or_* at the call sites.
find_table_by_column :: proc (tables: []Table, column: GlobalColumnIndex) -> int {
	for table, i in tables {
		if table.from_column <= column && column < table.to_column {
			return i
		}
	}
	return -1
}

collect_visible_tables :: proc(schema: ^Schema, state: DiagramState) -> (tables: [dynamic]GlobalTableIndex) {
	if !state.show_from_seed_table || state.degrees == 0 {
		for i in 0..<len(schema.tables) do append(&tables, GlobalTableIndex(u32(i)))
		return
	}

	depth := make(map[GlobalTableIndex]u8, context.temp_allocator)
	defer delete(depth)

	queue := make([dynamic]GlobalTableIndex, context.temp_allocator)
	defer delete(queue)
	head: int

	append(&queue, state.seed_table)
	depth[state.seed_table] = 0
	append(&tables, state.seed_table)

	for head < len(queue) {
		current := queue[head]
		head += 1

		current_depth := depth[current]
		if current_depth >= state.degrees {
			continue
		}

		linked := linked_tables(schema, current)
		for t in linked {
			if !(t in depth) {
				depth[t] = current_depth + 1
				append(&tables, t)
				append(&queue, t)
			}
		}
	}
	return
}

linked_tables :: proc(schema: ^Schema, table_idx: GlobalTableIndex) -> (tables: [dynamic]GlobalTableIndex) {
	table := schema.tables[table_idx]
	if table.has_foreign_keys {
		fks := schema.foreign_keys[table.from_foreign_key:table.to_foreign_key]
		for key in fks {
			t := find_table_by_column(schema.tables[:], key.to)
			if t >= 0 do append(&tables, GlobalTableIndex(u32(t)))
		}
	}
	for key in schema.foreign_keys {
		to_table := find_table_by_column(schema.tables[:], key.to)
		if to_table >= 0 && GlobalTableIndex(u32(to_table)) == table_idx {
			from_table := find_table_by_column(schema.tables[:], key.from)
			if from_table >= 0 {
				append(&tables, GlobalTableIndex(u32(from_table)))
			}
		}
	}
	return
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
	t_init_start := time.tick_now()

	// --- hardware profile (for comparing startup on different machines) ---
	{
		platform := sdl.GetPlatform()
		rams := sdl.GetSystemRAM()
		fmt.eprintfln("[hw] platform=%s cores=%d RAM=%dMB cacheline=%d sse4.1=%v avx2=%v avx512=%v",
			platform, sdl.GetNumLogicalCPUCores(), rams, sdl.GetCPUCacheLineSize(),
			sdl.HasSSE41(), sdl.HasAVX2(), sdl.HasAVX512F())
	}

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

	t_win := time.tick_now()
	window := sdl.CreateWindow("Schema Spelunker", 1600, 900, {.OPENGL, .RESIZABLE, .HIDDEN})
	fmt.eprintfln("[win] CreateWindow(OPENGL 3.3): %.1fms", time.duration_seconds(time.tick_since(t_win)) * 1000)
	if window == nil {
		fmt.eprintfln("SDL3 CreateWindow failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// --- experiment: is the OPENGL pixel-format setup the slow part? ---
	{
		t_plain := time.tick_now()
		plain := sdl.CreateWindow("probe", 320, 200, {.HIDDEN})
		plain_ms := time.duration_seconds(time.tick_since(t_plain)) * 1000
		if plain != nil {
			defer sdl.DestroyWindow(plain)
		}
		t_plain2 := time.tick_now()
		plain2 := sdl.CreateWindow("probe2", 320, 200, {.HIDDEN})
		plain2_ms := time.duration_seconds(time.tick_since(t_plain2)) * 1000
		if plain2 != nil {
			defer sdl.DestroyWindow(plain2)
		}
		fmt.eprintfln("[probe] plain window #1: %.1fms  #2: %.1fms", plain_ms, plain2_ms)
	}

	// --- display diagnostics ---
	{
		display_count: c.int
		displays := sdl.GetDisplays(&display_count)
		fmt.eprintfln("[disp] %d displays:", int(display_count))
		for i in 0..<int(display_count) {
			id := displays[i]
			bounds: sdl.Rect
			sdl.GetDisplayBounds(id, &bounds)
			fmt.eprintfln("[disp]   [%d] %s (%dx%d @ %d,%d)", i, sdl.GetDisplayName(id), int(bounds.w), int(bounds.h), int(bounds.x), int(bounds.y))
		}
		win_disp := sdl.GetDisplayForWindow(window)
		fmt.eprintfln("[disp] Window is on display ID %d (%s)", int(win_disp), sdl.GetDisplayName(win_disp))
	}

	t_ctx := time.tick_now()
	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintfln("SDL3 GL context failed: %s", sdl.GetError())
		return
	}
	defer sdl.GL_DestroyContext(gl_context)
	fmt.eprintfln("[ctx] GL_CreateContext: %.1fms", time.duration_seconds(time.tick_since(t_ctx)) * 1000)

	sdl.GL_MakeCurrent(window, gl_context)
	sdl.GL_SetSwapInterval(0)
	//@Note: adaptive vsync (swap interval -1) causes horrible input lag on
	// some GLX/EGL configurations despite being "adaptive".  We tried it.
	// Instead we run uncapped and pace the loop ourselves with a sleep.

	// Which GPU is actually driving the GL context? On laptops this reveals
	// whether SDL got the iGPU or the discrete GPU (Optimus/dGPU routing).
	fmt.eprintfln("[gl] vendor=%s renderer=%s version=%s",
		gl.GetString(gl.GL_VENDOR), gl.GetString(gl.GL_RENDERER), gl.GetString(gl.GL_VERSION))

	// Fire off the first swap to start any deferred driver work
	// (swap chain buffer allocation, DWM registration), then DON'T wait
	// for it yet — we'll overlap it with ImGui init.
	t_prime := time.tick_now()
	gl.Clear(gl.GL_COLOR_BUFFER_BIT)
	sdl.GL_SwapWindow(window)
	prime_ms := time.duration_seconds(time.tick_since(t_prime)) * 1000
	// Async GPU work is now in flight. Continue with init while it cooks.

	t_imgui := time.tick_now()

	// Keep the window hidden during init to avoid showing a black/empty window.
	// Show it once the GPU is warmed up and we're about to enter the main loop.

	ig.CreateContext()
	defer ig.DestroyContext(nil)
	t_imgui_ctx := time.duration_seconds(time.tick_since(t_imgui)) * 1000
	ig_time := time.tick_now()

	imn.CreateContext()
	defer imn.DestroyContext(nil)
	t_imn_ctx := time.duration_seconds(time.tick_since(ig_time)) * 1000
	theme_time := time.tick_now()

	if theme_data, theme_ok := parse_ssTheme("themes/paper_and_ink_light.ssTheme", context.temp_allocator); theme_ok {
		apply_theme(theme_data)
	}
	t_theme := time.duration_seconds(time.tick_since(theme_time)) * 1000
	font_time := time.tick_now()

	io := ig.GetIO()
	font_filename: cstring = "Roboto.ttf"
	ascii_range := [?]ig.Wchar{32, 126, 0}
	ig.FontAtlas_AddFontFromFileTTF(io.Fonts, font_filename, glyph_ranges = &ascii_range[0])
	t_font := time.duration_seconds(time.tick_since(font_time)) * 1000
	sdl_backend_time := time.tick_now()

	// Init backends
	if !sdl_impl.InitForOpenGL(window, gl_context) {
		fmt.eprintln("ImGui SDL3 backend init failed")
		return
	}
	defer sdl_impl.Shutdown()
	t_sdl_backend := time.duration_seconds(time.tick_since(sdl_backend_time)) * 1000
	gl_backend_time := time.tick_now()

	if !gl_impl.Init("#version 330 core") {
		fmt.eprintln("ImGui OpenGL3 backend init failed")
		return
	}
	defer gl_impl.Shutdown()
	t_gl_backend := time.duration_seconds(time.tick_since(gl_backend_time)) * 1000

	imgui_ms := time.duration_seconds(time.tick_since(t_imgui)) * 1000

	fmt.eprintfln("[init] breakdown: CreateContext=%.1fms ImNodesCtx=%.1fms theme=%.1fms font=%.1fms sdlBackend=%.1fms glBackend=%.1fms  total=%.1fms (prime swap ret=%.1fms)",
		t_imgui_ctx, t_imn_ctx, t_theme, t_font, t_sdl_backend, t_gl_backend, imgui_ms, prime_ms)

	io.ConfigFlags |= {.DockingEnable}

	// --- Render a warm-up frame to force shader+texture upload ---
	// The deferred GPU work from the prime swap should be mostly done by now.
	t_warm := time.tick_now()
	gl_impl.NewFrame()
	sdl_impl.NewFrame()
	ig.NewFrame()
	ig.DockSpaceOverViewport(viewport = ig.GetMainViewport())
	if ig.BeginMainMenuBar() {
		ig.EndMainMenuBar()
	}
	ig.Render()
	gl_impl.RenderDrawData(ig.GetDrawData())
	sdl.GL_SwapWindow(window)
	gl.Finish()
	warm_ms := time.duration_seconds(time.tick_since(t_warm)) * 1000
	fmt.eprintfln("[warmup] Warm-up frame (includes deferred wait): %.1fms", warm_ms)

	FPS_CEILING :: 240.0

	// Pick a multiple of the refresh rate closest to FPS_CEILING (max 4×),
	// then throttle down if the machine can't keep up.
	display_id := sdl.GetDisplayForWindow(window)
	mode := sdl.GetCurrentDisplayMode(display_id)
	refresh_rate := 60.0
	if mode != nil && mode.refresh_rate > 0 {
		refresh_rate = f64(mode.refresh_rate)
	}

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

	fmt.eprintfln("[startup] Total init: %.1fms", time.duration_seconds(time.tick_since(t_init_start)) * 1000)

	// Window was created hidden to avoid showing a black screen during init.
	// Now that the GPU is warmed up, make it visible.
	sdl.ShowWindow(window)

	// Main loop
	event: sdl.Event
	running := true
	t0 := time.tick_now()
	for running {

		// 1. Drain all pending events
		for sdl.PollEvent(&event) {
			if event.type == .QUIT { running = false }
			if event.type == .WINDOW_DISPLAY_CHANGED {
				display_id = sdl.GetDisplayForWindow(window)
				mode = sdl.GetCurrentDisplayMode(display_id)
				refresh_rate = 60.0
				if mode != nil && mode.refresh_rate > 0 {
					refresh_rate = f64(mode.refresh_rate)
				}
				max_multiple = clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
				multiple = clamp(multiple, 1, max_multiple)
				fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
				frame_time_target = 1.0 / fps_target
				fps_full = false
			}
			sdl_impl.ProcessEvent(&event)
		}

		// 2. Inject the absolute latest mouse position before the frame starts
		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)
		io.MousePos = ig.Vec2{mx, my}

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

					tables := collect_visible_tables(&schema, DiagramState{
						seed_table = GlobalTableIndex(0),
						show_from_seed_table = true,
						degrees = 2,
					})

					fmt.eprintfln("Visible: %v", tables)
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

show_node_editor :: proc(app_state: ^AppState) {
	ig.SetNextWindowSize(ig.Vec2{600, 400}, .Appearing)
	defer ig.End()
	if ig.Begin("Diagram") {
		if ig.Button("One Degree") {
			app_state.diagram_state.degrees = 1
			app_state.diagram_state.show_from_seed_table = true
		}
		ig.SameLine()
		if ig.Button("Two Degrees") {
			app_state.diagram_state.degrees = 2
			app_state.diagram_state.show_from_seed_table = true
		}
		ig.SameLine()
		if ig.Button("Show All") {
			app_state.diagram_state.show_from_seed_table = false
		}
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
