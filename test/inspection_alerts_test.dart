import 'package:clmschedule/models/dropsheet_task_type_config.dart';
import 'package:clmschedule/models/vehicle_inspection.dart';
import 'package:clmschedule/services/vehicle_inspection_service.dart';
import 'package:clmschedule/widgets/fleet/inspection_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VehicleInspection _inspection({
  required String vehicle,
  required String driver,
  int minutes = 8,
  double lat = -33.93,
  List<InspectionDefect> defects = const [],
}) {
  final start = DateTime(2026, 11, 3, 7, 4);
  return VehicleInspection(
    id: VehicleInspection.idFor('2026-11-03', vehicle, InspectionKind.start),
    date: '2026-11-03',
    kind: InspectionKind.start,
    vehicleKey: vehicle,
    vehicleLabel: vehicle == 'hyundai' ? 'Hyundai' : 'Mahindra',
    plateNumber: vehicle == 'hyundai' ? 'CA 412-778' : 'CY 90-221',
    driverName: driver,
    startedAt: start,
    completedAt: start.add(Duration(minutes: minutes)),
    lat: lat,
    lng: 18.50,
    defects: defects,
    review: const InspectionReview(status: InspectionReviewStatus.pending),
  );
}

const _depot = DepotConfig(lat: -33.93, lng: 18.50);

List<String> _attention(VehicleInspection i) =>
    VehicleInspectionService.attentionPoints(
      i,
      VehicleInspectionService.flagsFor(i, history: const [], depot: _depot)
        ..remove(InspectionFlag.missingPhotos),
      depot: _depot,
    );

List<VehicleInspection> _samples() {
  final unsafe = _inspection(
    vehicle: 'mahindra',
    driver: 'Tanaka',
    defects: const [
      InspectionDefect(
          itemId: 'tyres',
          note: 'Bulge on the front-right tyre wall',
          severity: DefectSeverity.unsafe),
    ],
  );
  final flagged = _inspection(
    vehicle: 'hyundai',
    driver: 'Francis',
    minutes: 1,
    lat: -33.95,
    defects: const [
      InspectionDefect(
          itemId: 'body',
          note: 'New scratch on the rear left door',
          severity: DefectSeverity.minor),
    ],
  );
  final clean = _inspection(vehicle: 'hyundai', driver: 'Francis');
  return [unsafe, flagged, clean];
}

Widget _cardsApp(List<VehicleInspection> list) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color.fromARGB(255, 222, 222, 222),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            for (final i in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InspectionAlertCard(
                  inspection: i,
                  attention: _attention(i),
                  onReview: () {},
                  onDismiss: () {},
                ),
              ),
          ]),
        ),
      ),
    );

void main() {
  final [unsafe, flagged, clean] = _samples();

  test('attention points spell out what is wrong', () {
    expect(_attention(unsafe), isEmpty); // unsafe is a defect, not a flag
    final points = _attention(flagged);
    expect(points, contains('Done in 1 min — too fast for every photo'));
    expect(points.any((p) => p.contains('km from the depot')), isTrue);
    expect(_attention(clean), isEmpty);
  });

  for (final width in const [380.0, 300.0]) {
    testWidgets('cards render without overflow at ${width.toInt()} px',
        (tester) async {
      tester.view.physicalSize = Size(width + 32, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_cardsApp(_samples()));
      expect(tester.takeException(), isNull);
      expect(find.text('Unsafe — do not drive'), findsOneWidget);
      expect(find.text('Needs attention'), findsWidgets);
      expect(find.text('All checks OK'), findsOneWidget);
    });
  }
}
