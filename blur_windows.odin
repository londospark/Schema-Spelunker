package main

import "core:fmt"
import windows "core:sys/windows"
import sdl "vendor:sdl3"

// Windows 11 DWM attribute values not present in the core:sys/windows bindings.
// DWMWA_SYSTEMBACKDROP_TYPE = 38 exists; REDIRECTIONBITMAP_ALPHA is the next one.
DWMWA_REDIRECTIONBITMAP_ALPHA :: 39

// DWM_BLURBEHIND (dwmapi.h) — also missing from core:sys/windows.
DWM_BB_ENABLE     :: 0x00000001
DWM_BB_BLURREGION :: 0x00000002

DWM_BLURBEHIND :: struct {
	dwFlags:              u32,
	fEnable:              windows.BOOL,
	hRgnBlur:             windows.HRGN,
	fTransitionOnMaximized: windows.BOOL,
}

foreign import gdi32 "system:Gdi32.lib"
@(default_calling_convention = "system")
foreign gdi32 {
	CreateRectRgn :: proc(x1, y1, x2, y2: i32) -> windows.HRGN ---
	DeleteObject  :: proc(hObject: windows.HGDIOBJ) -> windows.BOOL ---
}

foreign import dwmapi "system:Dwmapi.lib"
@(default_calling_convention = "system")
foreign dwmapi {
	DwmEnableBlurBehindWindow :: proc(hWnd: windows.HWND, pBlurBehind: ^DWM_BLURBEHIND) -> windows.HRESULT ---
}

// Ask the OS for a backdrop material (Windows 11 Mica/Acrylic via DWM) plus
// per-pixel alpha on the window surface. Call AFTER the GL context is current
// and the window is shown: DWM only respects the alpha channel once it knows
// the window has an alpha-capable pixel format.
//
// Three mechanisms, applied together:
//   - DWMWA_SYSTEMBACKDROP_TYPE: the theme's backdrop material (Mica/Acrylic/None).
//   - DWMWA_REDIRECTIONBITMAP_ALPHA (TRUE): DWM composites the redirection bitmap
//     that SwapBuffers writes using its (premultiplied) alpha (26100+). This is the
//     native fix — without it the GL surface is treated as fully opaque.
//   - DwmEnableBlurBehindWindow with an EMPTY region: the legacy idiom that makes
//     DWM alpha-composite GL windows on older builds. SDL3 applies it too early
//     (before the pixel format exists), so it must be re-applied here.
//
// Idempotent: safe to re-call on theme switches (the backdrop type changes).
enable_os_blur :: proc(window: ^sdl.Window, backdrop_type: BackdropType) {
	props := sdl.GetWindowProperties(window)
	hwnd_ptr := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
	if hwnd_ptr == nil {
		fmt.eprintfln("blur: failed to get HWND from SDL3 window")
		return
	}
	hwnd := windows.HWND(hwnd_ptr)

	// DWMSBT_*: 1=NONE, 2=MAINWINDOW (Mica), 3=TRANSIENTWINDOW (Acrylic)
	backdrop: i32 = 1
	switch backdrop_type {
	case .Mica:    backdrop = 2
	case .Acrylic: backdrop = 3
	case .None:    backdrop = 1
	}
	hr := windows.DwmSetWindowAttribute(
		hwnd,
		windows.DWORD(windows.DWMWINDOWATTRIBUTE.DWMWA_SYSTEMBACKDROP_TYPE),
		&backdrop,
		windows.DWORD(size_of(backdrop)),
	)
	if windows.FAILED(int(hr)) {
		fmt.eprintfln("blur: DwmSetWindowAttribute(SYSTEMBACKDROP_TYPE) failed (HRESULT 0x%08X)", u32(hr))
	}

	redir_alpha: windows.BOOL = true
	hr = windows.DwmSetWindowAttribute(
		hwnd,
		windows.DWORD(DWMWA_REDIRECTIONBITMAP_ALPHA),
		&redir_alpha,
		windows.DWORD(size_of(redir_alpha)),
	)
	if windows.FAILED(int(hr)) {
		fmt.eprintfln("blur: DwmSetWindowAttribute(REDIRECTIONBITMAP_ALPHA) failed (HRESULT 0x%08X) — needs Windows 11 24H2+", u32(hr))
	}

	region := CreateRectRgn(-1, -1, 0, 0)
	bb := DWM_BLURBEHIND{
		dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION,
		fEnable = true,
		hRgnBlur = region,
	}
	hr = DwmEnableBlurBehindWindow(hwnd, &bb)
	DeleteObject(windows.HGDIOBJ(region))
	if windows.FAILED(int(hr)) {
		fmt.eprintfln("blur: DwmEnableBlurBehindWindow failed (HRESULT 0x%08X)", u32(hr))
	}

	fmt.eprintfln("blur: backdrop=%v redirection-bitmap alpha enabled", backdrop_type)
}
