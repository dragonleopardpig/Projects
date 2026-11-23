use crate::ffi::*;
use crate::latex::LatexCache;
use crate::layout::{
    build_rich_pango_layout, document_bounds, ensure_all_tree_bboxes, ensure_minimum_node_sizes,
    measure_single_node, measure_table, relayout_document, update_badge_hitboxes, AssetCache,
};
use crate::model::*;

fn rects_intersect(a: &Rect, b: &Rect) -> bool {
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

fn expand_rect(r: &Rect, margin: f64) -> Rect {
    Rect {
        x: r.x - margin,
        y: r.y - margin,
        w: r.w + 2.0 * margin,
        h: r.h + 2.0 * margin,
    }
}

fn merge_rects(a: &Rect, b: &Rect) -> Rect {
    let min_x = a.x.min(b.x);
    let min_y = a.y.min(b.y);
    let max_x = (a.x + a.w).max(b.x + b.w);
    let max_y = (a.y + a.h).max(b.y + b.h);
    Rect {
        x: min_x,
        y: min_y,
        w: max_x - min_x,
        h: max_y - min_y,
    }
}

fn set_dash_from_style(cr: &CairoContext, dash: &str, width: f64) {
    let w = width.max(1.0);
    match dash.to_ascii_lowercase().as_str() {
        "dotted" => cr.set_dash(&[w, w * 2.2], 0.0),
        "short" | "dashed" => cr.set_dash(&[w * 3.0, w * 2.0], 0.0),
        "long" => cr.set_dash(&[w * 6.0, w * 3.0], 0.0),
        _ => cr.set_dash(&[], 0.0),
    }
}

fn draw_arrow_head(cr: &CairoContext, x: f64, y: f64, angle: f64, size: f64) {
    let len = (size * 3.8).max(7.0);
    let spread = 0.45;
    cr.save();
    cr.new_path();
    cr.move_to(x, y);
    cr.line_to(
        x - len * (angle - spread).cos(),
        y - len * (angle - spread).sin(),
    );
    cr.line_to(
        x - len * (angle + spread).cos(),
        y - len * (angle + spread).sin(),
    );
    cr.close_path();
    cr.fill();
    cr.restore();
}

fn link_points(parent: &Node, child: &Node) -> ((f64, f64), (f64, f64)) {
    let from_under = parent.style.nodeborder == NodeBorder::Underlined && !parent.is_root();
    let to_under = child.style.nodeborder == NodeBorder::Underlined && !child.is_root();

    let py = if from_under {
        parent.posy + parent.height
    } else {
        parent.posy + parent.height / 2.0
    };
    let cy = if to_under {
        child.posy + child.height
    } else {
        child.posy + child.height / 2.0
    };

    match child.side {
        NodeSide::Right => {
            let fx = parent.posx + parent.width;
            let tx = child.posx;
            ((fx, py), (tx, cy))
        }
        NodeSide::Left => {
            let fx = parent.posx;
            let tx = child.posx + child.width;
            ((fx, py), (tx, cy))
        }
        NodeSide::Bottom => (
            (parent.posx + parent.width / 2.0, parent.posy + parent.height),
            (child.posx + child.width / 2.0, child.posy),
        ),
        NodeSide::Top => (
            (parent.posx + parent.width / 2.0, parent.posy),
            (child.posx + child.width / 2.0, child.posy + child.height),
        ),
    }
}

fn draw_branch_link(cr: &CairoContext, doc: &MapDocument, parent: &Node, child: &Node) {
    let color = doc
        .get_effective_color(child.id)
        .unwrap_or(doc.theme.foreground);
    let style = &parent.style;
    let lw = style.linkwidth.clamp(1.5, 6.0);
    let ((x1, y1), (x2, y2)) = link_points(parent, child);

    cr.save();
    cr.set_rgba(color.r, color.g, color.b, 0.92);
    cr.set_line_width(lw);
    cr.set_line_cap(CAIRO_LINE_CAP_ROUND);
    cr.set_line_join(CAIRO_LINE_JOIN_ROUND);
    set_dash_from_style(cr, &style.linkdash, lw);

    let horizontal = child.side.is_horizontal();
    cr.new_path();
    cr.move_to(x1, y1);

    let end_angle = match style.linktype {
        LinkType::Straight => {
            cr.line_to(x2, y2);
            (y2 - y1).atan2(x2 - x1)
        }
        LinkType::Squared => {
            if horizontal {
                let mx = (x1 + x2) / 2.0;
                cr.line_to(mx, y1);
                cr.line_to(mx, y2);
                cr.line_to(x2, y2);
                if x2 >= mx { 0.0 } else { std::f64::consts::PI }
            } else {
                let my = (y1 + y2) / 2.0;
                cr.line_to(x1, my);
                cr.line_to(x2, my);
                cr.line_to(x2, y2);
                if y2 >= my {
                    std::f64::consts::FRAC_PI_2
                } else {
                    -std::f64::consts::FRAC_PI_2
                }
            }
        }
        LinkType::Curved => {
            if horizontal {
                let mx = (x1 + x2) / 2.0;
                cr.curve_to(mx, y1, mx, y2, x2, y2);
                if x2 >= x1 { 0.0 } else { std::f64::consts::PI }
            } else {
                let my = (y1 + y2) / 2.0;
                cr.curve_to(x1, my, x2, my, x2, y2);
                if y2 >= y1 {
                    std::f64::consts::FRAC_PI_2
                } else {
                    -std::f64::consts::FRAC_PI_2
                }
            }
        }
        LinkType::Rounded => {
            let r = style.branchradius.clamp(6.0, 28.0);
            if horizontal {
                let dx = x2 - x1;
                let dy = y2 - y1;
                if dy.abs() < 1.0 || dx.abs() < 8.0 {
                    cr.line_to(x2, y2);
                } else {
                    let sdx = dx.signum();
                    let sdy = dy.signum();
                    let rad = r.min(dx.abs() / 2.0).min(dy.abs() / 2.0);
                    let bend_x = x1 + sdx * rad;
                    cr.curve_to(x1 + sdx * rad * 0.55, y1, bend_x, y1 + sdy * rad * 0.45, bend_x, y1 + sdy * rad);
                    cr.line_to(bend_x, y2 - sdy * rad);
                    cr.curve_to(bend_x, y2 - sdy * rad * 0.45, bend_x + sdx * rad * 0.55, y2, bend_x + sdx * rad, y2);
                    cr.line_to(x2, y2);
                }
                if x2 >= x1 { 0.0 } else { std::f64::consts::PI }
            } else {
                let mx = x1;
                let dy = y2 - y1;
                let dx = x2 - x1;
                if dx.abs() < 1.0 || dy.abs() < 8.0 {
                    cr.line_to(x2, y2);
                } else {
                    let sdx = dx.signum();
                    let sdy = dy.signum();
                    let rad = r.min(dx.abs() / 2.0).min(dy.abs() / 2.0);
                    let bend_y = y1 + sdy * rad;
                    cr.line_to(mx, bend_y - sdy * rad);
                    cr.curve_to(mx, bend_y, mx + sdx * rad * 0.45, bend_y, mx + sdx * rad, bend_y);
                    cr.line_to(x2, bend_y);
                    cr.line_to(x2, y2);
                }
                if y2 >= y1 {
                    std::f64::consts::FRAC_PI_2
                } else {
                    -std::f64::consts::FRAC_PI_2
                }
            }
        }
    };
    cr.stroke();

    if style.linkarrow {
        draw_arrow_head(cr, x2, y2, end_angle, style.linkarrowsize);
    }

    cr.restore();
}

fn draw_connections(
    cr: &CairoContext,
    doc: &MapDocument,
    latex_cache: &LatexCache,
    view_world: Option<&Rect>,
) {
    for (idx, conn) in doc.connections.iter().enumerate() {
        let Some(from_n) = doc.nodes.get(&conn.from_id) else {
            continue;
        };
        let Some(to_n) = doc.nodes.get(&conn.to_id) else {
            continue;
        };
        let x1 = from_n.posx + from_n.width / 2.0;
        let y1 = from_n.posy + from_n.height / 2.0;
        let x2 = to_n.posx + to_n.width / 2.0;
        let y2 = to_n.posy + to_n.height / 2.0;

        let (cx, cy) = if conn.drag_x == 0.0 && conn.drag_y == 0.0 {
            let mx = (x1 + x2) / 2.0;
            let my = (y1 + y2) / 2.0;
            let dx = x2 - x1;
            let dy = y2 - y1;
            let dist = (dx * dx + dy * dy).sqrt().max(1.0);
            (mx - dy / dist * 40.0, my + dx / dist * 40.0)
        } else {
            (conn.drag_x, conn.drag_y)
        };

        if let Some(vw) = view_world {
            let min_x = x1.min(x2).min(cx) - 160.0;
            let min_y = y1.min(y2).min(cy) - 120.0;
            let max_x = x1.max(x2).max(cx) + 160.0;
            let max_y = y1.max(y2).max(cy) + 120.0;
            let cb = Rect {
                x: min_x,
                y: min_y,
                w: max_x - min_x,
                h: max_y - min_y,
            };
            if !rects_intersect(&cb, vw) {
                continue;
            }
        }

        let col = conn.color.unwrap_or(doc.theme.connection_background);
        let selected = doc.selected_connection == Some(idx);

        cr.save();
        cr.set_rgba(col.r, col.g, col.b, if selected { 1.0 } else { 0.85 });
        let lw = conn.style.connectionlwidth.max(2.0);
        cr.set_line_width(lw);
        set_dash_from_style(cr, &conn.style.connectiondash, lw);

        cr.new_path();
        cr.move_to(x1, y1);
        let c1x = x1 + (2.0 / 3.0) * (cx - x1);
        let c1y = y1 + (2.0 / 3.0) * (cy - y1);
        let c2x = x2 + (2.0 / 3.0) * (cx - x2);
        let c2y = y2 + (2.0 / 3.0) * (cy - y2);
        cr.curve_to(c1x, c1y, c2x, c2y, x2, y2);
        cr.stroke();

        cr.set_dash(&[], 0.0);
        let arrow = conn.style.connectionarrow.as_str();
        if arrow.contains("to") {
            let angle = (y2 - c2y).atan2(x2 - c2x);
            draw_arrow_head(cr, x2, y2, angle, 2.2);
        }
        if arrow.contains("from") {
            let angle = (y1 - c1y).atan2(x1 - c1x);
            draw_arrow_head(cr, x1, y1, angle, 2.2);
        }

        if !conn.title.trim().is_empty() {
            let mx = 0.25 * x1 + 0.5 * cx + 0.25 * x2;
            let my = 0.25 * y1 + 0.5 * cy + 0.25 * y2;
            let fg = col.contrast_fg();
            if let Ok(layout) = build_rich_pango_layout(
                cr,
                &conn.title,
                &conn.style.connectionfont,
                conn.style.connectiontwidth.max(180.0),
                fg,
                "center",
                latex_cache,
            ) {
                let (pw, ph) = layout.pixel_size();
                let pad = 6.0;
                let bx = mx - pw / 2.0 - pad;
                let by = my - ph / 2.0 - pad;
                cr.set_rgba(col.r, col.g, col.b, 0.94);
                cr.rounded_rect(bx, by, pw + 2.0 * pad, ph + 2.0 * pad, 6.0);
                cr.fill();
                cr.set_rgba(fg.r, fg.g, fg.b, 1.0);
                layout.update_and_show(cr, mx - pw / 2.0, my - ph / 2.0);
            }
        }
        cr.restore();
    }
}

fn draw_node_table(
    cr: &CairoContext,
    table: &NodeTable,
    x: f64,
    y: f64,
    font_str: &str,
    fg: Rgba,
    accent: Rgba,
    latex_cache: &LatexCache,
) {
    let m = measure_table(cr, table, font_str, latex_cache);
    let rows = table.rows.max(1);
    let cols = table.columns.max(1);

    let mut col_x = vec![x; cols + 1];
    for c in 0..cols {
        col_x[c + 1] = col_x[c] + m.col_widths[c];
    }
    let mut row_y = vec![y; rows + 1];
    for r in 0..rows {
        row_y[r + 1] = row_y[r] + m.row_heights[r];
    }

    cr.save();
    for cell in &table.cells {
        if cell.row >= rows || cell.col >= cols {
            continue;
        }
        let r2 = (cell.row + cell.rowspan.max(1)).min(rows);
        let c2 = (cell.col + cell.colspan.max(1)).min(cols);
        let cx = col_x[cell.col];
        let cy = row_y[cell.row];
        let cw = col_x[c2] - cx;
        let ch = row_y[r2] - cy;

        if cell.highlighted {
            cr.set_rgba(accent.r, accent.g, accent.b, 0.22);
            cr.rectangle(cx, cy, cw, ch);
            cr.fill();
        }
        cr.set_rgba(fg.r, fg.g, fg.b, 0.45);
        cr.set_line_width(1.0);
        cr.rectangle(cx, cy, cw, ch);
        cr.stroke();

        if !cell.text.trim().is_empty() {
            if let Ok(layout) = build_rich_pango_layout(
                cr,
                &cell.text,
                font_str,
                (cw - 8.0).max(20.0),
                fg,
                &cell.align,
                latex_cache,
            ) {
                let (pw, ph) = layout.pixel_size();
                let tx = match cell.align.as_str() {
                    "center" => cx + (cw - pw) / 2.0,
                    "right" => cx + cw - pw - 5.0,
                    _ => cx + 5.0,
                };
                let ty = cy + (ch - ph) / 2.0;
                cr.set_rgba(fg.r, fg.g, fg.b, 1.0);
                layout.update_and_show(cr, tx, ty);
            }
        }
    }
    cr.restore();
}

fn draw_node_recursive(
    cr: &CairoContext,
    doc: &MapDocument,
    id: i32,
    assets: &AssetCache,
    latex_cache: &LatexCache,
    view_world: Option<&Rect>,
) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };

    if let Some(vw) = view_world {
        if n.tree_bbox.w > 0.0 && !rects_intersect(&expand_rect(&n.tree_bbox, 80.0), vw) {
            return;
        }
    }

    let node_rect = Rect {
        x: n.posx,
        y: n.posy,
        w: n.width,
        h: n.height,
    };

    if !n.fold {
        for &cid in &n.children {
            if let Some(ch) = doc.nodes.get(&cid) {
                let draw_link = match view_world {
                    None => true,
                    Some(vw) => {
                        let cbox = if ch.tree_bbox.w > 0.0 {
                            &ch.tree_bbox
                        } else {
                            &Rect {
                                x: ch.posx,
                                y: ch.posy,
                                w: ch.width,
                                h: ch.height,
                            }
                        };
                        rects_intersect(&expand_rect(&merge_rects(&node_rect, cbox), 48.0), vw)
                    }
                };
                if draw_link {
                    draw_branch_link(cr, doc, n, ch);
                }
            }
        }
    }

    let draw_self = match view_world {
        None => true,
        Some(vw) => rects_intersect(&expand_rect(&node_rect, 80.0), vw),
    };
    if draw_self {

    let is_sel = doc.selected_node == Some(id);
    let is_connect_src = doc.connect_from == Some(id);
    let branch_color = doc
        .get_effective_color(id)
        .unwrap_or(doc.theme.root_background);
    let fill_color = if n.is_root() {
        n.color.unwrap_or(doc.theme.root_background)
    } else {
        branch_color
    };

    let filled = n.is_root() || (n.style.nodefill && n.style.nodeborder.is_fillable());
    let text_fg = if is_sel && filled {
        fill_color.contrast_fg()
    } else if filled {
        if n.is_root() && n.color.is_none() {
            doc.theme.root_foreground
        } else {
            fill_color.contrast_fg()
        }
    } else {
        doc.theme.foreground
    };

    cr.save();

    // Selection glow / highlight frame
    if is_sel || is_connect_src {
        let sel = if is_connect_src {
            Rgba::rgb(0.95, 0.55, 0.15)
        } else {
            doc.theme.nodesel_background
        };
        if !filled {
            cr.set_rgba(sel.r, sel.g, sel.b, 0.22);
            cr.rounded_rect(n.posx - 3.0, n.posy - 3.0, n.width + 6.0, n.height + 6.0, 8.0);
            cr.fill();
        }
        cr.set_rgba(sel.r, sel.g, sel.b, 0.95);
        cr.set_line_width(2.5);
        cr.rounded_rect(n.posx - 4.0, n.posy - 4.0, n.width + 8.0, n.height + 8.0, 9.0);
        cr.stroke();
    }

    // Node border & fill
    let bw = n.style.nodeborderwidth.clamp(1.5, 5.0);
    let x = n.posx;
    let y = n.posy;
    let w = n.width;
    let h = n.height;

    match n.style.nodeborder {
        NodeBorder::Squared => {
            if filled {
                cr.set_rgba(fill_color.r, fill_color.g, fill_color.b, 0.95);
                cr.rectangle(x, y, w, h);
                cr.fill();
            }
            cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.95);
            cr.set_line_width(bw);
            cr.rectangle(x, y, w, h);
            cr.stroke();
        }
        NodeBorder::Rounded | NodeBorder::Pill => {
            let rad = if n.style.nodeborder == NodeBorder::Pill {
                h / 2.0
            } else {
                10.0
            };
            if filled {
                cr.set_rgba(fill_color.r, fill_color.g, fill_color.b, 0.95);
                cr.rounded_rect(x, y, w, h, rad);
                cr.fill();
            }
            cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.95);
            cr.set_line_width(bw);
            cr.rounded_rect(x, y, w, h, rad);
            cr.stroke();
        }
        NodeBorder::Bracket => {
            cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.95);
            cr.set_line_width(bw);
            cr.new_path();
            cr.move_to(x + 8.0, y);
            cr.line_to(x, y);
            cr.line_to(x, y + h);
            cr.line_to(x + 8.0, y + h);
            cr.move_to(x + w - 8.0, y);
            cr.line_to(x + w, y);
            cr.line_to(x + w, y + h);
            cr.line_to(x + w - 8.0, y + h);
            cr.stroke();
        }
        NodeBorder::Underlined => {
            if n.is_root() {
                cr.set_rgba(fill_color.r, fill_color.g, fill_color.b, 0.96);
                cr.rounded_rect(x, y, w, h, 10.0);
                cr.fill();
            } else {
                cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.92);
                cr.set_line_width(n.style.linkwidth.clamp(1.5, 5.0));
                cr.set_line_cap(CAIRO_LINE_CAP_ROUND);
                cr.new_path();
                cr.move_to(x, y + h);
                cr.line_to(x + w, y + h);
                cr.stroke();
            }
        }
        NodeBorder::None => {
            if n.is_root() {
                cr.set_rgba(fill_color.r, fill_color.g, fill_color.b, 0.96);
                cr.rounded_rect(x, y, w, h, 10.0);
                cr.fill();
            }
        }
    }

    // Node content layout vertically stacked
    let pad = n.style.nodepadding.max(4.0);
    let mut cursor_y = y + pad;
    let inner_x = x + pad;
    let inner_w = (w - 2.0 * pad).max(20.0);

    // 1. Optional image
    if let Some(ref img_ref) = n.image {
        if let Some(meta) = assets.get_meta(img_ref.id) {
            let src_w = if img_ref.crop_w > 0 {
                img_ref.crop_w as f64
            } else {
                meta.width
            };
            let src_h = if img_ref.crop_h > 0 {
                img_ref.crop_h as f64
            } else {
                meta.height
            };
            let dw = img_ref.size.max(32.0).min(inner_w);
            let dh = (dw * src_h / src_w.max(1.0)).max(20.0);
            let ix = inner_x + (inner_w - dw) / 2.0;

            cr.save();
            cr.rounded_rect(ix, cursor_y, dw, dh, 4.0);
            cr.clip();
            if meta.is_svg {
                if let Some(svg_doc) = assets.get_svg(img_ref.id) {
                    let _ = svg_doc.render(cr, ix, cursor_y, dw, dh);
                }
            } else if let Some(surf) = assets.get_surface(img_ref.id) {
                cr.translate(ix, cursor_y);
                cr.scale(dw / surf.width.max(1) as f64, dh / surf.height.max(1) as f64);
                cr.set_source_surface(surf, 0.0, 0.0);
                cr.paint();
            }
            cr.restore();
            cursor_y += dh + 6.0;
        }
    }

    // 2. Task checkbox + TODO badge + Title text
    let mut text_x = inner_x;
    if n.task_enabled {
        let bx = text_x;
        let by = cursor_y + 2.0;
        if n.task_done {
            cr.set_rgba(0.20, 0.72, 0.36, 1.0);
            cr.rounded_rect(bx, by, 14.0, 14.0, 3.0);
            cr.fill();
            cr.set_rgba(1.0, 1.0, 1.0, 1.0);
            cr.set_line_width(2.0);
            cr.new_path();
            cr.move_to(bx + 3.0, by + 7.5);
            cr.line_to(bx + 6.0, by + 10.5);
            cr.line_to(bx + 11.5, by + 4.0);
            cr.stroke();
        } else {
            cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.9);
            cr.set_line_width(1.8);
            cr.rounded_rect(bx, by, 14.0, 14.0, 3.0);
            cr.stroke();
        }
        text_x += 20.0;
    }

    if let Some(ref kw) = n.todo_keyword {
        let kw_w = (kw.len() as f64) * 7.2 + 8.0;
        let kc = if n.task_done {
            Rgba::rgb(0.22, 0.65, 0.36)
        } else {
            Rgba::rgb(0.84, 0.38, 0.24)
        };
        cr.set_rgba(kc.r, kc.g, kc.b, 0.9);
        cr.rounded_rect(text_x, cursor_y + 1.0, kw_w, 16.0, 4.0);
        cr.fill();
        if let Ok(kl) = build_rich_pango_layout(
            cr,
            kw,
            "Sans Bold 8",
            kw_w,
            Rgba::rgb(1.0, 1.0, 1.0),
            "center",
            latex_cache,
        ) {
            cr.set_rgba(1.0, 1.0, 1.0, 1.0);
            kl.update_and_show(cr, text_x, cursor_y + 2.0);
        }
        text_x += kw_w + 6.0;
    }

    if !n.text.trim().is_empty() {
        let draw_w = (inner_w - (text_x - inner_x)).max(20.0);
        if let Ok(layout) = build_rich_pango_layout(
            cr,
            &n.text,
            &n.style.nodefont,
            draw_w,
            text_fg,
            &n.style.nodetextalign,
            latex_cache,
        ) {
            let (_pw, ph) = layout.pixel_size();
            cr.set_rgba(text_fg.r, text_fg.g, text_fg.b, 1.0);
            layout.update_and_show(cr, text_x, cursor_y);
            cursor_y += ph + 4.0;
        }
    }

    // Optional small indicators on right of title (note / url)
    let mut ind_x = x + w - pad - 12.0;
    if !n.note.trim().is_empty() {
        cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.8);
        cr.rounded_rect(ind_x, y + pad + 2.0, 11.0, 11.0, 2.5);
        cr.fill();
        ind_x -= 14.0;
    }
    if n.link.is_some() {
        cr.set_rgba(0.25, 0.62, 0.95, 0.9);
        cr.arc(ind_x + 5.5, y + pad + 7.5, 4.5, 0.0, std::f64::consts::TAU);
        cr.stroke();
    }

    // 3. Optional table
    if let Some(ref tbl) = n.table {
        draw_node_table(
            cr,
            tbl,
            inner_x,
            cursor_y,
            &n.style.nodefont,
            text_fg,
            branch_color,
            latex_cache,
        );
        let tm = measure_table(cr, tbl, &n.style.nodefont, latex_cache);
        cursor_y += tm.total_h + 4.0;
    }

    // 4. Optional tags row
    if !n.tags.is_empty() {
        let mut tx = inner_x;
        for tag in &n.tags {
            let pill_w = (tag.len() as f64) * 6.5 + 10.0;
            cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.22);
            cr.rounded_rect(tx, cursor_y, pill_w, 15.0, 4.0);
            cr.fill();
            if let Ok(tl) = build_rich_pango_layout(
                cr,
                tag,
                "Sans 8",
                pill_w,
                text_fg,
                "center",
                latex_cache,
            ) {
                cr.set_rgba(text_fg.r, text_fg.g, text_fg.b, 0.9);
                tl.update_and_show(cr, tx, cursor_y + 1.0);
            }
            tx += pill_w + 4.0;
        }
    }

    // 5. Fold indicator circle
    if !n.children.is_empty() && n.fold {
        let fb = &n.fold_bbox;
        cr.set_rgba(branch_color.r, branch_color.g, branch_color.b, 0.95);
        cr.arc(fb.x + fb.w / 2.0, fb.y + fb.h / 2.0, fb.w / 2.0, 0.0, std::f64::consts::TAU);
        cr.fill();
        let count_str = format!("{}", n.children.len());
        let cfg = branch_color.contrast_fg();
        if let Ok(fl) = build_rich_pango_layout(cr, &count_str, "Sans Bold 8", 24.0, cfg, "center", latex_cache) {
            let (fw, fh) = fl.pixel_size();
            cr.set_rgba(cfg.r, cfg.g, cfg.b, 1.0);
            fl.update_and_show(cr, fb.x + (fb.w - fw) / 2.0, fb.y + (fb.h - fh) / 2.0);
        }
    }

    // 6. Optional Callout bubble
    if let Some(ref co) = n.callout {
        let bg = doc.theme.callout_background;
        let cfg = bg.contrast_fg();
        if let Ok(cl) = build_rich_pango_layout(cr, &co.text, &n.style.calloutfont, 220.0, cfg, "left", latex_cache) {
            let (cw, ch) = cl.pixel_size();
            let cp = co.padding.max(4.0);
            let bw = cw + 2.0 * cp;
            let bh = ch + 2.0 * cp;
            let bx = x + w / 2.0 - bw / 2.0;
            let by = y - bh - 12.0;
            cr.set_rgba(bg.r, bg.g, bg.b, 0.95);
            cr.rounded_rect(bx, by, bw, bh, 6.0);
            cr.fill();
            cr.new_path();
            cr.move_to(x + w / 2.0 - 6.0, by + bh);
            cr.line_to(x + w / 2.0, by + bh + 9.0);
            cr.line_to(x + w / 2.0 + 6.0, by + bh);
            cr.close_path();
            cr.fill();
            cr.set_rgba(cfg.r, cfg.g, cfg.b, 1.0);
            cl.update_and_show(cr, bx + cp, by + cp);
        }
    }

    // 7. Resize handle on selected node's outer edge
    if is_sel {
        let rx = if n.resizer_on_left() {
            x - 5.0
        } else {
            x + w - 5.0
        };
        let ry = y + h / 2.0 - 8.0;
        let sel_bg = doc.theme.nodesel_background;
        let sel_fg = sel_bg.contrast_fg();
        cr.set_rgba(sel_bg.r, sel_bg.g, sel_bg.b, 0.96);
        cr.rounded_rect(rx, ry, 10.0, 16.0, 3.0);
        cr.fill();
        cr.set_rgba(sel_fg.r, sel_fg.g, sel_fg.b, 0.88);
        cr.set_line_width(1.2);
        cr.rounded_rect(rx, ry, 10.0, 16.0, 3.0);
        cr.stroke();
        cr.new_path();
        cr.move_to(rx + 3.5, ry + 4.0);
        cr.line_to(rx + 3.5, ry + 12.0);
        cr.move_to(rx + 6.5, ry + 4.0);
        cr.line_to(rx + 6.5, ry + 12.0);
        cr.stroke();
    }

    cr.restore();
    }

    if !n.fold {
        for &cid in &n.children {
            draw_node_recursive(cr, doc, cid, assets, latex_cache, view_world);
        }
    }
}

