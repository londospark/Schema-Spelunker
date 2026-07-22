# Schema Spelunker

An interactive desktop tool for exploring database schemas — fast, native,
GPU-accelerated, and built in the handmade spirit.

Inspired by [SchemaSpy](https://schemaspy.org/) and its wonderful diagramming,
but aiming for a live, interactive experience rather than static HTML output.

## Vision

- Open a database file in a GUI and immediately see its schema
- ER diagrams rendered interactively — zoom, pan, select, explore
- Sub-diagrams showing 1–2 degrees of separation from a selected table
- Everything stays fast because it runs natively on the GPU
- Dump the schema to a custom snapshot format so you can explore offline
  without repeatedly hitting the database
- CLI mode (`schema_spelunker path/to/database.db`) for scripting and CI

## Philosophy

Handmade software in the spirit of Casey Muratori, Ryan Fleury, and
gingerBill: minimal dependencies, own the stack where it counts, no
framework magic. The project uses Odin for its no-nonsense approach to
systems programming and its excellent FFI for binding C libraries like
SQLite.

**Optimisations are driven by profiles, not hunches.** The codebase builds
things simply first and only adds complexity when real-world usage proves
it matters. String interning, `#soa` layouts, and other cache-oriented
tricks live in the "If needed later" section of TODO.md until a profile
says otherwise.

## Current status

Early but building fast.

**SQLite:** vendored as source (`vendor/sqlite3/sqlite3.c` amalgamation
v3.48.0) instead of a binary `.dll`. Compiled to a static `.lib` on the
first build. Schema introspection via `PRAGMA table_info` and
`PRAGMA foreign_key_list` works on the command line.

**GUI:** Dear ImGui v1.92.8-docking with full C-ABI bindings via
dear_bindings-generated `dcimgui` + Capati/odin-imgui Odin bindings.
rlImGui bridges raylib (windowing, input, rendering) to ImGui.
ImNodes (nelarius/imnodes) is vendored and bound for the ER diagram
node graph. Docking is enabled.

**Build:** all native dependencies (SQLite, ImGui, ImNodes, rlImGui) are
compiled from source on the first build using MSVC, auto-detected via
vswhere. No binary blobs in the repo. Subsequent builds are pure-Odin
and take under a second.

## Building & running

Requires MSVC (Visual Studio 2022 Build Tools or newer) on Windows.
The build script auto-detects your VS installation via vswhere.

```
build.bat              # debug build (compiles native libs on first run)
build.bat run          # debug build + run
build.bat release      # optimized build (-o:speed)
build.bat debug        # debug build with symbols (-o:none -debug)
build.bat clean        # remove build output
```

Flags can be combined: `build.bat debug run`, `build.bat release run`.

**Linux** uses the same interface via `build.sh`:

```
./build.sh run          # debug build + run
./build.sh release      # optimized build (-o:speed)
./build.sh debug        # debug build with symbols (-o:none -debug)
./build.sh clean        # remove build output
```

`build.sh debug run` and `build.sh run debug` both work.

The spelunker takes a database path as a CLI argument:

```
schema_spelunker.exe path/to/database.db
```

Running without arguments opens the GUI.

## Seeding a test database

A sample multi-tenant Kanban board schema is in `test/complex.sql` with
16 tables, users, teams, roles, permissions, boards, columns, cards,
labels, comments, and activity history.

```
seed.bat                         # creates seed.db from test/complex.sql
schema_spelunker.exe seed.db     # explore it via CLI
build.bat run                    # explore it via GUI
```

---

## Architecture

```
vendor/
├── sqlite3/
│   ├── sqlite3.c / .h          SQLite amalgamation (compiled to .lib)
│   └── sqlite3.odin            Odin FFI bindings
├── imgui/
│   ├── imgui.cpp / .h etc.     ImGui v1.92.8-docking source
│   ├── dcimgui.h / .cpp        dear_bindings C wrapper (extern "C")
│   ├── imgui.odin              Odin bindings from Capati/odin-imgui
│   ├── imnodes.cpp / .h        ImNodes source
│   ├── dcimnodes.h / .cpp      Hand-written ImNodes C wrapper
│   └── imnodes.odin            Hand-written ImNodes Odin bindings
└── rlimgui/
    ├── rlImGui.cpp / .h        raylib→ImGui backend
    ├── rlImGui.odin            Odin bindings
    └── include/                raylib C headers (v6.0) for compilation
```

All C/C++ sources are compiled into a single static `.lib` by
`_compile_libs.bat` when any of the `.lib` files are missing.
Odin then links against these via `foreign import`.
