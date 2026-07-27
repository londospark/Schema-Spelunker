# `.ssTheme` Format Specification

## Overview

Schema Spelunker themes use `.ssTheme` files — a human-readable configuration format
designed to be edited by hand in any text editor. The format is a custom TOML-inspired
key–value grammar with sections, nested keys, basic data types, and comments.

No external parsing library is required. All theme files are parsed by the application's
own `theme_loader.odin` (~120 lines).

---

## File format

### Encoding

UTF-8 without BOM. Line endings may be LF (Unix) or CRLF (Windows).

### Comments

A `#` character begins a comment that runs to the end of the line.
Comments may appear on their own line or after a value:

```ini
# This is a comment
name = "Paper & Ink Light"  # inline comment
```

Inline comments after values are discouraged in published themes but tolerated
by the parser.

### Sections

Lines are grouped into sections denoted by `[section_name]`.  A section
ends when the next section starts or the file ends.

```ini
[text]
main = "#1F1F1F"
muted = "#8C8C8C"

[background]
window = "#F5F5F0"
```

Keys belong to the most recently declared section.  If a value appears
before the first section it is assigned to the implicit root section
(reserved for metadata: `name`, `author`, `description`).

### Data types

| Type | Example | Description |
|---|---|---|
| **String** | `"Paper & Ink Light"` | Double-quoted. Used for `name`, `author`, `description`. |
| **Colour** | `"#1F1F1F"` or `"#2C579680"` | Hex `#RRGGBB` or `#RRGGBBAA`. Embedded quotes are part of the value. |
| **Integer** | `2` | Whole number. Used for layout scalars. |
| **Axis pair** | `horizontal: 8, vertical: 6` | Two named fields separated by commas. Order does not matter. |

### Overall structure

```
<metadata fields>              # root section (no heading)

[section]                      # named section
key = <value>                  # one or more key-value pairs

[another_section]              # next section
key = <value>
```

---

## Theme sections

### Root section (metadata)

Keys before any `[section]` heading.

| Key | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Human name shown in the Theme menu. |
| `author` | string | no | Creator name. |
| `description` | string | no | Short description of the theme. |

### `[text]`

| Key | Default | Description |
|---|---|---|
| `main` | `"#1F1F1F"` | Body text, headings. |
| `muted` | `"#8C8C8C"` | Disabled labels, hints. |

### `[background]`

| Key | Default | Description |
|---|---|---|
| `window` | `"#F5F5F0"` | Main window canvas. |
| `child` | `"#F5F5F0"` | Child windows, panels inside the main canvas. |
| `popup` | `"#FFFFFF"` | Menus, tooltips, dropdowns. |

### `[controls]`

| Key | Default | Description |
|---|---|---|
| `frame` | `"#FFFFFF"` | Background of buttons, text inputs, dropdowns, sliders. |
| `frame_hover` | `"#E5EAF2"` | Control background when the mouse is over it. |
| `frame_active` | `"#D9E0EB"` | Control background while it is being interacted with. |

### `[title_bar]`

| Key | Default | Description |
|---|---|---|
| `background` | `"#EBEBE6"` | Window title bar, menu bar. |
| `background_focus` | `"#E0E0DB"` | Title bar when the window is the focused window. |
| `background_faded` | `"#EBEBE6"` | Collapsed or unfocused title bar. |

### `[table_card]`

These are the database table nodes in the diagram view.

| Key | Default | Description |
|---|---|---|
| `background` | `"#FFFFFF"` | Normal state. |
| `background_hovered` | `"#F9F9F2"` | Mouse cursor hovering over the card. |
| `background_selected` | `"#F0F0E8"` | Card is selected or active. |
| `outline` | `"#BFBFB8"` | Border drawn around the card. |

### `[border]`

| Key | Default | Description |
|---|---|---|
| `main` | `"#BFBFB8"` | Standard borders, dividers, strong lines. |
| `subtle` | `"#D9D9D1"` | Light inner borders, faint separators. |

### `[diagram_grid]`

The canvas area behind the table cards in the diagram view.

| Key | Default | Description |
|---|---|---|
| `background` | `"#F5F5F0"` | Canvas fill. |
| `line` | `"#D9D9D1"` | Repeating grid lines. |

### `[accent]`

A single accent colour from which all interactive-element colours are derived
(buttons, links, pins, selection highlights, check marks, slider grabs, etc.).

