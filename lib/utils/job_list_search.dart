import 'package:intl/intl.dart';

import '../models/job_list_item.dart';
import 'text_search.dart';

/// Labels that live outside the item (status and job-type names), looked up
/// at search time so a renamed status is found by its new name.
typedef JobSearchLabels = Iterable<String?> Function(JobListItem item);

/// Job List search across every column: dates, client, statuses, job type,
/// area, quantities, addresses, instructions, amounts and all invoice detail
/// (own number, Zoho/Xero numbers and statuses, split invoices, who to
/// invoice, invoice details, reminder notes).
///
/// Words use [TextSearch] rules (any order, close spellings). Numeric dates
/// typed as `12/10`, `12-10-2026`, `10/2026` or `2026-10-12` (day first, as
/// in SA) match the job date or collection date as dates; if no date
/// matches, the same text can still match as a whole phrase elsewhere (e.g.
/// invoice "INV 3/11") — never as loose separate numbers.
/// Month and weekday names ("oct", "october", "monday") match as words.
class JobListSearch {
  final JobSearchLabels? _labels;
  final List<_DateTerm> _dates;
  final TextSearch _text;

  JobListSearch._(this._labels, this._dates, this._text);

  factory JobListSearch(String raw, {JobSearchLabels? labels}) {
    final dates = <_DateTerm>[];
    var rest = raw;

    String take(RegExp re, _DateTerm? Function(Match m) parse) {
      return rest.replaceAllMapped(re, (m) {
        final term = parse(m);
        if (term == null) return m[0]!;
        dates.add(term);
        return ' ';
      });
    }

    rest = take(_iso, (m) => _DateTerm.of(m[0]!, m[3], m[2], m[1]));
    rest = take(_monthYear, (m) => _DateTerm.of(m[0]!, null, m[1], m[2]));
    rest = take(_dayMonth, (m) => _DateTerm.of(m[0]!, m[1], m[2], m[3]));
    return JobListSearch._(labels, dates, TextSearch(rest));
  }

  static final RegExp _iso =
      RegExp(r'\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b');
  static final RegExp _monthYear = RegExp(r'\b(\d{1,2})[-/.](\d{4})\b');
  static final RegExp _dayMonth =
      RegExp(r'\b(\d{1,2})[-/.](\d{1,2})(?:[-/.](\d{4}|\d{2}))?\b');

  bool get isEmpty => _dates.isEmpty && _text.isEmpty;

  bool matches(JobListItem item) {
    for (final d in _dates) {
      if (d.matches(item.date) || d.matches(item.collectionDate)) continue;
      if (_normalizedFor(item).contains(d.phrase)) continue;
      return false;
    }
    if (_text.isEmpty) return true;
    final labels = _labels?.call(item) ?? const <String?>[];
    return _text.matches([searchTextFor(item), ...labels]);
  }

  static final Expando<String> _textCache = Expando('jobSearchText');
  static final Expando<String> _normCache = Expando('jobSearchNorm');

  /// [searchTextFor] normalised and space-padded, for whole-phrase checks.
  static String _normalizedFor(JobListItem item) => _normCache[item] ??=
      ' ${normalizeForSearch(searchTextFor(item))} ';
  static final DateFormat _dayFmt = DateFormat('d MMM yyyy');
  static final DateFormat _longFmt = DateFormat('MMMM EEEE');

  /// Every searchable value of [item] as one string. Items are immutable
  /// (edits produce a new object), so it is built once per item.
  static String searchTextFor(JobListItem item) =>
      _textCache[item] ??= _build(item);

  static String _num(num v) {
    if (v == 0) return '';
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  static String _money(double v) {
    if (v <= 0) return '';
    final whole = v == v.roundToDouble() ? ' ${v.toInt()}' : '';
    return 'R ${v.toStringAsFixed(2)}$whole';
  }

  static String _date(DateTime d) =>
      d.year < 2000 ? '' : '${_dayFmt.format(d)} ${_longFmt.format(d)}';

  static String _build(JobListItem item) {
    final phoneDigits = item.contactPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    final parts = <String>[
      item.client,
      item.contactPerson,
      item.contactPhone,
      // "0821234567" finds "082 123 4567" too.
      if (phoneDigits != item.contactPhone.trim()) phoneDigits,
      item.invoice,
      item.area,
      _date(item.date),
      item.collectionAddress,
      item.offloadingAddress,
      item.specialInstructions,
      _date(item.collectionDate),
      item.timeSlot,
      item.assignedStaff.join(' '),
      _num(item.quantity),
      _num(item.manDays),
      _num(item.quantityDistributed),
      _money(item.amount),
      _money(item.amountExclVat),
      _money(item.amountInclVat),
      item.invoiceDetails,
      item.reportAddresses,
      item.whoToInvoice,
      item.zohoInvoiceNumber,
      item.zohoInvoiceStatus,
      item.accountingInvoiceNumber,
      item.accountingInvoiceStatus,
      for (final s in item.splitInvoices) ...[
        s.invoiceNumber,
        s.contactName,
        s.status,
        _money(s.total),
      ],
      for (final r in item.reminders) r.notes,
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }
}

/// A numeric date typed into the search: day and/or month, optional year.
class _DateTerm {
  final int? day;
  final int month;
  final int? year;

  /// The typed text normalised and space-padded, for when no date matches
  /// (it may be part of an invoice number): " 3 11 " in " inv 3 11 ".
  final String phrase;

  _DateTerm(this.day, this.month, this.year, String raw)
      : phrase = ' ${normalizeForSearch(raw)} ';

  static _DateTerm? of(String raw, String? d, String? m, String? y) {
    final day = d == null ? null : int.parse(d);
    final month = int.parse(m!);
    var year = y == null ? null : int.parse(y);
    if (year != null && year < 100) year += 2000;
    if (month < 1 || month > 12) return null;
    if (day != null && (day < 1 || day > 31)) return null;
    return _DateTerm(day, month, year, raw);
  }

  bool matches(DateTime date) =>
      date.month == month &&
      (day == null || date.day == day) &&
      (year == null || date.year == year);
}
