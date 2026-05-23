import { Variable } from "astal"
import { App } from "astal/gtk3"

// `date` is cheap; polling once a second is fine.
const time = Variable("").poll(1000, "date +' %a %d %b  %H:%M'")

export default function Clock() {
    return <button
        className="Clock"
        tooltipText="Click for calendar"
        onClicked={() => App.toggle_window("calendar")}>
        <label label={time()} />
    </button>
}
