import { Variable, exec, execAsync } from "astal"
import Gio from "gi://Gio"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"
import { SCRAMBLE_ICON } from "../lib/paths"

type Status = { state: string; message: string }
const helperDirectory = `${GLib.get_home_dir()}/.local/bin`

const status = Variable<Status>({ state: "pending", message: "Checking encrypted sync…" }).poll(15000, () => {
    try {
        const [state, message] = exec([`${helperDirectory}/scramble-sync-status`, "--brief"]).trim().split("|", 2)
        return { state: state || "error", message: message || "Status unavailable" }
    } catch {
        return { state: "error", message: "Encrypted sync status unavailable" }
    }
})
const scrambleIcon = Gio.FileIcon.new(Gio.File.new_for_path(SCRAMBLE_ICON))

function openDesktop() {
    Gio.DesktopAppInfo.new("scramble-desktop.desktop")?.launch([], null)
}

function contextMenu() {
    const menu = new Gtk.Menu()
    const actions: [string, string | (() => void)][] = [
        ["Open Scramble Desktop", openDesktop],
        ["Open Public Sync Folder", "open-public"],
        ["Open Private Sync Folder", "open-private"],
        ["Browse Cloud Files", "open-cloud"],
        ["Sync Now", "sync-now"],
        ["Sync Status", "status"],
        ["Quit Scramble", "quit"],
    ]
    for (const [label, action] of actions) {
        if (label === "Sync Now" || label === "Quit Scramble") menu.append(new Gtk.SeparatorMenuItem())
        const item = new Gtk.MenuItem({ label })
        item.connect("activate", () => {
            if (typeof action === "function") action()
            else execAsync([`${helperDirectory}/scramble-control`, action]).catch(console.error)
        })
        menu.append(item)
    }
    menu.show_all()
    return menu
}

export default function ScrambleStatus() {
    return <button
        className={status().as(currentStatus => `ScrambleStatus ${currentStatus.state}`)}
        tooltipText={status().as(currentStatus => `Scramble Cloud — ${currentStatus.message}\nClick to open; right-click for folders, sync, status, and quit`)}
        onClicked={openDesktop}
        onButtonPressEvent={(_, event) => {
            if (event.get_button()[1] !== 3) return false
            contextMenu().popup_at_pointer(event)
            return true
        }}>
        <box>
            <icon gicon={scrambleIcon} pixelSize={20} />
            <label className="health" label="●" />
        </box>
    </button>
}
