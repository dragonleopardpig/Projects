import { App } from "astal/gtk3"
import style from "./style.scss"
import Bar from "./widget/Bar"
import CalendarPopup from "./widget/CalendarPopup"

// GTK3's CSS parser doesn't understand `@charset` and bails on the whole
// stylesheet if it sees one. Sass emits it automatically when the SCSS source
// contains non-ASCII characters (our box-drawing comments).
const css = style.replace(/@charset\s+"[^"]*";\s*/g, "")

App.start({
    css,
    main() {
        App.get_monitors().map(Bar)
        // One shared popup; the bar on any monitor toggles it by name.
        CalendarPopup()
    },
})
