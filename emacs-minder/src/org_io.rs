use crate::model::*;
use std::collections::HashSet;
use std::path::Path;

const DEFAULT_TODO_KEYWORDS: &[&str] = &["TODO", "DONE", "FEEDBACK", "VERIFY", "CANCELED"];
const DONE_KEYWORDS: &[&str] = &["DONE", "CANCELED", "CANCELLED"];

fn is_image_ext(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".png")
        || lower.ends_with(".jpg")
        || lower.ends_with(".jpeg")
        || lower.ends_with(".svg")
        || lower.ends_with(".bmp")
        || lower.ends_with(".gif")
        || lower.ends_with(".webp")
}

fn parse_org_link(trimmed: &str) -> Option<(String, Option<String>)> {
    if !trimmed.starts_with("[[") || !trimmed.ends_with("]]") {
        return None;
    }
    let inner = &trimmed[2..trimmed.len() - 2];
    if inner.contains("][") {
        let mut parts = inner.splitn(2, "][");
        let target = parts.next()?.to_string();
        let desc = parts.next().map(|s| s.to_string());
        Some((target, desc))
    } else {
        Some((inner.to_string(), None))
    }
}

fn resolve_org_image_path(target: &str, org_dir: &Path) -> Option<String> {
    let raw = target
        .strip_prefix("file:")
        .or_else(|| target.strip_prefix("attachment:"))
        .unwrap_or(target);
    let p = Path::new(raw);
    let candidate = if p.is_absolute() {
        p.to_path_buf()
    } else {
        org_dir.join(p)
    };
    if is_image_ext(raw) && candidate.exists() {
        Some(candidate.to_string_lossy().into_owned())
    } else {
        None
    }
}

fn parse_heading_line(
    line: &str,
    todo_keywords: &HashSet<String>,
) -> Option<(usize, Option<String>, Option<String>, String, Vec<String>)> {
    let stars = line.bytes().take_while(|&b| b == b'*').count();
    if stars == 0 || line.as_bytes().get(stars) != Some(&b' ') {
        return None;
    }
    let mut rest = line[stars + 1..].trim();

    // Optional TODO keyword
    let mut todo = None;
    if let Some((first, tail)) = rest.split_once(char::is_whitespace) {
        if todo_keywords.contains(first) {
            todo = Some(first.to_string());
            rest = tail.trim_start();
        }
    } else if todo_keywords.contains(rest) {
        todo = Some(rest.to_string());
        rest = "";
    }

    // Optional priority [#A]
    let mut priority = None;
    if rest.starts_with("[#") {
        if let Some(end_idx) = rest.find(']') {
            if end_idx >= 3 && end_idx <= 5 {
                priority = Some(rest[2..end_idx].to_string());
                rest = rest[end_idx + 1..].trim_start();
            }
        }
    }

    // Optional trailing :tag1:tag2:
    let mut tags = Vec::new();
    let trimmed_end = rest.trim_end();
    if trimmed_end.ends_with(':') {
        if let Some(space_idx) = trimmed_end.rfind(|c: char| c.is_whitespace()) {
            let candidate = &trimmed_end[space_idx + 1..];
            if candidate.starts_with(':') && candidate.len() >= 3 {
                let parts: Vec<&str> = candidate
                    .trim_matches(':')
                    .split(':')
                    .filter(|t| !t.is_empty())
                    .collect();
                if !parts.is_empty()
                    && parts
                        .iter()
                        .all(|t| t.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '@' || c == '-'))
                {
                    tags = parts.into_iter().map(|s| s.to_string()).collect();
                    rest = trimmed_end[..space_idx].trim_end();
                }
            }
        } else if trimmed_end.starts_with(':') && trimmed_end.len() >= 3 {
            let parts: Vec<&str> = trimmed_end
                .trim_matches(':')
                .split(':')
                .filter(|t| !t.is_empty())
                .collect();
            if !parts.is_empty() {
                tags = parts.into_iter().map(|s| s.to_string()).collect();
                rest = "";
            }
        }
    }

    Some((stars, todo, priority, rest.trim().to_string(), tags))
}

