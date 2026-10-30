import { Variable, exec } from "astal"
import Gio from "gi://Gio"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"
import { SCRAMBLE_ICON } from "../lib/paths"

type Status = {
    state: string
    label: string
    summary: string
    workers?: { pid: number }[]
    progress?: string
    speed?: string
    speed_sampled?: number
    speed_scope?: string
    last_success?: number
    connection?: boolean
    connection_checked?: number
}
const helperDirectory = `${GLib.get_home_dir()}/.local/bin`

function readStatus(): Status {
    try {
        const status = JSON.parse(exec([`${helperDirectory}/scramble-sync-status`, "--json"])) as Status
        if (!status.state || !status.label || !status.summary) throw new Error("Incomplete status")
        return status
    } catch {
        return { state: "error", label: "Monitor error", summary: "Scramble status is unavailable; relaunch Scramble Desktop" }
    }
}
const scrambleIcon = Gio.FileIcon.new(Gio.File.new_for_path(SCRAMBLE_ICON))

function tooltip(status: Status): string {
    const lines = [`Scramble — ${status.label}`, status.summary]
    if (status.workers?.length) lines.push(`Rclone transfer alive: PID ${status.workers.map(worker => worker.pid).join(", ")}`)
    else if (status.state === "ok") lines.push("Rclone is idle; automatic sync checks every five minutes")
    else lines.push("No rclone transfer process running")
    if (status.speed) {
        const age = status.speed_sampled ? Math.max(0, Math.floor(Date.now() / 1000 - status.speed_sampled)) : 0
        lines.push(`Sync speed: ${status.speed}${status.speed_sampled ? ` (${age}s ago${status.speed_scope === "recent" ? ", recent transfer" : ""})` : ""}`)
    } else if (status.workers?.length) lines.push("Sync speed: waiting for the next rclone sample")
    if (status.progress) lines.push(`Current transfer: ${status.progress}`)
    if (status.connection_checked) {
        const age = Math.max(0, Math.floor(Date.now() / 1000 - status.connection_checked))
        lines.push(`Encrypted cloud check ${status.connection ? "passed" : "failed"} ${age}s ago`)
    }
    if (status.last_success) lines.push(`Last successful sync: ${new Date(status.last_success * 1000).toLocaleString()}`)
    lines.push("Live process checks every five seconds. Right-click for sync status and controls.")
    return lines.join("\n")
}

export default function ScrambleStatus() {
    const status = Variable(readStatus()).poll(2000, readStatus)

    return <box
        className={status().as(currentStatus => `ScrambleStatus ${currentStatus.state}`)}
        tooltipText={status().as(tooltip)}
        setup={self => {
            const unsubscribe = status.subscribe(() => self.trigger_tooltip_query())
            self.connect("destroy", unsubscribe)
        }}
        onDestroy={() => status.drop()}>
        <overlay halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
            <icon className="scramble-icon" gicon={scrambleIcon} />
            <box className="health" halign={Gtk.Align.END} valign={Gtk.Align.END} />
        </overlay>
    </box>
}
