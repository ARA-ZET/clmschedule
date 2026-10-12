// Point-only schedule jobs (a single tapped / searched point, no work-area
// polygon) get their working area named after the nearest intersection.
// These pin down WHICH jobs qualify — the rest is a best-effort lookup.
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';

const _pt = LatLng(-33.9005, 18.6285);

const _marker = CustomPolygon(
  name: '12 Durban Rd, Bellville',
  description: '',
  points: [_pt],
  color: Colors.red,
  type: MapElementType.point,
);

const _polygon = CustomPolygon(
  name: 'Bellville Central',
  description: '',
  points: [LatLng(-33.90, 18.62), LatLng(-33.90, 18.63), LatLng(-33.91, 18.63)],
  color: Colors.blue,
);

Job _job(
        {List<String> areas = const [], List<CustomPolygon> maps = const []}) =>
    Job(
      id: 'j',
      clients: const ['Client'],
      workingAreas: areas,
      workMaps: maps,
      distributorId: 'd',
      date: DateTime(2026, 9, 30),
      statusId: 'logged',
    );

LatLng? bare(Job j) => ScheduleProvider.barePointToNameForTest(j);

void main() {
  test('a placeholder-named job with only a point is named', () {
    expect(bare(_job(areas: ['To be assigned'], maps: [_marker])), _pt);
    expect(bare(_job(maps: [_marker])), _pt);
  });

  test('a job someone already named is left alone', () {
    expect(bare(_job(areas: ['Bellville CBD'], maps: [_marker])), isNull);
  });

  test('a job with a work-area polygon is never renamed', () {
    expect(bare(_job(maps: [_marker, _polygon])), isNull);
  });

  test('a job with no point has nothing to name', () {
    expect(bare(_job(areas: ['To be assigned'])), isNull);
  });

  test('a point marker alone still counts as point-only on the dropsheet', () {
    expect(DropsheetTask.isPointOnlyJob(_job(maps: [_marker])), isTrue);
    expect(
        DropsheetTask.isPointOnlyJob(_job(maps: [_marker, _polygon])), isFalse);
  });
}
