use crate::ffi::*;
use crate::latex::{split_latex_spans, LatexCache, SpanPart};
use crate::model::*;
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct DecodedAsset {
    pub width: f64,
    pub height: f64,
    pub is_svg: bool,
    pub raw_bytes: Vec<u8>,
}

pub struct AssetCache {
    meta: HashMap<i32, DecodedAsset>,
    surfaces: HashMap<i32, Arc<CairoSurface>>,
    svgs: HashMap<i32, Arc<RsvgDoc>>,
}

impl Default for AssetCache {
    fn default() -> Self {
        Self::new()
    }
}

impl AssetCache {
    pub fn new() -> Self {
        Self {
            meta: HashMap::new(),
            surfaces: HashMap::new(),
            svgs: HashMap::new(),
        }
    }

    pub fn ensure_asset(&mut self, asset: &ImageAsset) -> Option<&DecodedAsset> {
        if self.meta.contains_key(&asset.id) {
            return self.meta.get(&asset.id);
        }
        if asset.data.is_empty() {
            return None;
        }
        let is_svg = asset.ext.eq_ignore_ascii_case(".svg")
            || asset.data.starts_with(b"<svg")
            || asset.data.windows(4).take(64).any(|w| w == b"<svg");
        if is_svg {
            if let Ok(doc) = RsvgDoc::from_bytes(&asset.data, 96.0) {
                let (w, h) = doc.intrinsic_size_px().unwrap_or((120.0, 90.0));
                self.svgs.insert(asset.id, Arc::new(doc));
                self.meta.insert(
                    asset.id,
                    DecodedAsset {
                        width: w.max(1.0),
                        height: h.max(1.0),
                        is_svg: true,
                        raw_bytes: Vec::new(),
                    },
                );
                return self.meta.get(&asset.id);
            }
        }
        if let Ok(surf) = CairoSurface::from_pixbuf_bytes(&asset.data) {
            let w = surf.width as f64;
            let h = surf.height as f64;
            self.surfaces.insert(asset.id, Arc::new(surf));
            self.meta.insert(
                asset.id,
                DecodedAsset {
                    width: w,
                    height: h,
                    is_svg: false,
                    raw_bytes: Vec::new(),
                },
            );
            return self.meta.get(&asset.id);
        }
        None
    }

    pub fn get_surface(&self, id: i32) -> Option<&CairoSurface> {
        self.surfaces.get(&id).map(|s| s.as_ref())
    }

    pub fn get_svg(&self, id: i32) -> Option<&RsvgDoc> {
        self.svgs.get(&id).map(|s| s.as_ref())
    }

    pub fn get_meta(&self, id: i32) -> Option<&DecodedAsset> {
        self.meta.get(&id)
    }
}

pub fn build_rich_pango_layout(
    cr: &CairoContext,
    text: &str,
    font_str: &str,
    max_width_px: f64,
    text_color: Rgba,
    align: &str,
    latex_cache: &LatexCache,
) -> Result<PangoLayout, String> {
    let layout = PangoLayout::new(cr)?;
    let desc = PangoFontDesc::from_string(font_str);
    let font_pt = desc.size_pt().max(6.0);
    layout.set_font(&desc);
    layout.set_width_px(if max_width_px > 0.0 {
        Some(max_width_px)
    } else {
        None
    });
    layout.set_alignment(match align.to_ascii_lowercase().as_str() {
        "center" => PANGO_ALIGN_CENTER,
        "right" => PANGO_ALIGN_RIGHT,
        _ => PANGO_ALIGN_LEFT,
    });

    let spans = split_latex_spans(text);
    let has_formula = spans.iter().any(|p| matches!(p, SpanPart::Formula { .. }));
    if !has_formula {
        layout.set_text(text);
        return Ok(layout);
    }

    let latex_scale = (font_pt / 10.0) * 1.12;
    let mut display_str = String::with_capacity(text.len() + 16);
    let mut attrs = PangoAttrList::new();

    for part in spans {
        match part {
            SpanPart::Text(t) => display_str.push_str(&t),
            SpanPart::Formula {
                raw, normalized, ..
            } => {
                if let Some(compiled) = latex_cache.get_or_enqueue(&normalized) {
                    let start = display_str.len() as u32;
                    display_str.push('\u{FFFC}');
                    let end = display_str.len() as u32;
                    attrs.insert_shape(
                        start,
                        end,
                        InlineSvgShape {
                            svg_bytes: compiled.svg,
                            svg_hash: compiled.hash,
                            width_px: compiled.metrics.width_px * latex_scale,
                            ascent_px: compiled.metrics.ascent_px * latex_scale,
                            descent_px: compiled.metrics.descent_px * latex_scale,
                            color: [text_color.r, text_color.g, text_color.b, text_color.a],
                        },
                    );
                } else {
                    display_str.push_str(&raw);
                }
            }
        }
    }

    layout.set_text(&display_str);
    layout.set_attributes(&attrs);
    Ok(layout)
}

