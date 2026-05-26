import { bindToggleButton } from "../lib/drawers"

// Bar button that toggles the App Drawer (Launchpad-style).
// Uses the NixOS snowflake glyph from CaskaydiaCove Nerd Font
// (nf-linux-nixos, U+F313). Styled bigger + with a text-shadow halo
// in style.scss so it reads as bright as the bar's other glyphs.
export default function AppDrawerButton() {
    return <button
        className="AppDrawerButton"
        tooltipText="Open App Drawer"
        setup={(self) => bindToggleButton(self, "app-drawer")}>
        <label label={"\u{f313}"} />
    </button>
}
