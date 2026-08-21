# TODO

Legend: `[S/M/L]` = size · `[P0/P1/P2]` = priority · `[cat]` = category

---

## Schema loading

- [x] `[S]` `[P1]` `[binding]` Column type accessors: `column_int`, `column_double`,
      `column_type`, `column_count`, `column_name`
- [ ] `[M]` `[P2]` `[binding]` More PRAGMA introspection: `index_list`, `index_info`,
      `foreign_key_list`, `table_xinfo`
- [ ] `[S]` `[P2]` `[binding]` Bind `sqlite3_errmsg` for human-readable error messages
- [x] `[S]` `[P1]` `[data]` Arena allocator for schema data lifetime — load once,
      free on reload (implemented via `Schema.arena` + `Dynamic_Arena`)
- [x] `[M]` `[P1]` `[data]` Second pass to resolve FK `to_table`/`to_column` strings
      to `GlobalColumnIndex` after all tables are loaded
- [x] `[S]` `[P2]` `[data]` Read column properties (`type`, `not_null`, `pk`) from
      `pragma_table_info`
- [x] `[S]` `[P2]` `[data]` Remove `@Todo` on `database_name` — currently cloned
      from filename, confirm that's the right lifetime
- [x] `[S]` `[P2]` `[data]` Avoid duplicate schema load in GUI double-click handler
      (`print_database_information` re-calls `extract_database_information`) —
      double-click now sets `schema_dirty` and the main loop loads once;
      `print_database_information` is CLI-only
- [x] `[L]` `[P1]` `[data]` Abstract SQLite schema extraction behind a backend
      interface — `schema_load.odin` defines `Backend` (detect/open/close +
      neutral row listers) and shared `load_schema`; SQLite backend uses the
      PRAGMA queries. GUI load, CLI dump, and the file-dialog sniff all go
      through it (`known_database_format`), so MSSQL/Postgres are drop-in
      `BACKENDS` entries
- [ ] `[L]` `[P2]` `[data]` MSSQL backend — catalog queries
      (`INFORMATION_SCHEMA`/sys), connection string opens instead of a file
- [ ] `[L]` `[P2]` `[data]` Postgres backend — catalog queries, connection
      string opens; note SQL-backend assumption: row lists must be grouped by
      table in table order
- [ ] `[S]` `[P2]` `[data]` Revisit `load_schema` keying if a future backend
      needs it (only matters if a backend returns rows ungrouped)

## If needed later

Things we don't know if we'll need, kept here so we don't forget them but don't
spend time on them prematurely.

- [~] `[S]` `[P3]` `[data]` Consider string interning (esp. column types) if memory
  usage ever becomes a concern — store `string` directly for now
- [~] `[S]` `[P3]` `[data]` Store `referenced_by` slice on `Table` for O(1)
  reverse FK lookups (currently scan `foreign_keys` array on demand)
- [~] `[S]` `[P3]` `[data]` Add `table_index` field to `Column` for O(1)
  column→table lookup (currently scan `tables[]` range check)
- [~] `[S]` `[P3]` `[data]` Cache diagram layout positions per seed table
  so revisiting a sub-diagram remembers node positions after drag —
  drags persist within a view (positions mirrored into
  `DiagramState.layout` every frame), but a retarget re-centres the seed
  and re-lays-out the visible set. Per-seed position memory across
  retargets would need a layout cache keyed by (seed, visible set)
- [~] `[S]` `[P2]` `[data]` Remove temporary `from_column`/`to_table`/`to_column`
  string fields from `ForeignKey` now that index resolution works
- [~] `[S]` `[P2]` `[data]` Remove `resolved_to_index` bool from `ForeignKey` once
  display code checks resolution (currently set but never read)
- [~] `[M]` `[P2]` `[prof]` Integrate Tracy profiler for frame timing, zone
  instrumentation, and allocation tracking — can't optimise blind
- [ ] `[M]` `[P2]` `[data]` Dump schema to a custom snapshot format so exploration
      doesn't need repeated DB hits
- [ ] `[S]` `[P2]` `[cli]` CLI mode: `schema_spelunker dump something.db` to produce
      the snapshot
- [~] `[S]` `[P3]` `[perf]` Pre-filter magic bytes check by `.db`/`.sqlite` extension
  first to avoid opening every file in large directories
- [~] `[M]` `[P3]` `[settings]` File dialog filter model (settings-raft item):
  filter mode (All files / SQLite extensions / custom), "verify SQLite magic
  on open" toggle — sniff the one file being opened instead of every file
  in the listing (corp AV / network share safe)
