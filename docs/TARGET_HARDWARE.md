# Target Development Hardware

Research into what machines developers actually use in 2025-2026, so we know
what to target and what to test against. Last updated 2026-08-01.

## Why this matters

Schema Spelunker is a lightweight tool. Startup and interaction performance
matters most on the *weakest* plausible machine a user runs it on — not on the
beefy dev box where we develop. Knowing the realistic floor lets us set
sensible performance targets.

## What cheap/corporate shops actually issue

The overwhelming pattern in corporate fleets (2023-2026 era, still in service):

- **Dell Latitude 5440 / 5450** (the "5000 series" workhorse)
  - CPU: Intel Core i5-1335U (or i7-1355U / i7-1365U vPro for "developers")
  - RAM: 8-16GB (16GB increasingly standard, 8GB still common at the cheap end)
  - Storage: 250-500GB SSD (often just 256GB!)
  - Display: 14" FHD (1920x1080) IPS
  - iGPU: Intel Iris Xe (U-series = lower power, no dGPU in most units)
- **Lenovo ThinkPad E14 Gen 5 / Gen 6**
  - CPU: Intel Core i5-1335U (13th gen), or AMD Ryzen 5 7530U variants
  - RAM: 8-16GB, Storage: 256-512GB SSD, 14" FHD
  - The E-series is literally Lenovo's "budget corporate" line
- **HP ProBook / EliteBook (low end)**
  - Similar tier: i5-13xxxU or Ryzen 5 7000-series, 8-16GB, 256-512GB SSD
- **Lenovo ThinkPad X1 Carbon** (the "premium" default, still 13th-gen Intel
  i5/i7 U-series in the current wave) — what management and many devs get

### Key takeaway

The typical cheap corporate dev machine is:

```
CPU:    Intel Core i5 U-series (2 P-cores + 8 E-cores, ~15W TDP)
RAM:    8-16GB (often 16GB, but 8GB exists)
SSD:    256-512GB NVMe
GPU:    Intel Iris Xe iGPU (U-series = 96 or 80 EU)
Display: 14" 1920x1080
OS:     Windows 11 Pro
```

These are **single-digit-core U-series CPUs** (low power, thermally limited).
They are *slower per-core* than a desktop i5/i7 K-series and much slower than
a 32-core workstation. They have no dGPU. This is a meaningful performance
floor: roughly 2-4x slower than the dev desktop in single-threaded work, and
the iGPU is Intel Iris Xe-class (or similar AMD iGPU on Ryzen units).

## Where the Steam Deck fits

Steam Deck (LCD/OLED): AMD Van Gogh APU, 4 cores / 8 threads Zen 2 @ up to
3.5GHz, 16GB LPDDR5, RDNA2 8CU @ 1.0-1.6GHz, 1280x800. Runs Linux (SteamOS)
with Mesa drivers (radeonsi for GL, RADV for Vulkan).

- **CPU**: 4C/8T Zen 2 is comparable to a corp i5-U in multithread, slower in
  single-thread than a modern i5 but not by much.
- **GPU**: RDNA2 8CU is *much* faster than Intel Iris Xe for shader work, and
  Mesa's GL driver has near-zero per-context dispatch overhead (like the
  laptop iGPU, not like the desktop NVIDIA ICD).
- **RAM**: 16GB, but shared with GPU.
- **Display**: 1280x800 (much smaller than the 1600x900 window the app
  defaults to — the app window will need to fit 1280x800 or be resized).

So the Steam Deck is a **good low-end proxy** but with a twist: its GPU is
stronger than a corp laptop's iGPU, while its CPU is mid-range. It tests the
"old-ish APU + Linux + Mesa" path more than the "weak Windows laptop" path.

## Performance implications for Schema Spelunker

1. **Startup**: on a U-series iGPU laptop, expect the laptop-iGPU profile
   (~200-250ms total init, near-zero GL-backend cost). The prime-swap +
   warm-up fix handles the worst case; there is nothing to do here.
2. **The 1600x900 default window** is too big for the Steam Deck (1280x800)
   and for 1366x768 budget laptops. Consider a smaller default or
   `SDL_WINDOW_RESIZABLE` + clamping to the display size.
3. **Font/text rendering** is the main per-frame CPU cost (ImGui text
   vertices). On a 4C/8T U-series CPU at 60fps, keep draw-call and vertex
   counts sane; avoid rebuilding text every frame.
4. **iGPU vs dGPU**: on Windows laptops the app will default to the **iGPU**
   (Intel Iris Xe / AMD Radeon iGPU), not the GeForce/RTX dGPU. Optimize for
   the iGPU, treat the dGPU as free headroom.
5. **Avoid assumptions about high core counts**: the app should stay
   single-threaded-friendly. A 4-core U-series CPU at ~2-3GHz boost is the
   floor; don't do anything per-frame that's O(N^2) over schema size.

## Reference: our four test machines

| Machine | CPU | RAM | GPU path | GL driver | Startup (current) |
|---|---|---|---|---|---|
| Dev desktop | (32-core) | 128GB | NVIDIA RTX 5080 | NVIDIA ICD | ~500-1600ms |
| Desktop (RDP) | (32-core) | 128GB | NVIDIA RTX 5080 | NVIDIA ICD + encode | ~480ms |
| Laptop | i7-14650HX (24t) | 64GB | Intel iGPU (default) | Intel | ~220ms |
| Steam Deck (1440p) | Van Gogh 4C/8T | 16GB | RDNA2 8CU | Mesa | **144.7ms** |

The desktop's slow startup is NVIDIA-driver-specific; both the laptop and the
Steam Deck are fast (lightweight driver dispatch). The Steam Deck at 1440p was
the fastest of all four — rendering resolution is a non-issue for this 2D
workload; the CPU is the constraint on weak machines, not the GPU.

## Sources / notes

- Model/spec data from public comparisons of the Dell Latitude 5440, Lenovo
  ThinkPad E14 Gen 5, and related 2023-2025 enterprise laptops (laptop
  comparison sites, retailer listings).
- Corporate-fleet pattern (Latitude 5000 / ThinkPad E / ProBook, i5-U, 8-16GB,
  256-512GB SSD) is widely reported across enterprise IT reviews.
- These are 2023-2026-era units; older fleets still run 8th-11th gen i5/i7
  (even weaker). The Steam Deck test gives a concrete modern low-end data point.
