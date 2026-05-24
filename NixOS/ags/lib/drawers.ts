import { App } from "astal/gtk3"

// Names of every popup overlay window. Kept centralised so the bar dismiss
// handler can hide them all in one shot.
export const DRAWER_NAMES = [
    "control-center",
    "calendar",
    "app-drawer",
    "weather",
] as const

export function dismissDrawers(except?: string) {
    for (const n of DRAWER_NAMES) {
        if (n === except) continue
        const w = App.get_window(n)
        if (w?.visible) w.hide()
    }
}

// Toggle button helper. Gtk.Button consumes button-press-event so the
// bar's outer event-box never sees presses on a button; the toggle has
// to do its own open-vs-close logic. We capture visibility at press
// time so the answer is stable even if something else changes it.
export function bindToggleButton(button: any, name: string) {
    let wasOpenOnPress = false
    button.connect("button-press-event", () => {
        wasOpenOnPress = App.get_window(name)?.visible ?? false
        return false
    })
    button.connect("clicked", () => {
        const w = App.get_window(name)
        if (!w) return
        if (wasOpenOnPress) w.hide()
        else { dismissDrawers(name); w.show() }
    })
}

// Non-toggle bar widgets that aren't drawers themselves but should also
// dismiss whichever drawer is open. Wire each one's primary signal up
// with this. Returns no value — fire and forget.
export function dismissOnClick() { dismissDrawers() }
