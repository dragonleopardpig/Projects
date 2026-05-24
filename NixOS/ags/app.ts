import { App } from "astal/gtk3"
import style from "./style.scss"
import Bar from "./widget/Bar"
import CalendarPopup from "./widget/CalendarPopup"
import ControlCenter from "./widget/ControlCenter"
import AppDrawer from "./widget/AppDrawer"
import NowPlaying from "./widget/NowPlaying"

// GTK3's CSS parser doesn't understand `@charset` and bails on the whole
// stylesheet if it sees one. Sass emits it automatically when the SCSS source
// contains non-ASCII characters (our box-drawing comments).
const css = style.replace(/@charset\s+"[^"]*";\s*/g, "")

App.start({
    css,
    main() {
        App.get_monitors().map(Bar)
        // Shared popups; bars on any monitor toggle them by name.
        CalendarPopup()
        ControlCenter()
        AppDrawer()
        NowPlaying()
    },
})
