import { Variable, execAsync } from "astal"
import GLib from "gi://GLib"
import { WEATHER_CMD } from "../lib/paths"
import { bindToggleButton } from "../lib/drawers"

const CACHE_FILE = `${GLib.get_user_cache_dir()}/ags-weather-bar.txt`

function readCached(): string {
    try {
        if (GLib.file_test(CACHE_FILE, GLib.FileTest.EXISTS)) {
            const [ok, bytes] = GLib.file_get_contents(CACHE_FILE)
            if (ok) {
                const text = new TextDecoder().decode(bytes).trim()
                if (text) return text
            }
        }
    } catch (_) {}
    return "⛅ …"
}

export const weather = Variable(readCached())

async function fetchWeather() {
    try {
        const out = (await execAsync(WEATHER_CMD)).trim()
        if (out) {
            weather.set(out)
            try {
                GLib.file_set_contents(CACHE_FILE, out)
            } catch (_) {}
        }
    } catch (e) {
        console.error("weather fetch error:", e)
    }
}

// Fetch immediately on startup so the weather icon/temp is never delayed 30 minutes
void fetchWeather()
// Refresh periodically
setInterval(fetchWeather, 15 * 60 * 1000)

export default function Weather() {
    return <button
        className="Weather"
        tooltipText="Click for forecast"
        setup={(self) => bindToggleButton(self, "weather")}>
        <label label={weather()} />
    </button>
}
