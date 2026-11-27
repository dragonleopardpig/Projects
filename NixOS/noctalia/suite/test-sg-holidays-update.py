#!/usr/bin/env python3
"""Unit tests for sg-holidays-update.py."""

from __future__ import annotations

import datetime
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPT_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("sg-holidays-update.py")
SPEC = importlib.util.spec_from_file_location("sg_holidays_update", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


SAMPLE_2026 = """BEGIN:VCALENDAR\r
VERSION:2.0\r
METHOD:PUBLISH\r
X-WR-CALNAME:Public Holidays Singapore 2026\r
X-WR-TIMEZONE:Asia/Singapore\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260101\r
DTEND;VALUE=DATE:20260102\r
UID:20260101-nyd@www.mom.gov.sg\r
SUMMARY:New Year's Day\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260217\r
DTEND;VALUE=DATE:20260218\r
UID:20260217-cny1@www.mom.gov.sg\r
SUMMARY:Chinese New Year\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260218\r
DTEND;VALUE=DATE:20260219\r
UID:20260218-cny2@www.mom.gov.sg\r
SUMMARY:Chinese New Year\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260321\r
DTEND;VALUE=DATE:20260322\r
UID:20260321-hrp@www.mom.gov.sg\r
SUMMARY:Hari Raya Puasa\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260403\r
DTEND;VALUE=DATE:20260404\r
UID:20260403-gf@www.mom.gov.sg\r
SUMMARY:Good Friday\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260501\r
DTEND;VALUE=DATE:20260502\r
UID:20260501-ld@www.mom.gov.sg\r
SUMMARY:Labour Day\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260527\r
DTEND;VALUE=DATE:20260528\r
UID:20260527-hrh@www.mom.gov.sg\r
SUMMARY:Hari Raya Haji\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260531\r
DTEND;VALUE=DATE:20260601\r
UID:20260531-vesak@www.mom.gov.sg\r
SUMMARY:Vesak Day\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20260809\r
DTEND;VALUE=DATE:20260810\r
UID:20260809-nd@www.mom.gov.sg\r
SUMMARY:National Day\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20261108\r
DTEND;VALUE=DATE:20261109\r
UID:20261108-deepavali@www.mom.gov.sg\r
SUMMARY:Deepavali\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20261225\r
DTEND;VALUE=DATE:20261226\r
UID:20261225-xmas@www.mom.gov.sg\r
SUMMARY:Christmas Day\r
END:VEVENT\r
END:VCALENDAR\r
"""

# Synthetic year where a Sunday holiday is immediately followed by a Monday holiday (e.g. CNY Sun+Mon)
SAMPLE_CONSECUTIVE_SUN_MON = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290101
DTEND;VALUE=DATE:20290102
UID:nyd@test
SUMMARY:New Year's Day
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290211
DTEND;VALUE=DATE:20290212
UID:cny1@test
SUMMARY:Chinese New Year
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290212
DTEND;VALUE=DATE:20290213
UID:cny2@test
SUMMARY:Chinese New Year
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290330
DTEND;VALUE=DATE:20290331
UID:gf@test
SUMMARY:Good Friday
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290501
DTEND;VALUE=DATE:20290502
UID:ld@test
SUMMARY:Labour Day
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290527
DTEND;VALUE=DATE:20290528
UID:vd@test
SUMMARY:Vesak Day
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20290809
DTEND;VALUE=DATE:20290810
UID:nd@test
SUMMARY:National Day
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20291225
DTEND;VALUE=DATE:20291226
UID:xm@test
SUMMARY:Christmas Day
END:VEVENT
END:VCALENDAR
"""


class SgHolidaysUpdateTest(unittest.TestCase):
    def test_2026_sunday_in_lieu_and_idempotency(self) -> None:
        enriched, added = mod.enrich_in_lieu(SAMPLE_2026, 2026)
        self.assertEqual(added, 3)
        events = mod.parse_vevents(enriched)
        in_lieu = {ev["start"]: ev["summary"] for ev in events if "(in lieu)" in str(ev["summary"])}
        self.assertEqual(
            in_lieu,
            {
                datetime.date(2026, 6, 1): "Vesak Day (in lieu)",
                datetime.date(2026, 8, 10): "National Day (in lieu)",
                datetime.date(2026, 11, 9): "Deepavali (in lieu)",
            },
        )
        # Re-running enrichment must be idempotent
        enriched_again, added_again = mod.enrich_in_lieu(enriched, 2026)
        self.assertEqual(added_again, 0)
        self.assertEqual(len(mod.parse_vevents(enriched_again)), 14)

    def test_consecutive_sunday_monday_shifts_in_lieu_to_tuesday(self) -> None:
        # 2029-02-11 is Sunday, 2029-02-12 is Monday -> in-lieu lands on Tuesday 2029-02-13
        # 2029-05-27 is Sunday -> in-lieu lands on Monday 2029-05-28
        enriched, added = mod.enrich_in_lieu(SAMPLE_CONSECUTIVE_SUN_MON, 2029)
        self.assertEqual(added, 2)
        events = mod.parse_vevents(enriched)
        in_lieu = {ev["start"]: ev["summary"] for ev in events if "(in lieu)" in str(ev["summary"])}
        self.assertEqual(
            in_lieu,
            {
                datetime.date(2029, 2, 13): "Chinese New Year (in lieu)",
                datetime.date(2029, 5, 28): "Vesak Day (in lieu)",
            },
        )

    def test_rejects_html_redirect_or_wrong_year(self) -> None:
        with self.assertRaises(mod.HolidayFetchError):
            mod.validate_ics("<html><body>Not found</body></html>", 2028)
        with self.assertRaises(mod.HolidayFetchError):
            mod.validate_ics(SAMPLE_2026, 2027)

    def test_from_file_replaces_symlink_atomically_and_lists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            src_ics = tmp_path / "mom-2026.ics"
            src_ics.write_text(SAMPLE_2026, encoding="utf-8")

            store_dummy = tmp_path / "nix-store-dummy.ics"
            store_dummy.write_text("stale", encoding="utf-8")

            live_dir = tmp_path / "live"
            live_dir.mkdir()
            live_target = live_dir / "sg-holidays-2026.ics"
            live_target.symlink_to(store_dummy)

            rc = mod.main(
                [
                    "--from-file",
                    str(src_ics),
                    "--live-dir",
                    str(live_dir),
                    "--live-only",
                    "--force",
                    "2026",
                ]
            )
            self.assertEqual(rc, 0)
            self.assertFalse(live_target.is_symlink())
            self.assertEqual(store_dummy.read_text(encoding="utf-8"), "stale")
            self.assertEqual((live_dir / "displayname").read_text(encoding="utf-8"), "Singapore Public Holidays\n")
            self.assertEqual(len(mod.parse_vevents(live_target.read_text(encoding="utf-8"))), 14)
            self.assertEqual(mod.main(["--list", "--live-dir", str(live_dir)]), 0)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
