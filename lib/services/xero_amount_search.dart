import 'package:intl/intl.dart';

import '../models/xero_invoice.dart';

/// Why an invoice matched an amount search, e.g. "Line 2 · Flyer drop".
///
/// [rank] orders matches from most to least telling: a whole-invoice figure
/// beats one line, one line beats a combination, and VAT-inclusive beats
/// exclusive — clients pay what the invoice says, VAT and all.
class XeroAmountMatch {
  final String label;
  final int rank;

  /// The figures behind [label], one per line — for a tooltip, so a
  /// combination can be checked against the bank statement at a glance.
  final String detail;

  const XeroAmountMatch(this.label, this.rank, {this.detail = ''});
}

/// The figure on an invoice closest to a searched amount, for when nothing
/// matches exactly — a bank fee or a mistyped cent should still surface.
class XeroAmountNearMiss {
  final XeroInvoice invoice;
  final String label;
  final int cents;

  /// Signed: positive when the invoice figure is above the searched amount.
  final int diffCents;

  const XeroAmountNearMiss(this.invoice, this.label, this.cents, this.diffCents);
}

/// Finds invoices from the money a client actually paid.
///
/// Built for unallocated payments with no reference and no proof of payment:
/// a client invoiced for two lines who pays for only one leaves a deposit that
/// matches neither the invoice total nor the amount due, only a line. Xero's
/// own `where` can filter on Total/AmountDue but cannot see inside line items,
/// so lines are matched here, against invoices read with their lines.
class XeroAmountSearch {
  XeroAmountSearch._();

  /// Up to this many non-zero lines, every combination is tried (2^12 is
  /// 4,095 sums — trivial). Longer invoices get singles and pairs only.
  static const maxLinesForAllCombinations = 12;

  /// Line VATs are rounded per line, so a combination can land a cent away
  /// from what the client paid.
  static const toleranceCents = 1;

  /// The amount a search term spells, in cents, or null if it is not one.
  ///
  /// Accepts how amounts get typed or pasted off a bank statement: `1250`,
  /// `1250.5`, `R 1 250,50`, `1,250.00`. A trailing separator with one or two
  /// digits is the decimal point; any other `,` or `.` is a thousands mark.
  static int? parseCents(String term) {
    var s = term.trim().toLowerCase();
    if (s.startsWith('r')) s = s.substring(1);
    s = s.replaceAll(RegExp(r'[\s ]'), '');
    if (!RegExp(r'^\d[\d,.]*$').hasMatch(s)) return null;

    var whole = s;
    var frac = '';
    final decimal = RegExp(r'^(.*)[.,](\d{1,2})$').firstMatch(s);
    if (decimal != null) {
      whole = decimal.group(1)!;
      frac = decimal.group(2)!;
    }
    whole = whole.replaceAll(RegExp(r'[,.]'), '');
    if (whole.isEmpty || !RegExp(r'^\d+$').hasMatch(whole)) return null;

    final cents = int.parse(whole) * 100 + int.parse(frac.padRight(2, '0'));
    return cents > 0 ? cents : null;
  }

  /// `R 1,250.00` — for labels and messages.
  static String format(int cents) =>
      NumberFormat.currency(symbol: 'R ', decimalDigits: 2).format(cents / 100);

  /// A Xero `where` fragment matching the whole-invoice figures, for invoices
  /// outside the line-item scan. Two decimals so Xero reads a decimal literal.
  static String whereClause(int cents) {
    final lit = (cents / 100).toStringAsFixed(2);
    return '(Total == $lit OR AmountDue == $lit OR AmountPaid == $lit)';
  }

  static int _toCents(double v) => (v * 100).round();

  /// An invoice's non-zero lines in cents, numbered as printed — zero lines
  /// are skipped for the sums but still counted.
  static List<({int number, String description, int incl, int excl})> _lines(
      XeroInvoice invoice) {
    final lines = <({int number, String description, int incl, int excl})>[];
    for (var i = 0; i < invoice.lineItems.length; i++) {
      final line = invoice.lineItems[i];
      final amount = _toCents(line.lineAmount);
      final tax = _toCents(line.taxAmount);
      final ({int incl, int excl}) figures;
      switch (invoice.lineAmountTypes) {
        case XeroLineAmountType.exclusive:
          figures = (incl: amount + tax, excl: amount);
        case XeroLineAmountType.inclusive:
          figures = (incl: amount, excl: amount - tax);
        case XeroLineAmountType.noTax:
          figures = (incl: amount, excl: amount);
      }
      if (figures.incl == 0) continue;
      lines.add((
        number: i + 1,
        description: line.description.trim().split('\n').first,
        incl: figures.incl,
        excl: figures.excl,
      ));
    }
    return lines;
  }

  static String _short(String text, [int max = 40]) =>
      text.length > max ? '${text.substring(0, max - 1)}…' : text;

  /// Total, paid and due, for a whole-invoice match's tooltip.
  static String _invoiceDetail(XeroInvoice invoice) => [
        'Total ${format(_toCents(invoice.total))}',
        if (invoice.amountPaid > 0)
          'Paid ${format(_toCents(invoice.amountPaid))}',
        'Due ${format(_toCents(invoice.amountDue))}',
      ].join('\n');

