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
	Clear          :: proc(mask: u32) ---
	ClearColor     :: proc(r, g, b, a: f32) ---
	Finish         :: proc() ---
	GetString      :: proc(name: u32) -> cstring ---
	GenTextures    :: proc(n: i32, textures: [^]u32) ---
	DeleteTextures :: proc(n: i32, textures: [^]u32) ---
	BindTexture    :: proc(target: u32, texture: u32) ---
	TexParameteri  :: proc(target: u32, pname: u32, param: i32) ---
	PixelStorei    :: proc(pname: u32, param: i32) ---
	TexImage2D     :: proc(target: u32, level: i32, internalformat: i32, width, height: i32, border: i32, format, type: u32, pixels: rawptr) ---
}

GL_COLOR_BUFFER_BIT :: 0x00004000
GL_VENDOR           :: 0x1F00
GL_RENDERER         :: 0x1F01
GL_VERSION          :: 0x1F02

GL_TEXTURE_2D        :: 0x0DE1
GL_TEXTURE_WRAP_S    :: 0x2802
GL_TEXTURE_WRAP_T    :: 0x2803
GL_TEXTURE_MIN_FILTER :: 0x2801
GL_TEXTURE_MAG_FILTER :: 0x2800
GL_LINEAR            :: 0x2601
GL_CLAMP_TO_EDGE     :: 0x812F
GL_RGBA              :: 0x1908
GL_RGBA8             :: 0x8058
GL_UNSIGNED_BYTE     :: 0x1401
GL_TEXTURE0          :: 0x84C0
GL_UNPACK_ALIGNMENT  :: 0x0CF5
