import { App } from "astal/gtk3"
import style from "./style.scss"
import Bar from "./widget/Bar"
import CalendarPopup from "./widget/CalendarPopup"
import ControlCenter from "./widget/ControlCenter"
import AppDrawer from "./widget/AppDrawer"
import WeatherPopup from "./widget/WeatherPopup"

// GTK3's CSS parser doesn't understand `@charset` and bails on the whole
// stylesheet if it sees one. Sass emits it automatically when the SCSS source
// contains non-ASCII characters (our box-drawing comments).
const css = style.replace(/@charset\s+"[^"]*";\s*/g, "")

App.start({
    css,
    requestHandler(req, res) {
        if (req === "togglebar") {
            const bars = App.get_windows().filter(w => w.name?.startsWith("bar-"))
            const anyVisible = bars.some(w => w.visible)
            for (const w of bars) w.visible = !anyVisible
            res("ok")
        } else {
            res(`unknown: ${req}`)
        }
    },
    main() {
        App.get_monitors().map((m, i) => Bar(m, i))
        // Shared popups; bars on any monitor toggle them by name.
        CalendarPopup()
        ControlCenter()
        AppDrawer()
        WeatherPopup()
    },
})
