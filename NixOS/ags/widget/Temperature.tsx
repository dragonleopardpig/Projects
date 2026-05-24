import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

// Some boards expose a virtual ACPI zone (INT3400) at zone0 that idles at 20°C;
// pick the first zone whose type matches a real CPU sensor.
const PREFERRED = ["x86_pkg_temp", "TCPU", "k10temp", "cpu_thermal"]

function pickCpuZone(): string {
    try {
        const zones = exec("sh -c 'for z in /sys/class/thermal/thermal_zone*; do echo \"$z $(cat $z/type)\"; done'").split("\n")
        for (const pref of PREFERRED) {
            const hit = zones.find(l => l.endsWith(" " + pref))
            if (hit) return hit.split(" ")[0]
        }
    } catch { /* fall through */ }
    return "/sys/class/thermal/thermal_zone0"
}

const ZONE = pickCpuZone()

const c = Variable(0).poll(2000, () => {
    try {
        return Math.round(parseInt(exec(`cat ${ZONE}/temp`)) / 1000)
    } catch { return 0 }
})

export default function Temperature() {
    return <box className="Temperature">
        <label label={c().as(t => `${ICON.temp}  ${t}°C`)} />
    </box>
}
