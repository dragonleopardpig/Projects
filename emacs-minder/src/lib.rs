pub mod commands;
pub mod emacs_abi;
pub mod ffi;
pub mod latex;
pub mod layout;
pub mod minder_io;
pub mod model;
pub mod org_io;
pub mod render;

use crate::commands::apply_command;
use crate::emacs_abi::{EmacsEnv, EmacsRuntime, EmacsValue, Env};
use crate::latex::LatexCache;
use crate::layout::{center_on_node, hit_test, zoom_fit, AssetCache};
use crate::minder_io::{load_minder_file, save_minder_file};
use crate::model::{EditCommand, MapDocument, SourceFormat};
use crate::org_io::{load_org_file, save_org_file};
use crate::render::{render_full_map_png, render_viewport_png};
use std::os::raw::c_int;
use std::path::Path;
use std::sync::{Arc, OnceLock};

#[no_mangle]
pub static plugin_is_GPL_compatible: c_int = 1;

static GLOBAL_LATEX: OnceLock<Arc<LatexCache>> = OnceLock::new();

fn shared_latex() -> Arc<LatexCache> {
    Arc::clone(GLOBAL_LATEX.get_or_init(|| Arc::new(LatexCache::new())))
}

pub struct MinderSession {
    pub doc: MapDocument,
    pub assets: AssetCache,
    pub latex: Arc<LatexCache>,
    pub last_latex_gen: u64,
}

impl MinderSession {
    pub fn from_doc(mut doc: MapDocument) -> Self {
        let latex = shared_latex();
        let gen = latex.generation();
        let mut assets = AssetCache::new();
        crate::render::prepare_document_for_render(&mut doc, &mut assets, &latex);
        Self {
            doc,
            assets,
            latex,
            last_latex_gen: gen,
        }
    }
}

fn load_document_by_ext(path: &str) -> Result<MapDocument, String> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".org") {
        let mut doc = load_org_file(path)?;
        doc.viewport_w = 1280;
        doc.viewport_h = 840;
        Ok(doc)
    } else {
        let mut doc = load_minder_file(path)?;
        doc.viewport_w = 1280;
        doc.viewport_h = 840;
        Ok(doc)
    }
}

fn save_document_by_ext(doc: &mut MapDocument, path: &str) -> Result<(), String> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".org") {
        save_org_file(doc, path)?;
        doc.source_format = SourceFormat::Org;
    } else {
        save_minder_file(doc, path)?;
        if !doc.images.is_empty() {
            doc.source_format = SourceFormat::MinderTarGz;
        }
    }
    doc.file_path = Some(path.to_string());
    doc.dirty = false;
    Ok(())
}

unsafe extern "C" fn subr_new(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    let mut doc = MapDocument::new_empty();
    if nargs >= 1 {
        let arg0 = *args;
        if env.is_not_nil(arg0) {
            if let Ok(title) = env.extract_string(arg0) {
                if let Some(root) = doc.root_ids.first().copied().and_then(|id| doc.nodes.get_mut(&id)) {
                    root.text = title;
                }
            }
        }
    }
    let mut sess = MinderSession::from_doc(doc);
    center_on_node(&mut sess.doc, 0);
    env.make_user_ptr(sess)
}

unsafe extern "C" fn subr_open_file(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 1 {
        return env.signal_error("emacs-minder-core-open-file requires PATH");
    }
    let path = match env.extract_string(*args) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let doc = if Path::new(&path).exists() {
        match load_document_by_ext(&path) {
            Ok(d) => d,
            Err(e) => return env.signal_error(&e),
        }
    } else {
        let mut d = MapDocument::new_empty();
        d.file_path = Some(path.clone());
        d.source_format = if path.to_ascii_lowercase().ends_with(".org") {
            SourceFormat::Org
        } else {
            SourceFormat::MinderTarGz
        };
        d
    };
    let mut sess = MinderSession::from_doc(doc);
    zoom_fit(&mut sess.doc);
    env.make_user_ptr(sess)
}

