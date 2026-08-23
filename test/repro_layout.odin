package main

// Standalone repro of the diagram layered layout on a real database's FK
// data. Build: odin build test/repro_layout.odin -file -out:bin/repro_layout.exe
// Validates the layout algorithm (no overlapping tables, and the map-value
// range workaround) at scale without a GUI. Usage:
// repro_layout <db> [seed] [degrees]

import sqlite "../vendor/sqlite3"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"
import "core:time"

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

Vec2 :: struct {
	x, y: f32,
}

DiagramState :: struct {
	seed_table:             GlobalTableIndex,
	show_from_seed_table:   bool,
	degrees:                u8,
	visible_tables:         [dynamic]GlobalTableIndex,
	pending_seed_selection: bool,
	layout:                 map[GlobalTableIndex]Vec2,
	node_size:              map[GlobalTableIndex]Vec2,
	layer_order:            [dynamic][dynamic]GlobalTableIndex,
	pending_size_refine:    bool,
	layout_key:             DiagramLayoutKey,
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
	lo, hi := 0, len(tables) - 1
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		t := tables[mid]
		if column < t.from_column {
			hi = mid - 1
		} else if column >= t.to_column {
			lo = mid + 1
		} else {
			return mid
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

// --- Layered layout (byte-equivalent port of main.odin's algorithm) ---

LAYER_GUTTER_X :: 140.0
SUBCOL_GUTTER_X :: 40.0
NODE_GAP_Y :: 50.0
MAX_RANK_HEIGHT :: 1400.0
ORDER_SWEEPS :: 4
STRAIGHTEN_SWEEPS :: 3
RANK_RELAX_MAX_ITER :: 64
TRANSPOSE_MAX_PASSES :: 8

EST_CHAR_WIDTH :: 7.0
EST_WIDTH_PAD :: 36.0
EST_MIN_WIDTH :: 140.0
EST_HEADER_HEIGHT :: 34.0
EST_ROW_HEIGHT :: 20.0

estimate_node_size :: proc(schema: ^Schema, table_idx: GlobalTableIndex) -> Vec2 {
	table := schema.tables[table_idx]
	max_chars := len(table.name)
	for column in schema.columns[table.from_column:table.to_column] {
		if len(column.name) > max_chars {
			max_chars = len(column.name)
		}
	}
	width := max(EST_MIN_WIDTH, f32(max_chars) * EST_CHAR_WIDTH + EST_WIDTH_PAD)
	column_count := max(1, int(table.to_column) - int(table.from_column))
	height := EST_HEADER_HEIGHT + f32(column_count) * EST_ROW_HEIGHT
	return Vec2{width, height}
}

node_size_for :: proc(schema: ^Schema, state: ^DiagramState, table_idx: GlobalTableIndex) -> Vec2 {
	if size, cached := state.node_size[table_idx]; cached {
		return size
	}
	return estimate_node_size(schema, table_idx)
}

delete_layer_order :: proc(layers: [dynamic][dynamic]GlobalTableIndex) {
	for layer in layers {
		delete(layer)
	}
	delete(layers)
}

RankEntry :: struct {
	table: GlobalTableIndex,
	key:   f32,
}

compare_rank_entries :: proc(a, b: RankEntry) -> int {
	if a.key < b.key {
		return -1
	}
	if a.key > b.key {
		return 1
	}
	return 0
}

reorder_rank_by_neighbors :: proc(
	layers: [dynamic][dynamic]GlobalTableIndex,
	neighbors: map[GlobalTableIndex][dynamic]GlobalTableIndex,
	rank_of: map[GlobalTableIndex]u32,
	pos_in_rank: ^map[GlobalTableIndex]int,
	rank: u32,
	ref_rank: u32,
) {
	row := layers[rank]
	if len(row) <= 1 {
		return
	}

	entries := make([dynamic]RankEntry, 0, len(row), context.temp_allocator)
	for t, i in row {
		linked := neighbors[t]
		sum: f32 = 0
		count: f32 = 0
		for n in linked {
			if rank_of[n] == ref_rank {
				sum += f32(pos_in_rank[n])
				count += 1
			}
		}
		key := f32(i)
		if count > 0 {
			key = sum / count
		}
		append(&entries, RankEntry{table = t, key = key})
	}
	sort.merge_sort_proc(entries[:], compare_rank_entries)
	for e, i in entries {
		row[i] = e.table
		pos_in_rank[e.table] = i
	}
}

// Counts crossings that edges from `left` and `right` (in that left-to-right
// rank order) make against one neighbouring rank, by counting neighbour
// pairs out of order: a crossing happens whenever one of `left`'s neighbours
// in that rank sits to the right of one of `right`'s neighbours there — the
// two edges must cross to reach their targets. Summing this over both
// neighbouring ranks gives the total crossing contribution of this ordering
// of the pair; comparing it against the same count with the pair swapped is
// the classic Sugiyama "transpose" heuristic (used by dot/OGDF) for cleaning
// up crossings the barycenter sweeps alone converge to a local optimum on.
count_pair_crossings :: proc(
	left, right: GlobalTableIndex,
	neighbors: map[GlobalTableIndex][dynamic]GlobalTableIndex,
	rank_of: map[GlobalTableIndex]u32,
	pos_in_rank: ^map[GlobalTableIndex]int,
	adjacent_rank: u32,
) -> (
	crossings: int,
) {
	for a in neighbors[left] {
		if rank_of[a] != adjacent_rank {
			continue
		}
		a_pos := pos_in_rank[a]
		for b in neighbors[right] {
			if rank_of[b] != adjacent_rank {
				continue
			}
			if a_pos > pos_in_rank[b] {
				crossings += 1
			}
		}
	}
	return
}

// Adjacent-swap refinement pass: for every adjacent pair in a rank, swaps
// them if doing so strictly reduces the crossings their edges make against
// both neighbouring ranks. Repeats to a fixed point (or the pass cap, which
// only guards a pathological oscillation) since one pass' swaps can enable
// another. Barycenter ordering alone can leave crossings a local swap would
// remove — this is the standard second stage layered-graph tools pair with
// it for that reason.
transpose_layers :: proc(
	layers: [dynamic][dynamic]GlobalTableIndex,
	neighbors: map[GlobalTableIndex][dynamic]GlobalTableIndex,
	rank_of: map[GlobalTableIndex]u32,
	pos_in_rank: ^map[GlobalTableIndex]int,
) {
	last_rank := u32(len(layers) - 1)
	for _ in 0 ..< TRANSPOSE_MAX_PASSES {
		improved := false
		for r in 0 ..< len(layers) {
			row := layers[r]
			for i in 0 ..< len(row) - 1 {
				v := row[i]
				w := row[i + 1]

				before, after: int
				if u32(r) > 0 {
					before += count_pair_crossings(v, w, neighbors, rank_of, pos_in_rank, u32(r) - 1)
					after += count_pair_crossings(w, v, neighbors, rank_of, pos_in_rank, u32(r) - 1)
				}
				if u32(r) < last_rank {
					before += count_pair_crossings(v, w, neighbors, rank_of, pos_in_rank, u32(r) + 1)
					after += count_pair_crossings(w, v, neighbors, rank_of, pos_in_rank, u32(r) + 1)
				}

				if after < before {
					row[i] = w
					row[i + 1] = v
					pos_in_rank[w] = i
					pos_in_rank[v] = i + 1
					improved = true
				}
			}
		}
		if !improved {
			break
		}
	}
}

straighten_rank :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	layers: [dynamic][dynamic]GlobalTableIndex,
	neighbors: map[GlobalTableIndex][dynamic]GlobalTableIndex,
	rank_of: map[GlobalTableIndex]u32,
	rank: u32,
	ref_rank: u32,
) {
	col := layers[rank]
	if len(col) <= 1 {
		return
	}
	if state.layout[col[0]].x != state.layout[col[len(col) - 1]].x {
		return
	}

	prev_bottom: f32
	for t, i in col {
		linked := neighbors[t]
		sum: f32 = 0
		count: f32 = 0
		for n in linked {
			if rank_of[n] == ref_rank {
				sum += state.layout[n].y
				count += 1
			}
		}

		pos := state.layout[t]
		size := node_size_for(schema, state, t)
		desired := pos.y
		if count > 0 {
			desired = sum / count
		}
		if i > 0 {
			min_y := prev_bottom + NODE_GAP_Y
			if min_y > desired {
				desired = min_y
			}
		}
		pos.y = desired
		state.layout[t] = pos
		prev_bottom = pos.y + size.y
	}
}

pack_layer_positions :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	layers: [dynamic][dynamic]GlobalTableIndex,
) {
	x_cursor: f32 = 0
	for r in 0 ..< len(layers) {
		col := layers[r]
		if len(col) == 0 {
			x_cursor += LAYER_GUTTER_X
			continue
		}

		sub_starts := make([dynamic]int, 0, 4, context.temp_allocator)
		append(&sub_starts, 0)
		y_cursor: f32 = 0
		for t, i in col {
			size := node_size_for(schema, state, t)
			if i > sub_starts[len(sub_starts) - 1] && y_cursor + size.y > MAX_RANK_HEIGHT {
				append(&sub_starts, i)
				y_cursor = 0
			}
			y_cursor += size.y + NODE_GAP_Y
		}
		append(&sub_starts, len(col))

		rank_width: f32 = 0
		for s in 0 ..< len(sub_starts) - 1 {
			start := sub_starts[s]
			end := sub_starts[s + 1]
			y: f32 = 0
			sub_width: f32 = 0
			for i in start ..< end {
				t := col[i]
				size := node_size_for(schema, state, t)
				state.layout[t] = Vec2{x_cursor + rank_width, y}
				y += size.y + NODE_GAP_Y
				if size.x > sub_width {
					sub_width = size.x
				}
			}
			total_height := y - NODE_GAP_Y
			for i in start ..< end {
				pos := state.layout[col[i]]
				pos.y -= total_height * 0.5
				state.layout[col[i]] = pos
			}
			rank_width += sub_width + SUBCOL_GUTTER_X
		}
		rank_width -= SUBCOL_GUTTER_X
		x_cursor += rank_width + LAYER_GUTTER_X
	}

	if len(layers) < 2 {
		return
	}
	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for col in layers {
		for t in col {
			visible[t] = true
		}
	}
	neighbors := make(map[GlobalTableIndex][dynamic]GlobalTableIndex, context.temp_allocator)
	rank_of := make(map[GlobalTableIndex]u32, context.temp_allocator)
	for r in 0 ..< len(layers) {
		for t in layers[r] {
			rank_of[t] = u32(r)
			linked := linked_tables(schema, t)
			defer delete(linked)
			list := make([dynamic]GlobalTableIndex, 0, len(linked), context.temp_allocator)
			for n in linked {
				if visible[n] {
					append(&list, n)
				}
			}
			neighbors[t] = list
		}
	}

	for _ in 0 ..< STRAIGHTEN_SWEEPS {
		for r in 1 ..< len(layers) {
			straighten_rank(schema, state, layers, neighbors, rank_of, u32(r), u32(r) - 1)
		}
		for r := len(layers) - 2; r >= 0; r -= 1 {
			straighten_rank(schema, state, layers, neighbors, rank_of, u32(r), u32(r) + 1)
		}
	}
}

