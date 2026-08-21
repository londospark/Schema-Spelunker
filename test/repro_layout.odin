package main

// Standalone repro of the diagram radial layout on a real database's FK data.
// Build: odin build test/repro_layout.odin -file -out:bin/repro_layout.exe
// Validates the layout algorithm (and the map-value range workaround) at
// scale without a GUI. Usage: repro_layout <db> [seed] [degrees]

import sqlite "../vendor/sqlite3"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"

GlobalTableIndex :: distinct u32
GlobalColumnIndex :: distinct u32
GlobalForeignKeyIndex :: distinct u32

Column :: struct {
	name:                string,
	type:                string,
	composite_key_index: u32,
	not_null:            bool,
}

Table :: struct {
	name:             string,
	from_column:      GlobalColumnIndex,
	to_column:        GlobalColumnIndex,
	from_foreign_key: GlobalForeignKeyIndex,
	to_foreign_key:   GlobalForeignKeyIndex,
	has_foreign_keys: bool,
}

ForeignKey :: struct {
	from:              GlobalColumnIndex,
	to:                GlobalColumnIndex,
	from_column:       string,
	to_table:          string,
	to_column:         string,
	resolved_to_index: bool,
}

Schema :: struct {
	database_name: string,
	tables:        [dynamic]Table,
	columns:       [dynamic]Column,
	foreign_keys:  [dynamic]ForeignKey,
	arena:         mem.Dynamic_Arena,
	allocator:     mem.Allocator,
}

DiagramLayoutKey :: struct {
	seed:        GlobalTableIndex,
	visible_sum: u64,
}

DiagramState :: struct {
	seed_table:             GlobalTableIndex,
	show_from_seed_table:   bool,
	degrees:                u8,
	visible_tables:         [dynamic]GlobalTableIndex,
	pending_seed_selection: bool,
	layout:                 map[GlobalTableIndex]Mem_Vec2,
	layout_key:             DiagramLayoutKey,
}

Mem_Vec2 :: struct {
	x, y: f32,
}

load_schema_repro :: proc(filename: string) -> (schema: Schema, ok: bool) {
	db, open_err := sqlite.open(strings.clone_to_cstring(filename, context.temp_allocator))
	if open_err != .OK {
		return schema, false
	}
	defer sqlite.close(db)

	table_stmt, t_err := sqlite.prepare(
		db,
		"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';",
	)
	if t_err != .OK {
		return schema, false
	}
	defer sqlite.finalize(table_stmt)

	mem.dynamic_arena_init(&schema.arena)
	schema.allocator = mem.dynamic_arena_allocator(&schema.arena)

	old := context.allocator
	context.allocator = schema.allocator
	defer context.allocator = old

	schema.database_name = strings.clone(filename)
	col_indices := make(map[[2]string]GlobalColumnIndex, context.temp_allocator)

	current_column: GlobalColumnIndex = 0
	current_fk: GlobalForeignKeyIndex = 0

	for sqlite.step(table_stmt) == .ROW {
		table: Table
		table.name = sqlite.column_string(table_stmt, 0)
		table.from_column = current_column

		column_stmt, c_err := sqlite.prepare(db, "SELECT * FROM pragma_table_info(?)")
		if c_err != .OK {
			return schema, false
		}
		_ = sqlite.bind_text(
			column_stmt,
			1,
			strings.clone_to_cstring(table.name, context.temp_allocator),
		)

		for sqlite.step(column_stmt) == .ROW {
			column: Column
			column.name = sqlite.column_string(column_stmt, 1)
			column.type = sqlite.column_string(column_stmt, 2)
			column.not_null = sqlite.column_bool(column_stmt, 3)
			column.composite_key_index = sqlite.column_u32(column_stmt, 5)

			append(&schema.columns, column)
			col_indices[[2]string{table.name, column.name}] = current_column
			current_column += 1
		}
		sqlite.finalize(column_stmt)
		table.to_column = current_column

		fk_stmt, f_err := sqlite.prepare(db, "SELECT * FROM pragma_foreign_key_list(?)")
		if f_err != .OK {
			return schema, false
		}
		_ = sqlite.bind_text(
			fk_stmt,
			1,
			strings.clone_to_cstring(table.name, context.temp_allocator),
		)

		for sqlite.step(fk_stmt) == .ROW {
			if !table.has_foreign_keys {
				table.has_foreign_keys = true
				table.from_foreign_key = current_fk
			}
			fk: ForeignKey
			fk.from_column = sqlite.column_string(fk_stmt, 3)
			fk.to_table = sqlite.column_string(fk_stmt, 2)
			fk.to_column = sqlite.column_string(fk_stmt, 4)
			fk.from, _ = col_indices[[2]string{table.name, fk.from_column}]
			append(&schema.foreign_keys, fk)
			current_fk += 1
		}
		sqlite.finalize(fk_stmt)
		if table.has_foreign_keys {
			table.to_foreign_key = current_fk
		}
		append(&schema.tables, table)
	}

	for &fk in schema.foreign_keys {
		fk.to = col_indices[[2]string{fk.to_table, fk.to_column}] or_continue
		fk.resolved_to_index = true
	}
	return schema, true
}

