# Projects

NixOS-based development environment for machine vision, scientific computing, and Emacs tooling. All dev environments use [devenv.sh](https://devenv.sh/) for reproducible Nix shells.

## Repositories

### [dioxus-edge](dioxus-edge/)
Real-time camera capture and edge detection desktop app. Streams from an Euresys CoaxLink frame grabber at ~10 FPS with GPU-accelerated Sobel edge detection via wgpu compute shaders (RTX 4070). Built with Dioxus 0.6 (Rust) and a C++ capture helper using the eGrabber SDK.

- Mono8 pipeline for minimal bandwidth
- Green edge overlay on live/frozen frames
- Educational step-by-step Sobel visualization
- File-based image browser with side-by-side comparison

### [NixOS](NixOS/)
Flake-based NixOS configuration managing two machines:
- **X299 Desktop** — NVIDIA RTX 4070, Euresys CoaxLink frame grabber, DDC/CI brightness
- **M90aPro All-In-One Desktop** — Intel + NVIDIA Prime Sync

Hyprland (Wayland) with UWSM, HyprPanel, SDDM, and Home Manager.

### [scimax](scimax/) (fork)
Fork of [John Kitchin's scimax](https://github.com/jkitchin/scimax) — an Emacs starterkit for scientists and engineers. Org-mode based electronic lab notebooks with Jupyter integration.

### [lsp-bridge](lsp-bridge/) (fork)
Fork of [manateelazycat/lsp-bridge](https://github.com/manateelazycat/lsp-bridge) — a fast multi-threaded LSP client for Emacs using external Python processes.

### [flymake-bridge](flymake-bridge/)
Emacs package that surfaces lsp-bridge diagnostics through the built-in Flymake interface.

### [emacs](emacs/)
Personal Emacs configuration. Loads scimax as base, then layers custom themes (heaven-and-hell light/dark toggle), language settings, and keybindings.

### [rust](rust/)
Rust workspace with tutorial projects. Uses devenv.nix with wasm-bindgen and Dioxus CLI.

### [cpp](cpp/)
C++ development sandbox with CMake and auto-generated clangd configuration for NixOS.

### [python](python/)
Python 3.12 environment with PyTorch, pandas, scikit-learn, JupyterLab, and LSP tooling (pyright, ruff).

### [org](org/)
Org-mode files — notes, tutorials, contacts, and computational physics notebooks.

## Stack

| Layer      | Tools                              |
|------------|------------------------------------|
| OS         | NixOS, Nix flakes, Home Manager    |
| Desktop    | Hyprland, HyprPanel, Kitty         |
| Editor     | Emacs (pgtk) + scimax + lsp-bridge |
| Dev Shells | devenv.sh, direnv                  |
| Languages  | Rust, C++, Python, Emacs Lisp, Nix |
| GPU        | wgpu (Vulkan), NVIDIA RTX 4070     |
| Camera     | Euresys eGrabber SDK, CoaxPress    |
