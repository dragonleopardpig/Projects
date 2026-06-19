import { App, Astal, Gtk } from "astal/gtk3"
import { Variable, execAsync } from "astal"
import { WEATHER_FETCH_BIN, WEATHER_FETCH_SCRIPT, WEATHER_CITY } from "../lib/paths"

type Cur = {
    temp_c: string; feels_c: string; desc: string;
    humidity: string; wind_kmph: string; wind_dir: string;
    glyph: string; observed: string;
}
type Day = {
    date: string; min_c: string; max_c: string;
    sunrise: string; sunset: string; desc: string; glyph: string;
}
type WX = { location: string; current: Cur; forecast: Day[]; error?: string }

const data = Variable<WX | null>(null)
const loading = Variable(false)

async function refresh() {
    loading.set(true)
    try {
        const out = await execAsync([WEATHER_FETCH_BIN, WEATHER_FETCH_SCRIPT, WEATHER_CITY])
        const parsed = JSON.parse(out) as WX
        data.set(parsed)
    } catch (e: any) {
        data.set({ location: WEATHER_CITY, current: null as any, forecast: [],
                   error: String(e?.message ?? e) })
    } finally { loading.set(false) }
}

export default function WeatherPopup() {
    const { TOP, BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor

    // Build the body imperatively so we can rebuild on data updates without
    // tripping the bind().as()-can't-swap-trees gotcha.
    const body = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 12 })
    body.get_style_context().add_class("WeatherBody")

    function render(d: WX | null, isLoading: boolean) {
        for (const c of body.get_children()) body.remove(c)
        if (isLoading && !d) {
            const l = new Gtk.Label({ label: "Loading…" })
            l.get_style_context().add_class("WeatherSubtle")
            body.add(l)
            body.show_all()
            return
        }
        if (!d) { body.show_all(); return }
        if (d.error) {
            const l = new Gtk.Label({ label: `Error: ${d.error}` })
            l.get_style_context().add_class("WeatherSubtle")
            body.add(l)
            body.show_all()
            return
        }

        // Location header
        const loc = new Gtk.Label({ label: d.location, xalign: 0 })
        loc.get_style_context().add_class("WeatherLocation")
        body.add(loc)

        // Current
        if (d.current) {
            const big = new Gtk.Box({ spacing: 14 })
            const glyph = new Gtk.Label({ label: d.current.glyph || "" })
            glyph.get_style_context().add_class("WeatherGlyphBig")
            big.add(glyph)

            const info = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 2 })
            const temp = new Gtk.Label({
                label: `${d.current.temp_c}°C`, xalign: 0,
            })
            temp.get_style_context().add_class("WeatherTemp")
            const desc = new Gtk.Label({ label: d.current.desc, xalign: 0 })
            desc.get_style_context().add_class("WeatherDesc")
            const meta = new Gtk.Label({
                xalign: 0,
                label: `Feels ${d.current.feels_c}°C  ·  ${d.current.humidity}% humid  ·  ${d.current.wind_kmph} km/h ${d.current.wind_dir}`,
            })
            meta.get_style_context().add_class("WeatherSubtle")
            const obs = new Gtk.Label({
                xalign: 0, label: `Updated ${d.current.observed}`,
            })
            obs.get_style_context().add_class("WeatherSubtle")
            info.add(temp); info.add(desc); info.add(meta); info.add(obs)
            big.add(info)
            body.add(big)
        }

        // Forecast row
        const fc = new Gtk.Box({ spacing: 8, homogeneous: true })
        for (const day of d.forecast) {
            const cell = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 2 })
            cell.get_style_context().add_class("WeatherDay")
            const dt = new Gtk.Label({ label: day.date })
            dt.get_style_context().add_class("WeatherDayName")
            const g = new Gtk.Label({ label: day.glyph || "" })
            g.get_style_context().add_class("WeatherGlyph")
            const t = new Gtk.Label({ label: `${day.max_c}° / ${day.min_c}°` })
            t.get_style_context().add_class("WeatherTempRange")
            const sun = new Gtk.Label({ label: `↑ ${day.sunrise}  ↓ ${day.sunset}` })
            sun.get_style_context().add_class("WeatherSubtle")
            cell.add(dt); cell.add(g); cell.add(t); cell.add(sun)
            fc.add(cell)
        }
        body.add(fc)

        body.show_all()
    }
    data.subscribe(d => render(d, loading.get()))
    loading.subscribe(l => render(data.get(), l))
    render(data.get(), loading.get())

    return <window
        name="weather"
        className="WeatherPopupWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        exclusivity={Astal.Exclusivity.NORMAL}
        anchor={TOP | BOTTOM | LEFT | RIGHT}
        layer={Astal.Layer.OVERLAY}
        onShow={() => { refresh() }}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b) self.hide()
        }}>
        <eventbox hexpand vexpand
            onButtonPressEvent={(self) => {
                const w = self.get_ancestor(Astal.Window.$gtype) as Astal.Window
                w?.hide(); return true
            }}>
        <box halign={Gtk.Align.END} valign={Gtk.Align.START}>
        <eventbox onButtonPressEvent={() => true}>
        <box className="WeatherPanel" vertical spacing={10}
            widthRequest={420}>
            {body}
        </box>
        </eventbox>
        </box>
        </eventbox>
    </window>
}
