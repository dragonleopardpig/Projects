import { bind, Variable, derive } from "astal"
import AstalNetwork from "gi://AstalNetwork"
import { ICON } from "../lib/icons"
import { bindToggleButton } from "../lib/drawers"

// Compact bar indicator: glyph reflects primary connection type, so
// ethernet shows up when the user is on LAN even with no wifi link.
export default function Network() {
    const net = AstalNetwork.get_default()
    const wifi = net.wifi
    const wired = net.wired

    // Recompute on any of the inputs.
    const inputs: any[] = [
        bind(net, "primary"),
        bind(net, "connectivity"),
    ]
    if (wifi) inputs.push(bind(wifi, "ssid"), bind(wifi, "enabled"))
    if (wired) inputs.push(bind(wired, "state"))
    const status = derive(inputs, () => {
        const primary = net.primary
        const connectivity = net.connectivity
        const full = connectivity === AstalNetwork.Connectivity.FULL
        if (primary === AstalNetwork.Primary.WIRED) {
            return { glyph: ICON.ethernet, tip: "Ethernet" + (full ? "" : " · limited") }
        }
        if (primary === AstalNetwork.Primary.WIFI) {
            const ssid = wifi?.ssid ?? "(no SSID)"
            return { glyph: ICON.wifi, tip: `Wi-Fi · ${ssid}` + (full ? "" : " · limited") }
        }
        return { glyph: ICON.nowifi, tip: "No connection" }
    })

    return <button
        className="Network"
        tooltipText={status().as(s => s.tip)}
        setup={(self) => bindToggleButton(self, "control-center")}>
        <label label={status().as(s => s.glyph)} />
    </button>
}
