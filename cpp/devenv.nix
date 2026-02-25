{ pkgs, lib, config, inputs, ... }:

{
  # https://devenv.sh/basics/
  env.GREET = "devenv";
  env.LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib:/opt/euresys/egrabber/lib/x86_64";

  # https://devenv.sh/packages/
  packages =  with pkgs; [
    cmake
    gcc                        # GNU C/C++ compiler
    pkg-config
    enchant
  ];

  # https://devenv.sh/languages/
  languages.cplusplus.enable = true;

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts.hello.exec = ''
    echo hello from $GREET
  '';

  # Generate .clangd with correct nix store paths for clangd
  scripts.gen-clangd.exec = ''
    INCLUDES=$(echo | c++ -xc++ -E -v /dev/null 2>&1 | sed -n '/#include <...>/,/End of search list/{ //!p }' | sed 's/^ *//')
    {
      echo "CompileFlags:"
      echo "  Add:"
      echo "$INCLUDES" | while read -r dir; do
        echo "    - -isystem''${dir}"
      done
    } > .clangd
    echo "Generated .clangd with $(echo "$INCLUDES" | wc -l) include paths"
  '';

  # https://devenv.sh/basics/
  enterShell = ''
    hello         # Run scripts directly
    git --version # Use packages
    gen-clangd    # Regenerate .clangd with current nix store paths
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';

  # https://devenv.sh/git-hooks/
  # git-hooks.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
