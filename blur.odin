#+build !windows

package main

import sdl "vendor:sdl3"

// No-op on non-Windows. The window is still created with .TRANSPARENT, so a
// compositor (KDE/Hyprland window rules, macOS vibrancy) can blur it externally.
enable_os_blur :: proc(window: ^sdl.Window, backdrop_type: BackdropType) {
}
