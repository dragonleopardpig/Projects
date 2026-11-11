{ inputs, pkgs, lib, ... }:
let
  gtksourceview5-extra-specs = pkgs.runCommand "gtksourceview5-extra-specs" {} ''
    mkdir -p $out/share/gtksourceview-5/language-specs
    cp ${./strata/emacs-lisp.lang} $out/share/gtksourceview-5/language-specs/emacs-lisp.lang
    cp ${./strata/org.lang} $out/share/gtksourceview-5/language-specs/org.lang
  '';
in
{
  environment.systemPackages = [
    inputs.strata.packages.${pkgs.stdenv.hostPlatform.system}.default
    gtksourceview5-extra-specs
  ];
  environment.pathsToLink = [ "/share/gtksourceview-5" ];
  services.gvfs.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
}
