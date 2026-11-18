import 'package:clmschedule/models/dropsheet_task_type_config.dart';
import 'package:clmschedule/models/vehicle_inspection.dart';
import 'package:clmschedule/services/vehicle_inspection_service.dart';
import 'package:clmschedule/widgets/fleet/fleet_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A realistic fortnight: two vehicles out most days, one pending review
/// with a defect and a "too fast" flag, an unsafe defect yesterday, and one
/// day's start-of-day check missing.
FleetDashboardData sampleFleetData() {
  final date = DateTime(2026, 11, 3);
  final photos = {
    for (final slot in [
      for (final s in kInspectionChecklist)
        for (final i in s.items) ...i.photoSlots,
      ...kInspectionFixedSlots,
    ])
      slot: InspectionPhoto(slot: slot, path: '', sha256: ''),
  };
  final inspections = <VehicleInspection>[];
  final roster = <String, Map<String, String>>{};
  var km = 84200;
  for (var n = 13; n >= 0; n--) {
    final day = date.subtract(Duration(days: n));
    final key = VehicleInspectionService.dateKey(day);
    if (day.weekday == DateTime.sunday) {
      roster[key] = {};
      continue;
    }
    roster[key] = {'hyundai': 'Francis', 'mahindra': 'Tanaka'};
    for (final v in ['hyundai', 'mahindra']) {
      for (final kind in InspectionKind.values) {
        if (n == 0 && kind == InspectionKind.end) continue; // later today
        if (n == 5 && v == 'mahindra' && kind == InspectionKind.start) continue;
        final start = DateTime(day.year, day.month, day.day,
            kind == InspectionKind.start ? 7 : 17, 5);
        final fast = n == 0 && v == 'mahindra';
        km += 40;
        inspections.add(VehicleInspection(
          id: VehicleInspection.idFor(key, v, kind),
          date: key,
          kind: kind,
          vehicleKey: v,
          vehicleLabel: v == 'hyundai' ? 'Hyundai' : 'Mahindra',
          plateNumber: v == 'hyundai' ? 'CA 412-778' : 'CY 90-221',
          driverName: v == 'hyundai' ? 'Francis' : 'Tanaka',
          startedAt: start,
          completedAt: start.add(Duration(minutes: fast ? 1 : 8)),
          odometerKm: km,
          fuelLevel: '1/2',
          photos: photos,
          lat: -33.93,
          lng: 18.50,
          defects: [
            if (n == 0 && v == 'mahindra')
              const InspectionDefect(
                  itemId: 'body',
                  note: 'New scratch on the rear left door',
                  severity: DefectSeverity.minor),
            if (n == 1 && v == 'mahindra' && kind == InspectionKind.end)
              const InspectionDefect(
                  itemId: 'tyres',
                  note: 'Bulge on the front-right tyre wall',
                  severity: DefectSeverity.unsafe),
          ],
          review: InspectionReview(
              status: n <= 1
                  ? InspectionReviewStatus.pending
                  : InspectionReviewStatus.approved),
        ));
      }
    }
  }
  return FleetDashboardData(
    date: date,
    inspections: inspections,
    roster: roster,
    fleet: const {
      'hyundai': FleetVehicle(
          key: 'hyundai', name: 'Hyundai', plateNumber: 'CA 412-778'),
      'mahindra': FleetVehicle(
          key: 'mahindra', name: 'Mahindra', plateNumber: 'CY 90-221'),
    },
    depot: const DepotConfig(lat: -33.93, lng: 18.50),
    now: DateTime(2026, 11, 3, 14),
  );
}

Widget dashboardApp(FleetDashboardData data) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: ColorScheme.fromSeed(seedColor: Colors.blue)
            .surfaceContainer,
        body: FleetDashboard(
          data: data,
          onOpen: (_) {},
          onQuickApprove: (_) async {},
          photoUrl: (_) async => null,
        ),
      ),
    );

void main() {
  test('sample data drives the headline numbers', () {
    final data = sampleFleetData();
    expect(data.stateFor('hyundai', InspectionKind.start), ShiftState.needsReview);
    expect(data.stateFor('hyundai', InspectionKind.end), ShiftState.dueLater);
    expect(data.stateFor('nissan', InspectionKind.start), ShiftState.notOut);
    // Unsafe first, then flagged/defects, then clean ones.
    expect(data.reviewQueue.first.isUnsafe, isTrue);
    expect(data.flags[data.reviewQueue[1].id], contains(InspectionFlag.tooFast));
  });

  for (final size in const [Size(1440, 1100), Size(900, 1400), Size(390, 2400)]) {
    testWidgets('renders without overflow at ${size.width.toInt()} px',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(dashboardApp(sampleFleetData()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Review queue'), findsOneWidget);
    });
  }
}
