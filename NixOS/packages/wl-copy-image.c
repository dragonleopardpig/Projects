#include <errno.h>
#include <gtk/gtk.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-data-control-v1-client-protocol.h"

static const struct {
    const char *mime;
    const char *format;
} formats[] = {
    { "image/png", "png" },
    { "image/bmp", "bmp" },
    { "image/x-bmp", "bmp" },
    { "image/x-MS-bmp", "bmp" },
    { "image/tiff", "tiff" },
    { "image/jpeg", "jpeg" },
};

typedef struct {
    struct ext_data_control_manager_v1 *manager;
    struct wl_seat *seat;
    GdkPixbuf *image;
    gboolean running;
} Selection;

typedef struct {
    int fd;
    gchar *bytes;
    gsize length;
} Transfer;

static gpointer write_transfer(gpointer data) {
    Transfer *transfer = data;
    gsize written = 0;
    while (written < transfer->length) {
        ssize_t n = write(transfer->fd, transfer->bytes + written,
                          transfer->length - written);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd output = { .fd = transfer->fd, .events = POLLOUT };
            int ready;
            do {
                ready = poll(&output, 1, 5000);
            } while (ready < 0 && errno == EINTR);
            if (ready > 0 && (output.revents & POLLOUT))
                continue;
        }
        if (n <= 0)
            break;
        written += n;
    }
    close(transfer->fd);
    g_free(transfer->bytes);
    g_free(transfer);
    return NULL;
}

static void send_selection(void *data, struct ext_data_control_source_v1 *source,
                           const char *mime, int fd) {
    Selection *selection = data;
    for (size_t i = 0; i < G_N_ELEMENTS(formats); i++) {
        if (strcmp(mime, formats[i].mime) != 0)
            continue;
        gchar *bytes = NULL;
        gsize length = 0;
        if (gdk_pixbuf_save_to_buffer(selection->image, &bytes, &length,
                                      formats[i].format, NULL, NULL)) {
            Transfer *transfer = g_new(Transfer, 1);
            *transfer = (Transfer){ fd, bytes, length };
            g_thread_unref(g_thread_new("clipboard-image", write_transfer, transfer));
            return;
        }
        break;
    }
    close(fd);
}

static void cancel_selection(void *data, struct ext_data_control_source_v1 *source) {
    ((Selection *)data)->running = FALSE;
}

static const struct ext_data_control_source_v1_listener source_listener = {
    .send = send_selection,
    .cancelled = cancel_selection,
};

static void offered_mime(void *data, struct ext_data_control_offer_v1 *offer, const char *mime) {}
static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = offered_mime };

static void new_offer(void *data, struct ext_data_control_device_v1 *device,
                      struct ext_data_control_offer_v1 *offer) {
    ext_data_control_offer_v1_add_listener(offer, &offer_listener, NULL);
}

static void discard_offer(void *data, struct ext_data_control_device_v1 *device,
                          struct ext_data_control_offer_v1 *offer) {
    if (offer)
        ext_data_control_offer_v1_destroy(offer);
}

static void device_finished(void *data, struct ext_data_control_device_v1 *device) {
    ((Selection *)data)->running = FALSE;
}

static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = new_offer,
    .selection = discard_offer,
    .finished = device_finished,
    .primary_selection = discard_offer,
};

static void register_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    Selection *selection = data;
    if (strcmp(interface, ext_data_control_manager_v1_interface.name) == 0)
        selection->manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
    else if (!selection->seat && strcmp(interface, wl_seat_interface.name) == 0)
        selection->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}

static void remove_global(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = register_global, .global_remove = remove_global,
};

static void signal_ready(gboolean ready) {
    if (ready) {
        puts("ready");
        fflush(stdout);
    }
}

/* Privileged clipboard clients use data-control without a keyboard serial. */
static int copy_wayland(GdkPixbuf *image, gboolean ready) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display)
        return 1;
    Selection selection = { .image = image, .running = TRUE };
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &selection);
    if (wl_display_roundtrip(display) < 0 || !selection.manager || !selection.seat) {
        wl_display_disconnect(display);
        return 1;
    }
    struct ext_data_control_device_v1 *device =
        ext_data_control_manager_v1_get_data_device(selection.manager, selection.seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, &selection);
    struct ext_data_control_source_v1 *source =
        ext_data_control_manager_v1_create_data_source(selection.manager);
    ext_data_control_source_v1_add_listener(source, &source_listener, &selection);
    for (size_t i = 0; i < G_N_ELEMENTS(formats); i++)
        ext_data_control_source_v1_offer(source, formats[i].mime);
    ext_data_control_device_v1_set_selection(device, source);
    if (wl_display_roundtrip(display) < 0 || !selection.running) {
        wl_display_disconnect(display);
        return 1;
    }
    signal_ready(ready);
    while (selection.running && wl_display_dispatch(display) >= 0) {}
    wl_display_disconnect(display);
    return 0;
}

static void on_owner_change(GtkClipboard *clipboard, GdkEventOwnerChange *event, gpointer owner) {
    if (event->owner != owner)
        gtk_main_quit();
}

int main(int argc, char *argv[]) {
    const gboolean ready = argc == 3 && strcmp(argv[1], "--ready") == 0;
    if (argc != (ready ? 3 : 2))
        return 1;
    signal(SIGPIPE, SIG_IGN);
    GdkPixbuf *image = gdk_pixbuf_new_from_file(argv[argc - 1], NULL);
    if (!image)
        return 2;
    if (g_getenv("WAYLAND_DISPLAY") || g_getenv("WAYLAND_SOCKET")) {
        int result = copy_wayland(image, ready);
        g_object_unref(image);
        return result;
    }
    if (!gtk_init_check(NULL, NULL)) {
        g_object_unref(image);
        return 1;
    }
    GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    gtk_clipboard_set_image(clipboard, image);
    g_object_unref(image);
    GdkDisplay *display = gdk_display_get_default();
    GdkWindow *owner = gdk_selection_owner_get_for_display(display, GDK_SELECTION_CLIPBOARD);
    if (!owner)
        return 1;
    g_signal_connect(clipboard, "owner-change", G_CALLBACK(on_owner_change), owner);
    signal_ready(ready);
    gtk_main();
    return 0;
}
