import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/shareable_maps/adapters/date_schedule_adapter.dart';
import 'package:clmschedule/shareable_maps/adapters/schedule_job_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  const polygonPoints = [
    LatLng(-33.90, 18.40),
    LatLng(-33.91, 18.41),
    LatLng(-33.92, 18.42),
  ];
  const pointPosition = LatLng(-33.93, 18.43);

  test('CustomPolygon preserves point type and category through maps', () {
    const point = CustomPolygon(
      name: 'Gate',
      description: 'Pickup gate',
      points: [pointPosition],
      color: Colors.green,
      type: MapElementType.point,
      pointCategory: PointCategory.pickup,
    );

    final roundTripped = CustomPolygon.fromMap(point.toMap());

    expect(roundTripped.isPoint, isTrue);
    expect(roundTripped.pointCategory, PointCategory.pickup);
    expect(roundTripped.points.single, pointPosition);
  });

  test('Job.copyWith preserves work-map metadata and can clear drop-off', () {
    const polygon = CustomPolygon(
      name: 'Area A',
      description: 'Main area',
      points: polygonPoints,
      color: Colors.blue,
      fillOpacity: 0.45,
      strokeWidth: 4,
      letterBoxEstimate: 123,
    );
    final job = Job(
      id: 'job-1',
      clients: const ['Client'],
      workingAreas: const ['Area A'],
      workMaps: const [polygon],
      distributorId: 'dist-1',
      date: DateTime(2026, 5, 5),
      statusId: 'scheduled',
      dropOffPoint: pointPosition,
    );

    final copied = job.copyWith(dropOffPoint: null);

    expect(copied.dropOffPoint, isNull);
    expect(copied.workMaps.single.letterBoxEstimate, 123);
    expect(copied.workMaps.single.fillOpacity, 0.45);
    expect(copied.workMaps.single.strokeWidth, 4);
  });

  test('DateScheduleAdapter keeps every point visible with unique ids',
      () async {
    final job = Job(
      id: 'job-1',
      clients: const ['Client'],
      workingAreas: const [],
      workMaps: const [
        CustomPolygon(
          name: 'Pickup',
          description: '',
          points: [LatLng(-33.93, 18.43)],
          color: Colors.green,
          type: MapElementType.point,
          pointCategory: PointCategory.pickup,
        ),
        CustomPolygon(
          name: 'Loading',
          description: '',
          points: [LatLng(-33.94, 18.44)],
          color: Colors.orange,
          type: MapElementType.point,
          pointCategory: PointCategory.loading,
        ),
      ],
      distributorId: 'dist-1',
      date: DateTime(2026, 5, 5),
      statusId: 'scheduled',
    );

    final map = await DateScheduleAdapter(
      date: DateTime(2026, 5, 5),
      jobs: [job],
      distributors: [Distributor(id: 'dist-1', name: 'Dist', index: 0)],
    ).load();

    final points = map.layers.single.points;

    expect(points, hasLength(2));
    expect(points.map((p) => p.id).toSet(), hasLength(2));
    expect(points.map((p) => p.pointCategory).toSet(),
        containsAll({PointCategory.pickup, PointCategory.loading}));
  });

  test('ScheduleJobAdapter round-trips point categories and polygon metadata',
      () async {
    final job = Job(
      id: 'job-1',
      clients: const ['Client'],
      workingAreas: const ['Area A'],
      workMaps: const [
        CustomPolygon(
          name: 'Area A',
          description: 'Main area',
          points: polygonPoints,
          color: Colors.blue,
          fillOpacity: 0.5,
          strokeWidth: 5,
          letterBoxEstimate: 321,
        ),
        CustomPolygon(
          name: 'Offload',
          description: '',
          points: [pointPosition],
          color: Colors.red,
          type: MapElementType.point,
          pointCategory: PointCategory.offloading,
        ),
      ],
      distributorId: 'dist-1',
      date: DateTime(2026, 5, 5),
      statusId: 'scheduled',
    );
    late List<CustomPolygon> savedMaps;
    late List<String> savedNames;

    final adapter = ScheduleJobAdapter(
      job: job,
      onSave: (polygons, workingAreaNames) async {
        savedMaps = polygons;
        savedNames = workingAreaNames;
      },
    );

    final map = await adapter.load();
    await adapter.save(map);

    final savedPolygon = savedMaps.singleWhere((p) => p.isPolygon);
    final savedPoint = savedMaps.singleWhere((p) => p.name == 'Offload');

    expect(savedPolygon.letterBoxEstimate, 321);
    expect(savedPolygon.fillOpacity, 0.5);
    expect(savedPolygon.strokeWidth, 5);
    expect(savedPoint.pointCategory, PointCategory.offloading);
    expect(savedNames, ['Area A']);
  });
}
