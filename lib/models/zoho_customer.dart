/// A Zoho Books contact of type "customer".
///
/// Zoho is the source of truth for these — the app mirrors them so client
/// pickers don't have to hit the API on every keystroke.
class ZohoCustomer {
  final String contactId;
  final String contactName;
  final String companyName;
  final String email;
  final String phone;

  /// Outstanding balance owed by this customer, as reported by Zoho.
  final double outstandingReceivable;

  const ZohoCustomer({
    required this.contactId,
    required this.contactName,
    this.companyName = '',
    this.email = '',
    this.phone = '',
    this.outstandingReceivable = 0.0,
  });

  factory ZohoCustomer.fromJson(Map<String, dynamic> json) {
    return ZohoCustomer(
      contactId: json['contact_id'] as String? ?? '',
      contactName: json['contact_name'] as String? ?? '',
      companyName: json['company_name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String? ?? json['mobile'] as String? ?? '',
      outstandingReceivable:
          (json['outstanding_receivable_amount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Payload for POST /contacts and PUT /contacts/{id}. `contact_type` is
  /// added by the proxy, not here.
  Map<String, dynamic> toCreateJson() {
    return {
      'contact_name': contactName,
      if (companyName.isNotEmpty) 'company_name': companyName,
      if (email.isNotEmpty) 'email': email,
      if (phone.isNotEmpty) 'phone': phone,
    };
  }

  /// Name shown in pickers — falls back to the company when the contact has
  /// no personal name.
  String get displayName =>
      contactName.isNotEmpty ? contactName : companyName;

  ZohoCustomer copyWith({
    String? contactId,
    String? contactName,
    String? companyName,
    String? email,
    String? phone,
    double? outstandingReceivable,
  }) {
    return ZohoCustomer(
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      companyName: companyName ?? this.companyName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      outstandingReceivable:
          outstandingReceivable ?? this.outstandingReceivable,
    );
  }
}
