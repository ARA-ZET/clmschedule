// services/regular_client_matcher.dart
//
// Picks the regular client a Job List client name most likely means. Client
// names are free text, so this ranks loosely: exact (name or alias), then one
// containing the other, then shared words.
import '../models/regular_client.dart';
import 'client_map_allocation_service.dart';

class RegularClientMatcher {
  /// Minimum share of words in common for a word-overlap match.
  static const double kMinTokenOverlap = 0.5;

  /// The best match for [client] in [all], or null when none is close enough.
  static RegularClient? bestMatch(String client, List<RegularClient> all) {
    final want = ClientMapAllocationService.normaliseClient(client);
    if (want.isEmpty || all.isEmpty) return null;
    final wantTokens = _tokens(client);

    RegularClient? best;
    var bestScore = 0.0;
    for (final rc in all) {
      for (final name in [rc.name, ...rc.aliases]) {
        final score = _score(want, wantTokens, name);
        if (score > bestScore) {
          bestScore = score;
          best = rc;
        }
      }
    }
    return best;
  }

  /// 3 = exact, 2..3 = containment (longer overlap scores higher),
  /// 1..2 = word overlap at or above [kMinTokenOverlap], 0 = no match.
  static double _score(String want, Set<String> wantTokens, String name) {
    final have = ClientMapAllocationService.normaliseClient(name);
    if (have.isEmpty) return 0;
    if (have == want) return 3;
    // Containment needs a few characters, or "a" would match everything.
    final shorter = want.length < have.length ? want : have;
    final longer = want.length < have.length ? have : want;
    if (shorter.length >= 3 && longer.contains(shorter)) {
      return 2 + shorter.length / longer.length;
    }
    final haveTokens = _tokens(name);
    if (wantTokens.isEmpty || haveTokens.isEmpty) return 0;
    final common = wantTokens.intersection(haveTokens).length;
    final overlap = common /
        (wantTokens.length < haveTokens.length
            ? wantTokens.length
            : haveTokens.length);
    return overlap >= kMinTokenOverlap ? 1 + overlap : 0;
  }

  static Set<String> _tokens(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length >= 2)
      .toSet();
}
