#![allow(non_camel_case_types, dead_code)]

use flate2::{write::ZlibEncoder, Compression};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io::Write;
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::sync::{Arc, Mutex, OnceLock};

pub const CAIRO_FORMAT_ARGB32: c_int = 0;
pub const CAIRO_STATUS_SUCCESS: c_int = 0;
pub const CAIRO_OPERATOR_CLEAR: c_int = 0;
pub const CAIRO_OPERATOR_SOURCE: c_int = 1;
pub const CAIRO_OPERATOR_OVER: c_int = 2;
pub const CAIRO_LINE_CAP_BUTT: c_int = 0;
pub const CAIRO_LINE_CAP_ROUND: c_int = 1;
pub const CAIRO_LINE_CAP_SQUARE: c_int = 2;
pub const CAIRO_LINE_JOIN_MITER: c_int = 0;
pub const CAIRO_LINE_JOIN_ROUND: c_int = 1;

pub const PANGO_SCALE: i32 = 1024;
pub const PANGO_ALIGN_LEFT: c_int = 0;
pub const PANGO_ALIGN_CENTER: c_int = 1;
pub const PANGO_ALIGN_RIGHT: c_int = 2;
pub const PANGO_WRAP_WORD_CHAR: c_int = 2;

#[repr(C)]
pub struct CairoSurfaceRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct CairoTRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct PangoLayoutRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct PangoContextRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct PangoFontDescRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct PangoAttrListRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct PangoLayoutLineRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct RsvgHandleRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct GdkPixbufLoaderRaw {
    _private: [u8; 0],
}
#[repr(C)]
pub struct GdkPixbufRaw {
    _private: [u8; 0],
}