find_table_by_column :: proc(tables: []Table, column: GlobalColumnIndex) -> int {
	for table, i in tables {
		if table.from_column <= column && column < table.to_column {
			return i
		}
	}
	return -1
}

linked_tables :: proc(
	schema: ^Schema,
	table_idx: GlobalTableIndex,
) -> (
	tables: [dynamic]GlobalTableIndex,
) {
	table := schema.tables[table_idx]
	if table.has_foreign_keys {
		fks := schema.foreign_keys[table.from_foreign_key:table.to_foreign_key]
		for key in fks {
			t := find_table_by_column(schema.tables[:], key.to)
			if t >= 0 {
				append(&tables, GlobalTableIndex(u32(t)))
			}
		}
	}
	for key in schema.foreign_keys {
		to_table := find_table_by_column(schema.tables[:], key.to)
		if to_table >= 0 && GlobalTableIndex(u32(to_table)) == table_idx {
			from_table := find_table_by_column(schema.tables[:], key.from)
			if from_table >= 0 {
				append(&tables, GlobalTableIndex(u32(from_table)))
			}
		}
	}
	return
}

collect_visible_tables :: proc(
	schema: ^Schema,
	state: DiagramState,
) -> (
	tables: [dynamic]GlobalTableIndex,
) {
	if !state.show_from_seed_table ||
	   state.degrees == 0 ||
	   state.seed_table >= GlobalTableIndex(len(schema.tables)) {
		for i in 0 ..< len(schema.tables) {
			append(&tables, GlobalTableIndex(u32(i)))
		}
		return
	}

	depth := make(map[GlobalTableIndex]u8, context.temp_allocator)
	defer delete(depth)

	queue := make([dynamic]GlobalTableIndex, context.temp_allocator)
	defer delete(queue)
	head: int

	append(&queue, state.seed_table)
	depth[state.seed_table] = 0
	append(&tables, state.seed_table)

	for head < len(queue) {
		current := queue[head]
		head += 1

		current_depth := depth[current]
		if current_depth >= state.degrees {
			continue
		}

		{
			linked := linked_tables(schema, current)
			defer delete(linked)
			for t in linked {
				if !(t in depth) {
					depth[t] = current_depth + 1
					append(&tables, t)
					append(&queue, t)
				}
			}
		}
	}
	return
}

RING_SPACING :: 340.0

