// Selection logic for the Report panel: full-report vs. a hand-picked
// subset of promoter days, and the "toggling one day silently drops
// everything else" trap the full<->custom switch is written to avoid.
import 'dart:typed_data';

import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/providers/te_report_provider.dart';
import 'package:clmschedule/track_editor/services/te_folder_photos.dart';
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

  test('hand-typed where-worked text is kept per shift and cleared by a scan',
      () {
    p.setWhereOverride(days[0], 'Main Rd & Church St');
    expect(p.whereOverrideFor(days[0]), 'Main Rd & Church St');
    expect(p.whereOverrideFor(days[1]), isNull);
    expect(p.whereOverrides, {days[0].key: 'Main Rd & Church St'});

    p.setWhereOverride(days[0], null);
    expect(p.whereOverrideFor(days[0]), isNull);

    p.setWhereOverride(days[2], 'Durban Rd');
    p.seedDaysForTest(days);
    expect(p.whereOverrides, isEmpty);
  });

  group('folder photos and choices kept across scans', () {
    TEProofPhoto photo(String name, [DateTime? at]) => TEProofPhoto(
        bytes: Uint8List(1), fileName: name, storagePath: 'job/$name',
        takenAt: at);

    test('an undated photo can be put on a date, which chooses it, and the '
        'next scan keeps it there', () {
      final x = photo('x.jpg');
      p.seedScanForTest(days, TEFolderPhotos(undated: [x]));
      expect(p.undatedPhotos, [x]);
      final before = p.revision;

      p.assignPhoto(x, DateTime(2026, 5, 12));
      expect(p.undatedPhotos, isEmpty);
      expect(p.photosFor(DateTime(2026, 5, 12)), [x]);
      expect(p.photoDates, {'job/x.jpg': DateTime(2026, 5, 12)});
      expect(p.isChosen(x), isTrue);
      expect(p.revision, greaterThan(before));

      p.seedScanForTest(days, TEFolderPhotos(undated: [photo('x.jpg')]));
      expect(p.undatedPhotos, isEmpty);
      final again = p.photosFor(DateTime(2026, 5, 12)).single;
      expect(again.fileName, 'x.jpg');
      expect(p.isChosen(again), isTrue);
    });

    test('folder photos are left out until chosen; the choice is kept by '
        'path across scans', () {
      final a = photo('a.jpg', DateTime(2026, 5, 11, 9));
      final b = photo('b.jpg', DateTime(2026, 5, 11, 10));
      final c = photo('c.jpg', DateTime(2026, 5, 12, 8));
      p.seedScanForTest(
          days,
          TEFolderPhotos(byDate: {
            DateTime(2026, 5, 11): [a, b],
            DateTime(2026, 5, 12): [c],
          }));
      expect(p.availablePhotoCount, 3);
      expect(p.photoCount, 0);
      expect(p.chosenPhotosByDate, isEmpty);

      p.setPhotoChosen(b, true);
      p.setChosenForDate(DateTime(2026, 5, 12), true);
      expect(p.photoCount, 2);
      expect(p.chosenPhotosFor(DateTime(2026, 5, 11)), [b]);
      expect(p.chosenPhotoPaths, {'job/b.jpg', 'job/c.jpg'});
      expect(p.chosenPhotoBytes, 2);

      p.setPhotoChosen(c, false);
      expect(p.chosenPhotosByDate.keys, [DateTime(2026, 5, 11)]);

      p.seedScanForTest(
          days,
          TEFolderPhotos(byDate: {
            DateTime(2026, 5, 11): [photo('a.jpg'), photo('b.jpg')],
          }));
      expect(p.chosenPhotosFor(DateTime(2026, 5, 11)).single.fileName,
          'b.jpg');
    });

    test('the chooser\'s choices land in one change', () {
      final a = photo('a.jpg', DateTime(2026, 5, 11, 9));
      final b = photo('b.jpg', DateTime(2026, 5, 11, 10));
      final x = photo('x.jpg');
      p.seedScanForTest(
          days,
          TEFolderPhotos(byDate: {
            DateTime(2026, 5, 11): [a, b]
          }, undated: [x]));
      p.setPhotoChosen(a, true);
      final before = p.revision;

      p.applyPhotoChoices(
          assigned: {x: DateTime(2026, 5, 12)}, chosen: {b, x});
      expect(p.revision, before + 1);
      expect(p.isChosen(a), isFalse);
      expect(p.isChosen(b), isTrue);
      expect(p.chosenPhotosFor(DateTime(2026, 5, 12)), [x]);
      expect(p.undatedPhotos, isEmpty);

      // Nothing new: no change.
      p.applyPhotoChoices(chosen: {b, x});
      expect(p.revision, before + 1);
    });

    test('a photo with no date cannot be chosen until it is put on one', () {
      final x = photo('x.jpg');
      p.seedScanForTest(days, TEFolderPhotos(undated: [x]));
      p.setPhotoChosen(x, true);
      expect(p.isChosen(x), isFalse);
      expect(p.photoCount, 0);
    });

    test('unticked days survive a rescan, and a new day comes in ticked', () {
      p.toggleDay(days[2], false);
      expect(p.unselectedKeys, {days[2].key});

      // The folder holding days[2] is unticked: it is gone, not forgotten.
      p.seedScanForTest([days[0], days[1]]);
      expect(p.selectedDays, hasLength(2));
      expect(p.unselectedKeys, {days[2].key});

      final newcomer = _day('d3', 'Sipho', DateTime(2026, 5, 12));
      p.seedScanForTest([...days, newcomer]);
      expect(p.isSelected(days[2]), isFalse);
      expect(p.isSelected(newcomer), isTrue);
      expect(p.selectedDays, hasLength(3));
    });

    test('a draft\'s choices apply on the first scan', () {
      final fresh = TEReportProvider()
        ..restoreChoices(
          unselected: {days[0].key},
          where: {days[1].key: 'Main Rd & Kloof St'},
          chosenPhotos: {'job/y.jpg'},
          photoDates: {'job/y.jpg': DateTime(2026, 5, 11, 15)},
        );
      fresh.seedScanForTest(days, TEFolderPhotos(undated: [photo('y.jpg')]));
      expect(fresh.photoCount, 1);
      expect(fresh.isSelected(days[0]), isFalse);
      expect(fresh.selectedDays, hasLength(2));
      expect(fresh.whereOverrideFor(days[1]), 'Main Rd & Kloof St');
      expect(fresh.photosFor(DateTime(2026, 5, 11)).single.fileName, 'y.jpg');
    });
  });
}
