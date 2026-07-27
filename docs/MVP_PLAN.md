# Schema Spelunker — MVP Plan

## What MVP means for this project

A minimum viable product means a user can open any SQLite database and
immediately understand its schema:
- See all tables and their columns (name, type, nullable, primary key)
- See foreign key relationships
- Navigate the schema visually or by list

The sections below are ordered by dependency — do the first, then the
second, etc.

---

## 1. Wire the "Open" button in the file dialog

Right now the Open button renders but does nothing.  The user must
double-click a file entry.  This is the single most obvious missing
piece.

**What to do**: give `ig.Button("Open")` a click handler that reads
`selected_file`, grabs its path from `items_in_folder`, and runs the
same open logic that the double-click path already uses.

That code lives at lines 396–405 of `show_file_dialog`.  Extract the
open-into-schema logic into a small helper (e.g.
`open_database(app_state, path)`) and call it from both the
double-click branch and the Open button branch.

---

## 2. Turn the schema window into a real schema viewer

The current `show_schema_window` (lines 467–485) is a bare listbox of
table names.  When a table is selected there is no detail panel.

**What to do**: below the table-list listbox, add a detail area that
shows the selected table's columns.  Each column row should display:
- column name
- data type
- NOT NULL indicator
- primary key indicator / composite key index

Use an ImGui `BeginTable` / `TableNextRow` / `TableNextColumn` block
with four columns (Name, Type, Nullable, PK).  This makes the schema
immediately useful.

**Later polish** (not MVP-blocking):
- Show foreign keys for the selected table in a second table below
- Show index info (via `index_list` / `index_info` when bound)

---

## 3. Resolve foreign-key `from_column` strings to `GlobalColumnIndex`

`ForeignKey.from_column` is currently a string placeholder (line 79).
The `from` field (GlobalColumnIndex) and `to` field are never
populated.  This means node-editor links and FK-aware schema display
don't work.

**What to do**: after all tables + columns are loaded inside
`extract_database_information`, add a second pass that walks every
foreign key, looks up the source column and target column by name, and
writes their `GlobalColumnIndex` values into `fk.from` and `fk.to`.

Once resolved the temporary `from_column` string field can be removed
from the struct.

---

## 4. Draw FK links in the node editor

The node editor currently shows tables as nodes with column names, but
has no links between them.  After FK resolution (step 3) the data
exists to draw edges.

**What to do**: after the node-render loop (lines 451–461), add a
second loop over `schema.foreign_keys` that calls
`imn.Link(link_id, from_attr_id, to_attr_id)`.  Each column that
participates in a foreign key needs a pin attribute
(`imn.BeginInputAttribute` / `imn.BeginOutputAttribute`) around its
label so ImNodes has something to anchor the link to.

The result is a working ER diagram: tables as labelled boxes, lines
between related columns.

---

## 5. Validate schema extractor errors and surface them to the user

Currently if `os.open` or `extract_database_information` fails, the
error is either silently swallowed (`or_continue`) or printed to
stdout only.

**What to do**: store a `last_error: string` field (arena-allocated)
on `AppState`.  When the file dialog or schema extraction fails, write
the error message there.  Show it as an ImGui notification or status
bar entry.  This turns silent failures into visible ones.

Also bind `sqlite3_errmsg` (listed as `[P2]` in TODO) so the error
message actually says *why* the database failed to open or query.

---

## 6. Theme polish

Not MVP-blocking, but the Paper & Ink theme has some easily-fixed
rough edges that would make a better first impression:

- Remove the dead `imn.StyleColorsLight()` / `imn.StyleColorsDark()`
  calls (every color is immediately overwritten).
- Factor the ~15 identical Blueprint Blue accent assignments into a
  shared section so they aren't duplicated across both theme branches.
- Set the missing color slots listed below so the theme is complete:

  | Slot | Name |
  |------|------|
  | 19   | `CheckboxSelectedBg` |
  | 31–33 | `ResizeGrip*` |
  | 34   | `InputTextCursor` |
  | 38   | `TabSelectedOverline` |
  | 41   | `TabDimmedSelectedOverline` |
  | 45   | `PlotLinesHovered` |
  | 47   | `PlotHistogramHovered` |
  | 53   | `TextLink` |
  | 55   | `TreeLines` |
  | 57   | `DragDropTargetBg` |
  | 58   | `UnsavedMarker` |
  | 60–61 | `NavWindowingHighlight`, `NavWindowingDimBg` |

---

## File organisation note

The whole application lives in one file (`main.odin`, 811 lines,
package main).  This is fine — you've said you agree with gingerBill
and Casey Muratori that large files are not a problem.  The single
file stays.  The only structural change worth considering is pulling
the vendored ImGui bindings out of the way (they are already in
`vendor/`), which is done.

---

## What MVP does NOT include

These are explicitly deferred until after the MVP is usable:

- Schema snapshot file format (save/load without a live DB)
- CLI `dump` command
- Keyboard shortcuts in the file dialog
- Directory sorting (dirs before files, alphabetical)
- Sub-diagram view (1–2 degrees of separation)
- String interning for column types
- `referenced_by` reverse FK index
- Tracy profiling integration
- Frame pacing improvements (throttle-up, multi-monitor)
- Batch SQLite PRAGMA queries
