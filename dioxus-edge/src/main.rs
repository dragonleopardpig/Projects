mod gpu_sobel;

use dioxus::prelude::*;
use image::{DynamicImage, GrayImage, ImageBuffer, Luma, Rgba};
use std::fs;
use std::process::Command;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::io::AsyncReadExt;

#[derive(Clone, Debug)]
struct FileEntry {
    path: PathBuf,
    name: String,
    size: u64,
    is_dir: bool,
    is_image: bool,
}

fn main() {
    dioxus::launch(App);
}

#[component]
fn App() -> Element {
    let mut original_image = use_signal(|| None::<String>);
    let mut edge_image = use_signal(|| None::<String>);
    let mut status = use_signal(|| String::from("No image loaded"));
    let mut file_path = use_signal(|| String::new());
    let mut lightbox_image = use_signal(|| None::<String>);
    let mut lightbox_title = use_signal(|| String::new());
    let mut current_directory = use_signal(|| {
        std::env::var("HOME").unwrap_or_else(|_| "/".to_string())
    });
    let mut file_entries = use_signal(|| Vec::<FileEntry>::new());
    let mut processing_progress = use_signal(|| 0);
    let mut is_processing = use_signal(|| false);
    let mut visualization_mode = use_signal(|| false);
    let mut gray_values = use_signal(|| Vec::<Vec<u8>>::new());
    let mut current_scan_pos = use_signal(|| (0usize, 0usize));
    let mut edge_matrix = use_signal(|| Vec::<Vec<u8>>::new());
    let mut is_animating = use_signal(|| false);
    let mut animation_speed = use_signal(|| 100u64);
    let mut matrix_zoom = use_signal(|| 1.0f32);
    let mut scroll_x = use_signal(|| 0usize);
    let mut scroll_y = use_signal(|| 0usize);
    let mut smart_scan = use_signal(|| true);
    let mut skipped_pixels = use_signal(|| 0usize);
    let mut variance_threshold = use_signal(|| 10u8);

    // Camera signals
    let mut is_live = use_signal(|| false);
    let mut live_fps = use_signal(|| 0.0f64);
    let mut live_child: Signal<Option<Arc<Mutex<Option<tokio::process::Child>>>>> = use_signal(|| None);
    // camera_frame holds a URL string for the img src
    let mut camera_frame = use_signal(|| None::<String>);
    let mut camera_overlay = use_signal(|| None::<String>);
    let mut has_frozen_frame = use_signal(|| false);
    let mut show_edge_overlay = use_signal(|| false);
    // Keep raw grayscale bytes of the frozen frame for edge detection (avoids re-decoding)
    let mut camera_raw: Signal<Option<(u32, u32, Vec<u8>)>> = use_signal(|| None);

    // GPU-accelerated Sobel (falls back to CPU if GPU unavailable)
    let gpu_sobel: Signal<Arc<Option<gpu_sobel::GpuSobel>>> = use_signal(|| {
        Arc::new(gpu_sobel::GpuSobel::new())
    });

    // Shared BMP buffer for zero-copy asset serving
    let frame_buf: Arc<Mutex<Vec<u8>>> = use_hook(|| Arc::new(Mutex::new(Vec::new())));
    let frame_buf_handler = frame_buf.clone();
    dioxus_desktop::use_asset_handler("camera", move |_req, responder| {
        let data = frame_buf_handler.lock().unwrap().clone();
        responder.respond(
            http::Response::builder()
                .status(200)
                .header("Content-Type", "image/bmp")
                .header("Cache-Control", "no-cache, no-store")
                .body(data)
                .unwrap(),
        );
    });

    let mut load_directory = move || {
        let dir = current_directory.read().clone();
        if let Ok(entries) = fs::read_dir(&dir) {
            let mut files: Vec<FileEntry> = entries
                .filter_map(|entry| entry.ok())
                .filter_map(|entry| {
                    let path = entry.path();
                    let metadata = fs::metadata(&path).ok()?;
                    let name = path.file_name()?.to_string_lossy().to_string();
                    let is_dir = metadata.is_dir();
                    let is_image = !is_dir && path.extension()
                        .and_then(|s| s.to_str())
                        .map_or(false, |ext| {
                            matches!(ext.to_lowercase().as_str(), "png" | "jpg" | "jpeg" | "bmp" | "gif" | "webp")
                        });
                    
                    Some(FileEntry {
                        path: path.clone(),
                        name,
                        size: metadata.len(),
                        is_dir,
                        is_image,
                    })
                })
                .collect();
            
            files.sort_by(|a, b| {
                match (a.is_dir, b.is_dir) {
                    (true, false) => std::cmp::Ordering::Less,
                    (false, true) => std::cmp::Ordering::Greater,
                    _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
                }
            });
            
            file_entries.set(files);
        }
    };

    use_effect(move || {
        load_directory();
    });

    let open_file_dialog = move |_evt: Event<MouseData>| {
        let gpu = gpu_sobel.read().clone();
        spawn(async move {
            status.set("Opening file chooser...".to_string());
            
            let result = tokio::task::spawn_blocking(|| {
                if let Ok(output) = Command::new("zenity")
                    .args(&[
                        "--file-selection",
                        "--title=Select an Image",
                        "--file-filter=Images | *.png *.jpg *.jpeg *.bmp *.gif *.webp",
                    ])
                    .output()
                {
                    if output.status.success() {
                        return Some(String::from_utf8_lossy(&output.stdout).trim().to_string());
                    }
                }
                
                if let Ok(output) = Command::new("kdialog")
                    .args(&[
                        "--getopenfilename",
                        "~",
                        "*.png *.jpg *.jpeg *.bmp *.gif *.webp | Image files",
                    ])
                    .output()
                {
                    if output.status.success() {
                        return Some(String::from_utf8_lossy(&output.stdout).trim().to_string());
                    }
                }
                
                None
            }).await;
            
            match result {
                Ok(Some(path)) if !path.is_empty() => {
                    if let Some(parent) = Path::new(&path).parent() {
                        current_directory.set(parent.to_string_lossy().to_string());
                        load_directory();
                    }
                    
                    file_path.set(path.clone());
                    status.set("Processing...".to_string());
                    
                    match fs::read(&path) {
                        Ok(bytes) => {
                            match process_image_from_bytes(&bytes, &gpu) {
                                Ok((orig_base64, edge_base64)) => {
                                    // Clear camera state so file-loaded view shows
                                    camera_frame.set(None);
                                    camera_overlay.set(None);
                                    has_frozen_frame.set(false);
                                    show_edge_overlay.set(false);

                                    original_image.set(Some(orig_base64));
                                    edge_image.set(Some(edge_base64));

                                    if let Ok(img) = image::load_from_memory(&bytes) {
                                        let gray = img.to_luma8();
                                        let (width, height) = gray.dimensions();
                                        let mut values = Vec::new();
                                        for y in 0..height {
                                            let mut row = Vec::new();
                                            for x in 0..width {
                                                row.push(gray.get_pixel(x, y)[0]);
                                            }
                                            values.push(row);
                                        }
                                        gray_values.set(values);
                                    }
                                    
                                    status.set(format!("Processed: {}", path));
                                }
                                Err(e) => {
                                    status.set(format!("Error: {}", e));
                                }
                            }
                        }
                        Err(e) => {
                            status.set(format!("Error reading file: {}", e));
                        }
                    }
                }
                Ok(Some(_)) => {
                    status.set("No file selected".to_string());
                }
                Ok(None) => {
                    status.set("File chooser not available. Please install zenity or kdialog.".to_string());
                }
                Err(e) => {
                    status.set(format!("Error opening file chooser: {:?}", e));
                }
            }
        });
    };

    let mut open_lightbox = move |image: String, title: String| {
        lightbox_image.set(Some(image));
        lightbox_title.set(title);
    };

    let close_lightbox = move |_evt: Event<MouseData>| {
        lightbox_image.set(None);
    };

    let toggle_visualization = move |_evt: Event<MouseData>| {
        visualization_mode.set(!visualization_mode());
        if !visualization_mode() {
            is_animating.set(false);
            current_scan_pos.set((0, 0));
        }
    };

    let start_animation = move |_evt: Event<MouseData>| {
        if gray_values.read().is_empty() {
            status.set("Please load an image first".to_string());
            return;
        }
        
        is_animating.set(true);
        current_scan_pos.set((0, 0));
        scroll_x.set(0);
        scroll_y.set(0);
        skipped_pixels.set(0);
        
        let values = gray_values.read().clone();
        let height = values.len();
        let width = if height > 0 { values[0].len() } else { 0 };
        
        if width == 0 || height == 0 {
            return;
        }
        
        let mut edges = vec![vec![0u8; width]; height];
        edge_matrix.set(edges.clone());
        
        spawn(async move {
            let gx = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]];
            let gy = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]];
            
            let mut skipped_count = 0usize;
            let mut pixels_processed = 0usize;
            let threshold = variance_threshold();

            for y in 1..height-1 {
                for x in 1..width-1 {
                    if !is_animating() {
                        break;
                    }

                    let should_skip = if smart_scan() {
                        let mut min_val = 255u8;
                        let mut max_val = 0u8;

                        for ky in 0..3 {
                            for kx in 0..3 {
                                let pixel = values[y + ky - 1][x + kx - 1];
                                min_val = min_val.min(pixel);
                                max_val = max_val.max(pixel);
                            }
                        }

                        let variance = max_val - min_val;
                        variance < threshold
                    } else {
                        false
                    };

                    if should_skip {
                        skipped_count += 1;
                        edges[y][x] = 0;
                        continue;
                    }

                    current_scan_pos.set((x, y));

                    // Update skipped count periodically to avoid excessive UI updates
                    pixels_processed += 1;
                    if pixels_processed % 10 == 0 || skipped_count > 0 {
                        skipped_pixels.set(skipped_count);
                    }
                    
                    let visible_cols = 15;
                    let visible_rows = 10;
                    
                    if x > scroll_x() + visible_cols - 3 {
                        scroll_x.set((x as i32 - visible_cols as i32 + 5).max(0) as usize);
                    } else if x < scroll_x() + 2 && x > 2 {
                        scroll_x.set((x as i32 - 2).max(0) as usize);
                    }
                    
                    if y > scroll_y() + visible_rows - 3 {
                        scroll_y.set((y as i32 - visible_rows as i32 + 5).max(0) as usize);
                    } else if y < scroll_y() + 2 && y > 2 {
                        scroll_y.set((y as i32 - 2).max(0) as usize);
                    }
                    
                    let mut sum_x = 0i32;
                    let mut sum_y = 0i32;
                    
                    for ky in 0..3 {
                        for kx in 0..3 {
                            let pixel = values[y + ky - 1][x + kx - 1] as i32;
                            sum_x += pixel * gx[ky][kx];
                            sum_y += pixel * gy[ky][kx];
                        }
                    }
                    
                    let magnitude = ((sum_x * sum_x + sum_y * sum_y) as f64).sqrt();
                    let pixel_value = magnitude.min(255.0) as u8;
                    
                    edges[y][x] = pixel_value;
                    edge_matrix.set(edges.clone());
                    
                    tokio::time::sleep(std::time::Duration::from_micros(animation_speed())).await;
                }
                
                if !is_animating() {
                    break;
                }
            }
            
            is_animating.set(false);
            skipped_pixels.set(skipped_count);
            let total_pixels = (width - 2) * (height - 2);
            let processed = total_pixels - skipped_count;
            status.set(format!("Animation complete! Processed: {}/{} pixels (skipped {} uniform regions)",
                processed, total_pixels, skipped_count));
        });
    };

    let stop_animation = move |_evt: Event<MouseData>| {
        is_animating.set(false);
    };

    let mut select_file_from_browser = move |entry: FileEntry| {
        if entry.is_dir {
            current_directory.set(entry.path.to_string_lossy().to_string());
            load_directory();
            status.set(format!("Opened directory: {}", entry.name));
            return;
        }
        
        if !entry.is_image {
            status.set("Not an image file".to_string());
            return;
        }
        
        let path_str = entry.path.to_string_lossy().to_string();
        file_path.set(path_str.clone());
        let gpu = gpu_sobel.read().clone();

        spawn(async move {
            is_processing.set(true);
            processing_progress.set(10);
            status.set("Reading file...".to_string());
            
            match fs::read(&path_str) {
                Ok(bytes) => {
                    processing_progress.set(40);
                    status.set("Decoding image...".to_string());
                    
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    processing_progress.set(60);
                    status.set("Applying edge detection...".to_string());
                    
                    match process_image_from_bytes(&bytes, &gpu) {
                        Ok((orig_base64, edge_base64)) => {
                            processing_progress.set(90);
                            status.set("Finalizing...".to_string());

                            // Clear camera state so file-loaded view shows
                            camera_frame.set(None);
                            camera_overlay.set(None);
                            has_frozen_frame.set(false);
                            show_edge_overlay.set(false);

                            original_image.set(Some(orig_base64));
                            edge_image.set(Some(edge_base64));
                            
                            if let Ok(img) = image::load_from_memory(&bytes) {
                                let gray = img.to_luma8();
                                let (width, height) = gray.dimensions();
                                let mut values = Vec::new();
                                for y in 0..height {
                                    let mut row = Vec::new();
                                    for x in 0..width {
                                        row.push(gray.get_pixel(x, y)[0]);
                                    }
                                    values.push(row);
                                }
                                gray_values.set(values);
                            }
                            
                            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                            processing_progress.set(100);
                            status.set(format!("✓ Processed: {}", entry.name));
                            
                            tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                            is_processing.set(false);
                            processing_progress.set(0);
                        }
                        Err(e) => {
                            status.set(format!("Error: {}", e));
                            is_processing.set(false);
                            processing_progress.set(0);
                        }
                    }
                }
                Err(e) => {
                    status.set(format!("Error reading file: {}", e));
                    is_processing.set(false);
                    processing_progress.set(0);
                }
            }
        });
    };

    let mut change_directory = move |new_path: String| {
        if !new_path.is_empty() {
            let path = Path::new(&new_path);
            if path.is_dir() {
                current_directory.set(new_path);
                load_directory();
                status.set("Directory changed".to_string());
            } else if path.is_file() {
                if let Some(parent) = path.parent() {
                    current_directory.set(parent.to_string_lossy().to_string());
                    load_directory();
                }
            } else {
                status.set("Invalid path".to_string());
            }
        }
    };

    let mut path_input = use_signal(|| String::new());

    let on_path_input = move |evt: Event<FormData>| {
        path_input.set(evt.value().clone());
    };

    let on_path_keypress = move |evt: Event<KeyboardData>| {
        if evt.key() == Key::Enter {
            let path = path_input.read().clone();
            change_directory(path);
            path_input.set(String::new());
        }
    };

    use_effect(move || {
        path_input.set(current_directory.read().clone());
    });

    let go_to_parent = move |_evt: Event<MouseData>| {
        let current = current_directory.read().clone();
        if let Some(parent) = Path::new(&current).parent() {
            change_directory(parent.to_string_lossy().to_string());
        }
    };

    let go_to_home = move |_evt: Event<MouseData>| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
        change_directory(home);
    };

    let go_to_pictures = move |_evt: Event<MouseData>| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
        let pictures = format!("{}/Pictures", home);
        if Path::new(&pictures).exists() {
            change_directory(pictures);
        } else {
            change_directory(home);
        }
    };

    let go_to_downloads = move |_evt: Event<MouseData>| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
        let downloads = format!("{}/Downloads", home);
        if Path::new(&downloads).exists() {
            change_directory(downloads);
        } else {
            change_directory(home);
        }
    };

    // Camera: single capture
    let mut is_capturing = use_signal(|| false);
    let frame_buf_capture = frame_buf.clone();
    let capture_frame = move |_evt: Event<MouseData>| {
        if is_capturing() || is_live() {
            return;
        }
        let frame_buf_cap = frame_buf_capture.clone();
        spawn(async move {
            is_capturing.set(true);
            status.set("Capturing frame...".to_string());

            let capture_bin = find_egrab_capture();
            if capture_bin.is_none() {
                status.set("egrab-capture binary not found. Run: make -C egrab-capture".to_string());
                is_capturing.set(false);
                return;
            }
            let capture_bin = capture_bin.unwrap();
            let raw_path = "/tmp/egrab-capture.raw";

            let result = tokio::process::Command::new(&capture_bin)
                .args(["--mode", "single", "--output", raw_path])
                .output()
                .await;

            match result {
                Ok(output) if output.status.success() => {
                    match load_raw_mono(raw_path) {
                        Ok((width, height, mono_data)) => {
                            let mut bmp_buf = Vec::new();
                            mono_to_bmp(&mono_data, width, height, &mut bmp_buf);
                            {
                                let mut buf = frame_buf_cap.lock().unwrap();
                                buf.clear();
                                buf.extend_from_slice(&bmp_buf);
                            }
                            let ts = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_nanos();
                            camera_frame.set(Some(format!(
                                "dioxus://localhost/camera/frame.bmp?t={}",
                                ts
                            )));
                            camera_raw.set(Some((width, height, mono_data)));
                            has_frozen_frame.set(true);
                            show_edge_overlay.set(false);
                            camera_overlay.set(None);
                            status.set("Frame captured — click Detect Edge to find edges".to_string());
                        }
                        Err(e) => {
                            status.set(format!("Failed to load capture: {}", e));
                        }
                    }
                }
                Ok(output) => {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    status.set(format!("Capture failed: {}", stderr.trim()));
                }
                Err(e) => {
                    status.set(format!("Failed to run egrab-capture: {}", e));
                }
            }
            is_capturing.set(false);
        });
    };

    // Camera: live stream toggle
    let frame_buf_live = frame_buf.clone();
    let toggle_live = move |_evt: Event<MouseData>| {
        if is_live() {
            // Stop live — freeze the last frame
            is_live.set(false);
            if let Some(child_arc) = live_child() {
                if let Ok(mut guard) = child_arc.lock() {
                    if let Some(ref mut child) = *guard {
                        let _ = child.start_kill();
                    }
                }
            }
            live_fps.set(0.0);
            // Frame stays in camera_frame, mark as frozen
            if camera_frame().is_some() {
                has_frozen_frame.set(true);
            }
            status.set("Live stopped — frame frozen".to_string());
            return;
        }

        let capture_bin = find_egrab_capture();
        if capture_bin.is_none() {
            status.set("egrab-capture binary not found. Run: make -C egrab-capture".to_string());
            return;
        }
        let capture_bin = capture_bin.unwrap();

        // Reset state for new live session
        is_live.set(true);
        has_frozen_frame.set(false);
        show_edge_overlay.set(false);
        camera_overlay.set(None);
        status.set("Starting live capture...".to_string());

        let child_arc = Arc::new(Mutex::new(None::<tokio::process::Child>));
        live_child.set(Some(child_arc.clone()));

        let frame_buf_spawn = frame_buf_live.clone();
        spawn(async move {
            let child_result = tokio::process::Command::new(&capture_bin)
                .args(["--mode", "stream"])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn();

            let mut child = match child_result {
                Ok(c) => c,
                Err(e) => {
                    status.set(format!("Failed to start stream: {}", e));
                    is_live.set(false);
                    return;
                }
            };

            let mut stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();
            {
                let mut guard = child_arc.lock().unwrap();
                *guard = Some(child);
            }

            // Read camera init logs (stderr) until "Streaming" appears,
            // forwarding each line to the status bar so the user sees progress.
            // After init, keep draining stderr in a background task so the pipe
            // doesn't fill up and the child doesn't get SIGPIPE.
            use tokio::io::AsyncBufReadExt;
            let mut stderr_lines = tokio::io::BufReader::new(stderr).lines();
            while let Ok(Some(line)) = stderr_lines.next_line().await {
                if !line.is_empty() {
                    status.set(format!("Camera: {}", line));
                    tokio::task::yield_now().await; // let UI render
                }
                if line.contains("Streaming") {
                    break;
                }
            }
            // Drain remaining stderr in background (frame count logs, errors)
            spawn(async move {
                while let Ok(Some(_)) = stderr_lines.next_line().await {}
            });

            let mut frame_count = 0u64;
            let mut display_count = 0u64;
            let mut header_buf = [0u8; 12]; // width(4) + height(4) + len(4)
            let mut bmp_buf: Vec<u8> = Vec::new();
            let mut mono_data: Vec<u8> = Vec::new();
            let mut last_display = std::time::Instant::now();
            let display_interval = std::time::Duration::from_micros(16_667); // ~60 FPS display cap
            let mut last_fps_update = std::time::Instant::now();
            let mut last_width = 0u32;
            let mut last_height = 0u32;
            let frame_buf_loop = frame_buf_spawn.clone();

            // Set initial URL so the img element appears in DOM
            camera_frame.set(Some("dioxus://localhost/camera/frame.bmp?t=0".to_string()));
            tokio::task::yield_now().await;

            while is_live() {
                // Read header
                match stdout.read_exact(&mut header_buf).await {
                    Ok(_) => {}
                    Err(_) => break,
                }

                let width = u32::from_ne_bytes([header_buf[0], header_buf[1], header_buf[2], header_buf[3]]);
                let height = u32::from_ne_bytes([header_buf[4], header_buf[5], header_buf[6], header_buf[7]]);
                let data_len = u32::from_ne_bytes([header_buf[8], header_buf[9], header_buf[10], header_buf[11]]) as usize;

                mono_data.resize(data_len, 0);
                match stdout.read_exact(&mut mono_data).await {
                    Ok(_) => {}
                    Err(_) => break,
                }

                frame_count += 1;
                last_width = width;
                last_height = height;

                // Only push to UI at display rate — drain pipe fast, display at ~60fps
                let now = std::time::Instant::now();
                if now.duration_since(last_display) >= display_interval {
                    last_display = now;
                    display_count += 1;

                    // Build BMP and store in shared buffer (asset handler serves it)
                    mono_to_bmp(&mono_data, width, height, &mut bmp_buf);
                    {
                        let mut buf = frame_buf_loop.lock().unwrap();
                        buf.clear();
                        buf.extend_from_slice(&bmp_buf);
                    }

                    // Tiny URL change triggers webview to re-fetch from asset handler
                    let js = format!(
                        "document.getElementById('live-frame').src='dioxus://localhost/camera/frame.bmp?t={}';",
                        display_count
                    );
                    dioxus::document::eval(&js);

                    // Update FPS display only once per second to reduce signal churn
                    let fps_elapsed = now.duration_since(last_fps_update).as_secs_f64();
                    if fps_elapsed >= 1.0 {
                        live_fps.set(display_count as f64 / fps_elapsed);
                        display_count = 0;
                        last_fps_update = now;
                    }

                    // Yield so the webview can fetch the asset and render
                    tokio::task::yield_now().await;
                }
            }

            // Save last frame raw data for edge detection + frozen display
            if !mono_data.is_empty() {
                camera_raw.set(Some((last_width, last_height, mono_data)));
                // The shared buffer already has the last BMP — just update the signal URL
                camera_frame.set(Some(format!(
                    "dioxus://localhost/camera/frame.bmp?t={}",
                    frame_count
                )));
            }

            // Clean up child process
            if let Ok(mut guard) = child_arc.lock() {
                if let Some(ref mut child) = *guard {
                    let _ = child.kill().await;
                }
                *guard = None;
            }

            is_live.set(false);
            live_child.set(None);
            live_fps.set(0.0);
            if frame_count > 0 {
                status.set(format!("Live stopped after {} frames — frame frozen", frame_count));
            }
        });
    };

    // Camera: detect edges on frozen frame
    let detect_edge = move |_evt: Event<MouseData>| {
        if !has_frozen_frame() || show_edge_overlay() {
            return;
        }
        let raw = match camera_raw() {
            Some(r) => r,
            None => return,
        };
        let gpu = gpu_sobel.read().clone();
        spawn(async move {
            status.set("Running edge detection...".to_string());

            let (width, height, mono_data) = raw;
            let gray_img = match GrayImage::from_raw(width, height, mono_data) {
                Some(g) => g,
                None => {
                    status.set("Failed to reconstruct image from raw data".to_string());
                    return;
                }
            };
            let edges = run_sobel(&gray_img, &gpu);
            let overlay = create_edge_overlay(&edges);
            match image_to_base64(&DynamicImage::ImageRgba8(overlay)) {
                Ok(overlay_b64) => {
                    camera_overlay.set(Some(format!("data:image/png;base64,{}", overlay_b64)));
                    show_edge_overlay.set(true);
                    status.set("Edge detection complete — green overlay applied".to_string());
                }
                Err(e) => {
                    status.set(format!("Overlay encode error: {}", e));
                }
            }
        });
    };

    // Camera: save frozen frame to file
    let save_frame = move |_evt: Event<MouseData>| {
        let raw = match camera_raw() {
            Some(r) => r,
            None => return,
        };
        spawn(async move {
            status.set("Opening save dialog...".to_string());
            let result = tokio::task::spawn_blocking(|| {
                Command::new("zenity")
                    .args(&[
                        "--file-selection",
                        "--save",
                        "--confirm-overwrite",
                        "--title=Save Captured Frame",
                        "--file-filter=TIFF files | *.tiff *.tif",
                        "--file-filter=PNG files | *.png",
                        "--file-filter=BMP files | *.bmp",
                        "--file-filter=JPEG files | *.jpg *.jpeg",
                        "--filename=capture.tiff",
                    ])
                    .output()
                    .ok()
                    .and_then(|o| {
                        if o.status.success() {
                            Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                        } else {
                            None
                        }
                    })
            }).await;

            match result {
                Ok(Some(path)) if !path.is_empty() => {
                    let (width, height, mono_data) = raw;
                    if let Some(gray_img) = GrayImage::from_raw(width, height, mono_data) {
                        let dyn_img = DynamicImage::ImageLuma8(gray_img);
                        if let Err(e) = dyn_img.save(&path) {
                            status.set(format!("Save failed: {}", e));
                        } else {
                            status.set(format!("Saved to {}", path));
                        }
                    } else {
                        status.set("Failed to reconstruct image for saving".to_string());
                    }
                }
                _ => {
                    status.set("Save cancelled".to_string());
                }
            }
        });
    };

    let quit_app = move |_evt: Event<MouseData>| -> () {
        std::process::exit(0);
    };

    rsx! {
        style { {include_str!("style.css")} }
        div { class: "app-container",
            div { class: "sidebar",
                h3 { class: "sidebar-title", "📁 Image Browser" }
                
                div { class: "quick-nav",
                    button { class: "nav-button", onclick: go_to_home, title: "Home", "🏠 Home" }
                    button { class: "nav-button", onclick: go_to_pictures, title: "Pictures", "🖼️ Pictures" }
                    button { class: "nav-button", onclick: go_to_downloads, title: "Downloads", "📥 Downloads" }
                    button { class: "nav-button", onclick: go_to_parent, title: "Parent Directory", "⬆️ Up" }
                }
                
                input {
                    class: "current-path",
                    r#type: "text",
                    value: "{path_input}",
                    oninput: on_path_input,
                    onkeydown: on_path_keypress,
                    placeholder: "Enter directory path...",
                }
                
                div { class: "file-list",
                    if file_entries.read().is_empty() {
                        p { class: "no-files", "Empty directory" }
                    }
                    for entry in file_entries.read().iter() {
                        {
                            let file_size_str = format_file_size(entry.size);
                            let entry_clone = entry.clone();
                            let item_class = if entry.is_image { 
                                "file-item image-file" 
                            } else if entry.is_dir { 
                                "file-item dir-item" 
                            } else { 
                                "file-item" 
                            };
                            let icon = if entry.is_dir { 
                                "📁" 
                            } else if entry.is_image { 
                                "🖼️" 
                            } else { 
                                "📄" 
                            };
                            let name = entry.name.clone();
                            
                            rsx! {
                                div { 
                                    key: "{entry.path.to_string_lossy()}",
                                    class: "{item_class}",
                                    onclick: move |_| select_file_from_browser(entry_clone.clone()),
                                    span { class: "file-icon", "{icon}" }
                                    span { class: "file-name", "{name}" }
                                    span { class: "file-size", "{file_size_str}" }
                                }
                            }
                        }
                    }
                }
            }

            div { class: "main-content",
                div { class: "container",
                    div { class: "header-bar",
                        h1 { "Edge Detector" }
                        button { class: "quit-button", onclick: quit_app, title: "Quit Application", "❌ Quit" }
                    }
            
                    div { class: "controls",
                        div { class: "controls-row",
                            button { class: "file-button", onclick: open_file_dialog, "📁 Choose File" }
                            button {
                                class: "capture-button",
                                onclick: capture_frame,
                                disabled: is_capturing() || is_live(),
                                if is_capturing() { "📷 Capturing..." } else { "📷 Capture" }
                            }
                            button {
                                class: if is_live() { "live-button active" } else { "live-button" },
                                onclick: toggle_live,
                                disabled: is_capturing(),
                                if is_live() { "⏹ Stop" } else { "🎥 Live" }
                            }
                            if is_live() {
                                span { class: "fps-counter", "{live_fps():.1} FPS" }
                            }
                            if has_frozen_frame() && !show_edge_overlay() {
                                button {
                                    class: "detect-edge-button",
                                    onclick: detect_edge,
                                    "🔍 Detect Edge"
                                }
                            }
                            if has_frozen_frame() {
                                button {
                                    class: "save-button",
                                    onclick: save_frame,
                                    "💾 Save"
                                }
                            }
                            button {
                                class: if visualization_mode() { "viz-button active" } else { "viz-button" },
                                onclick: toggle_visualization,
                                if visualization_mode() { "📊 Exit Viz" } else { "📊 Visualize" }
                            }
                        }
                        
                        if is_processing() {
                            div { class: "progress-container",
                                div { class: "progress-bar",
                                    div { class: "progress-fill", style: "width: {processing_progress()}%" }
                                }
                                p { class: "progress-text", "{processing_progress()}%" }
                            }
                        }
                        
                        p { class: "status", "{status}" }
                        p { class: "hint", "💡 Click images in sidebar or use Choose File button" }
                    }

                    if visualization_mode() {
                        div { class: "visualization-panel",
                            h3 { "📚 Educational Visualization" }
                            
                            div { class: "viz-controls",
                                button { class: "viz-button", onclick: start_animation, disabled: is_animating(), "▶️ Start Animation" }
                                button { class: "viz-button stop-button", onclick: stop_animation, disabled: !is_animating(), "⏹️ Stop" }
                                
                                button { class: "viz-button turbo-button", onclick: move |_| animation_speed.set(1), "⚡ Turbo (1μs)" }
                                button { class: "viz-button", onclick: move |_| animation_speed.set(50), "🚀 Fast (50μs)" }
                                button { class: "viz-button", onclick: move |_| animation_speed.set(500), "🐢 Slow (500μs)" }
                                
                                div { class: "toggle-smart",
                                    input {
                                        r#type: "checkbox",
                                        id: "smart-scan",
                                        checked: smart_scan(),
                                        onchange: move |evt| smart_scan.set(evt.checked()),
                                    }
                                    label { r#for: "smart-scan", "🧠 Smart Scan (Skip Uniform)" }
                                }

                                if smart_scan() {
                                    div { class: "threshold-controls",
                                        label { "Variance Threshold: " }
                                        input {
                                            r#type: "range",
                                            min: "5",
                                            max: "200",
                                            value: "{variance_threshold}",
                                            oninput: move |evt| {
                                                if let Ok(val) = evt.value().parse::<u8>() {
                                                    variance_threshold.set(val);
                                                }
                                            }
                                        }
                                        span { "{variance_threshold}" }
                                        span { class: "threshold-hint", "(higher = skip more)" }
                                    }
                                }
                                
                                div { class: "speed-controls",
                                    label { "Custom: " }
                                    input {
                                        r#type: "range",
                                        min: "1",
                                        max: "2000",
                                        value: "{animation_speed}",
                                        oninput: move |evt| {
                                            if let Ok(val) = evt.value().parse::<u64>() {
                                                animation_speed.set(val);
                                            }
                                        }
                                    }
                                    span { "{animation_speed}μs" }
                                }
                                
                                div { class: "zoom-controls",
                                    label { "Zoom: " }
                                    button { class: "small-viz-button", onclick: move |_| matrix_zoom.set((matrix_zoom() - 0.2).max(0.5)), "−" }
                                    span { "{(matrix_zoom() * 100.0) as i32}%" }
                                    button { class: "small-viz-button", onclick: move |_| matrix_zoom.set((matrix_zoom() + 0.2).min(3.0)), "+" }
                                }
                                
                                if is_animating() {
                                    p { class: "scan-info", 
                                        "Scanning: ({current_scan_pos().0}, {current_scan_pos().1}) | Skipped: {skipped_pixels()} uniform regions" 
                                    }
                                }
                            }
                            
                            div { class: "viz-display",
                                div { class: "viz-section",
                                    h4 { "Grayscale Values" }
                                    div { class: "matrix-display",
                                        if !gray_values.read().is_empty() {
                                            div {
                                                dangerous_inner_html: "{render_matrix(&gray_values.read(), current_scan_pos(), true, matrix_zoom(), scroll_x(), scroll_y())}"
                                            }
                                        } else {
                                            p { "Load an image to see values" }
                                        }
                                    }
                                }
                                
                                div { class: "viz-section",
                                    h4 { "Edge Values (Sobel)" }
                                    div { class: "matrix-display",
                                        if !edge_matrix.read().is_empty() {
                                            div {
                                                dangerous_inner_html: "{render_matrix(&edge_matrix.read(), current_scan_pos(), false, matrix_zoom(), scroll_x(), scroll_y())}"
                                            }
                                        } else {
                                            p { "Start animation to see edge detection" }
                                        }
                                    }
                                }
                            }
                            
                            div { class: "viz-explanation",
                                h4 { "How Sobel Edge Detection Works:" }
                                p { "1. The image is converted to grayscale (0-255 values)" }
                                p { "2. Two 3×3 kernels (Gx and Gy) scan across the image" }
                                p { "3. Gx detects horizontal edges, Gy detects vertical edges" }
                                p { "4. The magnitude √(Gx² + Gy²) gives the edge strength" }
                                p { "5. Higher values (brighter) = stronger edges" }
                                p { "6. 🧠 Smart Scan: Skips uniform regions (variance < threshold) for 10-50x speedup!" }
                                p { "   Adjust threshold: lower (5-20) = more accurate, higher (50-200) = faster but may miss subtle edges" }
                            }
                        }
                    }

                    // Camera viewport — shown when camera has a frame
                    if let Some(frame) = camera_frame() {
                        div { class: "camera-viewport",
                            img {
                                id: "live-frame",
                                class: "camera-frame",
                                src: "{frame}",
                                alt: "Camera frame",
                            }
                            if show_edge_overlay() {
                                if let Some(overlay) = camera_overlay() {
                                    img {
                                        class: "edge-overlay",
                                        src: "{overlay}",
                                        alt: "Edge overlay",
                                    }
                                }
                            }
                        }
                    }

                    // Original/Edge side-by-side — only for file-loaded images (when no camera frame)
                    if camera_frame().is_none() {
                        div { class: "images",
                            div { class: "image-box",
                                h3 { "Original" }
                                if let Some(img) = original_image() {
                                    img {
                                        class: "clickable-image",
                                        src: "data:image/png;base64,{img}",
                                        alt: "Original image",
                                        onclick: move |_| open_lightbox(img.clone(), "Original Image".to_string()),
                                    }
                                } else {
                                    div { class: "placeholder", "No image" }
                                }
                            }

                            div { class: "image-box",
                                h3 { "Edge Detection" }
                                if let Some(img) = edge_image() {
                                    img {
                                        class: "clickable-image",
                                        src: "data:image/png;base64,{img}",
                                        alt: "Edge detected image",
                                        onclick: move |_| open_lightbox(img.clone(), "Edge Detection".to_string()),
                                    }
                                } else {
                                    div { class: "placeholder", "No image" }
                                }
                            }
                        }
                    }

                    if let Some(img) = lightbox_image() {
                        div { 
                            class: "lightbox-overlay",
                            onclick: close_lightbox,
                            div { 
                                class: "lightbox-content",
                                onclick: move |evt: Event<MouseData>| evt.stop_propagation(),
                                h2 { class: "lightbox-title", "{lightbox_title}" }
                                img { class: "lightbox-image", src: "data:image/png;base64,{img}", alt: "Full resolution view" }
                                p { class: "lightbox-hint", "Click outside to close" }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn process_image_from_bytes(bytes: &[u8], gpu: &Option<gpu_sobel::GpuSobel>) -> Result<(String, String), String> {
    let img = image::load_from_memory(bytes)
        .map_err(|e| format!("Failed to load image: {}", e))?;
    let original_base64 = image_to_base64(&img)?;
    let gray = img.to_luma8();
    let edges = run_sobel(&gray, gpu);
    let edge_img = DynamicImage::ImageLuma8(edges);
    let edge_base64 = image_to_base64(&edge_img)?;
    Ok((original_base64, edge_base64))
}

fn run_sobel(gray: &GrayImage, gpu: &Option<gpu_sobel::GpuSobel>) -> GrayImage {
    let (width, height) = gray.dimensions();
    if let Some(ref gpu) = gpu {
        gpu.detect_edges(gray.as_raw(), width, height)
    } else {
        sobel_edge_detection(gray)
    }
}

fn image_to_base64(img: &DynamicImage) -> Result<String, String> {
    let mut buffer = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut buffer), image::ImageFormat::Png)
        .map_err(|e| format!("Failed to encode image: {}", e))?;
    Ok(base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &buffer))
}

fn sobel_edge_detection(img: &GrayImage) -> GrayImage {
    let (width, height) = img.dimensions();
    let mut output = ImageBuffer::new(width, height);
    let gx = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]];
    let gy = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]];

    for y in 1..height - 1 {
        for x in 1..width - 1 {
            let mut sum_x = 0i32;
            let mut sum_y = 0i32;

            for ky in 0..3 {
                for kx in 0..3 {
                    let pixel = img.get_pixel(x + kx - 1, y + ky - 1)[0] as i32;
                    sum_x += pixel * gx[ky as usize][kx as usize];
                    sum_y += pixel * gy[ky as usize][kx as usize];
                }
            }

            let magnitude = ((sum_x * sum_x + sum_y * sum_y) as f64).sqrt();
            let pixel_value = magnitude.min(255.0) as u8;
            output.put_pixel(x, y, Luma([pixel_value]));
        }
    }

    output
}

fn render_matrix(matrix: &Vec<Vec<u8>>, scan_pos: (usize, usize), is_gray: bool, zoom: f32, scroll_x: usize, scroll_y: usize) -> String {
    let total_height = matrix.len();
    let total_width = if total_height > 0 { matrix[0].len() } else { 0 };
    
    let display_rows = 15;
    let display_cols = 20;
    
    let start_y = scroll_y.min(total_height.saturating_sub(display_rows));
    let start_x = scroll_x.min(total_width.saturating_sub(display_cols));
    let end_y = (start_y + display_rows).min(total_height);
    let end_x = (start_x + display_cols).min(total_width);
    
    let cell_size = (35.0 * zoom) as i32;
    let font_size = (10.0 * zoom) as i32;
    
    let mut html = format!("<div class='matrix-grid' style='grid-template-columns: repeat({}, {}px); font-size: {}px;'>", 
        end_x - start_x, cell_size, font_size);
    
    for y in start_y..end_y {
        for x in start_x..end_x {
            let value = matrix[y][x];
            let is_scanning = scan_pos.0 == x && scan_pos.1 == y && scan_pos != (0, 0);
            let class = if is_scanning {
                "matrix-cell scanning"
            } else if !is_gray && value > 30 {
                "matrix-cell edge"
            } else {
                "matrix-cell"
            };
            
            if is_scanning && is_gray {
                html.push_str(&format!(
                    "<div class='{}' style='background: rgb({},{},{}); width: {}px; height: {}px;' title='Gray value at ({},{}): {}'><span class='scan-value'>{}</span></div>",
                    class, value, value, value, cell_size, cell_size, x, y, value, value
                ));
            } else {
                html.push_str(&format!(
                    "<div class='{}' style='background: rgb({},{},{}); width: {}px; height: {}px;'>{}</div>",
                    class, value, value, value, cell_size, cell_size, value
                ));
            }
        }
    }
    
    html.push_str("</div>");
    html.push_str(&format!("<div class='matrix-info'>Showing region: ({}-{}, {}-{}) of {}x{}</div>", 
        start_x, end_x-1, start_y, end_y-1, total_width, total_height));
    html
}

fn find_egrab_capture() -> Option<String> {
    // Look relative to the cargo manifest dir, then in PATH
    let candidates = [
        "egrab-capture/egrab-capture",
        "./egrab-capture/egrab-capture",
    ];
    for c in &candidates {
        if Path::new(c).exists() {
            return Some(c.to_string());
        }
    }
    // Check PATH
    if let Ok(output) = Command::new("which").arg("egrab-capture").output() {
        if output.status.success() {
            return Some(String::from_utf8_lossy(&output.stdout).trim().to_string());
        }
    }
    None
}

/// Build an uncompressed 24-bit BMP from Mono8 pixels (expands gray→BGR for display).
/// WebKitGTK doesn't reliably render 8-bit paletted BMPs, so we use 24-bit format.
/// Reuses allocation across calls for zero-alloc streaming.
fn mono_to_bmp(gray: &[u8], width: u32, height: u32, bmp_buf: &mut Vec<u8>) {
    let row_stride = (width as usize) * 3;
    let row_pad = (4 - (row_stride % 4)) % 4;
    let pixel_data_size = (row_stride + row_pad) * (height as usize);
    let file_size = 14 + 40 + pixel_data_size;

    bmp_buf.clear();
    bmp_buf.reserve(file_size);

    // BMP file header (14 bytes)
    bmp_buf.extend_from_slice(b"BM");
    bmp_buf.extend_from_slice(&(file_size as u32).to_le_bytes());
    bmp_buf.extend_from_slice(&0u16.to_le_bytes()); // reserved
    bmp_buf.extend_from_slice(&0u16.to_le_bytes()); // reserved
    bmp_buf.extend_from_slice(&54u32.to_le_bytes()); // pixel data offset

    // DIB header (BITMAPINFOHEADER, 40 bytes)
    bmp_buf.extend_from_slice(&40u32.to_le_bytes());
    bmp_buf.extend_from_slice(&width.to_le_bytes());
    bmp_buf.extend_from_slice(&height.to_le_bytes()); // positive = bottom-up
    bmp_buf.extend_from_slice(&1u16.to_le_bytes()); // planes
    bmp_buf.extend_from_slice(&24u16.to_le_bytes()); // bits per pixel
    bmp_buf.extend_from_slice(&0u32.to_le_bytes()); // compression (none)
    bmp_buf.extend_from_slice(&(pixel_data_size as u32).to_le_bytes());
    bmp_buf.extend_from_slice(&2835u32.to_le_bytes()); // h resolution (72 DPI)
    bmp_buf.extend_from_slice(&2835u32.to_le_bytes()); // v resolution
    bmp_buf.extend_from_slice(&0u32.to_le_bytes()); // colors in palette
    bmp_buf.extend_from_slice(&0u32.to_le_bytes()); // important colors

    // Pixel data: BMP stores rows bottom-to-top, BGR order
    // Expand each gray byte to (B=g, G=g, R=g)
    let mono_stride = width as usize;
    let pad_bytes = [0u8; 3];
    for y in (0..height as usize).rev() {
        let row_start = y * mono_stride;
        let row_end = row_start + mono_stride;
        if row_end > gray.len() {
            break;
        }
        for &g in &gray[row_start..row_end] {
            bmp_buf.push(g); // B
            bmp_buf.push(g); // G
            bmp_buf.push(g); // R
        }
        if row_pad > 0 {
            bmp_buf.extend_from_slice(&pad_bytes[..row_pad]);
        }
    }
}

/// Load a raw egrab-capture frame file and return (width, height, mono_bytes).
fn load_raw_mono(path: &str) -> Result<(u32, u32, Vec<u8>), String> {
    let data = fs::read(path).map_err(|e| format!("Read error: {}", e))?;
    if data.len() < 12 {
        return Err("Raw file too small".to_string());
    }
    let width = u32::from_ne_bytes([data[0], data[1], data[2], data[3]]);
    let height = u32::from_ne_bytes([data[4], data[5], data[6], data[7]]);
    let data_len = u32::from_ne_bytes([data[8], data[9], data[10], data[11]]) as usize;
    if data.len() < 12 + data_len {
        return Err(format!("Expected {} bytes of pixel data, got {}", data_len, data.len() - 12));
    }
    Ok((width, height, data[12..12 + data_len].to_vec()))
}

fn create_edge_overlay(edges: &GrayImage) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    let (width, height) = edges.dimensions();
    let mut overlay = ImageBuffer::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let edge_val = edges.get_pixel(x, y)[0];
            if edge_val > 30 {
                overlay.put_pixel(x, y, Rgba([0, 255, 0, 200]));
            } else {
                overlay.put_pixel(x, y, Rgba([0, 0, 0, 0]));
            }
        }
    }
    overlay
}

fn format_file_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;
    
    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
