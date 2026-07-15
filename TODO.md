# TODO

Legend: `[S/M/L]` = size · `[P0/P1/P2]` = priority · `[cat]` = category

---

## Schema loading

- [ ] `[S]` `[P1]` `[binding]` Column type accessors: `column_int`, `column_double`,
      `column_type`, `column_count`, `column_name`
- [ ] `[M]` `[P2]` `[binding]` More PRAGMA introspection: `index_list`, `index_info`,
      `foreign_key_list`, `table_xinfo`
- [ ] `[S]` `[P2]` `[binding]` Bind `sqlite3_errmsg` for human-readable error messages
- [ ] `[M]` `[P1]` `[data]` Typed structs for each introspection query so schema data
      is strongly typed rather than ad-hoc
- [ ] `[S]` `[P1]` `[data]` Arena allocator for schema data lifetime — load once,
      free on reload
- [ ] `[M]` `[P2]` `[data]` Dump schema to a custom snapshot format so exploration
      doesn't need repeated DB hits
- [ ] `[S]` `[P2]` `[cli]` CLI mode: `schema_spelunker dump something.db` to produce
      the snapshot

## GUI

- [x] `[M]` `[P0]` `[gui]` SDL3 + ImGui + OpenGL 3.3 application loop
- [x] `[S]` `[P0]` `[gui]` Dockspace via `DockSpaceOverViewport`
- [x] `[S]` `[P0]` `[gui]` Roboto TTF font loading
- [ ] `[M]` `[P1]` `[gui]` File dialog: custom ImGui window with file list,
      path navigation, open/cancel
  - [x] `[S]` `[P1]` Cancel button wired (closes or resets)
  - [ ] `[S]` `[P1]` Open button — open selected file
  - [ ] `[S]` `[P1]` Double-click on file to confirm / on dir to navigate in
  - [ ] `[S]` `[P1]` Directory navigation (up, into subdirs)
  - [ ] `[S]` `[P1]` Keyboard shortcuts (Enter to confirm, Esc to cancel)
  - [ ] `[S]` `[P2]` Path bar showing current directory
  - [ ] `[S]` `[P2]` File type filter (`.db`, `.sqlite`, `*`)
- [x] `[S]` `[P1]` `[gui]` File dialog: use arena allocator for per-frame
      directory listing (reset each frame, no per-element delete)
- [ ] `[M]` `[P1]` `[gui]` Query and display schema data in ImGui tree/lists
- [ ] `[L]` `[P1]` `[gui]` ER diagram node graph via ImNodes: tables as labelled
      nodes, FK relationships as edges
- [ ] `[M]` `[P2]` `[gui]` Node canvas — drag, zoom, select
- [ ] `[M]` `[P2]` `[gui]` Sub-diagram view (1–2 degrees of separation from
      a selected table)
- [ ] `[S]` `[P2]` `[gui]` Schema snapshot viewer (load from file, no DB needed)

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
- [ ] `[M]` `[P1]` `[build]` Cross-platform: test the build on Linux and macOS
      (need `setup.sh`)
- [ ] `[L]` `[P1]` `[build]` Linux support: `setup.sh` for fetching/building
      deps (SDL3, sqlite3 amalgamation), odin build, font path, run
- [ ] `[S]` `[P2]` `[build]` Linux: provide `sqlite3.a` and `imgui.a` for
      non-Windows targets

## Performance

- [ ] `[S]` `[P2]` `[perf]` Time build phases with `-show-timings` flag in both
      debug and release
- [ ] `[M]` `[P2]` `[perf]` Time app phases (DB open, introspection queries)
      using `core:time` to measure and compare debug vs release performance
- [ ] `[S]` `[P2]` `[perf]` Establish baseline numbers and track regressions
      across changes
