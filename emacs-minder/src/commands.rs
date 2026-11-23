use crate::layout::{
    balance_sides, center_on_node, ensure_all_tree_bboxes, propagate_side, shift_subtree,
    update_badge_hitboxes, zoom_fit,
};
use crate::model::*;

fn remove_subtree(doc: &mut MapDocument, id: i32) {
    let Some(n) = doc.nodes.remove(&id) else {
        return;
    };
    for cid in n.children {
        remove_subtree(doc, cid);
    }
    doc.connections
        .retain(|c| c.from_id != id && c.to_id != id);
}

fn select_spatial_neighbor(doc: &MapDocument, cur_id: i32, dir: &str) -> Option<i32> {
    let cur = doc.nodes.get(&cur_id)?;

    match dir {
        "parent" => return cur.parent,
        "first_child" => return cur.children.first().copied(),
        "next_root" => {
            if doc.root_ids.is_empty() {
                return None;
            }
            let rpos = doc
                .root_ids
                .iter()
                .position(|&r| r == cur_id)
                .map(|i| (i + 1) % doc.root_ids.len())
                .unwrap_or(0);
            return doc.root_ids.get(rpos).copied();
        }
        "left" | "right" => {
            // Tree-aware horizontal step just like Minder
            if cur.is_root() {
                let want = if dir == "left" {
                    NodeSide::Left
                } else {
                    NodeSide::Right
                };
                if let Some(&cid) = cur
                    .children
                    .iter()
                    .find(|&&cid| doc.nodes.get(&cid).map(|c| c.side == want).unwrap_or(false))
                {
                    return Some(cid);
                }
            } else {
                let is_right = cur.side == NodeSide::Right;
                if (dir == "right" && is_right) || (dir == "left" && !is_right) {
                    if !cur.fold {
                        if let Some(&cid) = cur.children.first() {
                            return Some(cid);
                        }
                    }
                } else if (dir == "left" && is_right) || (dir == "right" && !is_right) {
                    if let Some(pid) = cur.parent {
                        return Some(pid);
                    }
                }
            }
        }
        "up" | "down" => {
            if let Some(pid) = cur.parent {
                if let Some(p) = doc.nodes.get(&pid) {
                    let same_side: Vec<i32> = p
                        .children
                        .iter()
                        .copied()
                        .filter(|&cid| {
                            doc.nodes
                                .get(&cid)
                                .map(|c| c.side == cur.side)
                                .unwrap_or(false)
                        })
                        .collect();
                    if let Some(pos) = same_side.iter().position(|&id| id == cur_id) {
                        if dir == "up" && pos > 0 {
                            return Some(same_side[pos - 1]);
                        }
                        if dir == "down" && pos + 1 < same_side.len() {
                            return Some(same_side[pos + 1]);
                        }
                    }
                }
            }
        }
        _ => {}
    }

    // Spatial nearest fallback among all visible nodes
    let cx = cur.posx + cur.width / 2.0;
    let cy = cur.posy + cur.height / 2.0;
    let mut best: Option<(f64, i32)> = None;

    fn collect_visible(doc: &MapDocument, id: i32, out: &mut Vec<i32>) {
        out.push(id);
        if let Some(n) = doc.nodes.get(&id) {
            if !n.fold {
                for &c in &n.children {
                    collect_visible(doc, c, out);
                }
            }
        }
    }
    let mut vis = Vec::new();
    for &rid in &doc.root_ids {
        collect_visible(doc, rid, &mut vis);
    }

    for id in vis {
        if id == cur_id {
            continue;
        }
        let n = &doc.nodes[&id];
        let nx = n.posx + n.width / 2.0;
        let ny = n.posy + n.height / 2.0;
        let dx = nx - cx;
        let dy = ny - cy;
        let ok = match dir {
            "left" => dx < -10.0,
            "right" => dx > 10.0,
            "up" => dy < -10.0,
            "down" => dy > 10.0,
            _ => false,
        };
        if !ok {
            continue;
        }
        let score = match dir {
            "left" | "right" => dx.abs() + dy.abs() * 2.5,
            _ => dy.abs() + dx.abs() * 2.5,
        };
        if best.map(|(b, _)| score < b).unwrap_or(true) {
            best = Some((score, id));
        }
    }
    best.map(|(_, id)| id)
}

