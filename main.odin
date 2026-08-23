package main

import c "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"
import "core:time"
import gl "vendor/gl"
import ig "vendor/imgui"
import sdl_impl "vendor/imgui/backends"
import gl_impl "vendor/imgui/backends/opengl3"
import imn "vendor/imnodes"
import sdl "vendor:sdl3"

BUF_LEN :: 4096

// Custom owner-drawn titlebar geometry (device pixels).
WINDOW_BUTTON_WIDTH :: 40.0
WINDOW_CONTROLS_WIDTH :: 3 * WINDOW_BUTTON_WIDTH

FileDialog :: struct {
	show:            bool,
	dirty:           bool,
	selected_file:   i32,
	path_buffer:     [BUF_LEN]u8,
	items_in_folder: [dynamic]DirectoryItem,
	arena:           mem.Dynamic_Arena,
}

SchemaWindow :: struct {
	show:           bool,
	selected_table: i32,
}

AppState :: struct {
	window:                                                               ^sdl.Window,
	schema_name:                                                          string,
	schema_dirty:                                                         bool,
	schema:                                                               Schema,
	file_dialog:                                                          FileDialog,
	schema_window:                                                        SchemaWindow,
	diagram_state:                                                        DiagramState,

	// Titlebar window-control icons (PNG -> GL textures).
	icon_min, icon_max, icon_restore, icon_close, icon_folder, icon_page: ig.TextureRef,

	// Bold weight of the UI font, used for diagram node titles.
	font_bold:                                                            ^ig.Font,

	// Actual height of the main menu bar (font-size driven), used to offset the
	// dockspace below the titlebar and to size the window-control hit-test region.
	titlebar_height:                                                      f32,

	// Right edge (ImGui px) of the interactive menu area in the titlebar. The
	// hit-test returns NORMAL here so menu clicks reach ImGui instead of starting
	// a window drag.
	titlebar_menu_end:                                                    f32,

	// Drag fallback used when the platform has no native hit-test (SetWindowHitTest).
	drag_manual:                                                          bool,
	drag_begin:                                                           bool,
	drag_mouse_start:                                                     ig.Vec2,
	drag_win_x, drag_win_y:                                               i32,
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

	// Request the seed node be selected in the node editor on the next frame.
	// Selection must wait until the node has been rendered (ImNodes asserts
	// SelectNode on a node that isn't in its pool), so retargets from the
	// schema list or a fresh schema load set this instead of selecting now.
	pending_seed_selection: bool,

	// Which seed + visible set the current layout was computed for; a refresh
	// with an unchanged view keeps the positions (and any drags).
	layout_key:             DiagramLayoutKey,

	// Grid-space positions of every table that has been shown, keyed by table
	// index. Mirrored from ImNodes every frame (drags included) so the layout
	// only changes when the view (seed or visible set) changes.
	layout:                 map[GlobalTableIndex]ig.Vec2,

	// Real rendered size (grid px) of every table ImNodes has drawn at least
	// once, mirrored back every frame the same way `layout` is. A table with
	// no entry yet falls back to estimate_node_size until it's first drawn.
	node_size:              map[GlobalTableIndex]ig.Vec2,

	// Rank -> top-to-bottom table order from the last full layout pass.
	// pack_layer_positions reuses this to repack coordinates (e.g. once real
	// sizes are known) without redoing BFS ranking or crossing reduction.
	layer_order:            [dynamic][dynamic]GlobalTableIndex,

	// Set by layout_visible_tables when the pass placed any table using an
	// estimated size (i.e. a table ImNodes hasn't drawn before). Consumed one
	// frame later, once that table's real size has been mirrored into
	// node_size, to repack positions precisely.
	pending_size_refine:    bool,

	// Set when the visible set was re-laid-out: the next editor frame pans so
	// the whole diagram sits at the centre of the viewport.
	pending_focus_view:     bool,

	// Press tracking for click-vs-drag: when the mouse goes down over a table
	// node its id and press position are recorded; the retarget only fires if
	// the release stays within the drag threshold. A drag (node moved) is
	// never a click.
	click_candidate_node:   i32,
	click_candidate_mouse:  ig.Vec2,
}

DirectoryItemType :: enum {
	Directory,
	File,
}

DirectoryItem :: struct {
	name: cstring,
	path: cstring,
	type: DirectoryItemType,
}


GlobalColumnIndex :: distinct u32 // All tables will have at least one column therefore we don't need a sentinel value
GlobalForeignKeyIndex :: distinct u32 // There may be tables with no FK, but we will deal with that with a simple bool
GlobalTableIndex :: distinct u32

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
	from_column:       string, // Temporary value to test that we have things working before we start doing the whole index setup
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

convert_odin_string_to_begin_and_end_cstrings :: proc(
	s: string,
) -> (
	begin: cstring,
	end: cstring,
) {
	return cstring(raw_data(s)), cstring(&raw_data(s)[len(s)])
}

// -1 is the sentinel value, having a bool as well provides no real benefit at the moment, that is something that might change
// if we want to use or_* at the call sites.
//
// Binary search: load_schema appends tables in ascending column order, so
// from_column/to_column ranges are sorted and non-overlapping. This is on
// the hot path for every FK lookup (linked_tables, link drawing) — layered
// layout on a large schema calls it often enough that a linear scan turns
// O(tables) per call into O(tables) per FK, which is the difference between
// a layout pass finishing instantly and taking seconds on a few thousand
// tables.
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

