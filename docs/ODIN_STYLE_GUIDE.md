# Odin Style Guide

Odin code style for this repo. The app (`main.odin`, `style.odin`,
`blur_windows.odin`) and the tools (`tools/*.odin`) follow these
conventions. There is no `odin fmt` in the current dev build — formatting is
applied by hand and enforced in review.

## Naming

- Types (struct/enum/union): `PascalCase` (`AppState`, `ThemeData`, `IconSpec`).
- Procedures: `snake_case` (`show_file_dialog`, `render_glyph`,
  `load_icon_texture`).
- Variables, parameters, struct fields: `snake_case` (`app_state`,
  `schema_name`, `text_main`).
- Constants: `SCREAMING_SNAKE` (`BUF_LEN`, `ICON_SIZE`,
  `WINDOW_BUTTON_WIDTH`). Group them at the top of the file.
- Enum values: `PascalCase`, used as `.Minimize`, `.File`, `.AllowDoubleClick`.
- Package aliases: short lowercase (`ig "vendor/imgui"`, `sdl "vendor:sdl3"`,
  `stbi "vendor:stb/image"`). Use an alias when the package name doesn't read
  well at the call site; a plain `import "core:fmt"` needs no alias.
- Fields of a struct don't repeat the type name: `AppState.schema_name`, not
  `AppState.app_state_schema_name`.

## Column alignment

This is the repo's signature style — keep it when editing.

- **Struct field definitions**: align the `:` column, then the type column,
  across a group of related fields. Type stays the last column; alignment
  padding goes before the `:`.

  ```odin
  // [title_bar]
  title_bg:         ig.Vec4,
  title_bg_focus:   ig.Vec4,
  title_bg_faded:   ig.Vec4,
  ```
- **Struct literals**: align the `name =` column so values line up.

  ```odin
  GLOBAL_SPECS := []IconSpec{
  	{name = "minimize", codepoint = 0xE921},
  	{name = "maximize", codepoint = 0xE922},
  	{name = "restore",  codepoint = 0xE923},
  	{name = "close",    codepoint = 0xE8BB},
  }
  ```
- Use tabs for indentation, spaces for alignment padding (tab-align the
  group start, then spaces to pad within the group).
- Realign the whole group when a longer name is added — don't leave a stale
  ragged column.
- Multi-field struct declarations on one line are fine for short, related
  fields: `icon_min, icon_max, icon_restore, icon_close: ig.TextureRef,`
  (as used in `AppState`).

## Braces and layout

- `{` on the same line as the `struct`/`proc`/control statement (Odin
  default; matches `odin fmt` output).
- One-tab indentation. Braces always explicit for `if`/`for` bodies — no
  single-line bodies.
- Blank line between declaration groups inside a struct; use a `// [section]`
  comment to label thematic groups in large structs (`ThemeData`).
- Procedure signatures: `:: proc` parameters on the signature line; if the
  parameter list is long, `params :=` style is not used — keep it on one line
  where it fits, otherwise break after `(` with each param on its own line.

## Comments

- `//` style only. Explain **why**, not **what** or **where** (AGENTS.md).
  A well-named symbol needs no what-comment.
- `// [section]` group markers are the one allowed labelling comment.
- File header: a `//` block at the top of the file describing purpose and any
  non-obvious constraints (see `tools/gen_icons.odin` for the pattern).

## Imports

- One per line, `core` packages first (alphabetical), then `vendor` packages
  (alphabetical by path).
- Alias foreign/vendor packages to short lowercase names; core packages
  usually unaliased.

## Theming constants

- Window/UI metrics that appear multiple times become named constants
  (`WINDOW_BUTTON_WIDTH`, `WINDOW_CONTROLS_WIDTH`), not magic numbers.

## Formatting discipline

- No `odin fmt` exists in the current build — alignment and layout are manual.
- Before finishing a change, `odin build -vet` (or `odin check -vet` for a
  type-check) the file; vet catches unused symbols and shadowing that the eye
  misses.
- Keep changes small and coherent; one style topic per commit.
