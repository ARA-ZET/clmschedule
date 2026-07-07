/// A single distributor's line in a week's payment-run summary.
class PaymentSummaryLine {
  final String distributorId;
  final String distributorName;
  final double netWage;
  final String? bankName;
  final String? bankAccountHolder;
  final String? bankAccountNumber;
  final String? bankBranchCode;
  final String paymentMethod;

  const PaymentSummaryLine({
    required this.distributorId,
    required this.distributorName,
    required this.netWage,
    this.bankName,
    this.bankAccountHolder,
    this.bankAccountNumber,
    this.bankBranchCode,
    this.paymentMethod = 'EFT',
  });
}

/// The EFT-run view for one payroll week — every distributor's net pay +
/// bank details + a grand total. Purely derived client-side from an
/// already-loaded `PayrollWeek`; not its own Firestore document (replaces
/// the old sheet's "banking" tab).
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
