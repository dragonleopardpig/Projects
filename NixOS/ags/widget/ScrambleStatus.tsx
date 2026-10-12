import { Variable, exec } from "astal"
import Gio from "gi://Gio"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"
import { SCRAMBLE_ICON } from "../lib/paths"

type Status = { state: string; message: string }
const helperDirectory = `${GLib.get_home_dir()}/.local/bin`

function readStatus(): Status {
    try {
        const [state, message] = exec([`${helperDirectory}/scramble-sync-status`, "--brief"]).trim().split("|", 2)
        return { state: state || "error", message: message || "Status unavailable" }
    } catch {
        return { state: "error", message: "Encrypted sync status unavailable" }
    }
}
const scrambleIcon = Gio.FileIcon.new(Gio.File.new_for_path(SCRAMBLE_ICON))

export default function ScrambleStatus() {
    const status = Variable(readStatus()).poll(15000, readStatus)

    return <overlay
        halign={Gtk.Align.CENTER}
        valign={Gtk.Align.CENTER}
        className={status().as(currentStatus => `ScrambleStatus ${currentStatus.state}`)}
        tooltipText={status().as(currentStatus => `Scramble Cloud — ${currentStatus.message}\nRight-click for folders, sync, status, and quit`)}
        onDestroy={() => status.drop()}>
        <icon gicon={scrambleIcon} pixelSize={20} />
        <label className="health" label="●" halign={Gtk.Align.END} valign={Gtk.Align.END} />
    </overlay>
}