#[repr(C)]
pub struct GError {
    pub domain: u32,
    pub code: c_int,
    pub message: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PangoRectangle {
    pub x: c_int,
    pub y: c_int,
    pub width: c_int,
    pub height: c_int,
}

#[repr(C)]
pub struct PangoAttribute {
    pub klass: *const c_void,
    pub start_index: u32,
    pub end_index: u32,
}

#[repr(C)]
pub struct PangoAttrShape {
    pub attr: PangoAttribute,
    pub ink_rect: PangoRectangle,
    pub logical_rect: PangoRectangle,
    pub data: *mut c_void,
    pub copy_func: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_void>,
    pub destroy_func: Option<unsafe extern "C" fn(*mut c_void)>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct RsvgRectangle {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CairoMatrix {
    pub xx: f64,
    pub yx: f64,
    pub xy: f64,
    pub yy: f64,
    pub x0: f64,
    pub y0: f64,
}

extern "C" {
    // Cairo
    fn cairo_image_surface_create(format: c_int, width: c_int, height: c_int) -> *mut CairoSurfaceRaw;
    fn cairo_image_surface_get_data(surface: *mut CairoSurfaceRaw) -> *mut u8;
    fn cairo_image_surface_get_stride(surface: *mut CairoSurfaceRaw) -> c_int;
    fn cairo_surface_mark_dirty(surface: *mut CairoSurfaceRaw);
    fn cairo_surface_flush(surface: *mut CairoSurfaceRaw);
    fn cairo_surface_destroy(surface: *mut CairoSurfaceRaw);
    fn cairo_surface_status(surface: *mut CairoSurfaceRaw) -> c_int;
    fn cairo_surface_write_to_png_stream(
        surface: *mut CairoSurfaceRaw,
        write_func: unsafe extern "C" fn(*mut c_void, *const u8, c_uint) -> c_int,
        closure: *mut c_void,
    ) -> c_int;
    fn cairo_create(target: *mut CairoSurfaceRaw) -> *mut CairoTRaw;
    fn cairo_destroy(cr: *mut CairoTRaw);
    fn cairo_save(cr: *mut CairoTRaw);
    fn cairo_restore(cr: *mut CairoTRaw);
    fn cairo_set_operator(cr: *mut CairoTRaw, op: c_int);
    fn cairo_set_source_rgba(cr: *mut CairoTRaw, r: f64, g: f64, b: f64, a: f64);
    fn cairo_set_source_surface(
        cr: *mut CairoTRaw,
        surface: *mut CairoSurfaceRaw,
        x: f64,
        y: f64,
    );
    fn cairo_set_line_width(cr: *mut CairoTRaw, width: f64);
    fn cairo_set_line_cap(cr: *mut CairoTRaw, line_cap: c_int);
    fn cairo_set_line_join(cr: *mut CairoTRaw, line_join: c_int);
    fn cairo_set_dash(cr: *mut CairoTRaw, dashes: *const f64, num_dashes: c_int, offset: f64);
    fn cairo_translate(cr: *mut CairoTRaw, tx: f64, ty: f64);
    fn cairo_scale(cr: *mut CairoTRaw, sx: f64, sy: f64);
    fn cairo_new_path(cr: *mut CairoTRaw);
    fn cairo_new_sub_path(cr: *mut CairoTRaw);
    fn cairo_close_path(cr: *mut CairoTRaw);
    fn cairo_move_to(cr: *mut CairoTRaw, x: f64, y: f64);
    fn cairo_line_to(cr: *mut CairoTRaw, x: f64, y: f64);
    fn cairo_curve_to(
        cr: *mut CairoTRaw,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        x3: f64,
        y3: f64,
    );
    fn cairo_arc(cr: *mut CairoTRaw, xc: f64, yc: f64, r: f64, a1: f64, a2: f64);
    fn cairo_arc_negative(cr: *mut CairoTRaw, xc: f64, yc: f64, r: f64, a1: f64, a2: f64);
    fn cairo_rectangle(cr: *mut CairoTRaw, x: f64, y: f64, width: f64, height: f64);
    fn cairo_stroke(cr: *mut CairoTRaw);
    fn cairo_stroke_preserve(cr: *mut CairoTRaw);
    fn cairo_fill(cr: *mut CairoTRaw);
    fn cairo_fill_preserve(cr: *mut CairoTRaw);
    fn cairo_paint(cr: *mut CairoTRaw);
    fn cairo_clip(cr: *mut CairoTRaw);
    fn cairo_reset_clip(cr: *mut CairoTRaw);
    fn cairo_get_current_point(cr: *mut CairoTRaw, x: *mut f64, y: *mut f64);
    fn cairo_get_matrix(cr: *mut CairoTRaw, matrix: *mut CairoMatrix);

    // Pango & PangoCairo
    fn pango_cairo_create_layout(cr: *mut CairoTRaw) -> *mut PangoLayoutRaw;
    fn pango_cairo_update_layout(cr: *mut CairoTRaw, layout: *mut PangoLayoutRaw);
    fn pango_cairo_show_layout(cr: *mut CairoTRaw, layout: *mut PangoLayoutRaw);
    fn pango_layout_get_context(layout: *mut PangoLayoutRaw) -> *mut PangoContextRaw;
    fn pango_cairo_context_set_shape_renderer(
        context: *mut PangoContextRaw,
        func: Option<unsafe extern "C" fn(*mut CairoTRaw, *mut PangoAttrShape, c_int, *mut c_void)>,
        data: *mut c_void,
        dnotify: Option<unsafe extern "C" fn(*mut c_void)>,
    );
    fn pango_layout_set_text(layout: *mut PangoLayoutRaw, text: *const c_char, length: c_int);
    fn pango_layout_set_markup(layout: *mut PangoLayoutRaw, markup: *const c_char, length: c_int);
    fn pango_layout_set_font_description(
        layout: *mut PangoLayoutRaw,
        desc: *const PangoFontDescRaw,
    );
    fn pango_layout_set_width(layout: *mut PangoLayoutRaw, width: c_int);
    fn pango_layout_set_wrap(layout: *mut PangoLayoutRaw, wrap: c_int);
    fn pango_layout_set_alignment(layout: *mut PangoLayoutRaw, alignment: c_int);
    fn pango_layout_set_attributes(layout: *mut PangoLayoutRaw, attrs: *mut PangoAttrListRaw);
    fn pango_layout_get_pixel_size(
        layout: *mut PangoLayoutRaw,
        width: *mut c_int,
        height: *mut c_int,
    );
    fn pango_layout_get_baseline(layout: *mut PangoLayoutRaw) -> c_int;
    fn pango_layout_get_line_count(layout: *mut PangoLayoutRaw) -> c_int;
    fn pango_layout_get_line_readonly(
        layout: *mut PangoLayoutRaw,
        line: c_int,
    ) -> *mut PangoLayoutLineRaw;
    fn pango_layout_line_get_pixel_extents(
        line: *mut PangoLayoutLineRaw,
        ink: *mut PangoRectangle,
        logical: *mut PangoRectangle,
    );
    fn pango_font_description_from_string(s: *const c_char) -> *mut PangoFontDescRaw;
    fn pango_font_description_free(desc: *mut PangoFontDescRaw);
    fn pango_font_description_get_size(desc: *const PangoFontDescRaw) -> c_int;
    fn pango_font_description_set_size(desc: *mut PangoFontDescRaw, size: c_int);
    fn pango_font_description_set_weight(desc: *mut PangoFontDescRaw, weight: c_int);
    fn pango_font_description_set_style(desc: *mut PangoFontDescRaw, style: c_int);
    fn pango_attr_list_new() -> *mut PangoAttrListRaw;
    fn pango_attr_list_unref(list: *mut PangoAttrListRaw);
    fn pango_attr_list_insert(list: *mut PangoAttrListRaw, attr: *mut PangoAttribute);
    fn pango_attr_shape_new_with_data(
        ink_rect: *const PangoRectangle,
        logical_rect: *const PangoRectangle,
        data: *mut c_void,
        copy_func: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_void>,
        destroy_func: Option<unsafe extern "C" fn(*mut c_void)>,
    ) -> *mut PangoAttribute;

    // librsvg
    fn rsvg_handle_new_from_data(
        data: *const u8,
        data_len: usize,
        error: *mut *mut GError,
    ) -> *mut RsvgHandleRaw;
    fn rsvg_handle_set_dpi(handle: *mut RsvgHandleRaw, dpi: f64);
    fn rsvg_handle_set_stylesheet(
        handle: *mut RsvgHandleRaw,
        css: *const u8,
        css_len: usize,
        error: *mut *mut GError,
    ) -> c_int;
    fn rsvg_handle_get_intrinsic_size_in_pixels(
        handle: *mut RsvgHandleRaw,
        out_width: *mut f64,
        out_height: *mut f64,
    ) -> c_int;
    fn rsvg_handle_render_document(
        handle: *mut RsvgHandleRaw,
        cr: *mut CairoTRaw,
        viewport: *const RsvgRectangle,
        error: *mut *mut GError,
    ) -> c_int;

    // GdkPixbuf
    fn gdk_pixbuf_loader_new() -> *mut GdkPixbufLoaderRaw;
    fn gdk_pixbuf_loader_write(
        loader: *mut GdkPixbufLoaderRaw,
        buf: *const u8,
        count: usize,
        error: *mut *mut GError,
    ) -> c_int;
    fn gdk_pixbuf_loader_close(
        loader: *mut GdkPixbufLoaderRaw,
        error: *mut *mut GError,
    ) -> c_int;
    fn gdk_pixbuf_loader_get_pixbuf(loader: *mut GdkPixbufLoaderRaw) -> *mut GdkPixbufRaw;
    fn gdk_pixbuf_get_n_channels(pixbuf: *mut GdkPixbufRaw) -> c_int;
    fn gdk_pixbuf_get_has_alpha(pixbuf: *mut GdkPixbufRaw) -> c_int;
    fn gdk_pixbuf_get_width(pixbuf: *mut GdkPixbufRaw) -> c_int;
    fn gdk_pixbuf_get_height(pixbuf: *mut GdkPixbufRaw) -> c_int;
    fn gdk_pixbuf_get_rowstride(pixbuf: *mut GdkPixbufRaw) -> c_int;
    fn gdk_pixbuf_get_pixels(pixbuf: *mut GdkPixbufRaw) -> *const u8;

    // GObject / GLib
    fn g_object_unref(object: *mut c_void);
    fn g_error_free(error: *mut GError);
}

fn take_gerror(err: *mut GError) -> String {
    if err.is_null() {
        return "unknown error".to_string();
    }
    let msg = unsafe {
        if (*err).message.is_null() {
            "unknown error".to_string()
        } else {
            CStr::from_ptr((*err).message).to_string_lossy().into_owned()
        }
    };
    unsafe { g_error_free(err) };
    msg
}

pub struct CairoSurface {
    raw: *mut CairoSurfaceRaw,
    pub width: i32,
    pub height: i32,
}

unsafe impl Send for CairoSurface {}
unsafe impl Sync for CairoSurface {}

impl Drop for CairoSurface {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { cairo_surface_destroy(self.raw) };
        }
    }
}

pub const UNPREMUL_RECIP: [u32; 256] = {
    let mut tbl = [0u32; 256];
    let mut a = 1u32;
    while a <= 255 {
        tbl[a as usize] = ((255u32 << 16) + (a - 1)) / a;
        a += 1;
    }
    tbl
};

#[inline(always)]
pub fn unpremul_channel(c: u32, a: u32) -> u8 {
    let recip = UNPREMUL_RECIP[(a & 0xff) as usize];
    (((c * recip) + 0x8000) >> 16).min(255) as u8
}

impl CairoSurface {
    pub fn new_argb32(width: i32, height: i32) -> Result<Self, String> {
        let w = width.max(1);
        let h = height.max(1);
        let raw = unsafe { cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h) };
        if raw.is_null() || unsafe { cairo_surface_status(raw) } != CAIRO_STATUS_SUCCESS {
            if !raw.is_null() {
                unsafe { cairo_surface_destroy(raw) };
            }
            return Err(format!("Failed to create Cairo surface {w}x{h}"));
        }
        Ok(Self {
            raw,
            width: w,
            height: h,
        })
    }

