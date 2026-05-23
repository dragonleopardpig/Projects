import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

// Compute % busy as a delta over polling interval, since /proc/stat is cumulative.
let prevTotal = 0, prevIdle = 0
const pct = Variable(0).poll(2000, () => {
    const parts = exec("head -1 /proc/stat").split(/\s+/).slice(1).map(Number)
    const idle = parts[3] + parts[4]
    const total = parts.reduce((a, b) => a + b, 0)
    const dTotal = total - prevTotal
    const dIdle = idle - prevIdle
    prevTotal = total; prevIdle = idle
    if (dTotal <= 0) return 0
    return Math.round((1 - dIdle / dTotal) * 100)
})

export default function Cpu() {
    return <box className="Cpu">
        <label label={pct().as(p => `${ICON.cpu}  ${p}%`)} />
    </box>
}