// Byte-identical copy of the app's radial layout_visible_tables.
layout_visible_tables :: proc(schema: ^Schema, state: ^DiagramState) {
	visible_count := len(state.visible_tables)
	if visible_count == 0 {
		return
	}
	if state.seed_table >= GlobalTableIndex(len(schema.tables)) {
		return
	}

	key_sum := u64(visible_count)
	for t in state.visible_tables {
		key_sum += u64(t)
	}
	if state.layout_key.seed == state.seed_table && state.layout_key.visible_sum == key_sum {
		return
	}
	state.layout_key.seed = state.seed_table
	state.layout_key.visible_sum = key_sum

	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for t in state.visible_tables {
		visible[t] = true
	}

	hop := make(map[GlobalTableIndex]u32, context.temp_allocator)
	parent := make(map[GlobalTableIndex]GlobalTableIndex, context.temp_allocator)
	children_of := make(map[GlobalTableIndex][dynamic]GlobalTableIndex, context.temp_allocator)
	queue := make([dynamic]GlobalTableIndex, context.temp_allocator)
	append(&queue, state.seed_table)
	hop[state.seed_table] = 0
	for head := 0; head < len(queue); head += 1 {
		current := queue[head]
		current_hop := hop[current]
		linked := linked_tables(schema, current)
		for neighbor in linked {
			if !visible[neighbor] {
				continue
			}
			if neighbor in hop {
				continue
			}
			hop[neighbor] = current_hop + 1
			parent[neighbor] = current
			if children_of[current] == nil {
				children_of[current] = make([dynamic]GlobalTableIndex, context.temp_allocator)
			}
			append(&children_of[current], neighbor)
			append(&queue, neighbor)
		}
		delete(linked)
	}

	max_hop: u32 = 0
	for t in state.visible_tables {
		if h := hop[t]; h > max_hop {
			max_hop = h
		}
	}
	outer_ring := max_hop + 1

	rings := make([dynamic][dynamic]GlobalTableIndex, context.temp_allocator)
	for _ in 0 ..= int(outer_ring) {
		append(&rings, make([dynamic]GlobalTableIndex, context.temp_allocator))
	}
	for t in state.visible_tables {
		h := hop[t]
		if _, reached := hop[t]; !reached {
			h = outer_ring
		}
		append(&rings[h], t)
	}

	angle := make(map[GlobalTableIndex]f32, context.temp_allocator)
	prev_ring_ordered: [dynamic]GlobalTableIndex
	for r in 0 ..= int(outer_ring) {
		bucket := rings[u32(r)]
		if len(bucket) == 0 {
			continue
		}

		ordered: [dynamic]GlobalTableIndex
		if r == 0 {
			state.layout[state.seed_table] = Mem_Vec2{0, 0}
			angle[state.seed_table] = 0
			continue
		}

		if r == 1 || u32(r) == outer_ring {
			ordered = bucket
		} else {
			ordered = make([dynamic]GlobalTableIndex, context.temp_allocator)
			for parent_t in prev_ring_ordered {
				children := children_of[parent_t]
				for child in children {
					append(&ordered, child)
				}
			}
		}

		count := f32(len(ordered))
		if count == 0 {
			continue
		}
		radius := RING_SPACING * max(1.0, count / 6.0)
		for t, i in ordered {
			a := (f32(i) + 0.5) / count * 2.0 * math.PI
			state.layout[t] = Mem_Vec2{math.cos_f32(a) * radius, math.sin_f32(a) * radius}
			angle[t] = a
		}
		prev_ring_ordered = ordered
	}
	fmt.eprintln("[repro] layout done")
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: repro_layout <db> [seed] [degrees]")
		os.exit(1)
	}
	schema, ok := load_schema_repro(os.args[1])
	if !ok {
		fmt.eprintln("load failed")
		os.exit(1)
	}
	defer mem.dynamic_arena_destroy(&schema.arena)
	fmt.eprintfln(
		"[repro] loaded %v tables, %v columns, %v fks",
		len(schema.tables),
		len(schema.columns),
		len(schema.foreign_keys),
	)

	seed := GlobalTableIndex(0)
	if len(os.args) >= 3 {
		seed = GlobalTableIndex(parse_int(os.args[2]))
	}
	degrees: u8 = 1
	if len(os.args) >= 4 {
		degrees = u8(parse_int(os.args[3]))
	}

	state: DiagramState
	state.show_from_seed_table = true
	state.seed_table = seed
	state.degrees = degrees
	state.layout = make(map[GlobalTableIndex]Mem_Vec2)

	visible := collect_visible_tables(&schema, state)
	defer delete(visible)
	state.visible_tables = visible
	fmt.eprintfln("[repro] visible: %v", visible)

	layout_visible_tables(&schema, &state)
	fmt.eprintfln("[repro] done, %d layout entries:", len(state.layout))
	printed := 0
	for k, v in state.layout {
		fmt.eprintfln("  table %v -> (%v, %v)", k, v.x, v.y)
		printed += 1
		if printed >= 10 {
			break
		}
	}
}

parse_int :: proc(s: string) -> int {
	n := 0
	for c in s {
		if '0' <= c && c <= '9' {
			n = n * 10 + int(c - '0')
		}
	}
	return n
}