    pub fn raw(&self) -> *mut CairoSurfaceRaw {
        self.raw
    }

    pub fn write_to_png(&self) -> Result<Vec<u8>, String> {
        unsafe extern "C" fn write_cb(
            closure: *mut c_void,
            data: *const u8,
            len: c_uint,
        ) -> c_int {
            let out = &mut *(closure as *mut Vec<u8>);
            let slice = std::slice::from_raw_parts(data, len as usize);
            out.extend_from_slice(slice);
            CAIRO_STATUS_SUCCESS
        }

        unsafe { cairo_surface_flush(self.raw) };
        let mut buf: Vec<u8> = Vec::with_capacity(64 * 1024);
        let status = unsafe {
            cairo_surface_write_to_png_stream(
                self.raw,
                write_cb,
                &mut buf as *mut Vec<u8> as *mut c_void,
            )
        };
        if status != CAIRO_STATUS_SUCCESS {
            return Err(format!("cairo_surface_write_to_png_stream failed: {status}"));
        }
        Ok(buf)
    }

    /// Fast RGBA8 PNG encoder using zlib level 1 + filter type 0 and reusable buffers.
    pub fn write_to_png_fast_into(
        &self,
        raw_scratch: &mut Vec<u8>,
        out: &mut Vec<u8>,
    ) -> Result<(), String> {
        unsafe { cairo_surface_flush(self.raw) };
        let w = self.width.max(1) as usize;
        let h = self.height.max(1) as usize;
        let src_ptr = unsafe { cairo_image_surface_get_data(self.raw) };
        let stride = unsafe { cairo_image_surface_get_stride(self.raw) } as usize;
        if src_ptr.is_null() {
            return Err("cairo_image_surface_get_data returned null".to_string());
        }

        let row_bytes = 1 + w * 4;
        let total_raw = h * row_bytes;
        if raw_scratch.len() != total_raw {
            raw_scratch.resize(total_raw, 0);
        }

        for y in 0..h {
            let src_row = unsafe {
                std::slice::from_raw_parts(src_ptr.add(y * stride) as *const u32, w)
            };
            let row = &mut raw_scratch[y * row_bytes..(y + 1) * row_bytes];
            row[0] = 0; // filter None
            let dst = &mut row[1..];
            for (x, &px) in src_row.iter().enumerate() {
                let di = x * 4;
                if px == 0 {
                    dst[di..di + 4].copy_from_slice(&[0, 0, 0, 0]);
                } else if (px >> 24) == 0xff {
                    let rgba_le = (px & 0xFF00_FF00)
                        | ((px & 0x00FF_0000) >> 16)
                        | ((px & 0x0000_00FF) << 16);
                    dst[di..di + 4].copy_from_slice(&rgba_le.to_le_bytes());
                } else {
                    let a = (px >> 24) & 0xff;
                    dst[di] = unpremul_channel((px >> 16) & 0xff, a);
                    dst[di + 1] = unpremul_channel((px >> 8) & 0xff, a);
                    dst[di + 2] = unpremul_channel(px & 0xff, a);
                    dst[di + 3] = a as u8;
                }
            }
        }

        let mut encoder =
            ZlibEncoder::new(Vec::with_capacity((total_raw / 32).max(16 * 1024)), Compression::fast());
        encoder
            .write_all(&raw_scratch[..total_raw])
            .map_err(|e| format!("png zlib write: {e}"))?;
        let idat = encoder
            .finish()
            .map_err(|e| format!("png zlib finish: {e}"))?;

        out.clear();
        out.reserve(64 + idat.len());
        out.extend_from_slice(b"\x89PNG\r\n\x1a\n");

        let mut ihdr = [0u8; 13];
        ihdr[0..4].copy_from_slice(&(w as u32).to_be_bytes());
        ihdr[4..8].copy_from_slice(&(h as u32).to_be_bytes());
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // RGBA
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;

        fn push_chunk(out: &mut Vec<u8>, tag: &[u8; 4], data: &[u8]) {
            out.extend_from_slice(&(data.len() as u32).to_be_bytes());
            out.extend_from_slice(tag);
            out.extend_from_slice(data);
            let mut hasher = crc32fast::Hasher::new();
            hasher.update(tag);
            hasher.update(data);
            out.extend_from_slice(&hasher.finalize().to_be_bytes());
        }

        push_chunk(out, b"IHDR", &ihdr);
        push_chunk(out, b"IDAT", &idat);
        push_chunk(out, b"IEND", &[]);
        Ok(())
    }

