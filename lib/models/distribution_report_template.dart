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
  client('client', 'Client / account name'),

  /// The days of a flyer handout ("20 and 22 October 2026"). Its report
  /// goes out as a PDF attachment, built on the report page.
  handoutDates('handout_dates', 'Handout dates'),

  // ── Flyers & Posters report ──────────────────────────────────────────────
  // A flyer job and a poster job reported together, for clients (Chand) who
  // need the people and both halves of the work spelled out.

  /// Typed in the dialog — the project the work was for.
  heading('heading', 'Heading'),

  /// Typed — what the leaflet is called ("MyCiTi Phase 2A").
  leafletName('leaflet_name', 'Leaflet name'),
  leafletQuantity('leaflet_quantity', 'Leaflet quantity'),
  leafletDate('leaflet_date', 'Leaflet date'),

  /// Prefilled from the leaflet map's areas, editable in the dialog.
  suburb('suburb', 'Suburb / area'),

  /// "two distributors" — the phrase, so one person reads correctly.
  leafletDistributorCount('leaflet_distributor_count', 'Leaflet distributors'),
  posterQuantity('poster_quantity', 'Poster quantity'),
  posterDate('poster_date', 'Poster date'),
  posterDistributorCount('poster_distributor_count', 'Poster distributors'),
  posterMapLink('poster_map_link', 'Poster map link'),
  posterPhotosLink('poster_photos_link', 'Poster photos link'),

  /// Name / ID table of everyone who worked on either job. A real table in
  /// the HTML render, tab-separated rows in the plain text.
  distributorsTable('distributors_table', 'Distributors table');

  const DistributionReportToken(this.key, this.label);

  /// Wire key, written into the body as `{start_date}`.
  final String key;

  /// Human label shown on the insert chips.
  final String label;

  String get placeholder => '{$key}';

  /// Tokens only the Flyers & Posters dialog can fill.
  bool get isFlyersAndPosters => index >= heading.index;
}

/// A conditional block in a template: `[[posters]]…[[/posters]]` is kept when
/// the report has a poster job and dropped, content and all, when it has not.
///
/// Sections exist because the Flyers & Posters report covers three shapes of
/// job — both, flyers only, posters only — and the opening sentence and the
/// headings differ between them.
enum DistributionReportSection {
  leaflets('leaflets'),
  posters('posters'),
  both('both'),
  leafletsOnly('leaflets_only'),
  postersOnly('posters_only');

  const DistributionReportSection(this.key);
  final String key;

  String get open => '[[$key]]';
  String get close => '[[/$key]]';

  bool isActive({required bool hasLeaflets, required bool hasPosters}) {
    switch (this) {
      case DistributionReportSection.leaflets:
        return hasLeaflets;
      case DistributionReportSection.posters:
        return hasPosters;
      case DistributionReportSection.both:
        return hasLeaflets && hasPosters;
      case DistributionReportSection.leafletsOnly:
        return hasLeaflets && !hasPosters;
      case DistributionReportSection.postersOnly:
        return hasPosters && !hasLeaflets;
    }
  }
}

/// One paragraph of a rendered report, or the place the people table goes.
class DistributionReportBlock {
  final String text;
  final bool isTable;

  const DistributionReportBlock.paragraph(this.text) : isTable = false;
  const DistributionReportBlock.table()
      : text = '',
        isTable = true;
}

/// One row of the Name / ID table.
class DistributionReportPerson {
  final String name;
  final String idNumber;

  const DistributionReportPerson({required this.name, this.idNumber = ''});
}

/// Subject line of every report email. Editable per report on the page.
const String kDefaultReportSubject = 'Your flyers distribution report';

/// Subject line of the flyer handout report email.
const String kFlyerHandoutReportSubject = 'Your flyer handout report';

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

