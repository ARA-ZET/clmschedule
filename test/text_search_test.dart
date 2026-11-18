import 'package:clmschedule/utils/text_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool m(String q, List<String?> fields) => TextSearch(q).matches(fields);

  test('empty query matches everything', () {
    expect(m('', ['anything']), isTrue);
    expect(m('  - ', ['anything']), isTrue);
  });

  test('plain substring still works', () {
    expect(m('bos', ['Rondebosch']), isTrue);
    expect(m('ROND', ['Rondebosch']), isTrue);
  });

  test('words in any order, all required', () {
    expect(m('smith joh', ['John Smith']), isTrue);
    expect(m('john xyz', ['John Smith']), isFalse);
    expect(m('smith rondebosch', ['John Smith', 'Rondebosch']), isTrue);
  });

  test('punctuation, spacing and accents ignored', () {
    expect(m('st james', ['St. James']), isTrue);
    expect(m('vanderwalt', ['Van der Walt']), isTrue);
    expect(m('inv-001234', ['INV 001234']), isTrue);
    expect(m('kleinbosch', ['Kléinbosch']), isTrue);
    expect(m('kléin', ['Kleinbosch']), isTrue);
  });

  test('typos on longer words', () {
    expect(m('rondebsoch', ['Rondebosch']), isTrue);
    expect(m('kenilwrth', ['Kenilworth']), isTrue);
    expect(m('bosch', ['Thompson']), isFalse);
    expect(m('rondebosch', ['Rosebank']), isFalse);
  });

  test('short and numeric words are never fuzzy', () {
    expect(m('abc', ['acb']), isFalse);
    expect(m('1234', ['1243']), isFalse);
    expect(m('inv1234', ['inv1243']), isFalse);
  });

  test('ranking: exact > prefix > substring > fuzzy, ties keep order', () {
    final items = ['Rondebsoch', 'Rondebosch East', 'Bosch', 'Rondebosch'];
    final ranked = TextSearch('rondebosch').rank(items, (s) => [s]);
    expect(ranked.first, 'Rondebosch East'); // exact word, earlier in input
    expect(ranked[1], 'Rondebosch');
    expect(ranked.last, 'Rondebsoch'); // fuzzy
    expect(ranked, isNot(contains('Bosch')));

    final prefix = TextSearch('ron').rank(['Baron', 'Ronald'], (s) => [s]);
    expect(prefix, ['Ronald', 'Baron']);
  });

  test('earlier fields weigh more', () {
    final ranked = TextSearch('smith').rank(
      [('a', 'smith.gpx'), ('b', 'other.gpx')],
      (e) => e.$1 == 'a' ? ['notes.gpx', 'Smith'] : ['Smith.gpx', 'x'],
    );
    expect(ranked.first.$1, 'b');
  });

  test('null and empty fields are skipped', () {
    expect(m('john', [null, '', 'John']), isTrue);
    expect(m('john', [null]), isFalse);
  });
}
