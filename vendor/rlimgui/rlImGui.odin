package rlimgui

import imgui "../imgui"
import rl "vendor:raylib"

// All compiled into the same .lib as imgui + imnodes
when ODIN_OS == .Windows {
	foreign import lib "../imgui/imgui.lib"
} else {
	foreign import lib "../imgui/imgui.a"
}

// imgui_impl_raylib backend (lower-level)
@(link_prefix = "ImGui_ImplRaylib_")
foreign lib {
	Init          :: proc(darkTheme: bool) ---
	BuildFontAtlas :: proc() ---
	Shutdown       :: proc() ---
	NewFrame       :: proc() ---
	RenderDrawData :: proc(draw_data: ^imgui.DrawData) ---
	ProcessEvents  :: proc() ---
}

// rlImGui high-level convenience API
foreign lib {
	rlImGuiSetup        :: proc(darkTheme: bool) ---
	rlImGuiBegin        :: proc() ---
	rlImGuiEnd          :: proc() ---
	rlImGuiShutdown     :: proc() ---
	rlImGuiBeginInitImGui :: proc() ---
	rlImGuiEndInitImGui :: proc() ---
	rlImGuiReloadFonts  :: proc() ---
	rlImGuiBeginDelta   :: proc(deltaTime: f32) ---
	rlImGuiImage        :: proc(image: ^rl.Texture) ---
	rlImGuiImageSize    :: proc(image: ^rl.Texture, width: i32, height: i32) ---
	rlImGuiImageRect    :: proc(image: ^rl.Texture, destWidht: i32, destHeight: i32, souruceRect: rl.Rectangle) ---
	rlImGuiImageRenderTexture     :: proc(image: ^rl.Texture) ---
	rlImGuiImageRenderTextureFit  :: proc(image: ^rl.Texture, center: bool) ---
	rlImGuiImageButton            :: proc(name: cstring, image: ^rl.Texture) -> bool ---
	rlImGuiImageButtonSize        :: proc(name: cstring, image: ^rl.Texture, size: imgui.Vec2) -> bool ---
}