    /// Fast RGBA8 PNG encoder using zlib level 1 + filter type 0 for responsive interactive pans.
    pub fn write_to_png_fast(&self) -> Result<Vec<u8>, String> {
        let mut scratch = Vec::new();
        let mut out = Vec::new();
        self.write_to_png_fast_into(&mut scratch, &mut out)?;
        Ok(out)
    }

    pub fn from_pixbuf_bytes(bytes: &[u8]) -> Result<Self, String> {
        let loader = unsafe { gdk_pixbuf_loader_new() };
        if loader.is_null() {
            return Err("gdk_pixbuf_loader_new returned null".to_string());
        }
        let mut err: *mut GError = std::ptr::null_mut();
        let ok = unsafe { gdk_pixbuf_loader_write(loader, bytes.as_ptr(), bytes.len(), &mut err) };
        if ok == 0 {
            let mut close_err: *mut GError = std::ptr::null_mut();
            unsafe { gdk_pixbuf_loader_close(loader, &mut close_err) };
            if !close_err.is_null() {
                let _ = take_gerror(close_err);
            }
            unsafe { g_object_unref(loader as *mut c_void) };
            return Err(format!("pixbuf decode error: {}", take_gerror(err)));
        }
        let ok_close = unsafe { gdk_pixbuf_loader_close(loader, &mut err) };
        if ok_close == 0 {
            unsafe { g_object_unref(loader as *mut c_void) };
            return Err(format!("pixbuf close error: {}", take_gerror(err)));
        }
        let pixbuf = unsafe { gdk_pixbuf_loader_get_pixbuf(loader) };
        if pixbuf.is_null() {
            unsafe { g_object_unref(loader as *mut c_void) };
            return Err("pixbuf loader produced null pixbuf".to_string());
        }
        let w = unsafe { gdk_pixbuf_get_width(pixbuf) };
        let h = unsafe { gdk_pixbuf_get_height(pixbuf) };
        let n_ch = unsafe { gdk_pixbuf_get_n_channels(pixbuf) };
        let has_alpha = unsafe { gdk_pixbuf_get_has_alpha(pixbuf) } != 0;
        let rowstride = unsafe { gdk_pixbuf_get_rowstride(pixbuf) };
        let src_ptr = unsafe { gdk_pixbuf_get_pixels(pixbuf) };

        if w <= 0 || h <= 0 || src_ptr.is_null() || (n_ch != 3 && n_ch != 4) {
            unsafe { g_object_unref(loader as *mut c_void) };
            return Err(format!("Unsupported pixbuf format {w}x{h} ch={n_ch}"));
        }

        let surface = Self::new_argb32(w, h)?;
        let dst_ptr = unsafe { cairo_image_surface_get_data(surface.raw) };
        let dst_stride = unsafe { cairo_image_surface_get_stride(surface.raw) };

        for y in 0..h {
            let src_row = unsafe {
                std::slice::from_raw_parts(src_ptr.offset((y * rowstride) as isize), (w * n_ch) as usize)
            };
            let dst_row = unsafe {
                std::slice::from_raw_parts_mut(
                    dst_ptr.offset((y * dst_stride) as isize) as *mut u32,
                    w as usize,
                )
            };
            for x in 0..w as usize {
                let idx = x * (n_ch as usize);
                let r = src_row[idx] as u32;
                let g = src_row[idx + 1] as u32;
                let b = src_row[idx + 2] as u32;
                let a = if has_alpha && n_ch == 4 {
                    src_row[idx + 3] as u32
                } else {
                    255
                };
                let pr = (r * a + 127) / 255;
                let pg = (g * a + 127) / 255;
                let pb = (b * a + 127) / 255;
                dst_row[x] = (a << 24) | (pr << 16) | (pg << 8) | pb;
            }
        }
        unsafe { cairo_surface_mark_dirty(surface.raw) };
        unsafe { g_object_unref(loader as *mut c_void) };
        Ok(surface)
    }
}

