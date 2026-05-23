import { Variable } from "astal"
import { HOLIDAY_CMD } from "../lib/paths"

type Payload = { text: string; tooltip: string; class: string }
const empty: Payload = { text: "", tooltip: "", class: "" }

const data = Variable<Payload>(empty).poll(60 * 60 * 1000, HOLIDAY_CMD, out => {
    try { return JSON.parse(out) as Payload } catch { return empty }
})

export default function Holiday() {
    return <box
        className={data().as(d => `Holiday ${d.class}`)}
        tooltipMarkup={data().as(d => d.tooltip)}>
        <label label={data().as(d => d.text)} useMarkup />
    </box>
}
