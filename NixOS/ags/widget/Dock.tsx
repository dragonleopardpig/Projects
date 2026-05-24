import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import { Variable, timeout } from "astal"
import Apps from "gi://AstalApps"
import Hyprland from "gi://AstalHyprland"

// macOS-style auto-hiding dock that sits just above the bar.
//
// PINS resolves to installed apps at startup. Running but un-pinned apps
// appear after a separator. Click focuses (or launches if none running);
// right-click opens a menu with new-window / cycle / close-all.

const PINS = [
    "firefox",
    "kitty",
    "emacs",
    "nemo",
    "mpv",
    "blueman-manager",
] as const

const ICON_SIZE = 48
const BAR_HEIGHT = 0     // bar lives at the top now; dock pins to bottom edge
const HIDE_DELAY = 350   // ms after pointer leaves the dock
const HOT_HEIGHT = 6     // px of trigger strip just above the bar

type Pin = { key: string; app: Apps.Application; pinned: boolean }

function findApp(apps: Apps.Apps, q: string): Apps.Application | null {
    const lower = q.toLowerCase()
    for (const a of apps.get_list()) {
        const hay = [
            (a as any).id, (a as any).entry, a.executable, a.name,
        ].filter(Boolean).map((s: string) => s.toLowerCase())
        if (hay.some(s => s.includes(lower))) return a
    }
    return null
}

