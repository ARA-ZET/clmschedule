/// Forgiving text search shared by every in-app search box.
///
/// A plain `contains` misses multi-word, reordered, punctuated or misspelt
/// queries. [TextSearch] splits the query into words and requires every word
/// to match somewhere (in any order), ignores case, accents, punctuation and
/// spacing, and lets longer words through on a close spelling via trigram
/// similarity — "rondebsoch" finds "Rondebosch".
///
/// Zoho and Xero searches are not routed through here: those APIs search
/// server-side.
library;

const Map<String, String> _accentFold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
  'ç': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
final RegExp _digit = RegExp(r'[0-9]');

/// Lowercase, fold accents, turn every non-letter/digit run into one space.
String normalizeForSearch(String s) {
  final lower = s.toLowerCase();
  final buf = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(_accentFold[ch] ?? ch);
  }
  return buf.toString().replaceAll(_nonAlnum, ' ').trim();
}

Set<String> _trigrams(String word) {
  final padded = '  $word ';
  return {
    for (var i = 0; i + 3 <= padded.length; i++) padded.substring(i, i + 3),
  };
}

double _dice(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var common = 0;
  for (final t in a) {
    if (b.contains(t)) common++;
  }
  return 2 * common / (a.length + b.length);
}

/// A field value prepared for matching. Memoised by raw text so re-filtering
/// a large list on each keystroke doesn't re-normalise it.
class _Haystack {
  final String normalized;
  final String compact;
  final List<String> words;
  List<Set<String>>? _wordTrigrams;

  _Haystack(this.normalized)
      : compact = normalized.replaceAll(' ', ''),
        words = normalized.isEmpty ? const [] : normalized.split(' ');

  List<Set<String>> get wordTrigrams =>
      _wordTrigrams ??= [for (final w in words) _trigrams(w)];

  static final Map<String, _Haystack> _cache = {};
  // Big enough for a whole Cloud Files scope's names, so retyping doesn't
  // re-normalise them; cleared wholesale when full.
  static const int _maxCache = 20000;

  static _Haystack of(String raw) {
    final hit = _cache[raw];
    if (hit != null) return hit;
    if (_cache.length >= _maxCache) _cache.clear();
    return _cache[raw] = _Haystack(normalizeForSearch(raw));
  }
}

class _Token {
  final String text;
  final bool fuzzy;
  final Set<String> trigrams;

  /// Minimum trigram similarity for a close spelling. 0.5 lets one swapped or
  /// dropped letter through ("rondebsoch", "kenilwrth") but not a shared tail
  /// ("bosch" vs "rondebosch" is 0.47).
  static const double _threshold = 0.5;

  _Token(this.text)
      : fuzzy = text.length >= 4 && !_digit.hasMatch(text),
        trigrams = _trigrams(text);

  /// 4 whole word, 3 word prefix, 2 substring, 0–1 close spelling, 0 none.
  double scoreIn(_Haystack h) {
    var best = 0.0;
    for (final w in h.words) {
      if (w == text) return 4;
      if (best < 3 && w.startsWith(text)) best = 3;
    }
    if (best > 0) return best;
    if (h.normalized.contains(text) || h.compact.contains(text)) return 2;
    if (!fuzzy) return 0;
    for (final wt in h.wordTrigrams) {
      final sim = _dice(trigrams, wt);
      if (sim >= _threshold && sim > best) best = sim;
    }
    return best;
  }
}

class TextSearch {
  final List<_Token> _tokens;

  TextSearch(String raw)
      : _tokens = [
          for (final t in normalizeForSearch(raw).split(' '))
            if (t.isNotEmpty) _Token(t),
        ];

  /// True when the query has no letters or digits — everything matches.
  bool get isEmpty => _tokens.isEmpty;

  /// Match score across [fields] (earlier fields weigh slightly more), or
  /// null when some query word matches none of them.
  double? score(Iterable<String?> fields) {
    if (_tokens.isEmpty) return 0;
    final hays = [
      for (final f in fields)
        if (f != null && f.isNotEmpty) _Haystack.of(f),
    ];
    if (hays.isEmpty) return null;
    var total = 0.0;
    for (final token in _tokens) {
      var best = 0.0;
      for (var i = 0; i < hays.length; i++) {
        final s = token.scoreIn(hays[i]) / (1 + 0.1 * i);
        if (s > best) best = s;
      }
      if (best == 0) return null;
      total += best;
    }
    return total;
  }

  bool matches(Iterable<String?> fields) => score(fields) != null;

  /// Items that match, best first; equal scores keep their input order.
  List<T> rank<T>(Iterable<T> items, Iterable<String?> Function(T) fields) {
    if (_tokens.isEmpty) return items.toList();
    final scored = <(T, double, int)>[];
    var i = 0;
    for (final item in items) {
      final s = score(fields(item));
      if (s != null) scored.add((item, s, i));
      i++;
    }
    scored.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$3.compareTo(b.$3);
    });
    return [for (final e in scored) e.$1];
  }
}
