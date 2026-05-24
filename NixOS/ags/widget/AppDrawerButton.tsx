import { bindToggleButton } from "../lib/drawers"

// Bar button that toggles the App Drawer (Launchpad-style).
export default function AppDrawerButton() {
    return <button
        className="AppDrawerButton"
        tooltipText="Open App Drawer"
        setup={(self) => bindToggleButton(self, "app-drawer")}>
        <label label={"\u{f0a96}"} />
    </button>
}
