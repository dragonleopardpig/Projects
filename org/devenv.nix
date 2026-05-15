{ pkgs, lib, ... }:

let
  # PyPI wheels for numpy/scipy/opencv-python/etc. bundle prebuilt .so
  # files that dlopen system libraries the Nix-store python doesn't
  # export by default. Surface them via LD_LIBRARY_PATH so the venv's
  # binary extensions can resolve at import time.
  runtimeLibs = with pkgs; [
    stdenv.cc.cc.lib   # libstdc++, libgomp
    zlib               # libz.so.1 — numpy/scipy/matplotlib
    glib               # libgthread/libglib — opencv
    libGL              # opencv cv2.imshow / matplotlib agg
    libGLU
    freetype
    fontconfig
    libpng
    libjpeg
    libsndfile         # librosa / soundfile
    libxkbcommon
    dbus
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libSM
    xorg.libICE
    xorg.libxcb
    enchant            # libenchant-2.so.2 — Emacs jinx module dlopens it
                       # while a buffer here has envrc active.
  ];
in
{
  # Python environment for org-babel source blocks across the notes here.
  # Top packages by occurrence (computed from `import`/`from` lines):
  #   numpy, scipy, matplotlib, pandas, cv2, seaborn, sklearn, skimage,
  #   drawsvg, sympy, pywt, librosa, sympy, IPython.
  # Anything not in nixpkgs (drawsvg, hyperbolic, mtspec…) is installed
  # into the venv from PyPI via pip.
  packages = runtimeLibs;
  # Extend LD_LIBRARY_PATH instead of replacing it.  envrc/direnv mirrors
  # the post-shell environment back into Emacs's process-environment, so a
  # bare `env.LD_LIBRARY_PATH =` wipes any path the parent (Emacs init or
  # system) had — notably /run/current-system/sw/lib where libenchant
  # lives.  Prepending in enterShell keeps the inherited path intact.
  enterShell = ''
    export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';

  languages.python = {
    enable = true;
    package = pkgs.python313;
    venv = {
      enable = true;
      requirements = ''
        numpy
        scipy
        matplotlib
        pandas
        seaborn
        scikit-learn
        scikit-image
        opencv-python
        sympy
        PyWavelets
        librosa
        drawsvg
        hyperbolic
        graphviz
        ipython
        jupyter
        yfinance
        pandas-datareader
        imageio
        statsmodels
        pykalman
        pyfftw
      '';
    };
  };
}
