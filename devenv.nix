{ pkgs, lib, config, inputs, ... }:

{
  # https://devenv.sh/languages/
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs;
    npm.enable = true;
  };

  # Set a local prefix for npm global installs so they don't try to write to the Nix store
  env.NPM_CONFIG_PREFIX = "${config.env.DEVENV_STATE}/npm";
  
  # Add the local npm bin directory to PATH
  enterShell = ''
    mkdir -p "$NPM_CONFIG_PREFIX/bin"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
  '';
  
  packages = [
    # Ensure nodejs is in packages if not fully handled by languages.javascript
    pkgs.nodejs
  ];
}
