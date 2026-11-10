import { Variable, execAsync, bind } from "astal"
import AstalTray from "gi://AstalTray"
import Gio from "gi://Gio"
import GObject from "gi://GObject"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"

export type FileLuWorker = {
    pid: number
    filename?: string
    local_path?: string
    remote_dest?: string
    size?: string
}

export type FileLuFolder = {
    local_path: string
    remote_path: string
    is_running: boolean
    trigger_mode?: string
    last_result?: string
    last_message?: string
}

export type FileLuAccount = {
    username: string
    logged_in: boolean
}

export type FileLuStatusData = {
    state: string // "syncing" | "ok" | "idle" | "paused" | "offline" | "not_signed_in"
    label: string
    dbus_title?: string
    dbus_desc?: string
    workers?: FileLuWorker[]
    account?: FileLuAccount
    folders?: FileLuFolder[]
    mount_point: string
    mounted: boolean
    rclone_alive: boolean
    rclone_mount_pid?: number
    updated?: number
}

const helperDirectory = `${GLib.get_home_dir()}/.local/bin`
const fileluFallbackIcon = Gio.FileIcon.new(Gio.File.new_for_path(`${GLib.get_home_dir()}/.local/opt/filelusync/app.png`))

const defaultFileLuStatus: FileLuStatusData = {
    state: "idle",
    label: "FileLuSync",
    mount_point: `${GLib.get_home_dir()}/FileLu`,
    mounted: false,
    rclone_alive: false,
}

export const fileluSharedStatus = Variable<FileLuStatusData>(defaultFileLuStatus)

export async function fetchFileLuStatus(): Promise<FileLuStatusData> {
    try {
        const output = (await execAsync([`${helperDirectory}/filelu-sync-status`, "--json"])).trim()
        if (output) {
            const parsed = JSON.parse(output) as FileLuStatusData
            if (parsed.state && parsed.label) {
                fileluSharedStatus.set(parsed)
                return parsed
            }
        }
    } catch (_) {}
    return defaultFileLuStatus
}

// Initial fetch in background
void fetchFileLuStatus()

export function readFileLuStatus(): FileLuStatusData {
    return fileluSharedStatus.get()
}

export function fileluTooltip(status: FileLuStatusData): string {
    const lines = [`FileLuSync — ${status.label}`]

    if (status.account?.username) {
        lines.push(`👤 Account: ${status.account.username}`)
    } else {
        lines.push("👤 Account: Not signed in")
    }

    if (status.workers && status.workers.length > 0) {
        lines.push(`📁 Active transfers (${status.workers.length}):`)
        for (const w of status.workers.slice(0, 3)) {
            const sz = w.size ? ` (${w.size})` : ""
            lines.push(`  • ${w.filename || "file"}${sz}`)
        }
        if (status.workers.length > 3) {
            lines.push(`  ...and ${status.workers.length - 3} more`)
        }
    } else if (status.state === "syncing") {
        lines.push("📁 Active transfer in progress")
    }

    if (status.folders && status.folders.length > 0) {
        for (const f of status.folders) {
            const localName = f.local_path.split("/").filter(Boolean).pop() || f.local_path
            lines.push(`🔄 Synced folder: ${localName} ➔ ${f.remote_path} (${f.trigger_mode || "live"})`)
        }
    }

    if (status.rclone_alive) {
        lines.push(`✔ Rclone FUSE mount: alive (PID ${status.rclone_mount_pid} at ${status.mount_point})`)
    } else if (status.mounted) {
        lines.push(`✔ FUSE mounted at ${status.mount_point}`)
    }

    lines.push("Live status checks every two seconds. Left-click to open, right-click for options.")
    return lines.join("\n")
}

export default function FileLuStatus({ item }: { item?: AstalTray.TrayItem }) {
    const status = Variable(defaultFileLuStatus).poll(3000, fetchFileLuStatus)

    return (
        <box
            className={status().as(currentStatus => `FileLuStatus ${currentStatus.state}`)}
            tooltipText={status().as(fileluTooltip)}
            setup={self => {
                const unsubscribe = status.subscribe(() => {
                    self.trigger_tooltip_query()
                    try {
                        self.get_parent()?.trigger_tooltip_query()
                    } catch (_) {}
                })
                let notifyId = 0
                if (item) {
                    notifyId = item.connect("notify::tooltip", () => {
                        void fetchFileLuStatus().then(s => status.set(s))
                    })
                }
                self.connect("destroy", () => {
                    unsubscribe()
                    if (item && notifyId && GObject.signal_handler_is_connected(item, notifyId)) {
                        item.disconnect(notifyId)
                    }
                })
            }}
            onDestroy={() => status.drop()}
        >
            {item ? (
                <icon gicon={bind(item, "gicon").as(g => g || fileluFallbackIcon)} pixelSize={18} />
            ) : (
                <icon gicon={fileluFallbackIcon} pixelSize={18} />
            )}
        </box>
    )
}
