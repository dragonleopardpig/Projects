use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Condvar, Mutex};

#[derive(Clone, Debug)]
pub struct LatexMetrics {
    pub width_px: f64,
    pub ascent_px: f64,
    pub descent_px: f64,
}

#[derive(Clone, Debug)]
pub struct CompiledLatex {
    pub svg: Arc<Vec<u8>>,
    pub metrics: LatexMetrics,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpanPart {
    Text(String),
    Formula {
        raw: String,
        normalized: String,
        display: bool,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DelimKind {
    SingleDollar,
    DoubleDollar,
    Paren,   // \( ... \)
    Bracket, // \[ ... \]
}

pub fn normalize_expression(expr: &str) -> String {
    let mut s = expr.trim().to_string();
    for (from, to) in [
        ("\\begin{align*}", "\\begin{aligned}"),
        ("\\end{align*}", "\\end{aligned}"),
        ("\\begin{align}", "\\begin{aligned}"),
        ("\\end{align}", "\\end{aligned}"),
        ("\\begin{gather*}", "\\begin{gathered}"),
        ("\\end{gather*}", "\\end{gathered}"),
        ("\\begin{gather}", "\\begin{gathered}"),
        ("\\end{gather}", "\\end{gathered}"),
    ] {
        if s.contains(from) {
            s = s.replace(from, to);
        }
    }
    s
}

fn is_escaped(source: &str, idx: usize) -> bool {
    let bytes = source.as_bytes();
    let mut bs = 0usize;
    let mut i = idx;
    while i > 0 && bytes[i - 1] == b'\\' {
        bs += 1;
        i -= 1;
    }
    bs % 2 == 1
}

fn can_open_dollar(source: &str, idx: usize) -> bool {
    let bytes = source.as_bytes();
    if idx + 1 >= bytes.len() {
        return false;
    }
    let next = bytes[idx + 1];
    if next.is_ascii_whitespace() {
        return false;
    }
    if idx > 0 {
        let prev = bytes[idx - 1];
        if prev.is_ascii_alphanumeric() {
            return false;
        }
    }
    true
}

fn can_close_dollar(source: &str, idx: usize) -> bool {
    let bytes = source.as_bytes();
    if idx == 0 {
        return false;
    }
    let prev = bytes[idx - 1];
    if prev.is_ascii_whitespace() {
        return false;
    }
    if idx + 1 < bytes.len() && bytes[idx + 1].is_ascii_alphanumeric() {
        return false;
    }
    true
}

fn find_next_delim(source: &str, mut offset: usize) -> Option<(usize, usize, DelimKind)> {
    let bytes = source.as_bytes();
    while offset < bytes.len() {
        if bytes[offset] == b'\\' && offset + 1 < bytes.len() && !is_escaped(source, offset) {
            if bytes[offset + 1] == b'(' {
                return Some((offset, 2, DelimKind::Paren));
            }
            if bytes[offset + 1] == b'[' {
                return Some((offset, 2, DelimKind::Bracket));
            }
        } else if bytes[offset] == b'$' && !is_escaped(source, offset) {
            if offset + 1 < bytes.len() && bytes[offset + 1] == b'$' {
                return Some((offset, 2, DelimKind::DoubleDollar));
            }
            if can_open_dollar(source, offset) {
                return Some((offset, 1, DelimKind::SingleDollar));
            }
        }
        offset += 1;
    }
    None
}

fn find_close_delim(
    source: &str,
    start: usize,
    delim_len: usize,
    kind: DelimKind,
) -> Option<(usize, usize)> {
    let bytes = source.as_bytes();
    let mut offset = start + delim_len;
    while offset < bytes.len() {
        match kind {
            DelimKind::SingleDollar => {
                if bytes[offset] == b'\n' {
                    return None;
                }
                if bytes[offset] == b'$' && !is_escaped(source, offset) {
                    let next_dollar = offset + 1 < bytes.len() && bytes[offset + 1] == b'$';
                    if !next_dollar && can_close_dollar(source, offset) {
                        return Some((offset, 1));
                    }
                }
            }
            DelimKind::DoubleDollar => {
                if bytes[offset] == b'$'
                    && offset + 1 < bytes.len()
                    && bytes[offset + 1] == b'$'
                    && !is_escaped(source, offset)
                {
                    return Some((offset, 2));
                }
            }
            DelimKind::Paren => {
                if bytes[offset] == b'\\'
                    && offset + 1 < bytes.len()
                    && bytes[offset + 1] == b')'
                    && !is_escaped(source, offset)
                {
                    return Some((offset, 2));
                }
            }
            DelimKind::Bracket => {
                if bytes[offset] == b'\\'
                    && offset + 1 < bytes.len()
                    && bytes[offset + 1] == b']'
                    && !is_escaped(source, offset)
                {
                    return Some((offset, 2));
                }
            }
        }
        offset += 1;
    }
    None
}

pub fn split_latex_spans(source: &str) -> Vec<SpanPart> {
    let mut out = Vec::new();
    let mut emit_cursor = 0usize;
    let mut search_cursor = 0usize;
    while search_cursor < source.len() {
        let Some((open_idx, open_len, kind)) = find_next_delim(source, search_cursor) else {
            break;
        };
        let Some((close_idx, close_len)) = find_close_delim(source, open_idx, open_len, kind) else {
            search_cursor = open_idx + open_len;
            continue;
        };
        let raw_inner = &source[open_idx + open_len..close_idx];
        let trimmed = raw_inner.trim();
        if trimmed.is_empty() {
            search_cursor = close_idx + close_len;
            continue;
        }
        if open_idx > emit_cursor {
            out.push(SpanPart::Text(source[emit_cursor..open_idx].to_string()));
        }
        out.push(SpanPart::Formula {
            raw: source[open_idx..close_idx + close_len].to_string(),
            normalized: normalize_expression(trimmed),
            display: matches!(kind, DelimKind::DoubleDollar | DelimKind::Bracket),
        });
        emit_cursor = close_idx + close_len;
        search_cursor = emit_cursor;
    }
    if emit_cursor < source.len() {
        out.push(SpanPart::Text(source[emit_cursor..].to_string()));
    }
    out
}

fn fnv1a_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn cache_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("emacs-minder/latex");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".cache/emacs-minder/latex");
    }
    std::env::temp_dir().join("emacs-minder/latex")
}

