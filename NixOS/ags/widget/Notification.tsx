import { Variable, subprocess, execAsync } from "astal"
import { SWAYNC_WATCH, SWAYNC_TOGGLE, SWAYNC_DND } from "../lib/paths"
import { ICON } from "../lib/icons"
import { dismissDrawers } from "../lib/drawers"

// swaync-client -swb streams a JSON line per change event in waybar's
// custom-module shape: {"text":"N","alt":"...","tooltip":"...","class":"..."}.
type State = { text?: string; alt?: string; tooltip?: string; class?: string }
const state = Variable<State>({})
subprocess(SWAYNC_WATCH, (line) => {
    try { state.set(JSON.parse(line)) } catch { /* swallow malformed lines */ }
})

function icon(s: State): string {
    const cls = s.class ?? ""
    if (cls.includes("dnd"))       return ICON.bell_dnd
    if (cls.includes("inhibited")) return ICON.bell_slash
    return ICON.bell
}

function count(s: State): string {
    const n = parseInt(s.text ?? "0")
    return isNaN(n) ? "0" : String(n)
}

export default function Notification() {
    return <button
        className="Notification"
        tooltipText={state().as(s => s.tooltip ?? "Notifications")}
        onClicked={() => { dismissDrawers(); execAsync(SWAYNC_TOGGLE).catch(() => {}) }}
        onButtonPressEvent={(_, ev) => {
            // 3 = right click
            if (ev.get_button()[1] === 3) execAsync(SWAYNC_DND).catch(() => {})
        }}>
        <label
            label={state().as(s => `${icon(s)} ${count(s)}`)}
        />
    </button>
}
