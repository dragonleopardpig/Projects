import { bind, execAsync } from "astal"
import AstalTray from "gi://AstalTray"
import GLib from "gi://GLib"
import ScrambleStatus from "./ScrambleStatus"

function runHelper(name: string, ...args: string[]) {
    void execAsync([`${GLib.get_home_dir()}/.local/bin/${name}`, ...args])
        .catch(error => console.error(`Scramble tray action failed: ${error}`))
}

export default function SysTray() {
    const tray = AstalTray.get_default()

    return <box className="SysTray">
        {bind(tray, "items").as(items => {
            const widgets = items.map(item => (
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
            ))
            if (!items.some(item => item.tooltipMarkup?.includes("Scramble Desktop"))) {
                widgets.push(<button
                    onClicked={() => runHelper("scramble-launch")}
                    onButtonPressEvent={(_self, event) => {
                        if (event.get_button()[1] !== 3) return false
                        runHelper("scramble-control", "status")
                        return true
                    }}>
                    <ScrambleStatus />
                </button>)
            }
            return widgets
        })}
    </box>
}
