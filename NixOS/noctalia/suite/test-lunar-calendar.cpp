#include "shell/calendar/lunar_calendar.h"

#include <array>
#include <chrono>
#include <cstdio>
#include <string>

namespace {

  bool expect(bool condition, const char* msg) {
    if (!condition) {
      std::fprintf(stderr, "test-lunar-calendar FAILED: %s\n", msg);
    }
    return condition;
  }

  int countSolarTermsInYear(int year) {
    int count = 0;
    const auto start = std::chrono::sys_days{std::chrono::year{year} / std::chrono::January / 1};
    const auto end = std::chrono::sys_days{std::chrono::year{year + 1} / std::chrono::January / 1};
    for (auto d = start; d < end; d += std::chrono::days{1}) {
      const std::chrono::year_month_day ymd{d};
      const auto info = lunar_calendar::lookup(
          static_cast<int>(ymd.year()), static_cast<int>(static_cast<unsigned>(ymd.month())),
          static_cast<int>(static_cast<unsigned>(ymd.day()))
      );
      if (!info.valid) {
        return -1;
      }
      if (!info.solarTerm.empty()) {
        ++count;
      }
    }
    return count;
  }

} // namespace

int main() {
  bool ok = true;

  // 2025 leap month 6 day 1 -> 2025-07-25
  {
    const auto info = lunar_calendar::lookup(2025, 7, 25);
    ok = expect(info.valid, "2025-07-25 valid") && ok;
    ok = expect(info.lunar.year == 2025 && info.lunar.month == 6 && info.lunar.day == 1 && info.lunar.isLeap,
                "2025-07-25 is leap 6/1") && ok;
    ok = expect(info.cellLabel == "闰六月" && info.cellKind == lunar_calendar::CellKind::MonthFirst,
                "2025-07-25 cellLabel 闰六月") && ok;
    ok = expect(info.festival.empty(), "leap month day 1 has no non-leap festival") && ok;
  }

  // 2026 CNY Eve (29-day 腊月) -> 2026-02-16
  {
    const auto info = lunar_calendar::lookup(2026, 2, 16);
    ok = expect(info.valid && info.lunar.year == 2025 && info.lunar.month == 12 && info.lunar.day == 29,
                "2026-02-16 is 2025-12-29") && ok;
    ok = expect(info.festival == "除夕" && info.cellLabel == "除夕" && info.cellKind == lunar_calendar::CellKind::Festival,
                "2026-02-16 is 除夕") && ok;
  }

  // 2026 CNY -> 2026-02-17 (丙午年 马)
  {
    const auto info = lunar_calendar::lookup(2026, 2, 17);
    ok = expect(info.valid && info.lunar.year == 2026 && info.lunar.month == 1 && info.lunar.day == 1 && !info.lunar.isLeap,
                "2026-02-17 is 2026-01-01") && ok;
    ok = expect(info.ganzhiYear == "丙午年" && info.zodiac == "马", "2026 ganzhi 丙午年 马") && ok;
    ok = expect(info.festival == "春节" && info.cellLabel == "春节" && info.cellKind == lunar_calendar::CellKind::Festival,
                "2026-02-17 is 春节") && ok;
  }

  // 2026 Qingming -> 2026-04-05 (both festival 清明节 and solar term 清明)
  {
    const auto info = lunar_calendar::lookup(2026, 4, 5);
    ok = expect(info.valid && info.solarTerm == "清明" && info.festival == "清明节", "2026-04-05 Qingming") && ok;
    ok = expect(info.cellLabel == "清明" && info.cellKind == lunar_calendar::CellKind::Festival,
                "2026-04-05 cellLabel 清明") && ok;
  }

  // 2026 Mid-Autumn Festival -> 2026-09-25
  {
    const auto info = lunar_calendar::lookup(2026, 9, 25);
    ok = expect(info.valid && info.lunar.month == 8 && info.lunar.day == 15, "2026-09-25 is 8/15") && ok;
    ok = expect(info.festival == "中秋节" && info.cellLabel == "中秋", "2026-09-25 is 中秋") && ok;
  }

  // 2026 Winter Solstice -> 2026-12-22
  {
    const auto info = lunar_calendar::lookup(2026, 12, 22);
    ok = expect(info.valid && info.solarTerm == "冬至" && info.cellLabel == "冬至"
                    && info.cellKind == lunar_calendar::CellKind::SolarTerm,
                "2026-12-22 is 冬至") && ok;
  }

  // 2027 CNY -> 2027-02-06 (丁未年 羊)
  {
    const auto info = lunar_calendar::lookup(2027, 2, 6);
    ok = expect(info.valid && info.lunar.year == 2027 && info.lunar.month == 1 && info.lunar.day == 1,
                "2027-02-06 is CNY") && ok;
    ok = expect(info.ganzhiYear == "丁未年" && info.zodiac == "羊", "2027 ganzhi 丁未年 羊") && ok;
  }

  // 2028 CNY & Leap Month 5 -> 2028-01-26 & 2028-06-23
  {
    const auto cny = lunar_calendar::lookup(2028, 1, 26);
    ok = expect(cny.valid && cny.lunar.year == 2028 && cny.lunar.month == 1 && cny.lunar.day == 1,
                "2028-01-26 is CNY") && ok;
    const auto leap = lunar_calendar::lookup(2028, 6, 23);
    ok = expect(leap.valid && leap.lunar.year == 2028 && leap.lunar.month == 5 && leap.lunar.day == 1 && leap.lunar.isLeap,
                "2028-06-23 is leap 5/1") && ok;
    ok = expect(leap.cellLabel == "闰五月", "2028-06-23 cellLabel 闰五月") && ok;
  }

  // Boundary years 1900 & 2100, plus out-of-range guards
  {
    const auto minDay = lunar_calendar::lookup(1900, 1, 31);
    ok = expect(minDay.valid && minDay.lunar.year == 1900 && minDay.lunar.month == 1 && minDay.lunar.day == 1,
                "1900-01-31 is 1900 CNY") && ok;
    const auto maxDay = lunar_calendar::lookup(2100, 12, 31);
    ok = expect(maxDay.valid && maxDay.lunar.year == 2100 && maxDay.lunar.month == 12 && maxDay.lunar.day == 1,
                "2100-12-31 is 2100-12-01") && ok;
    ok = expect(!lunar_calendar::lookup(1899, 12, 31).valid, "1899 rejected") && ok;
    ok = expect(!lunar_calendar::lookup(2101, 1, 1).valid, "2101 rejected") && ok;
    ok = expect(!lunar_calendar::lookup(2026, 2, 29).valid, "invalid Feb 29 rejected") && ok;
  }

  // Every year in 2026, 2027, 1900, 2100 has all 24 solar terms
  for (int y : std::array<int, 4>{1900, 2026, 2027, 2100}) {
    ok = expect(countSolarTermsInYear(y) == 24, "year has 24 solar terms") && ok;
  }

  return ok ? 0 : 1;
}
