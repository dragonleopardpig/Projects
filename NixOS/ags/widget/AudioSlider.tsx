import { bind } from "astal"
import Wp from "gi://AstalWp"
import { ICON } from "../lib/icons"

export default function AudioSlider() {
    const wp = Wp.get_default()
    const speaker = wp?.audio?.defaultSpeaker
    if (!speaker) return <box />

    return <box className="AudioSlider" spacing={4}>
        <button
            onClicked={() => speaker.set_mute(!speaker.mute)}
            tooltipText="Mute / unmute">
            <label label={bind(speaker, "mute").as(m => m ? ICON.mute : ICON.speaker)} />
        </button>
        <slider
            widthRequest={100}
            value={bind(speaker, "volume")}
            onDragged={({ value }) => speaker.set_volume(value)}
        />
        <label label={bind(speaker, "volume").as(v => `${Math.round(v * 100)}%`)} />
    </box>
}
