package imgui_impl_opengl3

// Odin bindings for ImGui's OpenGL3 render backend.
// C++ implementation compiled into ../../imgui.lib.

when ODIN_OS == .Windows {
	foreign import imguilib "../../imgui.lib"
} else {
	foreign import imguilib "../../imgui.a"
}

@(default_calling_convention = "c", link_prefix = "ImGui_ImplOpenGL3_")
foreign imguilib {
	Init      :: proc(glsl_version: cstring) -> bool ---
	Shutdown  :: proc() ---
	NewFrame  :: proc() ---
	RenderDrawData :: proc(draw_data: rawptr) ---
}
