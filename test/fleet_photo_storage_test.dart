import 'package:clmschedule/models/vehicle_inspection.dart';
import 'package:clmschedule/widgets/fleet/fleet_photo_storage_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime(2026, 11, 3);

/// One inspection a day for 80 days, 17 photos of ~450 KB each. Day 40 is
/// still pending, day 45 has a defect, day 50's photos were already cleared.
List<VehicleInspection> sampleStorage() {
  final list = <VehicleInspection>[];
  for (var n = 0; n < 80; n++) {
    final day = _today.subtract(Duration(days: n));
    final key = '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final id = VehicleInspection.idFor(key, 'hyundai', InspectionKind.start);
    list.add(VehicleInspection(
      id: id,
      date: key,
      kind: InspectionKind.start,
      vehicleKey: 'hyundai',
      driverName: 'Francis',
      photos: {
        for (var p = 0; p < 17; p++)
          'slot$p': InspectionPhoto(
              slot: 'slot$p',
              path: 'vehicleInspections/$key/$id/slot${p}_abc123.jpg',
              bytes: 450 * 1024),
      },
      defects: n == 45
          ? const [
              InspectionDefect(
                  itemId: 'body', note: 'Dent', severity: DefectSeverity.minor)
            ]
          : const [],
      review: InspectionReview(
          status: n < 2 || n == 40
              ? InspectionReviewStatus.pending
              : InspectionReviewStatus.approved),
      photosClearedAt: n == 50 ? DateTime(2026, 10, 1) : null,
    ));
  }
  return list;
}

Widget storageApp({
  required Future<void> Function(VehicleInspection) clear,
  bool canClear = true,
}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true),
      home: Scaffold(
        backgroundColor:
            ColorScheme.fromSeed(seedColor: Colors.blue).surfaceContainer,
        body: FleetPhotoStorageView(
          load: () async => sampleStorage(),
          clear: clear,
          canClear: canClear,
          today: _today,
          photoUrl: (_) async => null,
          onOpen: (_) {},
        ),
      ),
    );

void main() {
  testWidgets('clears only old, reviewed, defect-free photos', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cleared = <String>[];
    await tester
        .pumpWidget(storageApp(clear: (i) async => cleared.add(i.date)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 79 inspections still hold photos (day 50 was cleared already).
    expect(find.textContaining('from 79 inspections'), findsOneWidget);

    // Older than 30 days = days 31..79 = 49, minus day 40 (pending),
    // day 45 (defect) and day 50 (already cleared) = 46.
    expect(find.textContaining('from 46 inspections dated before 4 Oct 2026'),
        findsOneWidget);

    // Gallery: newest inspection first, five at a time.
    expect(
        find.textContaining('Tue 3 Nov · hyundai · Francis'), findsOneWidget);
    expect(find.text('Show more (74 left)'), findsOneWidget);

    await tester.ensureVisible(find.text('Clear photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear photos'));
    await tester.pumpAndSettle();
    expect(find.text('Clear inspection photos?'), findsOneWidget);
    await tester.tap(find.text('Delete photos'));
    await tester.pumpAndSettle();
    expect(cleared, hasLength(46));
    expect(cleared, isNot(contains('2026-09-24'))); // day 40, pending
    expect(cleared, isNot(contains('2026-09-19'))); // day 45, defect
  });

  testWidgets('non-admins see usage but cannot clear', (tester) async {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(storageApp(clear: (_) async {}, canClear: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final button = tester.widget<FilledButton>(find.ancestor(
        of: find.text('Clear photos'), matching: find.byType(FilledButton)));
    expect(button.onPressed, isNull);
  });
}