unsafe extern "C" fn subr_save_file(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 2 {
        return env.signal_error("emacs-minder-core-save-file requires HANDLE and PATH");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let path = match env.extract_string(slice[1]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    match save_document_by_ext(&mut sess.doc, &path) {
        Ok(()) => env.t(),
        Err(e) => env.signal_error(&e),
    }
}

unsafe extern "C" fn subr_render_png(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 3 {
        return env.signal_error("emacs-minder-core-render-png requires HANDLE WIDTH HEIGHT");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let w = env.extract_integer(slice[1]).unwrap_or(1200) as i32;
    let h = env.extract_integer(slice[2]).unwrap_or(800) as i32;

    match render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, w, h) {
        Ok(png) => env.make_unibyte_string(&png),
        Err(e) => env.signal_error(&e),
    }
}

unsafe extern "C" fn subr_export_png(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 2 {
        return env.signal_error("emacs-minder-core-export-png requires HANDLE OUT_PATH");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let out_path = match env.extract_string(slice[1]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let max_dim = if nargs >= 3 && env.is_not_nil(slice[2]) {
        env.extract_integer(slice[2]).unwrap_or(2400) as i32
    } else {
        2400
    };
    let prev_gen = sess.latex.generation();
    crate::render::prepare_document_for_render(&mut sess.doc, &mut sess.assets, &sess.latex);
    sess.latex.wait_idle();
    let new_gen = sess.latex.generation();
    if new_gen != prev_gen {
        sess.last_latex_gen = new_gen;
        sess.doc.layout_dirty = true;
    }
    match render_full_map_png(&mut sess.doc, &mut sess.assets, &sess.latex, max_dim) {
        Ok(png) => match std::fs::write(&out_path, &png) {
            Ok(()) => env.t(),
            Err(e) => env.signal_error(&format!("Failed writing {out_path}: {e}")),
        },
        Err(e) => env.signal_error(&e),
    }
}

unsafe extern "C" fn subr_set_viewport(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 3 {
        return env.signal_error("emacs-minder-core-set-viewport requires HANDLE WIDTH HEIGHT");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let w = env.extract_integer(slice[1]).unwrap_or(1200).clamp(64, 4096) as i32;
    let h = env.extract_integer(slice[2]).unwrap_or(800).clamp(64, 4096) as i32;
    sess.doc.viewport_w = w;
    sess.doc.viewport_h = h;
    let json = serde_json::to_string(&sess.doc.to_state_json()).unwrap_or_else(|_| "{}".into());
    env.make_string(&json)
}

unsafe extern "C" fn subr_command(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 2 {
        return env.signal_error("emacs-minder-core-command requires HANDLE JSON-CMD");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let cmd_str = match env.extract_string(slice[1]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let cmd: EditCommand = match serde_json::from_str(&cmd_str) {
        Ok(c) => c,
        Err(e) => return env.signal_error(&format!("Invalid minder command JSON: {e}")),
    };
    if let Err(e) = apply_command(&mut sess.doc, cmd) {
        return env.signal_error(&e);
    }
    if sess.doc.layout_dirty {
        crate::render::prepare_document_for_render(&mut sess.doc, &mut sess.assets, &sess.latex);
    }
    let json = serde_json::to_string(&sess.doc.to_state_json()).unwrap_or_else(|_| "{}".into());
    env.make_string(&json)
}

unsafe extern "C" fn subr_hit_test(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 3 {
        return env.signal_error("emacs-minder-core-hit-test requires HANDLE X Y");
    }
    let slice = std::slice::from_raw_parts(args, nargs as usize);
    let sess = match env.get_user_ptr::<MinderSession>(slice[0]) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let x = env.extract_float_or_int(slice[1]).unwrap_or(0.0);
    let y = env.extract_float_or_int(slice[2]).unwrap_or(0.0);
    let hit = hit_test(&sess.doc, x, y);
    let json = serde_json::to_string(&hit).unwrap_or_else(|_| r#"{"kind":"none"}"#.into());
    env.make_string(&json)
}

unsafe extern "C" fn subr_state_json(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 1 {
        return env.signal_error("emacs-minder-core-state-json requires HANDLE");
    }
    let sess = match env.get_user_ptr::<MinderSession>(*args) {
        Ok(s) => s,
        Err(e) => return env.signal_error(&e),
    };
    let json = serde_json::to_string(&sess.doc.to_state_json()).unwrap_or_else(|_| "{}".into());
    env.make_string(&json)
}

unsafe extern "C" fn subr_poll_updates(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 1 {
        return env.nil();
    }
    let sess = match env.get_user_ptr::<MinderSession>(*args) {
        Ok(s) => s,
        Err(_) => return env.nil(),
    };
    let cur_gen = sess.latex.generation();
    if cur_gen != sess.last_latex_gen {
        sess.last_latex_gen = cur_gen;
        sess.doc.layout_dirty = true;
        sess.doc.needs_measure = true;
        env.t()
    } else {
        env.nil()
    }
}

unsafe extern "C" fn subr_wait_latex(
    raw_env: *mut EmacsEnv,
    nargs: isize,
    args: *mut EmacsValue,
    _data: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env::from_raw(raw_env);
    if nargs < 1 {
        return env.nil();
    }
    let sess = match env.get_user_ptr::<MinderSession>(*args) {
        Ok(s) => s,
        Err(_) => return env.nil(),
    };
    sess.latex.wait_idle();
    let cur_gen = sess.latex.generation();
    if cur_gen != sess.last_latex_gen {
        sess.last_latex_gen = cur_gen;
        sess.doc.layout_dirty = true;
        sess.doc.needs_measure = true;
        env.t()
    } else {
        env.nil()
    }
}

#[no_mangle]
pub unsafe extern "C" fn emacs_module_init(runtime: *mut EmacsRuntime) -> c_int {
    let raw_env = ((*runtime).get_environment)(runtime);
    let env = Env::from_raw(raw_env);

    env.defun(
        "emacs-minder-core-new",
        0,
        1,
        subr_new,
        "Create a new in-memory Minder document handle.",
    );
    env.defun(
        "emacs-minder-core-open-file",
        1,
        1,
        subr_open_file,
        "Open a .minder or .org file into a Minder document handle.",
    );
    env.defun(
        "emacs-minder-core-save-file",
        2,
        2,
        subr_save_file,
        "Save Minder HANDLE to PATH (.minder or .org based on extension).",
    );
    env.defun(
        "emacs-minder-core-render-png",
        3,
        3,
        subr_render_png,
        "Render Minder HANDLE viewport WIDTH x HEIGHT into raw PNG bytes.",
    );
    env.defun(
        "emacs-minder-core-export-png",
        2,
        3,
        subr_export_png,
        "Export full Minder HANDLE diagram to OUT-PATH PNG file.",
    );
    env.defun(
        "emacs-minder-core-set-viewport",
        3,
        3,
        subr_set_viewport,
        "Update Minder HANDLE viewport dimensions WIDTH x HEIGHT.",
    );
    env.defun(
        "emacs-minder-core-command",
        2,
        2,
        subr_command,
        "Execute a JSON EditCommand on Minder HANDLE and return state JSON.",
    );
    env.defun(
        "emacs-minder-core-hit-test",
        3,
        3,
        subr_hit_test,
        "Hit-test pixel coordinates (X, Y) on Minder HANDLE.",
    );
    env.defun(
        "emacs-minder-core-state-json",
        1,
        1,
        subr_state_json,
        "Return full JSON state for Minder HANDLE.",
    );
    env.defun(
        "emacs-minder-core-poll-updates",
        1,
        1,
        subr_poll_updates,
        "Return non-nil if async LaTeX compiles resolved since last render.",
    );
    env.defun(
        "emacs-minder-core-wait-latex",
        1,
        1,
        subr_wait_latex,
        "Wait for queued LaTeX compiles on HANDLE to finish and return non-nil if updated.",
    );

    let sym = env.intern("emacs-minder-core");
    let mut args = [sym];
    let _ = env.funcall("provide", &mut args);
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::latex::{
        compile_latex_sync, normalize_expression, parse_tex_metrics, split_latex_spans, SpanPart,
    };
    use crate::minder_io::load_minder_bytes;
    use crate::model::*;
    use crate::org_io::{load_org_str, serialize_org};

    #[test]
    fn test_latex_span_parser_and_normalization() {
        let spans = split_latex_spans("Energy $E=mc^2$ and cost $5 vs \\(\\vec{A}=B\\)");
        assert_eq!(spans.len(), 4);
        assert!(matches!(&spans[1], SpanPart::Formula { normalized, display: false, .. } if normalized == "E=mc^2"));
        assert!(matches!(&spans[3], SpanPart::Formula { normalized, display: false, .. } if normalized == "\\vec{A}=B"));
        assert!(matches!(&spans[2], SpanPart::Text(t) if t.contains("$5")));

        let norm = normalize_expression("\\begin{align*}a&=b\\end{align*}");
        assert_eq!(norm, "\\begin{aligned}a&=b\\end{aligned}");

        let m = parse_tex_metrics("MINDER-METRICS:655360,458752,131072").unwrap();
        assert!(m.width_px > 10.0 && m.ascent_px > 5.0 && m.descent_px > 1.0);
    }

    #[test]
    fn test_render_transparent_argb32_png_and_layouts() {
        let mut sess = MinderSession::from_doc(MapDocument::new_empty());
        for i in 0..4 {
            apply_command(
                &mut sess.doc,
                EditCommand::AddChild {
                    parent_id: Some(0),
                    text: Some(format!("Branch {i}")),
                },
            )
            .unwrap();
        }
        for layout_name in [
            "Horizontal",
            "To right",
            "To left",
            "Vertical",
            "Upwards",
            "Downwards",
            "Manual",
        ] {
            apply_command(
                &mut sess.doc,
                EditCommand::SetLayout {
                    id: Some(0),
                    layout: layout_name.into(),
                },
            )
            .unwrap();
            let png = render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, 640, 420)
                .expect("PNG render");
            assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
            assert!(png.len() > 200);
            let decoded = crate::ffi::CairoSurface::from_pixbuf_bytes(&png).expect("fast PNG decode");
            assert_eq!(decoded.width, 640);
            assert_eq!(decoded.height, 420);
        }

        // Hit-test root center at zoom reset
        apply_command(&mut sess.doc, EditCommand::ZoomReset).unwrap();
        let root = &sess.doc.nodes[&0];
        let sx = (root.posx + root.width / 2.0 - sess.doc.origin_x) * sess.doc.scale;
        let sy = (root.posy + root.height / 2.0 - sess.doc.origin_y) * sess.doc.scale;
        let hit = hit_test(&sess.doc, sx, sy);
        assert_eq!(hit.kind, "node");
        assert_eq!(hit.node_id, Some(0));
    }

    #[test]
    fn test_org_roundtrip_and_tables() {
        let sample = "#+TITLE: Test Optics\n#+AUTHOR: User\n\n* Section One :tag1:tag2:\n  - Formula :: \\(n_1 \\sin\\theta_1 = n_2 \\sin\\theta_2\\)\n  - Subitem\n** Child Heading\n| ColA | ColB |\n|------+------|\n| 1    | 2    |\n\n* TODO Second Section\nBody note text.\n";
        let doc = load_org_str(sample, None).unwrap();
        let orig_len = doc.nodes.len();
        assert_eq!(doc.source_format, SourceFormat::Org);
        assert!(orig_len >= 5);
        assert!(doc.nodes.values().any(|n| n.table.is_some()));
        assert!(doc.nodes.values().any(|n| n.tags.contains(&"tag1".to_string())));

        let mut sess = MinderSession::from_doc(doc);
        let png =
            render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, 800, 600).unwrap();
        assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));

        let out_org = serialize_org(&sess.doc, None);
        assert!(out_org.contains("#+TITLE: Test Optics"));
        assert!(out_org.contains("* Section One :tag1:tag2:"));
        assert!(out_org.contains("| ColA | ColB |"));
        assert!(out_org.contains("* TODO Second Section"));

        let reloaded = load_org_str(&out_org, None).unwrap();
        assert_eq!(reloaded.nodes.len(), orig_len);
    }

    #[test]
    fn test_minder_tar_gz_and_xml_roundtrip() {
        let mut sess = MinderSession::from_doc(MapDocument::new_empty());
        let fake_svg = br#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="red"/></svg>"#;
        sess.doc.images.insert(
            7,
            ImageAsset {
                id: 7,
                uri: "".into(),
                ext: ".svg".into(),
                data: fake_svg.to_vec(),
            },
        );
        sess.doc.source_format = SourceFormat::MinderTarGz;
        if let Some(r) = sess.doc.nodes.get_mut(&0) {
            r.image = Some(NodeImageRef {
                id: 7,
                crop_x: 0,
                crop_y: 0,
                crop_w: 0,
                crop_h: 0,
                size: 80.0,
            });
            r.table = Some(NodeTable {
                rows: 2,
                columns: 2,
                cells: vec![
                    TableCell {
                        row: 0,
                        col: 0,
                        rowspan: 1,
                        colspan: 1,
                        text: "H1".into(),
                        align: "left".into(),
                        highlighted: true,
                        bold: true,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                    },
                    TableCell {
                        row: 1,
                        col: 1,
                        rowspan: 1,
                        colspan: 1,
                        text: "V2".into(),
                        align: "right".into(),
                        highlighted: false,
                        bold: false,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                    },
                ],
            });
        }

        let tmp = std::env::temp_dir().join(format!("emacs-minder-rt-{}.minder", std::process::id()));
        let tmp_str = tmp.to_string_lossy().into_owned();
        save_minder_file(&sess.doc, &tmp_str).unwrap();
        let reloaded_bytes = std::fs::read(&tmp).unwrap();
        let _ = std::fs::remove_file(&tmp);

        let reloaded = load_minder_bytes(&reloaded_bytes, None).unwrap();
        assert_eq!(reloaded.source_format, SourceFormat::MinderTarGz);
        assert!(reloaded.images.contains_key(&7));
        assert!(reloaded.nodes[&0].image.is_some());
        assert!(reloaded.nodes[&0].table.is_some());
    }

    #[test]
    fn test_real_user_fixtures_if_present() {
        let formula_path = "/home/thinky/Projects/Kraken-Optical-Simulator/attachment/Formula.minder";
        if Path::new(formula_path).exists() {
            let doc = load_minder_file(formula_path).expect("load Formula.minder");
            assert!(doc.nodes.len() > 100);
            assert!(!doc.images.is_empty());
            assert!(doc.nodes.values().any(|n| n.table.is_some()));
            let mut sess = MinderSession::from_doc(doc);
            zoom_fit(&mut sess.doc);
            let png = render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, 1000, 700)
                .unwrap();
            assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        }

        let build_path = "/home/thinky/Projects/Minder/build.minder";
        if Path::new(build_path).exists() {
            let doc = load_minder_file(build_path).expect("load build.minder");
            assert!(doc.nodes.len() > 10);
            let mut sess = MinderSession::from_doc(doc);
            zoom_fit(&mut sess.doc);
            let png = render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, 800, 600)
                .unwrap();
            assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        }

        let optics_path = "/home/thinky/Projects/org/optics.org";
        if Path::new(optics_path).exists() {
            let doc = load_org_file(optics_path).expect("load optics.org");
            assert!(doc.nodes.len() > 30);
            let mut sess = MinderSession::from_doc(doc);
            zoom_fit(&mut sess.doc);
            let png = render_viewport_png(&mut sess.doc, &mut sess.assets, &sess.latex, 1000, 700)
                .unwrap();
            assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        }
    }

    #[test]
    fn test_live_latex_when_available() {
        let has_latex = std::process::Command::new("latex")
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        let has_dvisvgm = std::process::Command::new("dvisvgm")
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if has_latex && has_dvisvgm {
            let res = compile_latex_sync("\\frac{1}{\\lambda} = R\\left(\\frac{1}{n_1^2} - \\frac{1}{n_2^2}\\right)").expect("live latex compile");
            assert!(res.metrics.width_px > 20.0);
            assert!(res.svg.windows(4).any(|w| w == b"<svg"));
        }
    }
}
