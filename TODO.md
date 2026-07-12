# TODO

## Schema data lifetime

- [ ] Replace `context.temp_allocator` in the exec callback with an arena allocator
      so that schema data can be batch-freed on reload without leaking.

## Bindings

- [ ] More PRAGMA introspection: `index_list`, `index_info`, `foreign_key_list`,
      `table_xinfo`
- [ ] Column type accessors: `column_int`, `column_double`, `column_type`,
      `column_count`, `column_name`
- [ ] Bind `sqlite3_errmsg` for human-readable error messages

## `exec` reflection layer

- [ ] Typed deserialisation path — map known query shapes directly to Odin
      structs using the column index
- [ ] Dynamic path — collect arbitrary results as `map[string]string` when
      the schema isn't known ahead of time

## Build / project

- [ ] CLI argument handling: take the database path from command-line args
      instead of hardcoding `something.db`
- [ ] Amalgamation build: compile SQLite from `sqlite3.c` + `sqlite3.h` instead
      of vendoring the binary DLL
- [ ] Cross-platform: provide `sqlite3_other.a` for non-Windows targets and
      test the build
