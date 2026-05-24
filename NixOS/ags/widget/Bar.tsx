import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import Workspaces from "./Workspaces"
import Window from "./Window"
import Clock from "./Clock"
import Battery from "./Battery"
import Network from "./Network"
import AudioSlider from "./AudioSlider"
import SysTray from "./SysTray"
import Weather from "./Weather"
import Cpu from "./Cpu"
import Memory from "./Memory"
import Disk from "./Disk"
import Temperature from "./Temperature"
import SystemdFailed from "./SystemdFailed"
import KeyboardState from "./KeyboardState"
import Mpris from "./Mpris"
import Power from "./Power"
import Notification from "./Notification"
import ControlButton from "./ControlButton"
import AppDrawerButton from "./AppDrawerButton"

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
                <AppDrawerButton />
                <Workspaces />
                <Cpu />
                <Memory />
                <Disk />
                <Temperature />
                <SystemdFailed />
                <Mpris />
            </box>
            <Window />
            <box halign={Gtk.Align.END} spacing={6}>
                <Network />
                <AudioSlider />
                <Battery />
                <KeyboardState />
                <SysTray />
                <Weather />
                <Clock />
                <Notification />
                <ControlButton />
                <Power />
            </box>
        </centerbox>
    </window>
}
