// Pure wage math — no Firestore, no side effects. Used both for the live
// preview while editing a payslip and for PayrollService.recomputeWeek's
// persisted recompute, so the number on screen always matches what's saved.
//
// Recreated from the distributor wage-slip Google Sheet:
//  - Daily basic = a flat day-rate if they worked, else 0.
//  - Daily bonus = either a flat amount for a special day-type code
//    (driving, scooter, etc.) or a performance formula for a normal
//    distribution day: perSetRate*(sets-1) + estimateBonus (the estimate
//    bonus only applies if the estimate was reached AND no issue was
//    logged in the day's notes).

import '../models/payroll_daily_entry.dart';

/// Day rate paid if [entry.worked], regardless of whether it's a special
/// code day or a normal distribution day (matches the sheet: driving/scooter
/// days still draw the full day rate, with the special bonus layered on top).
double dailyBasic(
  PayrollDailyEntry entry, {
  required double dayRate,
}) {
  if (!entry.worked) return 0;
  return dayRate;
}

/// Bonus for one day. [bonusCodeAmounts] should already be the
/// distributor-resolved map (profile override merged over company default).
double dailyBonus(
  PayrollDailyEntry entry, {
  required Map<String, double> bonusCodeAmounts,
  required double perSetRate,
  required double estimateBonus,
}) {
  if (!entry.worked) return 0;

  final code = entry.specialCode;
  if (code != null && code.isNotEmpty) {
    return bonusCodeAmounts[code] ?? 0;
  }

  final sets = entry.flyerSets;
  if (sets == null || sets < 1) return 0;

  final noIssueLogged = entry.notes.trim().isEmpty;
  final achievementBonus =
      (entry.estimateReached && noIssueLogged) ? estimateBonus : 0.0;
  return achievementBonus + perSetRate * (sets - 1);
}

/// Basic + bonus for one day.
double dailyTotal(
  PayrollDailyEntry entry, {
  required double dayRate,
  required Map<String, double> bonusCodeAmounts,
  required double perSetRate,
  required double estimateBonus,
}) {
  return dailyBasic(entry, dayRate: dayRate) +
      dailyBonus(
        entry,
        bonusCodeAmounts: bonusCodeAmounts,
        perSetRate: perSetRate,
        estimateBonus: estimateBonus,
      );
}

/// Sum of `dailyTotal` across every entry in [dailyEntries].
double weeklyGross(
  Map<String, PayrollDailyEntry> dailyEntries, {
  required double dayRate,
  required Map<String, double> bonusCodeAmounts,
  required double perSetRate,
  required double estimateBonus,
}) {
  var total = 0.0;
  for (final entry in dailyEntries.values) {
    total += dailyTotal(
      entry,
      dayRate: dayRate,
      bonusCodeAmounts: bonusCodeAmounts,
      perSetRate: perSetRate,
      estimateBonus: estimateBonus,
    );
  }
  return total;
}

/// Gross minus this week's deduction (advance/penalty), plus any one-off
/// extra earnings and this week's savings withdrawal payout.
double netWage({
  required double gross,
  required double advanceDeductionAmount,
  double extraEarningsAmount = 0,
  double savingsWithdrawalAmount = 0,
}) {
  return gross -
      advanceDeductionAmount +
      extraEarningsAmount +
      savingsWithdrawalAmount;
}
