# Schema Spelunker

SQLite schema browser. SDL3 + Dear ImGui + OpenGL 3.3.

## Project structure

- `main.odin` — app entry point, GUI loop, CLI schema dump
- `schema_load.odin` — database-format abstraction: `Backend` (detect/open/close
  - neutral row listers), shared `load_schema` builder, SQLite backend
    (MSSQL/Postgres backends to come — add entries to `BACKENDS`)
- `style.odin` — theme data + `.ssTheme` loader, ImGui/ImNodes styling, icon texture loading
- `blur_windows.odin` / `blur.odin` — Windows glass blur (`#+build windows`) + no-op shim for other platforms
- `assets/` — runtime resources: Roboto font, window-control/file/folder icons, `.ssTheme` themes
- `vendor/sqlite3/` — SQLite amalgamation build, Odin bindings
- `vendor/imgui/` — Dear ImGui + ImNodes via dcimgui C wrapper, Odin bindings
- `vendor/sdl3_headers/` — SDL3 C headers for dcimgui backend compilation
- `vendor/gl/` — OpenGL 3.3 core bindings
- `_compile_libs.bat` / `_compile_libs.sh` — build vendor native libs (dcimgui.cpp, sqlite3.c, etc.)
- `build.bat` / `build.sh` / `seed.bat` / `seed.sh` / `build_icons.bat` — build, run, and asset-gen scripts
- `.zed/tasks.json` / `.zed/debug.json` — Zed editor tasks (build/run/debug/release/clean/seed for Windows + Linux) and CodeLLDB launch configs (Windows + Linux)
- `test/` — seed tools and SQL schema
- `tools/` — asset generators (`gen_icons.odin`)
- `docs/` — design docs and style guides (`C_STYLE_GUIDE.md`, `ODIN_STYLE_GUIDE.md`)
- `flake.nix` / `.envrc` — Nix dev environment

## Build

**Linux:** enter the Nix dev shell first (`nix develop .`, or via direnv on `cd`), then run the scripts below.
`nix develop . --command ./build.sh run` works for a one-shot build. The devShell provides odin
(git-master, built with LLVM 22), clang, mold, SDL3 and GL at the right versions.

`./build.sh [run|release|debug|clean]` — same semantics.
`build.sh debug run` works the same as `build.sh run debug`.
`./seed.sh` — builds and runs `test/seed.odin` to create `seed.db`.
`./seed.sh huge` — builds `test/huge_seed.odin` to create `huge.db`.

**Windows:** `build.bat [run|release|debug|clean]` — compiles vendor libs, then `odin build . -vet`.
`build.bat run` builds and launches.
`build.bat release` adds `-o:speed`.
`build.bat debug` adds `-o:none -debug`.
`build.bat clean` removes `bin/` and `build/`.

## Nix dev environment

- `flake.nix` — odin built from git-master against LLVM 22 (`make release`), wrapped with `ODIN_ROOT`
  set and clang/lld on PATH. `devShells.default` exposes odin + build deps and sets `LD_LIBRARY_PATH`.
- `nix flake update` — bumps odin-src (git-master) and nixpkgs inputs to latest; the devShell picks up new odin.
- `.envrc` — `use flake`; direnv auto-loads the devShell on `cd`.
- Sublime build system runs through `nix develop . --command ./build.sh run` so C-b works anywhere.
- Odin is also installed globally via home-manager (`~/.nix-profile/share`), which the Sublime project
  uses for stdlib file browsing.

## Key design decisions

- SDL3 for window + input. OpenGL 3.3 core for rendering.
- ImGui binds to SDL3 + OpenGL via dcimgui C wrapper.
- ImNodes for ER diagram node graph (planned).
- SQLite statically linked via amalgamation (`sqlite3.c`).
- Two foreign lib blocks in imgui.odin: `ImGui_` prefix for bare functions, `Im` for namespaced (FontAtlas_, TextureData_, etc.).
- Adaptive vsync (`SDL_GL_SetSwapInterval(-1)`). Poll-based idle loop (no WaitEvent).
- Docking via `DockSpaceOverViewport` + `io.ConfigFlags |= {.DockingEnable}`.
- No animation in tool mode. GPU idle when no input.
- **Prefer clear naming over comments.** A well-named type or variable should make
  its purpose obvious without a comment. For example, `GlobalColumnIndex` is better
  than `ColumnIndex // global index into schema.columns`. When a comment is needed,
  it should explain _why_, not _what_ or _where_.

## Vendoring rules

- **All application code is Odin.** New behavior — layout, rendering,
  algorithms, glue — goes in `.odin` files, never in the vendored C/C++.
- **Never edit vendored source** (`vendor/imgui/*.cpp`/`*.h` — ImGui, ImNodes,
  the dcimgui/dcimnodes C wrappers — `vendor/sqlite3/`, `vendor/gl/`,
  `vendor/sdl3_headers/`). If a capability seems to need a vendor change,
  find (or add) an existing Odin-callable binding instead — ImGui's own
  `DrawList_*` functions (already bound in `vendor/imgui/imgui.odin`) cover
  most custom-drawing needs without touching C++ at all. Keeping the vendor
  tree untouched keeps the update path (re-pulling a newer ImGui/ImNodes/
  SQLite release) a straight drop-in rather than a rebase of local patches.

## Communication rules

