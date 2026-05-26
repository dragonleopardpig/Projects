import GLib from "gi://GLib"
import { bindToggleButton } from "../lib/drawers"

// Bar button that toggles the App Drawer (Launchpad-style).
// Loads the bundled NixOS snowflake PNG from ~/.config/ags/assets/
// (copied there at home-manager build time from NixOS/ags/assets/).
const ICON_PATH = `${GLib.get_user_config_dir()}/ags/assets/app-drawer.png`

export default function AppDrawerButton() {
    return <button
        className="AppDrawerButton"
        tooltipText="Open App Drawer"
        setup={(self) => bindToggleButton(self, "app-drawer")}>
        <icon icon={ICON_PATH} pixelSize={20} />
    </button>
}
