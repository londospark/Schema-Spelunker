package main

// Database-format abstraction. A Backend introspects one database family
// (SQLite today; MSSQL and Postgres to come) into neutral row types, and
// load_schema builds the index-resolved Schema from those rows. Row lists
// must be grouped by table, in table order, with columns/fks in creation
// order — SQLite's PRAGMA introspection satisfies this; catalog queries for
// other backends should ORDER BY table, ordinal.
//
// Add a new backend by filling in a Backend and appending it to BACKENDS.

import "core:mem"
import "core:os"
import "core:strings"
import sqlite "vendor/sqlite3"

TableRow :: struct {
	name: string,
}

ColumnRow :: struct {
	table:    string,
	name:     string,
	type:     string,
	not_null: bool,
	pk_index: u32, // 0 when not part of the primary key
}

ForeignKeyRow :: struct {
	from_table:  string,
	from_column: string,
	to_table:    string,
	to_column:   string,
}

SchemaError :: enum u8 {
	None,
	UnsupportedDatabase, // no backend claims the file/connection
	OpenFailed,
	QueryFailed,
	InvalidSchema, // introspection returned inconsistent rows
}

Backend :: struct {
	name:              string,
	detect:            proc(path: string) -> bool,
	open:              proc(path: string) -> (handle: rawptr, err: SchemaError),
	close:             proc(handle: rawptr),
	list_tables:       proc(
		handle: rawptr,
		allocator: mem.Allocator,
	) -> (
		rows: []TableRow,
		err: SchemaError,
	),
	list_columns:      proc(
		handle: rawptr,
		allocator: mem.Allocator,
	) -> (
		rows: []ColumnRow,
		err: SchemaError,
	),
	list_foreign_keys: proc(
		handle: rawptr,
		allocator: mem.Allocator,
	) -> (
		rows: []ForeignKeyRow,
		err: SchemaError,
	),
}

BACKENDS := []Backend{sqlite_backend}

detect_backend :: proc(path: string) -> (backend: Backend, err: SchemaError) {
	for candidate in BACKENDS {
		if candidate.detect(path) {
			return candidate, .None
		}
	}
	return {}, .UnsupportedDatabase
}

// True when any registered backend claims the file — used to filter the file
// dialog listing without touching the extractor.
known_database_format :: proc(path: string) -> bool {
	for backend in BACKENDS {
		if backend.detect(path) {
			return true
		}
	}
	return false
}

// Load a Schema from whatever database format claims the path. The returned
// Schema owns an arena; destroy it before dropping the Schema.
load_schema :: proc(path: string) -> (schema: Schema, err: SchemaError) {
	backend := detect_backend(path) or_return
	handle := backend.open(path) or_return
	defer backend.close(handle)

	init_schema(&schema)
	defer if err != .None {
		mem.dynamic_arena_destroy(&schema.arena)
	}

	table_rows := backend.list_tables(handle, schema.allocator) or_return
	column_rows := backend.list_columns(handle, schema.allocator) or_return
	fk_rows := backend.list_foreign_keys(handle, schema.allocator) or_return

	schema.database_name = strings.clone(path, schema.allocator)

	col_indices := make(map[[2]string]GlobalColumnIndex, context.temp_allocator)

	current_column: GlobalColumnIndex = 0
	current_fk: GlobalForeignKeyIndex = 0
	column_cursor, fk_cursor: int

	for table_row in table_rows {
		table: Table
		table.name = table_row.name
		table.from_column = current_column

		for column_cursor < len(column_rows) &&
		    column_rows[column_cursor].table == table_row.name {
			row := column_rows[column_cursor]
			append(
				&schema.columns,
				Column {
					name = row.name,
					type = row.type,
					not_null = row.not_null,
					composite_key_index = row.pk_index,
				},
			)
			col_indices[[2]string{table_row.name, row.name}] = current_column
			current_column += 1
			column_cursor += 1
		}
		table.to_column = current_column

		for fk_cursor < len(fk_rows) && fk_rows[fk_cursor].from_table == table_row.name {
			row := fk_rows[fk_cursor]
			if !table.has_foreign_keys {
				table.has_foreign_keys = true
				table.from_foreign_key = current_fk
			}

			fk: ForeignKey
			fk.from_column = row.from_column
			fk.to_table = row.to_table
			fk.to_column = row.to_column
			fk.from, _ = col_indices[[2]string{table_row.name, row.from_column}]

			append(&schema.foreign_keys, fk)
			current_fk += 1
			fk_cursor += 1
		}

		if table.has_foreign_keys {
			table.to_foreign_key = current_fk
		}

		append(&schema.tables, table)
	}

	for &fk in schema.foreign_keys {
		fk.to = col_indices[[2]string{fk.to_table, fk.to_column}] or_continue
		fk.resolved_to_index = true
	}

	return schema, .None
}

init_schema :: proc(schema: ^Schema) {
	mem.dynamic_arena_init(&schema.arena)
	schema.allocator = mem.dynamic_arena_allocator(&schema.arena)
}

// --- SQLite backend ---

SQLITE_MAGIC :: [16]u8 {
	0x53,
	0x51,
	0x4c,
	0x69,
	0x74,
	0x65,
	0x20,
	0x66,
	0x6f,
	0x72,
	0x6d,
	0x61,
	0x74,
	0x20,
	0x33,
	0x00,
}

