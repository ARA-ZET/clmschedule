/// A single distributor's line in a week's payment-run summary.
class PaymentSummaryLine {
  final String distributorId;
  final String distributorName;
  final double netWage;

  /// 'eWallet' or 'Bank account' — from the week's selected payment account.
  final String paymentMethod;

  /// Short display text for the selected account, e.g. `Nedbank · 8547 3692 4`
  /// or `082 123 4567`. Empty if no account was selected for the week.
  final String accountSummary;

  const PaymentSummaryLine({
    required this.distributorId,
    required this.distributorName,
    required this.netWage,
    required this.paymentMethod,
    required this.accountSummary,
  });
}

/// The EFT-run view for one payroll week — every distributor's net pay +
/// selected payment account + a grand total. Purely derived client-side
/// from an already-loaded `PayrollWeek`; not its own Firestore document
/// (replaces the old sheet's "banking" tab).
class PaymentSummary {
  final DateTime weekStart;
  final DateTime payDate;
  final List<PaymentSummaryLine> lines;
  final double totalNet;

  const PaymentSummary({
    required this.weekStart,
    required this.payDate,
    required this.lines,
    required this.totalNet,
  });
}
