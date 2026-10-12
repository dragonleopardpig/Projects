import { bind } from "astal"
import AstalTray from "gi://AstalTray"
import ScrambleStatus from "./ScrambleStatus"

export default function SysTray() {
    const tray = AstalTray.get_default()

    return <box className="SysTray">
        {bind(tray, "items").as(items => items.map(item => (
            <menubutton
                tooltipMarkup={bind(item, "tooltipMarkup")}
                usePopover={false}
                actionGroup={bind(item, "actionGroup").as(g => ["dbusmenu", g])}
                menuModel={bind(item, "menuModel")}
                onButtonPressEvent={(self, event) => {
                    if (event.get_button()[1] !== 3) return false
                    const menu = self.get_popup()
                    if (!menu) return false
                    menu.popup_at_pointer(event)
                    return true
                }}
            >
                {bind(item, "tooltipMarkup").as(tooltip => tooltip?.includes("Scramble Desktop")
                    ? <ScrambleStatus />
                    : <icon gicon={bind(item, "gicon")} pixelSize={18} />)}
            </menubutton>
        )))}
    </box>
}
