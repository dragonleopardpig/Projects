import { Variable } from "astal"
import { WEATHER_CMD } from "../lib/paths"
import { bindToggleButton } from "../lib/drawers"

// wttr.in updates slowly; 30 min is plenty for the bar summary.
const weather = Variable("").poll(30 * 60 * 1000, WEATHER_CMD)

export default function Weather() {
    return <button
        className="Weather"
        tooltipText="Click for forecast"
        setup={(self) => bindToggleButton(self, "weather")}>
        <label label={weather()} />
    </button>
}
