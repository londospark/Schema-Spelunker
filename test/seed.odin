package main

import "core:fmt"
import "core:os"
import "core:strings"
import "../vendor/sqlite3"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Usage: seed <database_path> [sql_file]")
		os.exit(1)
	}
	
	db_path := os.args[1]
	sql_path := "test/complex.sql"
	if len(os.args) >= 3 {
		sql_path = os.args[2]
	}

	data, err := os.read_entire_file_from_path(sql_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read %v: %v", sql_path, err)
		os.exit(1)
	}
	defer delete(data)
	
	db, open_err := sqlite3.open(strings.clone_to_cstring(db_path, context.temp_allocator))
	if open_err != .OK {
		fmt.eprintfln("Failed to open database: %v", open_err)
		os.exit(1)
	}
	defer sqlite3.close(db)
	
	sql := strings.clone_to_cstring(string(data))
	defer delete(sql)
	
	exec_err := sqlite3.exec(db, sql, nil, nil, nil)
	fmt.printfln("Exec returned: %v", exec_err)
}