compute_layer_order :: proc(
	schema: ^Schema,
	state: ^DiagramState,
) -> (
	layers: [dynamic][dynamic]GlobalTableIndex,
) {
	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for t in state.visible_tables {
		visible[t] = true
	}

	hop := make(map[GlobalTableIndex]u32, context.temp_allocator)
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
			append(&queue, neighbor)
		}
		delete(linked)
	}

	for _ in 0 ..< RANK_RELAX_MAX_ITER {
		changed := false
		for fk in schema.foreign_keys {
			from_i := find_table_by_column(schema.tables[:], fk.from)
			to_i := find_table_by_column(schema.tables[:], fk.to)
			if from_i < 0 || to_i < 0 {
				continue
			}
			from_t := GlobalTableIndex(u32(from_i))
			to_t := GlobalTableIndex(u32(to_i))
			// See the matching guard in main.odin's compute_layer_order: a
			// self-referencing FK makes from_hop == to_hop always, which
			// without this check never stops "relaxing".
			if from_t == state.seed_table || from_t == to_t || !visible[from_t] || !visible[to_t] {
				continue
			}
			from_hop, from_ok := hop[from_t]
			to_hop, to_ok := hop[to_t]
			if !from_ok || !to_ok {
				continue
			}
			if from_hop <= to_hop {
				hop[from_t] = to_hop + 1
				changed = true
			}
		}
		if !changed {
			break
		}
	}

	max_hop: u32 = 0
	for t in state.visible_tables {
		if h := hop[t]; h > max_hop {
			max_hop = h
		}
	}
	outer_rank := max_hop + 1

	work := make([dynamic][dynamic]GlobalTableIndex, context.temp_allocator)
	for _ in 0 ..= int(outer_rank) {
		append(&work, make([dynamic]GlobalTableIndex, context.temp_allocator))
	}
	for t in state.visible_tables {
		h, reached := hop[t]
		if !reached {
			h = outer_rank
		}
		append(&work[h], t)
	}

	neighbors := make(map[GlobalTableIndex][dynamic]GlobalTableIndex, context.temp_allocator)
	rank_of := make(map[GlobalTableIndex]u32, context.temp_allocator)
	pos_in_rank := make(map[GlobalTableIndex]int, context.temp_allocator)
	for r in 0 ..< len(work) {
		for t, i in work[r] {
			rank_of[t] = u32(r)
			pos_in_rank[t] = i
			linked := linked_tables(schema, t)
			defer delete(linked)
			list := make([dynamic]GlobalTableIndex, 0, len(linked), context.temp_allocator)
			for n in linked {
				if visible[n] {
					append(&list, n)
				}
			}
			neighbors[t] = list
		}
	}

	for sweep in 0 ..< ORDER_SWEEPS {
		if sweep % 2 == 0 {
			for r in 1 ..= int(outer_rank) {
				reorder_rank_by_neighbors(work, neighbors, rank_of, &pos_in_rank, u32(r), u32(r) - 1)
			}
		} else {
			for r := int(outer_rank) - 1; r >= 0; r -= 1 {
				reorder_rank_by_neighbors(work, neighbors, rank_of, &pos_in_rank, u32(r), u32(r) + 1)
			}
		}
	}

	transpose_layers(work, neighbors, rank_of, &pos_in_rank)

	layers = make([dynamic][dynamic]GlobalTableIndex, len(work))
	for r in 0 ..< len(work) {
		row := make([dynamic]GlobalTableIndex, len(work[r]))
		copy(row[:], work[r][:])
		layers[r] = row
	}
	return
}

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

	delete_layer_order(state.layer_order)
	state.layer_order = compute_layer_order(schema, state)
	pack_layer_positions(schema, state, state.layer_order)
	fmt.eprintln("[repro] layout done")
}

