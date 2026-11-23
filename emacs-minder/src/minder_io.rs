use crate::model::*;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use tar::{Archive, Builder, Header};

fn xml_escape_attr(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\n' => out.push_str("&#10;"),
            '\r' => {}
            c => out.push(c),
        }
    }
    out
}

fn xml_escape_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\r' => {}
            c => out.push(c),
        }
    }
    out
}

fn parse_bool(s: Option<&str>, default: bool) -> bool {
    match s {
        Some(v) => v.eq_ignore_ascii_case("true") || v == "1",
        None => default,
    }
}

fn parse_f64(s: Option<&str>, default: f64) -> f64 {
    s.and_then(|v| v.trim().parse::<f64>().ok()).unwrap_or(default)
}

fn parse_i32(s: Option<&str>, default: i32) -> i32 {
    s.and_then(|v| v.trim().parse::<i32>().ok()).unwrap_or(default)
}

fn parse_style_attrs(node: roxmltree::Node, base: &NodeStyle) -> NodeStyle {
    let mut s = base.clone();
    if let Some(v) = node.attribute("branchmargin") {
        s.branchmargin = v.parse().unwrap_or(s.branchmargin);
    }
    if let Some(v) = node.attribute("branchradius") {
        s.branchradius = v.parse().unwrap_or(s.branchradius);
    }
    if let Some(v) = node.attribute("linktype") {
        s.linktype = LinkType::from_str(v);
    }
    if let Some(v) = node.attribute("linkwidth") {
        s.linkwidth = v.parse().unwrap_or(s.linkwidth);
    }
    if node.attribute("linkarrow").is_some() {
        s.linkarrow = parse_bool(node.attribute("linkarrow"), s.linkarrow);
    }
    if let Some(v) = node.attribute("linkarrowsize") {
        s.linkarrowsize = v.parse().unwrap_or(s.linkarrowsize);
    }
    if let Some(v) = node.attribute("linkdash") {
        s.linkdash = v.to_string();
    }
    if let Some(v) = node.attribute("nodeborder") {
        s.nodeborder = NodeBorder::from_str(v);
    }
    if let Some(v) = node.attribute("nodeborderwidth") {
        s.nodeborderwidth = v.parse().unwrap_or(s.nodeborderwidth);
    }
    if node.attribute("nodefill").is_some() {
        s.nodefill = parse_bool(node.attribute("nodefill"), s.nodefill);
    }
    if let Some(v) = node.attribute("nodemargin") {
        s.nodemargin = v.parse().unwrap_or(s.nodemargin);
    }
    if let Some(v) = node.attribute("nodepadding") {
        s.nodepadding = v.parse().unwrap_or(s.nodepadding);
    }
    if let Some(v) = node.attribute("nodefont") {
        s.nodefont = v.to_string();
    }
    if let Some(v) = node.attribute("nodetextalign") {
        s.nodetextalign = v.to_string();
    }
    if let Some(v) = node.attribute("nodewidth") {
        s.nodewidth = v.parse().unwrap_or(s.nodewidth);
    }
    if node.attribute("nodemarkup").is_some() {
        s.nodemarkup = parse_bool(node.attribute("nodemarkup"), s.nodemarkup);
    }
    if let Some(v) = node.attribute("connectiondash") {
        s.connectiondash = v.to_string();
    }
    if let Some(v) = node.attribute("connectionlwidth") {
        s.connectionlwidth = v.parse().unwrap_or(s.connectionlwidth);
    }
    if let Some(v) = node.attribute("connectionarrow") {
        s.connectionarrow = v.to_string();
    }
    if let Some(v) = node.attribute("connectionpadding") {
        s.connectionpadding = v.parse().unwrap_or(s.connectionpadding);
    }
    if let Some(v) = node.attribute("connectionfont") {
        s.connectionfont = v.to_string();
    }
    if let Some(v) = node.attribute("connectiontwidth") {
        s.connectiontwidth = v.parse().unwrap_or(s.connectiontwidth);
    }
    if let Some(v) = node.attribute("calloutfont") {
        s.calloutfont = v.to_string();
    }
    if let Some(v) = node.attribute("calloutpadding") {
        s.calloutpadding = v.parse().unwrap_or(s.calloutpadding);
    }
    if let Some(v) = node.attribute("calloutptrwidth") {
        s.calloutptrwidth = v.parse().unwrap_or(s.calloutptrwidth);
    }
    if let Some(v) = node.attribute("calloutptrlength") {
        s.calloutptrlength = v.parse().unwrap_or(s.calloutptrlength);
    }
    s
}

