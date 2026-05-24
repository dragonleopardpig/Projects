import { Variable, subprocess, execAsync } from "astal"
import { SWAYNC_WATCH, SWAYNC_TOGGLE, SWAYNC_DND } from "../lib/paths"
import { ICON } from "../lib/icons"
import { dismissDrawers } from "../lib/drawers"

// swaync-client -swb streams a JSON line per change event; we sit on the
// pipe rather than polling.
type State = { count?: number; dnd?: boolean; cc_open?: boolean; inhibited?: boolean }
const state = Variable<State>({})
subprocess(SWAYNC_WATCH, (line) => {
    try { state.set(JSON.parse(line)) } catch { /* swallow malformed lines */ }
})

function icon(s: State): string {
    if (s.dnd) return ICON.bell_dnd
    if (s.inhibited) return ICON.bell_slash
    return ICON.bell
}

export default function Notification() {
    return <button
        className="Notification"
        tooltipText="Click: open center  ·  Right-click: toggle DND"
        onClicked={() => { dismissDrawers(); execAsync(SWAYNC_TOGGLE).catch(() => {}) }}
        onButtonPressEvent={(_, ev) => {
            // 3 = right click
            if (ev.get_button()[1] === 3) execAsync(SWAYNC_DND).catch(() => {})
        }}>
        <label
            label={state().as(s => `${icon(s)} ${s.count ?? 0}`)}
        />
    </button>
}