pub struct CairoContext {
    raw: *mut CairoTRaw,
}

impl Drop for CairoContext {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { cairo_destroy(self.raw) };
        }
    }
}

impl CairoContext {
    pub fn new(surface: &CairoSurface) -> Result<Self, String> {
        let raw = unsafe { cairo_create(surface.raw()) };
        if raw.is_null() {
            return Err("cairo_create returned null".to_string());
        }
        Ok(Self { raw })
    }

    pub fn raw(&self) -> *mut CairoTRaw {
        self.raw
    }

    pub fn save(&self) {
        unsafe { cairo_save(self.raw) };
    }
    pub fn restore(&self) {
        unsafe { cairo_restore(self.raw) };
    }
    pub fn clear(&self) {
        unsafe {
            cairo_save(self.raw);
            cairo_set_operator(self.raw, CAIRO_OPERATOR_CLEAR);
            cairo_paint(self.raw);
            cairo_restore(self.raw);
        }
    }
    pub fn set_operator_source(&self) {
        unsafe { cairo_set_operator(self.raw, CAIRO_OPERATOR_SOURCE) };
    }
    pub fn set_operator_over(&self) {
        unsafe { cairo_set_operator(self.raw, CAIRO_OPERATOR_OVER) };
    }
    pub fn set_rgba(&self, r: f64, g: f64, b: f64, a: f64) {
        unsafe { cairo_set_source_rgba(self.raw, r, g, b, a) };
    }
    pub fn set_source_surface(&self, surface: &CairoSurface, x: f64, y: f64) {
        unsafe { cairo_set_source_surface(self.raw, surface.raw(), x, y) };
    }
    pub fn set_line_width(&self, w: f64) {
        unsafe { cairo_set_line_width(self.raw, w) };
    }
    pub fn set_line_cap(&self, cap: c_int) {
        unsafe { cairo_set_line_cap(self.raw, cap) };
    }
    pub fn set_line_join(&self, join: c_int) {
        unsafe { cairo_set_line_join(self.raw, join) };
    }
    pub fn set_dash(&self, dashes: &[f64], offset: f64) {
        unsafe {
            cairo_set_dash(self.raw, dashes.as_ptr(), dashes.len() as c_int, offset);
        }
    }
    pub fn translate(&self, tx: f64, ty: f64) {
        unsafe { cairo_translate(self.raw, tx, ty) };
    }
    pub fn scale(&self, sx: f64, sy: f64) {
        unsafe { cairo_scale(self.raw, sx, sy) };
    }
    pub fn new_path(&self) {
        unsafe { cairo_new_path(self.raw) };
    }
    pub fn new_sub_path(&self) {
        unsafe { cairo_new_sub_path(self.raw) };
    }
    pub fn close_path(&self) {
        unsafe { cairo_close_path(self.raw) };
    }
    pub fn move_to(&self, x: f64, y: f64) {
        unsafe { cairo_move_to(self.raw, x, y) };
    }
    pub fn line_to(&self, x: f64, y: f64) {
        unsafe { cairo_line_to(self.raw, x, y) };
    }
    pub fn curve_to(&self, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) {
        unsafe { cairo_curve_to(self.raw, x1, y1, x2, y2, x3, y3) };
    }
    pub fn arc(&self, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) {
        unsafe { cairo_arc(self.raw, xc, yc, r, a1, a2) };
    }
    pub fn arc_negative(&self, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) {
        unsafe { cairo_arc_negative(self.raw, xc, yc, r, a1, a2) };
    }
    pub fn rectangle(&self, x: f64, y: f64, w: f64, h: f64) {
        unsafe { cairo_rectangle(self.raw, x, y, w, h) };
    }
    pub fn rounded_rect(&self, x: f64, y: f64, w: f64, h: f64, radius: f64) {
        let r = radius.max(0.0).min(w / 2.0).min(h / 2.0);
        let deg = std::f64::consts::PI / 180.0;
        self.new_sub_path();
        self.arc(x + w - r, y + r, r, -90.0 * deg, 0.0);
        self.arc(x + w - r, y + h - r, r, 0.0, 90.0 * deg);
        self.arc(x + r, y + h - r, r, 90.0 * deg, 180.0 * deg);
        self.arc(x + r, y + r, r, 180.0 * deg, 270.0 * deg);
        self.close_path();
    }
    pub fn stroke(&self) {
        unsafe { cairo_stroke(self.raw) };
    }
    pub fn stroke_preserve(&self) {
        unsafe { cairo_stroke_preserve(self.raw) };
    }
    pub fn fill(&self) {
        unsafe { cairo_fill(self.raw) };
    }
    pub fn fill_preserve(&self) {
        unsafe { cairo_fill_preserve(self.raw) };
    }
    pub fn paint(&self) {
        unsafe { cairo_paint(self.raw) };
    }
    pub fn clip(&self) {
        unsafe { cairo_clip(self.raw) };
    }
    pub fn reset_clip(&self) {
        unsafe { cairo_reset_clip(self.raw) };
    }
}