pub fn parse_tex_metrics(stdout: &str) -> Option<LatexMetrics> {
    const SP_TO_CSS_PIXEL: f64 = 96.0 / (72.27 * 65536.0);
    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix("MINDER-METRICS:") {
            let parts: Vec<&str> = rest.trim().split(',').collect();
            if parts.len() == 3 {
                let wd: f64 = parts[0].trim().parse().ok()?;
                let ht: f64 = parts[1].trim().parse().ok()?;
                let dp: f64 = parts[2].trim().parse().ok()?;
                return Some(LatexMetrics {
                    width_px: (wd * SP_TO_CSS_PIXEL).max(4.0),
                    ascent_px: (ht * SP_TO_CSS_PIXEL).max(4.0),
                    descent_px: (dp * SP_TO_CSS_PIXEL).max(0.0),
                });
            }
        }
    }
    None
}

pub fn compile_latex_sync(expr: &str) -> Result<CompiledLatex, String> {
    let norm = normalize_expression(expr);
    let key = fnv1a_hash(&format!("v2:{norm}"));
    let cdir = cache_dir();
    let svg_cache = cdir.join(format!("{key}.svg"));
    let met_cache = cdir.join(format!("{key}.metrics"));

    if svg_cache.exists() && met_cache.exists() {
        if let (Ok(svg), Ok(mstr)) = (std::fs::read(&svg_cache), std::fs::read_to_string(&met_cache)) {
            let nums: Vec<f64> = mstr.split_whitespace().filter_map(|p| p.parse().ok()).collect();
            if nums.len() == 3 && !svg.is_empty() {
                return Ok(CompiledLatex {
                    svg: Arc::new(svg),
                    metrics: LatexMetrics {
                        width_px: nums[0],
                        ascent_px: nums[1],
                        descent_px: nums[2],
                    },
                });
            }
        }
    }

    let tmp = std::env::temp_dir().join(format!(
        "emacs-minder-tex-{}-{}",
        std::process::id(),
        key
    ));
    let _ = std::fs::create_dir_all(&tmp);
    let tex_path = tmp.join("formula.tex");
    let tex_src = format!(
        "\\documentclass[10pt]{{article}}\n\
         \\usepackage{{amsmath,amssymb,amsfonts,bm,cancel}}\n\
         \\pagestyle{{empty}}\n\
         \\begin{{document}}\n\
         \\setbox0=\\hbox{{\\(\\displaystyle {norm} \\)}}\n\
         \\typeout{{MINDER-METRICS:\\number\\wd0,\\number\\ht0,\\number\\dp0}}\n\
         \\box0\n\
         \\end{{document}}\n"
    );
    std::fs::write(&tex_path, tex_src).map_err(|e| format!("write tex: {e}"))?;

    let out = Command::new("latex")
        .arg("-interaction=nonstopmode")
        .arg("-halt-on-error")
        .arg("formula.tex")
        .current_dir(&tmp)
        .output()
        .map_err(|e| format!("spawn latex: {e}"))?;

    let stdout_str = String::from_utf8_lossy(&out.stdout);
    let metrics = parse_tex_metrics(&stdout_str);
    let dvi_path = tmp.join("formula.dvi");
    if !out.status.success() || !dvi_path.exists() {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(format!("latex failed: {stdout_str}"));
    }

    let svg_path = tmp.join("formula.svg");
    let dvisvgm = Command::new("dvisvgm")
        .arg("--no-fonts")
        .arg("--exact")
        .arg("--currentcolor")
        .arg("--zoom=1")
        .arg("-o")
        .arg("formula.svg")
        .arg("formula.dvi")
        .current_dir(&tmp)
        .output()
        .map_err(|e| format!("spawn dvisvgm: {e}"))?;

    if !dvisvgm.status.success() || !svg_path.exists() {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(format!(
            "dvisvgm failed: {}",
            String::from_utf8_lossy(&dvisvgm.stderr)
        ));
    }

    let svg = std::fs::read(&svg_path).map_err(|e| format!("read svg: {e}"))?;
    let _ = std::fs::remove_dir_all(&tmp);

    let metrics = metrics.unwrap_or(LatexMetrics {
        width_px: 24.0,
        ascent_px: 12.0,
        descent_px: 4.0,
    });

    if std::fs::create_dir_all(&cdir).is_ok() {
        let _ = std::fs::write(&svg_cache, &svg);
        let _ = std::fs::write(
            &met_cache,
            format!("{} {} {}", metrics.width_px, metrics.ascent_px, metrics.descent_px),
        );
    }

    Ok(CompiledLatex {
        svg: Arc::new(svg),
        metrics,
    })
}

