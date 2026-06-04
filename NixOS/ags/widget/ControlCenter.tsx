import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, derive, exec, execAsync } from "astal"
import Wp from "gi://AstalWp"
import AstalNetwork from "gi://AstalNetwork"
import AstalBluetooth from "gi://AstalBluetooth"
import AstalPowerProfiles from "gi://AstalPowerProfiles"
import { ICON } from "../lib/icons"
import { WEATHER_CMD } from "../lib/paths"

// ── Audio card ────────────────────────────────────────────────────
function AudioCard() {
    const wp = Wp.get_default()
    const speaker = wp?.audio?.defaultSpeaker
    if (!speaker) return <box />
    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Volume" xalign={0} />
        <box spacing={8}>
            <button onClicked={() => speaker.set_mute(!speaker.mute)}>
                <label label={bind(speaker, "mute").as(m => m ? ICON.mute : ICON.speaker)} />
            </button>
            <slider
                hexpand
                value={bind(speaker, "volume")}
                onDragged={({ value }) => speaker.set_volume(value)}
            />
            <label
                widthChars={4}
                label={bind(speaker, "volume").as(v => `${Math.round(v * 100)}%`)}
            />
        </box>
    </box>
}

// ── Brightness card (backlight via brightnessctl) ─────────────────
// Scope to the backlight class; bare `brightnessctl` falls back to LED devices
// (capslock/numlock) on desktops with no backlight, which drive brightness over
// DDC instead. No backlight → no card.
function hasBacklight(): boolean {
    try { return parseInt(exec("brightnessctl -c backlight m")) > 0 }
    catch { return false }
}

const brightness = Variable(0).poll(2000, () => {
    try {
        const cur = parseInt(exec("brightnessctl -c backlight g"))
        const max = parseInt(exec("brightnessctl -c backlight m"))
        return max > 0 ? cur / max : 0
    } catch { return 0 }
})

function BrightnessCard() {
    if (!hasBacklight()) return <box />
    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Brightness" xalign={0} />
        <box spacing={8}>
            <label label={"\u{f0335}"} />
            <slider
                hexpand
                value={brightness()}
                onDragged={({ value }) => {
                    brightness.set(value)
                    execAsync(["brightnessctl", "-c", "backlight", "s", `${Math.round(value * 100)}%`])
                        .catch(() => {})
                }}
            />
            <label widthChars={4} label={brightness().as(v => `${Math.round(v * 100)}%`)} />
        </box>
    </box>
}

// ── Network (Wi-Fi / Ethernet) card ───────────────────────────────
function NetworkCard() {
    const net = AstalNetwork.get_default()
    const wifi = net.wifi
    const wired = net.wired

    const inputs: any[] = [bind(net, "primary"), bind(net, "connectivity")]
    if (wifi) inputs.push(bind(wifi, "ssid"), bind(wifi, "enabled"))
    if (wired) inputs.push(bind(wired, "state"))

    const summary = derive(inputs, () => {
        const primary = net.primary
        if (primary === AstalNetwork.Primary.WIRED) {
            return { glyph: ICON.ethernet, title: "Ethernet",
                     sub: "Wired connection", on: true }
        }
        if (primary === AstalNetwork.Primary.WIFI) {
            return { glyph: ICON.wifi, title: "Wi-Fi",
                     sub: wifi?.ssid ?? "(connecting…)", on: true }
        }
        return { glyph: ICON.nowifi, title: "Network",
                 sub: "Not connected", on: false }
    })

    return <button
        className="Card Tile"
        onClicked={() => { if (wifi) wifi.set_enabled(!wifi.enabled) }}
        tooltipText="Click: toggle Wi-Fi · Use nm-connection-editor for networks">
        <box vertical spacing={2}>
            <box spacing={6}>
                <label label={summary().as(s => s.glyph)} />
                <label className="CardTitle" label={summary().as(s => s.title)} xalign={0} hexpand />
                <label
                    className={summary().as(s => s.on ? "On" : "Off")}
                    label={summary().as(s => s.on ? "ON" : "OFF")}
                />
            </box>
            <label className="Subtle" xalign={0}
                label={summary().as(s => s.sub)}
            />
        </box>
    </button>
}