// Checks every pair of visible tables' axis-aligned boxes (using
// estimate_node_size, the same size this standalone harness lays out
// against) for overlap. Returns the number of overlapping pairs found.
count_overlaps :: proc(schema: ^Schema, state: ^DiagramState) -> int {
	overlaps := 0
	tables := state.visible_tables
	for i in 0 ..< len(tables) {
		a := tables[i]
		a_pos := state.layout[a]
		a_size := node_size_for(schema, state, a)
		for j in i + 1 ..< len(tables) {
			b := tables[j]
			b_pos := state.layout[b]
			b_size := node_size_for(schema, state, b)
			if a_pos.x < b_pos.x + b_size.x &&
			   a_pos.x + a_size.x > b_pos.x &&
			   a_pos.y < b_pos.y + b_size.y &&
			   a_pos.y + a_size.y > b_pos.y {
				overlaps += 1
				fmt.eprintfln(
					"  OVERLAP: %v %v (%v,%v %vx%v) vs %v %v (%v,%v %vx%v)",
					a,
					schema.tables[a].name,
					a_pos.x,
					a_pos.y,
					a_size.x,
					a_size.y,
					b,
					schema.tables[b].name,
					b_pos.x,
					b_pos.y,
					b_size.x,
					b_size.y,
				)
			}
		}
	}
	return overlaps
}

