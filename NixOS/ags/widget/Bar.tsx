import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import { Variable } from "astal"

// Live HH:MM:SS via the `date` shell command, polled once a second.
const time = Variable("").poll(1000, "date +%H:%M:%S")

export default function Bar(gdkmonitor: Gdk.Monitor) {
    const { BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor

    return <window
        className="Bar"
        gdkmonitor={gdkmonitor}
        exclusivity={Astal.Exclusivity.EXCLUSIVE}
        anchor={BOTTOM | LEFT | RIGHT}
        application={App}>
        <centerbox>
            <label
                label="◆ AGS v2 — placeholder bar (Phase 1) ◆"
                halign={Gtk.Align.CENTER}
            />
            <box />
            <label label={time()} halign={Gtk.Align.CENTER} />
        </centerbox>
    </window>
}
