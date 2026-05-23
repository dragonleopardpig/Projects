import { Variable, exec } from "astal"
import { ICON } from "../lib/icons"

const count = Variable(0).poll(10000, () => {
    const out = exec("systemctl --failed --no-legend --plain").trim()
    return out ? out.split("\n").length : 0
})

export default function SystemdFailed() {
    return <box
        className="SystemdFailed"
        visible={count().as(n => n > 0)}>
        <label label={count().as(n => `${ICON.warning}  ${n}`)} />
    </box>
}
