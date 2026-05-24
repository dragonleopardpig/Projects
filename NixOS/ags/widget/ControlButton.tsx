import { bindToggleButton } from "../lib/drawers"

// Bar button that toggles the Control Center popup.
export default function ControlButton() {
    return <button
        className="ControlButton"
        tooltipText="Open Control Center"
        setup={(self) => bindToggleButton(self, "control-center")}>
        <label label={"\u{f0493}"} />
    </button>
}