pub struct RsvgDoc {
    raw: *mut RsvgHandleRaw,
}

unsafe impl Send for RsvgDoc {}
unsafe impl Sync for RsvgDoc {}

impl Drop for RsvgDoc {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { g_object_unref(self.raw as *mut c_void) };
        }
    }
}

impl RsvgDoc {
    pub fn from_bytes(bytes: &[u8], dpi: f64) -> Result<Self, String> {
        let mut err: *mut GError = std::ptr::null_mut();
        let raw = unsafe { rsvg_handle_new_from_data(bytes.as_ptr(), bytes.len(), &mut err) };
        if raw.is_null() {
            return Err(format!("librsvg parse error: {}", take_gerror(err)));
        }
        unsafe { rsvg_handle_set_dpi(raw, dpi) };
        Ok(Self { raw })
    }

    pub fn set_stylesheet(&self, css: &str) -> Result<(), String> {
        let mut err: *mut GError = std::ptr::null_mut();
        let ok = unsafe { rsvg_handle_set_stylesheet(self.raw, css.as_ptr(), css.len(), &mut err) };
        if ok == 0 {
            return Err(format!("rsvg_handle_set_stylesheet: {}", take_gerror(err)));
        }
        Ok(())
    }

    pub fn intrinsic_size_px(&self) -> Option<(f64, f64)> {
        let mut w = 0.0f64;
        let mut h = 0.0f64;
        let ok = unsafe { rsvg_handle_get_intrinsic_size_in_pixels(self.raw, &mut w, &mut h) };
        if ok != 0 && w > 0.0 && h > 0.0 {
            Some((w, h))
        } else {
            None
        }
    }

    pub fn render(&self, cr: &CairoContext, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
        let viewport = RsvgRectangle {
            x,
            y,
            width: w,
            height: h,
        };
        let mut err: *mut GError = std::ptr::null_mut();
        let ok = unsafe { rsvg_handle_render_document(self.raw, cr.raw(), &viewport, &mut err) };
        if ok == 0 {
            return Err(format!("rsvg_handle_render_document: {}", take_gerror(err)));
        }
        Ok(())
    }
}

pub struct PangoFontDesc {
    raw: *mut PangoFontDescRaw,
}

impl Drop for PangoFontDesc {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { pango_font_description_free(self.raw) };
        }
    }
}

