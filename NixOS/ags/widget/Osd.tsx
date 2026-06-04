import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, exec, timeout } from "astal"
import Wp from "gi://AstalWp"
import { ICON } from "../lib/icons"

// macOS-style OSD: a pill near the bottom-center that flashes the
// current volume / mute / brightness for ~1.5s after a change.

type OsdKind = "volume" | "mute" | "brightness"
const kind = Variable<OsdKind>("volume")
const value = Variable(0)

let hideTimer: { cancel(): void } | null = null
function flash(k: OsdKind, v: number) {
    kind.set(k)
    value.set(Math.max(0, Math.min(1, v)))
    App.get_window("osd")?.show()
    if (hideTimer) hideTimer.cancel()
    hideTimer = timeout(1500, () => {
        App.get_window("osd")?.hide()
        hideTimer = null
    })
}

// Don't flash on the initial reads at module load.
let primed = false
timeout(800, () => { primed = true })

const wp = Wp.get_default()
const speaker = wp?.audio?.defaultSpeaker
if (speaker) {
    const onAudio = () => {
        if (!primed) return
        flash(speaker.mute ? "mute" : "volume", speaker.volume)
    }
    speaker.connect("notify::volume", onAudio)
    speaker.connect("notify::mute", onAudio)
}

// Scope reads to the backlight class. Without `-c backlight`, brightnessctl
// falls back to the first LED device (capslock/numlock), so toggling Caps Lock
// would otherwise trip the brightness OSD. Machines with no backlight (desktops
// driving monitors over DDC) read nothing and never flash brightness.
function readBacklight(): number | null {
    try {
        const cur = parseInt(exec("brightnessctl -c backlight g"))
        const max = parseInt(exec("brightnessctl -c backlight m"))
        return max > 0 ? cur / max : null
    } catch { return null }
}
const hasBacklight = readBacklight() !== null
if (hasBacklight) {
    let lastBrightness = readBacklight()
    Variable(0).poll(200, () => {
        const cur = readBacklight()
        if (cur !== null && cur !== lastBrightness) {
            lastBrightness = cur
            if (primed) flash("brightness", cur)
        }
        return 0
    })
}

const BRIGHT_GLYPH = "\u{f0335}"  // nf-md-brightness_6

export default function Osd() {
    const monitor = App.get_monitors()[0]
    if (!monitor) return null
    const { BOTTOM } = Astal.WindowAnchor

    return <window
        name="osd"
        className="OsdWindow"
        gdkmonitor={monitor}
        application={App}
        visible={false}
        anchor={BOTTOM}
        marginBottom={140}
        layer={Astal.Layer.OVERLAY}>
        <box className="Osd" spacing={12}>
            <label className="OsdGlyph" label={bind(kind).as(k => {
                if (k === "mute") return ICON.mute
                if (k === "volume") return ICON.speaker
                return BRIGHT_GLYPH
            })} />
            <levelbar
                className="OsdBar"
                widthRequest={220}
                heightRequest={6}
                valign={Gtk.Align.CENTER}
                maxValue={1}
                value={bind(value)}
            />
            <label className="OsdValue" widthChars={4}
                   label={bind(value).as(v => `${Math.round(v * 100)}%`)} />
        </box>
    </window>
}
