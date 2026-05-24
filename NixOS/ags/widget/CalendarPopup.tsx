import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, bind, execAsync } from "astal"
import { CALENDAR_BIN, CALENDAR_SCRIPT, CALENDAR_ICS_DIR } from "../lib/paths"

// ── Types mirror the JSON emitted by assets/calendar-month.py ────────────
type Event = { title: string; category: "public" | "school" }
type Cell = {
    date: string
    day: number
    in_month: boolean
    is_today: boolean
    lunar: string
    lunar_compact: string
    lunar_first: boolean
    festival: string | null
    solarterm: string | null
    events: Event[]
}
type Month = {
    year: number; month: number; title: string
    weekdays: string[]
    cells: Cell[]
}

const MONTHS = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]

const ymKey = (y: number, m: number) => `${y}-${String(m).padStart(2, "0")}`

function fetchMonth(year: number, month: number): Promise<Month> {
    return execAsync([CALENDAR_BIN, CALENDAR_SCRIPT, ymKey(year, month), CALENDAR_ICS_DIR])
        .then(out => JSON.parse(out) as Month)
}

function dotClassFor(c: Cell): string | null {
    if (c.events.some(e => e.category === "public")) return "Dot Public"
    if (c.festival)                                  return "Dot Festival"
    if (c.events.some(e => e.category === "school")) return "Dot School"
    if (c.solarterm)                                 return "Dot Solarterm"
    return null
}

function cellClasses(c: Cell, col: number): string {
    const parts = ["CalCell"]
    if (!c.in_month) parts.push("OutOfMonth")
    if (c.is_today) parts.push("Today")
    if (c.events.length) parts.push("HasEvent")
    if (c.festival) parts.push("HasFestival")
    if (c.solarterm) parts.push("HasSolarterm")
    if (col === 5 || col === 6) parts.push("Weekend")
    return parts.join(" ")
}