impl PangoFontDesc {
    pub fn from_string(desc: &str) -> Self {
        let c = CString::new(desc).unwrap_or_else(|_| CString::new("Sans 11").unwrap());
        let raw = unsafe { pango_font_description_from_string(c.as_ptr()) };
        Self { raw }
    }

    pub fn size_pt(&self) -> f64 {
        let raw_sz = unsafe { pango_font_description_get_size(self.raw) };
        if raw_sz <= 0 {
            11.0
        } else {
            raw_sz as f64 / PANGO_SCALE as f64
        }
    }

    pub fn set_bold(&mut self) {
        unsafe { pango_font_description_set_weight(self.raw, 700) };
    }

    pub fn set_italic(&mut self) {
        unsafe { pango_font_description_set_style(self.raw, 2) };
    }
}

#[derive(Clone)]
pub struct InlineSvgShape {
    pub svg_bytes: Arc<Vec<u8>>,
    pub svg_hash: u64,
    pub width_px: f64,
    pub ascent_px: f64,
    pub descent_px: f64,
    pub color: [f64; 4],
}

pub struct PangoAttrList {
    raw: *mut PangoAttrListRaw,
}

impl Drop for PangoAttrList {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { pango_attr_list_unref(self.raw) };
        }
    }
}

impl PangoAttrList {
    pub fn new() -> Self {
        Self {
            raw: unsafe { pango_attr_list_new() },
        }
    }

    pub fn insert_shape(&mut self, start_byte: u32, end_byte: u32, payload: InlineSvgShape) {
        unsafe extern "C" fn copy_payload(ptr: *mut c_void) -> *mut c_void {
            if !ptr.is_null() {
                Arc::increment_strong_count(ptr as *const InlineSvgShape);
            }
            ptr
        }
        unsafe extern "C" fn destroy_payload(ptr: *mut c_void) {
            if !ptr.is_null() {
                drop(Arc::from_raw(ptr as *const InlineSvgShape));
            }
        }

        let w_units = (payload.width_px * PANGO_SCALE as f64).round().max(1.0) as i32;
        let asc_units = (payload.ascent_px * PANGO_SCALE as f64).round().max(1.0) as i32;
        let desc_units = (payload.descent_px * PANGO_SCALE as f64).round().max(0.0) as i32;
        let rect = PangoRectangle {
            x: 0,
            y: -asc_units,
            width: w_units,
            height: asc_units + desc_units,
        };
        let raw_payload = Arc::into_raw(Arc::new(payload)) as *mut c_void;
        let attr = unsafe {
            pango_attr_shape_new_with_data(
                &rect,
                &rect,
                raw_payload,
                Some(copy_payload),
                Some(destroy_payload),
            )
        };
        unsafe {
            (*attr).start_index = start_byte;
            (*attr).end_index = end_byte;
            pango_attr_list_insert(self.raw, attr);
        }
    }
}

pub struct PangoLayout {
    raw: *mut PangoLayoutRaw,
}

impl Drop for PangoLayout {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { g_object_unref(self.raw as *mut c_void) };
        }
    }
}

static SVG_RASTER_CACHE: OnceLock<Mutex<HashMap<(u64, u32, i32, i32), Arc<CairoSurface>>>> =
    OnceLock::new();

fn svg_raster_cache() -> &'static Mutex<HashMap<(u64, u32, i32, i32), Arc<CairoSurface>>> {
    SVG_RASTER_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

