import 'package:clmschedule/models/vehicle_inspection.dart';
import 'package:clmschedule/widgets/fleet/fleet_dashboard.dart';
import 'package:clmschedule/widgets/fleet/fleet_vehicles_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fleet_dashboard_test.dart' show dashboardApp, sampleFleetData;

final _today = DateTime(2026, 11, 3);

/// Hyundai: disc expires in 12 days, service 640 km away. Mahindra: disc
/// expired, service overdue. Nissan: nothing set.
Map<String, FleetVehicle> sampleFleet() => {
      'hyundai': FleetVehicle(
        key: 'hyundai',
        name: 'Hyundai',
        plateNumber: 'CA 412-778',
        licenceExpiry: DateTime(2026, 11, 15),
        licenceRenewedOn: DateTime(2025, 11, 10),
        nextServiceKm: 85600,
      ),
      'mahindra': FleetVehicle(
        key: 'mahindra',
        name: 'Mahindra',
        plateNumber: 'CY 90-221',
        licenceExpiry: DateTime(2026, 10, 31),
        nextServiceKm: 84000,
      ),
    };

Widget vehiclesApp() {
  final data = sampleFleetData();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true),
    home: Scaffold(
      backgroundColor:
          ColorScheme.fromSeed(seedColor: Colors.blue).surfaceContainer,
      body: FleetVehiclesView(
        onSave: (_) async {},
        fleet: sampleFleet(),
        inspections: data.inspections,
      ),
    ),
  );
}

void main() {
  test('licence disc and service due states', () {
    final f = sampleFleet();
    expect(f['hyundai']!.licenceDue(_today), FleetDue.soon);
    expect(f['mahindra']!.licenceDue(_today), FleetDue.overdue);
    // Valid through the expiry day itself.
    expect(f['hyundai']!.licenceDue(DateTime(2026, 11, 15)), FleetDue.soon);
    expect(f['hyundai']!.licenceDue(DateTime(2026, 11, 16)), FleetDue.overdue);
    expect(const FleetVehicle(key: 'nissan', name: 'Nissan').licenceDue(_today),
        FleetDue.unknown);

    expect(f['hyundai']!.serviceDue(85000), FleetDue.soon);
    expect(f['hyundai']!.serviceDue(80000), FleetDue.ok);
    expect(f['mahindra']!.serviceDue(84500), FleetDue.overdue);
    expect(f['mahindra']!.serviceDue(null), FleetDue.unknown);
  });

  test('dates round-trip as calendar days', () {
    final v = sampleFleet()['hyundai']!;
    final back = FleetVehicle.fromMap('hyundai', v.toMap());
    expect(v.toMap()['licenceExpiry'], '2026-11-15');
    expect(back.licenceExpiry, DateTime(2026, 11, 15));
    expect(back.licenceRenewedOn, DateTime(2025, 11, 10));
    expect(back.nextServiceKm, 85600);
  });

  for (final size in const [Size(1200, 1000), Size(390, 1800)]) {
    testWidgets('vehicles view renders at ${size.width.toInt()} px',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(vehiclesApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Licence disc expiry'), findsNWidgets(3));
    });
  }

  testWidgets('dashboard cards tag a disc or service that is due',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final base = sampleFleetData();
    await tester.pumpWidget(dashboardApp(FleetDashboardData(
      date: base.date,
      inspections: base.inspections,
      roster: base.roster,
      fleet: sampleFleet(),
      depot: base.depot,
      now: base.now,
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Disc expires in 12 days'), findsOneWidget);
    expect(find.textContaining('Disc expired'), findsOneWidget);
  });
}
