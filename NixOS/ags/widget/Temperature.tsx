import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

// thermal_zone0 is usually CPU on consumer hardware; refine per-host if wrong.
const c = Variable(0).poll(2000, () => {
    try {
        return Math.round(parseInt(exec("cat /sys/class/thermal/thermal_zone0/temp")) / 1000)
    } catch { return 0 }
})

export default function Temperature() {
    return <box className="Temperature">
        <label label={c().as(t => `${ICON.temp}  ${t}°C`)} />
    </box>
}
