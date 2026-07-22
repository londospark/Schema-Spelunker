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
	dirty: bool,
	selected_file: i32,
	path_buffer: [BUF_LEN]u8,
	items_in_folder: [dynamic]DirectoryItem,
	arena: mem.Dynamic_Arena,
}

make_file_dialog :: proc() -> (fd: FileDialog, err: os.Error) {
	fd.show = true //Show on startup
	fd.selected_file = -1
	mem.dynamic_arena_init(&fd.arena)
	alloc := mem.dynamic_arena_allocator(&fd.arena)
	fd.items_in_folder = make([dynamic]DirectoryItem, alloc)
	directory_path := os.get_working_directory(context.temp_allocator) or_return
	copy(fd.path_buffer[:], directory_path)
	fd.dirty = true
	return fd, nil
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
	set_light_theme()

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

	file_dialog, err := make_file_dialog()
	defer {
		delete(file_dialog.items_in_folder)
		mem.dynamic_arena_destroy(&file_dialog.arena)
	}

	if err != nil do return

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


		{
			defer ig.Render()
			if file_dialog.show {
				show_file_dialog(&file_dialog) or_continue
			}

			if ig.BeginMainMenuBar() {
				if ig.BeginMenu("File") {
					if ig.MenuItem("Open...") do file_dialog.show = true
					ig.EndMenu()
				}
				if ig.BeginMenu("Theme") {
					if ig.MenuItem("Light") do set_light_theme()
					if ig.MenuItem("Dark") do set_dark_theme()
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

DirectoryItemType :: enum {
	Directory,
	File
}

DirectoryItem :: struct {
	name: cstring,
	path: cstring,
	type: DirectoryItemType
}

show_file_dialog :: proc(file_dialog: ^FileDialog) -> os.Error {
	ig.SetNextWindowSize(ig.Vec2{300, 500}, .Appearing)
	if ig.Begin("Open File...") {
		defer ig.End()

		if file_dialog.dirty {
			mem.dynamic_arena_free_all(&file_dialog.arena)
			alloc := mem.dynamic_arena_allocator(&file_dialog.arena)
		
			directory_handle, error := os.open(string(file_dialog.path_buffer[:]))
			defer os.close(directory_handle)

			file_dialog.items_in_folder = make([dynamic]DirectoryItem, alloc)

			if error == os.ERROR_NONE {

				files := os.read_dir(directory_handle, -1, context.temp_allocator) or_return
				defer os.file_info_slice_delete(files, context.temp_allocator)

				parent_path, path_alloc_error := os.clean_path(fmt.aprintf("%s%r..", cstring(&file_dialog.path_buffer[0]), os.Path_Separator, allocator=alloc), alloc)
				if path_alloc_error == .None {
					append(&file_dialog.items_in_folder, DirectoryItem{
						name = "../",
						path = strings.clone_to_cstring(parent_path, alloc),
						type = .Directory
					})
				}

				for f in files {
					item: DirectoryItem
					item.name = strings.clone_to_cstring(f.name, alloc)
					path := fmt.aprintf("%s%r%s", cstring(&file_dialog.path_buffer[0]), os.Path_Separator, item.name, allocator=alloc)
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
					append(&file_dialog.items_in_folder, item)
				}
			}
			file_dialog.dirty = false
		}

	
		style := ig.GetStyle()
		ig.PushItemWidth(ig.GetContentRegionAvail().x)
		if ig.InputText("##path", cstring(&file_dialog.path_buffer[0]), BUF_LEN) do file_dialog.dirty = true
		ig.PopItemWidth()
	
		avail := ig.GetContentRegionAvail()
		listbox_height := avail.y - ig.GetFrameHeightWithSpacing() - style.ItemSpacing.y
		if ig.BeginListBox("##folder", ig.Vec2{avail.x, listbox_height}) {

			// @Todo: Should we do something to have the folders come first?
			for item, i in file_dialog.items_in_folder {
				is_selected := i32(i) == file_dialog.selected_file
				switch item.type {
				case .File:
					
					if ig.SelectableBoolPtr(item.name, &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							fmt.printfln("OPEN: %s", item.path)
						} else {
							file_dialog.selected_file = i32(i)
						}
					}

				case .Directory:
					if ig.SelectableBoolPtr(fmt.ctprint("[DIR]", item.name), &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							file_dialog.dirty = true
							file_dialog.path_buffer = {}
							copy(file_dialog.path_buffer[:], string(item.path))
						} else {
							file_dialog.selected_file = i32(i)
						}
					}
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

	return nil
}

set_common_elements :: proc() {
	style := ig.GetStyle()

	// --- 1. Sizing & Spacing ---
	style.WindowPadding = {12.0, 12.0}
	style.FramePadding = {6.0, 4.0}
	style.CellPadding = {6.0, 4.0}
	style.ItemSpacing = {8.0, 6.0}
	style.ItemInnerSpacing = {6.0, 4.0}
	style.ScrollbarSize = 14.0
	style.GrabMinSize = 12.0

	// --- 2. Borders & Rounding ---
	style.WindowRounding = 2.0
	style.ChildRounding = 2.0
	style.FrameRounding = 2.0
	style.PopupRounding = 2.0
	style.ScrollbarRounding = 12.0
	style.GrabRounding = 2.0
	style.TabRounding = 2.0

	style.WindowBorderSize = 1.0
	style.ChildBorderSize = 1.0
	style.PopupBorderSize = 1.0
	style.FrameBorderSize = 1.0
	style.TabBorderSize = 1.0
}

set_light_theme :: proc() {
	set_common_elements()
	style := ig.GetStyle()

	// --- Color Palette: Paper & Ink (Light) ---

	// Main Text & Background
	style.Colors[ig.Col.Text]              = {0.12, 0.12, 0.12, 1.00} // Deep Carbon Ink
	style.Colors[ig.Col.TextDisabled]      = {0.55, 0.55, 0.55, 1.00}
	style.Colors[ig.Col.WindowBg]          = {0.96, 0.96, 0.94, 1.00} // Warm Paper
	style.Colors[ig.Col.ChildBg]           = {0.00, 0.00, 0.00, 0.03}
	style.Colors[ig.Col.PopupBg]           = {1.00, 1.00, 1.00, 1.00} // Clean White

	// Borders & Separators
	style.Colors[ig.Col.Border]            = {0.75, 0.75, 0.72, 1.00}
	style.Colors[ig.Col.BorderShadow]      = {0.00, 0.00, 0.00, 0.00}
	style.Colors[ig.Col.Separator]         = {0.80, 0.80, 0.78, 1.00}
	style.Colors[ig.Col.SeparatorHovered]  = {0.17, 0.34, 0.59, 0.78}
	style.Colors[ig.Col.SeparatorActive]   = {0.17, 0.34, 0.59, 1.00}

	// Frames (Inputs, Checkboxes, etc)
	style.Colors[ig.Col.FrameBg]           = {1.00, 1.00, 1.00, 1.00}
	style.Colors[ig.Col.FrameBgHovered]    = {0.90, 0.92, 0.95, 1.00}
	style.Colors[ig.Col.FrameBgActive]     = {0.85, 0.88, 0.92, 1.00}

	// Titles & Menus
	style.Colors[ig.Col.TitleBg]           = {0.92, 0.92, 0.90, 1.00}
	style.Colors[ig.Col.TitleBgActive]     = {0.88, 0.88, 0.86, 1.00}
	style.Colors[ig.Col.TitleBgCollapsed]  = {0.92, 0.92, 0.90, 0.75}
	style.Colors[ig.Col.MenuBarBg]         = {0.92, 0.92, 0.90, 1.00}

	// Scrollbars
	style.Colors[ig.Col.ScrollbarBg]       = {0.96, 0.96, 0.94, 1.00}
	style.Colors[ig.Col.ScrollbarGrab]     = {0.80, 0.80, 0.78, 1.00}
	style.Colors[ig.Col.ScrollbarGrabHovered] = {0.70, 0.70, 0.68, 1.00}
	style.Colors[ig.Col.ScrollbarGrabActive]  = {0.60, 0.60, 0.58, 1.00}

	// Interactables (Blueprint Blue)
	style.Colors[ig.Col.CheckMark]         = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.SliderGrab]        = {0.17, 0.34, 0.59, 0.70}
	style.Colors[ig.Col.SliderGrabActive]  = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.Button]            = {0.17, 0.34, 0.59, 0.08}
	style.Colors[ig.Col.ButtonHovered]     = {0.17, 0.34, 0.59, 0.20}
	style.Colors[ig.Col.ButtonActive]      = {0.17, 0.34, 0.59, 0.35}

	// Header (Selection in lists/trees)
	style.Colors[ig.Col.Header]            = {0.17, 0.34, 0.59, 0.12}
	style.Colors[ig.Col.HeaderHovered]     = {0.17, 0.34, 0.59, 0.25}
	style.Colors[ig.Col.HeaderActive]      = {0.17, 0.34, 0.59, 0.40}

	// Tables
	style.Colors[ig.Col.TableHeaderBg]     = {0.90, 0.90, 0.88, 1.00}
	style.Colors[ig.Col.TableBorderStrong] = {0.75, 0.75, 0.72, 1.00}
	style.Colors[ig.Col.TableBorderLight]  = {0.85, 0.85, 0.82, 1.00}
	style.Colors[ig.Col.TableRowBg]        = {0.00, 0.00, 0.00, 0.00}
	style.Colors[ig.Col.TableRowBgAlt]     = {0.00, 0.00, 0.00, 0.03}

	// Tabs
	style.Colors[ig.Col.Tab]               = {0.92, 0.92, 0.90, 1.00}
	style.Colors[ig.Col.TabHovered]        = {1.00, 1.00, 1.00, 1.00}
	style.Colors[ig.Col.TabSelected]       = {1.00, 1.00, 1.00, 1.00}
	style.Colors[ig.Col.TabDimmed]         = {0.92, 0.92, 0.90, 1.00}
	style.Colors[ig.Col.TabDimmedSelected] = {0.96, 0.96, 0.94, 1.00}

	// Misc
	style.Colors[ig.Col.PlotLines]         = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.PlotHistogram]     = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.TextSelectedBg]    = {0.17, 0.34, 0.59, 0.25}
	style.Colors[ig.Col.DragDropTarget]    = {0.17, 0.34, 0.59, 0.90}
	style.Colors[ig.Col.NavCursor]         = {0.17, 0.34, 0.59, 1.00}

	// Docking
	style.Colors[ig.Col.DockingPreview]    = {0.17, 0.34, 0.59, 0.40}
	style.Colors[ig.Col.DockingEmptyBg]    = {0.96, 0.96, 0.94, 1.00}

	style.Colors[ig.Col.ModalWindowDimBg]  = {0.00, 0.00, 0.00, 0.50}
}

set_dark_theme :: proc() {
	set_common_elements()
	style := ig.GetStyle()

	// --- Color Palette: Paper & Ink (Dark) ---

	// Main Text & Background
	style.Colors[ig.Col.Text]              = {0.90, 0.90, 0.88, 1.00} // Off-white Ink
	style.Colors[ig.Col.TextDisabled]      = {0.55, 0.55, 0.52, 1.00}
	style.Colors[ig.Col.WindowBg]          = {0.16, 0.16, 0.14, 1.00} // Dark Warm Paper
	style.Colors[ig.Col.ChildBg]           = {0.12, 0.12, 0.10, 1.00}
	style.Colors[ig.Col.PopupBg]           = {0.20, 0.20, 0.18, 1.00}

	// Borders & Separators
	style.Colors[ig.Col.Border]            = {0.30, 0.30, 0.28, 1.00}
	style.Colors[ig.Col.BorderShadow]      = {0.00, 0.00, 0.00, 0.00}
	style.Colors[ig.Col.Separator]         = {0.30, 0.30, 0.28, 1.00}
	style.Colors[ig.Col.SeparatorHovered]  = {0.17, 0.34, 0.59, 0.78}
	style.Colors[ig.Col.SeparatorActive]   = {0.17, 0.34, 0.59, 1.00}

	// Frames (Inputs, Checkboxes, etc)
	style.Colors[ig.Col.FrameBg]           = {0.22, 0.22, 0.20, 1.00}
	style.Colors[ig.Col.FrameBgHovered]    = {0.28, 0.28, 0.25, 1.00}
	style.Colors[ig.Col.FrameBgActive]     = {0.34, 0.34, 0.30, 1.00}

	// Titles & Menus
	style.Colors[ig.Col.TitleBg]           = {0.12, 0.12, 0.10, 1.00}
	style.Colors[ig.Col.TitleBgActive]     = {0.18, 0.18, 0.15, 1.00}
	style.Colors[ig.Col.TitleBgCollapsed]  = {0.12, 0.12, 0.10, 0.75}
	style.Colors[ig.Col.MenuBarBg]         = {0.18, 0.18, 0.15, 1.00}

	// Scrollbars
	style.Colors[ig.Col.ScrollbarBg]       = {0.16, 0.16, 0.14, 1.00}
	style.Colors[ig.Col.ScrollbarGrab]     = {0.35, 0.35, 0.32, 1.00}
	style.Colors[ig.Col.ScrollbarGrabHovered] = {0.45, 0.45, 0.42, 1.00}
	style.Colors[ig.Col.ScrollbarGrabActive]  = {0.55, 0.55, 0.52, 1.00}

	// Interactables (Blueprint Blue)
	style.Colors[ig.Col.CheckMark]         = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.SliderGrab]        = {0.17, 0.34, 0.59, 0.70}
	style.Colors[ig.Col.SliderGrabActive]  = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.Button]            = {0.17, 0.34, 0.59, 0.15}
	style.Colors[ig.Col.ButtonHovered]     = {0.17, 0.34, 0.59, 0.30}
	style.Colors[ig.Col.ButtonActive]      = {0.17, 0.34, 0.59, 0.45}

	// Header (Selection in lists/trees)
	style.Colors[ig.Col.Header]            = {0.17, 0.34, 0.59, 0.20}
	style.Colors[ig.Col.HeaderHovered]     = {0.17, 0.34, 0.59, 0.35}
	style.Colors[ig.Col.HeaderActive]      = {0.17, 0.34, 0.59, 0.50}

	// Tables
	style.Colors[ig.Col.TableHeaderBg]     = {0.20, 0.20, 0.18, 1.00}
	style.Colors[ig.Col.TableBorderStrong] = {0.30, 0.30, 0.28, 1.00}
	style.Colors[ig.Col.TableBorderLight]  = {0.25, 0.25, 0.22, 1.00}
	style.Colors[ig.Col.TableRowBg]        = {0.00, 0.00, 0.00, 0.00}
	style.Colors[ig.Col.TableRowBgAlt]     = {0.00, 0.00, 0.00, 0.06}

	// Tabs
	style.Colors[ig.Col.Tab]               = {0.18, 0.18, 0.15, 1.00}
	style.Colors[ig.Col.TabHovered]        = {0.25, 0.25, 0.22, 1.00}
	style.Colors[ig.Col.TabSelected]       = {0.22, 0.22, 0.20, 1.00}
	style.Colors[ig.Col.TabDimmed]         = {0.14, 0.14, 0.12, 1.00}
	style.Colors[ig.Col.TabDimmedSelected] = {0.18, 0.18, 0.15, 1.00}

	// Misc
	style.Colors[ig.Col.PlotLines]         = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.PlotHistogram]     = {0.17, 0.34, 0.59, 1.00}
	style.Colors[ig.Col.TextSelectedBg]    = {0.17, 0.34, 0.59, 0.30}
	style.Colors[ig.Col.DragDropTarget]    = {0.17, 0.34, 0.59, 0.90}
	style.Colors[ig.Col.NavCursor]         = {0.17, 0.34, 0.59, 1.00}

	// Docking
	style.Colors[ig.Col.DockingPreview]    = {0.17, 0.34, 0.59, 0.40}
	style.Colors[ig.Col.DockingEmptyBg]    = {0.16, 0.16, 0.14, 1.00}

	style.Colors[ig.Col.ModalWindowDimBg]  = {0.00, 0.00, 0.00, 0.60}
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
