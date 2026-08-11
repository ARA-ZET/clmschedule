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
