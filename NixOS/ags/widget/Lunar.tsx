import { Variable } from "astal"
import { LUNAR_CMD } from "../lib/paths"

type Payload = { text: string; tooltip: string; class: string }
const empty: Payload = { text: "", tooltip: "", class: "" }

const data = Variable<Payload>(empty).poll(60 * 60 * 1000, LUNAR_CMD, out => {
    try { return JSON.parse(out) as Payload } catch { return empty }
})

export default function Lunar() {
    return <box
        className={data().as(d => `Lunar ${d.class}`)}
        tooltipMarkup={data().as(d => d.tooltip)}>
        <label label={data().as(d => d.text)} useMarkup />
    </box>
}
