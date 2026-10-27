import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, derive, exec, execAsync } from "astal"
import Wp from "gi://AstalWp"
import AstalNetwork from "gi://AstalNetwork"
import AstalBluetooth from "gi://AstalBluetooth"
import AstalPowerProfiles from "gi://AstalPowerProfiles"
import GLib from "gi://GLib"
import { ICON } from "../lib/icons"
import { WEATHER_CMD, DISPLAY_SCALE_CMD, MOUSE_SPEED_CMD } from "../lib/paths"

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

// ── Microphone card ───────────────────────────────────────────────
// Mirrors AudioCard but drives the default *input* (defaultMicrophone).
// A muted mic shows the slashed glyph; the slider stays live so you can
// pre-set gain while muted. No default source → no card.
function MicCard() {
    const wp = Wp.get_default()
    const mic = wp?.audio?.defaultMicrophone
    if (!mic) return <box />
    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Microphone" xalign={0} />
        <box spacing={8}>
            <button
                onClicked={() => mic.set_mute(!mic.mute)}
                tooltipText="Mute / unmute microphone">
                <label label={bind(mic, "mute").as(m => m ? ICON.mic_off : ICON.mic)} />
            </button>
            <slider
                hexpand
                value={bind(mic, "volume")}
                onDragged={({ value }) => mic.set_volume(value)}
            />
            <label
                widthChars={4}
                label={bind(mic, "volume").as(v => `${Math.round(v * 100)}%`)}
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

// ── Display scale card ────────────────────────────────────────────
// Windows-style display scaling for the focused monitor: the panel keeps its
// native resolution and everything is drawn larger, so text gets bigger and
// stays sharp instead of being upscaled.
//
// The slider moves over the steps that are VALID for that panel rather than a
// continuous range. Hyprland only accepts a scale dividing the screen into
// whole pixels -- 1.75 is fine on many monitors but not on 3840x2160 -- and a
// free-running slider would keep producing values it refuses. display-scale
// also snaps whatever it is given onto a valid step, so even if the focused
// monitor changes under the card, nothing invalid can reach the compositor.
function scaleSteps(): number[] {
    try {
        return exec(`${DISPLAY_SCALE_CMD} steps`).trim().split("\n")
            .map(Number).filter(n => n > 0)
    } catch { return [] }
}

function currentScale(): number {
    try { return Number(exec(`${DISPLAY_SCALE_CMD} get`)) || 1 } catch { return 1 }
}

function ScaleCard() {
    const steps = scaleSteps()
    if (steps.length < 2) return <box />

    const nearest = (v: number) => {
        let best = 0
        for (let i = 1; i < steps.length; i++)
            if (Math.abs(steps[i] - v) < Math.abs(steps[best] - v)) best = i
        return best
    }
    const idx = Variable(nearest(currentScale()))

    const setStep = (i: number) => {
        const n = Math.max(0, Math.min(steps.length - 1, i))
        if (n === idx.get()) return
        idx.set(n)
        execAsync([DISPLAY_SCALE_CMD, "set", String(steps[n])]).catch(() => {})
    }

    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Display scale" xalign={0} />
        <box spacing={8}>
            <label label="Aa" />
            {/* The slider snaps between valid steps rather than sliding freely,
                because Hyprland refuses a scale that does not divide the panel
                into whole pixels.  With only a handful of steps, dragging is
                fiddly, so there is a button at each end to nudge one step. */}
            <button
                className="ScaleStep"
                tooltipText="Smaller"
                onClicked={() => setStep(idx.get() - 1)}>
                <label label="−" />
            </button>
            <slider
                hexpand
                min={0}
                max={steps.length - 1}
                step={1}
                value={bind(idx)}
                onDragged={({ value }) => setStep(Math.round(value))}
            />
            <button
                className="ScaleStep"
                tooltipText="Larger"
                onClicked={() => setStep(idx.get() + 1)}>
                <label label="+" />
            </button>
            <label widthChars={5} label={bind(idx).as(i => `${Math.round(steps[i] * 100)}%`)} />
        </box>
    </box>
}

function WindowsResourcesCard() {
    const command = GLib.find_program_in_path("winapps-settings")
    if (!command) return <box />
    const summary = Variable("Shared by all Windows apps")
    const refresh = () => execAsync([command, "status"])
        .then(output => {
            const details = JSON.parse(output)
            const defaults = `${details.configured_cpus} vCPUs · ${details.configured_gib} GiB`
            summary.set(details.running_gib === null || details.running_cpus === null
                ? `Defaults: ${defaults} (${details.state})`
                : `${details.state}: ${details.running_cpus} vCPUs · ${details.running_gib} GiB` +
                    (details.pending ? `\nDefaults: ${defaults}` : ""))
        })
        .catch(() => summary.set("VM status unavailable"))

    return <box className="Card" vertical spacing={4}
        onMap={() => { refresh() }}
        onDestroy={() => summary.drop()}>
        <label className="CardTitle" label="WinApps" xalign={0} />
        <box spacing={8}>
            <label hexpand xalign={0} wrap label={bind(summary)} />
            <button tooltipText="Manage Windows apps, CPU/RAM, desktop scale, and shutdown"
                onClicked={() => {
                    App.get_window("control-center")?.hide()
                    execAsync([command, "gui"])
                        .then(() => refresh())
                        .catch(error => console.error("WinApps:", error))
                }}>
                <label label="Manage…" />
            </button>
        </box>
    </box>
}

function MouseSpeedCard() {
    const current = () => {
        try {
            const value = Number(exec(`${MOUSE_SPEED_CMD} get`))
            return Number.isFinite(value) ? value : 0
        } catch { return 0 }
    }
    const speed = Variable(current())

    const setSpeed = (value: number) => {
        const next = Math.round(Math.max(-1, Math.min(1, value)) * 20) / 20
        if (next === speed.get()) return
        try {
            exec(`${MOUSE_SPEED_CMD} set ${next.toFixed(2)}`)
            speed.set(next)
        } catch (error) { console.error("mouse speed:", error) }
    }

    return <box className="Card" vertical spacing={4}>
        <label className="CardTitle" label="Mouse speed" xalign={0} />
        <box spacing={8}>
            <label label="Slow" />
            <slider
                hexpand
                min={-1}
                max={1}
                step={0.05}
                value={bind(speed)}
                onDragged={({ value }) => setSpeed(value)}
            />
            <label label="Fast" />
            <label widthChars={5}
                label={bind(speed).as(value => value > 0 ? `+${value.toFixed(2)}` : value.toFixed(2))} />
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
    const selectedSsid = Variable<string | null>(null)
    const profiles = Variable<{ uuid: string, ssid: string, autoConnect: boolean }[]>([])
    const pwFor = Variable<AstalNetwork.AccessPoint | null>(null)  // AP awaiting a password
    const password = Variable("")
    const status = Variable("")                                    // transient connect feedback

    async function refreshProfiles() {
        try {
            const rows = await execAsync(["nmcli", "-t", "-f", "UUID,TYPE", "connection", "show"])
            const uuids = rows.split("\n")
                .filter(row => row.endsWith(":802-11-wireless"))
                .map(row => row.slice(0, row.indexOf(":")))
            const saved = await Promise.all(uuids.map(async uuid => {
                const details = await execAsync(["nmcli", "-g",
                    "802-11-wireless.ssid,connection.autoconnect",
                    "connection", "show", "uuid", uuid])
                const [ssid, autoConnect] = details.trimEnd().split("\n")
                return { uuid, ssid, autoConnect: autoConnect === "yes" }
            }))
            profiles.set(saved.filter(profile => !!profile.ssid))
        } catch (error) {
            console.error("wifi saved profiles:", error)
        }
    }

    refreshProfiles()

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
                try {
                    (ap as any).activate_finish(res)
                    status.set(`Connected to ${ap.ssid}`)
                    refreshProfiles()
                }
                catch (e) { status.set(`Failed: ${ap.ssid}`); console.error("wifi connect:", e) }
            })
        } catch (e) { status.set(`Failed: ${ap.ssid}`); console.error("wifi activate:", e) }
    }

    function connectSelected(ssid: string) {
        const saved = profiles.get().find(profile => profile.ssid === ssid)
        if (saved) {
            status.set(`Connecting to ${ssid}…`)
            execAsync(["nmcli", "connection", "up", "uuid", saved.uuid])
                .then(() => { status.set(`Connected to ${ssid}`); refreshProfiles() })
                .catch(error => { status.set(`Could not connect to ${ssid}`); console.error("wifi connect:", error) })
            return
        }
        const ap = (wifi!.accessPoints ?? []).find(candidate => candidate.ssid === ssid)
        if (!ap) { status.set(`${ssid} is no longer in range`); return }
        if (ap.get_requires_password()) {
            password.set(""); pwFor.set(ap)                        // prompt only when needed
        } else {
            connect(ap, null)
        }
    }

    async function setAutoConnect(uuids: string[], enabled: boolean, ssid: string) {
        try {
            for (const uuid of uuids) {
                await execAsync(["nmcli", "connection", "modify", "uuid", uuid,
                                 "connection.autoconnect", enabled ? "yes" : "no"])
            }
            status.set(`Auto-connect ${enabled ? "on" : "off"} for ${ssid}`)
        } catch (error) {
            status.set(`Could not change auto-connect for ${ssid}`)
            console.error("wifi auto-connect:", error)
        } finally {
            await refreshProfiles()
        }
    }

    async function disconnect(ssid: string): Promise<boolean> {
        const iface = wifi!.get_device()?.get_iface()
        if (!iface) { status.set("Wi-Fi device unavailable"); return false }
        try {
            await execAsync(["nmcli", "device", "disconnect", iface])
            status.set(`Disconnected from ${ssid}`)
            return true
        } catch (error) {
            status.set(`Could not disconnect from ${ssid}`)
            console.error("wifi disconnect:", error)
            return false
        }
    }

    async function forget(uuids: string[], ssid: string, active: boolean) {
        try {
            if (active && !await disconnect(ssid)) return
            for (const uuid of uuids)
                await execAsync(["nmcli", "connection", "delete", "uuid", uuid])
            status.set(`Forgot ${ssid}`)
        } catch (error) {
            status.set(`Could not forget ${ssid}`)
            console.error("wifi forget:", error)
        } finally {
            await refreshProfiles()
        }
    }

    function submitPw() {
        const ap = pwFor.get()
        if (!ap) return
        connect(ap, password.get())
        pwFor.set(null); password.set("")
    }

    function ApRow(ap: AstalNetwork.AccessPoint, active: AstalNetwork.AccessPoint | null) {
        const ssid = ap.ssid
        const isActive = active != null && ap.bssid === active.bssid
        const secured = ap.get_requires_password()
        return <button className={selectedSsid().as(selected => selected === ssid ? "ApRow ApSelected" : "ApRow")}
            onClicked={() => { selectedSsid.set(ssid); pwFor.set(null) }}
            onButtonPressEvent={(_self, event) => {
                if (event.get_button()[1] !== 3) return false
                selectedSsid.set(ssid)
                pwFor.set(null)
                status.set(`Actions for ${ssid}`)
                return true
            }}
            tooltipText={`${ssid} · ${ap.strength}%` + (secured ? " · secured" : " · open")
                + " · right-click for actions"}>
            <box spacing={8}>
                <label className="ApLock" label={secured ? ICON.lock : " "} />
                <label className="ApSsid" xalign={0} hexpand label={ssid} />
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
                .sort((a, b) => Number(b.bssid === active?.bssid) - Number(a.bssid === active?.bssid)
                    || b.strength - a.strength)
                .filter(ap => { if (seen.has(ap.ssid)) return false; seen.add(ap.ssid); return true })
                .slice(0, 16)
            if (!list.length) {
                return [<label className="Subtle ApEmpty" xalign={0}
                    label={wifi!.get_enabled() ? "Scanning…" : "Wi-Fi is off"} />]
            }
            return list.map(ap => ApRow(ap, active))
        }
    )

    const selectedDetails = derive(
        [selectedSsid, bind(wifi, "accessPoints"), bind(wifi, "activeAccessPoint"), profiles],
        (ssid: string | null, aps: AstalNetwork.AccessPoint[], active: AstalNetwork.AccessPoint | null,
         availableProfiles: { uuid: string, ssid: string, autoConnect: boolean }[]) => {
            if (!ssid) return null
            const ap = (aps ?? []).find(candidate => candidate.ssid === ssid && candidate.bssid === active?.bssid)
                ?? (aps ?? []).filter(candidate => candidate.ssid === ssid)
                    .sort((a, b) => b.strength - a.strength)[0]
            if (!ap) return { ssid, ap: null, active: false, uuids: [], autoConnect: false }
            const saved = availableProfiles.filter(profile => profile.ssid === ssid)
            const uuids = saved.map(profile => profile.uuid)
            return { ssid, ap, active: ap.bssid === active?.bssid, uuids,
                     autoConnect: saved.some(profile => profile.autoConnect) }
        }
    )

    return <box className="Card NetCard" vertical spacing={6}>
        <box spacing={6}>
            <button className="NetHeader" hexpand
                onClicked={() => { const e = !expanded.get(); expanded.set(e); if (e) { rescan(); refreshProfiles() } }}
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
                <box visible={selectedDetails().as(detail => detail !== null)}>
                    {selectedDetails().as(detail => {
                        if (!detail) return <box />
                        if (!detail.ap) return <label className="Subtle" xalign={0}
                            label={`${detail.ssid} is no longer in range`} />
                        return <box className="ApDetails" vertical spacing={5}>
                            <label className="ApSsid" xalign={0} label={detail.ssid} />
                            <box spacing={6}>
                                <button className="ApAction" hexpand
                                    onClicked={() => detail.active
                                        ? disconnect(detail.ssid) : connectSelected(detail.ssid)}>
                                    <label label={detail.active ? "Disconnect" : "Connect"} />
                                </button>
                                <button className="ApAction"
                                    visible={detail.uuids.length > 0}
                                    onClicked={() => forget(detail.uuids, detail.ssid, detail.active)}>
                                    <label label="Forget" />
                                </button>
                            </box>
                            <box spacing={6} visible={detail.uuids.length > 0}>
                                <label className="Subtle" xalign={0} hexpand label="Auto-connect" />
                                <button className={detail.autoConnect ? "ApAuto On" : "ApAuto Off"}
                                    onClicked={() => setAutoConnect(detail.uuids,
                                        !detail.autoConnect, detail.ssid)}>
                                    <label label={detail.autoConnect ? "ON" : "OFF"} />
                                </button>
                            </box>
                            <label className="Subtle" xalign={0}
                                visible={detail.uuids.length === 0}
                                label="Connect first to save this network and set auto-connect." />
                        </box>
                    })}
                </box>
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
const BT_GLYPH = "\u{f00af}"  // nf-md-bluetooth

