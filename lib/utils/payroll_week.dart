/// Friday-anchored payroll week helpers.
///
/// The pay week runs Friday -> Thursday, with wages paid on the Friday
/// immediately after (i.e. `weekStart + 7 days`). A week's Firestore month
/// bucket is the month of its **start date** (the Friday), even if the
/// Thursday end date rolls into the next month.
library;

import 'schedule_time.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// The Friday on/before [date] (midnight-normalized). If [date] is already
/// a Friday, returns that same day at midnight.
DateTime weekStartFor(DateTime date) {
  final d = _midnight(date);
  final offset = (d.weekday - DateTime.friday + 7) % 7;
  return d.subtract(Duration(days: offset));
}

/// The Thursday ending the week that [anyDate] falls in.
DateTime weekEndFor(DateTime anyDate) =>
    weekStartFor(anyDate).add(const Duration(days: 6));

/// The Friday wages for this week are paid on (one day after the Thursday
/// end date, i.e. `weekStart + 7 days`).
DateTime payDateFor(DateTime weekStart) =>
    weekStartFor(weekStart).add(const Duration(days: 7));

/// Year-document id, e.g. `2026`. Matches `DropsheetService._yearId`.
String yearIdFor(DateTime weekStart) =>
    weekStart.year.toString().padLeft(4, '0');

/// Month-collection id, e.g. `May 2026`. Matches `DropsheetService._monthId`
/// but is keyed off the week's **start** date, per the payroll month rule.
String monthLabelFor(DateTime weekStart) {
  final ws = weekStartFor(weekStart);
  return '${_monthNames[ws.month - 1]} ${ws.year}';
}

/// Plain `yyyy-MM-dd` formatting for a single date (used as
/// `PayrollPayslip.dailyEntries` map keys).
String dayKeyFor(DateTime date) {
  final d = _midnight(date);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Week-document id: the start date as `yyyy-MM-dd`, e.g. `2026-05-22`.
String weekIdFor(DateTime weekStart) => dayKeyFor(weekStartFor(weekStart));

/// The 7 dates Friday..Thursday for the week containing [anyDate].
List<DateTime> daysInWeek(DateTime anyDate) {
  final start = weekStartFor(anyDate);
  return List.generate(7, (i) => start.add(Duration(days: i)));
}

/// True if [a] and [b] fall in the same Friday-Thursday week.
bool isSameWeek(DateTime a, DateTime b) => weekStartFor(a) == weekStartFor(b);

/// The week that should open by default (initial load and "This week") for
/// [referenceNow] (defaults to `scheduleNow()`, i.e. SAST "now", so clients
/// in other timezones resolve the same current week as SAST users).
///
/// Friday is a special case: it's simultaneously payday for the week that
/// just ended (Fri-Thu) and day 1 of a brand-new week. Defaulting to
/// `weekStartFor(today)` on a Friday would land on that brand-new, still-
/// empty week — exactly when the user most wants to see the week that just
/// finished, to review/print/pay it out. So on Fridays this resolves to
/// **last** week (the one ending yesterday) instead; every other day it's
/// just the ongoing week, same as [weekStartFor]. Moving on to the new week
/// is then a deliberate action (next-week / date-picker), not automatic.
DateTime defaultPayrollWeekStart([DateTime? referenceNow]) {
  final today = _midnight(referenceNow ?? scheduleNow());
  if (today.weekday == DateTime.friday) {
    return weekStartFor(today.subtract(const Duration(days: 1)));
  }
  return weekStartFor(today);
}

/// Whether a week starting [weekStart] is still open for editing. Wages are
/// paid weekly and rarely need correcting once payment has gone out, so
/// only the current week plus the two immediately before it stay editable
/// — anything older than that (more than 14 days before the real current
/// week, not the Friday-adjusted [defaultPayrollWeekStart]) is locked.
///
/// This only governs whether a week's raw daily entries/deductions can
/// still be touched — it has no bearing on `PayrollSettings`/bonus-code
/// rate changes, which never retroactively affect old weeks anyway since
/// each payslip snapshots its own rates at creation time (`dayRateSnapshot`
/// etc. on `PayrollPayslip`).
bool isPayrollWeekEditable(DateTime weekStart, {DateTime? referenceNow}) {
  final currentWeekStart = weekStartFor(referenceNow ?? scheduleNow());
  final start = weekStartFor(weekStart);
  return currentWeekStart.difference(start).inDays <= 14;
}
