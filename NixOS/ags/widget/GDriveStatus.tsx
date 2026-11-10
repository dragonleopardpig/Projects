import { Variable, execAsync } from "astal"
import Gio from "gi://Gio"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"
import * as Paths from "../lib/paths"

type Folder = {
    local_path: string
    remote_path: string
    status: string
    last_sync?: string
    error?: string
}

type AccountInfo = {
    logged_in: boolean
    name?: string
    email?: string
    usage_str?: string
    limit_str?: string
    percent_str?: string
}

type Status = {
    state: string // "ok" | "busy" | "paused" | "error" | "stopped"
    label: string
    summary: string
    mount_point: string
    mounted: boolean
    rclone_alive: boolean
    rclone_mount_pid?: number
    service_state?: string
    service_substate?: string
    result?: string
    vfs_status?: string
    workers?: { pid: number; command: string }[]
    folders_count?: number
    folders?: Folder[]
    paused?: boolean
    interval_minutes?: number
    last_sync?: string
    updated?: number
    account?: AccountInfo
}

const helperDirectory = `${GLib.get_home_dir()}/.local/bin`
const gdriveIconPath = (Paths as any).GDRIVE_ICON || `${GLib.get_home_dir()}/.local/share/icons/hicolor/scalable/apps/gdrive.svg`
const gdriveErrorIconPath = (Paths as any).GDRIVE_ERROR_ICON || `${GLib.get_home_dir()}/.local/share/icons/hicolor/scalable/apps/gdrive-error.svg`

const defaultGDriveStatus: Status = {
    state: "ok",
    label: "Google Drive",
    summary: "Connected",
    mount_point: `${GLib.get_home_dir()}/Google Drive`,
    mounted: true,
    rclone_alive: true,
}

export async function fetchGDriveStatus(): Promise<Status> {
    try {
        const output = (await execAsync([`${helperDirectory}/gdrive-sync-status`, "--json"])).trim()
        if (output) {
            const status = JSON.parse(output) as Status
            if (status.state && status.label && status.summary) return status
        }
    } catch {}
    return defaultGDriveStatus
}

// Initial fetch in background
void fetchGDriveStatus()

const gdriveNormalIcon = Gio.FileIcon.new(Gio.File.new_for_path(gdriveIconPath))
const gdriveErrorIcon = Gio.FileIcon.new(Gio.File.new_for_path(gdriveErrorIconPath))

function tooltip(status: Status): string {
    const lines = [`Google Drive — ${status.label}`, status.summary]

    if (status.account && status.account.logged_in) {
        const name = status.account.name ? `${status.account.name} ` : ""
        lines.push(`👤 Account: ${name}(${status.account.email})`)
        if (status.account.usage_str && status.account.limit_str) {
            lines.push(`📊 Quota: ${status.account.usage_str} / ${status.account.limit_str} used (${status.account.percent_str})`)
        }
    }

    if (status.rclone_alive) {
        lines.push(`✔ Rclone FUSE mount: alive (PID ${status.rclone_mount_pid})`)
        if (status.vfs_status) {
            const vfs = status.vfs_status.replace(/^\[.*?\]\s*/, "")
            lines.push(`VFS Cache: ${vfs}`)
        }
    } else {
        lines.push("⚠ CRITICAL: Rclone FUSE mount is DEAD!")
        lines.push(`Drive is unmounted (${status.mount_point})`)
        if (status.service_state) {
            lines.push(`Service: ${status.service_state} (${status.service_substate || "dead"}), result: ${status.result || "failed"}`)
        }
    }

    if (status.workers && status.workers.length > 0) {
        lines.push(`Rclone transfer active: PID ${status.workers.map(w => w.pid).join(", ")}`)
    } else if (status.rclone_alive) {
        lines.push(status.paused ? "Auto-sync is paused" : `Auto-sync: checks every ${status.interval_minutes || 10} minutes`)
    }

    if (status.folders && status.folders.length > 0) {
        lines.push(`Synced folders (${status.folders.length}):`)
        for (const f of status.folders.slice(0, 4)) {
            const name = f.local_path.split("/").filter(Boolean).pop() || f.local_path
            lines.push(`  • ${name}: ${f.status} (last: ${f.last_sync || "never"})`)
            if (f.error) lines.push(`    Error: ${f.error}`)
        }
        if (status.folders.length > 4) {
            lines.push(`  ...and ${status.folders.length - 4} more`)
        }
    } else {
        lines.push("No synced folders configured")
    }

    if (status.last_sync) {
        lines.push(`Last successful sync: ${status.last_sync}`)
    }

    lines.push("Live process checks every two seconds. Right-click for options.")
    return lines.join("\n")
}

export default function GDriveStatus() {
    const status = Variable(defaultGDriveStatus).poll(5000, fetchGDriveStatus)

    return <box
        className={status().as(currentStatus => `GDriveStatus ${currentStatus.state}`)}
        tooltipText={status().as(tooltip)}
        setup={self => {
            const unsubscribe = status.subscribe(() => self.trigger_tooltip_query())
            self.connect("destroy", unsubscribe)
        }}
        onDestroy={() => status.drop()}>
        <overlay halign={Gtk.Align.CENTER} valign={Gtk.Align.CENTER}>
            <icon
                className="gdrive-icon"
                pixelSize={18}
                gicon={status().as(s => (!s.rclone_alive || s.state === "error") ? gdriveErrorIcon : gdriveNormalIcon)}
            />
            <box className="health" halign={Gtk.Align.END} valign={Gtk.Align.END} />
        </overlay>
    </box>
}