- **Only give code when I specifically ask for it.** Before that: discuss, plan, explain, compare options. I will say "give me the code" or "write it" when ready.
- **Critique honestly.** Don't soften feedback. Point out dead code, bad naming, architectural issues, stale comments.
- **Prefer small, incremental changes.** One coherent step per commit.
- **No frameworks.** No nvrhi, no custom abstractions, no engine. SDL3 + ImGui + SQLite is the stack.
- **Explain tradeoffs.** If I ask about approach A vs B, give pros/cons and a recommendation, but let me decide.
- **Read the full file before editing.** Don't assume structure.
- **Never guess APIs.** Check vendor bindings, `odin doc`, or the core library before suggesting function names. Bad guesses waste time.

## General Rules

- **Always obey the .ignore file.** Even if you know a path, don't read/write to an ignored file.

## Commit rules

- **Only commit when I ask you to.** Do not stage or commit unprompted.
- Exception: if I say "push" without "commit", stage + commit + push as a single step.

## TODO.md rules

- **You are responsible for keeping TODO.md up to date.**
- **Never remove entries.** Mark them `[x]` when done.
- All entries must have: `[S/M/L]` size, `[P0/P1/P2]` priority, `[cat]` category tag.
- When a task is completed, update its status and add the completed date inline if relevant.
- When a new task is discovered mid-session, add it to the appropriate section immediately.
- The **"If needed later"** section in TODO.md is for optimisations we don't yet know
  if we need — don't build them until a profile or real-world usage proves they matter.

## Current state

- CLI path: `print_database_information` dumps schema to stdout via `load_schema` (legacy, still works).
- GUI: SDL3 + ImGui dockspace, owner-drawn titlebar with window controls and OS glass blur (Windows), menu bar with File > Open and a Theme menu built from a live scan of `assets/themes/*.ssTheme` — each file's `name` tag is the menu label, so a dropped-in theme file extends the menu with no code change.
- Theme: Paper & Ink light/dark + OLED Dark loaded from `assets/themes/*.ssTheme` via `parse_ssTheme` / `apply_theme`.
- File dialog: custom ImGui window with directory navigation, folder/file icons, magic-byte filter (backend-driven via `known_database_format`), arena allocator per-frame listing.
- Font: Roboto loaded from `assets/Roboto.ttf` via `FontAtlas_AddFontFromFileTTF`; the bold weight (`assets/Roboto-Bold.ttf`) pushes the diagram node title text.
- Schema data model: typed structs + arena (`Schema`, `Table`, `Column`, `ForeignKey`) with FK resolution to `GlobalColumnIndex`. Loaded through the `Backend` abstraction in `schema_load.odin`; SQLite is the only backend so far.
- Diagram: ImNodes node editor; One/Two Degree buttons (also shown in the
  schema list, acting on the selection) run a BFS over the FK graph from the
  seed table and filter visible nodes, Show All restores the full set; pin
  ids are `GlobalColumnIndex`. Opening a database defaults to One Degree from
  the first table. A click (release without drag) on a table in the diagram
  or the schema list retargets the seed (accent-tinted title bar marks it);
  dragging a node only moves it.
  Layout: layered (Sugiyama-style), not the original radial rings — tables
  are ranked by hop distance from the seed (relaxed by FK direction so a
  same-rank FK never loops sideways), ranks stack left-to-right, ordered
  within each rank by barycenter + transpose crossing-reduction sweeps, then
  packed using each table's real ImNodes-rendered size (`node_size`) so
  nothing overlaps. Positions are cached and mirrored back from ImNodes each
  frame (drags persist within a view), and a refresh with an unchanged seed +
  visible set is skipped, so re-clicking the active table costs nothing.
  Whenever the view re-lays out, the editor pans so the whole layout sits at
  the centre of the viewport (`EditorContextResetPanning`, exported via the
  dcimnodes wrapper). `test/repro_layout.odin` is a standalone, no-GUI
  harness that validates the layout at scale against real `.db` files
  (overlap-free, plus crossing/link-node-overlap metrics).
  Links: drawn ourselves (`link_routing.odin`), not through ImNodes' own
  `Link()` — that draws a fixed two-point bezier with no obstacle awareness.
  Every visible table's screen rect and FK pin position is captured fresh
  each frame straight from what ImNodes just drew (via `DrawList_*` and
  node/pin item rects — no vendor edits, see "Vendoring rules" above), so a
  routed link tracks a drag or pan for free. Each link samples the plain
  direct bezier, detours around any other visible table it actually crosses
  with a couple of waypoints, then smooths the whole path with a
  Catmull-Rom spline — an unobstructed link still looks like the original
  bezier. Cardinality is drawn as crow's-foot notation on the link itself
  (crow's foot + hollow circle if the referencing column is nullable on the
  "many" end, a single tick on the "one" end); the per-pin
  triangle/circle ImNodes shapes are shrunk to a near-invisible anchor dot
  so they don't double up with these. `test/repro_link_routing.odin` checks
  the routing math standalone.
- Debugging: Zed debugger (DAP) via `.zed/debug.json` — CodeLLDB adapter
  launches the debug build (the per-OS Debug task runs `build.bat debug` /
  `build.sh debug` first); press F4 (`debugger: start`) for the new-process
  modal.

## TODO priority

1. File dialog (custom ImGui window with file list)
2. Schema data model (typed structs, arena allocator, flat arrays)
3. Display schema in ImGui window (tree or list)
4. ER diagram with ImNodes
5. Schema snapshot format

## Agent memory files

- AGENTS.md — this file (project context, agent rules)
- TODO.md — task tracking
- ~/.config/opencode/AGENTS.caveman.md — communication mode config