  /// The best reason [invoice] matches [cents], or null.
  ///
  /// Lines are only considered when the invoice was read with them — summary
  /// reads still match on the whole-invoice figures.
  static XeroAmountMatch? match(XeroInvoice invoice, int cents) {
    bool hits(int value) => (value - cents).abs() <= toleranceCents;

    if (hits(_toCents(invoice.total))) {
      return XeroAmountMatch('Invoice total', 0,
          detail: _invoiceDetail(invoice));
    }
    if (invoice.amountDue > 0 && hits(_toCents(invoice.amountDue))) {
      return XeroAmountMatch('Amount due', 1, detail: _invoiceDetail(invoice));
    }
    if (invoice.amountPaid > 0 && hits(_toCents(invoice.amountPaid))) {
      return XeroAmountMatch('Already paid', 2,
          detail: _invoiceDetail(invoice));
    }

    final lines = _lines(invoice);
    if (lines.isEmpty) return null;

    final hasVat = invoice.lineAmountTypes != XeroLineAmountType.noTax &&
        lines.any((l) => l.incl != l.excl);
    String describe(List<int> subset, {required bool exclVat}) {
      final suffix = exclVat ? ' excl. VAT' : '';
      if (subset.length == 1) {
        final l = lines[subset.single];
        final short = _short(l.description);
        return 'Line ${l.number}$suffix${short.isEmpty ? '' : ' · $short'}';
      }
      if (subset.length == lines.length) return 'Subtotal$suffix';
      return 'Lines ${subset.map((i) => lines[i].number).join(' + ')}$suffix';
    }

    String detail(List<int> subset, int sum, {required bool exclVat}) => [
          for (final i in subset)
            'Line ${lines[i].number} · ${_short(lines[i].description, 50)}: '
                '${format(exclVat ? lines[i].excl : lines[i].incl)}',
          '= ${format(sum)} ${exclVat ? 'excl.' : 'incl.'} VAT',
          'Invoice total ${format(_toCents(invoice.total))}, '
              'due ${format(_toCents(invoice.amountDue))}',
        ].join('\n');

    final subsets = _subsets(lines.length);
    for (final exclVat in [false, if (hasVat) true]) {
      for (final subset in subsets) {
        // The whole invoice incl. VAT is the total, already checked above.
        if (!exclVat && subset.length == lines.length) continue;
        var sum = 0;
        for (final i in subset) {
          sum += exclVat ? lines[i].excl : lines[i].incl;
        }
        if (hits(sum)) {
          return XeroAmountMatch(
            describe(subset, exclVat: exclVat),
            (exclVat ? 5 : 3) + (subset.length == 1 ? 0 : 1),
            detail: detail(subset, sum, exclVat: exclVat),
          );
        }
      }
    }
    return null;
  }

  /// The figure on [invoice] — total, amount due or a single line incl. VAT
  /// — closest to [cents].
  static XeroAmountNearMiss? nearest(XeroInvoice invoice, int cents) {
    final figures = <(String, int)>[
      ('Invoice total', _toCents(invoice.total)),
      if (invoice.amountDue > 0) ('Amount due', _toCents(invoice.amountDue)),
      for (final l in _lines(invoice))
        (
          'Line ${l.number}${l.description.isEmpty ? '' : ' · ${_short(l.description)}'}',
          l.incl,
        ),
    ];
    XeroAmountNearMiss? best;
    for (final (label, value) in figures) {
      if (value <= 0) continue;
      final diff = value - cents;
      if (best == null || diff.abs() < best.diffCents.abs()) {
        best = XeroAmountNearMiss(invoice, label, value, diff);
      }
    }
    return best;
  }

  /// The [limit] invoices with a figure closest to [cents], within 10% (and
  /// never more than R 500 off) — beyond that, "close" stops meaning anything.
  static List<XeroAmountNearMiss> nearMisses(
    Iterable<XeroInvoice> invoices,
    int cents, {
    int limit = 5,
  }) {
    final within = (cents ~/ 10).clamp(100, 50000);
    final seen = <String>{};
    final misses = [
      for (final inv in invoices)
        if (seen.add(inv.invoiceId))
          if (nearest(inv, cents) case final m?)
            if (m.diffCents.abs() <= within) m,
    ]..sort((a, b) => a.diffCents.abs().compareTo(b.diffCents.abs()));
    return misses.take(limit).toList();
  }

  /// Line index subsets to try, fewest lines first — so "Line 2" wins over a
  /// coincidental "Lines 1 + 3".
  ///
  /// Index lists rather than bitmasks: on Flutter web, ints are JS numbers
  /// and bit operations wrap at 32 bits.
  static List<List<int>> _subsets(int n) {
    if (n <= maxLinesForAllCombinations) {
      final all = <List<int>>[[]];
      for (var i = 0; i < n; i++) {
        all.addAll([for (final s in all) [...s, i]]);
      }
      return all.skip(1).toList()
        ..sort((a, b) => a.length.compareTo(b.length));
    }
    return [
      for (var i = 0; i < n; i++) [i],
      for (var i = 0; i < n; i++)
        for (var j = i + 1; j < n; j++) [i, j],
    ];
  }
}
