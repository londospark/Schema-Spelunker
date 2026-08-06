# C Style Guide

C code style for this repo. Modeled on Casey Muratori's Handmade Hero
(`X:\Code\hmh`). Reference files: `handmade_types.h`, `handmade_png.cpp`,
`test_png.cpp`.

## Types

- Fixed-width integers: `i8`, `i16`, `i32`, `i64`, and unsigned `u8`, `u16`,
  `u32`, `u64` typedefs (from `<stdint.h>`). Use these, never `int8_t` etc.
  directly and never `int` where width matters.
- Byte buffers: `u8 *`.
- Floats: `f32`, `f64`.
- Sizes/indices: `memory_index` (= `size_t`) for buffer sizes, file sizes, and
  array-index loop counters. Loop counters indexed against `ArrayCount` use
  `memory_index` so no `size_t`-comparison cast is needed.
- Never cast unless a type truly requires it (e.g. a lib function returns
  `long`); prefer declaring the variable as the right type instead.
- The C standard library is allowed as a one-off exception in one-shot tools
  (`FILE`, `fopen_s`, `ftell`, etc.). No such first-party C remains as of
  2026-08-06 (`gen_icons.c` was ported to Odin — the dev-2026-07 foreign-call
  ABI crash that forced C is fixed on dev-2026-08); this guide still applies
  to any future C code in the repo.
- Security: use the MSVC secure-CRT `_s` variants where they exist
  (`fopen_s`), never the deprecated `fopen`/`sprintf`. `#define
  _CRT_SECURE_NO_WARNINGS` at the top so MSVC's `/W4` secure-CRT
  deprecations (which also fire inside vendor `stb_image_write.h`, which we
  won't rewrite) stay silent; builds are done at `/W4 /WX` (warnings as
  errors). Never commit secrets, keys, or credentials. No hardcoded
  passwords or auth tokens in source.

## Naming

- Functions: `PascalCase` (`RenderGlyph`). `main` stays lowercase.
- Types (struct/enum): `snake_case` (`icon_spec`).
- Variables, parameters, struct fields: `PascalCase` first letter capital
  (`Glyph`, `Canvas`, `Name`, `Codepoint`). No single/double-letter names;
  spell it out (`Width`, `Height`, not `W`/`H`). Short coordinate/offset
  names are fine where Casey uses them: `Ox`, `Oy`, `Px`, `Py` (he uses them
  as locals in `handmade_renderer.cpp` and `handmade_math.h`, not just in
  function names).
- Loop iteration vars only: lowercase (`i`, `x`, `y`).
- File-scope globals: `global` keyword + `Global` prefix (`GlobalSpecs`).
- Comments: `//` line style. `// NOTE(...)` for explanations, `// TODO(...)`
  for future work. Never `/* */` inline comments.

## Macros and keywords

- `typedef` for fixed-width integers (`typedef int8_t i8;`), not `#define`.
- Storage keywords that give `static` human meaning (from `handmade_types.h`):
  `#define function static`, `#define internal static`,
  `#define local_persist static`, `#define global static`. Use `internal` on
  file-local functions, `global` on file-scope data.
- `#define ArrayCount(Array) (sizeof(Array) / sizeof((Array)[0]))` — use
  instead of writing `sizeof`/`sizeof` by hand.

## Formatting

- 4-space indent, no tabs.
- Opening brace on its own line (Allman):
  ```
  if(!Glyph)
  {
      return(0);
  }
  ```
- No space between control keyword and `(`: `if(...)`, `for(...)`, `while(...)`.
- Function signature split: storage+return type on one line, name on next:
  ```
  internal i32
  RenderGlyph(stbtt_fontinfo *Font, i32 Codepoint, u8 *Canvas)
  {
  ```
- Pointer `*` binds to the name: `u8 *Canvas`.
- Multiplication written without spaces: `y*Width`, `ICON_SIZE*4`. All other
  operators spaced: `Ox + x`, `(ICON_SIZE - Width) / 2`.
- Multi-line `for` splits each clause onto its own line, aligned:
  ```
  for(i32 y = 0;
      y < Height;
      ++y)
  ```
- Short single-statement loops may stay one line: `for(memory_index i = 0; i < 2; ++i)`.
- `else` and `else if` on their own line:
  ```
  if(...)
  {
      ...
  }
  else
  {
      ...
  }
  ```
- `return` values wrapped in parens: `return(0);`, `return(Result);`.

## Header block

File starts with a `/* ===== */` comment block describing purpose. This repo
does not use the `$File:`/`$Creator:` tags from hmh; keep a plain descriptive
header.
