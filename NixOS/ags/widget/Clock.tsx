import { Variable } from "astal"

// `date` is cheap; polling once a second is fine.
const time = Variable("").poll(1000, "date +' %a %d %b  %H:%M'")

export default function Clock() {
    return <label className="Clock" label={time()} />
}
