{
  description = "Odin from Git";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Fetch the Odin source directly from GitHub
    odin-src = {
      url = "github:odin-lang/Odin/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, odin-src }:
    let
      system = "x86_64-linux"; # Or "aarch64-darwin" for Mac
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.odin = pkgs.stdenv.mkDerivation {
        pname = "odin";
        version = "git-master";
        src = odin-src;

        nativeBuildInputs = [
          pkgs.clang
          pkgs.llvmPackages_22.libllvm # Adjust LLVM version as needed (17-22 supported)
          pkgs.git
          pkgs.python3
        ];

        buildPhase = ''
          # Odin requires a release build
          runHook preBuild
          make release-native
          runHook postBuild
        '';

        installPhase = ''
          mkdir -p $out/bin
          cp odin $out/bin/odin
        '';
      };
    };
}   