pub fn prepare_document_for_render(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
) {
    if doc.layout_dirty || doc.needs_measure || doc.dirty_measure_node.is_some() {
        let img_assets: Vec<ImageAsset> = doc.images.values().cloned().collect();
        for asset in img_assets {
            let _ = assets.ensure_asset(&asset);
        }
    }
    if doc.layout_dirty {
        doc.dirty_measure_node = None;
        relayout_document(doc, assets, latex_cache);
    } else if let Some(nid) = doc.dirty_measure_node.take() {
        measure_single_node(doc, nid, assets, latex_cache, false);
        ensure_all_tree_bboxes(doc);
        update_badge_hitboxes(doc);
    } else if doc.needs_measure {
        ensure_minimum_node_sizes(doc, assets, latex_cache);
        ensure_all_tree_bboxes(doc);
        update_badge_hitboxes(doc);
    }
    doc.layout_dirty = false;
    doc.needs_measure = false;
}

pub fn render_viewport_png(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
    width: i32,
    height: i32,
) -> Result<Vec<u8>, String> {
    let w = width.clamp(64, 4096);
    let h = height.clamp(64, 4096);
    doc.viewport_w = w;
    doc.viewport_h = h;

    prepare_document_for_render(doc, assets, latex_cache);

    let surface = CairoSurface::new_argb32(w, h)?;
    let cr = CairoContext::new(&surface)?;

    if doc.transparent_bg {
        cr.clear();
    } else {
        let bg = doc.theme.background;
        cr.set_rgba(bg.r, bg.g, bg.b, bg.a);
        cr.paint();
    }

    cr.save();
    let s = doc.scale.clamp(0.05, 8.0);
    cr.scale(s, s);
    cr.translate(-doc.origin_x, -doc.origin_y);

    let view_world = Rect {
        x: doc.origin_x - 32.0 / s,
        y: doc.origin_y - 32.0 / s,
        w: (w as f64 + 64.0) / s,
        h: (h as f64 + 64.0) / s,
    };
    draw_connections(&cr, doc, latex_cache, Some(&view_world));
    for &rid in &doc.root_ids {
        draw_node_recursive(&cr, doc, rid, assets, latex_cache, Some(&view_world));
    }

    cr.restore();
    surface.write_to_png_fast()
}

pub fn render_full_map_png(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
    max_dim: i32,
) -> Result<Vec<u8>, String> {
    prepare_document_for_render(doc, assets, latex_cache);
    let b = document_bounds(doc);
    let max_d = max_dim.clamp(200, 4096) as f64;
    let scale = (max_d / b.w.max(b.h).max(1.0)).min(1.5).max(0.15);
    let w = (b.w * scale).ceil().clamp(120.0, max_d) as i32;
    let h = (b.h * scale).ceil().clamp(120.0, max_d) as i32;

    let surface = CairoSurface::new_argb32(w, h)?;
    let cr = CairoContext::new(&surface)?;
    if doc.transparent_bg {
        cr.clear();
    } else {
        let bg = doc.theme.background;
        cr.set_rgba(bg.r, bg.g, bg.b, bg.a);
        cr.paint();
    }
    cr.save();
    cr.scale(scale, scale);
    cr.translate(-b.x, -b.y);
    draw_connections(&cr, doc, latex_cache, None);
    for &rid in &doc.root_ids {
        draw_node_recursive(&cr, doc, rid, assets, latex_cache, None);
    }
    cr.restore();
    surface.write_to_png()
}
