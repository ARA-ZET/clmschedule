// utils/invoice_dates.dart
//
// The dates written in invoice line descriptions. Invoices are often made
// by copying the client's last one, and a date left over from it is easy to
// miss — the report page compares these with when the work was done.

/// A date mentioned in text. [day] is null when only the month is given
/// ("October 2026"); [year] is null when the text leaves it out ("20 Oct").
class InvoiceTextDate {
  final int? year;
  final int month;
  final int? day;

  /// The words as written, for the warning.
  final String text;

  const InvoiceTextDate(
      {this.year, required this.month, this.day, required this.text});

  /// Whether this could be [date]: the parts given agree with it.
  bool matches(DateTime date) =>
      (year == null || year == date.year) &&
      month == date.month &&
      (day == null || day == date.day);

  /// Whether this falls between [from] and [to], both days included, or is
  /// a month either of them is in.
  bool within(DateTime from, DateTime to) {
    if (day == null) {
      int key(int y, int m) => y * 12 + m;
      bool inMonths(int y) =>
          key(y, month) >= key(from.year, from.month) &&
          key(y, month) <= key(to.year, to.month);
      return year != null ? inMonths(year!) : inMonths(from.year) ||
          inMonths(to.year);
    }
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);
    for (final y in year != null ? [year!] : {from.year, to.year}) {
      final d = DateTime(y, month, day!);
      // DateTime rolls 31 Sep over to 1 Oct; that is no date at all.
      if (d.month != month) continue;
      if (!d.isBefore(start) && !d.isAfter(end)) return true;
    }
    return false;
  }

  @override
  String toString() => text;
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

const _monthWord = r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|'
    r'june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|'
    r'nov(?:ember)?|dec(?:ember)?)\.?';
const _ord = r'(?:st|nd|rd|th)?';
// "20", "20th", and the joins in "20 – 22", "20, 21 and 22", "20 & 21".
const _dayList = '((?:\\d{1,2}$_ord\\s*(?:,|&|and|to|-|–|—)\\s*)*)'
    '(\\d{1,2})$_ord';

final _patterns = <(RegExp, List<InvoiceTextDate> Function(Match))>[
  // 2026-10-20
  (
    RegExp(r'(?<![\d/.-])(20\d\d)[-/.](\d{1,2})[-/.](\d{1,2})(?![\d/.-])'),
    (m) => _numeric(m, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
  ),
  // 20/10/2026, 20-10-26, 20.10.2026 — South African order, day first.
  (
    RegExp(r'(?<![\d/.-])(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d\d)(?![\d/.-])'),
    (m) {
      var y = int.parse(m[3]!);
      if (y < 100) y += 2000;
      return _numeric(m, y, int.parse(m[2]!), int.parse(m[1]!));
    },
  ),
  // 20 October 2026, 20th Oct, 20 – 22 Oct 2026, 20, 21 & 22 October
  (
    RegExp('(?<![\\d/.-])$_dayList\\s*(?:of\\s+)?$_monthWord(?![a-z])'
        '(?:,?\\s*(\\d{4}))?',
        caseSensitive: false),
    (m) {
      final month = _months[m[3]!.substring(0, 3).toLowerCase()]!;
      final year = m[4] == null ? null : int.parse(m[4]!);
      final days = [
        for (final d in RegExp(r'\d{1,2}').allMatches(m[1]!))
          int.parse(d[0]!),
        int.parse(m[2]!),
      ];
      return [
        for (final d in days)
          if (d >= 1 && d <= 31)
            InvoiceTextDate(
                year: year, month: month, day: d, text: m[0]!.trim()),
      ];
    },
  ),
  // October 20, 2026; Oct 20th
  (
    RegExp('(?<![a-z])$_monthWord\\s+(\\d{1,2})$_ord(?![\\d])'
        '(?:,?\\s*(\\d{4}))?',
        caseSensitive: false),
    (m) {
      final d = int.parse(m[2]!);
      if (d < 1 || d > 31) return const [];
      return [
        InvoiceTextDate(
          year: m[3] == null ? null : int.parse(m[3]!),
          month: _months[m[1]!.substring(0, 3).toLowerCase()]!,
          day: d,
          text: m[0]!.trim(),
        ),
      ];
    },
  ),
  // October 2026 — the month alone.
  (
    RegExp('(?<![a-z])$_monthWord\\s+(\\d{4})(?!\\d)',
        caseSensitive: false),
    (m) => [
          InvoiceTextDate(
            year: int.parse(m[2]!),
            month: _months[m[1]!.substring(0, 3).toLowerCase()]!,
            text: m[0]!.trim(),
          ),
        ],
  ),
];

List<InvoiceTextDate> _numeric(Match m, int y, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return const [];
  return [InvoiceTextDate(year: y, month: month, day: day, text: m[0]!)];
}

/// Every date written in [text], in the order found. Text one pattern has
/// used is not read again by a later one, so "20 October 2026" is one date
/// and not also the month "October 2026".
List<InvoiceTextDate> datesInInvoiceText(String text) {
  final found = <(int, InvoiceTextDate)>[];
  final taken = <(int, int)>[];
  bool overlaps(Match m) =>
      taken.any((t) => m.start < t.$2 && m.end > t.$1);
  for (final (pattern, read) in _patterns) {
    for (final m in pattern.allMatches(text)) {
      if (overlaps(m)) continue;
      final dates = read(m);
      if (dates.isEmpty) continue;
      taken.add((m.start, m.end));
      found.addAll([for (final d in dates) (m.start, d)]);
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

/// The dates in [text] that fall outside the work done on [workDates] (any
/// of them, or between the first and the last). Empty when [workDates] is.
List<InvoiceTextDate> invoiceDatesOutside(
    String text, Iterable<DateTime> workDates) {
  final dates = workDates.toList()..sort();
  if (dates.isEmpty) return const [];
  return [
    for (final d in datesInInvoiceText(text))
      if (!dates.any(d.matches) && !d.within(dates.first, dates.last)) d,
  ];
}
