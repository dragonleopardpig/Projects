import { App } from "astal/gtk3"

// Names of every popup overlay window. Kept centralised so the bar dismiss
// handler can hide them all in one shot.
export const DRAWER_NAMES = [
    "control-center",
    "calendar",
    "app-drawer",
    "now-playing",
] as const

export function dismissDrawers(except?: string) {
    for (const n of DRAWER_NAMES) {
        if (n === except) continue
        const w = App.get_window(n)
        if (w?.visible) w.hide()
    }
}

// Toggle button helper that plays well with the bar's "any click dismisses
// drawers" handler. Bar's press handler runs *after* the inner button's
// press handler (events bubble inner→outer), so we capture the drawer's
// pre-press visibility on press and apply it on click — letting us tell
// "user wants to close this" apart from "user wants to open this".
export function bindToggleButton(button: any, name: string) {
    let wasOpenOnPress = false
    button.connect("button-press-event", () => {
        wasOpenOnPress = App.get_window(name)?.visible ?? false
        return false   // let event keep bubbling so siblings dismiss too
    })
    button.connect("clicked", () => {
        const w = App.get_window(name)
        if (!w) return
        if (wasOpenOnPress) {
            // The bar wrapper's press handler already hid it. Leave it hidden.
            return
        }
        dismissDrawers(name)
        w.show()
    })
}