fn parse_table_block(lines: &[&str]) -> NodeTable {
    let mut rows_data: Vec<(Vec<String>, bool)> = Vec::new();
    let mut next_highlighted = false;
    let mut seen_sep = false;

    for raw in lines {
        let t = raw.trim();
        if t.starts_with("|-") {
            seen_sep = true;
            if let Some(prev) = rows_data.last_mut() {
                prev.1 = true;
            }
            continue;
        }
        let inner = t.strip_prefix('|').unwrap_or(t);
        let inner = inner.strip_suffix('|').unwrap_or(inner);
        let cols: Vec<String> = inner.split('|').map(|c| c.trim().to_string()).collect();
        rows_data.push((cols, next_highlighted));
        next_highlighted = false;
    }

    if !seen_sep && !rows_data.is_empty() {
        // Leave default highlighting false when no header rule exists
    }

    let columns = rows_data.iter().map(|(r, _)| r.len()).max().unwrap_or(1).max(1);
    let rows = rows_data.len().max(1);
    let mut cells = Vec::new();
    for (r_idx, (cols, hi)) in rows_data.into_iter().enumerate() {
        for (c_idx, text) in cols.into_iter().enumerate() {
            cells.push(TableCell {
                row: r_idx,
                col: c_idx,
                rowspan: 1,
                colspan: 1,
                text,
                align: "left".into(),
                highlighted: hi,
                bold: hi,
                italic: false,
                underline: false,
                strikethrough: false,
            });
        }
    }
    NodeTable {
        rows,
        columns,
        cells,
    }
}

fn parse_list_item(line: &str) -> Option<(usize, Option<bool>, String)> {
    let indent = line.bytes().take_while(|&b| b == b' ').count();
    let rest = &line[indent..];
    if let Some(after_dash) = rest.strip_prefix("- ").or_else(|| rest.strip_prefix("+ ")) {
        let t = after_dash.trim_start();
        if let Some(after_box) = t.strip_prefix("[ ] ") {
            return Some((indent, Some(false), after_box.trim().to_string()));
        }
        if let Some(after_box) = t.strip_prefix("[X] ").or_else(|| t.strip_prefix("[x] ")) {
            return Some((indent, Some(true), after_box.trim().to_string()));
        }
        return Some((indent, None, after_dash.trim().to_string()));
    }
    None
}

