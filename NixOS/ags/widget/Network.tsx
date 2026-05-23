import { bind } from "astal"
import AstalNetwork from "gi://AstalNetwork"
import { ICON } from "../lib/icons"

export default function Network() {
    const net = AstalNetwork.get_default()
    const wifi = net.wifi
    const wired = net.wired

    if (wifi) {
        return <box className="Network">
            <label label={bind(wifi, "ssid").as(s =>
                s ? `${ICON.wifi}  ${s}` : `${ICON.nowifi}  —`
            )} />
        </box>
    }
    return <box className="Network">
        <label label={bind(wired, "state").as(s => `${ICON.ethernet}  ${s}`)} />
    </box>
}
