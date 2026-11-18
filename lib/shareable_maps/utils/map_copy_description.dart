import 'package:intl/intl.dart';

/// A month label line such as "October 2026" — what [copyDescription] writes.
final RegExp _monthLine = RegExp(r'^[A-Z][a-z]+ \d{4}$');

/// The description a copied map starts with: the month it is filed in on the
/// first line, then the source's own description.
///
/// A source that is itself a copy already leads with a month; that line is
/// replaced rather than stacked, so a copy of a copy reads "November 2026",
/// not "November 2026\nOctober 2026".
///
/// Mirrored by `copyDescription` in functions/index.js (Job List job copies).
String copyDescription(String source, DateTime month) {
  final label = DateFormat('MMMM yyyy').format(month);
  final lines = source.trim().split('\n');
  if (lines.isNotEmpty && _monthLine.hasMatch(lines.first.trim())) {
    lines.removeAt(0);
  }
  final rest = lines.join('\n').trim();
  return rest.isEmpty ? label : '$label\n$rest';
}
