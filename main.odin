package main

import "core:fmt"
import "core:c"
import "core:strings"
import "base:runtime"
import "sqlite3"

//@Incomplete just something to test with for now, we might want more information in time.
Table :: struct {
	name: string
}

main :: proc() {
	fmt.println("Hellope! Welcome to the Schema Spelunker")
	error := test_db_connection("something.db")
	fmt.printfln("Return code: %v", error)
}

test_db_connection :: proc(filename: cstring) -> sqlite3.SQLiteError {
	db := sqlite3.open(filename) or_return
	defer sqlite3.close(db)
	
	tables: [dynamic]Table
	sqlite3.exec(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';", callback, &tables, nil) or_return

	for table in tables {
		fmt.printfln("Table name %v", table.name)

		//@Safety: We're only calling this with names that have come out of sqlite
		// There is no way to do the whole placeholder thing here according
		// to the clanker.
		sql := strings.clone_to_cstring(fmt.tprintf("PRAGMA table_info(\"%v\")", table.name), context.temp_allocator)
		column_stmt := sqlite3.prepare(db, sql) or_continue
		defer sqlite3.finalize(column_stmt)

		for sqlite3.step(column_stmt) == .ROW {
			fmt.printfln("- %v", sqlite3.column_text(column_stmt, 1))
		}
	}

	return .OK
}

callback :: proc "c" (state: rawptr, column_count: c.int, values: [^]cstring, column_names: [^]cstring) -> sqlite3.CallbackStatus {
	context = runtime.default_context()
	tables := (^[dynamic]Table)(state)

	table: Table
	for idx := (c.int)(0); idx < column_count; idx += 1 {
		if column_names[idx] == "name" {
			table.name = strings.clone(string(values[idx]), context.temp_allocator)
		}
	}

	append(tables, table)

	return .OK
}
