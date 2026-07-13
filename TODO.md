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

- [ ] Floating file dialog with custom file browser
- [ ] Render a basic ER diagram: tables as labelled nodes, FK relationships
      as edges
- [ ] Node canvas — drag, zoom, select
- [ ] Sub-diagram view (1–2 degrees of separation from a selected table)
- [ ] Open DB from GUI file dialog

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
