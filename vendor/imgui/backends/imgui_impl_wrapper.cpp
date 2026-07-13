// extern "C" wrappers for ImGui backends.
// Forces C linkage via IMGUI_IMPL_API so Odin can link the functions.
// Compiles both backends in one translation unit.

#define IMGUI_IMPL_API extern "C"
#include "imgui_impl_sdl3.cpp"
#include "imgui_impl_opengl3.cpp"