// Map a freedesktop device icon name to a glyph; fall back to the BT symbol.
// Only classic nf-fa codepoints (present in CaskaydiaCove) are used.
function devGlyph(icon: string | null): string {
    if (!icon) return BT_GLYPH
    if (/audio|head(set|phone)/.test(icon)) return "\u{f025}"  // headphones
    if (/keyboard/.test(icon))              return "\u{f11c}"  // keyboard
    if (/phone/.test(icon))                 return "\u{f10b}"  // mobile
    return BT_GLYPH
}

function devBattery(dev: AstalBluetooth.Device): string {
    const p = dev.batteryPercentage
    if (!p || p <= 0) return ""
    return (p <= 1 ? Math.round(p * 100) : Math.round(p)) + "%"
}

function BluetoothCard() {
    const bt = AstalBluetooth.get_default()
    if (!bt) return <box />

    const adapter = bt.get_adapter()
    const expanded = Variable(false)
    const status = Variable("")

    function discover(on: boolean) {
        if (!adapter) return
        try { on ? adapter.start_discovery() : adapter.stop_discovery() }
        catch (e) { console.error("bt discovery:", e) }
    }

    function onDevClicked(dev: AstalBluetooth.Device) {
        if (dev.connecting) return
        if (dev.connected) {
            status.set(`Disconnecting ${dev.name}…`)
            ;(dev as any).disconnect_device((_s: any, res: any) => {
                try { (dev as any).disconnect_device_finish(res); status.set("") }
                catch (e) { status.set(`Failed: ${dev.name}`); console.error("bt disconnect:", e) }
            })
            return
        }
        // pair() is only needed (and only invoked) for unknown devices; saved
        // ones go straight to connect. Trust so it auto-reconnects next time.
        if (!dev.paired) {
            status.set(`Pairing ${dev.name}…`)
            try { dev.pair() } catch (e) { console.error("bt pair:", e) }
        }
        try { dev.set_trusted(true) } catch (e) { /* non-fatal */ }
        status.set(`Connecting ${dev.name}…`)
        ;(dev as any).connect_device((_s: any, res: any) => {
            try { (dev as any).connect_device_finish(res); status.set(`Connected ${dev.name}`) }
            catch (e) { status.set(`Failed: ${dev.name}`); console.error("bt connect:", e) }
        })
    }

    function DevRow(dev: AstalBluetooth.Device) {
        const meta = derive(
            [bind(dev, "connected"), bind(dev, "connecting"), bind(dev, "batteryPercentage")],
            () => {
                if (dev.connecting) return "connecting…"
                if (dev.connected) { const b = devBattery(dev); return b ? `connected · ${b}` : "connected" }
                return dev.paired ? "paired" : "tap to pair"
            }
        )
        return <button className="ApRow" onClicked={() => onDevClicked(dev)}
            tooltipText={dev.address}>
            <box spacing={8}>
                <label className="ApLock" label={devGlyph(dev.icon)} />
                <box vertical hexpand>
                    <label className="ApSsid" xalign={0} label={dev.name ?? dev.address} />
                    <label className="Subtle" xalign={0} label={meta()} />
                </box>
                <label className="ApActive"
                    label={bind(dev, "connected").as(c => c ? ICON.check : " ")} />
            </box>
        </button>
    }

    // Connected → paired → discovered; named devices ahead of bare addresses.
    const devRows = bind(bt, "devices").as((devs: AstalBluetooth.Device[]) => {
        const score = (d: AstalBluetooth.Device) => d.connected ? 0 : d.paired ? 1 : 2
        const list = (devs ?? [])
            .slice()
            .sort((a, b) => score(a) - score(b) || (a.name ?? "~").localeCompare(b.name ?? "~"))
            .slice(0, 16)
        if (!list.length) {
            return [<label className="Subtle ApEmpty" xalign={0}
                label={bt.get_is_powered() ? "Searching…" : "Bluetooth is off"} />]
        }
        return list.map(d => DevRow(d))
    })

    const subtitle = bind(bt, "devices").as((devs: AstalBluetooth.Device[]) => {
        const conn = (devs ?? []).filter(d => d.connected)
        return conn.length ? conn.map(d => d.name).join(", ")
                           : (bt.get_is_powered() ? "No device connected" : "Off")
    })

    return <box className="Card BtCard" vertical spacing={6}>
        <box spacing={6}>
            <button className="NetHeader" hexpand
                onClicked={() => { const e = !expanded.get(); expanded.set(e); discover(e) }}
                tooltipText="Show Bluetooth devices">
                <box spacing={8}>
                    <label label={BT_GLYPH} />
                    <box vertical hexpand>
                        <label className="CardTitle" xalign={0} label="Bluetooth" />
                        <label className="Subtle" xalign={0} label={subtitle} />
                    </box>
                    <label className="Chevron"
                        label={expanded().as(e => e ? ICON.chevron_up : ICON.chevron_dn)} />
                </box>
            </button>
            <button className="NetToggle" onClicked={() => bt.toggle()}
                tooltipText="Toggle Bluetooth radio">
                <label className={bind(bt, "isPowered").as(p => p ? "On" : "Off")}
                    label={bind(bt, "isPowered").as(p => p ? "ON" : "OFF")} />
            </button>
        </box>

        <revealer revealChild={expanded()}
            transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN}
            transitionDuration={150}>
            <box className="ApList" vertical spacing={6}>
                <box spacing={6}>
                    <label className="Subtle" xalign={0} hexpand
                        label={status().as(s => s || "Devices")} />
                    <label className="Subtle"
                        label={adapter ? bind(adapter, "discovering").as(d => d ? "scanning…" : "") : ""} />
                    <button className="ApRefresh" onClicked={() => discover(true)} tooltipText="Scan">
                        <label label={ICON.refresh} />
                    </button>
                </box>
                <scrollable className="ApScroll" heightRequest={170}
                    vscroll={Gtk.PolicyType.AUTOMATIC} hscroll={Gtk.PolicyType.NEVER}>
                    <box vertical spacing={2}>{devRows}</box>
                </scrollable>
            </box>
        </revealer>
    </box>
}

