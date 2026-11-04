{ pkgs ? import <nixpkgs> { } }:

let
  runtimeLibs = with pkgs; [
    libGL
    libxkbcommon
    wayland
    libX11
    libXcursor
    libXrandr
    libXinerama
    libXi
    libXext
  ];
in
pkgs.mkShell {
  packages = with pkgs; [
    odin
    ols
    gdb
    pkg-config
  ];

  buildInputs = runtimeLibs;

  shellHook = ''
    # Odin passes absolute project paths to the linker; Nix's wrapper rejects them otherwise
    export NIX_ENFORCE_PURITY=0
    export LIBRARY_PATH=${pkgs.lib.makeLibraryPath runtimeLibs}:$LIBRARY_PATH
    export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath runtimeLibs}:$LD_LIBRARY_PATH
    echo "Odin $(odin version) ready. Run ./build.sh"
    exec fish
  '';
}