- [~] `[S]` `[P3]` `[perf]` Replace `fmt.ctprintf` + `clone_to_cstring` with
  `ig.TextUnformatted` in schema/node display loops to avoid per-frame allocs
- [~] `[S]` `[P3]` `[perf]` Batch SQLite introspection queries instead of one
  `PRAGMA` per table (2000+ round trips at scale)
- [~] `[S]` `[P3]` `[build]` Odin git-master: ranging directly over a
  map-stored `[dynamic]` with a missing key segfaults (reproduced
  standalone in `test/repro_layout.odin`). Workaround in
  `layout_visible_tables`: copy the map value into a local before ranging.
  Drop the workaround when a fixed compiler is pinned.

## GUI

- [x] `[M]` `[P0]` `[gui]` SDL3 + ImGui + OpenGL 3.3 application loop
- [x] `[S]` `[P0]` `[gui]` Dockspace via `DockSpaceOverViewport`
- [x] `[S]` `[P0]` `[gui]` Roboto TTF font loading
- [x] `[S]` `[P1]` `[gui]` Menu bar with File > Open and Theme > Light/Dark switching
- [x] `[S]` `[P1]` `[gui]` File dialog: custom ImGui window with file list,
      path navigation, open/cancel
  - [x] `[S]` `[P1]` Cancel button wired (closes or resets)
  - [ ] `[S]` `[P1]` Open button — open selected file (stub exists, does nothing)
  - [x] `[S]` `[P1]` Double-click detection wired via `AllowDoubleClick` +
        `IsMouseDoubleClicked`
  - [~] `[S]` `[P1]` Double-click navigation into subdirectories
    (path_buffer set on click, but takes two frames to take effect since
    `os.open` already ran this frame)
  - [ ] `[S]` `[P1]` Keyboard shortcuts (Enter to confirm, Esc to cancel)
  - [x] `[S]` `[P2]` Path bar showing current directory (InputText, works now
        that buffer isn't zeroed every frame)
  - [x] `[S]` `[P2]` File type filter — magic bytes check on file open
  - [x] `[S]` `[P1]` Fix stability bug: `or_continue` on `show_file_dialog` error
        skips `ig.Render()` — fixed with `defer ig.Render()` block
  - [x] `[S]` `[P1]` Fix path buffer lifecycle: don't zero `path_buffer` every
        frame before `os.open` — no longer zeroed on every frame
  - [x] `[S]` `[P1]` File dialog: directory re-read every frame even when
        unchanged — add `dirty` flag to `FileDialog`, only rebuild listing
        on navigation
  - [ ] `[S]` `[P2]` File dialog: sort directories before files in the list
  - [ ] `[S]` `[P2]` File dialog: `os.open` error silently swallowed when
        directory can't be opened — show error message or return error
- [x] `[S]` `[P1]` `[gui]` File dialog: use arena allocator for per-frame
      directory listing (reset each frame, no per-element delete)
- [x] `[S]` `[P1]` `[gui]` Basic table-list schema viewer (listbox in schema
      window shows table names)
- [ ] `[M]` `[P1]` `[gui]` Schema detail view: when a table is selected, show its
      columns in an ImGui `BeginTable` with columns Name, Type, Nullable, PK
- [ ] `[S]` `[P1]` `[gui]` Foreign-key panel in schema detail view: show FK
      rows (from column, to table.to column) below the column table
- [ ] `[S]` `[P1]` `[gui]` Schema extractor errors surfaced to user: store
      `last_error: string` on `AppState`, show as status bar or notification

## Sub-diagram / ER diagram

Phased implementation of the filtered sub-diagram view with FK link lanes.

### Phase 1: Diagram state + BFS + FK links (MVP)

- [x] `[S]` `[P0]` `[gui]` Add `DiagramState` to `AppState` with `seed_table: u32`
      and `show_from_seed_table: bool` — zero value = show all tables
- [x] `[S]` `[P0]` `[gui]` Write `find_table_by_column :: proc(tables: []Table,
col: GlobalColumnIndex) -> int` — scans `from_column..to_column` range,
      returns -1 if not found
- [x] `[S]` `[P0]` `[gui]` Wire "One Degree" / "Two Degrees" / "Show All" buttons
      to set `diagram_state.degrees` and `show_from_seed_table`
- [x] `[M]` `[P0]` `[gui]` BFS over FK graph from seed table, collecting
      visible table indices within N degrees. Handle N=0/all as full set —
      wired 2026-08-21: degree buttons and schema load call
      `refresh_diagram_visible`; out-of-range seed falls back to the full set;
      `DiagramState.dirty` removed (refresh is immediate, no deferral needed)
- [x] `[M]` `[P0]` `[gui]` Render only visible nodes in `show_node_editor` —
      node loop iterates `diagram_state.visible_tables`
- [x] `[M]` `[P0]` `[gui]` Draw FK links: loop the visible tables' FK ranges,
      `imn.Link` where the referenced table is also visible. Link ids are the
      FK's index into the schema; pin ids are raw `GlobalColumnIndex` values —
      FK-endpoint columns are registered as pins (`BeginInputAttribute` for
      referencing, `BeginOutputAttribute` for referenced) so links anchor to
      the correct column line

### Phase 2: Seed-centred layout

- [x] `[S]` `[P1]` `[gui]` Compute each visible table's hop distance from the
      seed (BFS through both FK directions, restricted to the visible set)
- [x] `[S]` `[P1]` `[gui]` Place the seed at the origin and every other table
      on the ring matching its hop count — ring radius scales with the ring's
      table count so dense rings stay readable; deeper rings are ordered
      around their parent's angle to keep links short (unreachable tables go
      on one outermost ring)