collect_visible_tables :: proc(
	schema: ^Schema,
	state: DiagramState,
) -> (
	tables: [dynamic]GlobalTableIndex,
) {
	if !state.show_from_seed_table ||
	   state.degrees == 0 ||
	   state.seed_table >= GlobalTableIndex(len(schema.tables)) {
		// Seed table gone (e.g. after loading a different DB) — show everything.
		for i in 0 ..< len(schema.tables) do append(&tables, GlobalTableIndex(u32(i)))
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

refresh_diagram :: proc(schema: ^Schema, state: ^DiagramState) {
	delete(state.visible_tables)
	state.visible_tables = collect_visible_tables(schema, state^)
	if layout_visible_tables(schema, state) {
		// The visible set was re-laid-out, so centre the diagram in the editor
		// viewport on the next frame.
		state.pending_focus_view = true
	}
}

// Seed the degree filter at a table and refresh the visible set. Out-of-range
// seeds (no tables loaded yet) are a no-op.
set_diagram_seed :: proc(schema: ^Schema, state: ^DiagramState, seed: GlobalTableIndex) {
	if seed >= GlobalTableIndex(len(schema.tables)) {
		return
	}
	state.seed_table = seed
	state.show_from_seed_table = true
	refresh_diagram(schema, state)
}

show_all_tables :: proc(schema: ^Schema, state: ^DiagramState) {
	state.show_from_seed_table = false
	refresh_diagram(schema, state)
}

// Layered (Sugiyama-style) layout tuning, all in grid px. Ranks — one per hop
// distance from the seed — stack left-to-right; within a rank, tables run
// top-to-bottom and wrap into a new sub-column once the rank grows taller
// than MAX_RANK_HEIGHT, so a flat schema with hundreds of tables in one rank
// doesn't become a single absurdly tall column. Real per-table sizes (from
// node_size_for) drive every spacing decision, so packed tables never
// overlap.
//
// Left-to-right, not top-to-bottom: ImNodes always draws an input pin on a
// node's left edge and an output pin on its right, and its link curve is a
// horizontal S — control points offset purely along x by a quarter of the
// pin-to-pin distance (see GetCubicBezier in imnodes.cpp), regardless of how
// much of that distance is actually vertical. Laid out top-to-bottom, two
// pins mostly separated by a big vertical rank gutter still bulge sideways
// by a quarter of that (mostly-vertical) distance, which is enough to swing
// into a neighbouring table in the same rank. Ranking left-to-right instead
// makes the pin-to-pin distance mostly horizontal, so that same bulge lands
// inside the gutter it was already given rather than sideways into a
// sibling — and it matches the pins' fixed sides: the rank relaxation pass
// in compute_layer_order keeps a referencing ("many"/input) table at a rank
// at or after the table it references ("one"/output), so a link's output
// pin is (almost always) at or left of its input pin, which is exactly the
// direction ImNodes' left-input/right-output curve shape wants.
LAYER_GUTTER_X :: 140.0
SUBCOL_GUTTER_X :: 40.0
NODE_GAP_Y :: 50.0
MAX_RANK_HEIGHT :: 1400.0

// Crossing-reduction (barycenter) and straightening sweep counts. Almost
// every FK link connects same-rank or adjacent-rank tables (the rank
// relaxation pass below only occasionally pushes one more than one rank
// away), so a handful of sweeps is enough to converge — this is the same
// cheap heuristic Graphviz's `dot` and dagre use for layered graphs.
ORDER_SWEEPS :: 4
STRAIGHTEN_SWEEPS :: 3

// Iteration cap for the rank relaxation pass in compute_layer_order. A real
// schema's FK dependency chain converges in a handful of passes; this only
// guards against a pathological FK cycle spinning forever.
RANK_RELAX_MAX_ITER :: 64

// Fallback node size for a table ImNodes hasn't drawn yet, so the very first
// layout pass has a sane size to pack against before the real size (mirrored
// back after that first frame) triggers a precise repack. Rough character-
// width heuristic — it only needs to be in the right ballpark for one frame.
EST_CHAR_WIDTH :: 7.0
EST_WIDTH_PAD :: 36.0
EST_MIN_WIDTH :: 140.0
EST_HEADER_HEIGHT :: 34.0
EST_ROW_HEIGHT :: 20.0

estimate_node_size :: proc(schema: ^Schema, table_idx: GlobalTableIndex) -> ig.Vec2 {
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
	return ig.Vec2{width, height}
}

// Best known size for a table: the real ImNodes-rendered size once it has
// been drawn at least once this session, otherwise an estimate.
node_size_for :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	table_idx: GlobalTableIndex,
) -> ig.Vec2 {
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

// Reorders one rank in place to minimise edge crossings against ref_rank,
// using the classic barycenter heuristic: each table moves toward the
// average rank-order position of its neighbours in ref_rank. A table with no
// neighbour there keeps its current slot (key = its own index), so isolated
// tables don't get shuffled arbitrarily. merge_sort_proc is stable, so ties
// (equal barycenter) keep their previous relative order instead of
// oscillating between sweeps.
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

// Pulls a single-subcolumn rank's tables vertically toward the average y of
// their neighbours in ref_rank, then resolves top-to-bottom so minimum
// spacing is never violated — order is untouched, so this can only reduce
// edge slant, never introduce a new crossing or an overlap. Wrapped ranks
// (more than one sub-column) are left at their packed position: straightening
// a wrapped grid is a different problem and not worth the complexity here.
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
			// Positions are top-left (ImNodes' convention — see
			// SetNodeGridSpacePos), so the minimum next y is the previous
			// node's bottom edge plus the gap, no half-heights involved.
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

// Packs every rank's tables into non-overlapping grid-space positions using
// each table's best known size, wrapping a rank into new sub-columns once it
// grows past MAX_RANK_HEIGHT. Runs standalone (no BFS, no reordering) so it
// can cheaply repack once real ImNodes sizes replace first-pass estimates.
pack_layer_positions :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	layers: [dynamic][dynamic]GlobalTableIndex,
) {
	x_cursor: f32 = 0
	for r in 0 ..< len(layers) {
		col := layers[r]
		if len(col) == 0 {
			// Rank relaxation can leave a rank completely empty (a hop can
			// jump straight from N to N+2). Still advance x_cursor — every
			// rank index must own a distinct x, or the next non-empty rank
			// silently reuses this one's x and collides with it.
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
				state.layout[t] = ig.Vec2{x_cursor + rank_width, y}
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

	// Straightening: alternate sweeps pulling each rank toward its parent
	// rank, then toward its child rank, so parents tend to centre over their
	// children like a conventional tree layout instead of sitting wherever
	// the initial top-to-bottom pack put them.
	if len(layers) < 2 {
		return
	}
	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for row in layers {
		for t in row {
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

// Ranks every visible table by hop distance from the seed (BFS through both
// FK directions — the same neighbourhood rule as collect_visible_tables),
// relaxes that into a longest-path rank using FK direction (see the rank
// relaxation pass below), then reorders each rank with a few barycenter
// sweeps to reduce edge crossings against the ranks before and after it.
// Returns the final top-to-bottom order per rank, allocated with the default
// allocator since the caller keeps it around for a later size-refine repack.
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

	// Same-rank FK edges (e.g. two direct children of the seed that also
	// reference each other) would otherwise force that link to loop
	// sideways across the row, cutting through whatever sits between them.
	// Relax hop into a longest-path rank using the FK's actual direction:
	// the referencing ("many") table always ends up at least one rank
	// below the table it references, turning a same-rank link into a
	// normal top-to-bottom one. The iteration cap bounds the cost on a
	// pathological FK cycle; real schemas converge in a handful of passes.
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
			if from_t == state.seed_table || !visible[from_t] || !visible[to_t] {
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
	outer_rank := max_hop + 1 // tables the seed can't reach

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

	// Initial order within each rank is just bucket (visible_tables) order —
	// rank relaxation above means a table's rank no longer always matches
	// its BFS-tree parent's rank, so grouping by BFS parent here could put a
	// table in the wrong rank's order entirely. The barycenter sweeps below
	// converge to a good order from any starting point, so this heuristic
	// isn't needed for correctness or for a reasonable result.
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
				reorder_rank_by_neighbors(
					work,
					neighbors,
					rank_of,
					&pos_in_rank,
					u32(r),
					u32(r) - 1,
				)
			}
		} else {
			for r := int(outer_rank) - 1; r >= 0; r -= 1 {
				reorder_rank_by_neighbors(
					work,
					neighbors,
					rank_of,
					&pos_in_rank,
					u32(r),
					u32(r) + 1,
				)
			}
		}
	}

	layers = make([dynamic][dynamic]GlobalTableIndex, len(work))
	for r in 0 ..< len(work) {
		row := make([dynamic]GlobalTableIndex, len(work[r]))
		copy(row[:], work[r][:])
		layers[r] = row
	}
	return
}

// Layered layout: every visible table is ranked by hop distance from the
// seed (one FK link = one hop, either direction, then relaxed by FK
// direction — see compute_layer_order) and ranks stack left-to-right, which
// is the orientation ImNodes' link curves want (see the tuning comment
// above LAYER_GUTTER_X). Within a rank, tables are ordered to minimise edge
// crossings against the ranks before and after, then packed top-to-bottom
// using real table sizes so nothing overlaps and FK links have a clear
// gutter to run through between ranks instead of across a table body. Runs
// on every view change — centring the seed's neighbourhood is the point —
// but is skipped when the seed and visible set are unchanged, so
// re-clicking the active table (or Show All twice) costs nothing and leaves
// drags alone.
layout_visible_tables :: proc(schema: ^Schema, state: ^DiagramState) -> (relaid_out: bool) {
	visible_count := len(state.visible_tables)
	if visible_count == 0 {
		return false
	}
	if state.seed_table >= GlobalTableIndex(len(schema.tables)) {
		return false
	}

	key_sum := u64(visible_count)
	for t in state.visible_tables {
		key_sum += u64(t)
	}
	if state.layout_key.seed == state.seed_table && state.layout_key.visible_sum == key_sum {
		return false
	}
	state.layout_key.seed = state.seed_table
	state.layout_key.visible_sum = key_sum

	delete_layer_order(state.layer_order)
	state.layer_order = compute_layer_order(schema, state)
	pack_layer_positions(schema, state, state.layer_order)

	// At least one visible table may have just been placed against an
	// estimated size (never drawn before, so node_size has no entry yet).
	// The estimate is only ever off for the one frame before ImNodes draws
	// the node and reports its real size — request a repack for the frame
	// right after that happens.
	state.pending_size_refine = true
	return true
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
			if t >= 0 do append(&tables, GlobalTableIndex(u32(t)))
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

init_file_dialog :: proc(fd: ^FileDialog) -> (err: os.Error) {
	fd.show = true // Show on startup
	fd.selected_file = -1
	mem.dynamic_arena_init(&fd.arena)
	alloc := mem.dynamic_arena_allocator(&fd.arena)
	fd.items_in_folder = make([dynamic]DirectoryItem, alloc)
	directory_path := os.get_working_directory(context.temp_allocator) or_return
	copy(fd.path_buffer[:], directory_path)
	fd.dirty = true
	return nil
}

main :: proc() {
	if len(os.args) != 2 {
		make_imgui_app()
	} else {
		filename := os.args[1]
		error := print_database_information(filename)
		fmt.printfln("Return code: %v", error)
	}
}

// Apply an ImGui theme and (re)apply the OS backdrop material it requests.
// enable_os_blur is idempotent, so this is safe on every theme switch.
apply_theme_to_window :: proc(window: ^sdl.Window, theme_data: ThemeData) {
	apply_theme(theme_data)
	enable_os_blur(window, theme_data.backdrop)
}

window_hit_test :: proc "c" (
	win: ^sdl.Window,
	area: ^sdl.Point,
	data: rawptr,
) -> sdl.HitTestResult {
	as := (^AppState)(data)
	border := c.int(4)

	pw, ph: c.int
	sdl.GetWindowSizeInPixels(win, &pw, &ph)
	lw, lh: c.int
	sdl.GetWindowSize(win, &lw, &lh)
	scale := f32(pw) / f32(max(lw, 1))

	titlebar := i32(0)
	controls := i32(WINDOW_CONTROLS_WIDTH / scale)
	menu_end := i32(0)
	if as != nil {
		titlebar = i32(as.titlebar_height / scale)
		menu_end = i32(as.titlebar_menu_end / scale)
	}

	x := area[0]
	y := area[1]

	if x < border && y < border {return .RESIZE_TOPLEFT}
	if x >= lw - border && y < border {return .RESIZE_TOPRIGHT}
	if x < border && y >= lh - border {return .RESIZE_BOTTOMLEFT}
	if x >= lw - border && y >= lh - border {return .RESIZE_BOTTOMRIGHT}
	if y < border {return .RESIZE_TOP}
	if y >= lh - border {return .RESIZE_BOTTOM}
	if x < border {return .RESIZE_LEFT}
	if x >= lw - border {return .RESIZE_RIGHT}

	// Interactive titlebar content (menus, window controls) must NOT be draggable
	// — leave those to ImGui so clicks land on the widgets.
	if y < titlebar && x < menu_end {
		return .NORMAL
	}
	if y < titlebar && x < lw - controls {
		return .DRAGGABLE
	}
	return .NORMAL
}

// Create the docking host window below the owner-drawn titlebar.
dock_space_below_titlebar :: proc(app_state: ^AppState) {
	io := ig.GetIO()
	h := app_state.titlebar_height
	ig.SetNextWindowPos(ig.Vec2{0, h})
	ig.SetNextWindowSize(ig.Vec2{io.DisplaySize.x, io.DisplaySize.y - h})

	ig.PushStyleVar(.WindowRounding, 0.0)
	ig.PushStyleVar(.WindowBorderSize, 0.0)
	ig.PushStyleVarImVec2(.WindowPadding, ig.Vec2{0, 0})
	defer ig.PopStyleVar(3)

	if ig.Begin(
		"##MainDockHost",
		flags = {
			.NoTitleBar,
			.NoCollapse,
			.NoResize,
			.NoMove,
			.NoDocking,
			.NoBringToFrontOnFocus,
			.NoNavFocus,
		},
	) {
		ig.DockSpace(ig.GetID("MainDockSpace"), ig.GetContentRegionAvail())
	}
	ig.End()
}

TitleBarButtonAction :: enum {
	Minimize,
	Maximize,
	Restore,
	Close,
}

// One titlebar window-control button. Renders the icon texture when loaded,
// otherwise a plain text label (cross-platform fallback).
titlebar_button :: proc(
	app_state: ^AppState,
	id: cstring,
	icon: ig.TextureRef,
	text_label: cstring,
	text_col: ig.Vec4,
	action: TitleBarButtonAction,
) {
	clicked := false
	if icon._TexID != 0 {
		clicked = ig.ImageButton(id, icon, ig.Vec2{20, 20}, tint_col = text_col)
	} else {
		clicked = ig.Button(id, {WINDOW_BUTTON_WIDTH, app_state.titlebar_height})
	}
	if !clicked {
		return
	}
	switch action {
	case .Minimize:
		sdl.MinimizeWindow(app_state.window)
	case .Maximize:
		sdl.MaximizeWindow(app_state.window)
	case .Restore:
		sdl.RestoreWindow(app_state.window)
	case .Close:
		ev: sdl.Event
		ev.type = .QUIT
		_ = sdl.PushEvent(&ev)
	}
}

// Draw the owner-drawn titlebar via the main menu bar (always on top, full
// width): title text + File/Theme menus on the left, minimize/
// maximize-restore/close buttons pinned to the right edge.
show_titlebar :: proc(app_state: ^AppState) {
	io := ig.GetIO()
	style := ig.GetStyle()

	// Heighten the menu bar so it reads as a ~30px titlebar with the app's font.
	ig.PushStyleVarY(.FramePadding, 9.0)
	defer ig.PopStyleVar(1)
	app_state.titlebar_height = ig.GetFrameHeight()

	if ig.BeginMainMenuBar() {
		ig.SetCursorPosX(8)
		ig.TextUnformatted("Schema Spelunker")
		ig.SameLine()

		// Menus
		if ig.BeginMenu("File") {
			if ig.MenuItem("Open...") {app_state.file_dialog.show = true}
			ig.EndMenu()
		}
		ig.SameLine()
		if ig.BeginMenu("Theme") {
			// Menu built from a live scan of assets/themes/*.ssTheme — the
			// display name is each file's `name` tag, so dropping a new theme
			// file in the folder is all it takes to extend the menu.
			themes := discover_themes(context.temp_allocator)
			for theme in themes {
				if ig.MenuItem(theme.name) {
					if theme_data, theme_ok := parse_ssTheme(theme.path, context.temp_allocator);
					   theme_ok {
						apply_theme_to_window(app_state.window, theme_data)
					}
				}
			}
			ig.EndMenu()
		}
		app_state.titlebar_menu_end = ig.GetCursorPosX()

		// Window controls pinned to the right edge.
		text_col := style.Colors[ig.Col.Text]
		icon_size := ig.Vec2{20, 20}
		pad_x := (WINDOW_BUTTON_WIDTH - icon_size.x) / 2
		pad_y := (app_state.titlebar_height - icon_size.y) / 2
		ig.PushStyleVarImVec2(.FramePadding, ig.Vec2{pad_x, pad_y})
		defer ig.PopStyleVar(1)

		ig.SetCursorPosX(io.DisplaySize.x - WINDOW_CONTROLS_WIDTH)
		titlebar_button(app_state, "##win_min", app_state.icon_min, "-", text_col, .Minimize)
		ig.SameLine(0, 0)
		flags := sdl.GetWindowFlags(app_state.window)
		if .MAXIMIZED in flags {
			titlebar_button(
				app_state,
				"##win_restore",
				app_state.icon_restore,
				"[ ]",
				text_col,
				.Restore,
			)
		} else {
			titlebar_button(app_state, "##win_max", app_state.icon_max, "[]", text_col, .Maximize)
		}
		ig.SameLine(0, 0)
		ig.PushStyleColorImVec4(.ButtonHovered, {0.85, 0.16, 0.16, 0.90})
		ig.PushStyleColorImVec4(.ButtonActive, {0.95, 0.30, 0.30, 0.90})
		titlebar_button(app_state, "##win_close", app_state.icon_close, "x", text_col, .Close)
		ig.PopStyleColor(2)
	}
	ig.EndMainMenuBar()

	// Manual drag fallback for platforms without native hit-test support.
	if app_state.drag_manual {
		mouse := ig.GetMousePos()
		in_titlebar :=
			mouse.y < app_state.titlebar_height &&
			mouse.x < io.DisplaySize.x - WINDOW_CONTROLS_WIDTH
		if in_titlebar {
			if ig.IsMouseClicked(.Left) {
				app_state.drag_begin = true
				app_state.drag_mouse_start = mouse
				sdl.GetWindowPosition(
					app_state.window,
					&app_state.drag_win_x,
					&app_state.drag_win_y,
				)
			}
		}
		if app_state.drag_begin && ig.IsMouseDragging(.Left, 0) {
			delta := ig.Vec2 {
				mouse.x - app_state.drag_mouse_start.x,
				mouse.y - app_state.drag_mouse_start.y,
			}
			sdl.SetWindowPosition(
				app_state.window,
				app_state.drag_win_x + i32(delta.x),
				app_state.drag_win_y + i32(delta.y),
			)
		}
		if !ig.IsMouseDown(.Left) {
			app_state.drag_begin = false
		}
	}
}

make_imgui_app :: proc() {
	// --- hardware profile (for diagnosing startup on different machines) ---
	{
		platform := sdl.GetPlatform()
		rams := sdl.GetSystemRAM()
		fmt.eprintfln(
			"[hw] platform=%s cores=%d RAM=%dMB cacheline=%d sse4.1=%v avx2=%v avx512=%v",
			platform,
			sdl.GetNumLogicalCPUCores(),
			rams,
			sdl.GetCPUCacheLineSize(),
			sdl.HasSSE41(),
			sdl.HasAVX2(),
			sdl.HasAVX512F(),
		)
	}

	app_state: AppState
	sdl.SetHint("SDL_HINT_IME_SHOW_UI", "1")
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("SDL3 init failed: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()

	// OpenGL 3.3 core context — must be set before CreateWindow
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.GL_SetAttribute(.ALPHA_SIZE, 8) // needed for per-pixel alpha compositing

	// .TRANSPARENT is required for the OS-level blur: the window framebuffer
	// gets an alpha channel, and the desktop shows through the clear colour.
	// .BORDERLESS removes the OS titlebar — we draw our own (show_titlebar).
	window := sdl.CreateWindow(
		"Schema Spelunker",
		1600,
		900,
		{.OPENGL, .RESIZABLE, .HIDDEN, .TRANSPARENT, .BORDERLESS},
	)
	if window == nil {
		fmt.eprintfln("SDL3 CreateWindow failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)
	app_state.window = window

	// Native titlebar drag/snap via hit-test where the platform supports it
	// (Windows HTCAPTION, X11/Wayland). Unsupported platforms return false and
	// we fall back to manual dragging in show_titlebar.
	hit_test_ok := sdl.SetWindowHitTest(window, window_hit_test, &app_state)
	app_state.drag_manual = !hit_test_ok

	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintfln("SDL3 GL context failed: %s", sdl.GetError())
		return
	}
	defer sdl.GL_DestroyContext(gl_context)

	sdl.GL_MakeCurrent(window, gl_context)
	sdl.GL_SetSwapInterval(0)
	//@Note: adaptive vsync (swap interval -1) causes horrible input lag on
	// some GLX/EGL configurations despite being "adaptive".  We tried it.
	// Instead we run uncapped and pace the loop ourselves with a sleep.

	// Which GPU is actually driving the GL context? On laptops this reveals
	// whether SDL got the iGPU or the discrete GPU (Optimus/dGPU routing).
	fmt.eprintfln(
		"[gl] vendor=%s renderer=%s version=%s",
		gl.GetString(gl.GL_VENDOR),
		gl.GetString(gl.GL_RENDERER),
		gl.GetString(gl.GL_VERSION),
	)

	// Fire off the first swap to start any deferred driver work
	// (swap chain buffer allocation, DWM registration), then DON'T wait
	// for it yet — we'll overlap it with ImGui init.
	gl.Clear(gl.GL_COLOR_BUFFER_BIT)
	sdl.GL_SwapWindow(window)
	// Async GPU work is now in flight. Continue with init while it cooks.

	// Keep the window hidden during init to avoid showing a black/empty window.
	// Show it once the GPU is warmed up and we're about to enter the main loop.

	ig.CreateContext()
	defer ig.DestroyContext(nil)

	imn.CreateContext()
	defer imn.DestroyContext(nil)
	startup_backdrop := BackdropType.Mica
	if theme_data, theme_ok := parse_ssTheme(
		"assets/themes/paper_and_ink_light.ssTheme",
		context.temp_allocator,
	); theme_ok {
		apply_theme(theme_data)
		startup_backdrop = theme_data.backdrop
	}

	// Load the titlebar window-control icons (PNG -> GL textures).
	// Failures are non-fatal: show_titlebar falls back to plain text buttons.
	app_state.icon_min, _ = load_icon_texture("assets/icons/minimize.png")
	app_state.icon_max, _ = load_icon_texture("assets/icons/maximize.png")
	app_state.icon_restore, _ = load_icon_texture("assets/icons/restore.png")
	app_state.icon_close, _ = load_icon_texture("assets/icons/close.png")
	app_state.icon_folder, _ = load_icon_texture("assets/icons/folder.png")
	app_state.icon_page, _ = load_icon_texture("assets/icons/page.png")

	io := ig.GetIO()
	font_filename: cstring = "assets/Roboto.ttf"
	ascii_range := [?]ig.Wchar{32, 126, 0}
	ig.FontAtlas_AddFontFromFileTTF(io.Fonts, font_filename, glyph_ranges = &ascii_range[0])
	app_state.font_bold = ig.FontAtlas_AddFontFromFileTTF(
		io.Fonts,
		"assets/Roboto-Bold.ttf",
		glyph_ranges = &ascii_range[0],
	)

	// Init backends
	if !sdl_impl.InitForOpenGL(window, gl_context) {
		fmt.eprintln("ImGui SDL3 backend init failed")
		return
	}
	defer sdl_impl.Shutdown()

	if !gl_impl.Init("#version 330 core") {
		fmt.eprintln("ImGui OpenGL3 backend init failed")
		return
	}
	defer gl_impl.Shutdown()

	io.ConfigFlags |= {.DockingEnable}

	// --- Render a warm-up frame to force shader+texture upload ---
	// The deferred GPU work from the prime swap should be mostly done by now.
	gl_impl.NewFrame()
	sdl_impl.NewFrame()
	ig.NewFrame()
	show_titlebar(&app_state)
	dock_space_below_titlebar(&app_state)
	ig.Render()
	gl_impl.RenderDrawData(ig.GetDrawData())
	sdl.GL_SwapWindow(window)
	gl.Finish()

	FPS_CEILING :: 240.0

	// Pick a multiple of the refresh rate closest to FPS_CEILING (max 4×),
	// then throttle down if the machine can't keep up.
	display_id := sdl.GetDisplayForWindow(window)
	mode := sdl.GetCurrentDisplayMode(display_id)
	refresh_rate := 60.0
	if mode != nil && mode.refresh_rate > 0 {
		refresh_rate = f64(mode.refresh_rate)
	}

	multiple: u32 = 1
	max_multiple: u32 = 1
	fps_target: f64 = refresh_rate
	frame_time_target: f64 = 1.0 / refresh_rate

	{
		m := clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
		multiple = m
		max_multiple = m
		t := min(refresh_rate * f64(m), FPS_CEILING)
		fps_target = t
		frame_time_target = 1.0 / t
	}

	// Frame pacing throttle: 30-frame ring buffer
	FPS_HISTORY :: 30
	fps_ring: [FPS_HISTORY]f64
	fps_idx: u32
	fps_full := false

	if err := init_file_dialog(&app_state.file_dialog); err != nil {
		fmt.eprintfln("File dialog init failed: %v", err)
		return
	}
	defer mem.dynamic_arena_destroy(&app_state.file_dialog.arena)

	// Window was created hidden to avoid showing a black screen during init.
	// Now that the GPU is warmed up, make it visible.
	sdl.ShowWindow(window)

	// DWM must see an alpha-capable pixel format AND a visible window before the
	// transparency attributes take effect — SDL's .TRANSPARENT applies them too
	// early, so we re-apply here after context + show.
	enable_os_blur(window, startup_backdrop)

	// Main loop
	event: sdl.Event
	running := true
	t0 := time.tick_now()
	for running {

		// 1. Drain all pending events
		for sdl.PollEvent(&event) {
			if event.type == .QUIT {running = false}
			if event.type == .WINDOW_DISPLAY_CHANGED {
				display_id = sdl.GetDisplayForWindow(window)
				mode = sdl.GetCurrentDisplayMode(display_id)
				refresh_rate = 60.0
				if mode != nil && mode.refresh_rate > 0 {
					refresh_rate = f64(mode.refresh_rate)
				}
				max_multiple = clamp(u32(FPS_CEILING / refresh_rate), 1, 4)
				multiple = clamp(multiple, 1, max_multiple)
				fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
				frame_time_target = 1.0 / fps_target
				fps_full = false
			}
			sdl_impl.ProcessEvent(&event)
		}

		// 2. Inject the absolute latest mouse position before the frame starts
		mx, my: f32
		_ = sdl.GetMouseState(&mx, &my)
		io.MousePos = ig.Vec2{mx, my}

		// 3. Render one frame
		gl_impl.NewFrame()
		sdl_impl.NewFrame()
		ig.NewFrame()
		show_titlebar(&app_state)
		dock_space_below_titlebar(&app_state)
		{
			defer ig.Render()
			if app_state.file_dialog.show {
				show_file_dialog(&app_state) or_continue
			}

			// Load the schema before drawing the diagram so a freshly opened
			// database appears in the same frame.
			if app_state.schema_dirty {
				if schema, schema_err := load_schema(app_state.schema_name); schema_err == .None {
					mem.dynamic_arena_destroy(&app_state.schema.arena)
					app_state.schema_dirty = false
					app_state.schema = schema

					// New database: wipe diagram state, default to One
					// Degree from the first table, and build the initial
					// visible set + layout.
					delete(app_state.diagram_state.visible_tables)
					delete(app_state.diagram_state.layout)
					delete(app_state.diagram_state.node_size)
					delete_layer_order(app_state.diagram_state.layer_order)
					app_state.diagram_state = {}
					app_state.diagram_state.layout = make(map[GlobalTableIndex]ig.Vec2)
					app_state.diagram_state.node_size = make(map[GlobalTableIndex]ig.Vec2)
					if len(schema.tables) > 0 {
						app_state.diagram_state.degrees = 1
						app_state.diagram_state.show_from_seed_table = true
						app_state.diagram_state.seed_table = 0
						app_state.schema_window.selected_table = 0
						app_state.diagram_state.pending_seed_selection = true
					}
					refresh_diagram(&app_state.schema, &app_state.diagram_state)
				}
			}

			show_node_editor(&app_state)

			if app_state.schema_window.show do show_schema_window(&app_state)
		}
		// Transparent clear: the acrylic backdrop stays visible anywhere the UI
		// doesn't cover, and semi-transparent panels blend with it.
		gl.ClearColor(0.0, 0.0, 0.0, 0.0)
		gl.Clear(gl.GL_COLOR_BUFFER_BIT)
		gl_impl.RenderDrawData(ig.GetDrawData())
		sdl.GL_SwapWindow(window)

		// 4. Frame pace: sleep for the remaining time to hit target FPS.
		// No busy-wait — a fraction of a millisecond early is invisible.
		elapsed := time.duration_seconds(time.tick_since(t0))
		if elapsed < frame_time_target {
			remaining := frame_time_target - elapsed
			time.sleep(time.Duration(1e9 * remaining))
		}

		// 5. Record actual FPS and throttle down if needed
		{
			actual := 1.0 / max(elapsed, 1e-9)
			fps_ring[fps_idx] = actual
			fps_idx = (fps_idx + 1) % FPS_HISTORY
			if fps_idx == 0 {fps_full = true}

			if fps_full {
				avg := 0.0
				for v in fps_ring {avg += v}
				avg /= FPS_HISTORY

				if multiple > 1 && avg < fps_target * 0.8 {
					multiple -= 1
					fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
					frame_time_target = 1.0 / fps_target
					fps_full = false
				}

				if multiple < max_multiple && avg > fps_target * 0.95 {
					multiple += 1
					fps_target = min(refresh_rate * f64(multiple), FPS_CEILING)
					frame_time_target = 1.0 / fps_target
					fps_full = false
				}
			}
		}

		t0 = time.tick_now()
	}
}

// Load the database at path as the new schema; shared by the dialog's Open
// button and double-clicking a file entry.
open_database_file :: proc(app_state: ^AppState, path: string) {
	delete(app_state.schema_name)
	fmt.printfln("OPEN: %s", path)
	app_state.schema_name = strings.clone(path)
	app_state.schema_dirty = true
	app_state.schema_window.show = true
}

show_file_dialog :: proc(app_state: ^AppState) -> (os_err: os.Error) {
	ig.SetNextWindowSize(ig.Vec2{300, 500}, .Appearing)

	// @Note: This looks pretty odd but for a window you need the end to be called regardless of the result of ig.Begin(...)
	defer ig.End()
	if ig.Begin("Open File...") {

		if app_state.file_dialog.dirty {
			mem.dynamic_arena_free_all(&app_state.file_dialog.arena)
			alloc := mem.dynamic_arena_allocator(&app_state.file_dialog.arena)

			directory_handle, error := os.open(string(app_state.file_dialog.path_buffer[:]))
			defer os.close(directory_handle)

			app_state.file_dialog.items_in_folder = make([dynamic]DirectoryItem, alloc)

			if error == os.ERROR_NONE {

				files := os.read_dir(directory_handle, -1, context.temp_allocator) or_return
				defer os.file_info_slice_delete(files, context.temp_allocator)

				parent_path, path_alloc_error := os.clean_path(
					fmt.aprintf(
						"%s%r..",
						cstring(&app_state.file_dialog.path_buffer[0]),
						os.Path_Separator,
						allocator = alloc,
					),
					alloc,
				)
				if path_alloc_error == .None {
					append(
						&app_state.file_dialog.items_in_folder,
						DirectoryItem {
							name = "../",
							path = strings.clone_to_cstring(parent_path, alloc),
							type = .Directory,
						},
					)
				}

				for f in files {
					item: DirectoryItem
					item.name = strings.clone_to_cstring(f.name, alloc)
					path := fmt.aprintf(
						"%s%r%s",
						cstring(&app_state.file_dialog.path_buffer[0]),
						os.Path_Separator,
						item.name,
						allocator = alloc,
					)
					cleaned, err := os.clean_path(path, alloc)

					if err == .None {
						item.path = strings.clone_to_cstring(cleaned, alloc)
					} else {
						item.path = strings.clone_to_cstring(path, alloc)
					}

					if f.type == .Directory {
						item.type = .Directory
					} else {
						item.type = .File
					}

					if item.type == .Directory || known_database_format(string(item.path)) {
						append(&app_state.file_dialog.items_in_folder, item)
					}
				}
			}
			app_state.file_dialog.dirty = false
		}


		style := ig.GetStyle()
		ig.PushItemWidth(ig.GetContentRegionAvail().x)
		if ig.InputText("##path", cstring(&app_state.file_dialog.path_buffer[0]), BUF_LEN) do app_state.file_dialog.dirty = true
		ig.PopItemWidth()

		avail := ig.GetContentRegionAvail()
		listbox_height := avail.y - ig.GetFrameHeightWithSpacing() - style.ItemSpacing.y
		if ig.BeginListBox("##folder", ig.Vec2{avail.x, listbox_height}) {

			// @Todo: Should we do something to have the folders come first?
			for item, i in app_state.file_dialog.items_in_folder {
				is_selected := i32(i) == app_state.file_dialog.selected_file
				switch item.type {
				case .File:
					ig.AlignTextToFramePadding()
					ig.ImageWithBg(
						app_state.icon_page,
						ig.Vec2{32, 32},
						tint_col = style.Colors[ig.Col.Text],
					)
					ig.SameLine()
					if ig.SelectableBoolPtr(item.name, &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							open_database_file(app_state, string(item.path))
						} else {
							app_state.file_dialog.selected_file = i32(i)
						}
					}

				case .Directory:
					ig.AlignTextToFramePadding()
					ig.ImageWithBg(
						app_state.icon_folder,
						ig.Vec2{32, 32},
						tint_col = style.Colors[ig.Col.Text],
					)
					ig.SameLine()
					if ig.SelectableBoolPtr(item.name, &is_selected, {.AllowDoubleClick}) {
						if ig.IsMouseDoubleClicked(.Left) {
							app_state.file_dialog.dirty = true
							app_state.file_dialog.path_buffer = {}
							copy(app_state.file_dialog.path_buffer[:], string(item.path))
						} else {
							app_state.file_dialog.selected_file = i32(i)
						}
					}
				}
				if is_selected {
					ig.SetItemDefaultFocus()
				}
			}
			ig.EndListBox()
		}

		if ig.Button("Cancel") do app_state.file_dialog.show = false
		ig.SameLine()
		if ig.Button("Open") {
			if selected := app_state.file_dialog.selected_file;
			   selected >= 0 && selected < i32(len(app_state.file_dialog.items_in_folder)) {
				item := app_state.file_dialog.items_in_folder[selected]
				if item.type == .File {
					open_database_file(app_state, string(item.path))
				}
			}
		}
	}

	return
}

// Pushes a "this filter is active" look onto the next button; call
// active_button_pop with the same flag after the button.
active_button_color :: proc(active: bool) {
	if active {
		style := ig.GetStyle()
		ig.PushStyleColorImVec4(.Button, style.Colors[ig.Col.ButtonHovered])
		ig.PushStyleColorImVec4(.ButtonHovered, style.Colors[ig.Col.ButtonActive])
	}
}

active_button_pop :: proc(active: bool) {
	if active {
		ig.PopStyleColor(2)
	}
}

filter_button :: proc(
	schema: ^Schema,
	state: ^DiagramState,
	seed: GlobalTableIndex,
	label: cstring,
	active: bool,
	degrees: u8,
) {
	active_button_color(active)
	defer active_button_pop(active)
	if ig.Button(label) {
		state.degrees = degrees
		set_diagram_seed(schema, state, seed)
	}
}

// One Degree / Two Degrees / Show All row for the Diagram window. Laying out
// the visible set is automatic — every filter change runs it.
show_diagram_controls :: proc(app_state: ^AppState) {
	schema := &app_state.schema
	state := &app_state.diagram_state
	seed := state.seed_table

	active := state.show_from_seed_table
	filter_button(schema, state, seed, "One Degree", active && state.degrees == 1, 1)
	ig.SameLine()
	filter_button(schema, state, seed, "Two Degrees", active && state.degrees == 2, 2)
	ig.SameLine()
	// Capture the flag before the click handler below can flip
	// state.show_from_seed_table: Odin defers evaluate their arguments at scope
	// exit, so popping with the post-click value would underflow the style
	// colour stack.
	// No schema loaded yet: no view filter is in effect, so nothing is
	// highlighted (the zero-value state would otherwise light up Show All).
	show_all_active := len(schema.tables) > 0 && !state.show_from_seed_table
	active_button_color(show_all_active)
	defer active_button_pop(show_all_active)
	if ig.Button("Show All") {
		show_all_tables(schema, state)
	}
}

show_node_editor :: proc(app_state: ^AppState) {
	ig.SetNextWindowSize(ig.Vec2{600, 400}, .Appearing)
	defer ig.End()
	if ig.Begin("Diagram") {
		diagram := &app_state.diagram_state

		show_diagram_controls(app_state)

		imn.BeginNodeEditor()

		// Centre the visible diagram in the editor viewport after a re-layout.
		// ImNodes draws a node at editor-space `origin + panning`, so the diagram
		// centre lands on the canvas centre when
		// panning = canvas_size / 2 - centre — the same convention as the
		// minimap's click-to-centre in imnodes.cpp. Inside BeginNodeEditor the
		// current ImGui window IS the canvas child region, so GetWindowSize
		// returns the canvas size (ImNodes uses the same call internally).
		if diagram.pending_focus_view {
			diagram.pending_focus_view = false
			if len(diagram.visible_tables) > 0 {
				min_pos := diagram.layout[diagram.visible_tables[0]]
				max_pos := min_pos
				for table_idx in diagram.visible_tables {
					pos := diagram.layout[table_idx]
					if pos.x < min_pos.x {min_pos.x = pos.x}
					if pos.x > max_pos.x {max_pos.x = pos.x}
					if pos.y < min_pos.y {min_pos.y = pos.y}
					if pos.y > max_pos.y {max_pos.y = pos.y}
				}
				centre_x := (min_pos.x + max_pos.x) * 0.5
				centre_y := (min_pos.y + max_pos.y) * 0.5
				canvas_size := ig.GetWindowSize()
				imn.EditorContextResetPanning(
					canvas_size.x * 0.5 - centre_x,
					canvas_size.y * 0.5 - centre_y,
				)
			}
		}

		schema := &app_state.schema

		visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
		for table_idx in diagram.visible_tables {
			visible[table_idx] = true
		}

		// Pin side follows the linked nodes' relative x in the current layout,
		// never the FK's one/many semantics: the left node's pin is an output
		// (its right edge faces the link), the right node's pin an input (its
		// left edge). The rank relaxation usually puts the many side right of
		// the one side, but it deliberately exempts the seed's own FKs and
		// unreachable tables pile up on the far side — on those links the
		// static one/many mapping put both pin ends on the wrong edges. When
		// several FKs share a column, the first FK to visit it wins. A link to
		// an off-canvas table has no position to compare, so the legacy
		// one/many side is kept (the dangling pin stays on a sensible edge).
		pin_is_input := make(map[GlobalColumnIndex]bool, context.temp_allocator)
		for fk in schema.foreign_keys {
			from_table := find_table_by_column(schema.tables[:], fk.from)
			to_table := find_table_by_column(schema.tables[:], fk.to)
			if from_table < 0 || to_table < 0 {
				continue
			}
			from_visible := visible[GlobalTableIndex(u32(from_table))]
			to_visible := visible[GlobalTableIndex(u32(to_table))]
			if from_visible && to_visible {
				from_x := diagram.layout[GlobalTableIndex(u32(from_table))].x
				to_x := diagram.layout[GlobalTableIndex(u32(to_table))].x
				if from_x <= to_x {
					if !(fk.from in pin_is_input) {pin_is_input[fk.from] = false}
					if !(fk.to in pin_is_input) {pin_is_input[fk.to] = true}
				} else {
					if !(fk.from in pin_is_input) {pin_is_input[fk.from] = true}
					if !(fk.to in pin_is_input) {pin_is_input[fk.to] = false}
				}
			} else {
				if from_visible && !(fk.from in pin_is_input) {pin_is_input[fk.from] = true}
				if to_visible && !(fk.to in pin_is_input) {pin_is_input[fk.to] = false}
			}
		}

		// Screen-space geometry captured fresh every frame straight from what
		// ImNodes just drew (via ImGui's own item-rect tracking, right after
		// each node/pin is submitted) — not touching ImNodes internals, per
		// this project's no-vendor-edits rule (see AGENTS.md). This is what
		// makes draw_fk_link's routing track a drag or a pan for free: there's
		// no cached position to go stale, everything below is this frame's.
		pin_offset := imn.GetStyle().pin_offset
		node_rects := make(map[GlobalTableIndex]Rect2, context.temp_allocator)
		pin_row_y := make(map[GlobalColumnIndex]f32, context.temp_allocator)
		pin_pos := make(map[GlobalColumnIndex]ig.Vec2, context.temp_allocator)

		// The per-attribute pin marker is now redundant with the crow's-foot
		// cardinality glyphs draw_fk_link draws on the link itself (same
		// colour, same spot) — shrunk to a barely-visible anchor dot rather
		// than removed outright, since BeginInputAttribute/OutputAttribute
		// have no "no shape" option.
		imn.PushStyleVarFloat(.PinCircleRadius, 1.5)
		imn.PushStyleVarFloat(.PinTriangleSideLength, 1.5)

		for table_idx in diagram.visible_tables {
			pos := diagram.layout[table_idx]
			imn.SetNodeGridSpacePos(i32(table_idx), pos.x, pos.y)

			table := schema.tables[table_idx]
			imn.BeginNode(i32(table_idx))
			imn.BeginNodeTitleBar()
			is_seed := table_idx == diagram.seed_table
			if is_seed {
				// The seed table gets the accent-coloured title bar. The Link
				// colour IS the theme accent, so no extra state is needed.
				imn.PushColorStyle(.TitleBar, imn.GetStyle().colors[imn.Col.Link])
			}
			ig.PushFontFloat(app_state.font_bold, 0.0) // 0.0 = keep current size
			ig.TextUnformatted(convert_odin_string_to_begin_and_end_cstrings(table.name))
			ig.PopFont()
			if is_seed {
				imn.PopColorStyle()
			}
			imn.EndNodeTitleBar()

			for column, i in schema.columns[table.from_column:table.to_column] {
				column_idx := GlobalColumnIndex(u32(table.from_column) + u32(i))
				is_input, is_pin := pin_is_input[column_idx]
				if is_pin {
					if is_input {
						imn.BeginInputAttribute(i32(column_idx), .TriangleFilled)
					} else {
						imn.BeginOutputAttribute(i32(column_idx), .CircleFilled)
					}
				}
				ig.TextUnformatted(convert_odin_string_to_begin_and_end_cstrings(column.name))
				if is_pin {
					if is_input {
						imn.EndInputAttribute()
					} else {
						imn.EndOutputAttribute()
					}
					row_min := ig.GetItemRectMin()
					row_max := ig.GetItemRectMax()
					pin_row_y[column_idx] = (row_min.y + row_max.y) * 0.5
				}
			}
			imn.EndNode()

			node_min := ig.GetItemRectMin()
			node_max := ig.GetItemRectMax()
			node_rects[table_idx] = Rect2{node_min, node_max}
			for _, i in schema.columns[table.from_column:table.to_column] {
				column_idx := GlobalColumnIndex(u32(table.from_column) + u32(i))
				is_input, is_pin := pin_is_input[column_idx]
				if !is_pin {
					continue
				}
				x := is_input ? node_min.x - pin_offset : node_max.x + pin_offset
				pin_pos[column_idx] = ig.Vec2{x, pin_row_y[column_idx]}
			}
		}
		imn.PopStyleVar(2)

		// FK links between visible tables, drawn ourselves (see
		// link_routing.odin) rather than through ImNodes' own Link() so they
		// can route around tables they'd otherwise cross and carry proper
		// ER cardinality glyphs. Channel 0 is ImNodes' own link-background
		// channel (set the same way in its EndNodeEditor, right before it
		// loops over any Link() calls — there are none here — so this lands
		// underneath every node exactly like a native link would.
		draw_list := ig.GetWindowDrawList()
		ig.DrawList_ChannelsSetCurrent(draw_list, 0)
		link_color := imn.GetStyle().colors[imn.Col.Link]
		link_hover_color := imn.GetStyle().colors[imn.Col.LinkHovered]
		link_thickness := imn.GetStyle().link_thickness
		for table_idx in diagram.visible_tables {
			table := schema.tables[table_idx]
			if !table.has_foreign_keys {
				continue
			}
			for fk in schema.foreign_keys[table.from_foreign_key:table.to_foreign_key] {
				to_i := find_table_by_column(schema.tables[:], fk.to)
				if to_i < 0 || !visible[GlobalTableIndex(u32(to_i))] {
					continue
				}
				to_table := GlobalTableIndex(u32(to_i))
				many_optional := !schema.columns[fk.from].not_null
				draw_fk_link(
					draw_list,
					node_rects,
					to_table,
					table_idx,
					pin_pos[fk.to],
					pin_pos[fk.from],
					many_optional,
					link_color,
					link_hover_color,
					link_thickness,
				)
			}
		}

		imn.EndNodeEditor()

		// Mirror dragged positions back so the cache stays authoritative and a
		// later view change lays out from where the user left things. Runs before
		// the retarget check below: a retarget can reveal tables that were never
		// rendered, and GetNodeGridSpacePos asserts on those.
		for table_idx in diagram.visible_tables {
			pos_x, pos_y: f32
			imn.GetNodeGridSpacePos(i32(table_idx), &pos_x, &pos_y)
			diagram.layout[table_idx] = ig.Vec2{pos_x, pos_y}
		}

		// Mirror real rendered sizes back the same way, so node_size_for
		// has an accurate size for every table that's ever been drawn —
		// including on a future relayout of a different view.
		for table_idx in diagram.visible_tables {
			size_x, size_y: f32
			imn.GetNodeDimensions(i32(table_idx), &size_x, &size_y)
			diagram.node_size[table_idx] = ig.Vec2{size_x, size_y}
		}

		// This view's layout may have placed a never-before-drawn table
		// against an estimated size; now that ImNodes has drawn it and
		// its real size is cached above, repack once to correct any
		// spacing that estimate got wrong, then recentre on the result.
		if diagram.pending_size_refine {
			diagram.pending_size_refine = false
			pack_layer_positions(schema, diagram, diagram.layer_order)
			diagram.pending_focus_view = true
		}

		// A click on a table retargets the seed to it; a drag is not a click.
		// Track press → release: when the release lands inside the drag
		// threshold of the press (which was on a node) it's a click; moving
		// the node past the threshold makes it a drag and leaves the view
		// alone. IsMouseDragging can't be used here — it reports false on the
		// release frame itself.
		hovered: i32
		is_over_node := imn.IsNodeHovered(&hovered) != 0
		if ig.IsMouseClicked(.Left) {
			if is_over_node {
				diagram.click_candidate_node = hovered
				diagram.click_candidate_mouse = ig.GetMousePos()
			} else {
				diagram.click_candidate_node = -1
			}
		}
		if ig.IsMouseReleased(.Left) && diagram.click_candidate_node >= 0 {
			drag_threshold := ig.GetIO().MouseDragThreshold
			release_mouse := ig.GetMousePos()
			dx := release_mouse.x - diagram.click_candidate_mouse.x
			dy := release_mouse.y - diagram.click_candidate_mouse.y
			if dx * dx + dy * dy <= drag_threshold * drag_threshold {
				seed := GlobalTableIndex(u32(diagram.click_candidate_node))
				set_diagram_seed(schema, diagram, seed)
				imn.ClearNodeSelection()
				imn.SelectNode(i32(seed))
				app_state.schema_window.selected_table = i32(seed)
			}
			diagram.click_candidate_node = -1
		}

		// Deferred seed selection (schema load / list retarget): the node was
		// rendered above, so the pool is guaranteed to hold it now.
		if diagram.pending_seed_selection {
			diagram.pending_seed_selection = false
			imn.ClearNodeSelection()
			imn.SelectNode(i32(diagram.seed_table))
		}
	}
}

show_schema_window :: proc(app_state: ^AppState) {
	schema := app_state.schema
	ig.SetNextWindowSize(ig.Vec2{800, 600}, .Appearing)
	defer ig.End()
	if ig.Begin(strings.clone_to_cstring(schema.database_name, context.temp_allocator)) {
		diagram := &app_state.diagram_state

		// Clicking a table retargets the diagram to it — the list and the
		// diagram never need separately-picked seeds.
		avail := ig.GetContentRegionAvail()

		is_selected := false
		if ig.BeginListBox("##folder", avail) {
			for table, i in schema.tables {
				is_selected = i32(i) == app_state.schema_window.selected_table
				if ig.SelectableBoolPtr(
					strings.clone_to_cstring(table.name, context.temp_allocator),
					&is_selected,
				) {
					app_state.schema_window.selected_table = i32(i)
					set_diagram_seed(&app_state.schema, diagram, GlobalTableIndex(u32(i)))
					diagram.pending_seed_selection = true
				}
			}
			ig.EndListBox()
		}
	}
}

print_database_information :: proc(filename: string) -> SchemaError {
	schema := load_schema(filename) or_return
	defer mem.dynamic_arena_destroy(&schema.arena)

	for table in schema.tables {
		fmt.printfln("TABLE: %v", table.name)

		for column in schema.columns[table.from_column:table.to_column] {
			not_null: string
			pk: string
			if column.not_null || column.composite_key_index > 0 {
				not_null = "NOT_NULL"
			}
			if column.composite_key_index > 0 {
				pk = fmt.tprintf("PRIMARY KEY INDEX: %v", column.composite_key_index)
			}
			fmt.printfln("- %v OF %v %s %s", column.name, column.type, not_null, pk)
		}
	}
	return .None
}
