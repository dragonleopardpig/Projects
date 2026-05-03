# { pkgs ? import <nixpkgs> { }, pythonPackages ? pkgs.python3Packages }:

# pkgs.mkShell {
#   buildInputs = [
#     pythonPackages.numpy
#     pythonPackages.sympy
#     pythonPackages.scipy
#     pythonPackages.pandas
#     pythonPackages.jupyter
#     pythonPackages.matplotlib
#   ];
# }

{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
    buildInputs = [
      (pkgs.python3.withPackages (ps: with ps; [
        scipy
        numpy
        matplotlib
        sympy
        pandas
        jupyter
        ipython
        ipykernel
        setuptools
      ]))
    ];
}