fn parse_heading_body(
    body_lines: &[String],
    doc: &mut MapDocument,
    node_id: i32,
    org_dir: &Path,
) {
    let mut i = 0usize;
    let mut props: Vec<(String, String)> = Vec::new();
    let mut note_lines: Vec<String> = Vec::new();

    // Parse optional leading :PROPERTIES: drawer
    while i < body_lines.len() && body_lines[i].trim().is_empty() {
        i += 1;
    }
    if i < body_lines.len() && body_lines[i].trim().eq_ignore_ascii_case(":PROPERTIES:") {
        i += 1;
        while i < body_lines.len() {
            let t = body_lines[i].trim();
            i += 1;
            if t.eq_ignore_ascii_case(":END:") {
                break;
            }
            if let Some(stripped) = t.strip_prefix(':') {
                if let Some((k, v)) = stripped.split_once(':') {
                    props.push((k.trim().to_string(), v.trim().to_string()));
                }
            }
        }
    }

    // Walk remaining body lines: extract first Org table, image link, list items, and note prose
    let mut list_stack: Vec<(usize, i32)> = Vec::new();
    let mut extracted_table: Option<NodeTable> = None;
    let mut extracted_image: Option<NodeImageRef> = None;
    let mut extracted_url: Option<String> = None;

    while i < body_lines.len() {
        let line = &body_lines[i];
        let t = line.trim();

        // Org table block
        if t.starts_with('|') && extracted_table.is_none() {
            let start = i;
            while i < body_lines.len() && body_lines[i].trim().starts_with('|') {
                i += 1;
            }
            let slice: Vec<&str> = body_lines[start..i].iter().map(|s| s.as_str()).collect();
            extracted_table = Some(parse_table_block(&slice));
            continue;
        }

        // Standalone link / image link
        if let Some((target, _desc)) = parse_org_link(t) {
            if extracted_image.is_none() {
                if let Some(img_path) = resolve_org_image_path(&target, org_dir) {
                    if let Ok(img_id) = doc.add_image_from_file(&img_path) {
                        extracted_image = Some(NodeImageRef {
                            id: img_id,
                            crop_x: 0,
                            crop_y: 0,
                            crop_w: 0,
                            crop_h: 0,
                            size: 220.0,
                        });
                        i += 1;
                        continue;
                    }
                }
            }
            if extracted_url.is_none() && (target.starts_with("http://") || target.starts_with("https://")) {
                extracted_url = Some(target);
            }
        }

        // Indented list items become child list nodes on the mind map!
        if let Some((indent, checkbox, text)) = parse_list_item(line) {
            while let Some(&(top_indent, _)) = list_stack.last() {
                if indent <= top_indent {
                    list_stack.pop();
                } else {
                    break;
                }
            }
            let parent_for_item = list_stack.last().map(|&(_, id)| id).unwrap_or(node_id);
            let cid = doc.alloc_id();
            let mut item_node = Node::new(cid, text);
            item_node.parent = Some(parent_for_item);
            item_node.is_org_list_item = true;
            item_node.style = doc.global_style.clone();
            item_node.maxwidth = 340.0;
            item_node.style.nodewidth = 340.0;
            if let Some(done) = checkbox {
                item_node.task_enabled = true;
                item_node.task_done = done;
            }
            doc.nodes.insert(cid, item_node);
            if let Some(p) = doc.nodes.get_mut(&parent_for_item) {
                p.children.push(cid);
            }
            list_stack.push((indent, cid));
            i += 1;
            continue;
        }

        // Preserve non-list prose/blocks (like \begin{align*}...\end{align*})
        if !t.is_empty() || !note_lines.is_empty() {
            note_lines.push(line.clone());
        }
        i += 1;
    }

    while note_lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        note_lines.pop();
    }

    if let Some(n) = doc.nodes.get_mut(&node_id) {
        n.org_properties = props;
        n.table = extracted_table;
        n.image = extracted_image;
        if n.link.is_none() {
            n.link = extracted_url;
        }
        n.note = note_lines.join("\n");
    }
}

