import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, derive, exec, execAsync } from "astal"
import Wp from "gi://AstalWp"
import AstalNetwork from "gi://AstalNetwork"
import AstalBluetooth from "gi://AstalBluetooth"
import AstalPowerProfiles from "gi://AstalPowerProfiles"
import Mpris from "gi://AstalMpris"
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

// ── Now Playing card (compact, embedded in CC) ────────────────────
function NowPlayingCard(): Gtk.Widget {
    const mpris = Mpris.get_default()

    const art = new Gtk.Image({ pixel_size: 64 })
    art.get_style_context().add_class("NPCardArt")
    art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)

    const title = new Gtk.Label({
        xalign: 0, halign: Gtk.Align.START,
        max_width_chars: 24, ellipsize: 3,
    })
    title.get_style_context().add_class("NPCardTitle")

    const artist = new Gtk.Label({
        xalign: 0, halign: Gtk.Align.START,
        max_width_chars: 28, ellipsize: 3,
    })
    artist.get_style_context().add_class("NPCardArtist")

    const mkBtn = (glyph: string) => {
        const b = new Gtk.Button()
        const l = new Gtk.Label({ label: glyph })
        b.add(l)
        b.get_style_context().add_class("NPCardXport")
        return [b, l] as const
    }
    const [prevBtn] = mkBtn(ICON.prev)
    const [playBtn, playLbl] = mkBtn(ICON.play)
    const [nextBtn] = mkBtn(ICON.next)

    let cur: Mpris.Player | null = null
    const signals: number[] = []
    function detach() {
        if (cur) for (const id of signals) cur.disconnect(id)
        signals.length = 0
        cur = null
    }
    function refresh() {
        if (!cur) {
            title.label = "Nothing playing"
            artist.label = ""
            art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)
            playLbl.label = ICON.play
            prevBtn.set_sensitive(false)
            nextBtn.set_sensitive(false)
            playBtn.set_sensitive(false)
            return
        }
        title.label = cur.title || "Unknown"
        artist.label = cur.artist || ""
        const cover = cur.coverArt
        if (cover) art.set_from_file(cover)
        else art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)
        playLbl.label = cur.playbackStatus === Mpris.PlaybackStatus.PLAYING
            ? ICON.pause : ICON.play
        prevBtn.set_sensitive(cur.canGoPrevious)
        nextBtn.set_sensitive(cur.canGoNext)
        playBtn.set_sensitive(cur.canControl)
    }
    function attach(p: Mpris.Player | null) {
        detach()
        cur = p
        if (p) {
            for (const prop of ["title","artist","cover-art","playback-status",
                                "can-go-previous","can-go-next","can-control"]) {
                signals.push(p.connect(`notify::${prop}`, refresh))
            }
        }
        refresh()
    }
    const pickFirst = () => attach(mpris.players[0] ?? null)
    mpris.connect("notify::players", pickFirst)
    pickFirst()

    prevBtn.connect("clicked", () => cur?.previous())
    playBtn.connect("clicked", () => cur?.play_pause())
    nextBtn.connect("clicked", () => cur?.next())

    const xport = new Gtk.Box({ spacing: 6, halign: Gtk.Align.START })
    xport.add(prevBtn); xport.add(playBtn); xport.add(nextBtn)

    const info = new Gtk.Box({
        orientation: Gtk.Orientation.VERTICAL, spacing: 2, hexpand: true,
        valign: Gtk.Align.CENTER,
    })
    info.add(title); info.add(artist); info.add(xport)

    const row = new Gtk.Box({ spacing: 10 })
    row.add(art); row.add(info)

    const card = new Gtk.Box()
    card.get_style_context().add_class("Card")
    card.get_style_context().add_class("NPCard")
    card.add(row)
    card.show_all()
    return card
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
            {NowPlayingCard()}
        </box>
    </window>
}