/// The Flyers & Posters report, as Chand asked for it.
///
/// `**…**` lines are headings: bold in the pasted HTML, plain in the text.
const String kFlyersAndPostersReportBody = '''
Hi {greeting_name},

**{heading}**

[[both]]On {leaflet_date} we distributed {leaflet_quantity} {leaflet_name} leaflets in the {suburb} area and we put up {poster_quantity} posters across the same area.[[/both]]
[[leaflets_only]]On {leaflet_date} we distributed {leaflet_quantity} {leaflet_name} leaflets in the {suburb} area.[[/leaflets_only]]
[[posters_only]]On {poster_date} we put up {poster_quantity} posters in the {suburb} area.[[/posters_only]]

[[leaflets]]
**Leaflets**

The leaflet drops were delivered door-to-door to residential letter boxes and open businesses by {leaflet_distributor_count}.

The distributors who carried out the work are:

{distributors_table}

The total number of leaflets distributed is {leaflet_quantity}.

This map shows the area covered: {map_link}
[[/leaflets]]

[[posters]]
**Posters**

The poster notifications were placed in public facilities by {poster_distributor_count} on {poster_date}.
[[/posters]]
[[posters_only]]
The distributors who carried out the work are:

{distributors_table}
[[/posters_only]]
[[posters]]
Total number of posters placed: {poster_quantity}

This folder contains photos of the places where we placed posters: {poster_photos_link}

This map shows the positions of the posters: {poster_map_link}
[[/posters]]

**How to view the maps**

When you click on the map links, your browser will open a map in a new tab. Give it a few seconds to load.

On the map, you will see:

* The coloured blocks representing your target area.

* Blue lines across the target area. These are the movements of our distributors as tracked by the GPS devices they carried.

If you want to see the position of every letter box reached by our distributors, click on "Tap to load waypoints" at the bottom of the legend on the left-hand side of the map. Give it a few seconds to load. Each blue flag shows the position of a letter box that received your flyer.

Thank you very much for this opportunity. {invoice_line}

Please let me know if you have any questions.''';

/// The flyer handout (traffic light) report email, in the user's words. The
/// report itself is the attached PDF.
const String kFlyerHandoutReportBody = '''
Hi {greeting_name},

Please find attached the report on the handing out of your flyers on {handout_dates}.

Let me know if you have any questions.

{invoice_line}

Thank you!''';

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

  /// Flyer handout report.
  final String handoutDates;

  /// Whether to include [kInvoiceAttachedLine].
  final bool includeInvoiceLine;

  // Flyers & Posters report.
  final String heading;
  final String leafletName;
  final String leafletQuantity;
  final String leafletDate;
  final String suburb;
  final String leafletDistributorCount;
  final String posterQuantity;
  final String posterDate;
  final String posterDistributorCount;
  final String posterMapLink;
  final String posterPhotosLink;
  final List<DistributionReportPerson> people;

  /// Which [DistributionReportSection]s survive rendering.
  final bool hasLeaflets;
  final bool hasPosters;

  const DistributionReportValues({
    this.greetingName = '',
    this.startDate = '',
    this.quantityDistributed = '',
    this.distributionAreas = '',
    this.mapLink = '',
    this.client = '',
    this.handoutDates = '',
    this.includeInvoiceLine = false,
    this.heading = '',
    this.leafletName = '',
    this.leafletQuantity = '',
    this.leafletDate = '',
    this.suburb = '',
    this.leafletDistributorCount = '',
    this.posterQuantity = '',
    this.posterDate = '',
    this.posterDistributorCount = '',
    this.posterMapLink = '',
    this.posterPhotosLink = '',
    this.people = const [],
    this.hasLeaflets = false,
    this.hasPosters = false,
  });
}

/// Stands in for `{distributors_table}` until the last step of rendering, so
/// the plain text and the HTML can each draw the table their own way.
const String _kTableMarker = '\u0000distributors_table\u0000';

