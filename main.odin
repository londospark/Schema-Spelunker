package main

import "core:fmt"
import "core:strings"
import "core:os"
import sqlite "sqlite3"
import rl "vendor:raylib/v6"

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

make_raylib_app :: proc() {
	rl.InitWindow(1600, 900, "Schema Spelunker")
	rl.SetTargetFPS(240)

	show_fps := false

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		defer rl.EndDrawing()

		rl.ClearBackground(rl.RAYWHITE)

		rl.GuiEnable()
		defer rl.GuiDisable()

		rect := rl.Rectangle {x = 10, y = 30, width = 300, height = 40}
		if rl.GuiButton(rect, "Press Me") {
			show_fps = !show_fps
		}

		if show_fps {
			rl.DrawFPS(10, 10)
		}

		rl.DrawText("Hellope!", 10, 100, 40, rl.BLACK)
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