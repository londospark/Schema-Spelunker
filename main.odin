package main

import c "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
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
find_table_by_column :: proc(tables: []Table, column: GlobalColumnIndex) -> int {
	for table, i in tables {
		if table.from_column <= column && column < table.to_column {
			return i
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

// Radius of the inner ring (grid px); outer rings scale up when a ring holds
// many tables so their arc distance stays readable.
RING_SPACING :: 340.0

// Radial layout: the seed table sits at the origin and every other visible
// table is placed on the ring matching its hop distance from the seed (one FK
// link = one hop, either direction). Children are ordered around their parent
// so links cross less. Runs on every view change — centring the seed is the
// point of the layout — but is skipped when the seed and visible set are
// unchanged, so re-clicking the active table (or Show All twice) costs
// nothing and leaves drags alone.
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

	visible := make(map[GlobalTableIndex]bool, context.temp_allocator)
	for t in state.visible_tables {
		visible[t] = true
	}

	// BFS from the seed through both link directions (the same neighbourhood
	// rule as collect_visible_tables) to get the hop count and BFS parent of
	// every visible table.
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
	outer_ring := max_hop + 1 // tables the seed can't reach

	// Bucket visible tables by ring (flat slice of dynamics — the map-value
	// range workaround doesn't apply here and these range safely).
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

	// Copy the map value before ranging over it: ranging directly over a
	// map-stored [dynamic] whose key is missing (nil dynamic) crashes in this
	// Odin build — reproduced standalone with the exact same data. The copy
	// ranges safely.
	angle := make(map[GlobalTableIndex]f32, context.temp_allocator)
	prev_ring_ordered: [dynamic]GlobalTableIndex
	for r in 0 ..= int(outer_ring) {
		bucket := rings[u32(r)]
		if len(bucket) == 0 {
			continue
		}

		ordered: [dynamic]GlobalTableIndex
		if r == 0 {
			state.layout[state.seed_table] = ig.Vec2{0, 0}
			angle[state.seed_table] = 0
			continue
		}

		if r == 1 || u32(r) == outer_ring {
			// No parent ordering: ring 1's only parent is the centred seed,
			// and the outer ring holds unreachable tables with no BFS parent.
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
			state.layout[t] = ig.Vec2{math.cos_f32(a) * radius, math.sin_f32(a) * radius}
			angle[t] = a
		}
		prev_ring_ordered = ordered
	}
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
				if ig.MenuItem(cstring(raw_data(theme.name))) {
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
					app_state.diagram_state = {}
					app_state.diagram_state.layout = make(map[GlobalTableIndex]ig.Vec2)
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

// One Degree / Two Degrees / Show All row, shared by the Diagram window (its
// own seed) and the schema window (the selected table) so the filter follows
// whichever table the user is looking at. Laying out the visible set is
// automatic — every filter change runs it.
show_diagram_controls :: proc(app_state: ^AppState, seed: GlobalTableIndex) {
	schema := &app_state.schema
	state := &app_state.diagram_state

	active := state.show_from_seed_table && state.seed_table == seed
	filter_button(schema, state, seed, "One Degree", active && state.degrees == 1, 1)
	ig.SameLine()
	filter_button(schema, state, seed, "Two Degrees", active && state.degrees == 2, 2)
	ig.SameLine()
	// No schema loaded yet: no view filter is in effect, so nothing is
	// highlighted (the zero-value state would otherwise light up Show All).
	// Capture the flag before the click handler below can flip
	// state.show_from_seed_table: Odin defers evaluate their arguments at scope
	// exit, so popping with the post-click value would underflow the style
	// colour stack.
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

		show_diagram_controls(app_state, diagram.seed_table)

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

		// FK endpoint columns become pins so links anchor to the right row.
		// The shapes double as cardinality symbols: the referencing column
		// (input pin, left) is the "many" side — one referenced row can be
		// pointed at by many rows — a filled triangle; the referenced column
		// (output pin, right) is the "one" side — a filled circle. Distinct
		// shapes keep every link's two ends readable even when several links
		// share the same column.
		pin_is_input := make(map[GlobalColumnIndex]bool, context.temp_allocator)
		for fk in schema.foreign_keys {
			if !(fk.from in pin_is_input) {
				pin_is_input[fk.from] = true
			}
			if !(fk.to in pin_is_input) {
				pin_is_input[fk.to] = false
			}
		}

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
				}
			}
			imn.EndNode()
		}

		// FK links between visible tables. Link ids are the FK's index into
		// the schema; pin ids are the raw GlobalColumnIndex values.
		for table_idx in diagram.visible_tables {
			table := schema.tables[table_idx]
			if !table.has_foreign_keys {
				continue
			}
			for fk, i in schema.foreign_keys[table.from_foreign_key:table.to_foreign_key] {
				to_table := find_table_by_column(schema.tables[:], fk.to)
				if to_table >= 0 && visible[GlobalTableIndex(u32(to_table))] {
					imn.Link(i32(u32(table.from_foreign_key) + u32(i)), i32(fk.from), i32(fk.to))
				}
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

		// The degree buttons act on the table selected in this list, and
		// clicking a table retargets the diagram to it — the list and the
		// diagram never need separately-picked seeds.
		seed := diagram.seed_table
		if app_state.schema_window.selected_table >= 0 {
			seed = GlobalTableIndex(u32(app_state.schema_window.selected_table))
		}
		show_diagram_controls(app_state, seed)

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
