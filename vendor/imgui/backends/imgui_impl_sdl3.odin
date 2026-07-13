package imgui_impl_sdl3

// Odin bindings for ImGui's SDL3 platform backend.
// C++ implementation compiled into ../imgui.lib. Links against vendor:sdl3.

foreign import imguilib "../imgui.lib"

@(default_calling_convention = "c", link_prefix = "ImGui_ImplSDL3_")
foreign imguilib {
	InitForOpenGL :: proc(window: rawptr, sdl_gl_context: rawptr) -> bool ---
	InitForVulkan :: proc(window: rawptr) -> bool ---
	Shutdown      :: proc() ---
	NewFrame      :: proc() ---
	ProcessEvent  :: proc(event: rawptr) -> bool ---
}
