import { bind } from "astal"
import AstalTray from "gi://AstalTray"

export default function SysTray() {
    const tray = AstalTray.get_default()

    return <box className="SysTray">
        {bind(tray, "items").as(items => items.map(item => (
            <menubutton
                tooltipMarkup={bind(item, "tooltipMarkup")}
                usePopover={false}
                actionGroup={bind(item, "actionGroup").as(g => ["dbusmenu", g])}
                menuModel={bind(item, "menuModel")}
            >
                <icon gicon={bind(item, "gicon")} pixelSize={18} />
            </menubutton>
        )))}
    </box>
}