- [x] `[S]` `[P1]` `[gui]` Call `imn.SetNodeGridSpacePos` on each node
      before rendering to place it on its ring

Layout runs automatically on every view change (schema load, degree button,
seed retarget, Show All): the seed must land in the centre, so the visible
set is re-laid-out each time — that's the whole point of a centred layout.
Two guards keep it cheap on huge databases: positions are cached in
`DiagramState.layout` and mirrored back from ImNodes every frame (drags
included), and a refresh whose seed and visible set are unchanged
(`layout_key`) is skipped entirely, so re-clicking the active table or Show
All twice costs nothing. Show All on huge.db is a single radial pass per
click (O(V) placement, no per-frame cost).

### Phase 3: Polish

- [ ] `[S]` `[P2]` `[gui]` Pin attributes on column rows (`imn.BeginPin` /
      `imn.EndPin`) so FK links attach to the correct column line —
      FK-endpoint pins + anchoring done in Phase 1; remaining: pins on
      every column row
- [ ] `[S]` `[P2]` `[gui]` Visual direction: referenced table column =
      output pin (right side), referencing table column = input pin (left) —
      direction done for FK endpoints in Phase 1; remaining: apply to all
      column rows
- [x] `[S]` `[P2]` `[gui]` Highlight active seed table in the diagram — seed
      node gets the accent-coloured title bar (reads theme accent from the
      ImNodes Link colour, no extra state)
- [x] `[S]` `[P2]` `[gui]` Degree buttons show current state as selected/active
      (One Degree / Two Degrees / Show All all show their active state; row
      shared between the Diagram and schema windows)
- [x] `[M]` `[P2]` `[gui]` Schema window links to diagram: selecting a table
      in the schema list sets it as the diagram seed and shows One/Two Degree
      buttons that operate on the list selection; clicking a table node in
      the diagram retargets the seed back (both sync the node selection and
      the list highlight; selection is deferred a frame via
      `pending_seed_selection` because ImNodes asserts `SelectNode` on an
      unrendered node)
- [x] `[S]` `[P1]` `[gui]` Retarget happens on a click, not a drag: release
      without mouse movement past the drag threshold on a table retargets;
      dragging a node just moves it
- [x] `[S]` `[P2]` `[gui]` Cardinality symbols on FK links: the referencing
      (input) end is a filled triangle — the "many" side; the referenced
      (output) end is a filled circle — the "one" side. Shape contrast keeps
      both ends of every link readable even when one column is the endpoint
      of many links
- [x] `[S]` `[P2]` `[gui]` Default view on schema load: One Degree around the
      first table (seed table 0, list selection 0, node selected)
- [x] `[S]` `[P2]` `[gui]` Centre the seed in the editor viewport whenever the
      view re-lays-out: `EditorContextResetPanning` exported through the
      dcimnodes wrapper (pan = seed pos − window size / 2, the same canvas
      convention ImNodes uses for its minimap); skips the pan when nothing
      was re-laid-out, and never fights manual panning
- [ ] `[S]` `[P2]` `[gui]` Schema snapshot viewer (load from file, no DB needed)

## Theme migration

Migrate themes from hard-coded Odin procedures to `.ssTheme` files on
disk. See `docs/THEME_MIGRATION.md` for detailed plan.

