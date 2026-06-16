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
// Wi-Fi signal as a 4-segment block bar. Uses U+2588/U+2591 (full/light
// shade) so it renders in any font — no reliance on optional Nerd-Font
// wifi-strength codepoints that CaskaydiaCove is missing.
function signalBars(strength: number): string {
    const lvl = Math.max(0, Math.min(4, Math.round((strength ?? 0) / 25)))
    return "█".repeat(lvl).padEnd(4, "░")
}

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

    // Ethernet-only / no Wi-Fi device: keep the simple status tile.
    if (!wifi) {
        return <box className="Card Tile" vertical spacing={2}>
            <box spacing={6}>
                <label label={summary().as(s => s.glyph)} />
                <label className="CardTitle" xalign={0} hexpand label={summary().as(s => s.title)} />
            </box>
            <label className="Subtle" xalign={0} label={summary().as(s => s.sub)} />
        </box>
    }

    // Picker state (this component is constructed once).
    const expanded = Variable(false)
    const pwFor = Variable<AstalNetwork.AccessPoint | null>(null)  // AP awaiting a password
    const password = Variable("")
    const status = Variable("")                                    // transient connect feedback

    function rescan() {
        if (!wifi!.get_enabled()) return
        try { wifi!.scan() } catch (e) { console.error("wifi scan:", e) }
    }

    // astal's activate() reuses a saved connection or builds a wpa-psk one from
    // the supplied password. password === null → open or already-saved network.
    function connect(ap: AstalNetwork.AccessPoint, pw: string | null) {
        status.set(`Connecting to ${ap.ssid}…`)
        try {
            (ap as any).activate(pw, (_src: any, res: any) => {
                try { (ap as any).activate_finish(res); status.set(`Connected to ${ap.ssid}`) }
                catch (e) { status.set(`Failed: ${ap.ssid}`); console.error("wifi connect:", e) }
            })
        } catch (e) { status.set(`Failed: ${ap.ssid}`); console.error("wifi activate:", e) }
    }

    function onApClicked(ap: AstalNetwork.AccessPoint) {
        const active = wifi!.get_active_access_point()
        if (active && ap.bssid === active.bssid) return            // already connected
        const saved = ((ap.get_connections() as any[]) ?? []).length > 0
        if (ap.get_requires_password() && !saved) {
            password.set(""); pwFor.set(ap)                        // prompt only when needed
        } else {
            connect(ap, null)
        }
    }

    function submitPw() {
        const ap = pwFor.get()
        if (!ap) return
        connect(ap, password.get())
        pwFor.set(null); password.set("")
    }

    function ApRow(ap: AstalNetwork.AccessPoint, active: AstalNetwork.AccessPoint | null) {
        const isActive = active != null && ap.bssid === active.bssid
        const secured = ap.get_requires_password()
        return <button className="ApRow" onClicked={() => onApClicked(ap)}
            tooltipText={`${ap.ssid} · ${ap.strength}%` + (secured ? " · secured" : " · open")}>
            <box spacing={8}>
                <label className="ApLock" label={secured ? ICON.lock : " "} />
                <label className="ApSsid" xalign={0} hexpand label={ap.ssid} />
                <label className="ApActive" label={isActive ? ICON.check : " "} />
                <label className="ApSignal" label={signalBars(ap.strength)} />
            </box>
        </button>
    }

    // Strongest-first, deduped by SSID, non-empty. Rebuilds on scan results or
    // a change of active AP (so the ✓ tracks the live connection).
    const apRows = derive(
        [bind(wifi, "accessPoints"), bind(wifi, "activeAccessPoint")],
        (aps: AstalNetwork.AccessPoint[], active: AstalNetwork.AccessPoint | null) => {
            const seen = new Set<string>()
            const list = (aps ?? [])
                .filter(ap => !!ap.ssid)
                .sort((a, b) => b.strength - a.strength)
                .filter(ap => { if (seen.has(ap.ssid)) return false; seen.add(ap.ssid); return true })
                .slice(0, 16)
            if (!list.length) {
                return [<label className="Subtle ApEmpty" xalign={0}
                    label={wifi!.get_enabled() ? "Scanning…" : "Wi-Fi is off"} />]
            }
            return list.map(ap => ApRow(ap, active))
        }
    )

    return <box className="Card NetCard" vertical spacing={6}>
        <box spacing={6}>
            <button className="NetHeader" hexpand
                onClicked={() => { const e = !expanded.get(); expanded.set(e); if (e) rescan() }}
                tooltipText="Show nearby Wi-Fi networks">
                <box spacing={8}>
                    <label label={summary().as(s => s.glyph)} />
                    <box vertical hexpand>
                        <label className="CardTitle" xalign={0} label={summary().as(s => s.title)} />
                        <label className="Subtle" xalign={0} label={summary().as(s => s.sub)} />
                    </box>
                    <label className="Chevron"
                        label={expanded().as(e => e ? ICON.chevron_up : ICON.chevron_dn)} />
                </box>
            </button>
            <button className="NetToggle"
                onClicked={() => wifi!.set_enabled(!wifi!.get_enabled())}
                tooltipText="Toggle Wi-Fi radio">
                <label className={bind(wifi, "enabled").as(e => e ? "On" : "Off")}
                    label={bind(wifi, "enabled").as(e => e ? "ON" : "OFF")} />
            </button>
        </box>

        <revealer revealChild={expanded()}
            transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN}
            transitionDuration={150}>
            <box className="ApList" vertical spacing={6}>
                <box spacing={6}>
                    <label className="Subtle" xalign={0} hexpand
                        label={status().as(s => s || "Nearby networks")} />
                    <label className="Subtle"
                        label={bind(wifi, "scanning").as(s => s ? "scanning…" : "")} />
                    <button className="ApRefresh" onClicked={rescan} tooltipText="Rescan">
                        <label label={ICON.refresh} />
                    </button>
                </box>
                <scrollable className="ApScroll" heightRequest={190}
                    vscroll={Gtk.PolicyType.AUTOMATIC} hscroll={Gtk.PolicyType.NEVER}>
                    <box vertical spacing={2}>{apRows()}</box>
                </scrollable>
                <revealer revealChild={pwFor().as(ap => ap !== null)}
                    transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN}>
                    <box className="ApPassword" spacing={6}>
                        <label className="ApLock" label={ICON.lock} />
                        <entry className="ApPwEntry" hexpand visibility={false}
                            placeholderText={pwFor().as(ap => ap ? `Password · ${ap.ssid}` : "")}
                            onChanged={self => password.set(self.text)}
                            onActivate={() => submitPw()} />
                        <button className="ApJoin" onClicked={() => submitPw()} tooltipText="Join">
                            <label label="Join" />
                        </button>
                        <button onClicked={() => { pwFor.set(null); password.set("") }}
                            tooltipText="Cancel">
                            <label label={ICON.close} />
                        </button>
                    </box>
                </revealer>
            </box>
        </revealer>
    </box>
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
            <NetworkCard />
            <box homogeneous spacing={10}>
                <BluetoothCard />
                <PowerProfileCard />
            </box>
            <WeatherCard />
        </box>
    </window>
}
