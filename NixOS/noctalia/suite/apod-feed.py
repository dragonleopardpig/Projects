"""Convert NASA's APOD RSS item to the fields used by the daily downloader."""

from email.utils import parsedate_to_datetime
import json
import sys
from urllib.parse import urlsplit
from xml.etree import ElementTree


APOD_NS = "{https://science.nasa.gov/apod/}"
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".webp", ".gif")


def main() -> None:
    item = ElementTree.parse(sys.stdin).find("./channel/item")
    if item is None:
        raise SystemExit("NASA APOD feed has no items")

    date = parsedate_to_datetime(item.findtext("pubDate", "")).date().isoformat()
    for field in ("hdurl", "thumbnail_url"):
        url = item.findtext(APOD_NS + field, "")
        if urlsplit(url).path.lower().endswith(IMAGE_SUFFIXES):
            print(json.dumps({"date": date, "media_type": "image", "hdurl": url}))
            return
    raise SystemExit("NASA APOD feed item has no still image")


if __name__ == "__main__":
    main()