#[derive(Clone, Debug)]
pub struct TableMetrics {
    pub col_widths: Vec<f64>,
    pub row_heights: Vec<f64>,
    pub total_w: f64,
    pub total_h: f64,
}

pub fn measure_table(
    cr: &CairoContext,
    table: &NodeTable,
    font_str: &str,
    latex_cache: &LatexCache,
) -> TableMetrics {
    let rows = table.rows.max(1);
    let cols = table.columns.max(1);
    let mut col_widths = vec![28.0f64; cols];
    let mut row_heights = vec![24.0f64; rows];
    let cell_pad_x = 12.0;
    let cell_pad_y = 8.0;

    for c in &table.cells {
        if c.row >= rows || c.col >= cols {
            continue;
        }
        let Ok(layout) = build_rich_pango_layout(
            cr,
            &c.text,
            font_str,
            260.0,
            Rgba::rgb(0.0, 0.0, 0.0),
            &c.align,
            latex_cache,
        ) else {
            continue;
        };
        let (pw, ph) = layout.pixel_size();
        let need_w = pw + cell_pad_x;
        let need_h = ph + cell_pad_y;

        let cspan = c.colspan.max(1).min(cols - c.col);
        let rspan = c.rowspan.max(1).min(rows - c.row);

        let cur_w: f64 = col_widths[c.col..c.col + cspan].iter().sum();
        if need_w > cur_w {
            let add = (need_w - cur_w) / cspan as f64;
            for w in &mut col_widths[c.col..c.col + cspan] {
                *w += add;
            }
        }
        let cur_h: f64 = row_heights[c.row..c.row + rspan].iter().sum();
        if need_h > cur_h {
            let add = (need_h - cur_h) / rspan as f64;
            for h in &mut row_heights[c.row..c.row + rspan] {
                *h += add;
            }
        }
    }

    TableMetrics {
        total_w: col_widths.iter().sum(),
        total_h: row_heights.iter().sum(),
        col_widths,
        row_heights,
    }
}

pub fn measure_all_nodes(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
) {
    measure_all_nodes_inner(doc, assets, latex_cache, false);
}

pub fn ensure_minimum_node_sizes(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
) {
    measure_all_nodes_inner(doc, assets, latex_cache, true);
}

pub fn measure_single_node(
    doc: &mut MapDocument,
    id: i32,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
    grow_only: bool,
) {
    let Ok(surf) = CairoSurface::new_argb32(1, 1) else {
        return;
    };
    let Ok(cr) = CairoContext::new(&surf) else {
        return;
    };
    measure_single_node_with_cr(doc, &cr, id, assets, latex_cache, grow_only);
}

fn measure_all_nodes_inner(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
    grow_only: bool,
) {
    let Ok(surf) = CairoSurface::new_argb32(1, 1) else {
        return;
    };
    let Ok(cr) = CairoContext::new(&surf) else {
        return;
    };

    let ids: Vec<i32> = doc.nodes.keys().copied().collect();
    for id in ids {
        measure_single_node_with_cr(doc, &cr, id, assets, latex_cache, grow_only);
    }
}

pub fn node_badge_widths(n: &Node) -> (f64, f64) {
    let mut left_w = 0.0;
    if n.task_enabled {
        left_w += 20.0;
    }
    if let Some(ref kw) = n.todo_keyword {
        left_w += (kw.len() as f64) * 7.2 + 14.0;
    }
    let mut right_w = 0.0;
    if !n.note.trim().is_empty() {
        right_w += 16.0;
    }
    if n.link.is_some() {
        right_w += 16.0;
    }
    (left_w, right_w)
}