- [x] `[L]` `[P1]` `[theme]` Step 1: Write the two `.ssTheme` files
      (`paper_and_ink_light.ssTheme`, `paper_and_ink_dark.ssTheme`)
      translating current colour assignments into `[text]`, `[background]`,
      `[controls]`, `[title_bar]`, `[table_card]`, `[border]`,
      `[diagram_grid]`, `[accent]`, `[layout]` sections
- [x] `[M]` `[P1]` `[theme]` Step 2: Create theme loader — `ThemeData` struct,
      `parse_ssTheme` parser, `apply_theme` writer, hex/axis-pair helpers.
      Originally inlined in `main.odin`, later extracted to `style.odin`.
- [x] `[S]` `[P2]` `[theme]` Step 3: Remove `set_common_elements` (layout
      values now served as defaults in `ThemeData`)
- [x] `[S]` `[P2]` `[theme]` Step 4: Remove `_imnodes_light_theme` and
      `_imnodes_dark_theme` stubs (already dead code, confirmed gone)
- [x] `[S]` `[P2]` `[theme]` Step 5: Remove `Theme` enum, replace references
      with `ThemeData`
- [x] `[M]` `[P2]` `[theme]` Step 6: Replace `set_theme` calls with
      `parse_ssTheme("assets/themes/paper_and_ink_light.ssTheme")` + `apply_theme`
- [x] `[M]` `[P1]` `[theme]` Step 7: Build Theme menu dynamically from
      `discover_themes()` scan of `assets/themes/*.ssTheme` — removes hardcoded
      Light/Dark entries, user can drop custom `.ssTheme` files in the
      themes folder (done 2026-08-22)
- [x] `[S]` `[P2]` `[theme]` Step 8: Delete unused helpers —
      `imn_col` kept (used by `apply_theme`), `Theme` enum removed,
      dead stubs removed, `set_common_elements` removed
- [ ] `[M]` `[P2]` `[theme]` Step 9: Test — visual parity with current themes,
      fallback when file missing, custom `.ssTheme` with partial overrides

## CLI

- [x] `[S]` `[P0]` `[cli]` CLI mode: extract + print schema to stdout
- [x] `[S]` `[P0]` `[cli]` Parameterised introspection queries via
      `pragma_table_info(?)`
- [ ] `[S]` `[P2]` `[cli]` `schema_spelunker dump <file>` output snapshot

## Build / project

- [x] `[L]` `[P0]` `[build]` Amalgamation build: compile SQLite from `sqlite3.c` + `sqlite3.h` instead of vendoring binary DLL
- [x] `[L]` `[P0]` `[build]` Vendor ImGui docking branch source + dcimgui
      C wrapper + Odin bindings
- [x] `[M]` `[P0]` `[build]` Vendor SDL3 headers for dcimgui backend compilation
- [x] `[S]` `[P0]` `[build]` Vendor OpenGL 3.3 core bindings
- [x] `[S]` `[P0]` `[build]` Fix foreign lib link-prefix split in imgui.odin
- [x] `[S]` `[P0]` `[build]` Post-processing script for binding regen
- [x] `[M]` `[P1]` `[build]` Cross-platform: test the build on Linux and macOS
      (confirmed working on macOS ARM and Linux x64 — ImGui + SQLite)
- [x] `[L]` `[P1]` `[build]` Linux support: `setup.sh` for fetching/building
      deps — not needed, existing `_compile_libs.sh` + `build.sh` works on
      Linux x64 and macOS ARM out of the box
- [ ] `[S]` `[P2]` `[build]` Linux: provide `sqlite3.a` and `imgui.a` for
      non-Windows targets
- [x] `[S]` `[P2]` `[build]` Document `debug` argument in `build.bat`
      (AGENTS.md lists `[run|release|clean]` but `debug` exists)
- [x] `[S]` `[P2]` `[build]` Add `debug` + two-position arg support to `build.sh`
      to match `build.bat` semantics
- [ ] `[S]` `[P2]` `[build]` Replace hardcoded two-position arg checks in
      `build.bat` and `build.sh` with a `shift` loop for arbitrary flag ordering
- [x] `[S]` `[P2]` `[project]` Icon generator: `tools/gen_icons.odin` rasterises
      Segoe MDL2 window-control glyphs to `assets/icons/*.png` (committed).
      Ported from C on 2026-08-06: the dev-2026-07 foreign-call ABI crash on
      consecutive stb_truetype rasterise calls is fixed on dev-2026-08
      (verified with a 6-glyph repro). Glyph source remains Windows-only
      (Segoe MDL2 font); committed PNGs keep the runtime cross-platform.
