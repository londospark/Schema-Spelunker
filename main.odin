package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:time"
import sqlite "vendor/sqlite3"
import sdl "vendor:sdl3"
import ig "vendor/imgui"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"

BUF_LEN :: 1024
FileDialog :: struct {
	selected_file: i32,
	filename_buffer: [BUF_LEN]u8,
	items_in_folder: [dynamic]cstring
}

make_file_dialog :: proc() -> FileDialog {
	return FileDialog {
		selected_file = -1
	}
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

	window := sdl.CreateWindow("Schema Spelunker", 1600, 900, {.OPENGL, .HIGH_PIXEL_DENSITY})
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
	sdl.GL_SetSwapInterval(0)  // no VSync — we pace the loop manually

	// Init ImGui
	ig.CreateContext()
	defer ig.DestroyContext(nil)

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

	// Get display refresh rate for frame pacing
	// Pick a multiple closest to 240 FPS (max 4×), then throttle down if needed.
	display_id := sdl.GetDisplayForWindow(window)
	mode := sdl.GetCurrentDisplayMode(display_id)
	refresh_rate := f64(max(mode.refresh_rate, 60.0))

	multiple : u32 = 1
	fps_target : f64 = refresh_rate
	frame_time_target : f64 = 1.0 / refresh_rate

	calc_pacing :: proc "c" (rr: f64, mult: u32) -> (f64, f64) {
		t := min(rr * f64(mult), 240.0)
		return t, 1.0 / t
	}

	{
		m := clamp(u32(240.0 / refresh_rate), 1, 4)
		fps_target, frame_time_target = calc_pacing(refresh_rate, m)
		multiple = m
	}



	// Frame pacing throttle: 30-frame ring buffer
	FPS_HISTORY :: 30
	fps_ring : [FPS_HISTORY]f64
	fps_idx  : u32
	fps_full := false

	file_dialog := make_file_dialog()
	append(&file_dialog.items_in_folder, "something.db")
	append(&file_dialog.items_in_folder, "complex.db")

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

		// 2. Inject the absolute latest mouse position before the frame starts
		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)
		io.MousePos = ig.Vec2{mx, my}

		// 3. Render one frame
		gl_impl.NewFrame()
		sdl_impl.NewFrame()
		ig.NewFrame()
		ig.DockSpaceOverViewport(viewport = ig.GetMainViewport())

		ig.SetNextWindowSize(ig.Vec2{300, 500}, .Appearing)
		if ig.Begin("Open File...") {

			directory_path := os.get_working_directory(context.temp_allocator) or_continue
			directory_handle := os.open(directory_path) or_continue
			defer os.close(directory_handle)

			files := os.read_dir(directory_handle, -1, context.temp_allocator) or_continue
			defer os.file_info_slice_delete(files, context.temp_allocator)

			file_dialog.items_in_folder = {}
			for f in files {
				name: cstring
				if f.type == .Directory {
					name = strings.clone_to_cstring(fmt.tprintf("%v/", f.name), context.allocator)
				} else {
					name = strings.clone_to_cstring(f.name, context.allocator)
				}
				append(&file_dialog.items_in_folder, name)
			}

			ig.PushItemWidth(ig.GetContentRegionAvail().x)
			ig.InputText("##filename", cstring(&file_dialog.filename_buffer[0]), BUF_LEN)
			ig.ListBox("##folder", &file_dialog.selected_file, &file_dialog.items_in_folder[0], i32(len(file_dialog.items_in_folder)))
			ig.PopItemWidth()

			ig.Button("Cancel")
			ig.Button("Open")
		}
		ig.End()

		ig.Render()
		gl_impl.RenderDrawData(ig.GetDrawData())

		sdl.GL_SwapWindow(window)

		// 4. Frame pace: sleep for most of the remaining time, then busy-wait
		//    for precision. This lets us hit the target FPS without VSync.
		elapsed := time.duration_seconds(time.tick_since(t0))
		if elapsed < frame_time_target {
			remaining := frame_time_target - elapsed
			sleep_buffer :: 1.0 / 1000.0  // 1ms
			if remaining > sleep_buffer {
				time.sleep(time.Duration(1e9 * (remaining - sleep_buffer)))
			}
			for time.duration_seconds(time.tick_since(t0)) < frame_time_target {
				// busy-wait for precision
			}
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

				if avg < fps_target * 0.8 {
					multiple -= 1
					fps_target, frame_time_target = calc_pacing(refresh_rate, multiple)
					fps_full = false  // reset stats after change
				}
			}
		}

		t0 = time.tick_now()
	}
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
