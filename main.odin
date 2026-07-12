package main

import "core:fmt"
import "core:strings"
import "core:os"
import  sqlite "sqlite3"

main :: proc() {
	fmt.println("Hellope! Welcome to the Schema Spelunker")

	if len(os.args) != 2 {
		fmt.println("Please call with the filename that you would like to inspect")
		return
	}

	filename := os.args[1]
	error := test_db_connection(filename)
	fmt.printfln("Return code: %v", error)
}

test_db_connection :: proc(filename: string) -> sqlite.SQLiteError {
	cfilename := strings.clone_to_cstring(filename, context.temp_allocator)
	db := sqlite.open(cfilename) or_return
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

		fk_sql := strings.clone_to_cstring(fmt.tprintf("PRAGMA foreign_key_list(\"%v\")", table_name), context.temp_allocator)
		fk_stmt := sqlite.prepare(db, fk_sql) or_continue
		defer sqlite.finalize(fk_stmt)

		for sqlite.step(fk_stmt) == .ROW {
			fmt.printfln("FK: %v -> %v.%v", sqlite.column_text(fk_stmt, 3), sqlite.column_text(fk_stmt, 2), sqlite.column_text(fk_stmt, 4))
		}
	}

	return .OK
}