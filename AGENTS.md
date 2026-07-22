# Schema Spelunker

SQLite schema browser. SDL3 + Dear ImGui + OpenGL 3.3.

## Project structure

- `main.odin` — entry point, GUI loop, CLI schema dump
- `vendor/sqlite3/` — SQLite amalgamation build, Odin bindings
- `vendor/imgui/` — Dear ImGui + ImNodes via dcimgui C wrapper, Odin bindings
- `vendor/sdl3_headers/` — SDL3 C headers for dcimgui backend compilation
- `vendor/gl/` — OpenGL 3.3 core bindings
- `_compile_libs.bat` — builds vendor native libs (dcimgui.cpp, sqlite3.c, etc.)
- `seed.bat` — builds + runs test/seed.odin to create a test database
- `test/` — seed tool and SQL schema
- `dark.rgs` — raygui style (legacy, kept)
- `Roboto.ttf` — UI font

## Build

**Windows:** `build.bat [run|release|debug|clean]` — compiles vendor libs, then `odin build . -vet`.
`build.bat run` builds and launches.
`build.bat release` adds `-o:speed`.
`build.bat debug` adds `-o:none -debug`.
`build.bat clean` removes `bin/` and `build/`.

**Linux:** `./build.sh [run|release|debug|clean]` — same semantics.
`build.sh debug run` works the same as `build.sh run debug`.
`./seed.sh` — builds and runs `test/seed.odin` to create `seed.db`.

## Key design decisions

- SDL3 for window + input. OpenGL 3.3 core for rendering.
- ImGui binds to SDL3 + OpenGL via dcimgui C wrapper.
- ImNodes for ER diagram node graph (planned).
- SQLite statically linked via amalgamation (`sqlite3.c`).
- Two foreign lib blocks in imgui.odin: `ImGui_` prefix for bare functions, `Im` for namespaced (FontAtlas_, TextureData_, etc.).
- Adaptive vsync (`SDL_GL_SetSwapInterval(-1)`). Poll-based idle loop (no WaitEvent).
- Docking via `DockSpaceOverViewport` + `io.ConfigFlags |= {.DockingEnable}`.
- No animation in tool mode. GPU idle when no input.

## Communication rules

- **Only give code when I specifically ask for it.** Before that: discuss, plan, explain, compare options. I will say "give me the code" or "write it" when ready.
- **Critique honestly.** Don't soften feedback. Point out dead code, bad naming, architectural issues, stale comments.
- **Prefer small, incremental changes.** One coherent step per commit.
- **No frameworks.** No nvrhi, no custom abstractions, no engine. SDL3 + ImGui + SQLite is the stack.
- **Explain tradeoffs.** If I ask about approach A vs B, give pros/cons and a recommendation, but let me decide.
- **Read the full file before editing.** Don't assume structure.
- **Never guess APIs.** Check vendor bindings, `odin doc`, or the core library before suggesting function names. Bad guesses waste time.

## Commit rules

- **Only commit when I ask you to.** Do not stage or commit unprompted.
- Exception: if I say "push" without "commit", stage + commit + push as a single step.

## TODO.md rules

- **You are responsible for keeping TODO.md up to date.**
- **Never remove entries.** Mark them `[x]` when done.
- All entries must have: `[S/M/L]` size, `[P0/P1/P2]` priority, `[cat]` category tag.
- When a task is completed, update its status and add the completed date inline if relevant.
- When a new task is discovered mid-session, add it to the appropriate section immediately.

## Current state

- CLI path: `extract_database_information` prints schema to stdout (legacy, still works).
- GUI path: SDL3 window + ImGui dockspace, menu bar with File > Open and Theme > Light/Dark.
- Theme: Paper & Ink light and dark variants, factored into `set_common_elements` / `set_light_theme` / `set_dark_theme`.
- File dialog: custom ImGui window with directory navigation, arena allocator per-frame listing, double-click navigation into subdirectories.
- Font: Roboto.ttf loaded via `FontAtlas_AddFontFromFileTTF`.
- ImNodes vendored but not wired yet.
- Schema data model (typed structs + arena) not built yet — `extract_database_information` still couples extraction to printing.

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
