// Pure computation — no Flutter/pdf-widget dependency — so the exact same
// instalment schedule (what's already been paid + what's projected to come)
// can be rendered both on-screen and in the printed PDF.

/// One cell in an item's instalment schedule row: a date paired with an
/// amount. [isActual] distinguishes an instalment that's already happened
/// (shown shaded, like the original spreadsheet) from one that's merely
/// projected forward from the preferred instalment amount.
class ScheduleEntry {
  final DateTime date;
  final double amount;
  final bool isActual;

  const ScheduleEntry({
    required this.date,
    required this.amount,
    required this.isActual,
  });
}

/// Whether a ledger entry posted against [linkedWeekId] falls on or before
/// the pay week [weekId]. Week ids are `yyyy-MM-dd`, so a plain string
/// compare is a chronological one. A null id — an entry that didn't come
/// through the weekly payslip flow — is always included rather than silently
/// dropped from a distributor's history.
bool isOnOrBeforeWeek(String? linkedWeekId, String weekId) =>
    linkedWeekId == null || linkedWeekId.compareTo(weekId) <= 0;

/// Whether a deduction/savings item belongs on the payslip for the pay week
/// ending [weekEnd] (week id [weekId]).
///
/// An item earns its place if it already existed by that week AND was either
/// still being repaid then, or was touched by THAT week's own repayment. So
/// the week that finally settles an item still shows it — that's the week
/// the money actually came off — and every week after that leaves it out,
/// instead of dragging long-dead deductions down every future payslip.
///
/// Balances are measured AS AT that week: [payments] from later weeks are
/// ignored, so reprinting an old payslip reproduces what it said when it was
/// issued rather than today's picture.
bool belongsOnPayslip({
  required DateTime originDate,
  required double totalAmount,
  required DateTime weekEnd,
  required String weekId,
  required List<({String? linkedWeekId, double amount})> payments,
}) {
  if (originDate.isAfter(weekEnd)) return false;
  var paidToDate = 0.0;
  var touchedThisWeek = false;
  for (final p in payments) {
    if (p.linkedWeekId == weekId) touchedThisWeek = true;
    if (isOnOrBeforeWeek(p.linkedWeekId, weekId)) paidToDate += p.amount;
  }
  return touchedThisWeek || totalAmount - paidToDate > 0.005;
}

/// Builds a deduction/withdrawal item's full instalment schedule: every
/// actual payment so far (chronological, [isActual] = true), followed by a
/// weekly-cadence projection of the remaining balance at [instalmentAmount]
/// per week until it's fully settled ([isActual] = false) — giving a
/// distributor visibility into upcoming instalments, not just past ones.
List<ScheduleEntry> buildRepaymentSchedule({
  required double totalAmount,
  required double instalmentAmount,
  required DateTime originDate,
  required List<({DateTime date, double amount})> actualPayments,
}) {
  final sorted = [...actualPayments]..sort((a, b) => a.date.compareTo(b.date));
  final entries = <ScheduleEntry>[
    for (final p in sorted)
      ScheduleEntry(date: p.date, amount: p.amount, isActual: true),
  ];

  var remaining = totalAmount - sorted.fold<double>(0, (t, p) => t + p.amount);
  var cursor = sorted.isNotEmpty ? sorted.last.date : originDate;

  if (instalmentAmount > 0) {
    // Cap iterations defensively so a pathological instalment amount can
    // never spin this into an unbounded loop.
    var guard = 0;
    while (remaining > 0.005 && guard < 520) {
      cursor = cursor.add(const Duration(days: 7));
      final amount =
          remaining < instalmentAmount ? remaining : instalmentAmount;
      entries.add(ScheduleEntry(date: cursor, amount: amount, isActual: false));
      remaining -= amount;
      guard++;
    }
  }

  return entries;
}
