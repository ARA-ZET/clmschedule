// Track Editor saves made quicker (2026-11-10): the wage-stats save writes
// only its own payslip and returns once that is committed, and cloud
// uploads are tracked in the save-state provider so a finished upload ticks
// the right client even after a tab switch or a re-resolve.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/payroll_daily_entry.dart';
import 'package:clmschedule/models/payroll_settings.dart';
import 'package:clmschedule/services/payroll_service.dart';
import 'package:clmschedule/services/sync_status.dart';
import 'package:clmschedule/track_editor/models/tab_item.dart';
import 'package:clmschedule/track_editor/providers/te_cloud_save_state_provider.dart';
import 'package:clmschedule/utils/payroll_week.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('saveDailyEntryForDistributor', () {
    final settings = PayrollSettings.defaults();
    final anna = Distributor(id: 'anna', name: 'Anna', index: 0);
    final ben = Distributor(id: 'ben', name: 'Ben', index: 1);
    // A Monday well before the live week, so no deduction pass runs.
    final day = DateTime(2026, 10, 5);

    PayrollDailyEntry sets(int n) =>
        PayrollDailyEntry(date: day, worked: true, flyerSets: n);

    String weekPath(DateTime d) {
      final ws = weekStartFor(d);
      return 'payroll/${yearIdFor(ws)}/${monthLabelFor(ws)}/${weekIdFor(ws)}';
    }

    test('creates the week and payslip when neither exists', () async {
      final db = FakeFirebaseFirestore();
      final service = PayrollService(firestore: db);

      await service.saveDailyEntryForDistributor(
          distributor: anna, date: day, entry: sets(3), settings: settings);

      final week = await service.getWeek(day);
      final slip = week.payslips['anna']!;
      expect(slip.dailyEntries[dayKeyFor(day)]!.flyerSets, 3);
      expect(slip.grossWage, greaterThan(0), reason: 'recomputed on save');
    });

    test("writes only its own payslip — another distributor's is left as "
        'stored', () async {
      final db = FakeFirebaseFirestore();
      final service = PayrollService(firestore: db);
      await service.saveDailyEntryForDistributor(
          distributor: ben, date: day, entry: sets(2), settings: settings);
      // A value no recompute would produce: the old whole-week write
      // recomputed (and rewrote) every payslip in the week.
      await db.doc(weekPath(day)).update({'payslips.ben.grossWage': 999});

      await service.saveDailyEntryForDistributor(
          distributor: anna, date: day, entry: sets(4), settings: settings);

      final week = await service.getWeek(day);
      expect(week.payslips['ben']!.grossWage, 999);
      expect(
          week.payslips['anna']!.dailyEntries[dayKeyFor(day)]!.flyerSets, 4);
    });

    test('updating a day keeps the payslip\'s other days', () async {
      final db = FakeFirebaseFirestore();
      final service = PayrollService(firestore: db);
      final tuesday = day.add(const Duration(days: 1));
      await service.saveDailyEntryForDistributor(
          distributor: anna, date: day, entry: sets(2), settings: settings);
      await service.saveDailyEntryForDistributor(
          distributor: anna,
          date: tuesday,
          entry: PayrollDailyEntry(date: tuesday, worked: true, flyerSets: 5),
          settings: settings);
      await service.saveDailyEntryForDistributor(
          distributor: anna, date: day, entry: sets(6), settings: settings);

      final entries = (await service.getWeek(day)).payslips['anna']!.dailyEntries;
      expect(entries[dayKeyFor(day)]!.flyerSets, 6);
      expect(entries[dayKeyFor(tuesday)]!.flyerSets, 5);
    });

    test('on the live week, returns before the advance deduction pass and '
        'counts it as a pending write until it ends', () async {
      final db = FakeFirebaseFirestore();
      final service = PayrollService(firestore: db);
      final today = scheduleNow();

      await service.saveDailyEntryForDistributor(
          distributor: anna,
          date: today,
          entry: PayrollDailyEntry(date: today, worked: true, flyerSets: 1),
          settings: settings);

      expect(SyncStatus.instance.pendingWriteCount, greaterThan(0),
          reason: 'the deduction pass is still running');
      for (var i = 0;
          i < 50 && SyncStatus.instance.pendingWriteCount > 0;
          i++) {
        await pumpEventQueue();
      }
      expect(SyncStatus.instance.pendingWriteCount, 0);
    });
  });

  group('cloud save uploads', () {
    TECloudSaveClientEntry client(String name, {String folder = 'F/A'}) =>
        TECloudSaveClientEntry(
          clientName: name,
          distributorName: 'Anna',
          date: DateTime(2026, 11, 10),
          polygons: const [],
          folderPath: folder,
        );

    /// A tab with [clients] resolved onto it.
    (TECloudSaveStateProvider, TETabItem) resolved(
        List<TECloudSaveClientEntry> clients) {
      final p = TECloudSaveStateProvider();
      final tab = _tab();
      p.finishResolveSuccess(p.beginResolve(tab), clients);
      return (p, tab);
    }

    test('a finished upload ticks the client and clears its spinner', () {
      final seeff = client('Seeff');
      final (p, _) = resolved([seeff]);

      final upload = p.beginUpload(seeff, trimmed: false)!;
      expect(seeff.uploadingAsIs, isTrue);
      p.finishUpload(upload, saved: true);

      expect(seeff.uploadingAsIs, isFalse);
      expect(seeff.savedAsIs, isTrue);
    });

    test('lands on the new entry when a re-resolve replaced the old one '
        'mid-upload', () {
      final old = client('Seeff');
      final (p, tab) = resolved([old]);
      final upload = p.beginUpload(old, trimmed: false)!;

      final fresh = client('Seeff');
      p.finishResolveSuccess(p.beginResolve(tab), [fresh]);
      expect(fresh.uploadingAsIs, isTrue, reason: 'spinner carried over');

      p.finishUpload(upload, saved: true);
      expect(fresh.savedAsIs, isTrue);
      expect(fresh.uploadingAsIs, isFalse);
    });

    test('lands on its own tab after the schedule sync re-keys it', () {
      final seeff = client('Seeff');
      final (p, tab) = resolved([seeff]);
      final upload = p.beginUpload(seeff, trimmed: false)!;

      final swapped = _tab();
      p.markStale(tab, swapped);
      p.finishUpload(upload, saved: true);

      expect(p.clientsFor(swapped).single.savedAsIs, isTrue);
    });

    test('never ticks a different client', () {
      final seeff = client('Seeff');
      final pam = client('Pam Golding');
      final (p, _) = resolved([seeff, pam]);

      p.finishUpload(p.beginUpload(seeff, trimmed: false)!, saved: true);

      expect(seeff.savedAsIs, isTrue);
      expect(pam.savedAsIs, isFalse);
    });

    test('a folder changed mid-upload is not shown as saved', () {
      final seeff = client('Seeff');
      final (p, _) = resolved([seeff]);
      final upload = p.beginUpload(seeff, trimmed: false)!;

      p.setFolder(seeff, 'F/Other', exists: true);
      p.finishUpload(upload, saved: true);

      expect(seeff.savedAsIs, isFalse);
      expect(seeff.uploadingAsIs, isFalse);
    });

    test('a trim whose ticked areas changed mid-upload is not shown as '
        'saved', () {
      final seeff = client('Seeff')..selectedPolyIndices.add(0);
      final (p, _) = resolved([seeff]);
      final upload = p.beginUpload(seeff, trimmed: true)!;

      p.toggleSelectedPoly(seeff, 1);
      p.finishUpload(upload, saved: true);

      expect(seeff.trimmedSaved, isFalse);
      expect(seeff.uploadingTrimmed, isFalse);
    });

    test('a failed upload clears the spinner without ticking', () {
      final seeff = client('Seeff');
      final (p, _) = resolved([seeff]);

      p.finishUpload(p.beginUpload(seeff, trimmed: false)!, saved: false);

      expect(seeff.uploadingAsIs, isFalse);
      expect(seeff.savedAsIs, isFalse);
    });
  });
}

TETabItem _tab() => TETabItem(
      title: 'track.gpx',
      tracks: [],
      waypoints: [],
      polygons: [],
      targetPolygons: [],
    );
