package imgui_impl_opengl3

// Odin bindings for ImGui's OpenGL3 render backend.
// C++ implementation compiled into ../../imgui.lib.

foreign import imguilib "../../imgui.lib"

@(default_calling_convention = "c", link_prefix = "ImGui_ImplOpenGL3_")
foreign imguilib {
	Init      :: proc(glsl_version: cstring) -> bool ---
	Shutdown  :: proc() ---
	NewFrame  :: proc() ---
	RenderDrawData :: proc(draw_data: rawptr) ---
}