- [ ] `[S]` `[P2]` `[build]` Cross-platform smoke test for the owner-drawn
      titlebar on Linux/macOS (Nix shell): drag fallback path, vendor:stb/image
      PNG decode, borderless window — Windows verified only so far
- [x] `[S]` `[P2]` `[project]` Zed debugger wiring: `.zed/debug.json` with
      CodeLLDB launch configs for Windows + Linux; `build` field references
      the per-OS Debug task so the `-o:none -debug` build runs before launch
      — 2026-08-21
- [x] `[S]` `[P2]` `[project]` Add huge_seed tool (`test/huge_seed.odin`) for
      generating large test databases (2000 tables, random FKs). Build via
      `seed.bat huge`.
- [x] `[S]` `[P2]` `[project]` Update "Current state" section in AGENTS.md
      (was still saying "empty dockspace")

## Performance

- [x] `[M]` `[P1]` `[perf]` Frame pacing ramp-up: `multiple` now increases when
      30-frame avg exceeds 95% of target and `multiple < max_multiple`. FPS
      can recover after throttling down (was stuck at lowest throttle forever).
- [x] `[S]` `[P1]` `[perf]` Refresh rate re-query on `WINDOW_DISPLAY_CHANGED`:
      `display_id`, `refresh_rate`, and targets recalculated when window moves
      to another monitor.
- [ ] `[S]` `[P2]` `[perf]` Time build phases with `-show-timings` flag in both
      debug and release
- [ ] `[M]` `[P2]` `[perf]` Time app phases (DB open, introspection queries)
      using `core:time` to measure and compare debug vs release performance
- [ ] `[S]` `[P2]` `[perf]` Establish baseline numbers and track regressions
      across changes

## Tech debt / polish

- [x] `[S]` `[P2]` `[gui]` Add theme state enum to track current theme
- [x] `[S]` `[P2]` `[project]` Update AGENTS.md "Current state" section —
      (was still saying "empty dockspace" and "demo window removed")
- [x] `[S]` `[P3]` `[gui]` Bump `BUF_LEN` from 1024 to 4096 for long Windows paths
- [x] `[M]` `[P2]` `[refactor]` Extract theme/styling code from `main.odin` into
      `style.odin` (~440 lines moved)
- [ ] `[S]` `[P2]` `[refactor]` Extract `rebuild_directory_listing` and
      `render_file_dialog` from `show_file_dialog` to reduce nesting depth
- [x] `[M]` `[P1]` `[gui]` OS-level glass blur: transparent SDL3 window
      (`.TRANSPARENT` + alpha-0 clear + `GL_ALPHA_SIZE=8`) with per-pixel alpha
      via `DWMWA_REDIRECTIONBITMAP_ALPHA` (Win11 24H2+) + empty-region
      `DwmEnableBlurBehindWindow` fallback, and theme-configurable backdrop
      (`[glass] backdrop = "mica"|"acrylic"|"none"` -> `DWMWA_SYSTEMBACKDROP_TYPE`).
      Implemented in `blur_windows.odin`, applied after window is shown.
      Tuned: both themes Mica — light `backdrop_alpha 0.65` (subtle paper
      tint, effective ~0.87 after dock-host + child alpha stacking), dark
      `backdrop_alpha 1.0` (pixel-exact opaque). Original acrylic @ 0.35 let
      the desktop show through 65%, washing out the light paper and muddying
      dark; Mica reads through reliably on both light and dark systems.
- [x] `[M]` `[P1]` `[gui]` Custom title bar: borderless window
      (`SDL_SetWindowBordered(false)`) with client-side min/max/close + drag
      (WM_NCHITTEST HTCAPTION) — superseded by the owner-drawn titlebar entry
      below, done via `SDL_SetWindowHitTest` DRAGGABLE instead
- [x] `[M]` `[P1]` `[gui]` Owner-drawn titlebar: `.BORDERLESS` window, title +
      File/Theme menus + min/max-restore/close buttons (Segoe MDL2 glyphs
      rasterised to `assets/icons/*.png` by `tools/gen_icons.odin`, decoded at
      runtime via `vendor:stb/image`) in the main menu bar. Native drag/snap via
      `SDL_SetWindowHitTest` (returns DRAGGABLE for the titlebar, resize edges
      at the window border), manual `SetWindowPosition` fallback when the
      platform lacks hit-test. Dockspace host offset below the titlebar.
      Verified on Windows: min/max/restore/close + drag all work.
