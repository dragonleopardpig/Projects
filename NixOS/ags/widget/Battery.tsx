import { bind } from "astal"
import AstalBattery from "gi://AstalBattery"
import { ICON } from "../lib/icons"

export default function Battery() {
    const bat = AstalBattery.get_default()

    // Hide entirely on desktops without a battery.
    return <box
        className="Battery"
        visible={bind(bat, "isPresent")}>
        <label
            label={bind(bat, "percentage").as(p =>
                `${ICON.battery}  ${Math.round((p ?? 0) * 100)}%`
            )}
        />
    </box>
}
