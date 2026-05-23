#!/usr/bin/env python3
import datetime
import html
import json
import re
import sys
from pathlib import Path

ICON_PUBLIC = ""  # nf-fa-calendar
ICON_SCHOOL = ""  # nf-fa-graduation_cap


def parse_ics(path):
    events = []
    cur = {}
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line == "BEGIN:VEVENT":
            cur = {}
        elif line == "END:VEVENT":
            if "start" in cur and "name" in cur:
                events.append(cur)
        elif line.startswith("DTSTART;VALUE=DATE:"):
            d = line.split(":", 1)[1]
            cur["start"] = datetime.date(int(d[0:4]), int(d[4:6]), int(d[6:8]))
        elif line.startswith("DTEND;VALUE=DATE:"):
            d = line.split(":", 1)[1]
            # DTEND is exclusive in iCal — last actual day is end - 1
            cur["end_exclusive"] = datetime.date(int(d[0:4]), int(d[4:6]), int(d[6:8]))
        elif line.startswith("SUMMARY:"):
            cur["name"] = line.split(":", 1)[1]
    return events


def categorise(path):
    return "school" if "school" in path.name.lower() else "public"


def keep(event, category):
    name = event["name"]
    if category == "public":
        return True
    # School calendar: keep only school-holiday weeks (Term N holidays + ad-hoc days).
    return bool(re.search(r"school holiday", name, re.IGNORECASE))


def main():
    cal_dir = Path(sys.argv[1])
    today = datetime.date.today()

    all_events = []
    for ics in sorted(cal_dir.glob("*.ics")):
        category = categorise(ics)
        for e in parse_ics(ics):
            if not keep(e, category):
                continue
            e["category"] = category
            end_excl = e.get("end_exclusive", e["start"] + datetime.timedelta(days=1))
            e["last"] = end_excl - datetime.timedelta(days=1)
            all_events.append(e)

    # Dedupe: if a school event overlaps a public event on the same start+name,
    # drop the school one (public takes priority).
    public_keys = {(e["start"], e["name"]) for e in all_events if e["category"] == "public"}
    all_events = [
        e for e in all_events
        if not (e["category"] == "school" and (e["start"], e["name"]) in public_keys)
    ]

    all_events.sort(key=lambda e: (e["start"], 0 if e["category"] == "public" else 1))

    # An event is "active today" if today is between start and last (inclusive).
    today_ev = next(
        (e for e in all_events if e["start"] <= today <= e["last"]),
        None,
    )
    upcoming = [e for e in all_events if e["last"] >= today][:8]

    def icon(cat):
        return ICON_PUBLIC if cat == "public" else ICON_SCHOOL

    if today_ev:
        text = f"{icon(today_ev['category'])} {today_ev['name']}"
        cls = "today" if today_ev["category"] == "public" else "school-today"
    elif upcoming:
        nxt = upcoming[0]
        days = (nxt["start"] - today).days
        text = f"{icon(nxt['category'])} {nxt['name']} ({days}d)"
        cls = "upcoming" if nxt["category"] == "public" else "school-upcoming"
    else:
        text = ""
        cls = "none"

    lines = ["<b>Singapore Calendars</b>"]
    if not upcoming:
        lines.append("  (no upcoming events)")
    for e in upcoming:
        days = (e["start"] - today).days
        if e["start"] <= today <= e["last"]:
            when = "now"
        elif days == 1:
            when = "tomorrow"
        else:
            when = f"in {days}d"
        if e["last"] != e["start"]:
            date_str = f"{e['start']:%a %d %b} – {e['last']:%a %d %b}"
        else:
            date_str = f"{e['start']:%a %d %b}"
        lines.append(
            f"  {icon(e['category'])}  {html.escape(date_str)}  —  "
            f"{html.escape(e['name'])}  <i>({html.escape(when)})</i>"
        )

    print(json.dumps({
        "text": text,
        "tooltip": "\n".join(lines),
        "class": cls,
        "alt": cls,
    }))


if __name__ == "__main__":
    main()
