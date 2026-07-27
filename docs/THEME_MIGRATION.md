# Theme migration: hard-coded to file-based

## What is changing

Themes are moving from hard-coded Odin procedures to `.ssTheme` files on
disk.  Instead of a `set_theme` procedure with a `switch` over a two-case
enum, the application scans a `themes/` directory at startup, parses the
files, and builds the Theme menu dynamically.

### Before

```odin
// main.odin — theme enum and switch
Theme :: enum { Light, Dark }

set_theme :: proc(app_state: ^AppState, theme: Theme) {
    switch theme {
    case .Light:
        // 120 lines of colour assignments
    case .Dark:
        // 120 lines of colour assignments
    }
}
```

### After

```odin
// theme_loader.odin — parse and apply .ssTheme files
load_theme :: proc(filepath: string) -> (ThemeData, bool)
apply_theme :: proc(data: ThemeData)

// main.odin — discover themes and show menu
themes := discover_themes()
// ... menu items built from themes[]
```

---

## What is being removed

### `Theme` enum

The two-value enum is replaced by `ThemeData` — a struct that holds all
colours and layout values parsed from a `.ssTheme` file.  There is no
enumeration of possible themes; any `.ssTheme` file in the directory is a
valid theme.

### `set_common_elements` procedure

The shared sizing / spacing / rounding values currently set in this
procedure move into the `[layout]` section of each `.ssTheme` file.
The defaults are baked into `ThemeData` so that a theme file may omit
any or all of them.

### `set_imnodes_light_theme` and `set_imnodes_dark_theme` stubs

Already renamed to `_imnodes_light_theme` and `_imnodes_dark_theme` from a
previous refactor.  These are dead code and are deleted as part of this
change.  ImNodes colour slots are now filled by `apply_theme` in
`theme_loader.odin`, using the same `ThemeData` that drives ImGui.

### `imn_col` helper

This conversion function moves from `main.odin` into `theme_loader.odin`
since it is now only needed during theme application.

---

## What is added

### `theme_loader.odin` (new file)

~120 lines containing:

- `ThemeData` — the full colour + layout struct (application-domain names)
- `load_theme` — parses a `.ssTheme` file into `ThemeData`
- `apply_theme` — writes `ThemeData` into `ig.GetStyle()` and `imn.GetStyle()`
- `discover_themes` — scans `themes/*.ssTheme`, returns `[]ThemeInfo`
- `parse_colour` — hex `#RRGGBB` / `#RRGGBBAA` parser
- `parse_axis_pair` — `horizontal: X, vertical: Y` parser

### `themes/` directory

Contains the shipped themes:

```
themes/
├── paper_and_ink_light.ssTheme
└── paper_and_ink_dark.ssTheme
```

These are the canonical definitions of the two built-in themes.  The
application no longer has any colour values embedded in code.

---

## Migration steps

### Step 1 — Create `theme_loader.odin`

Write the parser and `apply_theme` function.  This is pure new code;
nothing is broken during this step.

### Step 2 — Write the two `.ssTheme` files

Translate the current hard-coded Light and Dark colour assignments into
the `[text]`, `[background]`, `[controls]`, `[title_bar]`, `[table_card]`,
`[border]`, `[diagram_grid]`, `[accent]`, and `[layout]` sections.

This is a mechanical translation — no logic changes.

### Step 3 — Remove `set_common_elements`

Delete the procedure.  Its values are now served as defaults inside
`ThemeData` and written by `apply_theme`.

### Step 4 — Remove `_imnodes_light_theme` and `_imnodes_dark_theme`

These stubs are already dead code.  Delete them.

### Step 5 — Remove the `Theme` enum

Replace references to `Theme` with `ThemeData`.  The menu no longer
switches on an enum; it selects from a slice of discovered themes.

### Step 6 — Replace `set_theme`

The old `set_theme(&app_state, theme_enum)` becomes:

```odin
if data, ok := load_theme(filepath); ok {
    apply_theme(&app_state, data)
}
```

The startup call changes from:

```odin
set_theme(&app_state, .Light)
```

to:

```odin
if data, ok := load_theme("themes/paper_and_ink_light.ssTheme"); ok {
    apply_theme(&app_state, data)
}
```

### Step 7 — Build the Theme menu from the theme list

```odin
themes := discover_themes()
for t in themes {
    if ig.MenuItem(cstring(raw_data(t.name))) {
        if data, ok := load_theme(t.filepath); ok {
            apply_theme(&app_state, data)
        }
    }
}
```

The hard-coded Light / Dark menu items are deleted.

### Step 8 — Delete unused helpers

- `imn_col` — moves to `theme_loader.odin`
- `set_common_elements` — removed (layout lives in `.ssTheme`)
- `Theme` enum — removed
- `_imnodes_light_theme` / `_imnodes_dark_theme` — removed

### Step 9 — Test

1. Build and run — verify the light theme looks identical to before.
2. Switch to dark via the menu — verify it matches the previous dark.
3. Delete `paper_and_ink_light.ssTheme` — verify the fallback is
   usable (all defaults).
4. Add a custom `.ssTheme` with a single `accent.colour` — verify it
   appears in the menu and applies.

---

## Backward compatibility

The change is a straight replacement.  Theme visual output is identical
before and after.  No user data is affected.  The only observable change
is that the application now ships with a `themes/` directory alongside
the executable.

## Future: `.ssConfig`

The theme system is designed so that a future `.ssConfig` settings file
can store a `theme = "themes/paper_and_ink_dark.ssTheme"` line, allowing
the application to restore the user's theme choice on next launch.
