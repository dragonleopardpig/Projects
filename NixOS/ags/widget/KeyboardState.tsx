import { Variable, exec } from "astal"

// Read led brightness directly from sysfs — works on any wayland session.
function readLed(pattern: string): boolean {
    try {
        const out = exec(["sh", "-c", `cat /sys/class/leds/input*::${pattern}/brightness 2>/dev/null | head -1`])
        return parseInt(out.trim()) > 0
    } catch { return false }
}

const caps = Variable(false).poll(500, () => readLed("capslock"))
const num  = Variable(false).poll(500, () => readLed("numlock"))

export default function KeyboardState() {
    return <box className="KeyboardState">
        <label
            className={caps().as(on => on ? "led on" : "led off")}
            label={caps().as(on => on ? " A" : "")}
        />
        <label
            className={num().as(on => on ? "led on" : "led off")}
            label={num().as(on => on ? " 1" : "")}
        />
    </box>
}
