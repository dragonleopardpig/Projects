import { bind } from "astal"
import AstalHyprland from "gi://AstalHyprland"
import { dismissDrawers } from "../lib/drawers"

export default function Workspaces() {
    const hypr = AstalHyprland.get_default()

    return <box className="Workspaces">
        {bind(hypr, "workspaces").as(wss =>
            wss
                .filter(w => w.id > 0)  // hide special/scratch workspaces
                .sort((a, b) => a.id - b.id)
                .map(ws => (
                    <button
                        className={bind(hypr, "focusedWorkspace").as(fw =>
                            fw && fw.id === ws.id ? "focused" : ""
                        )}
                        onClicked={() => { dismissDrawers(); ws.focus() }}
                    >
                        <label label={String(ws.id)} />
                    </button>
                ))
        )}
    </box>
}
