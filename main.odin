package main

import "core:fmt"
import "core:c"
import "core:strings"
import  sqlite "sqlite3"

main :: proc() {
	fmt.println("Hellope! Welcome to the Schema Spelunker")
	error := test_db_connection("something.db")
	fmt.printfln("Return code: %v", error)
}

test_db_connection :: proc(filename: cstring) -> sqlite.SQLiteError {
	db := sqlite.open(filename) or_return
	defer sqlite.close(db)
	
	table_stmt := sqlite.prepare(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';") or_return
	defer sqlite.finalize(table_stmt)

	for sqlite.step(table_stmt) == .ROW {
		table_name := sqlite.column_text(table_stmt, 0)
		fmt.printfln("Table name %v", table_name)

		//@Safety: We're only calling this with names that have come out of sqlite
		// There is no way to do the whole placeholder thing here according
		// to the clanker.
		sql := strings.clone_to_cstring(fmt.tprintf("PRAGMA table_info(\"%v\")", table_name), context.temp_allocator)
		column_stmt := sqlite.prepare(db, sql) or_continue
		defer sqlite.finalize(column_stmt)

		for sqlite.step(column_stmt) == .ROW {
			fmt.printfln("- %v", sqlite.column_text(column_stmt, 1))
		}
	}

	return .OK
}