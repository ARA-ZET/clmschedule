import 'package:clmschedule/models/dropsheet_task_type_config.dart';
import 'package:clmschedule/models/vehicle_inspection.dart';
import 'package:clmschedule/services/vehicle_inspection_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, InspectionPhoto> _allPhotos(String prefix) => {
      for (final slot in [
        for (final s in kInspectionChecklist)
          for (final i in s.items) ...i.photoSlots,
        ...kInspectionFixedSlots,
      ])
        slot: InspectionPhoto(slot: slot, path: 'p/$slot', sha256: '$prefix$slot'),
    };

VehicleInspection _inspection({
  String date = '2026-11-03',
  InspectionKind kind = InspectionKind.start,
  int minutes = 8,
  int? km = 1000,
  double lat = -33.93,
  double lng = 18.50,
  Map<String, InspectionPhoto>? photos,
}) {
  final start = DateTime(2026, 11, 3, 7);
  return VehicleInspection(
    id: VehicleInspection.idFor(date, 'hyundai', kind),
    date: date,
    kind: kind,
    vehicleKey: 'hyundai',
    startedAt: start,
    completedAt: start.add(Duration(minutes: minutes)),
    odometerKm: km,
    lat: lat,
    lng: lng,
    accuracyM: 10,
    photos: photos ?? _allPhotos(date + kind.name),
  );
}

const _depot = DepotConfig(lat: -33.93, lng: 18.50);

void main() {
  test('a proper inspection raises no flags', () {
    final i = _inspection();
    expect(
        VehicleInspectionService.flagsFor(i, history: [i], depot: _depot),
        isEmpty);
  });

  test('too fast, off site and missing photos', () {
    final i = _inspection(minutes: 1, lat: -33.80, photos: {});
    expect(
      VehicleInspectionService.flagsFor(i, history: const [], depot: _depot),
      {
        InspectionFlag.tooFast,
        InspectionFlag.offSite,
        InspectionFlag.missingPhotos,
      },
    );
  });

  test('odometer lower than the previous reading of the same vehicle', () {
    final yesterdayEnd = _inspection(
        date: '2026-11-02', kind: InspectionKind.end, km: 1200);
    final today = _inspection(km: 1100);
    expect(
      VehicleInspectionService.flagsFor(today,
          history: [yesterdayEnd, today], depot: _depot),
      {InspectionFlag.odometerBackwards},
    );
    // A later reading never counts as "previous".
    expect(
      VehicleInspectionService.flagsFor(yesterdayEnd,
          history: [yesterdayEnd, today], depot: _depot),
      isEmpty,
    );
  });

  test('a photo reused from another inspection is flagged', () {
    final earlier = _inspection(date: '2026-11-02');
    final reused = _inspection(photos: {
      ..._allPhotos('fresh'),
      'front': earlier.photos['front']!,
    });
    expect(
      VehicleInspectionService.flagsFor(reused,
          history: [earlier, reused], depot: _depot),
      {InspectionFlag.duplicatePhoto},
    );
  });
}
