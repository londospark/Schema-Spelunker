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
- CLI mode (`schema_spelunker dump something.db`) for scripting and CI

## Philosophy

Handmade software in the spirit of Casey Muratori, Ryan Fleury, and
gingerBill: minimal dependencies, own the stack where it counts, no
framework magic. The project uses Odin for its no-nonsense approach to
systems programming and its excellent FFI for binding C libraries like
SQLite.

## Current status

Early development. SQLite3 bindings exist (`sqlite3/` package), schema
introspection via `PRAGMA table_info` works on the command line. GUI is
the next frontier.

---

## GUI framework evaluation

The GUI needs to render entity-relationship diagrams: labelled rectangular
nodes (tables) connected by edges (foreign keys), with zoom/pan selection
and ideally interactive node-graph editing (drag to rearrange, click to
inspect).

**Hard requirement:** GPU-accelerated rendering, locked at the display's
native refresh rate, on everything from a laptop RTX 4070 (1600p, 240 Hz)
to a desktop RTX 5080 (5K2K ultrawide, 165 Hz). RadDBG proves that a
handmade tool can be instant and responsive — and we're doing a lot less
work per frame than a debugger. Diagram panning, zooming, and selection
must never stutter. This rules out any CPU-only rendering approach.

Here are the options being considered.

### Dear ImGui (candidate for prototype)

**Odin bindings:** `vendor:imgui` ships with Odin.

A battle-tested immediate-mode GUI library, widely used in game engines
and tooling.

**Pros:**
- Immediate mode is simple to iterate with — no retained widget trees
- **ImNodes** extension provides node-graph editing out of the box
  (drag nodes, connect ports, zoom/pan) — this maps directly to ER
  diagram interaction
- Well-known, well-documented, large community
- Easy to prototype: you can have a window on screen in ~50 lines
- Odin bindings are already in the vendor directory, no extra work
- Fully supported across Windows, Linux, macOS

**Cons:**
- The "ImGui look" is distinctive — it looks like a developer tool,
  not a polished end-user application, though custom styling helps
- Not a full framework: no built-in windowing, input, or GPU backend.
  You need an integration layer (SDL, GLFW, or a custom one)
- Immediate mode can become unwieldy for very complex UIs, though
  a schema diagram tool is unlikely to hit that ceiling
- No built-in 2D rendering primitives — drawing custom shapes means
  using the draw list API, which is workable but not a canvas

### Raylib

**Odin bindings:** `vendor:raylib` ships with Odin.

A full multimedia framework: windowing, input, audio, 2D/3D rendering,
fonts, all in one library.

**Pros:**
- All-in-one: no stitching libraries together, just `import raylib`
- Excellent 2D rendering primitives — `DrawRectangle`, `DrawLine`,
  `DrawText` map directly to drawing ER diagrams
- `raygui` (included) provides basic UI controls and can be styled
- Much smaller and simpler than a full game engine, fits the
  handmade ethos reasonably well
- ImGui can be embedded via `rlImGui` if you want both

**Cons:**
- Not immediate-mode for UI (retained-style raygui), which means more
  state management for complex interactions
- No built-in node-graph editor — would need to build diagram
  interaction from scratch (hit-testing, dragging, zoom-to-point)
- More opinionated than ImGui — wants to own the game loop, which
  may conflict with your control style
- Still a dependency with its own conventions and quirks

### Microui

**Odin bindings:** `vendor:microui` ships with Odin.

A minimal, single-header-C-file immediate-mode UI library by r-lyeh.

**Pros:**
- **Tiny** — truly minimal, easy to understand the entire codebase
- Fits the handmade philosophy perfectly
- Already vendored with Odin, zero integration fuss
- Immediate-mode like ImGui but far less code

**Cons:**
- **No 2D rendering** — microui gives you UI panels, buttons,
  sliders, text, but you provide the drawing backend yourself
  (draw rectangle, draw text, etc.)
- **No node-graph support** — no ImNodes equivalent; would need to
  build ER diagram interaction entirely by hand
- Very small community and fewer examples to learn from
- The bare-minimum approach means you'll end up writing a lot of
  infrastructure that other options provide for free
- Less suited for a complex diagram viewer out of the box

### Custom renderer (long-term)

Writing the UI and rendering from scratch on top of a GPU API (Vulkan,
Direct3D 12, Metal) or a thin abstraction layer.

**Pros:**
- **Maximum control** — every pixel, every frame, every interaction
- Pure handmade — no external UI code, full ownership
- Can be tailored exactly to the ER diagram use case, nothing more
- Significant learning experience in low-level rendering
- No dependency churn or framework-breaking updates

**Cons:**
- **Massive effort** — windowing, input, text rendering, font atlas,
  layout, hit-testing, graph layout algorithm, GPU resource management
- Years of development to reach parity with even a basic GUI library
- Odin's GPU bindings (`vendor:DirectX`, `vendor:Vulkan`, `vendor:gpu`)
  are available but lower-level than a full framework
- Risk of getting bogged down in infrastructure instead of the
  actual schema exploration problem

### 240 Hz performance note

For a 2D ER diagram tool with at most a few hundred nodes and edges, the
GPU is never the bottleneck. Any framework that submits draw calls to the
GPU (ImGui, Raylib, or a custom backend for Microui) can trivially hit
240 FPS on a 4070 mobile. The real limiting factors are:

- **CPU-side draw submission overhead** — ImGui batches everything into
  one draw list per frame; Raylib does its own batching. Both are
  negligible at this complexity level.
- **Graph layout algorithm** — if layout is computed on the fly during
  pan/zoom, that's CPU work and could stutter. Pre-computed or
  incremental layout solves this.
- **Font rendering** — a few hundred text labels is nothing for a GPU.

In short: all four options *can* hit 240 Hz. The choice between them
comes down to development speed and philosophical fit, not pixel
throughput.

### Summary

| Framework | Prototype speed | Diagram capability | Handmade fit | 240 Hz | Long-term polish |
|---|---|---|---|---|---|
| **Dear ImGui** | Fastest | ImNodes gives ER diagrams today | Moderate | ✅ Trivial | Good with custom styling |
| **Raylib** | Fast | Needs manual diagram interaction | Low-moderate | ✅ Trivial | Good (full framework) |
| **Microui** | Slow | Everything by hand | Best | ✅ With GPU backend | Excellent (you own it) |
| **Custom** | Very slow | Total control | Ultimate | ✅ Guaranteed | Ultimate (but huge effort) |

**Current thinking:** Dear ImGui for a quick prototype (ImNodes makes the
ER diagram interaction almost free), then evaluate whether to stay with it
for the long term or migrate toward something more handmade once the
interaction model is proven.