struct WorkerState {
    cache: BTreeMap<String, Option<CompiledLatex>>,
    queued: HashSet<String>,
    queue: Vec<String>,
    generation: u64,
    active_workers: usize,
}

pub struct LatexCache {
    state: Arc<(Mutex<WorkerState>, Condvar)>,
}

impl Default for LatexCache {
    fn default() -> Self {
        Self::new()
    }
}

impl LatexCache {
    pub fn new() -> Self {
        let state = Arc::new((
            Mutex::new(WorkerState {
                cache: BTreeMap::new(),
                queued: HashSet::new(),
                queue: Vec::new(),
                generation: 0,
                active_workers: 0,
            }),
            Condvar::new(),
        ));

        for _ in 0..4 {
            let st = Arc::clone(&state);
            std::thread::spawn(move || loop {
                let expr = {
                    let (lock, cv) = &*st;
                    let mut guard = lock.lock().unwrap();
                    while guard.queue.is_empty() {
                        guard = cv.wait(guard).unwrap();
                    }
                    guard.active_workers += 1;
                    guard.queue.remove(0)
                };

                let res = compile_latex_sync(&expr).ok();

                let (lock, cv) = &*st;
                let mut guard = lock.lock().unwrap();
                guard.active_workers -= 1;
                guard.queued.remove(&expr);
                guard.cache.insert(expr, res);
                guard.generation += 1;
                cv.notify_all();
            });
        }

        Self { state }
    }

    pub fn generation(&self) -> u64 {
        self.state.0.lock().unwrap().generation
    }

    pub fn has_pending(&self) -> bool {
        let g = self.state.0.lock().unwrap();
        !g.queue.is_empty() || g.active_workers > 0
    }

    pub fn wait_idle(&self) {
        let (lock, cv) = &*self.state;
        let mut g = lock.lock().unwrap();
        while !g.queue.is_empty() || g.active_workers > 0 {
            g = cv.wait(g).unwrap();
        }
    }

    /// Look up compiled SVG+metrics or try fast disk cache hit; otherwise enqueue async compile.
    pub fn get_or_enqueue(&self, normalized_expr: &str) -> Option<CompiledLatex> {
        let (lock, cv) = &*self.state;
        {
            let guard = lock.lock().unwrap();
            if let Some(entry) = guard.cache.get(normalized_expr) {
                return entry.clone();
            }
        }

        // Fast disk-cache check before spawning latex
        let key = fnv1a_hash(&format!("v2:{normalized_expr}"));
        let cdir = cache_dir();
        let svg_cache = cdir.join(format!("{key}.svg"));
        let met_cache = cdir.join(format!("{key}.metrics"));
        if svg_cache.exists() && met_cache.exists() {
            if let (Ok(svg), Ok(mstr)) = (std::fs::read(&svg_cache), std::fs::read_to_string(&met_cache)) {
                let nums: Vec<f64> = mstr.split_whitespace().filter_map(|p| p.parse().ok()).collect();
                if nums.len() == 3 && !svg.is_empty() {
                    let compiled = CompiledLatex {
                        svg: Arc::new(svg),
                        metrics: LatexMetrics {
                            width_px: nums[0],
                            ascent_px: nums[1],
                            descent_px: nums[2],
                        },
                    };
                    let mut guard = lock.lock().unwrap();
                    guard.cache.insert(normalized_expr.to_string(), Some(compiled.clone()));
                    return Some(compiled);
                }
            }
        }

        let mut guard = lock.lock().unwrap();
        if let Some(entry) = guard.cache.get(normalized_expr) {
            return entry.clone();
        }
        if !guard.queued.contains(normalized_expr) {
            guard.queued.insert(normalized_expr.to_string());
            guard.queue.push(normalized_expr.to_string());
            cv.notify_one();
        }
        None
    }
}
