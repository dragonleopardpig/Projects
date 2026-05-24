import { Variable, execAsync } from "astal"
import { ICON } from "../lib/icons"

// "Active" inverts the usual sense: when hypridle is RUNNING, the system
// will sleep/dim/lock idly. When hypridle is STOPPED, idle is inhibited.
// We toggle hypridle.service via systemctl --user.

const SVC = "hypridle.service"

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
// session restart).
const idleRunning = Variable(true)
async function refresh() { idleRunning.set(await isIdleActive()) }
refresh()
setInterval(refresh, 5000)

async function toggle() {
    const running = idleRunning.get()
    try {
        await execAsync(["systemctl", "--user", running ? "stop" : "start", SVC])
    } catch (e) {
        console.error("hypridle toggle failed:", e)
    }
    await refresh()
}

export default function IdleInhibitor() {
    return <button
        className={idleRunning().as(r => r ? "IdleInhibitor" : "IdleInhibitor Inhibited")}
        tooltipText={idleRunning().as(r => r
            ? "Idle/lock active — click to inhibit"
            : "Idle inhibited — click to resume idle handling")}
        onClicked={toggle}>
        <label label={idleRunning().as(r => r ? ICON.sleep : ICON.caffeine)} />
    </button>
}