fn extract_text_block(xml_node: roxmltree::Node) -> String {
    let mut parts = Vec::new();
    for ch in xml_node.children() {
        if ch.is_element() && ch.tag_name().name() == "text" {
            if let Some(data) = ch.attribute("data") {
                parts.push(data.to_string());
            } else if let Some(t) = ch.text() {
                parts.push(t.to_string());
            }
        }
    }
    if !parts.is_empty() {
        return parts.join("\n");
    }
    if let Some(data) = xml_node.attribute("data") {
        return data.to_string();
    }
    xml_node.text().unwrap_or("").to_string()
}

fn parse_node_xml(
    xml_node: roxmltree::Node,
    parent_id: Option<i32>,
    doc: &mut MapDocument,
) -> i32 {
    let id_raw = xml_node
        .attribute("id")
        .and_then(|s| s.parse::<i32>().ok());
    let id = match id_raw {
        Some(n) if !doc.nodes.contains_key(&n) => n,
        _ => doc.alloc_id(),
    };
    if id >= doc.next_id {
        doc.next_id = id + 1;
    }

    let mut node = Node::new(id, String::new());
    node.parent = parent_id;
    node.style = doc.global_style.clone();
    node.posx = parse_f64(xml_node.attribute("posx"), 0.0);
    node.posy = parse_f64(xml_node.attribute("posy"), 0.0);
    node.width = parse_f64(xml_node.attribute("width"), 80.0);
    node.height = parse_f64(xml_node.attribute("height"), 36.0);
    node.treesize = parse_f64(xml_node.attribute("treesize"), node.height);
    node.side = NodeSide::from_str(xml_node.attribute("side").unwrap_or("right"));
    node.fold = parse_bool(xml_node.attribute("fold"), false);
    node.sequence = parse_bool(xml_node.attribute("sequence"), false);
    node.group = parse_bool(xml_node.attribute("group"), false);
    node.summarized = parse_bool(xml_node.attribute("summarized"), false);
    node.color = xml_node.attribute("color").and_then(Rgba::from_hex_or_name);
    node.colorroot = parse_bool(xml_node.attribute("colorroot"), false);
    node.layout = LayoutKind::from_str(xml_node.attribute("layout").unwrap_or("Horizontal"));
    node.sticker = xml_node.attribute("sticker").map(|s| s.to_string());
    node.link = xml_node
        .attribute("link")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if let Some(task_str) = xml_node.attribute("task") {
        let lower = task_str.to_ascii_lowercase();
        if lower == "done" || lower == "1" || lower == "1.0" {
            node.task_enabled = true;
            node.task_done = true;
        } else if lower == "doing" || lower == "true" || lower == "0" {
            node.task_enabled = true;
            node.task_done = false;
        }
    }
    if let Some(tcount) = xml_node.attribute("taskcount") {
        if let Ok(tc) = tcount.parse::<i32>() {
            if tc > 0 {
                node.task_enabled = true;
                let tdone = xml_node
                    .attribute("taskdone")
                    .and_then(|s| s.parse::<i32>().ok())
                    .unwrap_or(0);
                node.task_done = tdone >= tc;
            }
        }
    }

    let mut child_xml_lists = Vec::new();

    for ch in xml_node.children().filter(|c| c.is_element()) {
        match ch.tag_name().name() {
            "style" => {
                node.style = parse_style_attrs(ch, &node.style);
            }
            "nodename" => {
                node.maxwidth = parse_f64(ch.attribute("maxwidth"), node.style.nodewidth);
                node.text = extract_text_block(ch);
            }
            "nodenote" => {
                node.note = extract_text_block(ch);
            }
            "nodeimage" => {
                let img_id = parse_i32(ch.attribute("id"), -1);
                if img_id >= 0 {
                    node.image = Some(NodeImageRef {
                        id: img_id,
                        crop_x: parse_i32(ch.attribute("x"), 0),
                        crop_y: parse_i32(ch.attribute("y"), 0),
                        crop_w: parse_i32(ch.attribute("w"), 0),
                        crop_h: parse_i32(ch.attribute("h"), 0),
                        size: parse_f64(ch.attribute("size"), 200.0).max(20.0),
                    });
                }
            }
            "nodetable" => {
                let rows = ch
                    .attribute("rows")
                    .and_then(|s| s.parse::<usize>().ok())
                    .unwrap_or(1);
                let columns = ch
                    .attribute("columns")
                    .and_then(|s| s.parse::<usize>().ok())
                    .unwrap_or(1);
                let mut cells = Vec::new();
                for cell in ch.children().filter(|c| c.is_element() && c.tag_name().name() == "cell")
                {
                    cells.push(TableCell {
                        row: cell.attribute("row").and_then(|s| s.parse().ok()).unwrap_or(0),
                        col: cell.attribute("column").and_then(|s| s.parse().ok()).unwrap_or(0),
                        rowspan: cell.attribute("rowspan").and_then(|s| s.parse().ok()).unwrap_or(1),
                        colspan: cell.attribute("colspan").and_then(|s| s.parse().ok()).unwrap_or(1),
                        text: cell.attribute("text").unwrap_or("").to_string(),
                        align: cell.attribute("align").unwrap_or("left").to_string(),
                        highlighted: parse_bool(cell.attribute("highlighted"), false),
                        bold: parse_bool(cell.attribute("bold"), false),
                        italic: parse_bool(cell.attribute("italic"), false),
                        underline: parse_bool(cell.attribute("underline"), false),
                        strikethrough: parse_bool(cell.attribute("strikethrough"), false),
                    });
                }
                node.table = Some(NodeTable {
                    rows,
                    columns,
                    cells,
                });
            }
            "nodelink" => {
                let lid = parse_i32(ch.attribute("id"), -1);
                let url = ch.attribute("url").unwrap_or("").to_string();
                let doc_name = ch.attribute("doc").unwrap_or("").to_string();
                if node.link.is_none() && !url.is_empty() {
                    node.link = Some(url.clone());
                }
                node.node_link = Some(NodeLink {
                    id: lid,
                    doc: doc_name,
                    url,
                });
            }
            "taglist" => {
                if let Some(list) = ch.attribute("list") {
                    for t in list.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()) {
                        node.tags.push(t.to_string());
                    }
                }
            }
            "callout" => {
                let text = extract_text_block(ch);
                let padding = ch
                    .children()
                    .find(|c| c.is_element() && c.tag_name().name() == "style")
                    .and_then(|st| st.attribute("calloutpadding"))
                    .and_then(|s| s.parse::<f64>().ok())
                    .unwrap_or(5.0);
                node.callout = Some(Callout { text, padding });
            }
            "nodes" => {
                for cnode in ch.children().filter(|c| c.is_element() && c.tag_name().name() == "node")
                {
                    child_xml_lists.push(cnode);
                }
            }
            _ => {}
        }
    }

    doc.nodes.insert(id, node);

    let mut children_ids = Vec::with_capacity(child_xml_lists.len());
    for cnode in child_xml_lists {
        let cid = parse_node_xml(cnode, Some(id), doc);
        children_ids.push(cid);
    }
    if let Some(n) = doc.nodes.get_mut(&id) {
        n.children = children_ids;
    }
    id
}

