import '../models/erf_list_entry.dart';

/// Turns a pasted block of text into [ErfListEntry] rows.
///
/// Real-world pastes come from spreadsheets, WhatsApp messages and work
/// orders, so the parser is deliberately forgiving. Every line keeps its
/// original text and the caller shows the parse result for review, which is
/// what makes the guessing below safe: a wrong split is visible and fixable
/// rather than silent.
///
/// Handled shapes (one entry per line):
///   12 Main Road, Kensington
///   ERF 1234
///   1234
///   12 Main Road, Kensington, 1234
///   12 Main Road, Kensington - ERF 1234/2
///   1234`\t`12 Main Road (tab-separated, straight from a spreadsheet)
class ErfListParser {
  /// Explicit "ERF 1234" / "erf no. 1234/2" / "erf#1234" markers.
  static final RegExp _erfKeyword = RegExp(
    r'\berf\b\s*(?:number|nr|no|#|:)?\s*\.?\s*(\d{1,6}(?:\s*/\s*\d{1,4})?)',
    caseSensitive: false,
  );

  /// A field that is nothing but an ERF number, optionally with a portion.
  static final RegExp _bareNumber = RegExp(r'^\d{1,6}(?:\s*/\s*\d{1,4})?$');

  /// Leading bullet characters.
  static final RegExp _bulletChar = RegExp(r'^[-*•·–—]+\s+');

  /// Leading "1." / "2)" list numbering.
  static final RegExp _listNumber = RegExp(r'^\d{1,3}[.)]\s+');

  /// Field separators: comma, semicolon, tab, pipe, or a spaced dash.
  static final RegExp _separators = RegExp(r'[,;|\t]|\s+-\s+');

  static final RegExp _hasLetter = RegExp(r'[A-Za-z]');

  static const _headerWords = {
    'address',
    'addresses',
    'erf',
    'erfs',
    'erf no',
    'erf number',
    'street',
    'suburb',
    'stand',
    'property',
  };

  /// Parse [text] into one entry per non-empty line.
  ///
  /// A leading header row ("Address, ERF") is dropped.
  static List<ErfListEntry> parse(String text) {
    final entries = <ErfListEntry>[];
    final lines = text.split(RegExp(r'\r\n|\r|\n'));

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i].trim();
      if (raw.isEmpty) continue;
      if (entries.isEmpty && _looksLikeHeader(raw)) continue;

      entries.add(_parseLine(raw, entries.length + 1));
    }

    return entries;
  }

  static bool _looksLikeHeader(String line) {
    final fields = line
        .split(_separators)
        .map((f) => f.trim().toLowerCase())
        .where((f) => f.isNotEmpty)
        .toList();
    if (fields.isEmpty) return false;
    // A header has no numbers in it and every field is a known column name.
    return fields.every((f) => _headerWords.contains(f));
  }

  static ErfListEntry _parseLine(String raw, int lineNumber) {
    var working = raw.trim();

    final bullet = _bulletChar.firstMatch(working);
    if (bullet != null) working = working.substring(bullet.end).trim();

    // A leading "12." is only list numbering when what follows still looks
    // like content — an address (has letters) or a bare ERF number.
    final numbering = _listNumber.firstMatch(working);
    if (numbering != null) {
      final remainder = working.substring(numbering.end).trim();
      if (_hasLetter.hasMatch(remainder) || _bareNumber.hasMatch(remainder)) {
        working = remainder;
      }
    }

    String? erf;
    String? address;

    // 1. An explicit "ERF nnnn" marker wins, wherever it sits on the line.
    final keyword = _erfKeyword.firstMatch(working);
    if (keyword != null) {
      erf = _normaliseErf(keyword.group(1)!);
      final remainder = working.replaceRange(keyword.start, keyword.end, ' ');
      address = _cleanAddress(remainder);
      return ErfListEntry(
        lineNumber: lineNumber,
        rawLine: raw,
        address: address,
        erfNumber: erf,
      );
    }

    // 2. Otherwise split into fields and look for a field that is only a
    //    number. The last such field wins, because the common spreadsheet
    //    layout is "address, suburb, erf".
    final fields = working
        .split(_separators)
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toList();

    if (fields.isEmpty) {
      return ErfListEntry(lineNumber: lineNumber, rawLine: raw);
    }

    if (fields.length == 1) {
      final only = fields.first;
      if (_bareNumber.hasMatch(only)) {
        return ErfListEntry(
          lineNumber: lineNumber,
          rawLine: raw,
          erfNumber: _normaliseErf(only),
        );
      }
      return ErfListEntry(
        lineNumber: lineNumber,
        rawLine: raw,
        address: _cleanAddress(only),
      );
    }

    int erfFieldIndex = -1;
    for (var i = fields.length - 1; i >= 0; i--) {
      if (_bareNumber.hasMatch(fields[i])) {
        erfFieldIndex = i;
        break;
      }
    }

    if (erfFieldIndex >= 0) {
      erf = _normaliseErf(fields[erfFieldIndex]);
      final addressFields = <String>[
        for (var i = 0; i < fields.length; i++)
          if (i != erfFieldIndex) fields[i]
      ];
      address = _cleanAddress(addressFields.join(', '));
    } else {
      address = _cleanAddress(fields.join(', '));
    }

    return ErfListEntry(
      lineNumber: lineNumber,
      rawLine: raw,
      address: address,
      erfNumber: erf,
    );
  }

  /// Strip spaces around a portion slash so "1234 / 2" and "1234/2" are the
  /// same key.
  static String _normaliseErf(String value) =>
      value.replaceAll(RegExp(r'\s+'), '');

  /// An address is only kept when it still contains letters — a leftover
  /// fragment of punctuation or a lone number is not something the geocoder
  /// can use.
  static String? _cleanAddress(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s,;:\-–—]+|[\s,;:\-–—]+$'), '')
        .trim();
    if (cleaned.isEmpty || !_hasLetter.hasMatch(cleaned)) return null;
    return cleaned;
  }
}