fn measure_single_node_with_cr(
    doc: &mut MapDocument,
    cr: &CairoContext,
    id: i32,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
    grow_only: bool,
) {
    let Some(n) = doc.nodes.get(&id).cloned() else {
        return;
    };
    let pad = n.style.nodepadding.max(4.0);
    let custom_w = n.custom_width;
    let max_w = custom_w
        .unwrap_or_else(|| n.maxwidth.max(n.style.nodewidth))
        .clamp(48.0, 1800.0);
    let (left_badge_w, right_badge_w) = node_badge_widths(&n);
    let text_wrap_w = if let Some(cw) = custom_w {
        (cw - left_badge_w - right_badge_w).max(48.0)
    } else {
        max_w
    };

    let text_layout = build_rich_pango_layout(
        cr,
        &n.text,
        &n.style.nodefont,
        text_wrap_w,
        doc.theme.foreground,
        &n.style.nodetextalign,
        latex_cache,
    );
    let (mut tw, mut th) = text_layout.map(|l| l.visual_size()).unwrap_or((40.0, 20.0));
    if n.text.trim().is_empty() && (n.image.is_some() || n.table.is_some()) {
        tw = 0.0;
        th = 0.0;
    } else {
        tw = tw.max(20.0);
        th = th.max(18.0);
    }

    let (mut img_w, mut img_h) = (0.0, 0.0);
    if let Some(ref img_ref) = n.image {
        if let Some(asset) = doc.images.get(&img_ref.id).cloned() {
            if let Some(meta) = assets.ensure_asset(&asset) {
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
                let dw = img_ref.size.max(32.0);
                let dh = (dw * src_h / src_w.max(1.0)).max(24.0);
                img_w = dw;
                img_h = dh;
            }
        }
    }

    let (tbl_w, tbl_h) = if let Some(ref tbl) = n.table {
        let tm = measure_table(cr, tbl, &n.style.nodefont, latex_cache);
        (tm.total_w, tm.total_h)
    } else {
        (0.0, 0.0)
    };

    let mut content_h = 0.0;
    if img_h > 0.0 {
        content_h += img_h;
    }
    if th > 0.0 {
        if content_h > 0.0 {
            content_h += 6.0;
        }
        content_h += th;
    }
    if tbl_h > 0.0 {
        if content_h > 0.0 {
            content_h += 6.0;
        }
        content_h += tbl_h;
    }
    if !n.tags.is_empty() {
        content_h += 18.0;
    }
    content_h = content_h.max(22.0);

    let min_custom = custom_w.unwrap_or(0.0);
    let text_total_w = if tw > 0.0 {
        tw + 6.0 + left_badge_w + right_badge_w
    } else {
        left_badge_w + right_badge_w
    };
    let content_w = text_total_w
        .max(img_w)
        .max(tbl_w)
        .max(min_custom)
        .max(28.0);
    let underline_extra = if n.style.nodeborder == NodeBorder::Underlined && !n.is_root() {
        (n.style.linkwidth.clamp(1.5, 5.0) * 0.5).ceil() + 3.0
    } else {
        0.0
    };
    let target_w = content_w + 2.0 * pad;
    let target_h = content_h + 2.0 * pad + underline_extra;
    if let Some(node_mut) = doc.nodes.get_mut(&id) {
        if grow_only {
            if target_w > node_mut.width {
                let dw = target_w - node_mut.width;
                if node_mut.is_root() {
                    node_mut.posx -= dw / 2.0;
                } else if node_mut.side == NodeSide::Left {
                    node_mut.posx -= dw;
                }
                node_mut.width = target_w;
            }
            if target_h > node_mut.height {
                let dh = target_h - node_mut.height;
                if node_mut.is_root() {
                    node_mut.posy -= dh / 2.0;
                }
                node_mut.height = target_h;
            }
        } else {
            let old_w = node_mut.width;
            let old_right = node_mut.posx + old_w;
            let resizer_left = node_mut.resizer_on_left();
            node_mut.width = target_w;
            node_mut.height = target_h;
            if resizer_left && (target_w - old_w).abs() > 0.01 {
                node_mut.posx = old_right - target_w;
            }
        }
    }
}