pub fn apply_command(doc: &mut MapDocument, cmd: EditCommand) -> Result<(), String> {
    let target_id = match &cmd {
        EditCommand::AddChild { parent_id, .. } => parent_id.or(doc.selected_node),
        EditCommand::AddSibling { ref_id, .. } => ref_id.or(doc.selected_node),
        EditCommand::AddParent { child_id, .. } => child_id.or(doc.selected_node),
        EditCommand::SetText { id, .. }
        | EditCommand::SetNote { id, .. }
        | EditCommand::ToggleFold { id }
        | EditCommand::ToggleTask { id }
        | EditCommand::SetTodoKeyword { id, .. }
        | EditCommand::SetLayout { id, .. }
        | EditCommand::SetSide { id, .. }
        | EditCommand::MoveSibling { id, .. }
        | EditCommand::StartOrFinishConnection { id }
        | EditCommand::SetTable { id, .. }
        | EditCommand::UpdateTableCell { id, .. }
        | EditCommand::AddTableRow { id }
        | EditCommand::AddTableCol { id }
        | EditCommand::AttachImageFile { id, .. }
        | EditCommand::DetachImage { id }
        | EditCommand::ResizeImage { id, .. }
        | EditCommand::SetUrl { id, .. }
        | EditCommand::SetTags { id, .. }
        | EditCommand::SetCallout { id, .. }
        | EditCommand::MoveNode { id, .. }
        | EditCommand::ResizeNode { id, .. } => id.or(doc.selected_node),
        _ => doc.selected_node,
    };

    match cmd {
        EditCommand::SelectNode { id } => {
            if doc.nodes.contains_key(&id) {
                doc.selected_node = Some(id);
            }
        }
        EditCommand::SelectClear => {
            doc.selected_node = None;
            doc.connect_from = None;
        }
        EditCommand::SelectRelative { dir } => {
            if let Some(cur) = doc.selected_node {
                if let Some(next) = select_spatial_neighbor(doc, cur, &dir) {
                    doc.selected_node = Some(next);
                }
            } else {
                doc.selected_node = doc.root_ids.first().copied();
            }
        }
        EditCommand::AddChild { text, .. } => {
            let Some(pid) = target_id.or_else(|| doc.root_ids.first().copied()) else {
                return Ok(());
            };
            doc.push_undo();
            let cid = doc.alloc_id();
            let (p_layout, p_side, p_children_len, p_is_root, p_color, p_is_list, p_posx, p_posy, p_w) = {
                let p = doc.nodes.get(&pid).ok_or("Missing parent")?;
                (
                    p.layout,
                    p.side,
                    p.children.len(),
                    p.is_root(),
                    p.color,
                    p.is_org_list_item,
                    p.posx,
                    p.posy,
                    p.width,
                )
            };
            let side = if p_is_root {
                let want = if p_children_len % 2 == 0 {
                    NodeSide::Right
                } else {
                    NodeSide::Left
                };
                p_layout.side_mapping(want)
            } else {
                p_side
            };
            let color = if p_is_root || p_color.is_none() {
                Some(doc.next_branch_color())
            } else {
                p_color
            };

            let mut node = Node::new(cid, text.unwrap_or_else(|| "New Node".into()));
            node.parent = Some(pid);
            node.side = side;
            node.color = color;
            node.layout = p_layout;
            node.style = doc.global_style.clone();
            node.is_org_list_item = p_is_list;
            node.posx = if side == NodeSide::Left {
                p_posx - 160.0
            } else {
                p_posx + p_w + 72.0
            };
            node.posy = p_posy + (p_children_len as f64) * 48.0;
            doc.nodes.insert(cid, node);

            if let Some(p) = doc.nodes.get_mut(&pid) {
                p.fold = false;
                p.children.push(cid);
            }
            doc.selected_node = Some(cid);
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::AddSibling { text, .. } => {
            let Some(cur_id) = target_id else {
                return apply_command(doc, EditCommand::AddRoot { text });
            };
            let Some(cur) = doc.nodes.get(&cur_id).cloned() else {
                return Ok(());
            };
            let Some(pid) = cur.parent else {
                return apply_command(doc, EditCommand::AddChild { parent_id: Some(cur_id), text });
            };
            doc.push_undo();
            let sid = doc.alloc_id();
            let p_is_root = doc.nodes.get(&pid).map(|p| p.is_root()).unwrap_or(false);
            let color = if p_is_root {
                Some(doc.next_branch_color())
            } else {
                cur.color
            };
            let mut sib = Node::new(sid, text.unwrap_or_else(|| "Sibling Node".into()));
            sib.parent = Some(pid);
            sib.side = cur.side;
            sib.color = color;
            sib.layout = cur.layout;
            sib.style = cur.style.clone();
            sib.is_org_list_item = cur.is_org_list_item;
            sib.posx = cur.posx;
            sib.posy = cur.posy + cur.height + 16.0;
            doc.nodes.insert(sid, sib);
            if let Some(p) = doc.nodes.get_mut(&pid) {
                if let Some(idx) = p.children.iter().position(|&id| id == cur_id) {
                    p.children.insert(idx + 1, sid);
                } else {
                    p.children.push(sid);
                }
            }
            doc.selected_node = Some(sid);
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::AddParent { text, .. } => {
            let Some(cid) = target_id else { return Ok(()) };
            let Some(child) = doc.nodes.get(&cid).cloned() else {
                return Ok(());
            };
            let Some(pid) = child.parent else {
                return Ok(());
            };
            doc.push_undo();
            let mid = doc.alloc_id();
            let mut mid_node = Node::new(mid, text.unwrap_or_else(|| "Parent Topic".into()));
            mid_node.parent = Some(pid);
            mid_node.side = child.side;
            mid_node.color = child.color;
            mid_node.layout = child.layout;
            mid_node.style = child.style.clone();
            mid_node.children.push(cid);
            doc.nodes.insert(mid, mid_node);

            if let Some(c) = doc.nodes.get_mut(&cid) {
                c.parent = Some(mid);
            }
            if let Some(p) = doc.nodes.get_mut(&pid) {
                if let Some(slot) = p.children.iter_mut().find(|id| **id == cid) {
                    *slot = mid;
                }
            }
            doc.selected_node = Some(mid);
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::AddRoot { text } => {
            doc.push_undo();
            let rid = doc.alloc_id();
            let mut root = Node::new(rid, text.unwrap_or_else(|| "Main Idea".into()));
            root.style = doc.global_style.clone();
            root.style.nodeborder = NodeBorder::Rounded;
            root.style.nodefont = "Sans Bold 13".into();
            doc.nodes.insert(rid, root);
            doc.root_ids.push(rid);
            doc.selected_node = Some(rid);
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::DeleteSelected => {
            let Some(id) = doc.selected_node else {
                return Ok(());
            };
            if doc.nodes.len() <= 1 {
                return Ok(());
            }
            doc.push_undo();
            let parent = doc.nodes.get(&id).and_then(|n| n.parent);
            let mut next_sel = parent;
            if let Some(pid) = parent {
                if let Some(p) = doc.nodes.get_mut(&pid) {
                    if let Some(pos) = p.children.iter().position(|&c| c == id) {
                        p.children.remove(pos);
                        if !p.children.is_empty() {
                            next_sel = Some(p.children[pos.min(p.children.len() - 1)]);
                        }
                    }
                }
            } else {
                doc.root_ids.retain(|&r| r != id);
                next_sel = doc.root_ids.first().copied();
            }
            remove_subtree(doc, id);
            doc.selected_node = next_sel;
            doc.ensure_valid_selection();
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::SetText { text, .. } => {
            if let Some(id) = target_id {
                if doc.nodes.get(&id).map(|n| n.text != text).unwrap_or(false) {
                    doc.push_undo();
                    if let Some(n) = doc.nodes.get_mut(&id) {
                        n.text = text;
                    }
                    doc.layout_dirty = true;
                    doc.dirty = true;
                }
            }
        }
        EditCommand::SetNote { note, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.note = note;
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::ToggleFold { .. } => {
            if let Some(id) = target_id {
                let has_ch = doc.nodes.get(&id).map(|n| !n.children.is_empty()).unwrap_or(false);
                if has_ch {
                    doc.push_undo();
                    if let Some(n) = doc.nodes.get_mut(&id) {
                        n.fold = !n.fold;
                    }
                    doc.layout_dirty = true;
                    doc.dirty = true;
                }
            }
        }
        EditCommand::FoldAll { fold } => {
            doc.push_undo();
            let ids: Vec<i32> = doc.nodes.keys().copied().collect();
            for id in ids {
                if let Some(n) = doc.nodes.get_mut(&id) {
                    if !n.is_root() && !n.children.is_empty() {
                        n.fold = fold;
                    }
                }
            }
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::ToggleTask { .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    if !n.task_enabled {
                        n.task_enabled = true;
                        n.task_done = false;
                        if n.todo_keyword.is_none() && doc.source_format == SourceFormat::Org {
                            n.todo_keyword = Some("TODO".into());
                        }
                    } else if !n.task_done {
                        n.task_done = true;
                        if doc.source_format == SourceFormat::Org {
                            n.todo_keyword = Some("DONE".into());
                        }
                    } else {
                        n.task_enabled = false;
                        n.task_done = false;
                        n.todo_keyword = None;
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::SetTodoKeyword { keyword, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    match keyword {
                        Some(k) if !k.trim().is_empty() => {
                            let u = k.trim().to_string();
                            n.task_enabled = true;
                            n.task_done = matches!(u.as_str(), "DONE" | "CANCELED" | "CANCELLED");
                            n.todo_keyword = Some(u);
                        }
                        _ => {
                            n.task_enabled = false;
                            n.task_done = false;
                            n.todo_keyword = None;
                        }
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::SetLayout { layout, .. } => {
            let kind = LayoutKind::from_str(&layout);
            doc.push_undo();
            let rid = target_id
                .and_then(|id| {
                    let mut c = id;
                    while let Some(pid) = doc.nodes.get(&c).and_then(|n| n.parent) {
                        c = pid;
                    }
                    Some(c)
                })
                .or_else(|| doc.root_ids.first().copied());
            if let Some(root_id) = rid {
                if let Some(r) = doc.nodes.get_mut(&root_id) {
                    r.layout = kind;
                }
                let ch = doc.nodes.get(&root_id).map(|r| r.children.clone()).unwrap_or_default();
                for (i, cid) in ch.iter().enumerate() {
                    let s = match kind {
                        LayoutKind::Horizontal => {
                            if i < (ch.len() + 1) / 2 {
                                NodeSide::Right
                            } else {
                                NodeSide::Left
                            }
                        }
                        LayoutKind::Vertical => {
                            if i < (ch.len() + 1) / 2 {
                                NodeSide::Bottom
                            } else {
                                NodeSide::Top
                            }
                        }
                        _ => kind.side_mapping(NodeSide::Right),
                    };
                    propagate_side(doc, *cid, s);
                }
            }
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::SetSide { side, .. } => {
            if let Some(id) = target_id {
                let s = NodeSide::from_str(&side);
                doc.push_undo();
                propagate_side(doc, id, s);
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::Balance => {
            doc.push_undo();
            balance_sides(doc);
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::MoveSibling { delta, .. } => {
            if let Some(id) = target_id {
                if let Some(pid) = doc.nodes.get(&id).and_then(|n| n.parent) {
                    doc.push_undo();
                    if let Some(p) = doc.nodes.get_mut(&pid) {
                        if let Some(pos) = p.children.iter().position(|&c| c == id) {
                            let new_pos = (pos as isize + delta as isize)
                                .clamp(0, (p.children.len() - 1) as isize) as usize;
                            if new_pos != pos {
                                let item = p.children.remove(pos);
                                p.children.insert(new_pos, item);
                            }
                        }
                    }
                    doc.layout_dirty = true;
                    doc.dirty = true;
                }
            }
        }
        EditCommand::SetLinktype { linktype } => {
            let lt = LinkType::from_str(&linktype);
            doc.push_undo();
            doc.global_style.linktype = lt;
            for n in doc.nodes.values_mut() {
                n.style.linktype = lt;
            }
            doc.dirty = true;
        }
        EditCommand::SetNodeborder { nodeborder } => {
            let nb = NodeBorder::from_str(&nodeborder);
            doc.push_undo();
            doc.global_style.nodeborder = nb;
            for n in doc.nodes.values_mut() {
                n.style.nodeborder = nb;
            }
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::SetFont { font } => {
            doc.push_undo();
            doc.global_style.nodefont = font.clone();
            for n in doc.nodes.values_mut() {
                n.style.nodefont = font.clone();
            }
            doc.layout_dirty = true;
            doc.dirty = true;
        }
        EditCommand::SetTheme { theme } => {
            doc.theme_name = theme.clone();
            doc.theme = ThemePalette::by_name(&theme);
            doc.dirty = true;
        }
        EditCommand::SetTransparentBg { enabled } => {
            doc.transparent_bg = enabled;
        }
        EditCommand::SetEmacsColors {
            bg,
            fg,
            accent,
            selection_bg,
            selection_fg,
            branch_colors,
        } => {
            if let Some(c) = Rgba::from_hex_or_name(&bg) {
                doc.theme.background = c;
            }
            if let Some(c) = Rgba::from_hex_or_name(&fg) {
                doc.theme.foreground = c;
            }
            if let Some(c) = Rgba::from_hex_or_name(&accent) {
                doc.theme.root_background = c;
                doc.theme.root_foreground = c.contrast_fg();
            }
            if let Some(c) = Rgba::from_hex_or_name(&selection_bg) {
                doc.theme.nodesel_background = c;
            }
            if let Some(c) = Rgba::from_hex_or_name(&selection_fg) {
                doc.theme.nodesel_foreground = c;
            }
            if !branch_colors.is_empty() {
                let parsed: Vec<Rgba> = branch_colors
                    .iter()
                    .filter_map(|s| Rgba::from_hex_or_name(s))
                    .collect();
                if !parsed.is_empty() {
                    for (i, slot) in doc.theme.link_colors.iter_mut().enumerate() {
                        *slot = parsed[i % parsed.len()];
                    }
                }
            }
            doc.theme_name = "emacs_dynamic".into();
            doc.theme.name = "emacs_dynamic".into();
            doc.theme.label = "Emacs Theme".into();
        }
        EditCommand::StartOrFinishConnection { .. } => {
            if let Some(id) = target_id {
                match doc.connect_from {
                    None => doc.connect_from = Some(id),
                    Some(from) if from == id => doc.connect_from = None,
                    Some(from) => {
                        doc.push_undo();
                        doc.connections.push(Connection {
                            from_id: from,
                            to_id: id,
                            drag_x: 0.0,
                            drag_y: 0.0,
                            title: String::new(),
                            note: String::new(),
                            color: None,
                            sticker: None,
                            style: doc.global_style.clone(),
                        });
                        doc.connect_from = None;
                        doc.dirty = true;
                    }
                }
            }
        }
        EditCommand::AddConnection {
            from_id,
            to_id,
            title,
        } => {
            if doc.nodes.contains_key(&from_id) && doc.nodes.contains_key(&to_id) {
                doc.push_undo();
                doc.connections.push(Connection {
                    from_id,
                    to_id,
                    drag_x: 0.0,
                    drag_y: 0.0,
                    title: title.unwrap_or_default(),
                    note: String::new(),
                    color: None,
                    sticker: None,
                    style: doc.global_style.clone(),
                });
                doc.dirty = true;
            }
        }
        EditCommand::DeleteConnection { index } => {
            if index < doc.connections.len() {
                doc.push_undo();
                doc.connections.remove(index);
                doc.dirty = true;
            }
        }
        EditCommand::SetTable { table, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.table = Some(table);
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::UpdateTableCell {
            row,
            col,
            text,
            highlighted,
            bold,
            ..
        } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    if let Some(ref mut tbl) = n.table {
                        if let Some(cell) = tbl.cells.iter_mut().find(|c| c.row == row && c.col == col) {
                            if let Some(t) = text {
                                cell.text = t;
                            }
                            if let Some(hi) = highlighted {
                                cell.highlighted = hi;
                            }
                            if let Some(b) = bold {
                                cell.bold = b;
                            }
                        } else if row < tbl.rows && col < tbl.columns {
                            tbl.cells.push(TableCell {
                                row,
                                col,
                                rowspan: 1,
                                colspan: 1,
                                text: text.unwrap_or_default(),
                                align: "left".into(),
                                highlighted: highlighted.unwrap_or(false),
                                bold: bold.unwrap_or(false),
                                italic: false,
                                underline: false,
                                strikethrough: false,
                            });
                        }
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::AddTableRow { .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    let tbl = n.table.get_or_insert(NodeTable {
                        rows: 1,
                        columns: 2,
                        cells: Vec::new(),
                    });
                    let new_r = tbl.rows;
                    tbl.rows += 1;
                    for c in 0..tbl.columns {
                        tbl.cells.push(TableCell {
                            row: new_r,
                            col: c,
                            rowspan: 1,
                            colspan: 1,
                            text: String::new(),
                            align: "left".into(),
                            highlighted: false,
                            bold: false,
                            italic: false,
                            underline: false,
                            strikethrough: false,
                        });
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::AddTableCol { .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    let tbl = n.table.get_or_insert(NodeTable {
                        rows: 2,
                        columns: 1,
                        cells: Vec::new(),
                    });
                    let new_c = tbl.columns;
                    tbl.columns += 1;
                    for r in 0..tbl.rows {
                        tbl.cells.push(TableCell {
                            row: r,
                            col: new_c,
                            rowspan: 1,
                            colspan: 1,
                            text: String::new(),
                            align: "left".into(),
                            highlighted: false,
                            bold: false,
                            italic: false,
                            underline: false,
                            strikethrough: false,
                        });
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::AttachImageFile { path, size, .. } => {
            if let Some(id) = target_id {
                let img_id = doc.add_image_from_file(&path)?;
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.image = Some(NodeImageRef {
                        id: img_id,
                        crop_x: 0,
                        crop_y: 0,
                        crop_w: 0,
                        crop_h: 0,
                        size: size.unwrap_or(220.0).max(32.0),
                    });
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::DetachImage { .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.image = None;
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::ResizeImage { width, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    if let Some(ref mut img) = n.image {
                        img.size = width.clamp(32.0, 900.0);
                    }
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::SetUrl { url, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.link = url.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::SetTags { tags, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.tags = tags;
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::SetCallout { text, .. } => {
            if let Some(id) = target_id {
                doc.push_undo();
                if let Some(n) = doc.nodes.get_mut(&id) {
                    n.callout = text.and_then(|t| {
                        let s = t.trim().to_string();
                        if s.is_empty() {
                            None
                        } else {
                            Some(Callout { text: s, padding: 6.0 })
                        }
                    });
                }
                doc.layout_dirty = true;
                doc.dirty = true;
            }
        }
        EditCommand::Pan { dx, dy } => {
            let s = doc.scale.max(0.1);
            doc.origin_x += dx / s;
            doc.origin_y += dy / s;
        }
        EditCommand::MoveNode {
            dx,
            dy,
            move_subtree,
            record_undo,
            ..
        } => {
            if let Some(nid) = target_id {
                if doc.nodes.contains_key(&nid) {
                    if record_undo {
                        doc.push_undo();
                    }
                    let mut root_id = nid;
                    while let Some(pid) = doc.nodes.get(&root_id).and_then(|n| n.parent) {
                        root_id = pid;
                    }
                    if let Some(r) = doc.nodes.get_mut(&root_id) {
                        r.layout = LayoutKind::Manual;
                    }
                    let s = doc.scale.max(0.05);
                    let wx = dx / s;
                    let wy = dy / s;
                    if move_subtree {
                        shift_subtree(doc, nid, wx, wy);
                    } else if let Some(n) = doc.nodes.get_mut(&nid) {
                        n.posx += wx;
                        n.posy += wy;
                    }
                    if let Some(pid) = doc.nodes.get(&nid).and_then(|n| n.parent) {
                        if let (Some(n), Some(p)) = (doc.nodes.get(&nid), doc.nodes.get(&pid)) {
                            let child_cx = n.posx + n.width / 2.0;
                            let parent_cx = p.posx + p.width / 2.0;
                            let new_side = if child_cx < parent_cx {
                                NodeSide::Left
                            } else {
                                NodeSide::Right
                            };
                            if let Some(nm) = doc.nodes.get_mut(&nid) {
                                nm.side = new_side;
                            }
                        }
                    }
                    ensure_all_tree_bboxes(doc);
                    update_badge_hitboxes(doc);
                    doc.dirty = true;
                }
            }
        }
        EditCommand::ResizeNode {
            width,
            record_undo,
            ..
        } => {
            if let Some(nid) = target_id {
                if doc.nodes.contains_key(&nid) {
                    if record_undo {
                        doc.push_undo();
                    }
                    let new_outer = width.clamp(68.0, 1800.0);
                    let pad = doc
                        .nodes
                        .get(&nid)
                        .map(|n| n.style.nodepadding.max(4.0))
                        .unwrap_or(6.0);
                    let inner_w = (new_outer - 2.0 * pad).max(48.0);
                    if let Some(n) = doc.nodes.get_mut(&nid) {
                        n.maxwidth = inner_w;
                        n.style.nodewidth = inner_w;
                        n.custom_width = Some(inner_w);
                        if let Some(ref mut img) = n.image {
                            img.size = inner_w;
                        }
                    }
                    doc.dirty_measure_node = Some(nid);
                    doc.dirty = true;
                    if doc.source_format == SourceFormat::Org {
                        let mut root_id = nid;
                        while let Some(pid) = doc.nodes.get(&root_id).and_then(|n| n.parent) {
                            root_id = pid;
                        }
                        let is_manual = doc
                            .nodes
                            .get(&root_id)
                            .map(|r| r.layout == LayoutKind::Manual)
                            .unwrap_or(false);
                        if !is_manual {
                            doc.layout_dirty = true;
                        }
                    }
                }
            }
        }
        EditCommand::Zoom {
            factor,
            anchor_x,
            anchor_y,
        } => {
            let old = doc.scale.max(0.05);
            let new_scale = (old * factor).clamp(0.15, 4.0);
            let vw = (doc.viewport_w as f64).max(1.0);
            let vh = (doc.viewport_h as f64).max(1.0);
            let ax = anchor_x.unwrap_or(vw / 2.0).clamp(0.0, vw);
            let ay = anchor_y.unwrap_or(vh / 2.0).clamp(0.0, vh);
            let wx = doc.origin_x + ax / old;
            let wy = doc.origin_y + ay / old;
            doc.scale = new_scale;
            doc.origin_x = wx - ax / new_scale;
            doc.origin_y = wy - ay / new_scale;
        }
        EditCommand::ZoomReset => {
            doc.scale = 1.0;
            if let Some(sel) = doc.selected_node {
                center_on_node(doc, sel);
            }
        }
        EditCommand::ZoomFit => {
            zoom_fit(doc);
        }
        EditCommand::CenterOnSelected => {
            if let Some(sel) = doc.selected_node {
                center_on_node(doc, sel);
            }
        }
        EditCommand::Undo => {
            doc.undo();
        }
        EditCommand::Redo => {
            doc.redo();
        }
        EditCommand::Search { query } => {
            let q = query.trim().to_ascii_lowercase();
            doc.search_matches.clear();
            doc.search_cursor = 0;
            if !q.is_empty() {
                for (&id, n) in &doc.nodes {
                    if n.text.to_ascii_lowercase().contains(&q)
                        || n.note.to_ascii_lowercase().contains(&q)
                        || n.tags.iter().any(|t| t.to_ascii_lowercase().contains(&q))
                    {
                        doc.search_matches.push(id);
                    }
                }
                if let Some(&first) = doc.search_matches.first() {
                    unfold_ancestors(doc, first);
                    doc.selected_node = Some(first);
                    center_on_node(doc, first);
                }
            }
        }
        EditCommand::SearchNext => {
            if !doc.search_matches.is_empty() {
                doc.search_cursor = (doc.search_cursor + 1) % doc.search_matches.len();
                let id = doc.search_matches[doc.search_cursor];
                unfold_ancestors(doc, id);
                doc.selected_node = Some(id);
                center_on_node(doc, id);
            }
        }
    }
    Ok(())
}

fn unfold_ancestors(doc: &mut MapDocument, mut id: i32) {
    while let Some(pid) = doc.nodes.get(&id).and_then(|n| n.parent) {
        if let Some(p) = doc.nodes.get_mut(&pid) {
            if p.fold {
                p.fold = false;
                doc.layout_dirty = true;
            }
        }
        id = pid;
    }
}
