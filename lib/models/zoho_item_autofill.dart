/// Placeholders available in an item's autofill templates.
///
/// Deliberately a small, job-shaped set: these are filled from the job the
/// invoice is being raised for, so anything the job does not know cannot appear
/// here.
enum ItemAutofillToken {
  client('client', 'Client name'),
  area('area', 'Area'),
  quantity('quantity', 'Quantity'),
  jobType('job_type', 'Job type'),
  date('date', 'Job date');

  const ItemAutofillToken(this.key, this.label);

  /// Wire key, written into a template as `{area}`.
  final String key;
  final String label;

  String get placeholder => '{$key}';
}

/// What an item's invoice line should say, overriding what the books store.
///
/// Zoho's own item description is a catalogue entry — it describes the service
/// in general. An invoice line usually wants to describe *this* job: which
/// area, how many, for whom. Rather than retyping that every time, each item
/// gets a template here and the job's values are substituted in.
///
/// Both fields are optional. An empty template means "use what Zoho stores",
/// so an item with no autofill configured behaves exactly as it did before.
class ZohoItemAutofill {
  /// Zoho's opaque `item_id`. The document id in Firestore, so there is exactly
  /// one autofill per item and no way to create a duplicate.
  final String itemId;

  /// Overrides the line's item name. Usually left blank — the catalogue name is
  /// normally right, and it is what makes the line recognisable in Zoho.
  final String nameTemplate;

  /// Overrides the line description. This is the one that earns its keep.
  final String descriptionTemplate;

  const ZohoItemAutofill({
    required this.itemId,
    this.nameTemplate = '',
    this.descriptionTemplate = '',
  });

  factory ZohoItemAutofill.fromMap(String itemId, Map<String, dynamic> map) {
    return ZohoItemAutofill(
      itemId: itemId,
      nameTemplate: map['nameTemplate'] as String? ?? '',
      descriptionTemplate: map['descriptionTemplate'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'nameTemplate': nameTemplate,
        'descriptionTemplate': descriptionTemplate,
      };

  bool get isEmpty => nameTemplate.isEmpty && descriptionTemplate.isEmpty;

  ZohoItemAutofill copyWith({
    String? nameTemplate,
    String? descriptionTemplate,
  }) {
    return ZohoItemAutofill(
      itemId: itemId,
      nameTemplate: nameTemplate ?? this.nameTemplate,
      descriptionTemplate: descriptionTemplate ?? this.descriptionTemplate,
    );
  }

  /// Substitute [values] into [template].
  ///
  /// A token with no value collapses to nothing, and the tidy-up below removes
  /// the punctuation it leaves behind — "{quantity} flyers — {area}" with no
  /// area should read "5000 flyers", not "5000 flyers — ".
  ///
  /// Unknown `{...}` sequences are left alone: they may be literal text the
  /// user wants, and silently deleting them would be worse than showing them.
  static String render(String template, Map<ItemAutofillToken, String> values) {
    if (template.isEmpty) return '';

    var out = template;
    for (final token in ItemAutofillToken.values) {
      out = out.replaceAll(token.placeholder, values[token]?.trim() ?? '');
    }

    // Collapse the gaps an empty token leaves: repeated separators, and a
    // dangling one at either end.
    out = out.replaceAll(RegExp(r'\s+'), ' ');
    out = out.replaceAll(RegExp(r'(\s*[—\-,:;]\s*){2,}'), ' — ');
    out = out.replaceAll(RegExp(r'^\s*[—\-,:;]\s*'), '');
    out = out.replaceAll(RegExp(r'\s*[—\-,:;]\s*$'), '');
    return out.trim();
  }
}