pub fn balance_sides(doc: &mut MapDocument) {
    let roots = doc.root_ids.clone();
    for rid in roots {
        let Some(root) = doc.nodes.get(&rid).cloned() else {
            continue;
        };
        let eff_layout = root.layout;
        let children = root.children;
        let half = (children.len() + 1) / 2;
        for (i, cid) in children.into_iter().enumerate() {
            let side = match eff_layout {
                LayoutKind::ToRight => NodeSide::Right,
                LayoutKind::ToLeft => NodeSide::Left,
                LayoutKind::Upwards => NodeSide::Top,
                LayoutKind::Downwards => NodeSide::Bottom,
                LayoutKind::Vertical => {
                    if i < half {
                        NodeSide::Bottom
                    } else {
                        NodeSide::Top
                    }
                }
                LayoutKind::Horizontal | LayoutKind::Manual => {
                    if i < half {
                        NodeSide::Right
                    } else {
                        NodeSide::Left
                    }
                }
            };
            propagate_side(doc, cid, side);
        }
    }
}

pub fn propagate_side(doc: &mut MapDocument, id: i32, side: NodeSide) {
    let children = if let Some(n) = doc.nodes.get_mut(&id) {
        n.side = side;
        n.children.clone()
    } else {
        return;
    };
    for cid in children {
        propagate_side(doc, cid, side);
    }
}

fn compute_subtree_extent(
    doc: &MapDocument,
    id: i32,
    layout: LayoutKind,
    side_override: Option<NodeSide>,
    horizontal_gap: f64,
    vertical_gap: f64,
    extents: &mut BTreeMap<i32, f64>,
) -> f64 {
    let Some(n) = doc.nodes.get(&id) else {
        return 0.0;
    };
    let eff_side = side_override.unwrap_or_else(|| layout.side_mapping(n.side));
    let axis_is_horiz = eff_side.is_horizontal();
    let self_span = if axis_is_horiz { n.height } else { n.width };
    let gap = if axis_is_horiz { vertical_gap } else { horizontal_gap };

    if n.fold || n.children.is_empty() {
        extents.insert(id, self_span);
        return self_span;
    }

    let mut sum = 0.0;
    for (idx, &cid) in n.children.iter().enumerate() {
        if idx > 0 {
            sum += gap;
        }
        sum += compute_subtree_extent(doc, cid, layout, Some(eff_side), horizontal_gap, vertical_gap, extents);
    }
    let total = self_span.max(sum);
    extents.insert(id, total);
    total
}

fn position_children_side(
    doc: &mut MapDocument,
    parent_x: f64,
    parent_y: f64,
    parent_w: f64,
    parent_h: f64,
    children: &[i32],
    side: NodeSide,
    layout: LayoutKind,
    branch_gap: f64,
    sibling_gap: f64,
    extents: &BTreeMap<i32, f64>,
) {
    if children.is_empty() {
        return;
    }

    match side {
        NodeSide::Right | NodeSide::Left => {
            let total_h: f64 = children
                .iter()
                .map(|cid| extents.get(cid).copied().unwrap_or(36.0))
                .sum::<f64>()
                + sibling_gap * (children.len().saturating_sub(1) as f64);
            let mut cursor_y = parent_y + parent_h / 2.0 - total_h / 2.0;
            for &cid in children {
                let c_ext = extents.get(&cid).copied().unwrap_or(36.0);
                let (cw, ch, fold, sub_children, c_layout) = {
                    let c = &doc.nodes[&cid];
                    (c.width, c.height, c.fold, c.children.clone(), c.layout)
                };
                let cx = if side == NodeSide::Right {
                    parent_x + parent_w + branch_gap
                } else {
                    parent_x - branch_gap - cw
                };
                let cy = cursor_y + (c_ext - ch) / 2.0;
                if let Some(c) = doc.nodes.get_mut(&cid) {
                    c.posx = cx;
                    c.posy = cy;
                    c.side = side;
                    c.treesize = c_ext;
                }
                if !fold && !sub_children.is_empty() {
                    position_children_side(
                        doc,
                        cx,
                        cy,
                        cw,
                        ch,
                        &sub_children,
                        side,
                        c_layout,
                        branch_gap * 0.85,
                        sibling_gap,
                        extents,
                    );
                }
                cursor_y += c_ext + sibling_gap;
            }
        }
        NodeSide::Bottom | NodeSide::Top => {
            let total_w: f64 = children
                .iter()
                .map(|cid| extents.get(cid).copied().unwrap_or(80.0))
                .sum::<f64>()
                + sibling_gap * (children.len().saturating_sub(1) as f64);
            let mut cursor_x = parent_x + parent_w / 2.0 - total_w / 2.0;
            for &cid in children {
                let c_ext = extents.get(&cid).copied().unwrap_or(80.0);
                let (cw, ch, fold, sub_children, c_layout) = {
                    let c = &doc.nodes[&cid];
                    (c.width, c.height, c.fold, c.children.clone(), c.layout)
                };
                let cy = if side == NodeSide::Bottom {
                    parent_y + parent_h + branch_gap
                } else {
                    parent_y - branch_gap - ch
                };
                let cx = cursor_x + (c_ext - cw) / 2.0;
                if let Some(c) = doc.nodes.get_mut(&cid) {
                    c.posx = cx;
                    c.posy = cy;
                    c.side = side;
                    c.treesize = c_ext;
                }
                if !fold && !sub_children.is_empty() {
                    position_children_side(
                        doc,
                        cx,
                        cy,
                        cw,
                        ch,
                        &sub_children,
                        side,
                        c_layout,
                        branch_gap * 0.85,
                        sibling_gap,
                        extents,
                    );
                }
                cursor_x += c_ext + sibling_gap;
            }
        }
    }
    let _ = layout;
}

