# Startup Performance Investigation

Investigation of the ~1s black-screen delay at application launch, plus the
overall slow startup on the desktop. Last updated 2026-08-01.

## TL;DR

- The visible ~1s black screen was caused by **deferred GPU work** (swap-chain
  setup / driver init) triggered by the first `SwapWindow`. The fix: fire the
  first swap early (the "prime swap"), overlap it with ImGui init, and absorb
  the remaining wait in a warm-up frame's `glFinish`. Window stays `.HIDDEN`
  until that's done.
- **Not** shader compilation, not font upload, not ImGui init (all <10ms).
- A second, separate cost: `SDL_CreateWindow` with the `.OPENGL` flag costs
  ~190-230ms on the desktop for SDL's pixel-format setup. Plain windows create
  in 5-7ms. This is unavoidable from app code (SDL3 requires the flag for GL).
- The slowdown is **machine/display-path dependent** and is worst over RDP
  (RemoteFX/Indirect Display encode pipeline init). The local console is
  faster but still slower than a laptop with a direct physical display.

---

## Symptom

On launch, the window stayed black for ~1s before the first frame appeared.
On the desktop (RTX 5080) this was reproducible. On a laptop (i7-14650HX,
RTX 4070, 64GB) it was not observed.

Early misdiagnosis blamed shader compilation (why the GL context was bumped
from 3.3 to 4.5 at one point — since reverted). Instrumentation proved that
wrong.

## How the problem was diagnosed

Timing instrumentation was added around each init phase with a
`gl.Finish()` checkpoint after each, so the *first* `glFinish` that blocks
reveals where the deferred GPU work originates.

Initial breakdown (desktop, over RDP):

```
[gpudbg] NewFrame+glFinish:       6.2ms   <- shader compile, fine
[gpudbg] Render+glFinish:         0.1ms   <- ImGui layout, fine
[gpudbg] RenderDrawData+glFinish: 1.2ms   <- texture upload + draw, fine
[gpudbg] SwapWindow+glFinish:  1089.3ms   <- THE PROBLEM
```

Splitting `SwapWindow` from `glFinish`:

```
[prime] SwapWindow: 0.1ms  glFinish: 1069.5ms
```

So `SwapWindow` itself returns instantly — it *submits* async GPU work
(swap-chain buffer allocation, DWM registration, and over RDP the RemoteFX
encode pipeline init) that a later `glFinish` blocks on.

## The fix

1. **Prime swap**: right after `GL_MakeCurrent`, do
   `gl.Clear(GL_COLOR_BUFFER_BIT)` + `GL_SwapWindow` and **do not** call
   `glFinish` immediately. The async work starts cooking while we continue.
2. **ImGui init** proceeds (~1-18ms of CPU work) while the GPU is busy.
3. **Warm-up frame**: render a minimal ImGui frame (menu bar only), swap,
   then `glFinish`. This absorbs whatever async work is still outstanding.
   After this, the swap chain is warm and every subsequent swap is ~3ms.
4. Window is created with `.HIDDEN` and shown with `ShowWindow()` only after
   the warm-up, so the black/empty window is never visible.

Result: the first real frame renders in ~3ms and appears instantly.

## What was tried and rejected

- `CreateDeviceObjects()` warm-up before the main loop — did not help; the
  stall was in swap, not in device-object creation.
- Moving `glFinish` earlier — just moved the same wall-clock cost around.
- Shader pre-compilation to binary (user suggestion) — impractical: driver/
  vendor-specific formats; and moot, since shader compile was never the cost.
- Hiding the stall (hidden window only) — user rejected: launch was still slow.

## Residual costs (current state)

Even with the stall fixed, two startup costs remain:

### 1. `SDL_CreateWindow` with `.OPENGL` flag: ~190-230ms

Measured on the desktop:

```
[win] CreateWindow(OPENGL 3.3): 196.0ms
[probe] plain window #1: 4.9ms  #2: 4.0ms
```

