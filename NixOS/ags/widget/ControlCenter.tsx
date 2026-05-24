import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, exec, execAsync } from "astal"
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

// ── Brightness card (intel_backlight via brightnessctl) ───────────
const brightness = Variable(0).poll(2000, () => {
    try {
        const cur = parseInt(exec("brightnessctl g"))
        const max = parseInt(exec("brightnessctl m"))
        return max > 0 ? cur / max : 0
    } catch { return 0 }
})

function BrightnessCard() {
    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Brightness" xalign={0} />
        <box spacing={8}>
            <label label={"\u{f0335}"} />
            <slider
                hexpand
                value={brightness()}
                onDragged={({ value }) => {
                    brightness.set(value)
                    execAsync(["brightnessctl", "s", `${Math.round(value * 100)}%`])
                        .catch(() => {})
                }}
            />
            <label widthChars={4} label={brightness().as(v => `${Math.round(v * 100)}%`)} />
        </box>
    </box>
}

// ── Wi-Fi card ────────────────────────────────────────────────────
function WifiCard() {
    const net = AstalNetwork.get_default()
    const wifi = net.wifi
    if (!wifi) return <box />

    return <button
        className="Card Tile"
        onClicked={() => wifi.set_enabled(!wifi.enabled)}
        tooltipText="Click: toggle Wi-Fi · Use nm-connection-editor to pick networks">
        <box vertical spacing={2}>
            <box spacing={6}>
                <label label={ICON.wifi} />
                <label className="CardTitle" label="Wi-Fi" xalign={0} hexpand />
                <label
                    className={bind(wifi, "enabled").as(e => e ? "On" : "Off")}
                    label={bind(wifi, "enabled").as(e => e ? "ON" : "OFF")}
                />
            </box>
            <label
                className="Subtle"
                xalign={0}
                label={bind(wifi, "ssid").as(s => s ?? "(not connected)")}
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
function PowerProfileCard() {
    const pp = AstalPowerProfiles.get_default()
    if (!pp) return <box />

    function next() {
        const profiles = (pp.profiles ?? []).map((p: any) => p.profile)
        if (!profiles.length) return
        const idx = profiles.indexOf(pp.activeProfile)
        pp.set_active_profile(profiles[(idx + 1) % profiles.length])
    }

    return <button
        className="Card Tile"
        onClicked={next}
        tooltipText="Click to cycle power profile">
        <box vertical spacing={2}>
            <box spacing={6}>
                <label label={"\u{f0335}"} />
                <label className="CardTitle" label="Power" xalign={0} hexpand />
            </box>
            <label
                className="Subtle"
                xalign={0}
                label={bind(pp, "activeProfile").as(p =>
                    String(p ?? "balanced").replaceAll("-", " ")
                )}
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
    const { BOTTOM, RIGHT } = Astal.WindowAnchor

    return <window
        name="control-center"
        className="ControlCenterWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        anchor={BOTTOM | RIGHT}
        layer={Astal.Layer.OVERLAY}
        widthRequest={360}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b) self.hide()
        }}>
        <box className="ControlCenter" vertical spacing={10}>
            <AudioCard />
            <BrightnessCard />
            <box homogeneous spacing={10}>
                <WifiCard />
                <BluetoothCard />
            </box>
            <box homogeneous spacing={10}>
                <PowerProfileCard />
                <WeatherCard />
            </box>
        </box>
    </window>
}
