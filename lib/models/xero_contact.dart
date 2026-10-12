/// A Xero contact (customer).
///
/// Xero stores phone numbers as an **array of typed entries** rather than as
/// fields — `Phones: [{PhoneType: "MOBILE", PhoneNumber: "..."}]` — which is
/// the same shape of trap as Zoho's `contact_persons`: read the array, write
/// the array, and never assume a flat `phone` key exists. Reads flatten the
/// two types we care about; writes rebuild the array.
class XeroContact {
  final String contactId;

  /// Xero's contact name — what appears in lists and on invoices.
  ///
  /// **Xero requires this to be unique across the organisation** and rejects a
  /// create that collides with an existing contact, archived ones included.
  /// The CLM flow seeds it as "client, area", which collides the second time
  /// the same client is billed for the same area — so a create must be
  /// prepared to handle a duplicate-name validation error rather than assume
  /// success. See [XeroException.isDuplicateName].
  final String name;

  final String firstName;
  final String lastName;
  final String emailAddress;

  /// The `DEFAULT` phone entry.
  final String phone;

  /// The `MOBILE` phone entry.
  final String mobile;

  /// `ACTIVE`, `ARCHIVED` or `GDPRREQUEST`.
  final String status;

  final String defaultCurrency;

  /// Outstanding receivable, from `Balances.AccountsReceivable.Outstanding`.
  /// Only present on a detail fetch.
  final double outstandingReceivable;

  const XeroContact({
    this.contactId = '',
    required this.name,
    this.firstName = '',
    this.lastName = '',
    this.emailAddress = '',
    this.phone = '',
    this.mobile = '',
    this.status = 'ACTIVE',
    this.defaultCurrency = '',
    this.outstandingReceivable = 0.0,
  });

  factory XeroContact.fromJson(Map<String, dynamic> json) {
    final phones = (json['Phones'] as List<dynamic>?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const <Map<String, dynamic>>[];

    /// Xero returns every phone type it knows about, most with empty numbers.
    String phoneOfType(String type) {
      for (final p in phones) {
        if (p['PhoneType'] == type) {
          final number = (p['PhoneNumber'] as String? ?? '').trim();
          if (number.isEmpty) continue;
          // Area/country codes are separate fields; join what is present so a
          // number entered in parts is not silently truncated to the stub.
          final area = (p['PhoneAreaCode'] as String? ?? '').trim();
          final country = (p['PhoneCountryCode'] as String? ?? '').trim();
          return [
            if (country.isNotEmpty) '+$country',
            if (area.isNotEmpty) area,
            number,
          ].join(' ');
        }
      }
      return '';
    }

    final balances = json['Balances'] as Map<dynamic, dynamic>?;
    final receivable = balances?['AccountsReceivable'] as Map<dynamic, dynamic>?;

    return XeroContact(
      contactId: json['ContactID'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      firstName: json['FirstName'] as String? ?? '',
      lastName: json['LastName'] as String? ?? '',
      emailAddress: json['EmailAddress'] as String? ?? '',
      phone: phoneOfType('DEFAULT'),
      mobile: phoneOfType('MOBILE'),
      status: json['ContactStatus'] as String? ?? 'ACTIVE',
      defaultCurrency: json['DefaultCurrency'] as String? ?? '',
      outstandingReceivable:
          (receivable?['Outstanding'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Payload for POST /Contacts.
  Map<String, dynamic> toCreateJson() => _toJson(forUpdate: false);

  /// Payload for POST /Contacts/{id}.
  Map<String, dynamic> toUpdateJson() => _toJson(forUpdate: true);

  Map<String, dynamic> _toJson({required bool forUpdate}) {
    final phones = <Map<String, dynamic>>[
      if (phone.isNotEmpty) {'PhoneType': 'DEFAULT', 'PhoneNumber': phone},
      if (mobile.isNotEmpty) {'PhoneType': 'MOBILE', 'PhoneNumber': mobile},
    ];

    return {
      // Xero matches an update by ContactID; without it a POST to the contact
      // endpoint can be treated as a create and trip the unique-name rule.
      if (forUpdate && contactId.isNotEmpty) 'ContactID': contactId,
      'Name': name,
      if (firstName.isNotEmpty) 'FirstName': firstName,
      if (lastName.isNotEmpty) 'LastName': lastName,
      if (emailAddress.isNotEmpty) 'EmailAddress': emailAddress,
      if (phones.isNotEmpty) 'Phones': phones,
    };
  }

  /// Name shown in pickers.
  String get displayName => name;

  /// Best available number — CLM's contact data is mostly mobile.
  String get bestPhone => mobile.isNotEmpty ? mobile : phone;

  bool get isActive => status.toUpperCase() == 'ACTIVE';

  /// Whether this contact exists in Xero yet.
  ///
  /// The create-vs-update decision must key on this, never on "did the caller
  /// hand me an object" — forms are seeded with a name-only [XeroContact] to
  /// pre-fill a *new* contact, and treating that as an edit sends an update for
  /// a contact that does not exist. This is the exact bug the Zoho model
  /// documents; the shape is identical here.
  bool get existsInXero => contactId.isNotEmpty;

  XeroContact copyWith({
    String? contactId,
    String? name,
    String? firstName,
    String? lastName,
    String? emailAddress,
    String? phone,
    String? mobile,
    String? status,
    String? defaultCurrency,
    double? outstandingReceivable,
  }) {
    return XeroContact(
      contactId: contactId ?? this.contactId,
      name: name ?? this.name,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      emailAddress: emailAddress ?? this.emailAddress,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      status: status ?? this.status,
      defaultCurrency: defaultCurrency ?? this.defaultCurrency,
      outstandingReceivable:
          outstandingReceivable ?? this.outstandingReceivable,
    );
  }
}