// --- Visual quality metrics (mirrors what ImNodes actually renders) ---
//
// These sample the exact cubic bezier ImNodes draws for each FK link (see
// GetCubicBezier in vendor/imgui/imnodes.cpp: control points offset from the
// endpoints by 0.25 * pin-to-pin distance, purely along x) so the crossing
// and node-overlap counts below reflect what a user actually sees on
// screen, not just the rank/order bookkeeping. Pin y is estimated the same
// uniform-row-height way estimate_node_size lays out a node's body, which
// is exact for this harness since it never renders through real ImNodes.

Edge :: struct {
	from_table, to_table: GlobalTableIndex,
	p0, p3:                Vec2, // p0 = output (one/referenced) pin, p3 = input (many/referencing) pin
}

pin_pos :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	column: GlobalColumnIndex,
	table_idx: GlobalTableIndex,
	is_output: bool,
) -> Vec2 {
	table := schema.tables[table_idx]
	row := int(column) - int(table.from_column)
	pos := state.layout[table_idx]
	size := node_size_for(schema, state, table_idx)
	y := pos.y + EST_HEADER_HEIGHT + f32(row) * EST_ROW_HEIGHT + EST_ROW_HEIGHT * 0.5
	x := pos.x
	if is_output {
		x += size.x
	}
	return Vec2{x, y}
}

