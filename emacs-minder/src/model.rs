use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub fn rgb(r: f64, g: f64, b: f64) -> Self {
        Self { r, g, b, a: 1.0 }
    }

    pub fn from_hex_or_name(s: &str) -> Option<Self> {
        let t = s.trim();
        if let Some(hex) = t.strip_prefix('#') {
            if hex.len() == 6 {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f64 / 255.0;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f64 / 255.0;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f64 / 255.0;
                return Some(Self::rgb(r, g, b));
            } else if hex.len() == 8 {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f64 / 255.0;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f64 / 255.0;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f64 / 255.0;
                let a = u8::from_str_radix(&hex[6..8], 16).ok()? as f64 / 255.0;
                return Some(Self { r, g, b, a });
            }
        }
        match t.to_ascii_lowercase().as_str() {
            "white" => Some(Self::rgb(1.0, 1.0, 1.0)),
            "black" => Some(Self::rgb(0.0, 0.0, 0.0)),
            "grey" | "gray" => Some(Self::rgb(0.502, 0.502, 0.502)),
            "red" => Some(Self::rgb(1.0, 0.0, 0.0)),
            "gold" => Some(Self::rgb(1.0, 0.843, 0.0)),
            _ => None,
        }
    }

    pub fn to_hex(&self) -> String {
        let r = (self.r.clamp(0.0, 1.0) * 255.0).round() as u8;
        let g = (self.g.clamp(0.0, 1.0) * 255.0).round() as u8;
        let b = (self.b.clamp(0.0, 1.0) * 255.0).round() as u8;
        format!("#{r:02x}{g:02x}{b:02x}")
    }

    pub fn is_dark(&self) -> bool {
        let lum = 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
        lum < 0.45
    }

    pub fn contrast_fg(&self) -> Self {
        if self.is_dark() {
            Self::rgb(0.97, 0.97, 0.98)
        } else {
            Self::rgb(0.08, 0.09, 0.11)
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThemePalette {
    pub name: String,
    pub label: String,
    pub background: Rgba,
    pub foreground: Rgba,
    pub root_background: Rgba,
    pub root_foreground: Rgba,
    pub nodesel_background: Rgba,
    pub nodesel_foreground: Rgba,
    pub connection_background: Rgba,
    pub connection_foreground: Rgba,
    pub callout_background: Rgba,
    pub link_colors: [Rgba; 8],
}

impl ThemePalette {
    pub fn by_name(name: &str) -> Self {
        match name.to_ascii_lowercase().as_str() {
            "dark" => Self {
                name: "dark".into(),
                label: "Dark".into(),
                background: Rgba::from_hex_or_name("#333333").unwrap(),
                foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                root_background: Rgba::from_hex_or_name("#d4d4d4").unwrap(),
                root_foreground: Rgba::from_hex_or_name("#000000").unwrap(),
                nodesel_background: Rgba::from_hex_or_name("#64baff").unwrap(),
                nodesel_foreground: Rgba::from_hex_or_name("#000000").unwrap(),
                connection_background: Rgba::from_hex_or_name("#7e8087").unwrap(),
                connection_foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                callout_background: Rgba::from_hex_or_name("#f9c440").unwrap(),
                link_colors: [
                    Rgba::from_hex_or_name("#a3242a").unwrap(),
                    Rgba::from_hex_or_name("#f37329").unwrap(),
                    Rgba::from_hex_or_name("#f9c440").unwrap(),
                    Rgba::from_hex_or_name("#68b723").unwrap(),
                    Rgba::from_hex_or_name("#3689e6").unwrap(),
                    Rgba::from_hex_or_name("#7a36b1").unwrap(),
                    Rgba::from_hex_or_name("#715344").unwrap(),
                    Rgba::from_hex_or_name("#bbbbbb").unwrap(),
                ],
            },
            "solarized_dark" => Self {
                name: "solarized_dark".into(),
                label: "Solarized Dark".into(),
                background: Rgba::from_hex_or_name("#002B36").unwrap(),
                foreground: Rgba::from_hex_or_name("#93A1A1").unwrap(),
                root_background: Rgba::from_hex_or_name("#d4d4d4").unwrap(),
                root_foreground: Rgba::from_hex_or_name("#000000").unwrap(),
                nodesel_background: Rgba::from_hex_or_name("#586E75").unwrap(),
                nodesel_foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                connection_background: Rgba::from_hex_or_name("#7e8087").unwrap(),
                connection_foreground: Rgba::from_hex_or_name("#d4d4d4").unwrap(),
                callout_background: Rgba::from_hex_or_name("#f9c440").unwrap(),
                link_colors: [
                    Rgba::from_hex_or_name("#a3242a").unwrap(),
                    Rgba::from_hex_or_name("#CB4B16").unwrap(),
                    Rgba::from_hex_or_name("#B58900").unwrap(),
                    Rgba::from_hex_or_name("#859900").unwrap(),
                    Rgba::from_hex_or_name("#268BD2").unwrap(),
                    Rgba::from_hex_or_name("#6C71C4").unwrap(),
                    Rgba::from_hex_or_name("#D33682").unwrap(),
                    Rgba::from_hex_or_name("#2AA198").unwrap(),
                ],
            },
            "solarized_light" => Self {
                name: "solarized_light".into(),
                label: "Solarized Light".into(),
                background: Rgba::from_hex_or_name("#FDF6E3").unwrap(),
                foreground: Rgba::from_hex_or_name("#586E75").unwrap(),
                root_background: Rgba::from_hex_or_name("#839496").unwrap(),
                root_foreground: Rgba::from_hex_or_name("#FDF6E3").unwrap(),
                nodesel_background: Rgba::from_hex_or_name("#586E75").unwrap(),
                nodesel_foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                connection_background: Rgba::from_hex_or_name("#606060").unwrap(),
                connection_foreground: Rgba::from_hex_or_name("#FDF6E3").unwrap(),
                callout_background: Rgba::from_hex_or_name("#f9c440").unwrap(),
                link_colors: [
                    Rgba::from_hex_or_name("#DC322F").unwrap(),
                    Rgba::from_hex_or_name("#CB4B16").unwrap(),
                    Rgba::from_hex_or_name("#B58900").unwrap(),
                    Rgba::from_hex_or_name("#859900").unwrap(),
                    Rgba::from_hex_or_name("#268BD2").unwrap(),
                    Rgba::from_hex_or_name("#6C71C4").unwrap(),
                    Rgba::from_hex_or_name("#D33682").unwrap(),
                    Rgba::from_hex_or_name("#2AA198").unwrap(),
                ],
            },
            _ => Self {
                name: "default".into(),
                label: "Light".into(),
                background: Rgba::from_hex_or_name("#ffffff").unwrap(),
                foreground: Rgba::from_hex_or_name("#2e3440").unwrap(),
                root_background: Rgba::from_hex_or_name("#3689e6").unwrap(),
                root_foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                nodesel_background: Rgba::from_hex_or_name("#64baff").unwrap(),
                nodesel_foreground: Rgba::from_hex_or_name("#1a1a1a").unwrap(),
                connection_background: Rgba::from_hex_or_name("#7e8087").unwrap(),
                connection_foreground: Rgba::from_hex_or_name("#ffffff").unwrap(),
                callout_background: Rgba::from_hex_or_name("#f9c440").unwrap(),
                link_colors: [
                    Rgba::from_hex_or_name("#c6262e").unwrap(),
                    Rgba::from_hex_or_name("#f37329").unwrap(),
                    Rgba::from_hex_or_name("#f9c440").unwrap(),
                    Rgba::from_hex_or_name("#68b723").unwrap(),
                    Rgba::from_hex_or_name("#3689e6").unwrap(),
                    Rgba::from_hex_or_name("#7a36b1").unwrap(),
                    Rgba::from_hex_or_name("#de3e80").unwrap(),
                    Rgba::from_hex_or_name("#0e9a83").unwrap(),
                ],
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeSide {
    Left,
    Right,
    Top,
    Bottom,
}

impl NodeSide {
    pub fn from_str(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "left" => Self::Left,
            "top" => Self::Top,
            "bottom" => Self::Bottom,
            _ => Self::Right,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Top => "top",
            Self::Bottom => "bottom",
        }
    }

    pub fn is_horizontal(&self) -> bool {
        matches!(self, Self::Left | Self::Right)
    }

    pub fn is_vertical(&self) -> bool {
        matches!(self, Self::Top | Self::Bottom)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LayoutKind {
    Horizontal,
    ToRight,
    ToLeft,
    Vertical,
    Upwards,
    Downwards,
    Manual,
}

impl LayoutKind {
    pub fn from_str(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "to right" | "right" => Self::ToRight,
            "to left" | "left" => Self::ToLeft,
            "vertical" => Self::Vertical,
            "upwards" | "up" => Self::Upwards,
            "downwards" | "down" => Self::Downwards,
            "manual" => Self::Manual,
            _ => Self::Horizontal,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Horizontal => "Horizontal",
            Self::ToRight => "To right",
            Self::ToLeft => "To left",
            Self::Vertical => "Vertical",
            Self::Upwards => "Upwards",
            Self::Downwards => "Downwards",
            Self::Manual => "Manual",
        }
    }

    pub fn side_mapping(&self, side: NodeSide) -> NodeSide {
        match self {
            Self::ToRight => NodeSide::Right,
            Self::ToLeft => NodeSide::Left,
            Self::Upwards => NodeSide::Top,
            Self::Downwards => NodeSide::Bottom,
            Self::Horizontal => match side {
                NodeSide::Left | NodeSide::Top => NodeSide::Left,
                NodeSide::Right | NodeSide::Bottom => NodeSide::Right,
            },
            Self::Vertical => match side {
                NodeSide::Left | NodeSide::Top => NodeSide::Top,
                NodeSide::Right | NodeSide::Bottom => NodeSide::Bottom,
            },
            Self::Manual => side,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkType {
    Straight,
    Squared,
    Curved,
    Rounded,
}

impl LinkType {
    pub fn from_str(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "straight" => Self::Straight,
            "squared" => Self::Squared,
            "rounded" => Self::Rounded,
            _ => Self::Curved,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Straight => "straight",
            Self::Squared => "squared",
            Self::Curved => "curved",
            Self::Rounded => "rounded",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeBorder {
    None,
    Underlined,
    Squared,
    Rounded,
    Pill,
    Bracket,
}

impl NodeBorder {
    pub fn from_str(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" => Self::None,
            "squared" => Self::Squared,
            "rounded" => Self::Rounded,
            "pill" => Self::Pill,
            "bracket" => Self::Bracket,
            _ => Self::Underlined,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Underlined => "underlined",
            Self::Squared => "squared",
            Self::Rounded => "rounded",
            Self::Pill => "pill",
            Self::Bracket => "bracket",
        }
    }

    pub fn is_fillable(&self) -> bool {
        matches!(self, Self::Squared | Self::Rounded | Self::Pill)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeStyle {
    pub branchmargin: f64,
    pub branchradius: f64,
    pub linktype: LinkType,
    pub linkwidth: f64,
    pub linkarrow: bool,
    pub linkarrowsize: f64,
    pub linkdash: String,
    pub nodeborder: NodeBorder,
    pub nodeborderwidth: f64,
    pub nodefill: bool,
    pub nodemargin: f64,
    pub nodepadding: f64,
    pub nodefont: String,
    pub nodetextalign: String,
    pub nodewidth: f64,
    pub nodemarkup: bool,
    pub connectiondash: String,
    pub connectionlwidth: f64,
    pub connectionarrow: String,
    pub connectionpadding: f64,
    pub connectionfont: String,
    pub connectiontwidth: f64,
    pub calloutfont: String,
    pub calloutpadding: f64,
    pub calloutptrwidth: f64,
    pub calloutptrlength: f64,
}

impl Default for NodeStyle {
    fn default() -> Self {
        Self {
            branchmargin: 100.0,
            branchradius: 25.0,
            linktype: LinkType::Curved,
            linkwidth: 4.0,
            linkarrow: false,
            linkarrowsize: 2.0,
            linkdash: "solid".into(),
            nodeborder: NodeBorder::Underlined,
            nodeborderwidth: 4.0,
            nodefill: false,
            nodemargin: 8.0,
            nodepadding: 6.0,
            nodefont: "Sans 11".into(),
            nodetextalign: "left".into(),
            nodewidth: 220.0,
            nodemarkup: true,
            connectiondash: "dotted".into(),
            connectionlwidth: 2.0,
            connectionarrow: "fromto".into(),
            connectionpadding: 3.0,
            connectionfont: "Sans 10".into(),
            connectiontwidth: 100.0,
            calloutfont: "Sans 12".into(),
            calloutpadding: 5.0,
            calloutptrwidth: 20.0,
            calloutptrlength: 20.0,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px <= self.x + self.w && py >= self.y && py <= self.y + self.h
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TableCell {
    pub row: usize,
    pub col: usize,
    pub rowspan: usize,
    pub colspan: usize,
    pub text: String,
    pub align: String,
    pub highlighted: bool,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeTable {
    pub rows: usize,
    pub columns: usize,
    pub cells: Vec<TableCell>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeImageRef {
    pub id: i32,
    pub crop_x: i32,
    pub crop_y: i32,
    pub crop_w: i32,
    pub crop_h: i32,
    pub size: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeLink {
    pub id: i32,
    pub doc: String,
    pub url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Callout {
    pub text: String,
    pub padding: f64,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Node {
    pub id: i32,
    pub text: String,
    pub note: String,
    pub maxwidth: f64,
    #[serde(default)]
    pub custom_width: Option<f64>,
    pub posx: f64,
    pub posy: f64,
    pub width: f64,
    pub height: f64,
    pub treesize: f64,
    pub tree_bbox: Rect,
    pub fold_bbox: Rect,
    pub task_bbox: Rect,
    #[serde(default)]
    pub resizer_bbox: Rect,
    pub side: NodeSide,
    pub fold: bool,
    pub sequence: bool,
    pub group: bool,
    pub summarized: bool,
    pub color: Option<Rgba>,
    pub colorroot: bool,
    pub layout: LayoutKind,
    pub task_enabled: bool,
    pub task_done: bool,
    pub todo_keyword: Option<String>,
    pub priority: Option<String>,
    pub org_properties: Vec<(String, String)>,
    pub is_org_title_root: bool,
    pub is_org_list_item: bool,
    pub tags: Vec<String>,
    pub link: Option<String>,
    pub node_link: Option<NodeLink>,
    pub image: Option<NodeImageRef>,
    pub table: Option<NodeTable>,
    pub callout: Option<Callout>,
    pub sticker: Option<String>,
    pub style: NodeStyle,
    pub parent: Option<i32>,
    pub children: Vec<i32>,
}

impl Node {
    pub fn new(id: i32, text: String) -> Self {
        Self {
            id,
            text,
            note: String::new(),
            maxwidth: 220.0,
            custom_width: None,
            posx: 0.0,
            posy: 0.0,
            width: 80.0,
            height: 36.0,
            treesize: 36.0,
            tree_bbox: Rect::default(),
            fold_bbox: Rect::default(),
            task_bbox: Rect::default(),
            resizer_bbox: Rect::default(),
            side: NodeSide::Right,
            fold: false,
            sequence: false,
            group: false,
            summarized: false,
            color: None,
            colorroot: false,
            layout: LayoutKind::Horizontal,
            task_enabled: false,
            task_done: false,
            todo_keyword: None,
            priority: None,
            org_properties: Vec::new(),
            is_org_title_root: false,
            is_org_list_item: false,
            tags: Vec::new(),
            link: None,
            node_link: None,
            image: None,
            table: None,
            callout: None,
            sticker: None,
            style: NodeStyle::default(),
            parent: None,
            children: Vec::new(),
        }
    }

    pub fn is_root(&self) -> bool {
        self.parent.is_none()
    }

    pub fn resizer_on_left(&self) -> bool {
        !self.is_root() && self.side == NodeSide::Left
    }

    pub fn total_children_count(&self, nodes: &BTreeMap<i32, Node>) -> usize {
        let mut count = self.children.len();
        for cid in &self.children {
            if let Some(c) = nodes.get(cid) {
                count += c.total_children_count(nodes);
            }
        }
        count
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Connection {
    pub from_id: i32,
    pub to_id: i32,
    pub drag_x: f64,
    pub drag_y: f64,
    pub title: String,
    pub note: String,
    pub color: Option<Rgba>,
    pub sticker: Option<String>,
    pub style: NodeStyle,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NodeGroup {
    pub nodes: Vec<i32>,
    pub color: Option<Rgba>,
    pub note: String,
}

#[derive(Clone, Debug)]
pub struct ImageAsset {
    pub id: i32,
    pub uri: String,
    pub ext: String,
    pub data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SourceFormat {
    New,
    MinderXml,
    MinderTarGz,
    Org,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DocumentSnapshot {
    pub theme_name: String,
    pub global_style: NodeStyle,
    pub level_styles: Vec<NodeStyle>,
    pub root_ids: Vec<i32>,
    pub nodes: BTreeMap<i32, Node>,
    pub connections: Vec<Connection>,
    pub groups: Vec<NodeGroup>,
    pub tags: Vec<(String, Option<String>)>,
    pub selected_node: Option<i32>,
    pub next_id: i32,
    pub color_index: usize,
}

pub struct MapDocument {
    pub source_format: SourceFormat,
    pub file_path: Option<String>,
    pub org_preamble: Vec<String>,
    pub version: String,
    pub etag: String,
    pub parent_etag: String,
    pub theme_name: String,
    pub theme: ThemePalette,
    pub transparent_bg: bool,
    pub global_style: NodeStyle,
    pub level_styles: Vec<NodeStyle>,
    pub root_ids: Vec<i32>,
    pub nodes: BTreeMap<i32, Node>,
    pub connections: Vec<Connection>,
    pub groups: Vec<NodeGroup>,
    pub images: BTreeMap<i32, ImageAsset>,
    pub tags: Vec<(String, Option<String>)>,
    pub braindump: Vec<String>,
    pub selected_node: Option<i32>,
    pub selected_connection: Option<usize>,
    pub search_matches: Vec<i32>,
    pub search_cursor: usize,
    pub scale: f64,
    pub origin_x: f64,
    pub origin_y: f64,
    pub viewport_w: i32,
    pub viewport_h: i32,
    pub dirty: bool,
    pub layout_dirty: bool,
    pub needs_measure: bool,
    pub dirty_measure_node: Option<i32>,
    pub next_id: i32,
    pub next_image_id: i32,
    pub color_index: usize,
    pub undo_stack: Vec<DocumentSnapshot>,
    pub redo_stack: Vec<DocumentSnapshot>,
    pub connect_from: Option<i32>,
}

impl Default for MapDocument {
    fn default() -> Self {
        Self::new_empty()
    }
}

impl MapDocument {
    pub fn new_empty() -> Self {
        let mut nodes = BTreeMap::new();
        let mut root = Node::new(0, "Central Topic".to_string());
        root.style = NodeStyle::default();
        root.style.nodeborder = NodeBorder::Rounded;
        root.style.nodefont = "Sans Bold 13".into();
        nodes.insert(0, root);
        Self {
            source_format: SourceFormat::New,
            file_path: None,
            org_preamble: Vec::new(),
            version: "2.0.9".into(),
            etag: "0".into(),
            parent_etag: String::new(),
            theme_name: "default".into(),
            theme: ThemePalette::by_name("default"),
            transparent_bg: true,
            global_style: NodeStyle::default(),
            level_styles: Vec::new(),
            root_ids: vec![0],
            nodes,
            connections: Vec::new(),
            groups: Vec::new(),
            images: BTreeMap::new(),
            tags: Vec::new(),
            braindump: Vec::new(),
            selected_node: Some(0),
            selected_connection: None,
            search_matches: Vec::new(),
            search_cursor: 0,
            scale: 1.0,
            origin_x: 0.0,
            origin_y: 0.0,
            viewport_w: 1200,
            viewport_h: 800,
            dirty: false,
            layout_dirty: true,
            needs_measure: true,
            dirty_measure_node: None,
            next_id: 1,
            next_image_id: 1,
            color_index: 0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            connect_from: None,
        }
    }

    pub fn alloc_id(&mut self) -> i32 {
        while self.nodes.contains_key(&self.next_id) {
            self.next_id += 1;
        }
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    pub fn next_branch_color(&mut self) -> Rgba {
        let c = self.theme.link_colors[self.color_index % self.theme.link_colors.len()];
        self.color_index = (self.color_index + 1) % self.theme.link_colors.len();
        c
    }

    pub fn push_undo(&mut self) {
        let snap = DocumentSnapshot {
            theme_name: self.theme_name.clone(),
            global_style: self.global_style.clone(),
            level_styles: self.level_styles.clone(),
            root_ids: self.root_ids.clone(),
            nodes: self.nodes.clone(),
            connections: self.connections.clone(),
            groups: self.groups.clone(),
            tags: self.tags.clone(),
            selected_node: self.selected_node,
            next_id: self.next_id,
            color_index: self.color_index,
        };
        self.undo_stack.push(snap);
        if self.undo_stack.len() > 100 {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    fn apply_snapshot(&mut self, snap: DocumentSnapshot) {
        self.theme_name = snap.theme_name;
        self.theme = ThemePalette::by_name(&self.theme_name);
        self.global_style = snap.global_style;
        self.level_styles = snap.level_styles;
        self.root_ids = snap.root_ids;
        self.nodes = snap.nodes;
        self.connections = snap.connections;
        self.groups = snap.groups;
        self.tags = snap.tags;
        self.selected_node = snap.selected_node;
        self.next_id = snap.next_id;
        self.color_index = snap.color_index;
        self.layout_dirty = true;
        self.needs_measure = true;
        self.dirty_measure_node = None;
        self.dirty = true;
    }

    pub fn undo(&mut self) -> bool {
        if let Some(prev) = self.undo_stack.pop() {
            let cur = DocumentSnapshot {
                theme_name: self.theme_name.clone(),
                global_style: self.global_style.clone(),
                level_styles: self.level_styles.clone(),
                root_ids: self.root_ids.clone(),
                nodes: self.nodes.clone(),
                connections: self.connections.clone(),
                groups: self.groups.clone(),
                tags: self.tags.clone(),
                selected_node: self.selected_node,
                next_id: self.next_id,
                color_index: self.color_index,
            };
            self.redo_stack.push(cur);
            self.apply_snapshot(prev);
            true
        } else {
            false
        }
    }

    pub fn redo(&mut self) -> bool {
        if let Some(next) = self.redo_stack.pop() {
            let cur = DocumentSnapshot {
                theme_name: self.theme_name.clone(),
                global_style: self.global_style.clone(),
                level_styles: self.level_styles.clone(),
                root_ids: self.root_ids.clone(),
                nodes: self.nodes.clone(),
                connections: self.connections.clone(),
                groups: self.groups.clone(),
                tags: self.tags.clone(),
                selected_node: self.selected_node,
                next_id: self.next_id,
                color_index: self.color_index,
            };
            self.undo_stack.push(cur);
            self.apply_snapshot(next);
            true
        } else {
            false
        }
    }

    pub fn get_effective_color(&self, id: i32) -> Option<Rgba> {
        let mut cur = self.nodes.get(&id)?;
        loop {
            if cur.color.is_some() {
                return cur.color;
            }
            if let Some(pid) = cur.parent {
                cur = self.nodes.get(&pid)?;
            } else {
                return None;
            }
        }
    }

    pub fn add_image_from_file(&mut self, path: &str) -> Result<i32, String> {
        let data = std::fs::read(path).map_err(|e| format!("Failed to read {path}: {e}"))?;
        let ext = std::path::Path::new(path)
            .extension()
            .and_then(|s| s.to_str())
            .map(|e| format!(".{}", e.to_ascii_lowercase()))
            .unwrap_or_else(|| ".png".to_string());
        while self.images.contains_key(&self.next_image_id) {
            self.next_image_id += 1;
        }
        let id = self.next_image_id;
        self.next_image_id += 1;
        let uri = format!("file://{path}");
        self.images.insert(id, ImageAsset { id, uri, ext, data });
        Ok(id)
    }

    pub fn ensure_valid_selection(&mut self) {
        if let Some(sel) = self.selected_node {
            if !self.nodes.contains_key(&sel) {
                self.selected_node = self.root_ids.first().copied();
            }
        } else {
            self.selected_node = self.root_ids.first().copied();
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum EditCommand {
    SelectNode { id: i32 },
    SelectClear,
    SelectRelative { dir: String },
    AddChild { parent_id: Option<i32>, text: Option<String> },
    AddSibling { ref_id: Option<i32>, text: Option<String> },
    AddParent { child_id: Option<i32>, text: Option<String> },
    AddRoot { text: Option<String> },
    DeleteSelected,
    SetText { id: Option<i32>, text: String },
    SetNote { id: Option<i32>, note: String },
    ToggleFold { id: Option<i32> },
    FoldAll { fold: bool },
    ToggleTask { id: Option<i32> },
    SetTodoKeyword { id: Option<i32>, keyword: Option<String> },
    SetLayout { id: Option<i32>, layout: String },
    SetSide { id: Option<i32>, side: String },
    Balance,
    MoveSibling { id: Option<i32>, delta: i32 },
    SetLinktype { linktype: String },
    SetNodeborder { nodeborder: String },
    SetFont { font: String },
    SetTheme { theme: String },
    SetTransparentBg { enabled: bool },
    SetEmacsColors {
        bg: String,
        fg: String,
        accent: String,
        selection_bg: String,
        selection_fg: String,
        branch_colors: Vec<String>,
    },
    StartOrFinishConnection { id: Option<i32> },
    AddConnection { from_id: i32, to_id: i32, title: Option<String> },
    DeleteConnection { index: usize },
    SetTable { id: Option<i32>, table: NodeTable },
    UpdateTableCell {
        id: Option<i32>,
        row: usize,
        col: usize,
        text: Option<String>,
        highlighted: Option<bool>,
        bold: Option<bool>,
    },
    AddTableRow { id: Option<i32> },
    AddTableCol { id: Option<i32> },
    AttachImageFile { id: Option<i32>, path: String, size: Option<f64> },
    DetachImage { id: Option<i32> },
    ResizeImage { id: Option<i32>, width: f64 },
    SetUrl { id: Option<i32>, url: Option<String> },
    SetTags { id: Option<i32>, tags: Vec<String> },
    SetCallout { id: Option<i32>, text: Option<String> },
    Pan { dx: f64, dy: f64 },
    MoveNode {
        id: Option<i32>,
        dx: f64,
        dy: f64,
        #[serde(default = "default_true")]
        move_subtree: bool,
        #[serde(default = "default_true")]
        record_undo: bool,
    },
    ResizeNode {
        id: Option<i32>,
        width: f64,
        #[serde(default = "default_true")]
        record_undo: bool,
    },
    Zoom {
        factor: f64,
        #[serde(default)]
        anchor_x: Option<f64>,
        #[serde(default)]
        anchor_y: Option<f64>,
    },
    ZoomReset,
    ZoomFit,
    CenterOnSelected,
    Undo,
    Redo,
    Search { query: String },
    SearchNext,
}

#[derive(Serialize)]
pub struct NodeStateJson {
    pub id: i32,
    pub text: String,
    pub note: String,
    pub level: usize,
    pub posx: f64,
    pub posy: f64,
    pub width: f64,
    pub height: f64,
    pub side: String,
    pub resizer_on_left: bool,
    pub fold: bool,
    pub layout: String,
    pub task_enabled: bool,
    pub task_done: bool,
    pub todo_keyword: Option<String>,
    pub tags: Vec<String>,
    pub url: Option<String>,
    pub has_image: bool,
    pub table: Option<NodeTable>,
    pub callout: Option<String>,
    pub parent: Option<i32>,
    pub children: Vec<i32>,
}

#[derive(Serialize)]
pub struct DocumentStateJson {
    pub format: String,
    pub file_path: Option<String>,
    pub dirty: bool,
    pub theme_name: String,
    pub transparent_bg: bool,
    pub scale: f64,
    pub origin_x: f64,
    pub origin_y: f64,
    pub viewport_w: i32,
    pub viewport_h: i32,
    pub node_count: usize,
    pub connection_count: usize,
    pub selected_node: Option<i32>,
    pub connect_from: Option<i32>,
    pub selected: Option<NodeStateJson>,
    pub root_ids: Vec<i32>,
    pub search_matches: Vec<i32>,
}

impl MapDocument {
    pub fn node_level(&self, id: i32) -> usize {
        let mut level = 0;
        let mut cur = self.nodes.get(&id);
        while let Some(n) = cur {
            if let Some(pid) = n.parent {
                level += 1;
                cur = self.nodes.get(&pid);
            } else {
                break;
            }
        }
        level
    }

    pub fn to_state_json(&self) -> DocumentStateJson {
        let selected = self.selected_node.and_then(|id| {
            let n = self.nodes.get(&id)?;
            Some(NodeStateJson {
                id: n.id,
                text: n.text.clone(),
                note: n.note.clone(),
                level: self.node_level(id),
                posx: n.posx,
                posy: n.posy,
                width: n.width,
                height: n.height,
                side: n.side.as_str().to_string(),
                resizer_on_left: n.resizer_on_left(),
                fold: n.fold,
                layout: n.layout.as_str().to_string(),
                task_enabled: n.task_enabled,
                task_done: n.task_done,
                todo_keyword: n.todo_keyword.clone(),
                tags: n.tags.clone(),
                url: n.link.clone(),
                has_image: n.image.is_some(),
                table: n.table.clone(),
                callout: n.callout.as_ref().map(|c| c.text.clone()),
                parent: n.parent,
                children: n.children.clone(),
            })
        });
        DocumentStateJson {
            format: match self.source_format {
                SourceFormat::New => "new",
                SourceFormat::MinderXml => "minder_xml",
                SourceFormat::MinderTarGz => "minder_tgz",
                SourceFormat::Org => "org",
            }
            .to_string(),
            file_path: self.file_path.clone(),
            dirty: self.dirty,
            theme_name: self.theme_name.clone(),
            transparent_bg: self.transparent_bg,
            scale: self.scale,
            origin_x: self.origin_x,
            origin_y: self.origin_y,
            viewport_w: self.viewport_w,
            viewport_h: self.viewport_h,
            node_count: self.nodes.len(),
            connection_count: self.connections.len(),
            selected_node: self.selected_node,
            connect_from: self.connect_from,
            selected,
            root_ids: self.root_ids.clone(),
            search_matches: self.search_matches.clone(),
        }
    }
}