- A plain (non-GL) window creates in ~5ms. Adding the `.OPENGL` flag adds
  ~190ms of SDL pixel-format enumeration/setup.
- GL version does not matter: 3.3 and 4.5 both ~196ms.
- Attribute timing does not matter: setting attributes before `CreateWindow`
  vs right before `GL_CreateContext` — same ~200-230ms.
- `CreateWindowWithProperties` maps to the same internal path; no win.
- SDL3 refuses GL on a window created without the flag ("The specified window
  isn't an OpenGL window"), so there is no way to defer the cost from app code.

### 2. Async swap/GPU work landing in `ImGui+backends init`: 0-600ms

The prime swap's deferred work gets flushed by the first real GL call inside
backend init (`sdl_impl.InitForOpenGL` / `gl_impl.Init`). This bucket varies
wildly:

- Over RDP: ~18ms
- Local console: 167-973ms across runs

This is the same underlying cost as the original stall, just attributed to a
different phase depending on display path. The warm-up frame absorbs whatever
remains (observed 3-33ms).

## Machine / display-path dependence

| Metric | Laptop (RTX 4070, physical panel) | Desktop (RTX 5080, RDP) | Desktop (RTX 5080, local console) |
|---|---|---|---|
| CreateWindow (OPENGL) | 120.6ms | 357.7ms | ~195ms |
| Plain window | — | — | 5-7ms |
| ImGui+backends init | 0.6ms | 17.8ms | 167-973ms |
| Warm-up frame | 18.8ms | 33.6ms | 2.8-32.5ms |
| Total init | 219.1ms | 479.2ms | 478-1283ms |

### Displays observed

- **Laptop**: `TL160ADMP11-0` (built-in panel), 2560x1600. One display.
- **Desktop via RDP**: `Generic PnP Monitor` 2560x1600 (the RemoteFX virtual
  display). One display. Only the virtual display is visible to SDL; the
  physical displays are not enumerated.
- **Desktop local console**: two physical displays — `LG HDR 4K` 3840x2160 and
  `DELL P2414H` 1920x1080. The desktop also has a `SudoMaker Virtual Display
  Adapter` (1920x1080) and `Microsoft Remote Display Adapter` installed.

### Why RDP is slow

The first present over RDP triggers RemoteFX / Indirect Display **encode
pipeline initialization** (server-side encoding setup, transport buffers).
That is one-time per process/window and explains the 300-1000ms first-swap
cost over RDP. It also explains why the user saw the problem locally too —
the local console still goes through the same driver's present path with its
own one-time setup cost.

## Why the laptop is fast — it was using the iGPU

The laptop (i7-14650HX, RTX 4070) does not actually use the GeForce for this
app. Evidence:

| Measurement | Laptop (Intel iGPU) | Desktop (NVIDIA RTX 5080) |
|---|---|---|
| `gl_impl.Init` + backend init | **0.6ms** | 306-1527ms |
| `GL_CreateContext` | **18.8ms** | 2.7-3.4ms |

The 0.6ms vs 306-1527ms gap in the ImGui/GL-backend init is the signature of
driver type. The NVIDIA ICD has heavy one-time per-context dispatch cost
(extension enumeration + first real GL calls after context creation). Intel's
iGPU driver has almost none. Slower context creation on the laptop (18.8ms vs
~3ms) is also classic iGPU behavior.

**Routing mechanism**: On Windows laptops, which GPU a generic OpenGL app gets
is decided by Windows graphics settings + the NVIDIA driver (Optimus), *not*
by SDL or the app. The default for an app without an explicit "High
performance" assignment is the **iGPU** (power-saving default). There is no
SDL hint to force the dGPU; it's controlled by:
1. `Settings → System → Display → Graphics` (per-app preference)
2. NVIDIA Control Panel (per-app GPU selection)
3. Driver default (iGPU)

So the iGPU is the realistic baseline for Windows laptops. The desktop's
NVIDIA ICD overhead (300-1500ms in `gl_impl.Init`) is driver-side and not
reducible from app code.

## The `gl_impl.Init` cost is CPU-side, not GPU

A `glFinish` checkpoint right after `ImGui_ImplOpenGL3_Init` returns in
**0.1ms** — the GPU is already idle. So the 300-1500ms is **CPU-side driver
dispatch** inside Init (the `GL_NUM_EXTENSIONS` enumeration loop at
`imgui_impl_opengl3.cpp:1079-1086` plus the first real GL round-trip after
context creation), not async GPU work. It is a one-time per-context NVIDIA
driver cost.

## Conclusions / guidance

- Do **not** chase the remaining ~190ms `CreateWindow` cost from app code —
  it's inside SDL3's OpenGL window path. A fix would require patching SDL3
  or swapping its Windows video driver, neither of which is worth it here.
- The prime-swap + warm-up pattern is correct and should be kept. It is
  harmless on fast machines (~3ms warm-up) and eliminates the visible stall
  on slow ones.
- Accept that absolute startup time is display-path dependent: ~220ms laptop
  (iGPU), ~480-900ms desktop (NVIDIA ICD). The window is never visibly black
  thanks to `.HIDDEN`.
- The `[gl]` instrumentation line reports `GL_VENDOR`/`GL_RENDERER` so any
  machine's actual GPU routing is visible at a glance.
- **Steam Deck result**: total init **144.7ms** at 1440p — the fastest of all
  four machines tested, via Mesa (radeonsi/RADV). Confirms the desktop's slow
  startup is NVIDIA-ICD-specific, not our code.

## Status: investigation on ice

The black-screen fix is in and validated across four machines (desktop local,
desktop RDP, laptop iGPU, Steam Deck). No further startup work is planned
unless a new machine shows a problem.

**Final instrumentation state** (kept deliberately light):
- `[hw]` — one line, platform/cores/RAM/SIMD (harmless, useful forever)
- `[gl]` — one line, `GL_VENDOR`/`GL_RENDERER`/`GL_VERSION` (reveals iGPU vs
  dGPU routing and Mesa vs NVIDIA at a glance)
- All other startup timers (`[win]`, `[probe]`, `[disp]`, `[ctx]`, `[init]`,
  `[warmup]`, `[startup]`) were stripped once the investigation concluded.

## Repo state

- Commit `200004f` ("wip: instrument startup timing; prime swap + warm-up
  frame to diagnose first-frame stall") pushed to `origin/main` contains the
  fix plus startup-phase instrumentation.
- Commit `89d1b5e` ("docs: add startup performance investigation notes;
  revert GL to 3.3 core") added this file and reverted the GL context to 3.3.
- Commit `b5aa426` ("feat: add hardware profile + GL vendor/renderer
  diagnostics, fine-grained init timing") added the `[hw]`, `[gl]` lines and
  the per-phase `[init]` breakdown.
- Commit `<next>` strips the verbose instrumentation, keeping `[hw]` + `[gl]`.
- The GL context is 3.3 core (the 4.5 experiment was reverted; it made no
  measurable difference).
- The prime-swap + warm-up + hidden-window flow and the `.HIDDEN`/`ShowWindow`
  pair are the final fix and stay in place.

## Files touched during the investigation

- `main.odin` — startup flow, prime swap, warm-up frame, instrumentation.
- `vendor/gl/gl.odin` — added `Finish`, `GetString` bindings and
  `GL_VENDOR`/`GL_RENDERER`/`GL_VERSION` constants.
- `vendor/imgui/backends/imgui_impl_opengl3.h` — wrapped `CreateDeviceObjects`/
  `DestroyDeviceObjects` in `extern "C"` (fixes linkage).
- `vendor/imgui/backends/opengl3/imgui_impl_opengl3.odin` — exposed
  `CreateDeviceObjects` binding.
- `build.bat` — default build now `-o:speed`.
