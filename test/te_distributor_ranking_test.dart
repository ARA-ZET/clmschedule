import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/services/te_gpx_matching.dart';

/// When a track's file name matches no distributor, the picker lists the
/// closest names first — the name in the file is usually just misspelt.
void main() {
  var i = 0;
  Distributor d(String name) => Distributor(id: name, name: name, index: i++);
  final team = [
    d('Tichaona'),
    d('Dickson'),
    d('Hakizimana'),
    d('Marlon Smith'),
    d('Samuel'),
  ];

  String top(String key) =>
      rankDistributorsByName(key, team).first.distributor.name;

  test('a misspelt first name ranks the right distributor first', () {
    expect(top('16 sep 2026 tichona rondebosch 412'), 'Tichaona');
    expect(top('16 sep 2026 dixon claremont 380'), 'Dickson');
    expect(top('16 sep 2026 hakizmana wynberg 290'), 'Hakizimana');
  });

  test('dates and counts in the file name are ignored', () {
    final ranked = rankDistributorsByName('16 sep 2026 400', team);
    expect(ranked.every((r) => r.score == 0), isTrue);
  });

  test('a name that starts like a month is still matched', () {
    // "Marlon" must not be dropped as if it were "Mar(ch)".
    expect(top('3 mar 2026 marlon kenilworth 120'), 'Marlon Smith');
  });

  test('an exact name scores 1', () {
    final ranked = rankDistributorsByName('16 sep 2026 samuel 10', team);
    expect(ranked.first.distributor.name, 'Samuel');
    expect(ranked.first.score, 1.0);
  });
}
