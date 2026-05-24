import { execAsync } from "astal"
import { WLOGOUT_CMD } from "../lib/paths"
import { ICON } from "../lib/icons"
import { dismissDrawers } from "../lib/drawers"

export default function Power() {
    return <button
        className="Power"
        tooltipText="Power menu (wlogout)"
        onClicked={() => { dismissDrawers(); execAsync(WLOGOUT_CMD).catch(() => {}) }}>
        <label label={ICON.power} />
    </button>
}
