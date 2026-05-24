import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import { Variable } from "astal"
import Apps from "gi://AstalApps"
import Hyprland from "gi://AstalHyprland"

// macOS-style dock. Edit PINS to taste — each entry is matched against
// application id/name/executable case-insensitive substring. Running apps
// (Hyprland clients) whose class includes the pin string get a running dot.
const PINS = [
    "firefox",
    "kitty",
    "emacs",
    "nemo",
    "mpv",
    "blueman-manager",
] as const

const ICON_SIZE = 48
const BAR_HEIGHT = 40   // matches Hyprland reserved zone for the bar

function findApp(apps: Apps.Apps, q: string): Apps.Application | null {
    const lower = q.toLowerCase()
    for (const a of apps.get_list()) {
        const hay = [
            (a as any).id,
            (a as any).entry,
            a.executable,
            a.name,
        ].filter(Boolean).map((s: string) => s.toLowerCase())
        if (hay.some(s => s.includes(lower))) return a
    }
    return null
}

export default function Dock() {
    const { BOTTOM } = Astal.WindowAnchor
    const apps = new Apps.Apps()
    const hypr = Hyprland.get_default()

    // Resolve each pin to an installed app once at startup.
    type Pin = { key: string; app: Apps.Application }
    const pinned: Pin[] = []
    for (const k of PINS) {
        const a = findApp(apps, k)
        if (a) pinned.push({ key: k, app: a })
        else console.warn(`Dock: no app matched pin '${k}'`)
    }

    // Track running Hyprland client classes; recomputed on add/remove.
    const runningClasses = Variable<string[]>([])
    function updateRunning() {
        const s = new Set<string>()
        for (const c of hypr.clients ?? []) {
            const cls = c.class || c.initialClass
            if (cls) s.add(cls.toLowerCase())
        }
        runningClasses.set([...s])
    }
    hypr.connect("client-added", updateRunning)
    hypr.connect("client-removed", updateRunning)
    updateRunning()

    function isRunning(key: string, classes: string[]): boolean {
        const k = key.toLowerCase()
        return classes.some(c => c.includes(k))
    }

    function focusOrLaunch(p: Pin) {
        const k = p.key.toLowerCase()
        const target = (hypr.clients ?? []).find(c => {
            const cls = (c.class || c.initialClass || "").toLowerCase()
            return cls.includes(k)
        })
        if (target) {
            try { target.focus() } catch (e) { console.error("focus failed:", e) }
        } else {
            try { p.app.launch() } catch (e) { console.error("launch failed:", e) }
        }
    }

    // Build tiles imperatively so the running-dot can be mutated cheaply.
    function makeTile(p: Pin): Gtk.Widget {
        const icon = new Gtk.Image({
            icon_name: p.app.iconName || "application-x-executable",
            pixel_size: ICON_SIZE,
        })
        const dot = new Gtk.Label({ label: "●" })
        dot.get_style_context().add_class("DockDot")
        // Keep set_visible() decisions intact across the show_all() below.
        dot.no_show_all = true
        const inner = new Gtk.Box({
            orientation: Gtk.Orientation.VERTICAL, spacing: 1,
            halign: Gtk.Align.CENTER,
        })
        inner.add(icon); inner.add(dot)

        const btn = new Gtk.Button()
        btn.add(inner)
        btn.get_style_context().add_class("DockTile")
        btn.set_tooltip_text(p.app.name)
        btn.connect("clicked", () => focusOrLaunch(p))

        const sync = (classes: string[]) => {
            const running = isRunning(p.key, classes)
            dot.set_visible(running)
            const ctx = btn.get_style_context()
            if (running) ctx.add_class("Running")
            else ctx.remove_class("Running")
        }
        runningClasses.subscribe(sync)
        sync(runningClasses.get())
        return btn
    }

    const dockBox = new Gtk.Box({ spacing: 4, halign: Gtk.Align.CENTER })
    for (const p of pinned) dockBox.add(makeTile(p))
    dockBox.show_all()

    return <window
        name="dock"
        className="DockWindow"
        application={App}
        // IGNORE so the dock doesn't add to the exclusive zone (the bar
        // already reserves 40px). marginBottom positions us just above
        // the bar.
        exclusivity={Astal.Exclusivity.IGNORE}
        anchor={BOTTOM}
        marginBottom={BAR_HEIGHT}
        layer={Astal.Layer.TOP}>
        <box className="DockPanel" halign={Gtk.Align.CENTER}>
            {dockBox}
        </box>
    </window>
}