pub fn load_minder_bytes(bytes: &[u8], file_path: Option<&str>) -> Result<MapDocument, String> {
    let mut doc = MapDocument::new_empty();
    doc.root_ids.clear();
    doc.nodes.clear();
    doc.file_path = file_path.map(|s| s.to_string());

    let mut extracted_imgs: BTreeMap<i32, (String, Vec<u8>)> = BTreeMap::new();
    let xml_str: String;

    if bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        doc.source_format = SourceFormat::MinderTarGz;
        let gz = GzDecoder::new(bytes);
        let mut archive = Archive::new(gz);
        let mut found_xml = None;
        let entries = archive
            .entries()
            .map_err(|e| format!("Failed to read .minder tar.gz entries: {e}"))?;
        for entry_res in entries {
            let mut entry = entry_res.map_err(|e| format!("Tar entry error: {e}"))?;
            let path_str = entry
                .path()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let fname = std::path::Path::new(&path_str)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            let mut data = Vec::new();
            entry
                .read_to_end(&mut data)
                .map_err(|e| format!("Read tar entry {path_str}: {e}"))?;
            if fname == "map.xml" {
                found_xml = Some(
                    String::from_utf8(data).map_err(|e| format!("map.xml UTF-8 error: {e}"))?,
                );
            } else if let Some(rest) = fname.strip_prefix("img") {
                let stem_end = rest.find('.').unwrap_or(rest.len());
                let hex_part = &rest[..stem_end];
                let ext = &rest[stem_end..];
                if let Ok(img_id) = i32::from_str_radix(hex_part, 16) {
                    if !data.is_empty() {
                        extracted_imgs.insert(img_id, (ext.to_string(), data));
                    }
                }
            }
        }
        xml_str = found_xml.ok_or_else(|| "Archive .minder does not contain map.xml".to_string())?;
    } else {
        doc.source_format = SourceFormat::MinderXml;
        xml_str = String::from_utf8(bytes.to_vec())
            .map_err(|e| format!("XML .minder UTF-8 error: {e}"))?;
    }

    let xml = roxmltree::Document::parse(&xml_str)
        .map_err(|e| format!("Failed to parse Minder XML: {e}"))?;
    let root = xml.root_element();
    if root.tag_name().name() != "minder" {
        return Err(format!(
            "Expected <minder> root element, got <{}>",
            root.tag_name().name()
        ));
    }

    doc.version = root.attribute("version").unwrap_or("2.0.9").to_string();
    doc.etag = root.attribute("etag").unwrap_or("0").to_string();
    doc.parent_etag = root.attribute("parent-etag").unwrap_or("").to_string();

    for child in root.children().filter(|c| c.is_element()) {
        match child.tag_name().name() {
            "theme" => {
                let name = child.attribute("name").unwrap_or("default");
                doc.theme_name = name.to_string();
                doc.theme = ThemePalette::by_name(name);
            }
            "global-style" => {
                doc.global_style = parse_style_attrs(child, &doc.global_style);
            }
            "styles" => {
                for st in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "style")
                {
                    let parsed = parse_style_attrs(st, &doc.global_style);
                    if st.attribute("level") == Some("0") {
                        doc.global_style = parsed.clone();
                    }
                    doc.level_styles.push(parsed);
                }
            }
            "drawarea" => {
                doc.origin_x = parse_f64(child.attribute("x"), 0.0);
                doc.origin_y = parse_f64(child.attribute("y"), 0.0);
                doc.scale = parse_f64(child.attribute("scale"), 1.0).clamp(0.1, 8.0);
            }
            "images" => {
                for img in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "image")
                {
                    let id = parse_i32(img.attribute("id"), -1);
                    if id < 0 {
                        continue;
                    }
                    if id >= doc.next_image_id {
                        doc.next_image_id = id + 1;
                    }
                    let uri = img.attribute("uri").unwrap_or("").to_string();
                    let ext = img.attribute("ext").unwrap_or(".png").to_string();
                    let (final_ext, data) = if let Some((ex_ext, ex_data)) = extracted_imgs.remove(&id)
                    {
                        (if ex_ext.is_empty() { ext } else { ex_ext }, ex_data)
                    } else if let Some(path) = uri.strip_prefix("file://") {
                        let d = std::fs::read(path).unwrap_or_default();
                        (ext, d)
                    } else {
                        (ext, Vec::new())
                    };
                    doc.images.insert(
                        id,
                        ImageAsset {
                            id,
                            uri,
                            ext: final_ext,
                            data,
                        },
                    );
                }
            }
            "tags" => {
                for tag in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "tag")
                {
                    if let Some(name) = tag.attribute("name") {
                        doc.tags
                            .push((name.to_string(), tag.attribute("color").map(|s| s.to_string())));
                    }
                }
            }
            "nodes" => {
                for node_el in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "node")
                {
                    let rid = parse_node_xml(node_el, None, &mut doc);
                    doc.root_ids.push(rid);
                }
            }
            "groups" => {
                for g in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "group")
                {
                    let mut nids = Vec::new();
                    for gn in g.children().filter(|c| c.is_element()) {
                        if let Some(id) = gn.attribute("id").and_then(|s| s.parse().ok()) {
                            nids.push(id);
                        }
                    }
                    if let Some(ids_attr) = g.attribute("nodes") {
                        for part in ids_attr.split(',') {
                            if let Ok(id) = part.trim().parse::<i32>() {
                                nids.push(id);
                            }
                        }
                    }
                    doc.groups.push(NodeGroup {
                        nodes: nids,
                        color: g.attribute("color").and_then(Rgba::from_hex_or_name),
                        note: g.attribute("note").unwrap_or("").to_string(),
                    });
                }
            }
            "connections" => {
                for conn in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "connection")
                {
                    let from_id = parse_i32(conn.attribute("from_id"), -1);
                    let to_id = parse_i32(conn.attribute("to_id"), -1);
                    if from_id < 0 || to_id < 0 {
                        continue;
                    }
                    let mut style = doc.global_style.clone();
                    let mut title = conn.attribute("title").unwrap_or("").to_string();
                    let mut note = conn.attribute("note").unwrap_or("").to_string();
                    for cc in conn.children().filter(|c| c.is_element()) {
                        match cc.tag_name().name() {
                            "style" => style = parse_style_attrs(cc, &style),
                            "title" => {
                                let t = extract_text_block(cc);
                                if !t.is_empty() {
                                    title = t;
                                }
                            }
                            "note" => {
                                let t = extract_text_block(cc);
                                if !t.is_empty() {
                                    note = t;
                                }
                            }
                            _ => {}
                        }
                    }
                    doc.connections.push(Connection {
                        from_id,
                        to_id,
                        drag_x: parse_f64(conn.attribute("drag_x"), 0.0),
                        drag_y: parse_f64(conn.attribute("drag_y"), 0.0),
                        title,
                        note,
                        color: conn.attribute("color").and_then(Rgba::from_hex_or_name),
                        sticker: conn.attribute("sticker").map(|s| s.to_string()),
                        style,
                    });
                }
            }
            "ideas" => {
                for idea in child
                    .children()
                    .filter(|c| c.is_element() && c.tag_name().name() == "idea")
                {
                    if let Some(t) = idea.attribute("text") {
                        doc.braindump.push(t.to_string());
                    }
                }
            }
            _ => {}
        }
    }

    // Any remaining extracted images not listed in <images> still get registered
    for (id, (ext, data)) in extracted_imgs {
        if id >= doc.next_image_id {
            doc.next_image_id = id + 1;
        }
        doc.images.insert(
            id,
            ImageAsset {
                id,
                uri: String::new(),
                ext,
                data,
            },
        );
    }

    doc.selected_node = doc.root_ids.first().copied();
    // Preserve layout geometry loaded from file, but recompute missing coords if needed
    doc.layout_dirty = doc.nodes.values().all(|n| n.posx == 0.0 && n.posy == 0.0);
    doc.needs_measure = true;
    doc.dirty = false;
    Ok(doc)
}

