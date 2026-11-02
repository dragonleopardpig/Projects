import { Variable, execAsync } from "astal"
import GLib from "gi://GLib"
import { ICON } from "../lib/icons"
import { dismissDrawers } from "../lib/drawers"

// The tea cup holds two switches:
//
// LEFT CLICK -- idle handling. "Active" inverts the usual sense: when
// hypridle is RUNNING, the system will dim/lock idly. When hypridle is
// STOPPED, idle is inhibited. We toggle hypridle.service via systemctl --user.
//
// RIGHT CLICK -- always-on mode (modules/always-on.nix): the host kept up
// after office hours so the Claude sessions can be reached remotely -- the
// lid, the power key, the suspend keys and idle ignored, suspend refused.
// A deliberate shutdown or reboot into Windows works either way. ON shows a
// green infinity beside the cup.

const SVC = "hypridle.service"
const ALWAYS_ON = "/run/current-system/sw/bin/always-on"
// The live truth: the drop-in exists exactly while the mode is on.
const ALWAYS_ON_DROPIN = "/run/systemd/logind.conf.d/50-always-on.conf"

async function isIdleActive(): Promise<boolean> {
    try {
        const out = await execAsync(["systemctl", "--user", "is-active", SVC])
        return out.trim() === "active"
    } catch {
        // is-active returns non-zero when inactive — execAsync rejects on
        // non-zero exit, so swallow and treat as "not active".
        return false
    }
}

// Poll every 5s; cheap, and catches external start/stop (e.g. hyprland
// session restart, or `always-on on` typed in a terminal).
const idleRunning = Variable(true)
const alwaysOn = Variable(false)
async function refresh() {
    idleRunning.set(await isIdleActive())
    alwaysOn.set(GLib.file_test(ALWAYS_ON_DROPIN, GLib.FileTest.EXISTS))
}
refresh()
setInterval(refresh, 5000)

async function toggle() {
    dismissDrawers()
    const running = idleRunning.get()
    try {
        await execAsync(["systemctl", "--user", running ? "stop" : "start", SVC])
    } catch (e) {
        console.error("hypridle toggle failed:", e)
    }
    await refresh()
}

async function toggleAlwaysOn() {
    dismissDrawers()
    try {
        // (the script re-runs itself under sudo, which needs no password here)
        await execAsync([ALWAYS_ON, alwaysOn.get() ? "off" : "on"])
    } catch (e) {
        console.error("always-on toggle failed:", e)
    }
    await refresh()
}

function tooltip(idle: boolean, on: boolean): string {
    const first = idle
        ? "Idle/lock active — click to inhibit"
        : "Idle inhibited — click to resume idle handling"
    const second = on
        ? "Always-on ON — stays up for remote sessions; right-click for office mode"
        : "Always-on OFF — right-click to keep this host up after hours"
    return `${first}\n${second}`
}

export default function IdleInhibitor() {
    const state = Variable.derive([idleRunning, alwaysOn], (idle, on) => ({ idle, on }))
    return <button
        className={state().as(s => ["IdleInhibitor", s.idle ? "" : "Inhibited",
                                     s.on ? "AlwaysOn" : ""].filter(Boolean).join(" "))}
        tooltipText={state().as(s => tooltip(s.idle, s.on))}
        onClicked={toggle}
        onButtonPressEvent={(_self, event) => {
            if (event.get_button()[1] !== 3) return false
            toggleAlwaysOn()
            return true
        }}>
        <box>
            <label label={idleRunning().as(r => r ? ICON.sleep : ICON.caffeine)} />
            <label className="AlwaysOnBadge" label="∞" visible={alwaysOn()} />
        </box>
    </button>
}
