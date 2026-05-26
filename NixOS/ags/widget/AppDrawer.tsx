import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import { Variable, exec, execAsync } from "astal"
import Apps from "gi://AstalApps"

// Launch an app pinned to the currently-focused Hyprland workspace.
// Hyprland's PID-based initial_workspace_tracking can't follow the
// spawn chain across the AGS layer-shell + systemd-scope boundary, so
// untracked windows drift to whichever workspace Hyprland defaults to
// (often the one hosting a long-lived client like Kitty). We query
// the active workspace ID and dispatch via `[workspace N silent]`,
// which is Hyprland's runtime windowrule prefix.
function launchOnActiveWorkspace(app: Apps.Application) {
    try {
        const ws = JSON.parse(exec("hyprctl activeworkspace -j")).id
        // Strip XDG field codes (%f %F %u %U %i %c %k) before passing
        // to hyprctl — the launcher isn't supplying any file/url args.
        const cmd = app.executable.replace(/\s*%[a-zA-Z]/g, "").trim()
        execAsync(["hyprctl", "dispatch", "exec",
                   `[workspace ${ws} silent] ${cmd}`])
            .catch(e => { console.error("hyprctl dispatch failed:", e); app.launch() })
    } catch (e) {
        console.error("launchOnActiveWorkspace fallback:", e)
        app.launch()
    }
}

// macOS Launchpad-style app drawer: a true full-screen overlay with a
// search box and a FlowBox of icon tiles. Click outside any icon or
// press Esc to close.
const COLS = 8

export default function AppDrawer() {
    const { TOP, BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor
    const apps = new Apps.Apps()
    const query = Variable("")

    // FlowBox for the icon grid (auto-wraps, no manual row math needed).
    const grid = new Gtk.FlowBox({
        valign: Gtk.Align.START,
        halign: Gtk.Align.CENTER,
        homogeneous: true,
        selection_mode: Gtk.SelectionMode.NONE,
        min_children_per_line: COLS,
        max_children_per_line: COLS,
        column_spacing: 24,
        row_spacing: 24,
    })

    function makeTile(app: Apps.Application): Gtk.Widget {
        const icon = new Gtk.Image({
            icon_name: app.iconName || "application-x-executable",
            pixel_size: 72,
        })
        const name = new Gtk.Label({
            label: app.name,
            max_width_chars: 14,
            ellipsize: 3,             // Pango.EllipsizeMode.END
            justify: Gtk.Justification.CENTER,
            xalign: 0.5,
        })
        name.get_style_context().add_class("AppName")
        const inner = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 6 })
        inner.add(icon); inner.add(name)
        const btn = new Gtk.Button()
        btn.add(inner)
        btn.get_style_context().add_class("AppTile")
        btn.connect("clicked", () => {
            launchOnActiveWorkspace(app)
            App.toggle_window("app-drawer")
        })
        btn.set_tooltip_text(app.description || app.name)
        return btn
    }

    function repopulate(q: string) {
        for (const c of grid.get_children()) grid.remove(c)
        const results = q.trim()
            ? apps.fuzzy_query(q).slice(0, 80)
            : apps.get_list().slice().sort((a, b) => a.name.localeCompare(b.name))
        for (const a of results) grid.add(makeTile(a))
        grid.show_all()
    }
    query.subscribe(repopulate)
    repopulate("")

    // Scrollable wrapper for the grid — fills the available vertical space.
    const scroll = new Gtk.ScrolledWindow({
        hscrollbar_policy: Gtk.PolicyType.NEVER,
        vscrollbar_policy: Gtk.PolicyType.AUTOMATIC,
        hexpand: true,
        vexpand: true,
    })
    scroll.add(grid)
    scroll.show_all()

    // Search entry — focus on show, type to filter, Enter launches first hit.
    const searchEntry = new Gtk.SearchEntry({
        placeholder_text: "Search apps…",
        width_request: 400,
    })
    searchEntry.get_style_context().add_class("AppSearch")
    searchEntry.connect("search-changed", () => query.set(searchEntry.get_text()))
    searchEntry.connect("activate", () => {
        const results = apps.fuzzy_query(query.get())
        if (results.length) {
            launchOnActiveWorkspace(results[0])
            App.toggle_window("app-drawer")
        }
    })
    searchEntry.show()

    return <window
        name="app-drawer"
        className="AppDrawerWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.EXCLUSIVE}
        // NORMAL keeps the bar visible & clickable; Bar handles dismiss.
        exclusivity={Astal.Exclusivity.NORMAL}
        anchor={TOP | BOTTOM | LEFT | RIGHT}
        layer={Astal.Layer.OVERLAY}
        onShow={() => {
            searchEntry.set_text("")
            query.set("")
            searchEntry.grab_focus()
        }}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b) self.hide()
        }}>
        <eventbox hexpand vexpand
            // Click anywhere outside an app tile dismisses (including empty
            // areas of the grid, the gap above search, the sides).
            onButtonPressEvent={(self) => {
                const w = self.get_ancestor(Astal.Window.$gtype) as Astal.Window
                w?.hide(); return true
            }}>
            <box vertical hexpand vexpand>
                <box halign={Gtk.Align.CENTER} marginTop={40} marginBottom={20}>
                    <eventbox onButtonPressEvent={() => true}>
                        {searchEntry}
                    </eventbox>
                </box>
                <box hexpand vexpand marginStart={60} marginEnd={60} marginBottom={40}>
                    {scroll}
                </box>
            </box>
        </eventbox>
    </window>
}