final RegExp _kBold = RegExp(r'\*\*(.+?)\*\*');
final RegExp _kUrl = RegExp(r'https?://[^\s<>"]+');

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

  /// Whether this body needs the Flyers & Posters controls in the dialog.
  bool get usesFlyersAndPosters =>
      DistributionReportToken.values
          .any((t) => t.isFlyersAndPosters && body.contains(t.placeholder)) ||
      DistributionReportSection.values.any((s) => body.contains(s.open));

  /// Whether this body is the flyer handout report, which builds a PDF to
  /// attach.
  bool get usesFlyerHandouts =>
      body.contains(DistributionReportToken.handoutDates.placeholder);

  /// Substitute every token with [values].
  ///
  /// Unknown `{...}` sequences are left untouched — they may be literal text
  /// the user wants, and silently deleting them would be worse than leaving
  /// them visible.
  String render(DistributionReportValues values) {
    final text = _expand(values);
    return text
        .replaceAll(_kTableMarker, _plainTable(values.people))
        .replaceAllMapped(_kBold, (m) => m.group(1)!);
  }

  /// The same report as an HTML fragment, for pasting into Gmail.
  ///
  /// Gmail's compose URL only takes plain text, so a real table can only
  /// reach the draft through the clipboard.
  String renderHtml(DistributionReportValues values) {
    final out = StringBuffer(
        '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px">');
    for (final block in renderBlocks(values)) {
      if (block.isTable) {
        out.write(_htmlTable(values.people));
        continue;
      }
      final html = _escapeHtml(block.text)
          .replaceAllMapped(_kBold, (m) => '<b>${m.group(1)}</b>')
          .replaceAllMapped(_kUrl, (m) {
        // A sentence-ending full stop is not part of the link.
        final url = trimUrl(m.group(0)!);
        final tail = m.group(0)!.substring(url.length);
        return '<a href="$url">$url</a>$tail';
      }).replaceAll('\n', '<br>');
      out.write('<p>$html</p>');
    }
    out.write('</div>');
    return out.toString();
  }

  /// The report as paragraphs and the people table, in order — what the
  /// HTML and the in-app preview are both drawn from, so they cannot
  /// disagree. Paragraph text still carries its `**bold**` markers.
  List<DistributionReportBlock> renderBlocks(DistributionReportValues values) {
    final blocks = <DistributionReportBlock>[];
    for (final paragraph in _expand(values).split(RegExp(r'\n{2,}'))) {
      // A table written mid-paragraph still gets a block of its own.
      final parts = paragraph.split(_kTableMarker);
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) blocks.add(const DistributionReportBlock.table());
        final text = parts[i].trim();
        if (text.isNotEmpty) blocks.add(DistributionReportBlock.paragraph(text));
      }
    }
    return blocks;
  }

  /// [url] without sentence punctuation the URL pattern swallowed.
  static String trimUrl(String url) =>
      url.replaceFirst(RegExp(r'[.,;:)]+$'), '');

  static final RegExp urlPattern = _kUrl;

  /// Sections resolved, tokens substituted, tidied — with the table still a
  /// marker for [render] / [renderHtml] to draw.
  String _expand(DistributionReportValues values) {
    var result = body;
    for (final section in DistributionReportSection.values) {
      final keep = section.isActive(
        hasLeaflets: values.hasLeaflets,
        hasPosters: values.hasPosters,
      );
      result = result.replaceAllMapped(
        RegExp('${RegExp.escape(section.open)}([\\s\\S]*?)'
            '${RegExp.escape(section.close)}'),
        (m) => keep ? m.group(1)! : '',
      );
    }

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
        case DistributionReportToken.handoutDates:
          return values.handoutDates;
        case DistributionReportToken.heading:
          return values.heading;
        case DistributionReportToken.leafletName:
          return values.leafletName;
        case DistributionReportToken.leafletQuantity:
          return values.leafletQuantity;
        case DistributionReportToken.leafletDate:
          return values.leafletDate;
        case DistributionReportToken.suburb:
          return values.suburb;
        case DistributionReportToken.leafletDistributorCount:
          return values.leafletDistributorCount;
        case DistributionReportToken.posterQuantity:
          return values.posterQuantity;
        case DistributionReportToken.posterDate:
          return values.posterDate;
        case DistributionReportToken.posterDistributorCount:
          return values.posterDistributorCount;
        case DistributionReportToken.posterMapLink:
          return values.posterMapLink;
        case DistributionReportToken.posterPhotosLink:
          return values.posterPhotosLink;
        case DistributionReportToken.distributorsTable:
          return _kTableMarker;
      }
    }

    for (final token in DistributionReportToken.values) {
      result = result.replaceAll(token.placeholder, forToken(token));
    }
    return tidy(result);
  }

  /// The table as lines of text, for the Gmail draft link, which only
  /// carries plain text. Tabs would be collapsed to single spaces there, so
  /// each row is spelled out instead.
  static String _plainTable(List<DistributionReportPerson> people) {
    return [
      for (final p in people)
        p.idNumber.trim().isEmpty
            ? p.name
            : '${p.name} — ID / Passport: ${p.idNumber.trim()}',
    ].join('\n');
  }

  static String _htmlTable(List<DistributionReportPerson> people) {
    const cell = 'border:1px solid #999;padding:4px 10px;text-align:left';
    final rows = StringBuffer()
      ..write('<tr><th style="$cell">Name</th>'
          '<th style="$cell">ID / Passport Number</th></tr>');
    for (final p in people) {
      rows.write('<tr><td style="$cell">${_escapeHtml(p.name)}</td>'
          '<td style="$cell">${_escapeHtml(p.idNumber)}</td></tr>');
    }
    return '<table style="border-collapse:collapse;margin:8px 0">$rows</table>';
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

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

  /// Flyer + poster jobs reported together, with the Name / ID table.
  static const flyersAndPosters = DistributionReportTemplate(
    id: '_flyers_posters',
    name: 'Flyers & Posters report',
    body: kFlyersAndPostersReportBody,
    order: 1000,
  );

  /// Traffic-light flyer handouts: a short email carrying the Flyer Handout
  /// Report PDF.
  static const flyerHandouts = DistributionReportTemplate(
    id: '_flyer_handouts',
    name: 'Flyer handout report (PDF)',
    body: kFlyerHandoutReportBody,
    order: 1001,
  );

  /// Offered alongside Firestore's templates unless one with the same id
  /// overrides it.
  static const builtIns = [fallback, flyersAndPosters, flyerHandouts];

  /// The built-ins offered even when Firestore holds templates.
  static const alwaysOffered = [flyersAndPosters, flyerHandouts];
}

