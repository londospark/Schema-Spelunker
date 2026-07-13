# Regenerating ImGui + ImNodes bindings

The C wrapper files (`dcimgui.h`, `dcimgui.cpp`) in this directory are generated
by [dear_bindings](https://github.com/dearimgui/dear_bindings), a Python tool
that parses `imgui.h` and produces `extern "C"` wrappers around ImGui's C++ API.

The Odin bindings (`imgui.odin`) are from
[Capati/odin-imgui](https://github.com/Capati/odin-imgui), which runs a second
generator over dear_bindings' JSON metadata to produce the `.odin` file.

The ImNodes C wrapper (`dcimnodes.h`, `dcimnodes.cpp`) and Odin bindings
(`imnodes.odin`) are hand-written and maintained manually.

## Dependencies

- **Python 3.3+** — for dear_bindings
- **Git** — to clone dear_bindings at the pinned version
- **ImGui source** — already vendored in this directory

## Regenerating dcimgui (C wrapper)

```bat
regen.bat
```

This runs `dear_bindings.py` on the vendored `imgui.h` and writes
`dcimgui.h`, `dcimgui.cpp`, and `dcimgui.json` to this directory.

## Regenerating imgui.odin (Odin bindings)

The `imgui.odin` is from Capati/odin-imgui. To regenerate:

1. Clone Capati/odin-imgui (version matching our ImGui version)
2. Run their generator pipeline (premake5 + Python + Odin)
3. Copy the resulting `imgui.odin` here

This is rarely needed — `imgui.odin` is stable and covers the entire API.
Only regenerate when:
- You update the ImGui version
- You need new ImGui functions that aren't in the current bindings

## Regenerating ImNodes bindings

The ImNodes wrapper and bindings are hand-written and don't need regeneration.
If you update the ImNodes version, manually update:
- `dcimnodes.h` — C `extern "C"` declarations
- `dcimnodes.cpp` — C implementation calling `ImNodes::*`
- `imnodes.odin` — Odin bindings matching `imn_*` functions

## Version pinning

| Component | Source | Version |
|---|---|---|
| ImGui | ocornut/imgui docking branch | v1.92.8-docking |
| dear_bindings | github.com/dearimgui/dear_bindings | DearBindings_v0.21_ImGui_v1.92.8-docking |
| ImNodes | nelarius/imnodes master | head (no tag) |
| rlImGui | TillWege/odin-rlImGui | head (no tag) |
| Capati bindings | Capati/odin-imgui main | v1.92.8-docking |

The `regen.bat` script uses the exact dear_bindings tag listed above.
Update the tag in `regen.bat` when updating ImGui.
