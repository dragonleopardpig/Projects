import { App } from "astal/gtk3"

// Bar button that toggles the App Drawer (Launchpad-style).
export default function AppDrawerButton() {
    return <button
        className="AppDrawerButton"
        tooltipText="Open App Drawer"
        onClicked={() => App.toggle_window("app-drawer")}>
        <label label={"\u{f0a96}"} />
    </button>
}
