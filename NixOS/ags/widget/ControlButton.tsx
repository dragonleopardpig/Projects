import { App } from "astal/gtk3"

// Bar button that toggles the Control Center popup.
export default function ControlButton() {
    return <button
        className="ControlButton"
        tooltipText="Open Control Center"
        onClicked={() => App.toggle_window("control-center")}>
        <label label={"\u{f0493}"} />
    </button>
}
