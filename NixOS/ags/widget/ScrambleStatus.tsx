import { Variable, exec } from "astal"
import Gio from "gi://Gio"
import { SCRAMBLE_ICON } from "../lib/paths"

type Status = { state: string; message: string }

const status = Variable<Status>({ state: "pending", message: "Checking encrypted sync…" }).poll(15000, () => {
    try {
        const [state, message] = exec(["/home/thinky/.local/bin/scramble-sync-status", "--brief"]).trim().split("|", 2)
        return { state: state || "error", message: message || "Status unavailable" }
    } catch {
        return { state: "error", message: "Encrypted sync status unavailable" }
    }
})
const scrambleIcon = Gio.FileIcon.new(Gio.File.new_for_path(SCRAMBLE_ICON))

export default function ScrambleStatus() {
    return <box
        className={status().as(s => `ScrambleStatus ${s.state}`)}
        tooltipText={status().as(s => `Scramble Cloud — ${s.message}`)}>
        <icon gicon={scrambleIcon} pixelSize={20} />
        <label className="health" label="●" />
    </box>
}