// ── Power Profile card ────────────────────────────────────────────
// Tap-to-pick selector. Drive via `powerprofilesctl` directly — the
// AstalPowerProfiles binding races with late D-Bus activation when
// power-profiles-daemon wasn't running at AGS startup. CLI is
// dbus-activated each call and always works.
const POWER_PROFILES = [
    { id: "power-saver", label: "Saver" },
    { id: "balanced",    label: "Balanced" },
    { id: "performance", label: "Performance" },
] as const

// Full `powerprofilesctl` listing, re-read periodically (and on demand after
// a set). We parse the active profile and any performance-degraded reason
// (e.g. "lap-detected") out of it.
const ppdText = Variable("").poll(4000, "powerprofilesctl")

function parsePPD(text: string): { active: string; degraded: string } {
    let active = "balanced", degraded = "", profile: string | null = null
    for (const ln of (text ?? "").split("\n")) {
        const h = ln.match(/^(\*|\s)\s*([a-z-]+):\s*$/)
        if (h) { profile = h[2]; if (h[1] === "*") active = profile; continue }
        const d = ln.match(/Degraded:\s*(.+?)\s*$/)
        if (d && profile === "performance" && d[1] !== "no") {
            const paren = d[1].match(/\(([^)]+)\)/)   // "yes (lap-detected)" → "lap-detected"
            degraded = (paren ? paren[1] : d[1]).replace(/-/g, " ")
        }
    }
    return { active, degraded }
}