pub fn compute_tree_bbox(doc: &mut MapDocument, id: i32) -> Rect {
    let Some(n) = doc.nodes.get(&id).cloned() else {
        return Rect::default();
    };
    let mut min_x = n.posx;
    let mut min_y = n.posy;
    let mut max_x = n.posx + n.width;
    let mut max_y = n.posy + n.height;

    if !n.fold {
        for &cid in &n.children {
            let cb = compute_tree_bbox(doc, cid);
            min_x = min_x.min(cb.x);
            min_y = min_y.min(cb.y);
            max_x = max_x.max(cb.x + cb.w);
            max_y = max_y.max(cb.y + cb.h);
        }
    }
    let rect = Rect {
        x: min_x,
        y: min_y,
        w: max_x - min_x,
        h: max_y - min_y,
    };
    if let Some(nm) = doc.nodes.get_mut(&id) {
        nm.tree_bbox = rect.clone();
    }
    rect
}

pub fn ensure_all_tree_bboxes(doc: &mut MapDocument) {
    let root_ids = doc.root_ids.clone();
    for rid in root_ids {
        compute_tree_bbox(doc, rid);
    }
}

pub fn update_single_badge_hitbox(n: &mut Node) {
    let pad = n.style.nodepadding.max(4.0);
    n.task_bbox = if n.task_enabled {
        Rect {
            x: n.posx + pad - 2.0,
            y: n.posy + n.height / 2.0 - 10.0,
            w: 20.0,
            h: 20.0,
        }
    } else {
        Rect::default()
    };
    n.fold_bbox = if !n.children.is_empty() {
        let fx = match n.side {
            NodeSide::Left => n.posx - 18.0,
            NodeSide::Right => n.posx + n.width + 2.0,
            NodeSide::Top | NodeSide::Bottom => n.posx + n.width / 2.0 - 8.0,
        };
        let fy = match n.side {
            NodeSide::Top => n.posy - 18.0,
            NodeSide::Bottom => n.posy + n.height + 2.0,
            NodeSide::Left | NodeSide::Right => n.posy + n.height / 2.0 - 8.0,
        };
        Rect {
            x: fx,
            y: fy,
            w: 16.0,
            h: 16.0,
        }
    } else {
        Rect::default()
    };
    let rx = if n.resizer_on_left() {
        n.posx - 8.0
    } else {
        n.posx + n.width - 8.0
    };
    n.resizer_bbox = Rect {
        x: rx,
        y: n.posy + n.height / 2.0 - 11.0,
        w: 16.0,
        h: 22.0,
    };
}

pub fn update_badge_hitboxes(doc: &mut MapDocument) {
    let ids: Vec<i32> = doc.nodes.keys().copied().collect();
    for id in ids {
        if let Some(n) = doc.nodes.get_mut(&id) {
            update_single_badge_hitbox(n);
        }
    }
}

