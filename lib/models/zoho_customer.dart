/// A Zoho Books contact of type "customer".
///
/// Zoho stores contact details (email/phone/mobile) on the contact's
/// **primary contact person**, not on the contact itself. The top-level
/// `email` / `phone` / `mobile` fields in a list response are read-only
/// mirrors of that person — writing them on create is ignored. So reads take
/// the mirrors when that's all we have, and writes always go through
/// `contact_persons`.
class ZohoCustomer {
  final String contactId;

  /// Zoho's "Display Name" (`contact_name`) — what appears in lists and on
  /// invoices. Required by Zoho on create.
  final String contactName;

  final String companyName;
  final String salutation;
  final String firstName;
  final String lastName;
  final String email;

  /// Work phone.
  final String phone;

  final String mobile;

  /// `business` or `individual`. Zoho defaults to business.
  final String customerSubType;

  /// `active` or `inactive`.
  final String status;

  final String currencyCode;

  /// Outstanding balance owed by this customer, as reported by Zoho.
  final double outstandingReceivable;

  /// `contact_person_id` of the primary contact person. Only present on a
  /// detail fetch — required when updating so Zoho amends that person rather
  /// than appending a duplicate one.
  final String primaryContactPersonId;

  const ZohoCustomer({
    required this.contactId,
    required this.contactName,
    this.companyName = '',
    this.salutation = '',
    this.firstName = '',
    this.lastName = '',
    this.email = '',
    this.phone = '',
    this.mobile = '',
    this.customerSubType = 'business',
    this.status = 'active',
    this.currencyCode = '',
    this.outstandingReceivable = 0.0,
    this.primaryContactPersonId = '',
  });

  factory ZohoCustomer.fromJson(Map<String, dynamic> json) {
    // List responses have no `contact_persons`; detail responses do, and are
    // the authoritative source for the person-level fields.
    final persons = (json['contact_persons'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const <Map<String, dynamic>>[];

    Map<String, dynamic>? primary;
    for (final p in persons) {
      if (p['is_primary_contact'] == true) {
        primary = p;
        break;
      }
    }
    primary ??= persons.isNotEmpty ? persons.first : null;

    String pick(String key) {
      final fromPerson = primary?[key] as String?;
      if (fromPerson != null && fromPerson.isNotEmpty) return fromPerson;
      return json[key] as String? ?? '';
    }

    return ZohoCustomer(
      contactId: json['contact_id'] as String? ?? '',
      contactName: json['contact_name'] as String? ?? '',
      companyName: json['company_name'] as String? ?? '',
      salutation: pick('salutation'),
      firstName: pick('first_name'),
      lastName: pick('last_name'),
      email: pick('email'),
      phone: pick('phone'),
      mobile: pick('mobile'),
      customerSubType: json['customer_sub_type'] as String? ?? 'business',
      status: json['status'] as String? ?? 'active',
      currencyCode: json['currency_code'] as String? ?? '',
      outstandingReceivable:
          (json['outstanding_receivable_amount'] as num?)?.toDouble() ?? 0.0,
      primaryContactPersonId: primary?['contact_person_id'] as String? ?? '',
    );
  }

  /// The primary contact person payload, or null when there is nothing to say.
  Map<String, dynamic>? _contactPersonJson({required bool forUpdate}) {
    final person = <String, dynamic>{
      if (salutation.isNotEmpty) 'salutation': salutation,
      if (firstName.isNotEmpty) 'first_name': firstName,
      if (lastName.isNotEmpty) 'last_name': lastName,
      if (email.isNotEmpty) 'email': email,
      if (phone.isNotEmpty) 'phone': phone,
      if (mobile.isNotEmpty) 'mobile': mobile,
    };
    if (person.isEmpty) return null;

    person['is_primary_contact'] = true;
    // Without the id, an update appends a second contact person instead of
    // editing the existing one.
    if (forUpdate && primaryContactPersonId.isNotEmpty) {
      person['contact_person_id'] = primaryContactPersonId;
    }
    return person;
  }

  /// Payload for POST /contacts. `contact_type` is added by the proxy.
  Map<String, dynamic> toCreateJson() => _toJson(forUpdate: false);

  /// Payload for PUT /contacts/{id}.
  Map<String, dynamic> toUpdateJson() => _toJson(forUpdate: true);

  Map<String, dynamic> _toJson({required bool forUpdate}) {
    final person = _contactPersonJson(forUpdate: forUpdate);
    return {
      'contact_name': contactName,
      if (companyName.isNotEmpty) 'company_name': companyName,
      if (customerSubType.isNotEmpty) 'customer_sub_type': customerSubType,
      if (person != null) 'contact_persons': [person],
    };
  }

  /// Name shown in pickers — falls back to the company when the contact has
  /// no display name of its own.
  String get displayName => contactName.isNotEmpty ? contactName : companyName;

  /// Best available number: Zoho data here is overwhelmingly mobile rather
  /// than work phone.
  String get bestPhone => phone.isNotEmpty ? phone : mobile;

  bool get isActive => status.toLowerCase() == 'active';

  /// Whether this contact exists in Zoho yet.
  ///
  /// The create-vs-update decision must key on this, never on "did the caller
  /// hand me an object" — forms are seeded with a name-only [ZohoCustomer] to
  /// pre-fill a *new* contact, and treating that as an edit calls
  /// `updateCustomer`, which Zoho rejects for a missing contactId.
  bool get existsInZoho => contactId.isNotEmpty;

  ZohoCustomer copyWith({
    String? contactId,
    String? contactName,
    String? companyName,
    String? salutation,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? mobile,
    String? customerSubType,
    String? status,
    String? currencyCode,
    double? outstandingReceivable,
    String? primaryContactPersonId,
  }) {
    return ZohoCustomer(
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      companyName: companyName ?? this.companyName,
      salutation: salutation ?? this.salutation,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      customerSubType: customerSubType ?? this.customerSubType,
      status: status ?? this.status,
      currencyCode: currencyCode ?? this.currencyCode,
      outstandingReceivable:
          outstandingReceivable ?? this.outstandingReceivable,
      primaryContactPersonId:
          primaryContactPersonId ?? this.primaryContactPersonId,
    );
  }
}
