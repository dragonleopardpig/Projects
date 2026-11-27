#!/usr/bin/env python3
"""Fetch, enrich, and install Singapore Public Holidays (.ics) from MOM."""

from __future__ import annotations

import argparse
import datetime
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.error
import urllib.request

MOM_ICS_URL = (
    "https://www.mom.gov.sg/-/media/mom/documents/employment-practices/"
    "public-holidays/public-holidays-sg-{year}.ics"
)
DEFAULT_LIVE_DIR = Path(
    os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share"
) / "noctalia-suite" / "calendars" / "sg-holidays"
DEFAULT_REPO_DIR = Path("/home/thinky/Projects/NixOS/noctalia/suite/calendars/sg-holidays")
DEFAULT_LEGACY_DIR = Path("/home/thinky/Projects/NixOS/assets/calendars")
DISPLAYNAME = "Singapore Public Holidays\n"
IN_LIEU_SUFFIX = " (in lieu)"
IN_LIEU_UID_DOMAIN = "sg-holidays-update"


class HolidayFetchError(RuntimeError):
    """Raised when downloading or validating an ICS feed fails."""


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Do not follow HTTP 302 redirects (MOM redirects unpublished years to HTML)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "holiday"


def unfold_ics_lines(raw_text: str) -> list[str]:
    """Unfold RFC 5545 folded lines (CRLF/LF followed by single space/tab)."""
    normalized = raw_text.replace("\r\n", "\n").replace("\r", "\n")
    lines: list[str] = []
    for line in normalized.split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def parse_vevents(raw_text: str) -> list[dict[str, object]]:
    """Parse VEVENT blocks from an ICS string."""
    lines = unfold_ics_lines(raw_text)
    if not any(line.strip() == "BEGIN:VCALENDAR" for line in lines) or not any(
        line.strip() == "END:VCALENDAR" for line in lines
    ):
        raise HolidayFetchError("missing VCALENDAR wrapper")

    events: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    for line in lines:
        stripped = line.strip()
        if stripped == "BEGIN:VEVENT":
            current = {}
            continue
        if stripped == "END:VEVENT":
            if current is not None and "start" in current and "summary" in current:
                events.append(current)
            current = None
            continue
        if current is None or ":" not in stripped:
            continue
        key_part, value = stripped.split(":", 1)
        prop_name = key_part.split(";", 1)[0].upper()
        if prop_name == "DTSTART":
            m = re.match(r"^(\d{4})(\d{2})(\d{2})", value.strip())
            if m:
                current["start"] = datetime.date(
                    int(m.group(1)), int(m.group(2)), int(m.group(3))
                )
        elif prop_name == "DTEND":
            m = re.match(r"^(\d{4})(\d{2})(\d{2})", value.strip())
            if m:
                current["end"] = datetime.date(
                    int(m.group(1)), int(m.group(2)), int(m.group(3))
                )
        elif prop_name == "SUMMARY":
            current["summary"] = value.strip()
        elif prop_name == "UID":
            current["uid"] = value.strip()
    return events


def validate_ics(raw_text: str, year: int) -> list[dict[str, object]]:
    """Validate that raw_text is a genuine ICS calendar for the given year."""
    events = parse_vevents(raw_text)
    year_events = [
        ev for ev in events if isinstance(ev.get("start"), datetime.date) and ev["start"].year == year
    ]
    if len(year_events) < 8:
        raise HolidayFetchError(
            f"expected at least 8 holiday events in {year}, got {len(year_events)}"
        )
    return events


