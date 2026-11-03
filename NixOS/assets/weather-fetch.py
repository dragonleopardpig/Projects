#!/usr/bin/env python3
"""Fetch wttr.in JSON and emit a slim shape the AGS popup can render.

Usage: weather-fetch.py [--bar] [city]
Default city: Singapore.  --bar prints only the bar's one line ("glyph +31°C").

When wttr.in cannot be reached -- it refused every connection on 2026-11-03 --
the same shape comes from Open-Meteo (free, no key), its WMO codes mapped to
the same glyphs.

Glyphs are plain Unicode weather emoji so they render correctly in any
font without needing Nerd Font's weather extension.
"""
import json
import sys
import urllib.request

ARGS = [a for a in sys.argv[1:] if a != "--bar"]
BAR = "--bar" in sys.argv[1:]
CITY = ARGS[0] if ARGS else "Singapore"

# wttr.in weather code -> Unicode weather emoji.
# Codes: https://github.com/chubin/wttr.in/blob/master/lib/constants.py
CODE_GLYPH = {
    "113": "☀️",   # sunny / clear
    "116": "⛅",   # partly cloudy
    "119": "☁️",   # cloudy
    "122": "☁️",   # overcast
    "143": "🌫️",   # mist
    "176": "🌦️",   # patchy rain nearby
    "179": "🌨️",   # patchy sleet
    "182": "🌨️",   # patchy sleet
    "185": "🌧️",   # patchy freezing drizzle
    "200": "⛈️",   # thundery outbreaks
    "227": "❄️",   # blowing snow
    "230": "❄️",   # blizzard
    "248": "🌫️",   # fog
    "260": "🌫️",   # freezing fog
    "263": "🌦️",   # patchy light drizzle
    "266": "🌧️",   # light drizzle
    "281": "🌧️",   # freezing drizzle
    "284": "🌧️",   # heavy freezing drizzle
    "293": "🌦️",   # patchy light rain
    "296": "🌧️",   # light rain
    "299": "🌧️",   # moderate rain at times
    "302": "🌧️",   # moderate rain
    "305": "🌧️",   # heavy rain at times
    "308": "🌧️",   # heavy rain
    "311": "🌧️",   # light freezing rain
    "314": "🌧️",   # mod/hvy freezing rain
    "317": "🌨️",   # light sleet
    "320": "🌨️",   # mod/hvy sleet
    "323": "🌨️",   # patchy light snow
    "326": "🌨️",   # light snow
    "329": "🌨️",   # patchy mod snow
    "332": "🌨️",   # mod snow
    "335": "❄️",   # patchy heavy snow
    "338": "❄️",   # heavy snow
    "350": "🌨️",   # ice pellets
    "353": "🌦️",   # light rain shower
    "356": "🌧️",   # mod/hvy rain shower
    "359": "🌧️",   # torrential rain shower
    "362": "🌨️",   # light sleet showers
    "365": "🌨️",   # mod/hvy sleet showers
    "368": "🌨️",   # light snow showers
    "371": "🌨️",   # mod/hvy snow showers
    "374": "🌨️",   # light ice pellet showers
    "377": "🌨️",   # mod/hvy ice pellet showers
    "386": "⛈️",   # patchy light rain in thunder
    "389": "⛈️",   # mod/hvy rain in thunder
    "392": "⛈️",   # patchy light snow in thunder
    "395": "⛈️",   # mod/hvy snow in thunder
}

def glyph_for(code: str) -> str:
    return CODE_GLYPH.get(code, "🌡️")

def fmt_date(iso: str) -> str:
    import datetime
    d = datetime.date.fromisoformat(iso)
    today = datetime.date.today()
    if d == today:
        return "Today"
    if (d - today).days == 1:
        return "Tomorrow"
    return d.strftime("%a %b %d")