pub fn load_org_str(content: &str, file_path: Option<&str>) -> Result<MapDocument, String> {
    let normalized = content.replace("\r\n", "\n").replace('\r', "\n");
    let mut doc = MapDocument::new_empty();
    doc.root_ids.clear();
    doc.nodes.clear();
    doc.source_format = SourceFormat::Org;
    doc.file_path = file_path.map(|s| s.to_string());
    doc.global_style.nodewidth = 280.0;

    let org_dir = file_path
        .and_then(|p| Path::new(p).parent())
        .unwrap_or_else(|| Path::new("."));

    let mut todo_keywords: HashSet<String> = DEFAULT_TODO_KEYWORDS
        .iter()
        .map(|s| s.to_string())
        .collect();
    let mut title_from_preamble: Option<String> = None;
    let mut preamble = Vec::new();
    let mut raw_headings: Vec<(usize, Option<String>, Option<String>, String, Vec<String>, Vec<String>)> =
        Vec::new();

    let mut in_preamble = true;
    for raw_line in normalized.lines() {
        if let Some((lvl, todo, prio, title, tags)) = parse_heading_line(raw_line, &todo_keywords) {
            in_preamble = false;
            raw_headings.push((lvl, todo, prio, title, tags, Vec::new()));
            continue;
        }
        if in_preamble {
            let trimmed = raw_line.trim();
            if let Some(rest) = trimmed
                .strip_prefix("#+TITLE:")
                .or_else(|| trimmed.strip_prefix("#+title:"))
            {
                let t = rest.trim().to_string();
                if !t.is_empty() {
                    title_from_preamble = Some(t);
                }
            }
            if let Some(rest) = trimmed
                .strip_prefix("#+TODO:")
                .or_else(|| trimmed.strip_prefix("#+todo:"))
                .or_else(|| trimmed.strip_prefix("#+SEQ_TODO:"))
            {
                for tok in rest.split_whitespace() {
                    if tok != "|" {
                        let clean = tok.split('(').next().unwrap_or(tok);
                        if !clean.is_empty() {
                            todo_keywords.insert(clean.to_string());
                        }
                    }
                }
            }
            preamble.push(raw_line.to_string());
        } else if let Some(last) = raw_headings.last_mut() {
            last.5.push(raw_line.to_string());
        }
    }

    doc.org_preamble = preamble;

    // Count level-1 headings to decide whether #+TITLE becomes a virtual root topic
    let min_level = raw_headings.iter().map(|h| h.0).min().unwrap_or(1);
    let top_count = raw_headings.iter().filter(|h| h.0 == min_level).count();

    let mut stack: Vec<(usize, i32)> = Vec::new();
    if let Some(ref title) = title_from_preamble {
        if top_count > 1 || raw_headings.is_empty() {
            let rid = doc.alloc_id();
            let mut root = Node::new(rid, title.clone());
            root.is_org_title_root = true;
            root.style = doc.global_style.clone();
            root.style.nodeborder = NodeBorder::Rounded;
            root.style.nodefont = "Sans Bold 13".into();
            doc.nodes.insert(rid, root);
            doc.root_ids.push(rid);
            stack.push((0, rid));
        }
    }

    if raw_headings.is_empty() && doc.root_ids.is_empty() {
        let rid = doc.alloc_id();
        let label = file_path
            .and_then(|p| Path::new(p).file_stem())
            .and_then(|s| s.to_str())
            .unwrap_or("Org Mind Map")
            .to_string();
        let mut root = Node::new(rid, label);
        root.style = doc.global_style.clone();
        root.style.nodeborder = NodeBorder::Rounded;
        doc.nodes.insert(rid, root);
        doc.root_ids.push(rid);
    }

    for (level, todo, prio, title, tags, body_lines) in raw_headings {
        while let Some(&(top_lvl, _)) = stack.last() {
            if level <= top_lvl {
                stack.pop();
            } else {
                break;
            }
        }
        let parent_id = stack.last().map(|&(_, id)| id);
        let nid = doc.alloc_id();
        let mut node = Node::new(nid, title);
        node.parent = parent_id;
        node.style = doc.global_style.clone();
        node.maxwidth = 280.0;
        node.tags = tags;
        node.priority = prio;
        if let Some(kw) = todo {
            node.task_enabled = true;
            node.task_done = DONE_KEYWORDS.contains(&kw.as_str());
            node.todo_keyword = Some(kw);
        }

        // Assign distinct branch colors on main top-level branches under root (or root children)
        let is_main_branch = match parent_id {
            None => true,
            Some(pid) => doc.nodes.get(&pid).map(|p| p.parent.is_none()).unwrap_or(false),
        };
        if is_main_branch {
            node.color = Some(doc.next_branch_color());
        } else if parent_id.is_some() && parent_id == doc.root_ids.first().copied() {
            node.color = Some(doc.next_branch_color());
        }

        if parent_id.is_none() {
            node.style.nodeborder = NodeBorder::Rounded;
            node.style.nodefont = "Sans Bold 13".into();
        }

        doc.nodes.insert(nid, node);
        if let Some(pid) = parent_id {
            if let Some(p) = doc.nodes.get_mut(&pid) {
                p.children.push(nid);
            }
        } else {
            doc.root_ids.push(nid);
        }

        parse_heading_body(&body_lines, &mut doc, nid, org_dir);
        stack.push((level, nid));
    }

    // Balance sides cleanly across children of root nodes
    let root_ids = doc.root_ids.clone();
    for rid in root_ids {
        let children = doc.nodes.get(&rid).map(|n| n.children.clone()).unwrap_or_default();
        let half = (children.len() + 1) / 2;
        for (idx, cid) in children.into_iter().enumerate() {
            let side = if idx < half { NodeSide::Right } else { NodeSide::Left };
            set_subtree_side(&mut doc, cid, side);
        }
    }

    doc.selected_node = doc.root_ids.first().copied();
    doc.layout_dirty = true;
    doc.dirty = false;
    Ok(doc)
}

