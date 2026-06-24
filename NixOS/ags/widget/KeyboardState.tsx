import { Variable, exec, derive } from "astal"

// Read led brightness directly from sysfs — works on any wayland session.
function readLed(pattern: string): boolean {
    try {
        const out = exec(["sh", "-c", `cat /sys/class/leds/input*::${pattern}/brightness 2>/dev/null | head -1`])
        return parseInt(out.trim()) > 0
    } catch { return false }
}

const caps = Variable(false).poll(500, () => readLed("capslock"))
const num  = Variable(false).poll(500, () => readLed("numlock"))

// Collapse the box when neither lock is on; an always-visible empty box still
// claims its `spacing` slot in the bar, leaving a gap (as the Privacy widget does).
const anyLock = derive([caps(), num()], (c, n) => c || n)

export default function KeyboardState() {
    return <box
        className="KeyboardState"
        visible={anyLock()}>
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