gather_edges :: proc(schema: ^Schema, state: ^DiagramState) -> (edges: [dynamic]Edge) {
	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for t in state.visible_tables {
		visible[t] = true
	}
	for table_idx in state.visible_tables {
		table := schema.tables[table_idx]
		if !table.has_foreign_keys {
			continue
		}
		for fk in schema.foreign_keys[table.from_foreign_key:table.to_foreign_key] {
			to_i := find_table_by_column(schema.tables[:], fk.to)
			if to_i < 0 {
				continue
			}
			to_table := GlobalTableIndex(u32(to_i))
			if !visible[to_table] {
				continue
			}
			p0 := pin_pos(schema, state, fk.to, to_table, true)
			p3 := pin_pos(schema, state, fk.from, table_idx, false)
			append(&edges, Edge{from_table = table_idx, to_table = to_table, p0 = p0, p3 = p3})
		}
	}
	return
}

BEZIER_SAMPLES :: 24

// Same construction as GetCubicBezier in imnodes.cpp: control points offset
// purely along x by a quarter of the pin-to-pin distance.
sample_bezier :: proc(p0, p3: Vec2, out: []Vec2) {
	dx := p3.x - p0.x
	dy := p3.y - p0.y
	length := math.sqrt(dx * dx + dy * dy)
	offset := 0.25 * length
	p1 := Vec2{p0.x + offset, p0.y}
	p2 := Vec2{p3.x - offset, p3.y}
	n := len(out)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		mt := 1 - t
		a := mt * mt * mt
		b := 3 * mt * mt * t
		c := 3 * mt * t * t
		d := t * t * t
		out[i] = Vec2 {
			a * p0.x + b * p1.x + c * p2.x + d * p3.x,
			a * p0.y + b * p1.y + c * p2.y + d * p3.y,
		}
	}
}

orientation :: proc(a, b, c: Vec2) -> int {
	v := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	if v > 1e-6 {
		return 1
	}
	if v < -1e-6 {
		return -1
	}
	return 0
}

segments_intersect :: proc(a1, a2, b1, b2: Vec2) -> bool {
	o1 := orientation(a1, a2, b1)
	o2 := orientation(a1, a2, b2)
	o3 := orientation(b1, b2, a1)
	o4 := orientation(b1, b2, a2)
	return o1 != o2 && o3 != o4 && o1 != 0 && o2 != 0 && o3 != 0 && o4 != 0
}

