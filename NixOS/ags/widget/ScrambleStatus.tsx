import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

type Status = { state: string; message: string }

const status = Variable<Status>({ state: "pending", message: "Checking encrypted sync…" }).poll(15000, () => {
    try {
        const [state, message] = exec(["/home/thinky/.local/bin/scramble-sync-status", "--brief"]).trim().split("|", 2)
        return { state: state || "error", message: message || "Status unavailable" }
    } catch {
        return { state: "error", message: "Encrypted sync status unavailable" }
    }
})

export default function ScrambleStatus() {
    return <box
        className={status().as(s => `ScrambleStatus ${s.state}`)}
        tooltipText={status().as(s => s.message)}>
        <label label={status().as(s =>
            `Sync ${s.state === "ok" ? ICON.check : s.state === "busy" ? ICON.refresh : ICON.warning}`)} />
    </box>
}
