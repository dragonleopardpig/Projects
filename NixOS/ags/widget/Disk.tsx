import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

const pct = Variable(0).poll(10000, () => {
    const line = exec("df --output=pcent /").trim().split("\n")[1] ?? "0%"
    return parseInt(line.trim().replace("%", "")) || 0
})

export default function Disk() {
    return <box className="Disk">
        <label label={pct().as(p => `${ICON.disk}  ${p}%`)} />
    </box>
}
