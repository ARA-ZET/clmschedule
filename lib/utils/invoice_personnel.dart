// utils/invoice_personnel.dart
//
// The legal names and IDs of the people who did the work, added to invoice
// line descriptions — Chand's invoices carry them under each line.
import '../models/distribution_report_template.dart';

/// First line of the block. Also how an earlier block is found again, so
/// running the step twice updates the list instead of stacking a second one.
const String kInvoicePersonnelHeading = 'Personnel:';

/// Marks a person line as one this step wrote.
const String _kIdLabel = '— ID/Passport:';

String _personLine(DistributionReportPerson p) => p.idNumber.trim().isEmpty
    ? p.name.trim()
    : '${p.name.trim()} $_kIdLabel ${p.idNumber.trim()}';

/// [description] with a personnel block for [people] added on new lines at
/// the end.
///
/// Nothing already in the description is removed — except a personnel block
/// this step wrote before (its heading and its name/ID lines), which is
/// replaced by the current one. Any other text, even text typed below that
/// block, is kept. With no [people] the description is returned unchanged.
String withPersonnelBlock(
  String description,
  List<DistributionReportPerson> people,
) {
  if (people.isEmpty) return description;

  final names = {for (final p in people) p.name.trim().toLowerCase()};
  final kept = <String>[];
  var inOldBlock = false;
  for (final line in description.split('\n')) {
    final t = line.trim();
    if (t == kInvoicePersonnelHeading) {
      inOldBlock = true;
      continue;
    }
    if (inOldBlock &&
        (t.contains(_kIdLabel) || names.contains(t.toLowerCase()))) {
      continue;
    }
    inOldBlock = false;
    kept.add(line);
  }

  final before = kept.join('\n').trimRight();
  final block = [
    kInvoicePersonnelHeading,
    for (final p in people) _personLine(p)
  ].join('\n');
  return before.isEmpty ? block : '$before\n$block';
}

/// Whether an invoice line is for posters rather than leaflets, from its
/// item name and description.
bool isPosterLine(String text) => text.toLowerCase().contains('poster');

/// Who goes under one invoice line: the poster team on a poster line, the
/// leaflet team on the rest. With only one kind of job on the report,
/// everyone goes on every line.
List<DistributionReportPerson> personnelForLine({
  required String lineText,
  required List<DistributionReportPerson> leaflets,
  required List<DistributionReportPerson> posters,
}) {
  if (leaflets.isEmpty) return posters;
  if (posters.isEmpty) return leaflets;
  return isPosterLine(lineText) ? posters : leaflets;
}