def enrich_in_lieu(raw_text: str, year: int) -> tuple[str, int]:
    """Append statutory Singapore Sunday-in-lieu VEVENTs when not already present.

    Under Singapore's Holidays Act, when a public holiday falls on a Sunday,
    the following Monday (or the next non-holiday weekday if consecutive holidays
    cover Monday) is a public holiday in lieu.
    """
    events = validate_ics(raw_text, year)
    occupied: set[datetime.date] = set()
    existing_uids: set[str] = set()
    existing_in_lieu_dates: set[datetime.date] = set()

    for ev in events:
        start = ev["start"]
        assert isinstance(start, datetime.date)
        end = ev.get("end")
        if not isinstance(end, datetime.date) or end <= start:
            end = start + datetime.timedelta(days=1)
        uid = str(ev.get("uid", ""))
        if uid:
            existing_uids.add(uid)
        summary = str(ev.get("summary", ""))
        if IN_LIEU_SUFFIX.strip().lower() in summary.lower():
            existing_in_lieu_dates.add(start)
            continue
        cur = start
        while cur < end:
            occupied.add(cur)
            cur += datetime.timedelta(days=1)

    new_blocks: list[str] = []
    # Process chronologically so consecutive holidays advance the in-lieu day deterministically.
    sorted_events = sorted(
        (ev for ev in events if isinstance(ev.get("start"), datetime.date) and ev["start"].year == year),
        key=lambda ev: ev["start"],  # type: ignore[arg-type]
    )
    for ev in sorted_events:
        start = ev["start"]
        assert isinstance(start, datetime.date)
        end = ev.get("end")
        if not isinstance(end, datetime.date) or end <= start:
            end = start + datetime.timedelta(days=1)
        if (end - start).days != 1:
            continue
        if start.weekday() != 6:  # 6 == Sunday
            continue
        summary = str(ev["summary"])
        if IN_LIEU_SUFFIX.strip().lower() in summary.lower():
            continue

        candidate = start + datetime.timedelta(days=1)
        while candidate in occupied:
            candidate += datetime.timedelta(days=1)

        uid = f"{candidate:%Y%m%d}-{slugify(summary)}-in-lieu@{IN_LIEU_UID_DOMAIN}"
        if uid in existing_uids or candidate in existing_in_lieu_dates:
            occupied.add(candidate)
            continue

        occupied.add(candidate)
        existing_uids.add(uid)
        existing_in_lieu_dates.add(candidate)
        next_day = candidate + datetime.timedelta(days=1)
        new_blocks.append(
            "\n".join(
                [
                    "BEGIN:VEVENT",
                    f"DTSTART;VALUE=DATE:{candidate:%Y%m%d}",
                    f"DTEND;VALUE=DATE:{next_day:%Y%m%d}",
                    "LOCATION:",
                    f"UID:{uid}",
                    "SEQUENCE:0",
                    "DESCRIPTION:Public holiday in lieu (Singapore Holidays Act)",
                    "STATUS:CONFIRMED",
                    f"SUMMARY:{summary}{IN_LIEU_SUFFIX}",
                    "END:VEVENT",
                ]
            )
        )

    normalized = raw_text.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n")
    if new_blocks:
        idx = normalized.rfind("END:VCALENDAR")
        prefix = normalized[:idx].rstrip("\n")
        suffix = normalized[idx:]
        normalized = prefix + "\n\n" + "\n\n".join(new_blocks) + "\n" + suffix
    return normalized + "\n", len(new_blocks)