export default function Dock() {
    const { BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor
    const apps = new Apps.Apps()
    const hypr = Hyprland.get_default()

    // ── Pin resolution ───────────────────────────────────────────────
    const pinnedList: Pin[] = []
    for (const k of PINS) {
        const a = findApp(apps, k)
        if (a) pinnedList.push({ key: k, app: a, pinned: true })
        else console.warn(`Dock: no app matched pin '${k}'`)
    }

    // ── Hyprland client tracking ─────────────────────────────────────
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

    function classMatchesPin(cls: string): boolean {
        const c = cls.toLowerCase()
        return PINS.some(p => c.includes(p.toLowerCase()))
    }
    function isRunningPin(pin: Pin, classes: string[]): boolean {
        const k = pin.key.toLowerCase()
        return classes.some(c => c.includes(k))
    }
    function clientsFor(pin: Pin) {
        const k = pin.key.toLowerCase()
        return (hypr.clients ?? []).filter(c =>
            (c.class || c.initialClass || "").toLowerCase().includes(k)
        )
    }

    // ── Click / right-click handlers ─────────────────────────────────
    function focusOrLaunch(pin: Pin) {
        const matching = clientsFor(pin)
        if (matching.length) {
            try { matching[0].focus() } catch (e) { console.error(e) }
        } else {
            try { pin.app.launch() } catch (e) { console.error(e) }
        }
    }

    function rightClickMenu(pin: Pin) {
        const menu = new Gtk.Menu()
        const matching = clientsFor(pin)

        const newItem = new Gtk.MenuItem({ label: "Open new window" })
        newItem.connect("activate", () => {
            try { pin.app.launch() } catch (e) { console.error(e) }
        })
        menu.append(newItem)

        if (matching.length > 1) {
            const cycle = new Gtk.MenuItem({
                label: `Cycle ${matching.length} windows`,
            })
            cycle.connect("activate", () => {
                const focused = (hypr as any).focusedClient
                let idx = matching.findIndex(c => c.address === focused?.address)
                if (idx < 0) idx = -1
                const next = matching[(idx + 1) % matching.length]
                try { next.focus() } catch (e) { console.error(e) }
            })
            menu.append(cycle)
        }
        if (matching.length > 0) {
            const close = new Gtk.MenuItem({
                label: matching.length > 1
                    ? `Close all ${matching.length} windows`
                    : "Close window",
            })
            close.connect("activate", () => {
                for (const c of matching) try { c.kill() } catch (e) { console.error(e) }
            })
            menu.append(close)
        }
        menu.show_all()
        menu.popup_at_pointer(null)
    }

    // ── Tile factory ─────────────────────────────────────────────────
    function makeTile(pin: Pin): Gtk.Widget {
        const icon = new Gtk.Image({
            icon_name: pin.app.iconName || "application-x-executable",
            pixel_size: ICON_SIZE,
        })
        const dot = new Gtk.Label({ label: "●" })
        dot.get_style_context().add_class("DockDot")
        dot.no_show_all = true

        const inner = new Gtk.Box({
            orientation: Gtk.Orientation.VERTICAL, spacing: 1,
            halign: Gtk.Align.CENTER,
        })
        inner.add(icon); inner.add(dot)

        const btn = new Gtk.Button()
        btn.add(inner)
        btn.get_style_context().add_class("DockTile")
        if (!pin.pinned) btn.get_style_context().add_class("Unpinned")
        btn.set_tooltip_text(pin.app.name)
        btn.connect("clicked", () => focusOrLaunch(pin))
        btn.connect("button-press-event", (_self: any, ev: any) => {
            if (ev.get_button()[1] === 3 /* right click */) {
                rightClickMenu(pin)
                return true
            }
            return false
        })

        const sync = (classes: string[]) => dot.set_visible(isRunningPin(pin, classes))
        runningClasses.subscribe(sync)
        sync(runningClasses.get())
        return btn
    }

    // ── Build pinned section ─────────────────────────────────────────
    const dockBox = new Gtk.Box({ spacing: 4, halign: Gtk.Align.CENTER })
    for (const pin of pinnedList) dockBox.add(makeTile(pin))

    const separator = new Gtk.Separator({ orientation: Gtk.Orientation.VERTICAL })
    separator.get_style_context().add_class("DockSep")
    separator.set_margin_start(8)
    separator.set_margin_end(8)
    separator.no_show_all = true
    dockBox.add(separator)

    // ── Non-pinned running tiles (rebuilt as classes change) ─────────
    const nonPinned: Map<string, Gtk.Widget> = new Map()
    function syncNonPinned(classes: string[]) {
        const next = classes.filter(c => !classMatchesPin(c))
        const nextSet = new Set(next)
        for (const [cls, w] of [...nonPinned.entries()]) {
            if (!nextSet.has(cls)) { dockBox.remove(w); nonPinned.delete(cls) }
        }
        for (const cls of next) {
            if (nonPinned.has(cls)) continue
            const a = apps.fuzzy_query(cls)[0]
            if (!a) continue
            const tile = makeTile({ key: cls, app: a, pinned: false })
            dockBox.add(tile)
            nonPinned.set(cls, tile)
        }
        separator.set_visible(nonPinned.size > 0)
        dockBox.show_all()
    }
    runningClasses.subscribe(syncNonPinned)
    syncNonPinned(runningClasses.get())

    // ── Auto-hide state ──────────────────────────────────────────────
    let hideTimer: any = null
    const showDock = () => {
        if (hideTimer) { hideTimer.cancel(); hideTimer = null }
        App.get_window("dock")?.show()
    }
    const cancelHide = () => {
        if (hideTimer) { hideTimer.cancel(); hideTimer = null }
    }
    const scheduleHide = () => {
        if (hideTimer) hideTimer.cancel()
        hideTimer = timeout(HIDE_DELAY, () => {
            App.get_window("dock")?.hide()
            hideTimer = null
        })
    }

    // ── Hot zone window (always present, transparent) ────────────────
    // Side-effect registers with App via application= prop.
    void (
        <window
            name="dock-hot"
            className="DockHot"
            application={App}
            exclusivity={Astal.Exclusivity.IGNORE}
            anchor={BOTTOM | LEFT | RIGHT}
            marginBottom={BAR_HEIGHT}
            layer={Astal.Layer.OVERLAY}>
            <eventbox
                heightRequest={HOT_HEIGHT}
                onEnterNotifyEvent={() => { showDock(); return false }}>
                <box />
            </eventbox>
        </window>
    )

    return <window
        name="dock"
        className="DockWindow"
        application={App}
        visible={false}
        exclusivity={Astal.Exclusivity.IGNORE}
        anchor={BOTTOM | LEFT | RIGHT}
        marginBottom={BAR_HEIGHT}
        layer={Astal.Layer.OVERLAY}
        onShow={cancelHide}>
        <eventbox
            onEnterNotifyEvent={() => { cancelHide(); return false }}
            onLeaveNotifyEvent={(_self: any, ev: any) => {
                // Ignore crossings into child widgets (buttons etc.).
                if (ev.get_detail()[1] === Gdk.NotifyType.INFERIOR) return false
                scheduleHide()
                return false
            }}>
            <box halign={Gtk.Align.CENTER}>
                <box className="DockPanel">
                    {dockBox}
                </box>
            </box>
        </eventbox>
    </window>
}
