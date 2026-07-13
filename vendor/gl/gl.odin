package gl

// Minimal OpenGL 1.1 bindings for clearing the framebuffer.
// Uses system OpenGL library (opengl32.lib on Windows, libGL on Linux, OpenGL.framework on macOS).

when ODIN_OS == .Windows {
	foreign import lib "system:opengl32.lib"
} else when ODIN_OS == .Linux {
	foreign import lib "system:GL"
} else when ODIN_OS == .Darwin {
	foreign import lib "system:OpenGL.framework"
}

@(default_calling_convention = "c", link_prefix = "gl")
foreign lib {
	Clear      :: proc(mask: u32) ---
	ClearColor :: proc(r, g, b, a: f32) ---
}

GL_COLOR_BUFFER_BIT :: 0x00004000
