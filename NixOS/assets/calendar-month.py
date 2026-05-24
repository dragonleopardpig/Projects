#!/usr/bin/env python3
"""Emit a 6×7 calendar grid for one month, with lunar dates + events.

argv[1]: YYYY-MM   (the month to render)
argv[2]: path to a directory of .ics files (Singapore public + school holidays)

stdout: JSON
{
  "year": 2026, "month": 5, "title": "May 2026",
  "weekdays": ["Mon","Tue",...,"Sun"],
  "cells": [
    {
      "date": "2026-04-27", "day": 27,
      "in_month": false, "is_today": false,
      "lunar": "三月初十",          # already-formatted Chinese lunar m+d
      "lunar_compact": "初十",       # day-only (for cells inside a known month)
      "lunar_first": false,          # true on day-1 of lunar month → show full
      "festival": null,              # e.g. "端午节"
      "solarterm": null,             # e.g. "芒种"
      "events": [
        {"title": "Labour Day", "category": "public"}
      ]
    },
    ...   # 42 entries: 6 weeks Mon-Sun
  ]
}
"""
import calendar
import datetime
import json
import re
import sys
from pathlib import Path

from lunarcalendar import Converter, Solar, zh_festivals, zh_solarterms

LUNAR_MONTH_NAMES = [
    "", "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
]
LUNAR_DAY_NAMES = [
    "",
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
]
TRADITIONAL_FESTIVALS = {
    "腊八节", "除夕", "小年", "春节", "破五节", "元宵节", "龙抬头",
    "清明节", "端午节", "七夕节", "中元节", "中秋节", "重阳节", "寒衣节", "冬节",
}


# ── lunar ──────────────────────────────────────────────────────────
def lunar_for(d):
    lun = Converter.Solar2Lunar(Solar(d.year, d.month, d.day))
    m = LUNAR_MONTH_NAMES[lun.month]
    if lun.isleap:
        m = "闰" + m
    day = LUNAR_DAY_NAMES[lun.day]
    first = (lun.day == 1)
    full = f"{m}月{day}"
    compact = f"{m}月" if first else day
    return full, compact, first


# ── .ics parsing (mirrors waybar-sg-holidays.py) ───────────────────
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
            cur["end_exclusive"] = datetime.date(int(d[0:4]), int(d[4:6]), int(d[6:8]))
        elif line.startswith("SUMMARY:"):
            cur["name"] = line.split(":", 1)[1]
    return events


def categorise(path):
    return "school" if "school" in path.name.lower() else "public"


def keep(event, category):
    if category == "public":
        return True
    return bool(re.search(r"school holiday", event["name"], re.IGNORECASE))


def load_events(cal_dir):
    all_ev = []
    for ics in sorted(cal_dir.glob("*.ics")):
        cat = categorise(ics)
        for e in parse_ics(ics):
            if not keep(e, cat):
                continue
            end_excl = e.get("end_exclusive", e["start"] + datetime.timedelta(days=1))
            last = end_excl - datetime.timedelta(days=1)
            all_ev.append({
                "start": e["start"], "last": last,
                "name": e["name"], "category": cat,
            })
    # Drop school events that duplicate a public one on the same start+name.
    pub_keys = {(e["start"], e["name"]) for e in all_ev if e["category"] == "public"}
    return [e for e in all_ev
            if not (e["category"] == "school" and (e["start"], e["name"]) in pub_keys)]


def events_for(d, all_ev):
    return [{"title": e["name"], "category": e["category"]}
            for e in all_ev if e["start"] <= d <= e["last"]]


# ── chinese festivals / solar terms for a given year ───────────────
def zh_events_for_year(y):
    """Return dict[date] = {'festival': name|None, 'solarterm': name|None}."""
    out = {}
    for f in zh_festivals:
        name = f.get_lang("zh")
        if name not in TRADITIONAL_FESTIVALS:
            continue
        try:
            d = f(y)
        except Exception:
            continue
        out.setdefault(d, {"festival": None, "solarterm": None})
        out[d]["festival"] = name
    for st in zh_solarterms:
        try:
            d = st(y)
        except Exception:
            continue
        out.setdefault(d, {"festival": None, "solarterm": None})
        out[d]["solarterm"] = st.get_lang("zh")
    return out


# ── main ────────────────────────────────────────────────────────────
def main():
    ym = sys.argv[1]            # "YYYY-MM"
    cal_dir = Path(sys.argv[2])
    y, m = int(ym[:4]), int(ym[5:7])
    today = datetime.date.today()

    # First Monday on or before day 1, then 6 weeks = 42 days.
    first = datetime.date(y, m, 1)
    start = first - datetime.timedelta(days=first.weekday())   # Monday-anchored

    events = load_events(cal_dir)
    zh_cache = {}
    for yr in {start.year, (start + datetime.timedelta(days=41)).year}:
        zh_cache[yr] = zh_events_for_year(yr)

    cells = []
    for i in range(42):
        d = start + datetime.timedelta(days=i)
        full, compact, lfirst = lunar_for(d)
        zh = zh_cache[d.year].get(d, {"festival": None, "solarterm": None})
        cells.append({
            "date": d.isoformat(),
            "day": d.day,
            "in_month": (d.month == m),
            "is_today": (d == today),
            "lunar": full,
            "lunar_compact": compact,
            "lunar_first": lfirst,
            "festival": zh["festival"],
            "solarterm": zh["solarterm"],
            "events": events_for(d, events),
        })

    print(json.dumps({
        "year": y, "month": m,
        "title": f"{calendar.month_name[m]} {y}",
        "weekdays": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "cells": cells,
    }))


if __name__ == "__main__":
    main()
