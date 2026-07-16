package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:os"
import "core:time"
import sqlite "vendor/sqlite3"
import sdl "vendor:sdl3"
import ig "vendor/imgui"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"

Window :: struct {
	show: bool
}

BUF_LEN :: 1024
FileDialog :: struct {
	using window: Window,
	selected_file: i32,
	path_buffer: [BUF_LEN]u8,
	items_in_folder: [dynamic]cstring,
	arena: mem.Dynamic_Arena,
}

make_file_dialog :: proc() -> FileDialog {
	fd: FileDialog
	fd.show = true //Show on startup
	fd.selected_file = -1
	mem.dynamic_arena_init(&fd.arena)
	alloc := mem.dynamic_arena_allocator(&fd.arena)
	fd.items_in_folder = make([dynamic]cstring, alloc)
	return fd
}

main :: proc() {
	fmt.println("Hellope! Welcome to the Schema Spelunker")

	if len(os.args) != 2 {
		make_imgui_app()
	} else {
		filename := os.args[1]
		error := extract_database_information(filename)
		fmt.printfln("Return code: %v", error)
	}
}

make_imgui_app :: proc() {

	sdl.SetHint("SDL_HINT_IME_SHOW_UI", "1")
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("SDL3 init failed: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("Schema Spelunker", 1600, 900, {.OPENGL, .HIGH_PIXEL_DENSITY, .RESIZABLE})
	if window == nil {
		fmt.eprintfln("SDL3 CreateWindow failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// OpenGL 3.3 core context
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLProfile.CORE))

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
	set_theme()

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
	fps_target : f64 = refresh_rate
	frame_time_target : f64 = 1.0 / refresh_rate

	{
		m := clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
		t := min(refresh_rate * f64(m), FPS_CEILING)
		fps_target = t
		frame_time_target = 1.0 / t
		multiple = m
	}



	// Frame pacing throttle: 30-frame ring buffer
	FPS_HISTORY :: 30
	fps_ring : [FPS_HISTORY]f64
	fps_idx  : u32
	fps_full := false

	file_dialog := make_file_dialog()
	defer {
		delete(file_dialog.items_in_folder)
		mem.dynamic_arena_destroy(&file_dialog.arena)
	}

	// Main loop
	event: sdl.Event
	running := true
	io.ConfigFlags |= {.DockingEnable}
	t0 := time.tick_now()
	for running {
		// 1. Drain all pending events
		for sdl.PollEvent(&event) {
			if event.type == .QUIT { running = false }
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

		if file_dialog.show {
			show_file_dialog(&file_dialog) or_continue
		}

		ig.Render()
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

			if fps_full && multiple > 1 {
				avg := 0.0
				for v in fps_ring { avg += v }
				avg /= FPS_HISTORY

				THROTTLE_RATIO :: 0.8
				if avg < fps_target * THROTTLE_RATIO {
					multiple -= 1
					t := min(refresh_rate * f64(multiple), FPS_CEILING)
					fps_target = t
					frame_time_target = 1.0 / t
					fps_full = false
				}
			}
		}

		t0 = time.tick_now()
	}
}

show_file_dialog :: proc(file_dialog: ^FileDialog) -> os.Error {
	ig.SetNextWindowSize(ig.Vec2{300, 500}, .Appearing)
	if ig.Begin("Open File...") {
		mem.dynamic_arena_free_all(&file_dialog.arena)
		alloc := mem.dynamic_arena_allocator(&file_dialog.arena)
	
		directory_path := os.get_working_directory(context.temp_allocator) or_return
		directory_handle := os.open(directory_path) or_return
		defer os.close(directory_handle)

		file_dialog.path_buffer = {}
		copy(file_dialog.path_buffer[:], directory_path)

		files := os.read_dir(directory_handle, -1, context.temp_allocator) or_return
		defer os.file_info_slice_delete(files, context.temp_allocator)
	
		file_dialog.items_in_folder = make([dynamic]cstring, alloc)
		append(&file_dialog.items_in_folder, "../")
		for f in files {
			name: cstring
			if f.type == .Directory {
				name = strings.clone_to_cstring(fmt.tprintf("%v/", f.name), alloc)
			} else {
				name = strings.clone_to_cstring(f.name, alloc)
			}
			append(&file_dialog.items_in_folder, name)
		}
	
		style := ig.GetStyle()
		ig.PushItemWidth(ig.GetContentRegionAvail().x)
		ig.InputText("##path", cstring(&file_dialog.path_buffer[0]), BUF_LEN)
		ig.PopItemWidth()
	
		avail := ig.GetContentRegionAvail()
		listbox_height := avail.y - ig.GetFrameHeightWithSpacing() - style.ItemSpacing.y
		if ig.BeginListBox("##folder", ig.Vec2{avail.x, listbox_height}) {
			for item, i in file_dialog.items_in_folder {
				is_selected := i32(i) == file_dialog.selected_file
				if ig.SelectableBoolPtr(item, &is_selected) {
					file_dialog.selected_file = i32(i)
				}
				if is_selected {
					ig.SetItemDefaultFocus()
				}
			}
			ig.EndListBox()
		}
	
		if ig.Button("Cancel") do file_dialog.show = false
		ig.SameLine()
		ig.Button("Open")
	}
	ig.End()

	return nil
}

rgba :: proc(r, g, b: u8, a: f32 = 1.0) -> ig.Vec4 {
	return {f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, a}
}

set_theme :: proc() {
	style := ig.GetStyle()

	style.WindowRounding = 4.0
	style.FrameRounding = 3.0
	style.PopupRounding = 4.0
	style.ScrollbarRounding = 3.0
	style.GrabRounding = 3.0
	style.TabRounding = 3.0
	style.ChildRounding = 4.0

	style.WindowBorderSize = 1.0
	style.FrameBorderSize = 0.0
	style.PopupBorderSize = 1.0
	style.ChildBorderSize = 1.0
	style.TabBorderSize = 1.0

	style.WindowPadding = {10.0, 10.0}
	style.FramePadding = {8.0, 4.0}
	style.ItemSpacing = {8.0, 5.0}
	style.ItemInnerSpacing = {5.0, 5.0}
	style.IndentSpacing = 18.0
	style.ScrollbarSize = 12.0
	style.GrabMinSize = 10.0
	style.WindowMinSize = {60.0, 60.0}

	style.Colors[ig.Col.Text]              = rgba(205, 214, 244)
	style.Colors[ig.Col.TextDisabled]      = rgba(127, 132, 156)
	style.Colors[ig.Col.WindowBg]          = rgba(24,  25,  38)
	style.Colors[ig.Col.ChildBg]           = rgba(20,  21,  33)
	style.Colors[ig.Col.PopupBg]           = rgba(31,  33,  48)
	style.Colors[ig.Col.Border]            = rgba(60,  63,  85)
	style.Colors[ig.Col.BorderShadow]      = rgba(0,    0,   0, 0)
	style.Colors[ig.Col.FrameBg]           = rgba(40,  42,  60)
	style.Colors[ig.Col.FrameBgHovered]    = rgba(54,  56,  78)
	style.Colors[ig.Col.FrameBgActive]     = rgba(68,  71,  97)
	style.Colors[ig.Col.TitleBg]           = rgba(20,  21,  33)
	style.Colors[ig.Col.TitleBgActive]     = rgba(35,  37,  54)
	style.Colors[ig.Col.TitleBgCollapsed]  = rgba(20,  21,  33)
	style.Colors[ig.Col.MenuBarBg]         = rgba(31,  33,  48)
	style.Colors[ig.Col.ScrollbarBg]       = rgba(24,  25,  38)
	style.Colors[ig.Col.ScrollbarGrab]     = rgba(60,  63,  85)
	style.Colors[ig.Col.ScrollbarGrabHovered] = rgba(81,  85, 111)
	style.Colors[ig.Col.ScrollbarGrabActive]  = rgba(104, 108, 138)
	style.Colors[ig.Col.CheckMark]         = rgba(137, 180, 250)
	style.Colors[ig.Col.SliderGrab]        = rgba(137, 180, 250)
	style.Colors[ig.Col.SliderGrabActive]  = rgba(159, 194, 252)
	style.Colors[ig.Col.Button]            = rgba(45,  47,  66)
	style.Colors[ig.Col.ButtonHovered]     = rgba(59,  62,  86)
	style.Colors[ig.Col.ButtonActive]      = rgba(74,  78, 107)
	style.Colors[ig.Col.Header]            = rgba(45,  47,  66)
	style.Colors[ig.Col.HeaderHovered]     = rgba(59,  62,  86)
	style.Colors[ig.Col.HeaderActive]      = rgba(74,  78, 107)
	style.Colors[ig.Col.Separator]         = rgba(60,  63,  85)
	style.Colors[ig.Col.SeparatorHovered]  = rgba(137, 180, 250)
	style.Colors[ig.Col.SeparatorActive]   = rgba(159, 194, 252)
	style.Colors[ig.Col.ResizeGrip]        = rgba(60,  63,  85)
	style.Colors[ig.Col.ResizeGripHovered] = rgba(137, 180, 250)
	style.Colors[ig.Col.ResizeGripActive]  = rgba(159, 194, 252)
	style.Colors[ig.Col.Tab]               = rgba(31,  33,  48)
	style.Colors[ig.Col.TabHovered]        = rgba(54,  56,  78)
	style.Colors[ig.Col.TabSelected]       = rgba(45,  47,  66)
	style.Colors[ig.Col.TabDimmed]         = rgba(24,  25,  38)
	style.Colors[ig.Col.TabDimmedSelected] = rgba(35,  37,  54)
	style.Colors[ig.Col.DockingPreview]    = rgba(137, 180, 250, 0.30)
	style.Colors[ig.Col.DockingEmptyBg]    = rgba(20,  21,  33)
	style.Colors[ig.Col.TextLink]          = rgba(137, 180, 250)
	style.Colors[ig.Col.TextSelectedBg]    = rgba(137, 180, 250, 0.25)
	style.Colors[ig.Col.DragDropTarget]    = rgba(137, 180, 250, 0.80)
	style.Colors[ig.Col.DragDropTargetBg]  = rgba(137, 180, 250, 0.15)
	style.Colors[ig.Col.NavCursor]         = rgba(137, 180, 250)
	style.Colors[ig.Col.ModalWindowDimBg]  = rgba(0,    0,   0, 0.50)
}

extract_database_information :: proc(filename: string) -> sqlite.SQLiteError {
	cfilename := strings.clone_to_cstring(filename, context.temp_allocator)
	db := sqlite.open(cfilename) or_return
	defer sqlite.close(db)
	
	table_stmt := sqlite.prepare(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';") or_return
	defer sqlite.finalize(table_stmt)

	for sqlite.step(table_stmt) == .ROW {
		table_name := sqlite.column_text(table_stmt, 0)
		fmt.printfln("Table name %v", table_name)

		column_stmt := sqlite.prepare(db, "SELECT * FROM pragma_table_info(?)") or_return
		defer sqlite.finalize(column_stmt)

		sqlite.bind_text(column_stmt, 1, table_name) or_return

		for sqlite.step(column_stmt) == .ROW {
			fmt.printfln("- %v", sqlite.column_text(column_stmt, 1))
		}

		fk_stmt := sqlite.prepare(db, "SELECT * FROM pragma_foreign_key_list(?)") or_return
		defer sqlite.finalize(fk_stmt)

		sqlite.bind_text(fk_stmt, 1, table_name) or_return

		for sqlite.step(fk_stmt) == .ROW {
			fmt.printfln("FK: %v -> %v.%v", sqlite.column_text(fk_stmt, 3), sqlite.column_text(fk_stmt, 2), sqlite.column_text(fk_stmt, 4))
		}
	}

	return .OK
}