pub fn load_minder_file(path: &str) -> Result<MapDocument, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("Failed to read {path}: {e}"))?;
    load_minder_bytes(&bytes, Some(path))
}

fn write_style_attrs(out: &mut String, s: &NodeStyle, include_conn_callout: bool) {
    out.push_str(&format!(
        " branchmargin=\"{}\" branchradius=\"{}\" linktype=\"{}\" linkwidth=\"{}\" linkarrow=\"{}\" linkarrowsize=\"{}\" linkdash=\"{}\" nodeborder=\"{}\" nodewidth=\"{}\" nodeborderwidth=\"{}\" nodefill=\"{}\" nodemargin=\"{}\" nodepadding=\"{}\" nodefont=\"{}\" nodetextalign=\"{}\" nodemarkup=\"{}\"",
        s.branchmargin,
        s.branchradius,
        s.linktype.as_str(),
        s.linkwidth,
        s.linkarrow,
        s.linkarrowsize,
        xml_escape_attr(&s.linkdash),
        s.nodeborder.as_str(),
        s.nodewidth,
        s.nodeborderwidth,
        s.nodefill,
        s.nodemargin,
        s.nodepadding,
        xml_escape_attr(&s.nodefont),
        xml_escape_attr(&s.nodetextalign),
        s.nodemarkup
    ));
    if include_conn_callout {
        out.push_str(&format!(
            " connectiondash=\"{}\" connectionlwidth=\"{}\" connectionarrow=\"{}\" connectionpadding=\"{}\" connectionfont=\"{}\" connectiontwidth=\"{}\" calloutfont=\"{}\" calloutpadding=\"{}\" calloutptrwidth=\"{}\" calloutptrlength=\"{}\"",
            xml_escape_attr(&s.connectiondash),
            s.connectionlwidth,
            xml_escape_attr(&s.connectionarrow),
            s.connectionpadding,
            xml_escape_attr(&s.connectionfont),
            s.connectiontwidth,
            xml_escape_attr(&s.calloutfont),
            s.calloutpadding,
            s.calloutptrwidth,
            s.calloutptrlength
        ));
    }
}

