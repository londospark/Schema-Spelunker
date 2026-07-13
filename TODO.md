# TODO

## Schema loading

- [ ] Column type accessors: `column_int`, `column_double`, `column_type`,
      `column_count`, `column_name`
- [ ] More PRAGMA introspection: `index_list`, `index_info`, `foreign_key_list`,
      `table_xinfo`
- [ ] Bind `sqlite3_errmsg` for human-readable error messages
- [ ] Typed structs for each introspection query so schema data is strongly
      typed rather than ad-hoc
- [ ] Arena allocator for schema data lifetime — load once, free on reload
- [ ] Dump schema to a custom snapshot format so exploration doesn't need
      repeated DB hits
- [ ] CLI mode: `schema_spelunker dump something.db` to produce the snapshot

## GUI

- [ ] Write `gui.odin`: ImGui + rlImGui setup (docking enabled)
- [ ] Query and display schema data in ImGui tree/lists
- [ ] Open DB from GUI (file dialog)
- [ ] ER diagram node graph via ImNodes:
      tables as labelled nodes, FK relationships as edges
- [ ] Node canvas — drag, zoom, select
- [ ] Sub-diagram view (1–2 degrees of separation from a selected table)
- [ ] Schema snapshot viewer (load from file, no DB needed)

## Build / project

- [x] Amalgamation build: compile SQLite from `sqlite3.c` + `sqlite3.h` instead
      of vendoring the binary DLL
- [x] Vendor ImGui docking branch source + cimgui bindings
- [x] Vendor ImNodes + rlImGui for raylib backend
- [ ] Custom `gui.odin` entry point with docking + open/save file dialogs
- [ ] Cross-platform: test the build on Linux and macOS (need `setup.sh`)
- [ ] Linux: provide `sqlite3.a` and `imgui.a` for non-Windows targets

## Performance

- [ ] Time build phases with `-show-timings` flag in both debug and release
- [ ] Time app phases (DB open, introspection queries) using `core:time`
      to measure and compare debug vs release performance
- [ ] Establish baseline numbers and track regressions across changes
