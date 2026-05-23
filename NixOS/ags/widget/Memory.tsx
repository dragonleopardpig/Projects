import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

const pct = Variable(0).poll(2000, () => {
    const [tot, avail] = exec("awk '/MemTotal|MemAvailable/ {print $2}' /proc/meminfo")
        .trim().split("\n").map(Number)
    if (!tot) return 0
    return Math.round((1 - avail / tot) * 100)
})

export default function Memory() {
    return <box className="Memory">
        <label label={pct().as(p => `${ICON.memory}  ${p}%`)} />
    </box>
}
