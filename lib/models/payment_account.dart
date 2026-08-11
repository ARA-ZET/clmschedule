import '../utils/digit_grouping.dart';

/// One saved way to pay a distributor — an eWallet number or a bank
/// account. A distributor can have several (e.g. two eWallet numbers they
/// alternate between, or both an eWallet and a bank account); each payroll
/// week just records *which one* was used that week, via
/// `PayrollPayslip.selectedPaymentAccountId` + a frozen `paymentAccountSnapshot`
/// copy, rather than overwriting a single shared slot.
class PaymentAccount {
  final String id;

  /// 'eWallet' or 'Bank account'.
  final String method;

  /// Optional nickname shown in pickers, e.g. "Main", "Mom's number".
  final String label;

  final String? bankName;
  final String? accountHolder;
  final String? accountNumber;
  final String? branchCode;

  /// Phone number the eWallet payment is sent to. Only meaningful when
  /// [method] is 'eWallet'.
  final String? ewalletNumber;

  const PaymentAccount({
    required this.id,
    required this.method,
    this.label = '',
    this.bankName,
    this.accountHolder,
    this.accountNumber,
    this.branchCode,
    this.ewalletNumber,
  });

  factory PaymentAccount.fromMap(Map<String, dynamic> data) => PaymentAccount(
        id: data['id'] as String? ?? '',
        method: data['method'] as String? ?? 'eWallet',
        label: data['label'] as String? ?? '',
        bankName: data['bankName'] as String?,
        accountHolder: data['accountHolder'] as String?,
        accountNumber: data['accountNumber'] as String?,
        branchCode: data['branchCode'] as String?,
        ewalletNumber: data['ewalletNumber'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'method': method,
        'label': label,
        'bankName': bankName,
        'accountHolder': accountHolder,
        'accountNumber': accountNumber,
        'branchCode': branchCode,
        'ewalletNumber': ewalletNumber,
      };

  PaymentAccount copyWith({
    String? method,
    String? label,
    String? bankName,
    bool clearBankName = false,
    String? accountHolder,
    bool clearAccountHolder = false,
    String? accountNumber,
    bool clearAccountNumber = false,
    String? branchCode,
    bool clearBranchCode = false,
    String? ewalletNumber,
    bool clearEwalletNumber = false,
  }) {
    return PaymentAccount(
      id: id,
      method: method ?? this.method,
      label: label ?? this.label,
      bankName: clearBankName ? null : (bankName ?? this.bankName),
      accountHolder:
          clearAccountHolder ? null : (accountHolder ?? this.accountHolder),
      accountNumber:
          clearAccountNumber ? null : (accountNumber ?? this.accountNumber),
      branchCode: clearBranchCode ? null : (branchCode ?? this.branchCode),
      ewalletNumber:
          clearEwalletNumber ? null : (ewalletNumber ?? this.ewalletNumber),
    );
  }

  /// Short display text for pickers and summary rows, e.g.
  /// `Main (eWallet - 082 123 4567)` or `Nedbank · 8547 3692 4`.
  String get summary {
    final detail = method == 'eWallet'
        ? 'eWallet - '
            '${ewalletNumber?.isNotEmpty == true ? groupDigits(ewalletNumber!) : 'no number'}'
        : '${bankName?.isNotEmpty == true ? bankName! : 'Bank account'} · '
            '${accountNumber?.isNotEmpty == true ? groupDigits(accountNumber!) : 'no number'}';
    return label.isNotEmpty ? '$label ($detail)' : detail;
  }
}