| Key | Default | Description |
|---|---|---|
| `colour` | `"#2C5796"` | The accent colour. Alpha variants (hover, active, selected, box selector, etc.) are generated automatically by the loader. |

### `[layout]`

Sizing and spacing values. All keys are optional; omitted keys use the defaults
listed below. Axis pairs use `horizontal: X, vertical: Y` syntax.

| Key | Type | Default | Description |
|---|---|---|---|
| `corner_rounding` | integer | `2` | Uniform rounding radius for windows, frames, popups, tabs, and sliders. |
| `scrollbar_size` | integer | `14` | Width of vertical scrollbars, height of horizontal scrollbars. |
| `grab_min_size` | integer | `12` | Minimum size of slider grabs and resize grips. |
| `item_spacing` | axis pair | `horizontal: 8, vertical: 6` | Gap between separate widgets. |
| `item_inner_spacing` | axis pair | `horizontal: 6, vertical: 4` | Gap within a composite widget (e.g. between a slider and its label). |
| `window_padding` | axis pair | `horizontal: 12, vertical: 12` | Padding between window edges and content. |
| `frame_padding` | axis pair | `horizontal: 6, vertical: 4` | Padding inside buttons, input fields, and frames. |
| `cell_padding` | axis pair | `horizontal: 6, vertical: 4` | Padding inside table cells. |
| `border_width` | integer | `1` | Border thickness for windows, child windows, and popups. |
| `frame_border_width` | integer | `1` | Border thickness for controls (buttons, inputs). |
| `tab_border_width` | integer | `1` | Border thickness for tabs. |

---

## Colour variants derived from accent

The loader expands the single `accent.colour` value into the full set of
interactive-element colours by varying opacity.  The theme author sets one
value; the loader handles the rest.

| Context | Alpha |
|---|---|
| Check marks, slider grabs, plot lines | 1.00 |
| Links, pins | 1.00 |
| Link hovered, pin hovered | 0.85 |
| Navigation cursor | 1.00 |
| Drag-and-drop target | 0.90 |
| Dragging preview overlay | 0.40 |
| Box selector fill | 0.30 |
| Box selector outline | 0.80 |
| Button background | 0.08 |
| Button hovered | 0.20 |
| Button active | 0.35 |
| Header / selection highlights | 0.12 |
| Header hovered | 0.25 |
| Header active | 0.40 |
| Separator hovered | 0.78 |
| Text selection | 0.25 |
| Table borders | 1.00 |

---

## Parser design (`theme_loader.odin`)

### State machine

```
read line
  → empty or whitespace only → skip
  → starts with "#" → skip (comment)
  → starts with "[" → set current_section, continue
  → contains "=" → parse key = value in current_section
  → anything else → skip (treated as malformed comment)
```

### Value parsing

For the value part after `=`:

1. **Strip leading/trailing whitespace.**
2. **If it starts with `"`** — read until the closing `"`.  This is a string.
   Handles `\"` inside the string as a literal quote character.
3. **If it starts with `#`** — read the hex digits (up to 8).
   Parse as `#RRGGBB` or `#RRGGBBAA`.
4. **If it contains `horizontal:` or `vertical:`** — split on commas,
   extract the named axis values.
5. **Otherwise** — parse as integer (`i64`).

### Default filling

After all sections are parsed, iterate over every field in the `ThemeData`
struct.  If a field was not assigned during parsing, overwrite it with the
hard-coded default from the specification tables above.

### Error handling

Missing `name` → default to `"Unnamed Theme"`.
Unparseable colour → log a warning, skip that key, keep the default.
Unknown section name → log a warning, ignore.
Unknown key within a known section → log a warning, ignore.

The loader never crashes.  An unparseable theme file returns a `ThemeData`
populated entirely with defaults.

---

## Integration

1. On startup, `discover_themes()` scans `themes/*.ssTheme`.
2. Each file is opened, parsed minimally to extract `name`.
   The result is a list of `{ display_name, filepath }` pairs.
3. The Theme menu in the menu bar is built from this list.
4. Selecting a menu item calls `load_theme(filepath)` which does a full
   parse and returns `ThemeData`.
5. `apply_theme(data)` writes all values to `ig.GetStyle()` and
   `imn.GetStyle()`, expanding accent variants as described above.

No theme data is hard-coded in the application binary.  Even the built-in
light and dark themes are delivered as `.ssTheme` files in `themes/`.
