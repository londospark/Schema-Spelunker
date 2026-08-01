{
  description = "Schema Spelunker — SDL3 + ImGui + SQLite schema browser";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    odin-src = {
      url = "github:odin-lang/Odin/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, odin-src }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      llvmPackages = pkgs.llvmPackages_22;

      odin = llvmPackages.stdenv.mkDerivation {
        pname = "odin";
        version = "git-master";
        src = odin-src;

        env.LLVM_CONFIG = pkgs.lib.getExe' llvmPackages.llvm.dev "llvm-config";

        dontConfigure = true;

        buildFlags = [ "release" ];

        nativeBuildInputs = [
          pkgs.makeBinaryWrapper
          pkgs.which
          pkgs.binutils
        ];

        postPatch = ''
          # Don't ship the prebuilt vendored Raylib binaries. This project uses
          # SDL3, and the odin source still builds fine without them.
          rm -r vendor/raylib/{linux,macos,wasm,windows}

          patchShebangs --build build_odin.sh
          patchShebangs --build vendor/cgltf/src/build_cgltf.sh
          patchShebangs --build vendor/stb/src/build_stb.sh
          patchShebangs --build vendor/miniaudio/src/build_miniaudio.sh
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin
          cp odin $out/bin/odin

          mkdir -p $out/share
          cp -r {base,core,vendor,shared} $out/share

          wrapProgram $out/bin/odin \
            --prefix PATH : ${
              pkgs.lib.makeBinPath (
                with llvmPackages;
                [
                  bintools
                  llvm
                  clang
                  lld
                ]
              )
            } \
            --set-default ODIN_ROOT $out/share

          (cd "$out/share/vendor/cgltf/src" && ./build_cgltf.sh unix)
          (cd "$out/share/vendor/stb/src" && ./build_stb.sh unix)
          (cd "$out/share/vendor/miniaudio/src" && ./build_miniaudio.sh unix)

          runHook postInstall
        '';
      };

      runtimeLibs = with pkgs; [
        sdl3
        libGL
        llvmPackages.libcxx
        libxkbcommon
        wayland
        alsa-lib
        libX11
        libXext
        libXcursor
        libXi
        libXrandr
        libXrender
      ];
    in
    {
      packages.${system} = {
        odin = odin;
        default = odin;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          odin
          llvmPackages.clang
          pkgs.gcc
          pkgs.binutils
          pkgs.mold
        ] ++ runtimeLibs;

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;

        shellHook = ''
          echo "=== schema-spelunker devShell ==="
          echo "  odin:  $(odin version | head -n1)"
          echo "  clang: $(clang --version | head -n1)"
          echo "  mold:  $(mold --version)"
        '';
      };
    };
}
