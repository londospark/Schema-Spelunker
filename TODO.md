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
- [ ] `[M]` `[P1]` `[data]` Second pass to resolve FK `to_table`/`to_column` strings
      to `GlobalColumnIndex` after all tables are loaded — then remove temporary
      `from_column` string field from `ForeignKey`
- [x] `[S]` `[P2]` `[data]` Read column properties (`type`, `not_null`, `pk`) from
      `pragma_table_info`
- [x] `[S]` `[P2]` `[data]` Remove `@Todo` on `database_name` — currently cloned
      from filename, confirm that's the right lifetime
- [ ] `[S]` `[P2]` `[data]` Avoid duplicate schema load in GUI double-click handler
      (`print_database_information` re-calls `extract_database_information`)

## If needed later

Things we don't know if we'll need, kept here so we don't forget them but don't
spend time on them prematurely.

- [~] `[S]` `[P3]` `[data]` Consider string interning (esp. column types) if memory
      usage ever becomes a concern — store `string` directly for now
- [~] `[S]` `[P3]` `[data]` Store `referenced_by` slice on `Table` for O(1)
      reverse FK lookups (currently scan `foreign_keys` array on demand)
- [~] `[M]` `[P2]` `[prof]` Integrate Tracy profiler for frame timing, zone
      instrumentation, and allocation tracking — can't optimise blind
- [ ] `[M]` `[P2]` `[data]` Dump schema to a custom snapshot format so exploration
      doesn't need repeated DB hits
- [ ] `[S]` `[P2]` `[cli]` CLI mode: `schema_spelunker dump something.db` to produce
      the snapshot
- [~] `[S]` `[P3]` `[perf]` Pre-filter magic bytes check by `.db`/`.sqlite` extension
      first to avoid opening every file in large directories
- [~] `[S]` `[P3]` `[perf]` Replace `fmt.ctprintf` + `clone_to_cstring` with
      `ig.TextUnformatted` in schema/node display loops to avoid per-frame allocs
- [~] `[S]` `[P3]` `[perf]` Batch SQLite introspection queries instead of one
      `PRAGMA` per table (2000+ round trips at scale)

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
- [~] `[L]` `[P1]` `[gui]` ER diagram node graph via ImNodes: tables as labelled
      nodes with columns, Paper & Ink theme applied
- [ ] `[M]` `[P2]` `[gui]` Draw FK links in node editor: after FK column
      resolution, loop `schema.foreign_keys` and call `imn.Link`
- [ ] `[M]` `[P2]` `[gui]` Node canvas — drag, zoom, select (ImNodes provides basic)
- [ ] `[M]` `[P2]` `[gui]` Sub-diagram view (1–2 degrees of separation from
      a selected table)
- [ ] `[S]` `[P2]` `[gui]` Schema snapshot viewer (load from file, no DB needed)

## Theme migration

Migrate themes from hard-coded Odin procedures to `.ssTheme` files on
disk.  See `docs/THEME_MIGRATION.md` for detailed plan.

- [x] `[L]` `[P1]` `[theme]` Step 1: Write the two `.ssTheme` files
      (`paper_and_ink_light.ssTheme`, `paper_and_ink_dark.ssTheme`)
      translating current colour assignments into `[text]`, `[background]`,
      `[controls]`, `[title_bar]`, `[table_card]`, `[border]`,
      `[diagram_grid]`, `[accent]`, `[layout]` sections
- [x] `[M]` `[P1]` `[theme]` Step 2: Create theme loader — `ThemeData` struct,
      `parse_ssTheme` parser, `apply_theme` writer, hex/axis-pair helpers.
      Inlined in `main.odin` (no separate file).
- [x] `[S]` `[P2]` `[theme]` Step 3: Remove `set_common_elements` (layout
      values now served as defaults in `ThemeData`)
- [x] `[S]` `[P2]` `[theme]` Step 4: Remove `_imnodes_light_theme` and
      `_imnodes_dark_theme` stubs (already dead code, confirmed gone)
- [x] `[S]` `[P2]` `[theme]` Step 5: Remove `Theme` enum, replace references
      with `ThemeData`
- [x] `[M]` `[P2]` `[theme]` Step 6: Replace `set_theme` calls with
      `parse_ssTheme("themes/paper_and_ink_light.ssTheme")` + `apply_theme`
- [ ] `[S]` `[P2]` `[theme]` Step 7: Build Theme menu dynamically from
      `discover_themes()` slice (currently hardcoded to two files)
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

- [x] `[L]` `[P0]` `[build]` Amalgamation build: compile SQLite from `sqlite3.c`
      + `sqlite3.h` instead of vendoring binary DLL
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
- [ ] `[S]` `[P2]` `[refactor]` Extract `rebuild_directory_listing` and
      `render_file_dialog` from `show_file_dialog` to reduce nesting depth