fn write_node_xml(out: &mut String, doc: &MapDocument, id: i32, indent: usize) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };
    let pad = " ".repeat(indent);
    out.push_str(&format!(
        "{pad}<node id=\"{}\" posx=\"{}\" posy=\"{}\" width=\"{}\" height=\"{}\" side=\"{}\" fold=\"{}\" sequence=\"{}\" treesize=\"{}\" layout=\"{}\" group=\"{}\" summarized=\"{}\"",
        n.id,
        n.posx,
        n.posy,
        n.width,
        n.height,
        n.side.as_str(),
        n.fold,
        n.sequence,
        n.treesize,
        n.layout.as_str(),
        n.group,
        n.summarized
    ));
    if let Some(c) = n.color {
        out.push_str(&format!(" color=\"{}\" colorroot=\"{}\"", c.to_hex(), n.colorroot));
    }
    if n.task_enabled {
        out.push_str(&format!(
            " task=\"{}\"",
            if n.task_done { "done" } else { "true" }
        ));
    }
    if let Some(ref link) = n.link {
        out.push_str(&format!(" link=\"{}\"", xml_escape_attr(link)));
    }
    if let Some(ref st) = n.sticker {
        out.push_str(&format!(" sticker=\"{}\"", xml_escape_attr(st)));
    }
    out.push_str(">\n");

    let cpad = " ".repeat(indent + 2);
    out.push_str(&format!("{cpad}<style"));
    write_style_attrs(out, &n.style, false);
    out.push_str("/>\n");

    if let Some(ref img) = n.image {
        out.push_str(&format!(
            "{cpad}<nodeimage id=\"{}\" x=\"{}\" y=\"{}\" w=\"{}\" h=\"{}\" size=\"{}\"/>\n",
            img.id, img.crop_x, img.crop_y, img.crop_w, img.crop_h, img.size
        ));
    }

    if let Some(ref tbl) = n.table {
        out.push_str(&format!(
            "{cpad}<nodetable rows=\"{}\" columns=\"{}\">\n",
            tbl.rows, tbl.columns
        ));
        for c in &tbl.cells {
            out.push_str(&format!(
                "{cpad}  <cell row=\"{}\" column=\"{}\" rowspan=\"{}\" colspan=\"{}\" text=\"{}\" align=\"{}\" highlighted=\"{}\" bold=\"{}\" italic=\"{}\" underline=\"{}\" strikethrough=\"{}\"/>\n",
                c.row,
                c.col,
                c.rowspan,
                c.colspan,
                xml_escape_attr(&c.text),
                xml_escape_attr(&c.align),
                c.highlighted,
                c.bold,
                c.italic,
                c.underline,
                c.strikethrough
            ));
        }
        out.push_str(&format!("{cpad}</nodetable>\n"));
    }

    out.push_str(&format!("{cpad}<nodename maxwidth=\"{}\">\n", n.maxwidth));
    out.push_str(&format!(
        "{cpad}  <text data=\"{}\"/>\n",
        xml_escape_attr(&n.text)
    ));
    out.push_str(&format!("{cpad}</nodename>\n"));
    out.push_str(&format!(
        "{cpad}<nodenote>{}</nodenote>\n",
        xml_escape_text(&n.note)
    ));
    out.push_str(&format!(
        "{cpad}<taglist list=\"{}\"/>\n",
        xml_escape_attr(&n.tags.join(","))
    ));

    if let Some(ref co) = n.callout {
        out.push_str(&format!("{cpad}<callout>\n"));
        out.push_str(&format!(
            "{cpad}  <text data=\"{}\"/>\n",
            xml_escape_attr(&co.text)
        ));
        out.push_str(&format!(
            "{cpad}  <style calloutpadding=\"{}\"/>\n",
            co.padding
        ));
        out.push_str(&format!("{cpad}</callout>\n"));
    }

    if !n.children.is_empty() {
        out.push_str(&format!("{cpad}<nodes>\n"));
        for &cid in &n.children {
            write_node_xml(out, doc, cid, indent + 4);
        }
        out.push_str(&format!("{cpad}</nodes>\n"));
    }

    out.push_str(&format!("{pad}</node>\n"));
}

