import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import Workspaces from "./Workspaces"
import Window from "./Window"
import Clock from "./Clock"
import Battery from "./Battery"
import Network from "./Network"
import Audio from "./Audio"
import SysTray from "./SysTray"
import Weather from "./Weather"
import Holiday from "./Holiday"
import Lunar from "./Lunar"

export default function Bar(gdkmonitor: Gdk.Monitor) {
    const { BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor

    return <window
        className="Bar"
        gdkmonitor={gdkmonitor}
        exclusivity={Astal.Exclusivity.EXCLUSIVE}
        anchor={BOTTOM | LEFT | RIGHT}
        application={App}>
        <centerbox>
            <box halign={Gtk.Align.START} spacing={6}>
                <Workspaces />
            </box>
            <Window />
            <box halign={Gtk.Align.END} spacing={6}>
                <SysTray />
                <Audio />
                <Network />
                <Battery />
                <Weather />
                <Clock />
                <Lunar />
                <Holiday />
            </box>
        </centerbox>
    </window>
}
