import { bind, derive } from "astal"
import AstalBattery from "gi://AstalBattery"
import { ICON } from "../lib/icons"

// fa battery glyphs, empty → full, indexed by quarter.
const BAT_LEVELS = [ICON.bat_empty, ICON.bat_1q, ICON.bat_half, ICON.bat_3q, ICON.bat_full]

// While charging, show the bolt — the percentage text already conveys the
// level, so a dedicated charging glyph is the clearer signal.
function batGlyph(pct: number, charging: boolean): string {
    if (charging) return ICON.charging
    const i = Math.max(0, Math.min(4, Math.round((pct ?? 0) * 4)))
    return BAT_LEVELS[i]
}

export default function Battery() {
    const bat = AstalBattery.get_default()

    const text = derive(
        [bind(bat, "percentage"), bind(bat, "charging")],
        (p: number, c: boolean) => `${batGlyph(p, c)}  ${Math.round((p ?? 0) * 100)}%`
    )
    const cls = derive(
        [bind(bat, "percentage"), bind(bat, "charging")],
        (p: number, c: boolean) => c ? "BatLabel Charging" : ((p ?? 1) < 0.15 ? "BatLabel Low" : "BatLabel")
    )

    // Hide entirely on desktops without a battery.
    return <box
        className="Battery"
        visible={bind(bat, "isPresent")}>
        <label className={cls()} label={text()} />
    </box>
}