pub fn relayout_document(
    doc: &mut MapDocument,
    assets: &mut AssetCache,
    latex_cache: &LatexCache,
) {
    measure_all_nodes(doc, assets, latex_cache);

    let root_ids = doc.root_ids.clone();
    let mut root_cursor_y = 0.0;

    for rid in root_ids {
        let Some(root) = doc.nodes.get(&rid).cloned() else {
            continue;
        };
        if root.layout == LayoutKind::Manual && doc.nodes.len() > 1 {
            compute_tree_bbox(doc, rid);
            continue;
        }

        let branch_gap = root.style.branchmargin.clamp(48.0, 96.0);
        let sibling_gap = (root.style.nodemargin * 1.8).clamp(12.0, 24.0);

        let mut right_children = Vec::new();
        let mut left_children = Vec::new();
        let mut top_children = Vec::new();
        let mut bottom_children = Vec::new();

        if !root.fold {
            for &cid in &root.children {
                let side = root.layout.side_mapping(doc.nodes[&cid].side);
                match side {
                    NodeSide::Right => right_children.push(cid),
                    NodeSide::Left => left_children.push(cid),
                    NodeSide::Top => top_children.push(cid),
                    NodeSide::Bottom => bottom_children.push(cid),
                }
            }
        }

        let mut extents: BTreeMap<i32, f64> = BTreeMap::new();
        for &cid in &right_children {
            compute_subtree_extent(
                doc,
                cid,
                root.layout,
                Some(NodeSide::Right),
                sibling_gap,
                sibling_gap,
                &mut extents,
            );
        }
        for &cid in &left_children {
            compute_subtree_extent(
                doc,
                cid,
                root.layout,
                Some(NodeSide::Left),
                sibling_gap,
                sibling_gap,
                &mut extents,
            );
        }
        for &cid in &top_children {
            compute_subtree_extent(
                doc,
                cid,
                root.layout,
                Some(NodeSide::Top),
                sibling_gap,
                sibling_gap,
                &mut extents,
            );
        }
        for &cid in &bottom_children {
            compute_subtree_extent(
                doc,
                cid,
                root.layout,
                Some(NodeSide::Bottom),
                sibling_gap,
                sibling_gap,
                &mut extents,
            );
        }

        if let Some(rm) = doc.nodes.get_mut(&rid) {
            rm.posx = 0.0;
            rm.posy = root_cursor_y;
        }

        position_children_side(
            doc,
            0.0,
            root_cursor_y,
            root.width,
            root.height,
            &right_children,
            NodeSide::Right,
            root.layout,
            branch_gap,
            sibling_gap,
            &extents,
        );
        position_children_side(
            doc,
            0.0,
            root_cursor_y,
            root.width,
            root.height,
            &left_children,
            NodeSide::Left,
            root.layout,
            branch_gap,
            sibling_gap,
            &extents,
        );
        position_children_side(
            doc,
            0.0,
            root_cursor_y,
            root.width,
            root.height,
            &top_children,
            NodeSide::Top,
            root.layout,
            branch_gap,
            sibling_gap,
            &extents,
        );
        position_children_side(
            doc,
            0.0,
            root_cursor_y,
            root.width,
            root.height,
            &bottom_children,
            NodeSide::Bottom,
            root.layout,
            branch_gap,
            sibling_gap,
            &extents,
        );

        let tb = compute_tree_bbox(doc, rid);
        // Normalize this root tree vertically so next root sits cleanly underneath
        let dy = root_cursor_y - tb.y;
        shift_subtree(doc, rid, 0.0, dy);
        let tb2 = compute_tree_bbox(doc, rid);
        root_cursor_y = tb2.y + tb2.h + 90.0;
    }

    update_badge_hitboxes(doc);
    doc.layout_dirty = false;
    doc.needs_measure = false;
}

pub fn shift_subtree(doc: &mut MapDocument, id: i32, dx: f64, dy: f64) {
    let children = if let Some(n) = doc.nodes.get_mut(&id) {
        n.posx += dx;
        n.posy += dy;
        n.children.clone()
    } else {
        return;
    };
    for cid in children {
        shift_subtree(doc, cid, dx, dy);
    }
}

pub fn document_bounds(doc: &MapDocument) -> Rect {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;

    for rid in &doc.root_ids {
        collect_visible_bounds(doc, *rid, &mut min_x, &mut min_y, &mut max_x, &mut max_y);
    }
    if !min_x.is_finite() {
        return Rect {
            x: -100.0,
            y: -100.0,
            w: 200.0,
            h: 200.0,
        };
    }
    Rect {
        x: min_x - 36.0,
        y: min_y - 36.0,
        w: (max_x - min_x) + 72.0,
        h: (max_y - min_y) + 72.0,
    }
}

