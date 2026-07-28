package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:math/rand"
import "../vendor/sqlite3"

NUM_TABLES   :: 2000
FK_DENSITY   :: 3
BATCH_SIZE   :: 50

ColumnDef :: struct {
	name: string,
	type: string,
	extra: string,
}

main :: proc() {
	db_path := "huge.db"
	if len(os.args) >= 2 {
		db_path = os.args[1]
	}

	fmt.printfln("Creating huge database: %s", db_path)
	fmt.printfln("Tables: %v, FK density: ~%v per table", NUM_TABLES, FK_DENSITY)

	os.remove(db_path)

	db, open_err := sqlite3.open(strings.clone_to_cstring(db_path, context.temp_allocator))
	if open_err != .OK {
		fmt.eprintfln("Failed to open database: %v", open_err)
		os.exit(1)
	}
	defer sqlite3.close(db)

	// Enable WAL + fast mode
	_ = sqlite3.exec(db, strings.clone_to_cstring(
		"PRAGMA journal_mode=WAL; PRAGMA synchronous=OFF; PRAGMA cache_size=-80000;", context.temp_allocator),
		nil, nil, nil)

	schema_buf := strings.builder_make()
	defer strings.builder_destroy(&schema_buf)

	fmt.println("Generating schema...")

	col_templates := [?]ColumnDef{
		{"name",        "TEXT",    "NOT NULL"},
		{"description", "TEXT",    ""},
		{"value",       "REAL",    ""},
		{"count",       "INTEGER", "NOT NULL DEFAULT 0"},
		{"is_active",   "INTEGER", "NOT NULL DEFAULT 1"},
		{"created_at",  "TEXT",    "NOT NULL DEFAULT (datetime('now'))"},
		{"updated_at",  "TEXT",    ""},
		{"sort_order",  "INTEGER", "NOT NULL DEFAULT 0"},
		{"status",      "TEXT",    "NOT NULL DEFAULT 'active'"},
		{"notes",       "TEXT",    ""},
		{"score",       "REAL",    "NOT NULL DEFAULT 0.0"},
		{"category",    "TEXT",    ""},
		{"priority",    "INTEGER", "NOT NULL DEFAULT 0"},
		{"tags",        "TEXT",    ""},
	}

	flush_sql :: proc(sb: ^strings.Builder, db: sqlite3.Database) -> bool {
		if strings.builder_len(sb^) == 0 do return true
		sql := strings.to_string(sb^)
		cstr := strings.clone_to_cstring(sql, context.temp_allocator)
		err := sqlite3.exec(db, cstr, nil, nil, nil)
		strings.builder_reset(sb)
		if err != .OK {
			fmt.eprintfln("SQL exec error: %v", err)
			return false
		}
		return true
	}

	TABLE_NAMES := make([]string, NUM_TABLES)
	defer delete(TABLE_NAMES)
	batch := 0

	for i in 0 ..< NUM_TABLES {
		table_name := fmt.tprintf("table_%04d", i)
		TABLE_NAMES[i] = strings.clone(table_name)
		num_extra := rand.int_max(11)
		num_cols := 5 + num_extra

		strings.write_string(&schema_buf, "CREATE TABLE ")
		strings.write_string(&schema_buf, table_name)
		strings.write_string(&schema_buf, " (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n")

		for j in 0 ..< num_cols {
			t := col_templates[rand.int_max(len(col_templates))]
			col_name := fmt.tprintf("col_%s_%d", t.name, j)
			strings.write_string(&schema_buf, fmt.tprintf("  %s %s %s", col_name, t.type, t.extra))
			if j < num_cols - 1 do strings.write_string(&schema_buf, ",")
			strings.write_string(&schema_buf, "\n")
		}

		if i > 0 {
			num_fks := rand.int_max(FK_DENSITY + 1)
			for j in 0 ..< num_fks {
				target := rand.int_max(i)
				strings.write_string(&schema_buf, fmt.tprintf("  ,fk_%d INTEGER REFERENCES %s(id)\n", j, TABLE_NAMES[target]))
			}
		}

		strings.write_string(&schema_buf, ") STRICT;\n")
		batch += 1

		if batch >= BATCH_SIZE {
			if !flush_sql(&schema_buf, db) do os.exit(1)
			if i % 500 == 0 do fmt.printfln("  %d / %d tables...", i + 1, NUM_TABLES)
			batch = 0
		}
	}

	if batch > 0 {
		if !flush_sql(&schema_buf, db) do os.exit(1)
	}

	fmt.println("Schema created.")
	fmt.printfln("Total tables: %d", NUM_TABLES)


	// Get DB size via file stat
	fi, fi_err := os.stat(db_path, context.allocator)
	db_size_mb := f64(0)
	if fi_err == nil {
		db_size_mb = f64(fi.size) / (1024.0 * 1024.0)
	}

	fmt.printfln("")
	fmt.printfln("=== Done ===")
	fmt.printfln("Database: %s", db_path)
	fmt.printfln("Tables: %d", NUM_TABLES)
	fmt.printfln("DB size: %.1f MB", db_size_mb)
}
