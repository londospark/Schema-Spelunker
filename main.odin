package main

import "core:fmt"
import "core:strings"
import "core:os"
import sqlite "vendor/sqlite3"
import sdl "vendor:sdl3"
import ig "vendor/imgui"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"
import gl "vendor/gl"

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
	sdl.GL_SetSwapInterval(1)  // VSYNC on — SDL3's event-driven input shouldn't lag like raylib's polling did

	// Init ImGui
	ig.CreateContext(nil)
	defer ig.DestroyContext(nil)

	// Init backends
	if !sdl_impl.InitForOpenGL(window, gl_context) {
		fmt.eprintln("ImGui SDL3 backend init failed")
		return
	}
	defer sdl_impl.Shutdown()

	if !gl_impl.Init("#version 130") {
		fmt.eprintln("ImGui OpenGL3 backend init failed")
		return
	}
	defer gl_impl.Shutdown()

	// Main loop
	event: sdl.Event
	running := true
	for running {
		for sdl.PollEvent(&event) {
			if event.type == .QUIT {
				running = false
			}
			sdl_impl.ProcessEvent(&event)
		}

		gl.ClearColor(0.45, 0.55, 0.60, 1.00)
		gl.Clear(gl.GL_COLOR_BUFFER_BIT)

		gl_impl.NewFrame()
		sdl_impl.NewFrame()
		ig.NewFrame()

		// — Your ImGui windows go here —
		ig.ShowDemoWindow(nil)

		ig.Render()
		gl_impl.RenderDrawData(ig.GetDrawData())

		// VSync normally on, off while dragging/resizing — avoids the 1–2 frame
		// latency penalty when the user is actively moving windows.
		if ig.IsAnyItemActive() {
			sdl.GL_SetSwapInterval(0)
		} else {
			sdl.GL_SetSwapInterval(1)
		}
		sdl.GL_SwapWindow(window)
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