function PowerProfileCard() {
    const state = ppdText().as(parsePPD)

    function setProfile(id: string) {
        execAsync(["powerprofilesctl", "set", id])
            .then(() => execAsync("powerprofilesctl"))
            .then(t => ppdText.set(t))
            .catch(e => console.error("set power profile:", e))
    }

    return <box className="Card PowerCard" vertical spacing={6}>
        <box spacing={6}>
            <label label={"\u{f0335}"} />
            <label className="CardTitle" label="Power" xalign={0} hexpand />
        </box>
        <box className="PowerSeg" homogeneous spacing={6}>
            {POWER_PROFILES.map(p =>
                <button className={state.as(s => s.active === p.id ? "PowerOpt Active" : "PowerOpt")}
                    onClicked={() => setProfile(p.id)}
                    tooltipText={`Set ${p.label} power profile`}>
                    <label label={p.label} />
                </button>
            )}
        </box>
        <revealer revealChild={state.as(s => s.degraded !== "")}
            transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN}>
            <label className="Subtle PowerDegraded" xalign={0} wrap
                label={state.as(s => `${ICON.warning}  performance throttled · ${s.degraded}`)} />
        </revealer>
    </box>
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

// ── Printers & Scanners card ──────────────────────────────────────
// No Astal CUPS/SANE binding exists, so drive the CLI like PowerProfileCard
// drives powerprofilesctl. Printer state + queue length poll cheaply (local
// lpstat). Scanner enumeration (scanimage -L is slow over the network) runs
// lazily on first expand. Tapping a printer sets a USER default via
// `lpoptions -d` — no root, unlike the system-wide `lpadmin -d`.
const PRINT_POLL =
    "lpstat -p 2>/dev/null; echo __DEF__; lpstat -d 2>/dev/null; echo __JOBS__; lpstat -o 2>/dev/null | wc -l"