fn set_subtree_side(doc: &mut MapDocument, id: i32, side: NodeSide) {
    let children = if let Some(n) = doc.nodes.get_mut(&id) {
        n.side = side;
        n.children.clone()
    } else {
        return;
    };
    for cid in children {
        set_subtree_side(doc, cid, side);
    }
}

pub fn load_org_file(path: &str) -> Result<MapDocument, String> {
    let content = std::fs::read_to_string(path).map_err(|e| format!("Read {path}: {e}"))?;
    load_org_str(&content, Some(path))
}

fn serialize_table(table: &NodeTable, out: &mut String) {
    let mut grid = vec![vec![String::new(); table.columns.max(1)]; table.rows.max(1)];
    let mut row_hi = vec![false; table.rows.max(1)];
    for c in &table.cells {
        if c.row < grid.len() && c.col < grid[0].len() {
            grid[c.row][c.col] = c.text.replace('\n', " ");
            if c.highlighted {
                row_hi[c.row] = true;
            }
        }
    }
    let mut col_w = vec![1usize; table.columns.max(1)];
    for row in &grid {
        for (ci, val) in row.iter().enumerate() {
            col_w[ci] = col_w[ci].max(val.chars().count());
        }
    }
    for (ri, row) in grid.iter().enumerate() {
        out.push('|');
        for (ci, val) in row.iter().enumerate() {
            let pad = col_w[ci].saturating_sub(val.chars().count());
            out.push(' ');
            out.push_str(val);
            for _ in 0..pad {
                out.push(' ');
            }
            out.push_str(" |");
        }
        out.push('\n');
        if row_hi[ri] && ri + 1 < grid.len() {
            out.push('|');
            for (ci, w) in col_w.iter().enumerate() {
                for _ in 0..(*w + 2) {
                    out.push('-');
                }
                out.push(if ci + 1 == col_w.len() { '|' } else { '+' });
            }
            out.push('\n');
        }
    }
}

fn write_list_item(out: &mut String, doc: &MapDocument, id: i32, indent: usize) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };
    let pad = " ".repeat(indent);
    if n.task_enabled {
        let mark = if n.task_done { 'X' } else { ' ' };
        out.push_str(&format!("{pad}- [{mark}] {}\n", n.text));
    } else {
        out.push_str(&format!("{pad}- {}\n", n.text));
    }
    for &cid in &n.children {
        if doc.nodes.get(&cid).map(|c| c.is_org_list_item).unwrap_or(false) {
            write_list_item(out, doc, cid, indent + 2);
        }
    }
}

