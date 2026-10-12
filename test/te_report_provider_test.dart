// Selection logic for the Report panel: full-report vs. a hand-picked
// subset of promoter days, and the "toggling one day silently drops
// everything else" trap the full<->custom switch is written to avoid.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/providers/te_report_provider.dart';
import 'package:flutter_test/flutter_test.dart';

Distributor _d(String id, String name) =>
    Distributor(id: id, name: name, index: 0);

TEPromoterDay _day(String distributorId, String name, DateTime date) =>
    TEPromoterDay(
      distributor: _d(distributorId, name),
      date: date,
      tracks: const [],
      waypoints: const [],
      sourcePaths: const [],
    );

void main() {
  late TEReportProvider p;
  late List<TEPromoterDay> days;

  setUp(() {
    p = TEReportProvider();
    days = [
      _day('d1', 'Nolan', DateTime(2026, 5, 11)),
      _day('d1', 'Nolan', DateTime(2026, 5, 12)),
      _day('d2', 'Thandiwe', DateTime(2026, 5, 11)),
    ];
    p.seedDaysForTest(days);
  });

  test('starts as a full report — every day selected', () {
    expect(p.fullReport, isTrue);
    expect(p.selectedDays, hasLength(3));
    for (final d in days) {
      expect(p.isSelected(d), isTrue);
    }
  });

  test('unchecking one day switches out of full report and keeps the rest', () {
    p.toggleDay(days[0], false);
    expect(p.fullReport, isFalse);
    expect(p.selectedDays, hasLength(2));
    expect(p.isSelected(days[0]), isFalse);
    expect(p.isSelected(days[1]), isTrue);
    expect(p.isSelected(days[2]), isTrue);
  });

  test('re-checking every day back does not silently re-enable full report',
      () {
    // Explicit re-selection of everything is still "custom" — only the
    // Full report toggle itself means "full report".
    p.toggleDay(days[0], false);
    p.toggleDay(days[0], true);
    expect(p.fullReport, isFalse);
    expect(p.selectedDays, hasLength(3));
  });

  test('switching Full report back on restores everything', () {
    p.toggleDay(days[0], false);
    p.toggleDay(days[1], false);
    expect(p.selectedDays, hasLength(1));

    p.setFullReport(true);
    expect(p.fullReport, isTrue);
    expect(p.selectedDays, hasLength(3));
  });

  test(
      'turning OFF full report with nothing chosen yet keeps everything '
      'selected rather than producing an empty PDF', () {
    p.setFullReport(false);
    expect(p.fullReport, isFalse);
    expect(p.selectedDays, hasLength(3));
  });

  test('Deselect all empties the selection; Select all brings it back', () {
    p.selectAll(false);
    expect(p.fullReport, isFalse);
    expect(p.selectedDays, isEmpty);

    p.selectAll(true);
    expect(p.fullReport, isFalse);
    expect(p.selectedDays, hasLength(3));
  });

  test('selectAllForDate toggles every promoter on that date only', () {
    p.selectAllForDate(DateTime(2026, 5, 11), false);
    expect(p.fullReport, isFalse);
    expect(p.isSelected(days[0]), isFalse); // Nolan, 11 May
    expect(p.isSelected(days[2]), isFalse); // Thandiwe, 11 May
    expect(p.isSelected(days[1]), isTrue); // 12 May untouched
    expect(p.selectedDays, hasLength(1));

    p.selectAllForDate(DateTime(2026, 5, 11, 14, 30), true); // time ignored
    expect(p.selectedDays, hasLength(3));
  });

  test('a fresh scan clears the previous selection', () {
    p.toggleDay(days[0], false);
    p.seedDaysForTest([days[2]]);
    expect(p.fullReport, isTrue);
    expect(p.selectedDays, hasLength(1));
  });

  test('proof photos are offered once per date, not once per promoter', () {
    // Two promoters on 11 May and one on 12 May: two dates, oldest first.
    expect(p.dates, [DateTime(2026, 5, 11), DateTime(2026, 5, 12)]);
    expect(p.photosFor(DateTime(2026, 5, 11)), isEmpty);
    expect(p.photosByDate, isEmpty);
  });

  test('clear() resets to the empty/idle state', () {
    p.toggleDay(days[0], false);
    p.clear();
    expect(p.hasFolder, isFalse);
    expect(p.status, TEReportScanStatus.idle);
    expect(p.days, isEmpty);
    expect(p.fullReport, isTrue);
  });
}
