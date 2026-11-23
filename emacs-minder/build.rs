fn main() {
    for lib in [
        "cairo",
        "pangocairo",
        "pango",
        "librsvg-2.0",
        "gdk-pixbuf-2.0",
        "glib-2.0",
        "gobject-2.0",
    ] {
        println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
        pkg_config::Config::new()
            .probe(lib)
            .unwrap_or_else(|err| panic!("failed to probe pkg-config library `{lib}`: {err}"));
    }
}