fn write_org_node(
    out: &mut String,
    doc: &MapDocument,
    id: i32,
    level: usize,
    base_dir: &Path,
) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };

    if n.is_org_list_item {
        write_list_item(out, doc, id, 2);
        return;
    }

    for _ in 0..level {
        out.push('*');
    }
    out.push(' ');

    if let Some(ref kw) = n.todo_keyword {
        out.push_str(kw);
        out.push(' ');
    } else if n.task_enabled {
        out.push_str(if n.task_done { "DONE " } else { "TODO " });
    }
    if let Some(ref prio) = n.priority {
        out.push_str(&format!("[#{prio}] "));
    }
    out.push_str(&n.text.replace('\n', " "));
    if !n.tags.is_empty() {
        out.push_str(" :");
        out.push_str(&n.tags.join(":"));
        out.push(':');
    }
    out.push('\n');

    if !n.org_properties.is_empty() {
        out.push_str(":PROPERTIES:\n");
        for (k, v) in &n.org_properties {
            out.push_str(&format!(":{k}: {v}\n"));
        }
        out.push_str(":END:\n");
    }

    // List item children come right inside this heading body
    let list_children: Vec<i32> = n
        .children
        .iter()
        .copied()
        .filter(|cid| doc.nodes.get(cid).map(|c| c.is_org_list_item).unwrap_or(false))
        .collect();
    if !list_children.is_empty() {
        for cid in list_children {
            write_list_item(out, doc, cid, 2);
        }
    }

    if let Some(ref img) = n.image {
        if let Some(asset) = doc.images.get(&img.id) {
            let link_target = asset
                .uri
                .strip_prefix("file://")
                .map(|p| {
                    if let Ok(rel) = Path::new(p).strip_prefix(base_dir) {
                        rel.to_string_lossy().into_owned()
                    } else {
                        p.to_string()
                    }
                })
                .unwrap_or_else(|| format!("img{:06x}{}", asset.id, asset.ext));
            out.push_str(&format!("[[file:{link_target}]]\n"));
        }
    }

    if let Some(ref url) = n.link {
        if !n.note.contains(url) {
            out.push_str(&format!("[[{url}]]\n"));
        }
    }

    if let Some(ref tbl) = n.table {
        serialize_table(tbl, out);
    }

    if !n.note.trim().is_empty() {
        out.push_str(n.note.trim_end());
        out.push('\n');
    }

    if !n.children.is_empty() {
        out.push('\n');
    }

    for &cid in &n.children {
        if !doc.nodes.get(&cid).map(|c| c.is_org_list_item).unwrap_or(false) {
            write_org_node(out, doc, cid, level + 1, base_dir);
        }
    }
}

pub fn serialize_org(doc: &MapDocument, dest_path: Option<&str>) -> String {
    let mut out = String::with_capacity(8192);
    let base_dir = dest_path
        .or(doc.file_path.as_deref())
        .and_then(|p| Path::new(p).parent())
        .unwrap_or_else(|| Path::new("."));

    let title_root = if doc.root_ids.len() == 1 {
        doc.root_ids
            .first()
            .and_then(|id| doc.nodes.get(id))
            .filter(|n| n.is_org_title_root)
    } else {
        None
    };

    if !doc.org_preamble.is_empty() {
        let mut updated_title = false;
        for line in &doc.org_preamble {
            if let Some(tr) = title_root {
                let trim = line.trim_start();
                if trim.starts_with("#+TITLE:") || trim.starts_with("#+title:") {
                    out.push_str(&format!("#+TITLE: {}\n", tr.text.replace('\n', " ")));
                    updated_title = true;
                    continue;
                }
            }
            out.push_str(line);
            out.push('\n');
        }
        if !updated_title {
            if let Some(tr) = title_root {
                out.push_str(&format!("#+TITLE: {}\n", tr.text.replace('\n', " ")));
            }
        }
    } else if let Some(tr) = title_root {
        out.push_str(&format!("#+TITLE: {}\n\n", tr.text.replace('\n', " ")));
    }

    if let Some(tr) = title_root {
        if !tr.note.trim().is_empty() {
            out.push_str(tr.note.trim_end());
            out.push_str("\n\n");
        }
        for &cid in &tr.children {
            if doc.nodes.get(&cid).map(|c| c.is_org_list_item).unwrap_or(false) {
                write_list_item(&mut out, doc, cid, 0);
            } else {
                write_org_node(&mut out, doc, cid, 1, base_dir);
            }
        }
    } else {
        for &rid in &doc.root_ids {
            write_org_node(&mut out, doc, rid, 1, base_dir);
        }
    }

    out
}

pub fn save_org_file(doc: &MapDocument, path: &str) -> Result<(), String> {
    let text = serialize_org(doc, Some(path));
    std::fs::write(path, text.as_bytes()).map_err(|e| format!("Write {path}: {e}"))
}
