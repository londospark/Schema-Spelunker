package main

// Runtime PNG icon loading: decode with the Odin vendor stb_image bindings and
// upload to an OpenGL texture for ImageButton. Cross-platform — vendor:stb/image
// links prebuilt libs for Windows/Linux/macOS.

import "core:os"
import c "core:c"
import stbi "vendor:stb/image"
import ig "vendor/imgui"
import gl "vendor/gl"

// Load a PNG file into a GL texture usable by ig.ImageButton.
// Returns a zero TextureRef (and false) on any failure.
load_icon_texture :: proc(path: string) -> (tex: ig.TextureRef, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != os.ERROR_NONE {
		return {}, false
	}
	defer delete(data)

	w, h, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil {
		return {}, false
	}
	defer stbi.image_free(pixels)

	if w <= 0 || h <= 0 {
		return {}, false
	}

	id: u32
	gl.GenTextures(1, &id)
	if id == 0 {
		return {}, false
	}

	gl.BindTexture(gl.GL_TEXTURE_2D, id)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE)
	gl.TexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE)
	gl.PixelStorei(gl.GL_UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels)

	return ig.TextureRef{_TexID = ig.TextureID(u64(id))}, true
}

destroy_icon_texture :: proc(tex: ig.TextureRef) {
	id := u32(tex._TexID)
	if id != 0 {
		gl.DeleteTextures(1, &id)
	}
}
