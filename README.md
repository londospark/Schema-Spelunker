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

**Stack:** SDL3 (window + input), OpenGL 3.3 core (rendering), Dear ImGui
(docking branch, C-ABI via dcimgui), ImNodes (ER diagram), SQLite
(amalgamation, statically linked). Borderless window with an owner-drawn
titlebar and optional OS glass blur on Windows.

**SQLite:** vendored as source (`vendor/sqlite3/sqlite3.c` amalgamation)
instead of a binary `.dll`, compiled to a static `.lib` on the first build.
Schema introspection via `PRAGMA table_info` / `PRAGMA foreign_key_list`.

**Build:** all native dependencies (SQLite, ImGui, ImNodes, SDL3 backends)
are compiled from source on the first build via MSVC (auto-detected with
vswhere) or clang/mold in the Nix dev shell. No binary blobs in the repo.

## Project layout

```
main.odin            app entry point, GUI loop, CLI schema dump
style.odin           theme data + .ssTheme loader, ImGui/ImNodes styling
blur_windows.odin    Windows glass blur (#+build windows)
blur.odin            no-op blur shim for other platforms
assets/              runtime resources: Roboto.ttf, icons/, themes/
vendor/              vendored C sources + Odin bindings (sqlite3, imgui,
                     sdl3_headers, gl, stb)
docs/                design docs + C_STYLE_GUIDE.md, ODIN_STYLE_GUIDE.md
test/                seed tools and SQL schema
tools/               asset generators (gen_icons.odin)
build.bat, build.sh  Windows / Linux build scripts
```

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