export default function CalendarPopup() {
    const { BOTTOM, RIGHT } = Astal.WindowAnchor
    const today = new Date()

    const cursor = Variable({ y: today.getFullYear(), m: today.getMonth() + 1 })
    const selected = Variable<Cell | null>(null)
    const title = Variable("")

    // ── Build static grid widgets up front, populate cells imperatively ──
    // Each cell is a button containing day#, dot, and lunar label. We keep
    // direct references so the subscribe callback can mutate them in place.
    type CellRefs = {
        button: Gtk.Button
        day: Gtk.Label
        dot: Gtk.Label
        lunar: Gtk.Label
    }
    const cellRefs: CellRefs[] = []

    for (let i = 0; i < 42; i++) {
        const day = new Gtk.Label({ xalign: 0, hexpand: true })
        day.get_style_context().add_class("DayNum")
        const dot = new Gtk.Label({ label: "" })
        const lunar = new Gtk.Label({ xalign: 1 })
        lunar.get_style_context().add_class("Lunar")

        const top = new Gtk.Box({ orientation: Gtk.Orientation.HORIZONTAL })
        top.add(day); top.add(dot)
        const inner = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL })
        inner.add(top); inner.add(lunar)

        const button = new Gtk.Button()
        button.add(inner)
        button.get_style_context().add_class("CalCell")
        cellRefs.push({ button, day, dot, lunar })
    }

    function paintCells(d: Month) {
        for (let i = 0; i < 42; i++) {
            const c = d.cells[i]
            const r = cellRefs[i]
            r.day.set_label(String(c.day))
            r.lunar.set_label(c.lunar_compact)
            // Reset and re-apply class list on the button.
            const ctx = r.button.get_style_context()
            for (const cl of ["OutOfMonth","Today","HasEvent","HasFestival","HasSolarterm","Weekend"])
                ctx.remove_class(cl)
            for (const cl of cellClasses(c, i % 7).split(" "))
                if (cl !== "CalCell") ctx.add_class(cl)
            // Lunar accent on month-rollover days.
            const lc = r.lunar.get_style_context()
            lc.remove_class("LunarFirst")
            if (c.lunar_first) lc.add_class("LunarFirst")
            // Dot label + class.
            const dc = r.dot.get_style_context()
            for (const cl of ["Dot","Public","School","Festival","Solarterm"])
                dc.remove_class(cl)
            const dot = dotClassFor(c)
            if (dot) {
                r.dot.set_label("●")
                for (const cl of dot.split(" ")) dc.add_class(cl)
            } else {
                r.dot.set_label("")
            }
            // Stash the cell on the button so onClicked can recover it.
            ;(r.button as any)._cell = c
        }
    }

    // Hook clicks: set the selected cell.
    for (const r of cellRefs) {
        r.button.connect("clicked", (self: any) => {
            if (self._cell) selected.set(self._cell as Cell)
        })
    }

    function loadMonth() {
        const { y, m } = cursor.get()
        title.set(`${MONTHS[m - 1]} ${y}`)
        fetchMonth(y, m).then(d => {
            paintCells(d)
            const todayCell = d.cells.find(c => c.is_today && c.in_month) ?? null
            const firstCell = d.cells.find(c => c.in_month && c.day === 1) ?? null
            selected.set(todayCell ?? firstCell)
        }).catch(e => console.error("calendar fetch failed:", e))
    }

    cursor.subscribe(loadMonth)
    loadMonth()

    function shiftMonth(delta: number) {
        const { y, m } = cursor.get()
        const nm = m + delta
        if (nm < 1) cursor.set({ y: y - 1, m: 12 })
        else if (nm > 12) cursor.set({ y: y + 1, m: 1 })
        else cursor.set({ y, m: nm })
    }

    function gotoToday() {
        const t = new Date()
        cursor.set({ y: t.getFullYear(), m: t.getMonth() + 1 })
    }

    // Assemble the grid: 6 rows × 7 cells.
    const gridRows: Gtk.Box[] = []
    for (let r = 0; r < 6; r++) {
        const row = new Gtk.Box({ homogeneous: true, spacing: 2 })
        for (let c = 0; c < 7; c++) row.add(cellRefs[r * 7 + c].button)
        gridRows.push(row)
    }
    const gridBox = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 2 })
    for (const r of gridRows) gridBox.add(r)

    // Weekday header.
    const weekdayBox = new Gtk.Box({ homogeneous: true, spacing: 2 })
    const dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    dayNames.forEach((n, i) => {
        const l = new Gtk.Label({ label: n })
        l.get_style_context().add_class("Weekday")
        if (i >= 5) l.get_style_context().add_class("Weekend")
        weekdayBox.add(l)
    })

    // Detail pane — rebuilt from `selected`.
    const detailBox = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 3 })
    detailBox.get_style_context().add_class("Detail")

    function setDetail(c: Cell | null) {
        for (const child of detailBox.get_children()) detailBox.remove(child)
        if (!c) { detailBox.show_all(); return }
        const d = new Date(c.date + "T00:00:00")
        const head = d.toLocaleDateString(undefined, {
            weekday: "short", day: "numeric", month: "long",
        })
        const headRow = new Gtk.Box({ spacing: 8 })
        const headL = new Gtk.Label({ label: head, xalign: 0, hexpand: true })
        headL.get_style_context().add_class("DetailHead")
        const lunL = new Gtk.Label({ label: c.lunar })
        lunL.get_style_context().add_class("DetailLunar")
        headRow.add(headL); headRow.add(lunL)
        detailBox.add(headRow)

        const addLine = (text: string, cls: string) => {
            const l = new Gtk.Label({ label: text, xalign: 0, wrap: true })
            l.get_style_context().add_class(cls)
            detailBox.add(l)
        }
        if (c.solarterm) addLine(`节气 · ${c.solarterm}`, "DetailSolarterm")
        if (c.festival)  addLine(`节日 · ${c.festival}`,   "DetailFestival")
        for (const e of c.events) {
            const prefix = e.category === "public" ? "" : ""
            addLine(`${prefix}  ${e.title}`,
                e.category === "public" ? "DetailPublic" : "DetailSchool")
        }
        if (!c.solarterm && !c.festival && !c.events.length)
            addLine("(no events)", "DetailEmpty")
        detailBox.show_all()
    }
    selected.subscribe(setDetail)

    weekdayBox.show_all()
    gridBox.show_all()
    detailBox.show_all()

    return <window
        name="calendar"
        className="CalendarPopupWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        anchor={BOTTOM | RIGHT}
        layer={Astal.Layer.OVERLAY}
        widthRequest={460}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b /* GDK_KEY_Escape */) self.hide()
        }}>
        <box className="CalendarPanel" vertical spacing={8}>
            <box className="CalHeader" spacing={6}>
                <button className="NavBtn" onClicked={() => shiftMonth(-1)}>
                    <label label={"\u{f0141}"} />
                </button>
                <label className="CalTitle" hexpand
                    label={bind(title)} />
                <button className="TodayBtn" onClicked={gotoToday}>
                    <label label="Today" />
                </button>
                <button className="NavBtn" onClicked={() => shiftMonth(1)}>
                    <label label={"\u{f0142}"} />
                </button>
            </box>
            {weekdayBox}
            {gridBox}
            {detailBox}
        </box>
    </window>
}
