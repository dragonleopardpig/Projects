import { Variable } from "astal"
import { WEATHER_CMD } from "../lib/paths"

// wttr.in updates slowly; 30 min is plenty.
const weather = Variable("").poll(30 * 60 * 1000, WEATHER_CMD)

export default function Weather() {
    return <box className="Weather">
        <label label={weather()} />
    </box>
}
