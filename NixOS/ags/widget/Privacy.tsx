import { Variable, execAsync } from "astal"
import { ICON } from "../lib/icons"

// Counts active PipeWire capture streams. A Stream/Input/Audio node
// appears whenever an app is recording from a microphone; Stream/Input/Video
// appears when an app is reading from a camera through pipewire/libcamera
// (which is the default path on modern NixOS).
//
// pw-cli is cheap; 2s polling is comfortable and lets us catch quick
// camera handoffs (e.g. browser tab switching cameras).
const POLL_CMD = ["sh", "-c",
    "n=$(pw-cli ls Node 2>/dev/null); " +
    "echo \"$(printf '%s\\n' \"$n\" | grep -c 'Stream/Input/Audio') " +
    "$(printf '%s\\n' \"$n\" | grep -c 'Stream/Input/Video')\""
]

type Counts = { mic: number; cam: number }
const counts = Variable<Counts>({ mic: 0, cam: 0 })

async function refresh() {
    try {
        const out = await execAsync(POLL_CMD)
        const [m, c] = out.trim().split(/\s+/).map(s => parseInt(s) || 0)
        counts.set({ mic: m, cam: c })
    } catch {
        counts.set({ mic: 0, cam: 0 })
    }
}
refresh()
setInterval(refresh, 2000)

export default function Privacy() {
    return <box
        className="Privacy"
        visible={counts().as(c => c.mic + c.cam > 0)}
        spacing={4}>
        <label
            className="MicActive"
            visible={counts().as(c => c.mic > 0)}
            tooltipText={counts().as(c => `Microphone in use (${c.mic} stream${c.mic > 1 ? "s" : ""})`)}
            label={ICON.mic}
        />
        <label
            className="CamActive"
            visible={counts().as(c => c.cam > 0)}
            tooltipText={counts().as(c => `Camera in use (${c.cam} stream${c.cam > 1 ? "s" : ""})`)}
            label={ICON.camera}
        />
    </box>
}