fn collect_visible_bounds(
    doc: &MapDocument,
    id: i32,
    min_x: &mut f64,
    min_y: &mut f64,
    max_x: &mut f64,
    max_y: &mut f64,
) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };
    *min_x = min_x.min(n.posx);
    *min_y = min_y.min(n.posy);
    *max_x = max_x.max(n.posx + n.width);
    *max_y = max_y.max(n.posy + n.height);
    if !n.children.is_empty() {
        *min_x = min_x.min(n.fold_bbox.x);
        *min_y = min_y.min(n.fold_bbox.y);
        *max_x = max_x.max(n.fold_bbox.x + n.fold_bbox.w);
        *max_y = max_y.max(n.fold_bbox.y + n.fold_bbox.h);
    }
    if !n.fold {
        for &cid in &n.children {
            collect_visible_bounds(doc, cid, min_x, min_y, max_x, max_y);
        }
    }
}

pub fn zoom_fit(doc: &mut MapDocument) {
    let b = document_bounds(doc);
    let vw = (doc.viewport_w as f64).max(200.0);
    let vh = (doc.viewport_h as f64).max(160.0);
    let sx = (vw - 24.0) / b.w.max(1.0);
    let sy = (vh - 24.0) / b.h.max(1.0);
    doc.scale = sx.min(sy).clamp(0.15, 2.5);
    let rendered_w = b.w * doc.scale;
    let rendered_h = b.h * doc.scale;
    doc.origin_x = b.x - ((vw - rendered_w) / 2.0) / doc.scale;
    doc.origin_y = b.y - ((vh - rendered_h) / 2.0) / doc.scale;
}

pub fn center_on_node(doc: &mut MapDocument, id: i32) {
    let Some(n) = doc.nodes.get(&id) else {
        return;
    };
    let vw = (doc.viewport_w as f64).max(200.0) / doc.scale.max(0.1);
    let vh = (doc.viewport_h as f64).max(160.0) / doc.scale.max(0.1);
    doc.origin_x = n.posx + n.width / 2.0 - vw / 2.0;
    doc.origin_y = n.posy + n.height / 2.0 - vh / 2.0;
}

#[derive(serde::Serialize)]
pub struct HitResult {
    pub kind: &'static str, // "resizer", "fold", "task", "node", "none"
    pub node_id: Option<i32>,
}

pub fn hit_test(doc: &MapDocument, screen_x: f64, screen_y: f64) -> HitResult {
    let wx = doc.origin_x + screen_x / doc.scale.max(0.05);
    let wy = doc.origin_y + screen_y / doc.scale.max(0.05);

    if let Some(sel_id) = doc.selected_node {
        if let Some(sel) = doc.nodes.get(&sel_id) {
            let pad = 4.0 / doc.scale.max(0.25);
            let rb = Rect {
                x: sel.resizer_bbox.x - pad,
                y: sel.resizer_bbox.y - pad,
                w: sel.resizer_bbox.w + 2.0 * pad,
                h: sel.resizer_bbox.h + 2.0 * pad,
            };
            if rb.contains(wx, wy) {
                return HitResult {
                    kind: "resizer",
                    node_id: Some(sel_id),
                };
            }
        }
    }

    fn search(doc: &MapDocument, id: i32, wx: f64, wy: f64) -> Option<HitResult> {
        let n = doc.nodes.get(&id)?;
        if !n.children.is_empty() && n.fold_bbox.contains(wx, wy) {
            return Some(HitResult {
                kind: "fold",
                node_id: Some(id),
            });
        }
        if n.task_enabled && n.task_bbox.contains(wx, wy) {
            return Some(HitResult {
                kind: "task",
                node_id: Some(id),
            });
        }
        let body = Rect {
            x: n.posx - 4.0,
            y: n.posy - 4.0,
            w: n.width + 8.0,
            h: n.height + 8.0,
        };
        if body.contains(wx, wy) {
            return Some(HitResult {
                kind: "node",
                node_id: Some(id),
            });
        }
        if !n.fold {
            for &cid in &n.children {
                if let Some(hit) = search(doc, cid, wx, wy) {
                    return Some(hit);
                }
            }
        }
        None
    }

    for &rid in &doc.root_ids {
        if let Some(hit) = search(doc, rid, wx, wy) {
            return hit;
        }
    }
    HitResult {
        kind: "none",
        node_id: None,
    }
}
