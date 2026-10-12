/// How a pasted block of text should be read.
enum AddressParseMode {
  /// Inspect the text and pick between the two modes below.
  auto,

  /// Every line is one delimited record: street, suburb, city, postal,
  /// province, country — or whatever a header row names.
  columns,

  /// Every line is one whole address written out as prose; nothing is
  /// split off it.
  singleLine;

  String get label => switch (this) {
        AddressParseMode.auto => 'Detect automatically',
        AddressParseMode.columns => 'Columns (CSV / TSV)',
        AddressParseMode.singleLine => 'One address per line',
      };
}

/// A parsed row, before it becomes an [Address].
class ParsedAddress {
  final String streetAddress;
  final String suburb;
  final String city;
  final String postalCode;
  final String province;
  final String country;
  final String notes;

  /// The line this came from, kept so the preview can show what was read.
  final String sourceLine;

  const ParsedAddress({
    required this.streetAddress,
    required this.suburb,
    required this.city,
    required this.postalCode,
    required this.province,
    required this.country,
    this.notes = '',
    this.sourceLine = '',
  });

  Map<String, String> toRawMap() => {
        'streetAddress': streetAddress,
        'suburb': suburb,
        'city': city,
        'postalCode': postalCode,
        'province': province,
        'country': country,
        'notes': notes,
      };

  String get fullAddress => [
        streetAddress,
        suburb,
        city,
        postalCode,
        province,
        country,
      ].where((p) => p.isNotEmpty).join(', ');

  String get dedupeKey => [
        streetAddress.toLowerCase(),
        suburb.toLowerCase(),
        city.toLowerCase(),
      ].join('|');
}

/// Result of parsing a pasted block.
class AddressParseResult {
  final List<ParsedAddress> addresses;

  /// Rows dropped as exact duplicates of an earlier row.
  final List<String> duplicates;

  /// Lines that held nothing usable.
  final List<String> skipped;

  /// The mode actually used, so `auto` can report what it decided.
  final AddressParseMode modeUsed;

  /// True when a header row was detected and consumed.
  final bool headerDetected;

  const AddressParseResult({
    required this.addresses,
    required this.duplicates,
    required this.skipped,
    required this.modeUsed,
    required this.headerDetected,
  });

  static const empty = AddressParseResult(
    addresses: [],
    duplicates: [],
    skipped: [],
    modeUsed: AddressParseMode.auto,
    headerDetected: false,
  );

  bool get isEmpty => addresses.isEmpty;
}

/// Reads pasted address lists into structured rows.
///
/// Real paste sources are messy: a column dump out of a spreadsheet, a
/// numbered list out of a document, a WhatsApp message with one address
/// per line. This handles all three, strips list numbering and stray
/// quoting, respects quoted commas, honours a header row when there is
/// one, and reports what it dropped instead of silently losing rows.
class AddressImportParser {
  final String defaultSuburb;
  final String defaultCity;
  final String defaultProvince;
  final String defaultCountry;

  const AddressImportParser({
    this.defaultSuburb = '',
    this.defaultCity = 'CAPE TOWN',
    this.defaultProvince = 'Western Cape',
    this.defaultCountry = 'South Africa',
  });

  /// Header spellings we accept, mapped to the field they fill.
  static const Map<String, String> _headerAliases = {
    'street': 'streetAddress',
    'streetaddress': 'streetAddress',
    'street address': 'streetAddress',
    'address': 'streetAddress',
    'address1': 'streetAddress',
    'addressline1': 'streetAddress',
    'line1': 'streetAddress',
    'suburb': 'suburb',
    'area': 'suburb',
    'neighbourhood': 'suburb',
    'town': 'city',
    'city': 'city',
    'postal': 'postalCode',
    'postalcode': 'postalCode',
    'postal code': 'postalCode',
    'postcode': 'postalCode',
    'zip': 'postalCode',
    'province': 'province',
    'state': 'province',
    'region': 'province',
    'country': 'country',
    'notes': 'notes',
    'note': 'notes',
    'comment': 'notes',
    'instructions': 'notes',
  };

