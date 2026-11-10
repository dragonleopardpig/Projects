import { bind, execAsync } from "astal"
import AstalTray from "gi://AstalTray"
import Gio from "gi://Gio"
import GLib from "gi://GLib"
import Gtk from "gi://Gtk?version=3.0"
import ScrambleStatus from "./ScrambleStatus"
import GDriveStatus from "./GDriveStatus"
import ProtonDriveStatus from "./ProtonDriveStatus"
import FileLuStatus, { readFileLuStatus } from "./FileLuStatus"

function getFallbackTrayGicon(item: AstalTray.TrayItem) {
    if (item.gicon) return item.gicon
    if (item.iconName) {
        if (item.iconName.startsWith("/")) {
            return Gio.FileIcon.new(Gio.File.new_for_path(item.iconName))
        }
        return Gio.ThemedIcon.new(item.iconName)
    }
    if (item.id?.includes("chrome")) {
        return Gio.ThemedIcon.new("google-chrome")
    }
    return Gio.ThemedIcon.new("application-default-icon")
}

function runHelper(name: string, ...args: string[]) {
    void execAsync([`${GLib.get_home_dir()}/.local/bin/${name}`, ...args])
        .catch(error => console.error(`Tray action failed: ${error}`))
}

function openFileLuMenu(item: AstalTray.TrayItem) {
    const menu = new Gtk.Menu()

    // Status header (live status from helper or tooltip or title)
    const liveStatus = readFileLuStatus()
    const rawStatus = liveStatus.label || item.tooltipMarkup || item.title || "FileLuSync"
    const statusText = rawStatus.replace(/<[^>]*>/g, "").trim()
    const header = new Gtk.MenuItem({ label: `● ${statusText}` })
    header.set_sensitive(false)
    menu.append(header)
    menu.append(new Gtk.SeparatorMenuItem())

    // 1. Open FileLuSync
    const openItem = new Gtk.MenuItem({ label: "Open FileLuSync" })
    openItem.connect("activate", () => {
        runHelper("filelu-toggle")
    })
    menu.append(openItem)

    // 2. Pause / Resume syncing
    const isPaused = statusText.toLowerCase().includes("paused")
    const pauseItem = new Gtk.MenuItem({ label: isPaused ? "Resume syncing" : "Pause syncing" })
    pauseItem.connect("activate", () => {
        runHelper("filelu-action", isPaused ? "resume" : "pause")
    })
    menu.append(pauseItem)

    // 3. Upload files
    const uploadItem = new Gtk.MenuItem({ label: "Upload files…" })
    uploadItem.connect("activate", () => {
        runHelper("filelu-action", "upload")
    })
    menu.append(uploadItem)

    menu.append(new Gtk.SeparatorMenuItem())

    // 4. Vault
    const isLocked = statusText.toLowerCase().includes("locked")
    const vaultItem = new Gtk.MenuItem({ label: isLocked ? "Unlock Vault…" : "Lock Vault now" })
    vaultItem.connect("activate", () => {
        runHelper("filelu-action", isLocked ? "unlock" : "lock")
    })
    menu.append(vaultItem)

    menu.append(new Gtk.SeparatorMenuItem())

    // 5. Quit
    const quitItem = new Gtk.MenuItem({ label: "Quit FileLuSync" })
    quitItem.connect("activate", () => {
        runHelper("filelu-action", "quit")
    })
    menu.append(quitItem)

    menu.show_all()
    // Using popup_at_pointer(null) prevents layer-shell 42px bounding constraint (no scroll arrows)
    menu.popup_at_pointer(null)
    return true
}

function openGenericTrayMenu(item: AstalTray.TrayItem) {
    try {
        (item as any).about_to_show?.()
    } catch (_) {}

    const model = (item as any).menuModel || (item as any).menu_model
    if (!model || (model.get_n_items && model.get_n_items() === 0)) {
        return false
    }

    const menu = Gtk.Menu.new_from_model(model)
    const actionGroup = (item as any).actionGroup || (item as any).action_group
    if (actionGroup) {
        menu.insert_action_group("dbusmenu", actionGroup)
    }

    menu.show_all()
    menu.popup_at_pointer(null)
    return true
}

export default function SysTray() {
    const tray = AstalTray.get_default()

    return <box className="SysTray">
        {bind(tray, "items").as(items => {
            const isScrambleItem = (item: AstalTray.TrayItem) =>
                Boolean(item.tooltipMarkup?.includes("Scramble Desktop") || item.id?.includes("scramble"))
            const isGDriveItem = (item: AstalTray.TrayItem) =>
                Boolean(item.id === "google-drive-sync" || item.title === "Google Drive" || item.tooltipMarkup?.includes("Google Drive"))
            const isProtonDriveItem = (item: AstalTray.TrayItem) =>
                Boolean(item.id === "protondrive-sync" || item.title === "Proton Drive" || item.tooltipMarkup?.includes("Proton Drive"))
            const isFileLuItem = (item: AstalTray.TrayItem) =>
                Boolean(item.id === "FileLuSync.bin" || item.title === "FileLuSync.bin" || item.tooltipMarkup?.includes("FileLuSync"))

            const widgets = items.map(item => {
                const isScramble = isScrambleItem(item)
                const isGDrive = isGDriveItem(item)
                const isProtonDrive = isProtonDriveItem(item)
                const isFileLu = isFileLuItem(item)

                if (isFileLu) {
                    return (
                        <button
                            className="FileLuTray"
                            onClicked={() => runHelper("filelu-toggle")}
                            onButtonPressEvent={(_self, event) => {
                                const [, button] = event.get_button()
                                if (button === 3) {
                                    openFileLuMenu(item)
                                    return true
                                }
                                return false
                            }}
                        >
                            <FileLuStatus item={item} />
                        </button>
                    )
                }

                return (
                    <menubutton
                        tooltipMarkup={bind(item, "tooltipMarkup").as(tooltip =>
                            (isScramble || isGDrive || isProtonDrive) ? null : tooltip
                        )}
                        usePopover={false}
                        actionGroup={bind(item, "actionGroup").as(g => ["dbusmenu", g])}
                        menuModel={bind(item, "menuModel")}
                        onButtonPressEvent={(self, event) => {
                            const [, button] = event.get_button()
                            const [, x, y] = event.get_root_coords()

                            if (button === 1) {
                                const model = item.menuModel as any
                                const nItems = model?.get_n_items ? model.get_n_items() : 0
                                if (nItems === 0) {
                                    item.activate(Math.round(x), Math.round(y))
                                    return true
                                }
                                return false
                            }

                            if (button === 3) {
                                const model = item.menuModel as any
                                const nItems = model?.get_n_items ? model.get_n_items() : 0
                                if (nItems > 0) {
                                    return openGenericTrayMenu(item)
                                }
                                item.activate(Math.round(x), Math.round(y))
                                return true
                            }
                            return false
                        }}
                    >
                        {isScramble ? <ScrambleStatus /> : isGDrive ? <GDriveStatus /> : isProtonDrive ? <ProtonDriveStatus /> : <icon gicon={bind(item, "gicon").as(g => g || getFallbackTrayGicon(item))} pixelSize={18} />}
                    </menubutton>
                )
            })

            if (!items.some(isScrambleItem)) {
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