rect_overlaps_polyline :: proc(min, max: Vec2, points: []Vec2) -> bool {
	for i in 0 ..< len(points) - 1 {
		p1 := points[i]
		p2 := points[i + 1]
		if p1.x < min.x && p2.x < min.x {continue}
		if p1.x > max.x && p2.x > max.x {continue}
		if p1.y < min.y && p2.y < min.y {continue}
		if p1.y > max.y && p2.y > max.y {continue}
		// One more rejection pass isn't worth the code here: at this scale
		// (a handful of samples per edge) an approximate but conservative
		// bounding-box test per segment is precise enough to compare two
		// layouts against each other.
		return true
	}
	return false
}

// Counts link-vs-link visual crossings and link-vs-node overlaps by
// sampling every FK link's actual rendered bezier curve. Two links that
// share an endpoint pin are skipped for crossing purposes (they legitimately
// touch there, not a layout defect).
count_link_crossings_and_overlaps :: proc(
	schema: ^Schema,
	state: ^DiagramState,
) -> (
	crossings: int,
	node_overlaps: int,
) {
	edges := gather_edges(schema, state)
	defer delete(edges)
	if len(edges) == 0 {
		return
	}

	samples := make([][BEZIER_SAMPLES]Vec2, len(edges), context.temp_allocator)
	for e, i in edges {
		sample_bezier(e.p0, e.p3, samples[i][:])
	}

	for i in 0 ..< len(edges) {
		for j in i + 1 ..< len(edges) {
			found := false
			for si in 0 ..< BEZIER_SAMPLES - 1 {
				for sj in 0 ..< BEZIER_SAMPLES - 1 {
					if segments_intersect(
						samples[i][si],
						samples[i][si + 1],
						samples[j][sj],
						samples[j][sj + 1],
					) {
						found = true
						break
					}
				}
				if found {break}
			}
			if found {
				crossings += 1
			}
		}
	}

	for t in state.visible_tables {
		pos := state.layout[t]
		size := node_size_for(schema, state, t)
		min := pos
		max := Vec2{pos.x + size.x, pos.y + size.y}
		for e, i in edges {
			if e.from_table == t || e.to_table == t {
				continue
			}
			if rect_overlaps_polyline(min, max, samples[i][:]) {
				node_overlaps += 1
			}
		}
	}
	return
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
	state.layout = make(map[GlobalTableIndex]Vec2)
	state.node_size = make(map[GlobalTableIndex]Vec2)

	visible := collect_visible_tables(&schema, state)
	defer delete(visible)
	state.visible_tables = visible
	fmt.eprintfln("[repro] visible: %v tables", len(visible))

	start := time.now()
	layout_visible_tables(&schema, &state)
	elapsed := time.since(start)
	fmt.eprintfln("[repro] layout took %v", elapsed)

	overlaps := count_overlaps(&schema, &state)
	crossings, node_overlaps := count_link_crossings_and_overlaps(&schema, &state)
	fmt.eprintfln(
		"[repro] done, %d layout entries, %d overlapping table pairs, %d link crossings, %d link-node overlaps",
		len(state.layout),
		overlaps,
		crossings,
		node_overlaps,
	)

	rank_of := make(map[GlobalTableIndex]int)
	for row, r in state.layer_order {
		for t in row {
			rank_of[t] = r
		}
	}
	span_hist := make(map[int]int)
	edges := gather_edges(&schema, &state)
	for e in edges {
		span := rank_of[e.from_table] - rank_of[e.to_table]
		span_hist[span] += 1
	}
	fmt.eprintfln("[repro] rank count: %d", len(state.layer_order))
	fmt.eprintfln("[repro] edge rank-span histogram (from_rank - to_rank -> count): %v", span_hist)
	for row, r in state.layer_order {
		fmt.eprintfln("[repro]   rank %d: %d tables", r, len(row))
	}

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