type PrinterInfo = { name: string; state: string }

function parsePrinters(text: string): { printers: PrinterInfo[]; def: string; jobs: number } {
    const printers: PrinterInfo[] = []
    let def = "", jobs = 0, section = "p"
    for (const ln of (text ?? "").split("\n")) {
        if (ln === "__DEF__") { section = "d"; continue }
        if (ln === "__JOBS__") { section = "j"; continue }
        if (section === "p") {
            const m = ln.match(/^printer (\S+) (.*)$/)
            if (m) {
                const rest = m[2]
                const state = /now printing|is printing/.test(rest) ? "printing"
                            : /disabled/.test(rest) ? "disabled"
                            : /is idle/.test(rest) ? "idle" : "ready"
                printers.push({ name: m[1], state })
            }
        } else if (section === "d") {
            const m = ln.match(/system default destination: (\S+)/)
            if (m) def = m[1]
        } else if (section === "j") {
            const n = parseInt(ln.trim()); if (!isNaN(n)) jobs = n
        }
    }
    return { printers, def, jobs }
}

const printRaw = Variable("").poll(8000, () => {
    try { return exec(["sh", "-c", PRINT_POLL]) } catch { return "" }
})

function PrintersCard() {
    const expanded = Variable(false)
    const scanners = Variable<{ id: string; name: string }[]>([])
    const scanState = Variable("")

    const state = printRaw().as(parsePrinters)

    function refresh() { try { printRaw.set(exec(["sh", "-c", PRINT_POLL])) } catch { /* keep last */ } }

    function setDefault(name: string) {
        execAsync(["lpoptions", "-d", name]).then(refresh)
            .catch(e => console.error("set default printer:", e))
    }

    // scanimage -L: `device `escl:...' is a Brother … scanner`. Skip v4l webcams.
    function detectScanners() {
        scanState.set("Detecting…")
        execAsync(["scanimage", "-L"]).then(out => {
            const list: { id: string; name: string }[] = []
            for (const ln of out.split("\n")) {
                const m = ln.match(/device `([^']+)' is a (.+)/)
                if (!m || m[1].startsWith("v4l:")) continue
                list.push({ id: m[1], name: m[2].replace(/ scanner$/, "") })
            }
            scanners.set(list)
            scanState.set(list.length ? "Scanners" : "No scanners found")
        }).catch(e => { console.error("scanimage -L:", e); scanState.set("Scanner detect failed") })
    }

    let scanned = false
    function onExpand() {
        const e = !expanded.get(); expanded.set(e)
        if (e && !scanned) { scanned = true; detectScanners() }
    }

    // Launch a GUI app onto the active workspace, dismissing the panel first.
    function launch(cmd: string) {
        App.get_window("control-center")?.hide()
        execAsync(["hyprctl", "dispatch", "exec", cmd])
            .catch(e => console.error("launch:", e))
    }

    const subtitle = state.as(s => {
        if (!s.def) return "No default printer"
        const p = s.printers.find(x => x.name === s.def)
        const st = p ? p.state : "unknown"
        return `${s.def.replace(/_/g, " ")} · ${st}` + (s.jobs ? ` · ${s.jobs} in queue` : "")
    })

    return <box className="Card BtCard" vertical spacing={6}>
        <box spacing={6}>
            <button className="NetHeader" hexpand onClicked={onExpand}
                tooltipText="Show printers and scanners">
                <box spacing={8}>
                    <label label={ICON.printer} />
                    <box vertical hexpand>
                        <label className="CardTitle" xalign={0} label="Printers & Scanners" />
                        <label className="Subtle" xalign={0} label={subtitle} />
                    </box>
                    <label className="Chevron"
                        label={expanded().as(e => e ? ICON.chevron_up : ICON.chevron_dn)} />
                </box>
            </button>
            <button className="NetToggle" onClicked={() => launch("naps2")}
                tooltipText="Open NAPS2 scanner">
                <label label="Scan" />
            </button>
        </box>

        <revealer revealChild={expanded()}
            transitionType={Gtk.RevealerTransitionType.SLIDE_DOWN} transitionDuration={150}>
            <box className="ApList" vertical spacing={6}>
                <label className="Subtle" xalign={0} label="Printers · tap to set default" />
                {state.as(s => s.printers.length
                    ? s.printers.map(p =>
                        <button className="ApRow" onClicked={() => setDefault(p.name)}
                            tooltipText={`Set ${p.name} as default`}>
                            <box spacing={8}>
                                <label className="ApSsid" xalign={0} hexpand
                                    label={p.name.replace(/_/g, " ")} />
                                <label className="Subtle" label={p.state} />
                                <label className="ApActive" label={p.name === s.def ? ICON.check : " "} />
                            </box>
                        </button>)
                    : [<label className="Subtle ApEmpty" xalign={0} label="No printers configured" />])}

                <label className="Subtle" xalign={0} label={scanState()} />
                {scanners().as(list => list.map(sc =>
                    <button className="ApRow" onClicked={() => launch("naps2")} tooltipText={sc.id}>
                        <box spacing={8}>
                            <label className="ApSsid" xalign={0} hexpand label={sc.name} />
                            <label className="Subtle" label={/^escl:/.test(sc.id) ? "network" : "usb"} />
                        </box>
                    </button>))}

                <box spacing={6} homogeneous>
                    <button className="PowerOpt" onClicked={() => launch("naps2")}
                        tooltipText="Scan documents (NAPS2)">
                        <label label="Scan (NAPS2)" />
                    </button>
                    <button className="PowerOpt"
                        onClicked={() => launch("xdg-open http://localhost:631/printers")}
                        tooltipText="Open the CUPS web interface">
                        <label label="CUPS" />
                    </button>
                    <button className="ApRefresh" onClicked={() => { refresh(); detectScanners() }}
                        tooltipText="Refresh">
                        <label label={ICON.refresh} />
                    </button>
                </box>
            </box>
        </revealer>
    </box>
}

// ── Panel ─────────────────────────────────────────────────────────
export default function ControlCenter() {
    const { TOP, BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor

    // Full-screen transparent window; NORMAL exclusivity keeps it below the
    // bar so the bar stays clickable. Outer eventbox dismisses on any click
    // outside the panel; inner eventbox swallows the panel's own clicks.
    // Also dismissable via the gear toggle, the bar wrapper, or Esc.
    return <window
        name="control-center"
        className="ControlCenterWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        exclusivity={Astal.Exclusivity.NORMAL}
        anchor={TOP | BOTTOM | LEFT | RIGHT}
        layer={Astal.Layer.OVERLAY}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b) self.hide()
        }}>
        <eventbox hexpand vexpand
            onButtonPressEvent={(self) => {
                const w = self.get_ancestor(Astal.Window.$gtype) as Astal.Window
                w?.hide(); return true
            }}>
        <box halign={Gtk.Align.END} valign={Gtk.Align.START}>
        <eventbox onButtonPressEvent={() => true}>
        <box className="ControlCenter" vertical spacing={10}
            widthRequest={420}>
            <AudioCard />
            <MicCard />
            <BrightnessCard />
            <ScaleCard />
            <MouseSpeedCard />
            <WindowsResourcesCard />
            <NetworkCard />
            <BluetoothCard />
            <PowerProfileCard />
            <PrintersCard />
            <WeatherCard />
        </box>
        </eventbox>
        </box>
        </eventbox>
    </window>
}
