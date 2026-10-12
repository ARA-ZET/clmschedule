import 'package:intl/intl.dart';

/// A placeholder the user can drop into a report body.
///
/// Deliberately small. The report is mostly fixed prose explaining how to read
/// the map; only these values change between jobs. Add a token when a template
/// needs one, not in anticipation.
enum DistributionReportToken {
  /// The person being greeted — typed in the dialog, not derived.
  ///
  /// The Job List's `client` column is the account name ("Seeff"), which is
  /// rarely who you address the email to.
  greetingName('greeting_name', 'Greeting name'),

  startDate('start_date', 'Start date'),
  quantityDistributed('quantity_distributed', 'Quantity distributed'),
  distributionAreas('distribution_areas', 'Distribution areas'),
  mapLink('map_link', 'Map link'),

  /// Expands to "Your invoice is attached." or to nothing.
  ///
  /// Being a token rather than a conditional block is what keeps rendering a
  /// plain series of `replaceAll` calls — no template syntax to parse.
  invoiceLine('invoice_line', 'Invoice attached line'),

  /// The account name, for a template that wants it.
  client('client', 'Client / account name');

  const DistributionReportToken(this.key, this.label);

  /// Wire key, written into the body as `{start_date}`.
  final String key;

  /// Human label shown on the insert chips.
  final String label;

  String get placeholder => '{$key}';
}

/// The sentence that appears when an invoice still needs paying.
const String kInvoiceAttachedLine = 'Your invoice is attached.';

/// The wording CLM sends today, with its variables tokenised.
///
/// Seeded into Firestore on first use so the feature works before anyone opens
/// the template editor.
const String kDefaultDistributionReportBody = '''
Hi {greeting_name},

From {start_date}, we distributed {quantity_distributed} of your flyers in {distribution_areas}.

This map shows the area covered, as well as the position of every letterbox to which your flyers were delivered: {map_link}

When you click on the link, your browser will open a map in a new tab. Give it a few seconds to load.

On the map, you will see:

* The coloured blocks representing your target area.

* Blue lines across the target area. These are the movements of our distributors as tracked by the GPS devices they carried.

If you want to see the position of every letter box reached by our distributors, click on "Tap to load waypoints" at the bottom of the legend on the left-hand side of the map. Give it a few seconds to load. Each blue flag shows the position of a letter box that received your flyer.

Please let me know if you have any questions. {invoice_line}

Thank you for this opportunity.''';

/// The values a [DistributionReportTemplate] renders against.
///
/// Flat and already formatted, so rendering is pure string substitution and
/// can be tested without a report, a map or Firestore.
class DistributionReportValues {
  final String greetingName;
  final String startDate;
  final String quantityDistributed;
  final String distributionAreas;
  final String mapLink;
  final String client;

  /// Whether to include [kInvoiceAttachedLine].
  final bool includeInvoiceLine;

  const DistributionReportValues({
    this.greetingName = '',
    this.startDate = '',
    this.quantityDistributed = '',
    this.distributionAreas = '',
    this.mapLink = '',
    this.client = '',
    this.includeInvoiceLine = false,
  });
}

/// A reusable report body sent to a client after a distribution.
class DistributionReportTemplate {
  final String id;
  final String name;
  final String body;

  /// Sort order in the picker; ties fall back to [name].
  final int order;

  const DistributionReportTemplate({
    required this.id,
    required this.name,
    required this.body,
    this.order = 0,
  });

  factory DistributionReportTemplate.fromMap(Map<String, dynamic> map) {
    return DistributionReportTemplate(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      body: map['body'] as String? ?? '',
      order: (map['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'body': body,
        'order': order,
      };

  /// Substitute every token with [values].
  ///
  /// Unknown `{...}` sequences are left untouched — they may be literal text
  /// the user wants, and silently deleting them would be worse than leaving
  /// them visible.
  String render(DistributionReportValues values) {
    String forToken(DistributionReportToken t) {
      switch (t) {
        case DistributionReportToken.greetingName:
          return values.greetingName;
        case DistributionReportToken.startDate:
          return values.startDate;
        case DistributionReportToken.quantityDistributed:
          return values.quantityDistributed;
        case DistributionReportToken.distributionAreas:
          return values.distributionAreas;
        case DistributionReportToken.mapLink:
          return values.mapLink;
        case DistributionReportToken.invoiceLine:
          return values.includeInvoiceLine ? kInvoiceAttachedLine : '';
        case DistributionReportToken.client:
          return values.client;
      }
    }

    var result = body;
    for (final token in DistributionReportToken.values) {
      result = result.replaceAll(token.placeholder, forToken(token));
    }
    return tidy(result);
  }

  /// Clean up after a token expanded to nothing.
  ///
  /// Dropping `{invoice_line}` otherwise leaves "…any questions. " with a
  /// trailing space, and a template with the token on its own line leaves a
  /// third blank line. Neither is visible while editing, both are visible in
  /// the sent email.
  static String tidy(String text) {
    final lines = text.split('\n').map((l) {
      // Collapse runs of spaces left where a token used to be, but do not
      // touch leading indentation, which may be deliberate.
      final trimmedEnd = l.trimRight();
      final leading = RegExp(r'^\s*').firstMatch(trimmedEnd)!.group(0)!;
      final rest = trimmedEnd.substring(leading.length).replaceAll(
            RegExp(r'  +'),
            ' ',
          );
      return '$leading$rest';
    }).toList();

    // Three or more newlines can only come from a now-empty line.
    return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  DistributionReportTemplate copyWith({
    String? id,
    String? name,
    String? body,
    int? order,
  }) {
    return DistributionReportTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      body: body ?? this.body,
      order: order ?? this.order,
    );
  }

  /// The built-in, used when Firestore holds no templates yet.
  static const fallback = DistributionReportTemplate(
    id: '_default',
    name: 'Standard distribution report',
    body: kDefaultDistributionReportBody,
  );
}

/// Formatters shared by the report dialog and the template renderer, so the
/// preview and the sent message cannot drift apart.
class DistributionReportFormat {
  DistributionReportFormat._();

  static final DateFormat date = DateFormat('d MMMM yyyy');
  static final NumberFormat quantity = NumberFormat.decimalPattern();

  /// "Claremont", "Claremont and Newlands", "Claremont, Newlands and Rondebosch".
  ///
  /// The names land inside a sentence, so they read as prose rather than as a
  /// list.
  static String areaList(List<String> areas) {
    if (areas.isEmpty) return '';
    if (areas.length == 1) return areas.first;
    return '${areas.sublist(0, areas.length - 1).join(', ')} and ${areas.last}';
  }
}
