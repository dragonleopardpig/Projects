import { bind } from "astal"
import { Gtk } from "astal/gtk3"
import AstalHyprland from "gi://AstalHyprland"

export default function Window() {
    const hypr = AstalHyprland.get_default()

    return <label
        className="Window"
        label={bind(hypr, "focusedClient").as(c => (c && c.title) ? c.title : "")}
        maxWidthChars={80}
        ellipsize={Gtk.PangoEllipsizeMode?.END ?? 3}
    />
}