# WMO weather code (Open-Meteo) -> (glyph, description).
WMO = {
    0: ("☀️", "Clear sky"), 1: ("🌤️", "Mainly clear"), 2: ("⛅", "Partly cloudy"),
    3: ("☁️", "Overcast"), 45: ("🌫️", "Fog"), 48: ("🌫️", "Rime fog"),
    51: ("🌦️", "Light drizzle"), 53: ("🌧️", "Drizzle"), 55: ("🌧️", "Dense drizzle"),
    56: ("🌧️", "Freezing drizzle"), 57: ("🌧️", "Dense freezing drizzle"),
    61: ("🌦️", "Light rain"), 63: ("🌧️", "Rain"), 65: ("🌧️", "Heavy rain"),
    66: ("🌧️", "Freezing rain"), 67: ("🌧️", "Heavy freezing rain"),
    71: ("🌨️", "Light snow"), 73: ("🌨️", "Snow"), 75: ("❄️", "Heavy snow"),
    77: ("🌨️", "Snow grains"), 80: ("🌦️", "Rain showers"), 81: ("🌧️", "Rain showers"),
    82: ("🌧️", "Violent rain showers"), 85: ("🌨️", "Snow showers"),
    86: ("❄️", "Heavy snow showers"), 95: ("⛈️", "Thunderstorm"),
    96: ("⛈️", "Thunderstorm, hail"), 99: ("⛈️", "Thunderstorm, heavy hail"),
}
COMPASS = ("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")


def get_json(url: str, timeout: float):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def clock(iso: str) -> str:
    """'2026-11-03T06:58' -> '06:58 AM', as wttr.in writes its times."""
    import datetime
    try:
        return datetime.datetime.fromisoformat(iso).strftime("%I:%M %p")
    except ValueError:
        return iso


def from_open_meteo(city: str) -> dict:
    """The popup's shape from Open-Meteo: the city found by its geocoder."""
    from urllib.parse import quote
    found = get_json("https://geocoding-api.open-meteo.com/v1/search?count=1&format=json"
                     f"&name={quote(city)}", 8).get("results") or []
    if not found:
        raise RuntimeError(f"no place called {city}")
    place = found[0]
    w = get_json(
        "https://api.open-meteo.com/v1/forecast"
        f"?latitude={place['latitude']}&longitude={place['longitude']}"
        "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
        "weather_code,wind_speed_10m,wind_direction_10m"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
        "&timezone=auto&forecast_days=3&wind_speed_unit=kmh", 8)
    cur, daily = w["current"], w["daily"]
    glyph, desc = WMO.get(int(cur["weather_code"]), ("🌡️", ""))
    return {
        "location": f"{place.get('name', city)}, {place.get('country', '')}",
        "current": {
            "temp_c":    str(round(cur["temperature_2m"])),
            "feels_c":   str(round(cur["apparent_temperature"])),
            "desc":      desc,
            "humidity":  str(round(cur["relative_humidity_2m"])),
            "wind_kmph": str(round(cur["wind_speed_10m"])),
            "wind_dir":  COMPASS[round(float(cur["wind_direction_10m"]) / 22.5) % 16],
            "code":      str(cur["weather_code"]),
            "glyph":     glyph,
            "observed":  clock(cur["time"]) + " (Open-Meteo)",
        },
        "forecast": [
            {
                "date":    fmt_date(day),
                "min_c":   str(round(daily["temperature_2m_min"][i])),
                "max_c":   str(round(daily["temperature_2m_max"][i])),
                "sunrise": clock(daily["sunrise"][i]),
                "sunset":  clock(daily["sunset"][i]),
                "desc":    WMO.get(int(daily["weather_code"][i]), ("", ""))[1],
                "code":    str(daily["weather_code"][i]),
                "glyph":   WMO.get(int(daily["weather_code"][i]), ("🌡️", ""))[0],
            }
            for i, day in enumerate(daily["time"][:3])
        ],
    }


def bar_line(out: dict) -> str:
    """The bar's label, as wttr.in's '%c+%t' reads: '☀️ +31°C'."""
    try:
        t = int(out["current"]["temp_c"])
    except (TypeError, ValueError):
        return out["current"]["glyph"]
    return f"{out['current']['glyph']} {'+' if t > 0 else ''}{t}°C"


try:
    data = get_json(f"https://wttr.in/{CITY}?format=j1", 6)
except Exception as first:
    try:
        out = from_open_meteo(CITY)
    except Exception as second:
        if BAR:
            sys.exit(1)
        print(json.dumps({"error": f"wttr.in: {first}; Open-Meteo: {second}"}))
        sys.exit(0)
    print(bar_line(out) if BAR else json.dumps(out, ensure_ascii=False))
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
print(bar_line(out) if BAR else json.dumps(out, ensure_ascii=False))
