import { execAsync } from "astal"
import { WLOGOUT_CMD } from "../lib/paths"
import { ICON } from "../lib/icons"
import { dismissDrawers } from "../lib/drawers"

export default function Power() {
    return <button
        className="Power"
        tooltipText="Power menu (wlogout)"
        onClicked={() => {
            dismissDrawers()
            // Toggle, never stack. This spawned a new wlogout on every press,
            // and each one puts a surface on every output, so repeated presses
            // left several dialogs layered over each other. The click then
            // landed on whichever happened to be on top rather than the one
            // being looked at, and nothing happened -- leaving stale wlogout
            // processes behind, which is how this was found.
            execAsync(["sh", "-c", `pkill -x wlogout || exec ${WLOGOUT_CMD}`]).catch(() => {})
        }}>
        <label label={ICON.power} />
    </button>
}
