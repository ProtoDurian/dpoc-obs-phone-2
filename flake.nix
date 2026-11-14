{
  description = "g4 spike: Flutter + web user-side signals";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let pkgs = import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [ flutter bun xvfb-run xorg.xvfb jq curl pkg-config gtk3 cmake ninja clang mesa ];
        CHROME_EXECUTABLE = "/home/kirin/.nix-profile/bin/google-chrome";
      };
    };
}
