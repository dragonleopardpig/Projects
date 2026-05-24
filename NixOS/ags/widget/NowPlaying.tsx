import { App, Astal, Gtk, Gdk } from "astal/gtk3"
import { Variable, interval } from "astal"
import Mpris from "gi://AstalMpris"
import { ICON } from "../lib/icons"

// macOS-style "Now Playing" popup: tabs for each MPRIS player, large
// album art, title/artist/album, seekable progress, transport controls,
// volume slider. Click outside or press Esc to close.
const ART_SIZE = 180
const PANEL_WIDTH = 460

function fmtTime(sec: number): string {
    if (!isFinite(sec) || sec <= 0) return "0:00"
    const s = Math.floor(sec)
    const m = Math.floor(s / 60)
    return `${m}:${(s % 60).toString().padStart(2, "0")}`
}

export default function NowPlaying() {
    const { TOP, BOTTOM, LEFT, RIGHT } = Astal.WindowAnchor
    const mpris = Mpris.get_default()

    // ── Tabs row (one button per MPRIS player) ───────────────────────
    const tabsBox = new Gtk.Box({ spacing: 6, halign: Gtk.Align.START })

    // ── Album art + track info ───────────────────────────────────────
    const art = new Gtk.Image({ pixel_size: ART_SIZE })
    art.get_style_context().add_class("NPArt")
    art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)

    const titleLabel = new Gtk.Label({
        xalign: 0, halign: Gtk.Align.START,
        max_width_chars: 28, ellipsize: 3, wrap: true, lines: 2,
    })
    titleLabel.get_style_context().add_class("NPTitle")

    const artistLabel = new Gtk.Label({
        xalign: 0, halign: Gtk.Align.START,
        max_width_chars: 32, ellipsize: 3,
    })
    artistLabel.get_style_context().add_class("NPArtist")

    const albumLabel = new Gtk.Label({
        xalign: 0, halign: Gtk.Align.START,
        max_width_chars: 32, ellipsize: 3,
    })
    albumLabel.get_style_context().add_class("NPAlbum")

    const infoBox = new Gtk.Box({
        orientation: Gtk.Orientation.VERTICAL, spacing: 4,
        valign: Gtk.Align.CENTER, hexpand: true,
    })
    infoBox.add(titleLabel); infoBox.add(artistLabel); infoBox.add(albumLabel)

    const topRow = new Gtk.Box({ spacing: 14 })
    topRow.add(art); topRow.add(infoBox)

    // ── Seek slider + time labels ────────────────────────────────────
    const seekScale = new Gtk.Scale({
        orientation: Gtk.Orientation.HORIZONTAL,
        draw_value: false, hexpand: true,
    })
    seekScale.set_range(0, 1)
    seekScale.get_style_context().add_class("NPSeek")

    let seeking = false
    seekScale.connect("button-press-event", () => { seeking = true; return false })
    seekScale.connect("button-release-event", () => {
        const p = currentPlayer
        if (p) p.position = seekScale.get_value()
        seeking = false
        return false
    })

    const positionLabel = new Gtk.Label({ xalign: 0, label: "0:00" })
    positionLabel.get_style_context().add_class("NPTime")
    const lengthLabel = new Gtk.Label({ xalign: 1, label: "—:—" })
    lengthLabel.get_style_context().add_class("NPTime")
    const timeRow = new Gtk.Box({ spacing: 8 })
    timeRow.pack_start(positionLabel, false, false, 0)
    timeRow.pack_end(lengthLabel, false, false, 0)

    // ── Transport buttons ────────────────────────────────────────────
    const mkXport = (glyph: string, cls: string): [Gtk.Button, Gtk.Label] => {
        const b = new Gtk.Button()
        const l = new Gtk.Label({ label: glyph })
        b.add(l)
        b.get_style_context().add_class("NPXport")
        b.get_style_context().add_class(cls)
        return [b, l]
    }
    const [prevBtn] = mkXport(ICON.prev, "Prev")
    const [playBtn, playLbl] = mkXport(ICON.play, "Play")
    const [nextBtn] = mkXport(ICON.next, "Next")

    prevBtn.connect("clicked", () => currentPlayer?.previous())
    nextBtn.connect("clicked", () => currentPlayer?.next())
    playBtn.connect("clicked", () => currentPlayer?.play_pause())

    const xportRow = new Gtk.Box({ spacing: 18, halign: Gtk.Align.CENTER })
    xportRow.add(prevBtn); xportRow.add(playBtn); xportRow.add(nextBtn)

    // ── Volume row ───────────────────────────────────────────────────
    const volIcon = new Gtk.Label({ label: ICON.speaker })
    volIcon.get_style_context().add_class("NPVolIcon")
    const volScale = new Gtk.Scale({
        orientation: Gtk.Orientation.HORIZONTAL,
        draw_value: false, hexpand: true,
    })
    volScale.set_range(0, 1)
    volScale.get_style_context().add_class("NPVol")
    let volSeeking = false
    volScale.connect("button-press-event", () => { volSeeking = true; return false })
    volScale.connect("button-release-event", () => {
        const p = currentPlayer
        if (p) p.volume = volScale.get_value()
        volSeeking = false
        return false
    })
    const volRow = new Gtk.Box({ spacing: 8 })
    volRow.add(volIcon); volRow.add(volScale)

    // ── Selected player + signal management ──────────────────────────
    const selected = Variable<Mpris.Player | null>(null)
    let currentPlayer: Mpris.Player | null = null
    const playerSignals: number[] = []

    function disconnectPlayer() {
        if (!currentPlayer) return
        for (const id of playerSignals) currentPlayer.disconnect(id)
        playerSignals.length = 0
        currentPlayer = null
    }

    function refreshTrack() {
        const p = currentPlayer
        if (!p) {
            titleLabel.label = ""
            artistLabel.label = ""
            albumLabel.label = ""
            art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)
            return
        }
        titleLabel.label = p.title || "Unknown title"
        artistLabel.label = p.artist || ""
        albumLabel.label = p.album || ""
        const cover = p.coverArt
        if (cover) art.set_from_file(cover)
        else art.set_from_icon_name("audio-x-generic", Gtk.IconSize.DIALOG)
    }
    function refreshPlay() {
        const playing = currentPlayer?.playbackStatus === Mpris.PlaybackStatus.PLAYING
        playLbl.label = playing ? ICON.pause : ICON.play
    }
    function refreshPosition() {
        const p = currentPlayer
        if (!p) {
            positionLabel.label = "0:00"
            lengthLabel.label = "—:—"
            seekScale.set_sensitive(false)
            return
        }
        const len = p.length
        positionLabel.label = fmtTime(p.position)
        lengthLabel.label = len > 0 ? fmtTime(len) : "—:—"
        if (!seeking) {
            seekScale.set_range(0, Math.max(1, len))
            seekScale.set_value(Math.max(0, p.position))
        }
        seekScale.set_sensitive(p.canSeek && len > 0)
    }
    function refreshVolume() {
        if (!currentPlayer) { volScale.set_value(0); return }
        if (!volSeeking) volScale.set_value(currentPlayer.volume)
    }
    function refreshXportSensitivity() {
        const p = currentPlayer
        prevBtn.set_sensitive(!!p?.canGoPrevious)
        nextBtn.set_sensitive(!!p?.canGoNext)
        playBtn.set_sensitive(!!p?.canControl)
    }

    function attachPlayer(p: Mpris.Player | null) {
        disconnectPlayer()
        currentPlayer = p
        const watch = (prop: string, fn: () => void) => {
            if (!p) return
            playerSignals.push(p.connect(`notify::${prop}`, fn))
        }
        watch("title", refreshTrack)
        watch("artist", refreshTrack)
        watch("album", refreshTrack)
        watch("cover-art", refreshTrack)
        watch("playback-status", refreshPlay)
        watch("position", refreshPosition)
        watch("length", refreshPosition)
        watch("can-seek", refreshPosition)
        watch("volume", refreshVolume)
        watch("can-go-previous", refreshXportSensitivity)
        watch("can-go-next", refreshXportSensitivity)
        watch("can-control", refreshXportSensitivity)
        refreshTrack(); refreshPlay(); refreshPosition()
        refreshVolume(); refreshXportSensitivity()
    }
    selected.subscribe(attachPlayer)

    // ── Tabs ─────────────────────────────────────────────────────────
    function rebuildTabs() {
        for (const c of tabsBox.get_children()) tabsBox.remove(c)
        const players = mpris.players
        if (players.length === 0) {
            const lbl = new Gtk.Label({ label: "No active media players" })
            lbl.get_style_context().add_class("NPTabEmpty")
            tabsBox.add(lbl)
        } else {
            const cur = selected.get()
            for (const p of players) {
                const btn = new Gtk.Button()
                const inner = new Gtk.Box({ spacing: 4 })
                const glyph = new Gtk.Label({ label: ICON.music })
                const name = new Gtk.Label({
                    label: p.identity || p.busName || "player",
                    max_width_chars: 14, ellipsize: 3,
                })
                inner.add(glyph); inner.add(name)
                btn.add(inner)
                btn.get_style_context().add_class("NPTab")
                if (p === cur) btn.get_style_context().add_class("Selected")
                btn.connect("clicked", () => { selected.set(p); rebuildTabs() })
                tabsBox.add(btn)
            }
        }
        tabsBox.show_all()
    }

    mpris.connect("notify::players", () => {
        const players = mpris.players
        const cur = selected.get()
        if (!cur || !players.includes(cur)) selected.set(players[0] ?? null)
        rebuildTabs()
    })
    selected.set(mpris.players[0] ?? null)
    rebuildTabs()

    // ── Make sure raw Gtk widgets are visible inside JSX. ────────────
    topRow.show_all()
    seekScale.show()
    timeRow.show_all()
    xportRow.show_all()
    volRow.show_all()

    // ── Position ticker (1Hz while popup is visible) ─────────────────
    let timer: any = null

    return <window
        name="now-playing"
        className="NowPlayingWindow"
        application={App}
        visible={false}
        keymode={Astal.Keymode.ON_DEMAND}
        exclusivity={Astal.Exclusivity.IGNORE}
        anchor={TOP | BOTTOM | LEFT | RIGHT}
        layer={Astal.Layer.OVERLAY}
        onShow={() => {
            if (!timer) timer = interval(1000, refreshPosition)
        }}
        onHide={() => { if (timer) { timer.cancel(); timer = null } }}
        onKeyPressEvent={(self, ev) => {
            if (ev.get_keyval()[1] === 0xff1b /* Esc */) self.hide()
        }}>
        <eventbox hexpand vexpand onButtonPressEvent={(self) => {
            const w = self.get_ancestor(Astal.Window.$gtype) as Astal.Window
            w?.hide()
            return true
        }}>
            <box halign={Gtk.Align.START} valign={Gtk.Align.END}>
                <eventbox onButtonPressEvent={() => true}>
                    <box className="NowPlayingPanel" vertical spacing={12}
                        widthRequest={PANEL_WIDTH}>
                        {tabsBox}
                        {topRow}
                        {seekScale}
                        {timeRow}
                        {xportRow}
                        {volRow}
                    </box>
                </eventbox>
            </box>
        </eventbox>
    </window>
}