pub fn serialize_minder_xml(doc: &MapDocument) -> String {
    let mut out = String::with_capacity(16 * 1024);
    out.push_str("<?xml version=\"1.0\"?>\n");
    out.push_str(&format!(
        "<minder version=\"{}\" parent-etag=\"{}\" etag=\"{}\">\n",
        xml_escape_attr(&doc.version),
        xml_escape_attr(&doc.parent_etag),
        xml_escape_attr(&doc.etag)
    ));
    out.push_str(&format!(
        "  <theme name=\"{}\" label=\"{}\"/>\n",
        xml_escape_attr(&doc.theme.name),
        xml_escape_attr(&doc.theme.label)
    ));
    out.push_str("  <global-style");
    write_style_attrs(&mut out, &doc.global_style, true);
    out.push_str("/>\n");
    out.push_str(&format!(
        "  <drawarea x=\"{}\" y=\"{}\" scale=\"{}\"/>\n",
        doc.origin_x, doc.origin_y, doc.scale
    ));

    out.push_str("  <images>\n");
    for img in doc.images.values() {
        out.push_str(&format!(
            "    <image id=\"{}\" uri=\"{}\" ext=\"{}\"/>\n",
            img.id,
            xml_escape_attr(&img.uri),
            xml_escape_attr(&img.ext)
        ));
    }
    out.push_str("  </images>\n");

    out.push_str("  <tags>\n");
    for (name, color) in &doc.tags {
        if let Some(c) = color {
            out.push_str(&format!(
                "    <tag name=\"{}\" color=\"{}\"/>\n",
                xml_escape_attr(name),
                xml_escape_attr(c)
            ));
        } else {
            out.push_str(&format!("    <tag name=\"{}\"/>\n", xml_escape_attr(name)));
        }
    }
    out.push_str("  </tags>\n");

    out.push_str("  <nodes>\n");
    for &rid in &doc.root_ids {
        write_node_xml(&mut out, doc, rid, 4);
    }
    out.push_str("  </nodes>\n");

    out.push_str("  <groups/>\n");
    out.push_str("  <connections>\n");
    for conn in &doc.connections {
        out.push_str(&format!(
            "    <connection from_id=\"{}\" to_id=\"{}\" drag_x=\"{}\" drag_y=\"{}\"",
            conn.from_id, conn.to_id, conn.drag_x, conn.drag_y
        ));
        if let Some(c) = conn.color {
            out.push_str(&format!(" color=\"{}\"", c.to_hex()));
        }
        out.push_str(">\n");
        out.push_str("      <style");
        write_style_attrs(&mut out, &conn.style, true);
        out.push_str("/>\n");
        out.push_str(&format!(
            "      <title>{}</title>\n",
            xml_escape_text(&conn.title)
        ));
        out.push_str(&format!(
            "      <note>{}</note>\n",
            xml_escape_text(&conn.note)
        ));
        out.push_str("    </connection>\n");
    }
    out.push_str("  </connections>\n");
    out.push_str("  <stickers/>\n");
    out.push_str("  <nodelinks id=\"0\"/>\n");
    out.push_str("  <ideas/>\n");
    out.push_str("</minder>\n");
    out
}

