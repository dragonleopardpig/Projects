{ stdenvNoCC, fetchurl, lib }:

let
  revision = "5174b3333331c966c38f4355d50b03ca1c1df2f9";
  licenseFile = fetchurl {
    name = "Caveat-OFL.txt";
    url = "https://raw.githubusercontent.com/google/fonts/${revision}/ofl/caveat/OFL.txt";
    sha256 = "0yqmh1470nqhvszgfpxzxi8d05x7k2syh7lai7rq4g97jk88378z";
  };
in
stdenvNoCC.mkDerivation {
  pname = "caveat";
  version = "2026-03-13";
  src = fetchurl {
    name = "Caveat.ttf";
    url = "https://raw.githubusercontent.com/google/fonts/${revision}/ofl/caveat/Caveat%5Bwght%5D.ttf";
    sha256 = "123r2p2f77kbkr5059sxd7w3wswilpxljn4lncqiblw20ik6pnqb";
  };
  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    install -Dm444 "$src" "$out/share/fonts/truetype/Caveat.ttf"
    install -Dm444 ${licenseFile} "$out/share/doc/caveat/OFL.txt"
    runHook postInstall
  '';
  meta.license = lib.licenses.ofl;
}
