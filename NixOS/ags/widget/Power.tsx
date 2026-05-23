import { execAsync } from "astal"
import { WLOGOUT_CMD } from "../lib/paths"
import { ICON } from "../lib/icons"

export default function Power() {
    return <button
        className="Power"
        tooltipText="Power menu (wlogout)"
        onClicked={() => execAsync(WLOGOUT_CMD).catch(() => {})}>
        <label label={ICON.power} />
    </button>
}
