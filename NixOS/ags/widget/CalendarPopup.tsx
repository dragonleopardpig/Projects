import { App, Astal, Gtk } from "astal/gtk3"

// A floating panel that drops in from the bottom near the clock when toggled.
// Toggle via App.toggle_window("calendar") from anywhere (e.g. Clock onClick).
export default function CalendarPopup() {
    const { BOTTOM, RIGHT } = Astal.WindowAnchor

    // <calendar> isn't a JSX intrinsic in astal/gtk3 — construct directly.
    const cal = new Gtk.Calendar({
        show_heading: true,
        show_day_names: true,
        show_week_numbers: false,
    })
    cal.show()

    const win = <window
        name="calendar"
        className="CalendarPopupWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        anchor={BOTTOM | RIGHT}
        layer={Astal.Layer.OVERLAY}
        widthRequest={320}
        heightRequest={280}
        // Esc closes the popup.
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b /* GDK_KEY_Escape */) self.hide()
        }}>
        <box className="CalendarPanel" vertical spacing={8}>
            {cal}
        </box>
    </window> as Astal.Window

    return win
}
