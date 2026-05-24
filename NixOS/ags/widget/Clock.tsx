import { Variable } from "astal"
import { bindToggleButton } from "../lib/drawers"

// `date` is cheap; polling once a second is fine.
const time = Variable("").poll(1000, "date +' %a %d %b  %H:%M'")

export default function Clock() {
    return <button
        className="Clock"
        tooltipText="Click for calendar"
        setup={(self) => bindToggleButton(self, "calendar")}>
        <label label={time()} />
    </button>
}