pub fn save_minder_file(doc: &MapDocument, path: &str) -> Result<(), String> {
    let xml = serialize_minder_xml(doc);
    let use_tar_gz = doc.source_format == SourceFormat::MinderTarGz || !doc.images.is_empty();
    if !use_tar_gz {
        return std::fs::write(path, xml.as_bytes()).map_err(|e| format!("Write {path}: {e}"));
    }

    let tmp_path = format!("{path}.tmp-{}", std::process::id());
    {
        let file = std::fs::File::create(&tmp_path)
            .map_err(|e| format!("Create {tmp_path}: {e}"))?;
        let gz = GzEncoder::new(file, Compression::default());
        let mut tar_builder = Builder::new(gz);

        let xml_bytes = xml.as_bytes();
        let mut header = Header::new_gnu();
        header.set_size(xml_bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar_builder
            .append_data(&mut header, "map.xml", xml_bytes)
            .map_err(|e| format!("Write map.xml to archive: {e}"))?;

        for img in doc.images.values() {
            if img.data.is_empty() {
                continue;
            }
            let ext = if img.ext.is_empty() { ".png" } else { &img.ext };
            let name = format!("img{:06x}{ext}", img.id);
            let mut ih = Header::new_gnu();
            ih.set_size(img.data.len() as u64);
            ih.set_mode(0o644);
            ih.set_cksum();
            tar_builder
                .append_data(&mut ih, name, img.data.as_slice())
                .map_err(|e| format!("Write image to archive: {e}"))?;
        }

        let gz = tar_builder
            .into_inner()
            .map_err(|e| format!("Finalize tar: {e}"))?;
        let mut file = gz
            .finish()
            .map_err(|e| format!("Finalize gzip: {e}"))?;
        file.flush().map_err(|e| format!("Flush archive: {e}"))?;
    }
    std::fs::rename(&tmp_path, path).map_err(|e| format!("Rename {tmp_path} -> {path}: {e}"))?;
    Ok(())
}
