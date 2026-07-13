package main

import "core:fmt"
import "core:strings"
import "core:os"
import sqlite "vendor/sqlite3"
import rl "vendor:raylib"

main :: proc() {
	fmt.println("Hellope! Welcome to the Schema Spelunker")

	if len(os.args) != 2 {
		make_raylib_app()
	} else {
		filename := os.args[1]
		error := extract_database_information(filename)
		fmt.printfln("Return code: %v", error)
	}
}

GuiState :: struct {
	open_dialog: bool,
	open_dialog_rect: rl.Rectangle
}

FONT_SIZE :: 18

make_raylib_app :: proc() {
	gui_state := GuiState {
		open_dialog = false,
		open_dialog_rect = rl.Rectangle {x = 10, y = 10, width = 100, height = 40}
	}

	rl.SetConfigFlags({.VSYNC_HINT})

	rl.InitWindow(1600, 900, "Schema Spelunker")

	font := rl.LoadFontEx("Roboto.ttf", FONT_SIZE, nil, 0)
	defer rl.UnloadFont(font)

	rl.GuiLoadStyle("dark.rgs")

	rl.GuiSetFont(font)

	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), FONT_SIZE)
	bg := rl.GetColor(u32(rl.GuiGetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.BACKGROUND_COLOR))))

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		defer rl.EndDrawing()

		rl.ClearBackground(bg)

		if rl.GuiButton(gui_state.open_dialog_rect, "Load DB") {
			fmt.println("Load a file")
			gui_state.open_dialog = true
		}
		rl.GuiLabel(rl.Rectangle{10, 60, 200, 40}, "Hellope!")

		if gui_state.open_dialog {
			if rl.GuiWindowBox(rl.Rectangle {100, 100, 300, 400}, "Open File") == 1 {
				gui_state.open_dialog = false
			}
		}
	}

	rl.CloseWindow()
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