// ── Bluetooth card ────────────────────────────────────────────────
function BluetoothCard() {
    const bt = AstalBluetooth.get_default()
    if (!bt) return <box />

    return <button
        className="Card Tile"
        onClicked={() => bt.toggle()}
        tooltipText="Click: toggle Bluetooth">
        <box vertical spacing={2}>
            <box spacing={6}>
                <label label={"\u{f00af}"} />
                <label className="CardTitle" label="Bluetooth" xalign={0} hexpand />
                <label
                    className={bind(bt, "isPowered").as(p => p ? "On" : "Off")}
                    label={bind(bt, "isPowered").as(p => p ? "ON" : "OFF")}
                />
            </box>
            <label
                className="Subtle"
                xalign={0}
                label={bind(bt, "devices").as(devs => {
                    const conn = devs?.filter(d => d.connected) ?? []
                    return conn.length ? conn.map(d => d.name).join(", ") : "(no device)"
                })}
            />
        </box>
    </button>
}

// ── Power Profile card ────────────────────────────────────────────
// Drive via `powerprofilesctl` directly — the AstalPowerProfiles binding
// races with late D-Bus activation when power-profiles-daemon wasn't
// running at AGS startup. CLI is dbus-activated each call and always works.
const POWER_PROFILES = ["power-saver", "balanced", "performance"] as const
const power = Variable("balanced").poll(2000, "powerprofilesctl get")

function PowerProfileCard() {
    function next() {
        const cur = power.get().trim()
        const idx = POWER_PROFILES.indexOf(cur as any)
        const nxt = POWER_PROFILES[(idx + 1) % POWER_PROFILES.length]
        execAsync(["powerprofilesctl", "set", nxt])
            .then(() => power.set(nxt))
            .catch(e => console.error("set power profile:", e))
    }

    return <button
        className="Card Tile"
        onClicked={next}
        tooltipText="Click to cycle: power-saver → balanced → performance">
        <box vertical spacing={2}>
            <box spacing={6}>
                <label label={"\u{f0335}"} />
                <label className="CardTitle" label="Power" xalign={0} hexpand />
            </box>
            <label className="Subtle" xalign={0}
                label={power().as(p => p.trim().replaceAll("-", " "))}
            />
        </box>
    </button>
}

// ── Weather card ──────────────────────────────────────────────────
const weather = Variable("").poll(30 * 60 * 1000, WEATHER_CMD)

function WeatherCard() {
    return <box className="Card Tile" vertical spacing={2}>
        <box spacing={6}>
            <label label={"\u{f0599}"} />
            <label className="CardTitle" label="Weather" xalign={0} hexpand />
        </box>
        <label className="Subtle" xalign={0} label={weather()} />
    </box>
}

// ── Panel ─────────────────────────────────────────────────────────
export default function ControlCenter() {
    const { TOP, BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor

    // Small top-right panel. Dismiss via gear toggle, bar wrapper, or Esc.
    return <window
        name="control-center"
        className="ControlCenterWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        exclusivity={Astal.Exclusivity.NORMAL}
        anchor={TOP | RIGHT}
        layer={Astal.Layer.OVERLAY}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b) self.hide()
        }}>
        <box className="ControlCenter" vertical spacing={10}
            widthRequest={420}>
            <AudioCard />
            <BrightnessCard />
            <box homogeneous spacing={10}>
                <NetworkCard />
                <BluetoothCard />
            </box>
            <box homogeneous spacing={10}>
                <PowerProfileCard />
                <WeatherCard />
            </box>
        </box>
    </window>
}