unsafe extern "C" fn svg_shape_renderer(
    cr: *mut CairoTRaw,
    attr: *mut PangoAttrShape,
    do_path: c_int,
    _data: *mut c_void,
) {
    if do_path != 0 || attr.is_null() {
        return;
    }
    let payload_ptr = (*attr).data as *const InlineSvgShape;
    if payload_ptr.is_null() {
        return;
    }
    let payload = &*payload_ptr;
    let mut cx = 0.0f64;
    let mut cy = 0.0f64;
    cairo_get_current_point(cr, &mut cx, &mut cy);

    let mut mat = CairoMatrix::default();
    cairo_get_matrix(cr, &mut mat);
    let sx = (mat.xx * mat.xx + mat.yx * mat.yx).sqrt().max(0.1);
    let sy = (mat.xy * mat.xy + mat.yy * mat.yy).sqrt().max(0.1);

    let w_log = payload.width_px.max(1.0);
    let h_log = (payload.ascent_px + payload.descent_px).max(1.0);
    let dev_w = (w_log * sx).ceil().clamp(1.0, 2048.0) as i32;
    let dev_h = (h_log * sy).ceil().clamp(1.0, 2048.0) as i32;

    let r = (payload.color[0] * 255.0).round().clamp(0.0, 255.0) as u8;
    let g = (payload.color[1] * 255.0).round().clamp(0.0, 255.0) as u8;
    let b = (payload.color[2] * 255.0).round().clamp(0.0, 255.0) as u8;
    let a_u8 = (payload.color[3] * 255.0).round().clamp(0.0, 255.0) as u8;
    let rgba_u32 = ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a_u8 as u32);
    let cache_key = (payload.svg_hash, rgba_u32, dev_w, dev_h);

    let cached_hit = {
        let map = svg_raster_cache().lock().unwrap();
        map.get(&cache_key).cloned()
    };

    let surf = if let Some(hit) = cached_hit {
        Some(hit)
    } else if let Ok(doc) = RsvgDoc::from_bytes(&payload.svg_bytes, 96.0) {
        let css = format!(
            "svg {{ color: rgb({r},{g},{b}); }} \
             [fill=\"#000\"], [fill=\"#000000\"], [fill=\"black\"] {{ fill: rgb({r},{g},{b}) !important; }} \
             [stroke=\"#000\"], [stroke=\"#000000\"], [stroke=\"black\"] {{ stroke: rgb({r},{g},{b}) !important; }}"
        );
        let _ = doc.set_stylesheet(&css);
        if let Ok(surf) = CairoSurface::new_argb32(dev_w, dev_h) {
            if let Ok(sub_cr) = CairoContext::new(&surf) {
                sub_cr.clear();
                let viewport = RsvgRectangle {
                    x: 0.0,
                    y: 0.0,
                    width: dev_w as f64,
                    height: dev_h as f64,
                };
                let mut err: *mut GError = std::ptr::null_mut();
                let ok = rsvg_handle_render_document(doc.raw, sub_cr.raw(), &viewport, &mut err);
                if ok == 0 && !err.is_null() {
                    let _ = take_gerror(err);
                }
            }
            let arc = Arc::new(surf);
            let mut map = svg_raster_cache().lock().unwrap();
            if map.len() >= 512 {
                map.clear();
            }
            map.insert(cache_key, Arc::clone(&arc));
            Some(arc)
        } else {
            None
        }
    } else {
        None
    };

    if let Some(cached) = surf {
        cairo_save(cr);
        cairo_translate(cr, cx, cy - payload.ascent_px);
        cairo_scale(cr, w_log / (dev_w as f64), h_log / (dev_h as f64));
        cairo_set_source_surface(cr, cached.raw(), 0.0, 0.0);
        cairo_paint(cr);
        cairo_restore(cr);
    }
}

impl PangoLayout {
    pub fn new(cr: &CairoContext) -> Result<Self, String> {
        let raw = unsafe { pango_cairo_create_layout(cr.raw()) };
        if raw.is_null() {
            return Err("pango_cairo_create_layout returned null".to_string());
        }
        unsafe {
            let ctx = pango_layout_get_context(raw);
            pango_cairo_context_set_shape_renderer(
                ctx,
                Some(svg_shape_renderer),
                std::ptr::null_mut(),
                None,
            );
        }
        Ok(Self { raw })
    }

    pub fn set_font(&self, desc: &PangoFontDesc) {
        unsafe { pango_layout_set_font_description(self.raw, desc.raw) };
    }

    pub fn set_width_px(&self, width_px: Option<f64>) {
        let w = match width_px {
            Some(px) if px > 0.0 => (px * PANGO_SCALE as f64).round() as c_int,
            _ => -1,
        };
        unsafe {
            pango_layout_set_width(self.raw, w);
            pango_layout_set_wrap(self.raw, PANGO_WRAP_WORD_CHAR);
        }
    }

    pub fn set_alignment(&self, align: c_int) {
        unsafe { pango_layout_set_alignment(self.raw, align) };
    }

    pub fn set_text(&self, text: &str) {
        let bytes = text.as_bytes();
        unsafe {
            pango_layout_set_text(self.raw, bytes.as_ptr() as *const c_char, bytes.len() as c_int);
        }
    }

    pub fn set_markup(&self, markup: &str) -> bool {
        let bytes = markup.as_bytes();
        unsafe {
            pango_layout_set_markup(
                self.raw,
                bytes.as_ptr() as *const c_char,
                bytes.len() as c_int,
            );
        }
        true
    }

    pub fn set_attributes(&self, attrs: &PangoAttrList) {
        unsafe { pango_layout_set_attributes(self.raw, attrs.raw) };
    }

    pub fn pixel_size(&self) -> (f64, f64) {
        let mut w = 0;
        let mut h = 0;
        unsafe { pango_layout_get_pixel_size(self.raw, &mut w, &mut h) };
        (w as f64, h as f64)
    }

    pub fn baseline_px(&self) -> f64 {
        let b = unsafe { pango_layout_get_baseline(self.raw) };
        b as f64 / PANGO_SCALE as f64
    }

    pub fn update_and_show(&self, cr: &CairoContext, x: f64, y: f64) {
        unsafe {
            cairo_save(cr.raw());
            cairo_move_to(cr.raw(), x, y);
            pango_cairo_update_layout(cr.raw(), self.raw);
            pango_cairo_show_layout(cr.raw(), self.raw);
            cairo_restore(cr.raw());
        }
    }
}
