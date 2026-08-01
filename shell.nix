{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ odin ];
  
  buildInputs = with pkgs; [
    clang
    libGL
    libxkbcommon
    wayland
    alsa-lib
    raylib
    sdl3
    
    # Often required as fallback dependencies by the vendored Raylib
    libX11
    libXrandr
    libXi
    libXcursor
    libcxx
  ];

  # This explicitly maps the system libraries so Odin's vendored raylib can see them
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
    raylib
    libGL
    libxkbcommon
    wayland
    alsa-lib
    libX11
    libXrandr
    libXi
    libXcursor
    libcxx
    sdl3
  ]);
}
