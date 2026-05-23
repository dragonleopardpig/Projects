import { bind } from "astal"
import Wp from "gi://AstalWp"

export default function Audio() {
    const wp = Wp.get_default()
    const speaker = wp?.audio?.defaultSpeaker
    if (!speaker) return <box />

    return <box className="Audio">
        <label
            label={bind(speaker, "volume").as(v => ` ${Math.round(v * 100)}%`)}
        />
    </box>
}
