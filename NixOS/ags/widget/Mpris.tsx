import { bind } from "astal"
import { Gtk } from "astal/gtk3"
import Mpris from "gi://AstalMpris"
import { ICON } from "../lib/icons"

export default function MprisWidget() {
    const mpris = Mpris.get_default()

    return <box
        className="Mpris"
        visible={bind(mpris, "players").as(ps => ps.length > 0)}>
        {bind(mpris, "players").as(players => {
            const p = players[0]
            if (!p) return <box />
            return <box spacing={4}>
                <button onClicked={() => p.play_pause()}>
                    <label label={bind(p, "playbackStatus").as(s =>
                        s === Mpris.PlaybackStatus.PLAYING ? ICON.pause : ICON.play
                    )} />
                </button>
                <label
                    label={bind(p, "title").as(t => t ?? "")}
                    maxWidthChars={28}
                    ellipsize={Gtk.PangoEllipsizeMode?.END ?? 3}
                />
            </box>
        })}
    </box>
}
