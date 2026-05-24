#!/usr/bin/env python3
"""Fetch wttr.in JSON and emit a slim shape the AGS popup can render.

Usage: weather-fetch.py [city]
Default city: Singapore.
"""
import json
import sys
import urllib.request

CITY = sys.argv[1] if len(sys.argv) > 1 else "Singapore"

# wttr.in code -> Nerd Font weather glyph
CODE_GLYPH = {
    "113": "",  # sunny -> weather-day-sunny
    "116": "",  # partly cloudy -> day-cloudy
    "119": "",  # cloudy
    "122": "",  # overcast
    "143": "",  # mist -> day-fog
    "176": "",  # patchy rain -> day-showers
    "179": "",  # patchy sleet
    "182": "",  # patchy sleet
    "185": "",  # patchy freezing drizzle
    "200": "",  # thundery outbreaks
    "227": "",  # blowing snow
    "230": "",  # blizzard
    "248": "",  # fog
    "260": "",  # freezing fog
    "263": "",  # patchy light drizzle
    "266": "",  # light drizzle
    "281": "",  # freezing drizzle
    "284": "",  # heavy freezing drizzle
    "293": "",  # patchy light rain
    "296": "",  # light rain
    "299": "",  # moderate rain at times
    "302": "",  # moderate rain
    "305": "",  # heavy rain at times
    "308": "",  # heavy rain
    "311": "",  # light freezing rain
    "314": "",  # mod/hvy freezing rain
    "317": "",  # light sleet
    "320": "",  # mod/hvy sleet
    "323": "",  # patchy light snow
    "326": "",  # light snow
    "329": "",  # patchy mod snow
    "332": "",  # mod snow
    "335": "",  # patchy heavy snow
    "338": "",  # heavy snow
    "350": "",  # ice pellets
    "353": "",  # light rain shower
    "356": "",  # mod/hvy rain shower
    "359": "",  # torrential rain shower
    "362": "",  # light sleet showers
    "365": "",  # mod/hvy sleet showers
    "368": "",  # light snow showers
    "371": "",  # mod/hvy snow showers
    "374": "",  # light ice pellet showers
    "377": "",  # mod/hvy ice pellet showers
    "386": "",  # patchy light rain in thunder
    "389": "",  # mod/hvy rain in thunder
    "392": "",  # patchy light snow in thunder
    "395": "",  # mod/hvy snow in thunder
}

def glyph_for(code: str) -> str:
    return CODE_GLYPH.get(code, "")  # day-cloudy-windy fallback

def fmt_date(iso: str) -> str:
    # iso like "2026-05-24"
    import datetime
    d = datetime.date.fromisoformat(iso)
    today = datetime.date.today()
    if d == today:
        return "Today"
    if (d - today).days == 1:
        return "Tomorrow"
    return d.strftime("%a %b %d")

try:
    url = f"https://wttr.in/{CITY}?format=j1"
    with urllib.request.urlopen(url, timeout=8) as resp:
        data = json.loads(resp.read().decode("utf-8"))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

cur = (data.get("current_condition") or [{}])[0]
area = (data.get("nearest_area") or [{}])[0]
weather_days = data.get("weather") or []

out = {
    "location": (area.get("areaName") or [{}])[0].get("value", CITY)
                + ", "
                + (area.get("country") or [{}])[0].get("value", ""),
    "current": {
        "temp_c":     cur.get("temp_C"),
        "feels_c":    cur.get("FeelsLikeC"),
        "desc":       (cur.get("weatherDesc") or [{}])[0].get("value", ""),
        "humidity":   cur.get("humidity"),
        "wind_kmph":  cur.get("windspeedKmph"),
        "wind_dir":   cur.get("winddir16Point"),
        "code":       cur.get("weatherCode", ""),
        "glyph":      glyph_for(cur.get("weatherCode", "")),
        "observed":   cur.get("observation_time"),
    },
    "forecast": [
        {
            "date":     fmt_date(d.get("date", "")),
            "min_c":    d.get("mintempC"),
            "max_c":    d.get("maxtempC"),
            "sunrise":  (d.get("astronomy") or [{}])[0].get("sunrise"),
            "sunset":   (d.get("astronomy") or [{}])[0].get("sunset"),
            # Noon condition (4th hourly entry of 8) — best summary of the day.
            "desc":     ((d.get("hourly") or [{}, {}, {}, {}])[4]
                         .get("weatherDesc") or [{}])[0].get("value", ""),
            "code":     ((d.get("hourly") or [{}, {}, {}, {}])[4]
                         .get("weatherCode", "")),
            "glyph":    glyph_for(((d.get("hourly") or [{}, {}, {}, {}])[4]
                                   .get("weatherCode", ""))),
        }
        for d in weather_days[:3]
    ],
}
print(json.dumps(out))