def fetch_mom_ics(year: int, timeout: float = 15.0) -> str:
    """Fetch official Singapore Public Holidays ICS from MOM for `year`."""
    url = MOM_ICS_URL.format(year=year)
    opener = urllib.request.build_opener(NoRedirectHandler())
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "sg-holidays-update/1.0 (+https://www.mom.gov.sg)",
            "Accept": "text/calendar, */*;q=0.5",
        },
    )
    try:
        with opener.open(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise HolidayFetchError(f"MOM returned HTTP {resp.status} for {year}")
            raw_bytes = resp.read()
    except urllib.error.HTTPError as err:
        if err.code in (301, 302, 303, 307, 308, 404):
            raise HolidayFetchError(
                f"MOM has not published {year} holidays yet (HTTP {err.code})"
            ) from err
        raise HolidayFetchError(f"HTTP error fetching {year}: {err.code} {err.reason}") from err
    except urllib.error.URLError as err:
        raise HolidayFetchError(f"Network error fetching {year}: {err.reason}") from err

    return raw_bytes.decode("utf-8", errors="replace")


def atomic_write_text(path: Path, content: str) -> None:
    """Atomically write `content` to `path`, replacing any existing file or symlink."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def ensure_displayname(target_dir: Path) -> None:
    target_dir.mkdir(parents=True, exist_ok=True)
    dn = target_dir / "displayname"
    if not dn.exists():
        atomic_write_text(dn, DISPLAYNAME)


def list_installed(live_dir: Path) -> int:
    if not live_dir.is_dir():
        print(f"No holiday directory at {live_dir}")
        return 0
    files = sorted(live_dir.glob("*.ics"))
    if not files:
        print(f"No .ics files in {live_dir}")
        return 0
    for ics in files:
        try:
            events = parse_vevents(ics.read_text(encoding="utf-8", errors="replace"))
        except HolidayFetchError as err:
            print(f"{ics.name}: invalid ({err})")
            continue
        events.sort(key=lambda e: e["start"])  # type: ignore[arg-type]
        tag = "symlink" if ics.is_symlink() else "file"
        print(f"{ics.name} ({tag}, {len(events)} events):")
        for ev in events:
            d = ev["start"]
            assert isinstance(d, datetime.date)
            print(f"  {d:%Y-%m-%d (%a)}  {ev['summary']}")
    return 0


def check_availability(years: list[int]) -> int:
    ok = True
    for year in years:
        try:
            raw = fetch_mom_ics(year)
            events = validate_ics(raw, year)
            print(f"{year}: available from MOM ({len(events)} events)")
        except HolidayFetchError as err:
            print(f"{year}: unavailable ({err})")
            ok = False
    return 0 if ok else 1


def resolve_repo_dir(arg: str | None) -> Path | None:
    if arg is not None:
        return Path(arg).expanduser()
    if DEFAULT_REPO_DIR.parent.parent.is_dir():
        return DEFAULT_REPO_DIR
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "years",
        nargs="*",
        type=int,
        help="Years to fetch/install (default: current year and next year)",
    )
    parser.add_argument(
        "--live-dir",
        type=Path,
        default=DEFAULT_LIVE_DIR,
        help="Live Noctalia vdir folder (default: %(default)s)",
    )
    parser.add_argument(
        "--repo-dir",
        default=None,
        help="Optional NixOS repo holiday directory to keep in sync",
    )
    parser.add_argument(
        "--legacy-dir",
        type=Path,
        default=DEFAULT_LEGACY_DIR,
        help="Optional legacy assets/calendars directory to mirror into when updating repo",
    )
    parser.add_argument(
        "--from-file",
        type=Path,
        default=None,
        help="Import a locally downloaded MOM .ics file instead of fetching online (requires 1 YEAR)",
    )
    parser.add_argument(
        "--live-only",
        action="store_true",
        help="Only write to --live-dir; do not update the NixOS git repo",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download and overwrite existing files/symlinks",
    )
    parser.add_argument(
        "--no-in-lieu",
        action="store_true",
        help="Do not append statutory Monday-in-lieu events for Sunday holidays",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check whether MOM has published the requested year(s) without writing files",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List installed holiday files and dates in --live-dir",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress informational output and ignore unpublished future years in auto mode",
    )
    args = parser.parse_args(argv)

    live_dir = args.live_dir.expanduser()
    if args.list:
        return list_installed(live_dir)

    today_year = datetime.date.today().year
    explicit_years = bool(args.years)
    years = args.years if explicit_years else [today_year, today_year + 1]

    if args.check:
        return check_availability(years)

    if args.from_file is not None:
        if len(years) != 1 or not explicit_years:
            parser.error("--from-file requires exactly one explicit YEAR argument")
        if not args.from_file.is_file():
            print(f"error: file not found: {args.from_file}", file=sys.stderr)
            return 1

    repo_dir = None if args.live_only else resolve_repo_dir(args.repo_dir)
    repo_updated = False
    failures = 0

    for year in years:
        filename = f"sg-holidays-{year}.ics"
        live_target = live_dir / filename
        repo_target = repo_dir / filename if repo_dir is not None else None

        need_live = args.force or not live_target.exists()
        need_repo = repo_target is not None and (args.force or not repo_target.exists())

        if not need_live and not need_repo:
            if not args.quiet:
                print(f"{year}: already installed ({live_target})")
            continue

        try:
            if args.from_file is not None:
                raw_text = args.from_file.read_text(encoding="utf-8", errors="replace")
            else:
                raw_text = fetch_mom_ics(year)

            if args.no_in_lieu:
                validate_ics(raw_text, year)
                final_text = raw_text.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n") + "\n"
                added_in_lieu = 0
            else:
                final_text, added_in_lieu = enrich_in_lieu(raw_text, year)
        except HolidayFetchError as err:
            # In automatic timer mode (--quiet without explicit years), an unpublished
            # future year is expected and should not fail the systemd unit.
            if args.quiet and not explicit_years and year > today_year:
                continue
            print(f"{year}: {err}", file=sys.stderr)
            failures += 1
            continue

        if need_live:
            ensure_displayname(live_dir)
            atomic_write_text(live_target, final_text)
            if not args.quiet:
                print(
                    f"{year}: installed {live_target} (+{added_in_lieu} in-lieu)"
                )

        if repo_target is not None and need_repo:
            ensure_displayname(repo_dir)  # type: ignore[arg-type]
            if not repo_target.exists() or repo_target.read_text(encoding="utf-8", errors="replace") != final_text:
                atomic_write_text(repo_target, final_text)
                repo_updated = True
                if not args.quiet:
                    print(f"{year}: updated {repo_target}")
            if args.legacy_dir and args.legacy_dir.is_dir():
                legacy_target = args.legacy_dir / filename
                if not legacy_target.exists() or args.force:
                    atomic_write_text(legacy_target, final_text)
                    if not args.quiet:
                        print(f"{year}: mirrored {legacy_target}")

    if repo_updated and not args.quiet:
        print(
            "Repo files updated. Commit and push in /home/thinky/Projects/NixOS "
            "to distribute to all hosts."
        )

    return 1 if failures > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
