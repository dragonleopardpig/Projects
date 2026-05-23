#!/usr/bin/env python3
"""Waybar custom-module showing the lunar (Chinese) date for today,
with upcoming traditional festivals + 24 solar terms in the tooltip."""
import datetime
import html
import json
import sys

from lunarcalendar import Converter, Solar, zh_festivals, zh_solarterms

TIANGAN = "甲乙丙丁戊己庚辛壬癸"
DIZHI = "子丑寅卯辰巳午未申酉戌亥"
SHENGXIAO = "鼠牛虎兔龙蛇马羊猴鸡狗猪"

LUNAR_MONTH_NAMES = [
    "", "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
]
LUNAR_DAY_NAMES = [
    "",
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
]

# Only the traditional Chinese-calendar entries — modern Western/civic ones
# (情人节/劳动节/国庆节/etc) are skipped to avoid overlap with the holiday widget.
TRADITIONAL_FESTIVALS = {
    "腊八节", "除夕", "小年", "春节", "破五节", "元宵节", "龙抬头",
    "清明节", "端午节", "七夕节", "中元节", "中秋节", "重阳节", "寒衣节", "冬节",
}


def fmt_lunar_md(lunar):
    m = LUNAR_MONTH_NAMES[lunar.month]
    if lunar.isleap:
        m = "闰" + m
    return f"{m}月{LUNAR_DAY_NAMES[lunar.day]}"


def fmt_ganzhi_year(lunar_year):
    gan = TIANGAN[(lunar_year - 4) % 10]
    zhi = DIZHI[(lunar_year - 4) % 12]
    sx = SHENGXIAO[(lunar_year - 4) % 12]
    return f"{gan}{zhi}年", sx


def upcoming_events(today, years_ahead=2):
    events = []
    for y in range(today.year, today.year + years_ahead):
        for f in zh_festivals:
            name = f.get_lang("zh")
            if name not in TRADITIONAL_FESTIVALS:
                continue
            try:
                events.append((f(y), name, "festival"))
            except Exception:
                pass
        for st in zh_solarterms:
            try:
                events.append((st(y), st.get_lang("zh"), "solarterm"))
            except Exception:
                pass
    events.sort(key=lambda e: e[0])
    return events


def main():
    today = datetime.date.today()
    lunar = Converter.Solar2Lunar(Solar(today.year, today.month, today.day))
    md = fmt_lunar_md(lunar)
    ganzhi, shengxiao = fmt_ganzhi_year(lunar.year)

    # Bar text: keep it compact — Chinese month + day only.
    text = md

    events = upcoming_events(today)
    todays = [(d, n, k) for d, n, k in events if d == today]
    upcoming = [(d, n, k) for d, n, k in events if d > today][:8]

    lines = [f"<b>农历 {ganzhi} {md}</b>", f"生肖 {shengxiao}"]
    if todays:
        names = " / ".join(n for _, n, _ in todays)
        lines.append(f"今日: <b>{html.escape(names)}</b>")
    lines.append("")
    lines.append("<b>即将到来</b>")
    if not upcoming:
        lines.append("  (无)")
    for d, name, kind in upcoming:
        days = (d - today).days
        when = "明天" if days == 1 else f"{days}天后"
        icon = "" if kind == "solarterm" else ""  # nf-md-weather / nf-fa-star
        lines.append(
            f"  {icon}  {d:%a %d %b}  —  {html.escape(name)}  <i>({when})</i>"
        )

    print(json.dumps({
        "text": text,
        "tooltip": "\n".join(lines),
        "class": "lunar",
        "alt": "lunar",
    }))


if __name__ == "__main__":
    main()
