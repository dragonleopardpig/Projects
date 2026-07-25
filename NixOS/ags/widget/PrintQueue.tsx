import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"
import { bindToggleButton } from "../lib/drawers"

// Windows-style print-queue indicator: only visible while jobs are pending,
// hidden when the queue is empty. `lpstat -o` lists not-completed jobs (one
// per line) — cheap and local, so a 5s poll is fine. Click toggles the
// Control Center, where the Printers & Scanners card shows detail.
const jobs = Variable(0).poll(5000, () => {
    try {
        const n = parseInt(exec(["sh", "-c", "lpstat -o 2>/dev/null | wc -l"]).trim())
        return isNaN(n) ? 0 : n
    } catch { return 0 }
})

export default function PrintQueue() {
    return <button
        className="PrintQueue"
        visible={jobs().as(n => n > 0)}
        tooltipText={jobs().as(n => `${n} print job${n === 1 ? "" : "s"} in queue — open Control Center`)}
        setup={(self) => bindToggleButton(self, "control-center")}>
        <label label={jobs().as(n => `${ICON.printer}  ${n}`)} />
    </button>
}