sqlite_backend := Backend {
	name              = "SQLite",
	detect            = sqlite_detect,
	open              = sqlite_open,
	close             = sqlite_close,
	list_tables       = sqlite_list_tables,
	list_columns      = sqlite_list_columns,
	list_foreign_keys = sqlite_list_foreign_keys,
}

sqlite_detect :: proc(path: string) -> bool {
	handle, err := os.open(path)
	if err != os.ERROR_NONE {
		return false
	}
	defer os.close(handle)

	buf: [16]u8
	bytes_read, read_err := os.read(handle, buf[:])
	return read_err == os.ERROR_NONE && bytes_read >= len(SQLITE_MAGIC) && buf == SQLITE_MAGIC
}

sqlite_open :: proc(path: string) -> (rawptr, SchemaError) {
	db, err := sqlite.open(strings.clone_to_cstring(path, context.temp_allocator))
	if err != .OK {
		return nil, .OpenFailed
	}
	return rawptr(db), .None
}

sqlite_close :: proc(handle: rawptr) {
	_ = sqlite.close(sqlite.Database(handle))
}

sqlite_list_tables :: proc(handle: rawptr, allocator: mem.Allocator) -> ([]TableRow, SchemaError) {
	db := sqlite.Database(handle)

	stmt, err := sqlite.prepare(
		db,
		"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
	)
	if err != .OK {
		return nil, .QueryFailed
	}
	defer sqlite.finalize(stmt)

	rows := make([dynamic]TableRow, allocator)
	for {
		res := sqlite.step(stmt)
		if res == .ROW {
			append(&rows, TableRow{name = sqlite.column_string(stmt, 0, allocator)})
		} else {
			if res != .DONE {
				return nil, .QueryFailed
			}
			break
		}
	}
	return rows[:], .None
}

sqlite_list_columns :: proc(
	handle: rawptr,
	allocator: mem.Allocator,
) -> (
	[]ColumnRow,
	SchemaError,
) {
	db := sqlite.Database(handle)

	table_stmt, err := sqlite.prepare(
		db,
		"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
	)
	if err != .OK {
		return nil, .QueryFailed
	}
	defer sqlite.finalize(table_stmt)

	rows := make([dynamic]ColumnRow, allocator)
	for {
		res := sqlite.step(table_stmt)
		if res == .ROW {
			table_name := sqlite.column_string(table_stmt, 0, allocator)

			col_stmt, c_err := sqlite.prepare(db, "SELECT * FROM pragma_table_info(?)")
			if c_err != .OK {
				return nil, .QueryFailed
			}
			if bind_err := sqlite.bind_text(
				col_stmt,
				1,
				strings.clone_to_cstring(table_name, context.temp_allocator),
			); bind_err != .OK {
				sqlite.finalize(col_stmt)
				return nil, .QueryFailed
			}

			for {
				cres := sqlite.step(col_stmt)
				if cres == .ROW {
					append(
						&rows,
						ColumnRow {
							table = table_name,
							name = sqlite.column_string(col_stmt, 1, allocator),
							type = sqlite.column_string(col_stmt, 2, allocator),
							not_null = sqlite.column_bool(col_stmt, 3),
							pk_index = sqlite.column_u32(col_stmt, 5),
						},
					)
				} else {
					if cres != .DONE {
						sqlite.finalize(col_stmt)
						return nil, .QueryFailed
					}
					break
				}
			}
			sqlite.finalize(col_stmt)
		} else {
			if res != .DONE {
				return nil, .QueryFailed
			}
			break
		}
	}
	return rows[:], .None
}

sqlite_list_foreign_keys :: proc(
	handle: rawptr,
	allocator: mem.Allocator,
) -> (
	[]ForeignKeyRow,
	SchemaError,
) {
	db := sqlite.Database(handle)

	table_stmt, err := sqlite.prepare(
		db,
		"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
	)
	if err != .OK {
		return nil, .QueryFailed
	}
	defer sqlite.finalize(table_stmt)

	rows := make([dynamic]ForeignKeyRow, allocator)
	for {
		res := sqlite.step(table_stmt)
		if res == .ROW {
			table_name := sqlite.column_string(table_stmt, 0, allocator)

			fk_stmt, f_err := sqlite.prepare(db, "SELECT * FROM pragma_foreign_key_list(?)")
			if f_err != .OK {
				return nil, .QueryFailed
			}
			if bind_err := sqlite.bind_text(
				fk_stmt,
				1,
				strings.clone_to_cstring(table_name, context.temp_allocator),
			); bind_err != .OK {
				sqlite.finalize(fk_stmt)
				return nil, .QueryFailed
			}

			for {
				fres := sqlite.step(fk_stmt)
				if fres == .ROW {
					append(
						&rows,
						ForeignKeyRow {
							from_table = table_name,
							to_table = sqlite.column_string(fk_stmt, 2, allocator),
							from_column = sqlite.column_string(fk_stmt, 3, allocator),
							to_column = sqlite.column_string(fk_stmt, 4, allocator),
						},
					)
				} else {
					if fres != .DONE {
						sqlite.finalize(fk_stmt)
						return nil, .QueryFailed
					}
					break
				}
			}
			sqlite.finalize(fk_stmt)
		} else {
			if res != .DONE {
				return nil, .QueryFailed
			}
			break
		}
	}
	return rows[:], .None
}