/// Formatters shared by the report dialog and the template renderer, so the
/// preview and the sent message cannot drift apart.
class DistributionReportFormat {
  DistributionReportFormat._();

  static final DateFormat date = DateFormat('d MMMM yyyy');
  static final NumberFormat quantity = NumberFormat.decimalPattern();

  static const List<String> _numberWords = [
    'no', 'one', 'two', 'three', 'four', 'five', //
    'six', 'seven', 'eight', 'nine', 'ten',
  ];

  /// "one distributor", "two distributors", "12 distributors".
  static String countOf(int n, String singular) {
    final word = n >= 0 && n < _numberWords.length ? _numberWords[n] : '$n';
    return '$word ${n == 1 ? singular : '${singular}s'}';
  }

  /// "Claremont", "Claremont and Newlands", "Claremont, Newlands and Rondebosch".
  ///
  /// The names land inside a sentence, so they read as prose rather than as a
  /// list.
  static String areaList(List<String> areas) {
    if (areas.isEmpty) return '';
    if (areas.length == 1) return areas.first;
    return '${areas.sublist(0, areas.length - 1).join(', ')} and ${areas.last}';
  }

  /// "22 October 2026", "20 and 22 October 2026", "30 September and
  /// 1 October 2026", "30 December 2026 and 2 January 2027" — the month and
  /// year are said once for the days that share them.
  static String dateList(Iterable<DateTime> dates) {
    final days = {
      for (final d in dates) DateTime(d.year, d.month, d.day),
    }.toList()
      ..sort();
    if (days.isEmpty) return '';
    final parts = <String>[];
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final next = i + 1 < days.length ? days[i + 1] : null;
      final sameYear = next != null && next.year == d.year;
      final sameMonth = sameYear && next.month == d.month;
      parts.add(sameMonth
          ? '${d.day}'
          : sameYear
              ? DateFormat('d MMMM').format(d)
              : date.format(d));
    }
    return areaList(parts);
  }
}
