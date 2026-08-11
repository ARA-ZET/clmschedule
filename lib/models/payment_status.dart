/// Whether a distributor's payment for a given payroll week has gone out.
/// Lives on `PayrollPayslip` (per week, per distributor) — recorded from the
/// Banking tab, defaults to [notPaid] for every new payslip.
enum PaymentStatus {
  notPaid,
  processing,
  paid;

  String get displayName {
    switch (this) {
      case PaymentStatus.notPaid:
        return 'Not paid';
      case PaymentStatus.processing:
        return 'Processing';
      case PaymentStatus.paid:
        return 'Paid';
    }
  }

  static PaymentStatus fromString(String? value) {
    switch (value) {
      case 'processing':
        return PaymentStatus.processing;
      case 'paid':
        return PaymentStatus.paid;
      default:
        return PaymentStatus.notPaid;
    }
  }
}
