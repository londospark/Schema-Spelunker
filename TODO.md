# TODO

## Schema loading (immediate)

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

## GUI (prototype)

- [ ] Integrate Dear ImGui for the first-pass GUI prototype
      (vendor bindings already available in Odin)
- [ ] Render a basic ER diagram: tables as labelled nodes, FK relationships
      as edges
- [ ] ImNodes for interactive node graph — drag, zoom, select
- [ ] Sub-diagram view (1–2 degrees of separation from a selected table)
- [ ] Open DB from GUI file dialog instead of hardcoded path

## GUI framework evaluation

- [x] Document pros/cons of Dear ImGui, Raylib, Microui, and custom
      renderer in README.md

## Build / project

- [ ] Amalgamation build: compile SQLite from `sqlite3.c` + `sqlite3.h` instead
      of vendoring the binary DLL
- [ ] Cross-platform: provide `sqlite3_other.a` for non-Windows targets and
      test the build

## Performance

- [ ] Time build phases with `-show-timings` flag in both debug and release
- [ ] Time app phases (DB open, introspection queries) using `core:time`
      to measure and compare debug vs release performance
- [ ] Establish baseline numbers and track regressions across changes
