{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      outputsWithoutSystem = { };
      outputsWithSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          lib = pkgs.lib;
        in
        {
          packages = {
            luajit = pkgs.pkgsStatic.luajit.overrideAttrs (oldAttrs: {
              env = (oldAttrs.env or { }) // {
                NIX_CFLAGS_COMPILE = toString [
                  (oldAttrs.env.NIX_CFLAGS_COMPILE or "")
                  "-DLUAJIT_ENABLE_LUA52COMPAT"
                  "-DLUAJIT_NO_UNWIND=1"
                ];

                prePatch = (oldAttrs.prePatch or "") + ''
                  sed -i -E 's/#define LUAI_MAXCSTACK\s+8000/#define LUAI_MAXCSTACK 0xFFFFFF00/' src/luaconf.h
                  sed -i -E 's/#define LUAI_MAXSTACK\s+65500/#define LUAI_MAXSTACK 0xFFFFFF00/' src/luaconf.h
                '';

                dontStrip = true;
              };
            });
          };
          devShells = {
            default = pkgs.mkShell rec {
              buildInputs =
                with pkgs;
                [
                  pkg-config
                  zig
                ]
                ++ [ self.packages.${system}.luajit ];

              LD_LIBRARY_PATH = "${lib.makeLibraryPath buildInputs}";
            };
          };
        }
      );
    in
    outputsWithSystem // outputsWithoutSystem;
}