  AddressParseResult parse(
    String text, {
    AddressParseMode mode = AddressParseMode.auto,
    bool dropDuplicates = true,
  }) {
    final rawLines = text
        .split(RegExp(r'\r\n|\r|\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (rawLines.isEmpty) return AddressParseResult.empty;

    final delimiter = _detectDelimiter(rawLines);
    var headerMap = <int, String>{};
    var lines = rawLines;
    var headerDetected = false;

    if (delimiter != null) {
      final firstCells = _splitLine(rawLines.first, delimiter);
      final detected = _headerMapFor(firstCells);
      if (detected != null) {
        headerMap = detected;
        headerDetected = true;
        lines = rawLines.sublist(1);
      }
    }

    final effectiveMode = mode == AddressParseMode.auto
        ? (delimiter != null &&
                (headerDetected || _looksTabular(lines, delimiter))
            ? AddressParseMode.columns
            : AddressParseMode.singleLine)
        : mode;

    final addresses = <ParsedAddress>[];
    final duplicates = <String>[];
    final skipped = <String>[];
    final seen = <String>{};

    for (final line in lines) {
      final cleaned = _stripListMarker(line);
      if (cleaned.isEmpty) {
        skipped.add(line);
        continue;
      }

      final parsed = effectiveMode == AddressParseMode.columns &&
              delimiter != null
          ? _parseColumns(cleaned, delimiter, headerMap)
          : _parseSingleLine(cleaned);

      if (parsed.streetAddress.isEmpty && parsed.suburb.isEmpty) {
        skipped.add(line);
        continue;
      }

      if (dropDuplicates && !seen.add(parsed.dedupeKey)) {
        duplicates.add(line);
        continue;
      }

      addresses.add(parsed);
    }

    return AddressParseResult(
      addresses: addresses,
      duplicates: duplicates,
      skipped: skipped,
      modeUsed: effectiveMode,
      headerDetected: headerDetected,
    );
  }

  // ── Detection ──────────────────────────────────────────────────────────

  /// Prefer tabs (a spreadsheet paste) over semicolons, pipes and commas.
  /// Returns null when no line is delimited at all.
  String? _detectDelimiter(List<String> lines) {
    for (final candidate in ['\t', ';', '|', ',']) {
      final withDelimiter = lines.where((l) => l.contains(candidate)).length;
      if (withDelimiter >= (lines.length / 2).ceil() && withDelimiter > 0) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether the paste is really a table rather than prose that happens
  /// to contain the delimiter.
  ///
  /// A tab, semicolon or pipe only ever shows up in a paste out of a
  /// spreadsheet, so one is proof enough. Commas are different — every
  /// written-out address has them — so a comma paste has to look like a
  /// grid before it is read as one: several lines, all the same width.
  bool _looksTabular(List<String> lines, String delimiter) {
    if (lines.isEmpty) return false;

    final counts =
        lines.take(20).map((l) => _splitLine(l, delimiter).length).toList();
    if (counts.every((c) => c <= 1)) return false;

    if (delimiter != ',') return true;

    if (lines.length < 2) return false;
    final first = counts.first;
    final consistent = counts.where((c) => c == first).length;
    return first >= 3 && consistent >= (counts.length * 0.8);
  }

  Map<int, String>? _headerMapFor(List<String> cells) {
    final map = <int, String>{};
    for (var i = 0; i < cells.length; i++) {
      final key = cells[i].trim().toLowerCase().replaceAll(RegExp(r'[_-]'), ' ');
      final field = _headerAliases[key] ?? _headerAliases[key.replaceAll(' ', '')];
      if (field != null) map[i] = field;
    }
    // Two recognised headings is enough to be sure; one could be a street
    // name that happens to read like a column name.
    return map.length >= 2 ? map : null;
  }

  // ── Row parsing ────────────────────────────────────────────────────────

  ParsedAddress _parseColumns(
    String line,
    String delimiter,
    Map<int, String> headerMap,
  ) {
    final cells = _splitLine(line, delimiter);

    if (headerMap.isNotEmpty) {
      final values = <String, String>{};
      for (var i = 0; i < cells.length; i++) {
        final field = headerMap[i];
        if (field == null) continue;
        final value = cells[i].trim();
        if (value.isNotEmpty) values[field] = value;
      }
      return _build(values, line);
    }

    return _build(_assignPositional(cells), line);
  }

  /// Assign unheadered cells to fields by what they look like, not by
  /// where they sit.
  ///
  /// Pasted lists are ragged: some rows carry a country, some stop at the
  /// city, some put the postal code last. Recognising a 4-digit code, a
  /// province name and a country by shape first — then filling street,
  /// suburb and city from whatever is left, in order — reads all of those
  /// correctly, where fixed positions would shift every later field along
  /// by one the moment a column is missing.
  Map<String, String> _assignPositional(List<String> cells) {
    final values = <String, String>{};
    final remaining = <String>[];

    for (final raw in cells) {
      final cell = raw.trim();
      if (cell.isEmpty) continue;

      if (!values.containsKey('postalCode') && _postalCode.hasMatch(cell)) {
        values['postalCode'] = cell;
        continue;
      }
      if (!values.containsKey('country') && _isCountry(cell)) {
        values['country'] = _canonicalCountry(cell);
        continue;
      }
      if (!values.containsKey('province') && _isProvince(cell)) {
        values['province'] = cell;
        continue;
      }
      remaining.add(cell);
    }

    // Street, suburb, city in order; anything past that is a note.
    const order = ['streetAddress', 'suburb', 'city'];
    for (var i = 0; i < remaining.length; i++) {
      if (i < order.length) {
        values[order[i]] = remaining[i];
      } else {
        values['notes'] = [
          if (values['notes']?.isNotEmpty ?? false) values['notes']!,
          remaining[i],
        ].join(' · ');
      }
    }

    return values;
  }

  static final RegExp _postalCode = RegExp(r'^\d{4}$');

  static const Set<String> _countries = {
    'south africa',
    'republic of south africa',
    'rsa',
    'za',
  };

  static const Set<String> _provinces = {
    'western cape',
    'eastern cape',
    'northern cape',
    'gauteng',
    'kwazulu-natal',
    'kwazulu natal',
    'kzn',
    'free state',
    'north west',
    'mpumalanga',
    'limpopo',
  };

  static bool _isCountry(String cell) =>
      _countries.contains(cell.toLowerCase());

  static bool _isProvince(String cell) =>
      _provinces.contains(cell.toLowerCase());

  static String _canonicalCountry(String cell) =>
      _countries.contains(cell.toLowerCase()) ? 'South Africa' : cell;

  /// One whole address on the line. Only a trailing country and postal
  /// code are lifted out — everything else stays in the street field so
  /// the geocoder sees the address exactly as written.
  ParsedAddress _parseSingleLine(String line) {
    var working = line.trim();
    final values = <String, String>{};

    // Trailing "South Africa" / "ZA".
    final countryMatch = RegExp(
      r',\s*(south africa|republic of south africa|rsa|za)\s*$',
      caseSensitive: false,
    ).firstMatch(working);
    if (countryMatch != null) {
      values['country'] = 'South Africa';
      working = working.substring(0, countryMatch.start).trim();
    }

    // Trailing 4-digit postal code, with or without a preceding comma.
    final postalMatch =
        RegExp(r'[,\s]\s*(\d{4})\s*$').firstMatch(working);
    if (postalMatch != null) {
      values['postalCode'] = postalMatch.group(1)!;
      working = working.substring(0, postalMatch.start).trim();
    }

    values['streetAddress'] = working.replaceAll(RegExp(r',\s*$'), '').trim();
    return _build(values, line);
  }

  ParsedAddress _build(Map<String, String> values, String sourceLine) {
    return ParsedAddress(
      streetAddress: values['streetAddress'] ?? '',
      suburb: values['suburb'] ?? defaultSuburb,
      city: values['city'] ?? defaultCity,
      postalCode: values['postalCode'] ?? '',
      province: values['province'] ?? defaultProvince,
      country: values['country'] ?? defaultCountry,
      notes: values['notes'] ?? '',
      sourceLine: sourceLine,
    );
  }

  // ── Text helpers ───────────────────────────────────────────────────────

  /// Split honouring double quotes, so `"Smith, J", Pinelands` is two
  /// cells rather than three.
  static List<String> _splitLine(String line, String delimiter) {
    final cells = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
        continue;
      }
      if (!inQuotes && ch == delimiter) {
        cells.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    cells.add(buffer.toString().trim());
    return cells;
  }

  /// Drop `1.`, `1)`, `-`, `•` and similar list markers from a line.
  static String _stripListMarker(String line) {
    return line
        .replaceFirst(RegExp(r'^\s*(\d+\s*[.)\-:]\s+|[-•*]\s+)'), '')
        .trim();
  }
}
