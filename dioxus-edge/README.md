# Edge Detector

A desktop application for real-time camera capture and Sobel edge detection, built with [Dioxus 0.6](https://dioxuslabs.com/) (Rust) and a C++ camera helper for Euresys CoaxLink frame grabbers.

## Features

- **Live camera streaming** at ~10 FPS display rate from a Euresys CoaxLink camera
- **Single-frame capture** from the camera
- **Sobel edge detection** with green overlay on frozen camera frames
- **File-based edge detection** with side-by-side Original/Edge view
- **Educational visualization** mode showing the Sobel algorithm scanning pixel-by-pixel
- **Image browser** sidebar with directory navigation
- **Save captured frames** to TIFF, PNG, BMP, or JPEG via save dialog
- **Lightbox** for full-resolution viewing of file-loaded images

## Architecture

```
  CoaxLink Camera
        |
        | (CoaXPress)
        v
+---------------------+
| egrab-capture       |    C++ helper binary
| EGrabber SDK        |    Converts to RGB8
| FormatConverter     |    8 frame buffers
+---------------------+
        |
        | stdout pipe: [u32 w][u32 h][u32 len][RGB bytes]
        v
+--------------------------------------------------+
| Async Live Stream Loop                           |
|                                                  |
| 1. Read frame header (12 bytes: w, h, len)       |
| 2. Read RGB pixel data                           |
| 3. If display interval elapsed (~60fps cap):     |
|    a. Encode to BMP (uncompressed, <1ms)         |
|    b. Write BMP into shared buffer               |
|    c. eval() tiny URL change on img element      |
|    d. yield_now() for webview to render          |
+--------------------------------------------------+
        |
        | writes BMP bytes
        v
+--------------------------------------------------+
| Shared Buffer: Arc<Mutex<Vec<u8>>>               |
+--------------------------------------------------+
        |
        | dioxus://localhost/camera/frame.bmp?t=N
        v
+--------------------------------------------------+
| Asset Handler (use_asset_handler "camera")       |
| Responds with BMP bytes from shared buffer       |
| Headers: Content-Type: image/bmp, no-cache       |
+--------------------------------------------------+
        |
        | HTTP response (BMP bytes)
        v
+--------------------------------------------------+
| WebView <img id="live-frame">                    |
| JS eval() updates src URL (tiny string change)   |
| WebView fetches from asset handler, renders BMP  |
+--------------------------------------------------+

Signals (reactive state):
  is_live, live_fps, camera_frame, camera_raw,
  has_frozen_frame, show_edge_overlay, camera_overlay
```

### Key Design Decision: Asset Handler for Live Video

The main performance challenge was displaying live video in Dioxus's webview-based UI. Several approaches were tried and abandoned:

| Approach | Result | Bottleneck |
|----------|--------|------------|
| PNG base64 → Signal | ~1 FPS | PNG encoding (~50-100ms/frame) |
| BMP base64 → Signal | ~1.4 FPS | 1.2MB base64 through VDOM diff |
| BMP base64 → JS eval | ~3 FPS | 1.2MB JS string parsing |
| file:// URL | Broken | WebView didn't load file:// properly |
| **Asset handler** | **~10 FPS** | **Winner** |

The asset handler (`dioxus_desktop::use_asset_handler`) registers a custom protocol `dioxus://localhost/camera/...` that serves BMP bytes directly from an `Arc<Mutex<Vec<u8>>>` shared buffer. The live loop writes BMP data into this buffer, then uses `dioxus::document::eval()` to change only the tiny URL query string (`?t=N`) on the `<img>` element. This triggers the webview to re-fetch from the asset handler without any large data passing through signals, VDOM, or JavaScript.

## Project Structure

```
dioxus-edge/
├── src/
│   ├── main.rs          # Application code (UI, camera, edge detection)
│   └── style.css        # CSS styles (embedded via include_str!)
├── egrab-capture/
│   ├── capture.cpp      # C++ camera helper using Euresys eGrabber SDK
│   ├── Makefile          # Builds egrab-capture binary
│   └── egrab-capture     # Compiled binary (not in git)
├── Cargo.toml           # Rust dependencies
├── devenv.nix           # Nix development environment
├── devenv.yaml          # Devenv configuration
└── README.md            # This file
```

## Dependencies

### Rust Crates (Cargo.toml)

| Crate | Version | Purpose |
|-------|---------|---------|
| `dioxus` | 0.6 | UI framework (desktop feature) |
| `dioxus-desktop` | 0.6 | Desktop-specific APIs (asset handler) |
| `image` | 0.25 | Image loading, Sobel processing, TIFF/PNG/BMP/JPEG save |
| `base64` | 0.22 | Base64 encoding for edge overlay PNG data URIs |
| `tokio` | 1 | Async runtime (process spawning, I/O, timers) |
| `http` | 1.4 | HTTP Response builder for asset handler |

### System Dependencies (devenv.nix)

The project uses [devenv](https://devenv.sh/) to provide a reproducible NixOS development shell with:

- Rust toolchain (rustc, cargo, rust-analyzer, clippy, rustfmt)
- GTK3/GTK4, WebKitGTK 4.1 (required by Dioxus desktop/webview)
- Wayland + X11 libraries, Vulkan loader, libGL
- pkg-config, openssl, sqlite, gcc, gnumake
- zenity (file chooser/save dialogs)
- Euresys eGrabber SDK at `/opt/euresys/egrabber/` (linked via `LD_LIBRARY_PATH`)

### Camera Hardware

- **Euresys CoaxLink** frame grabber with eGrabber SDK installed at `/opt/euresys/egrabber/`
- Any CoaXPress camera supported by the grabber

## Building

### 1. Build the camera helper (requires eGrabber SDK)

```bash
cd egrab-capture
make
```

This produces `egrab-capture/egrab-capture`. The Rust app looks for it relative to the working directory.

### 2. Build and run the Dioxus app

```bash
# Enter the devenv shell (sets up all system dependencies)
devenv shell

# Development build
cargo run

# Release build (optimized, LTO enabled)
cargo run --release
```

Or without entering the shell:

```bash
devenv shell -- cargo run
```

## Usage

### Camera Operations

1. **Live streaming**: Click **Live** to start streaming. The FPS counter shows the current display rate. Click **Stop** to freeze the last frame.

2. **Single capture**: Click **Capture** to grab one frame from the camera.

3. **Edge detection**: After stopping live or capturing a frame, click **Detect Edge** to apply Sobel edge detection. A green overlay highlights detected edges on top of the frozen frame.

4. **Save**: After capturing or freezing a frame, click **Save** to export the image. The save dialog defaults to TIFF format and also supports PNG, BMP, and JPEG. The format is determined by the file extension.

### File-Based Edge Detection

- Use the **sidebar file browser** to navigate to an image and click it, or click **Choose File** to open a system file dialog.
- The app shows Original and Edge Detection images side-by-side.
- Click either image to open a full-resolution lightbox view.

### Educational Visualization

Click **Visualize** to enter the educational mode, which shows:

- A **grayscale values matrix** showing pixel intensities
- A **Sobel edge values matrix** showing computed edge magnitudes
- Animated pixel-by-pixel scanning with a highlighted cursor
- Speed controls from Turbo (1us) to Slow (500us)
- **Smart Scan** option that skips uniform regions (configurable variance threshold)
- An explanation of how the Sobel algorithm works

## Wire Protocol (egrab-capture)

The `egrab-capture` binary communicates via a simple binary protocol on stdout:

```
Per frame:
  [4 bytes] width   (u32, native endian)
  [4 bytes] height  (u32, native endian)
  [4 bytes] length  (u32, native endian) = width * height * 3
  [N bytes] RGB8 pixel data (row-major, top-to-bottom)
```

### Single mode

```bash
egrab-capture --mode single --output /tmp/capture.raw
```

Captures one frame and writes the binary format to the specified file.

### Stream mode

```bash
egrab-capture --mode stream
```

Continuously writes frames to stdout. Reads stdin for 'q' to quit. Also handles SIGTERM/SIGPIPE for graceful shutdown. Uses 8 frame buffers and the Euresys `FormatConverter` to convert the camera's native pixel format to RGB8.

## Key Code Sections (main.rs)

| Lines | Section | Description |
|-------|---------|-------------|
| 1-7 | Imports | Dioxus, image processing, std, tokio |
| 23-74 | Signal setup | All reactive state + asset handler registration |
| 62-74 | Asset handler | `dioxus://localhost/camera/` serves BMP from shared buffer |
| 503-568 | Capture handler | Single-frame capture via egrab-capture |
| 569-725 | Live stream | Async loop reading frames, BMP encoding, display throttling |
| 727-759 | Detect Edge | Sobel edge detection on frozen frame with green overlay |
| 761-812 | Save handler | zenity save dialog, exports via `image` crate `.save()` |
| 1141-1167 | `sobel_edge_detection()` | Core Sobel algorithm (3x3 Gx/Gy kernels) |
| 1239-1289 | `rgb_to_bmp()` | Custom uncompressed BMP encoder for zero-overhead streaming |
| 1291-1304 | `load_raw_rgb()` | Reads egrab-capture's binary frame format |
| 1306-1320 | `create_edge_overlay()` | RGBA overlay: green where edge > 30, transparent elsewhere |

## Performance Notes

- **BMP encoding** is used instead of PNG for live streaming because uncompressed BMP takes <1ms vs ~50-100ms for PNG compression.
- The live loop **reads all frames** from the pipe to prevent backpressure, but only updates the display at ~60fps intervals (`display_interval = 16,667us`).
- `tokio::task::yield_now()` is called after each display update to let the Dioxus single-threaded async runtime process the webview fetch.
- The edge detection overlay uses PNG encoding (via `image_to_base64`) since it's a one-time operation on a frozen frame, not a streaming path.
- Release builds with LTO (`opt-level = 3`, `lto = true`) significantly improve edge detection speed.
