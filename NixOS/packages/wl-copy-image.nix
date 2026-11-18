{
  stdenv,
  pkg-config,
  gtk3,
}:

stdenv.mkDerivation {
  name = "wl-copy-image";
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ gtk3 ];
  dontUnpack = true;
  buildPhase = ''
    cat << 'EOF' > main.c
    #include <gtk/gtk.h>

    int main(int argc, char *argv[]) {
        if (argc < 2) return 1;
        gtk_init(&argc, &argv);
        GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
        GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(argv[1], NULL);
        if (!pixbuf) return 2;
        gtk_clipboard_set_image(clipboard, pixbuf);
        g_signal_connect(clipboard, "owner-change", G_CALLBACK(gtk_main_quit), NULL);
        gtk_main();
        return 0;
    }
    EOF
    $CC -O2 main.c $(pkg-config --cflags --libs gtk+-3.0) -o wl-copy-image
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp wl-copy-image $out/bin/
  '';
}
