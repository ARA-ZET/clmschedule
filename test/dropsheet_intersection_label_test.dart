// Street-corner names on distributor tasks: a name is only trusted while it
// was resolved for the task's current point, and it leads the Location label
// so a printed dropsheet says where to stop.
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/utils/dropsheet_maps.dart';

DropsheetTask dropOff(Map<String, dynamic> extra) => DropsheetTask(
      id: 'd1',
      type: DropsheetTaskType.dropOff,
      typeData: {
        'distributorName': 'Thabo',
        'workArea': 'Pinelands',
        'lat': -33.93712,
        'lng': 18.50401,
        DropsheetTask.kPointOnlyKey: true,
        ...extra,
      },
    );

void main() {
  test('pointKey is lat,lng to 4 decimals', () {
    expect(dropOff({}).pointKey, '-33.9371,18.5040');
  });

  test('a corner resolved for this point leads the location', () {
    final t = dropOff({
      DropsheetTask.kIntersectionKey: 'Forest Dr & Central Sq',
      DropsheetTask.kIntersectionAtKey: '-33.9371,18.5040',
    });
    expect(t.hasCurrentIntersection, isTrue);
    expect(
        DropsheetMaps.locationLabel(t), 'Forest Dr & Central Sq · Pinelands');
  });

  test('a corner resolved for an old point is ignored', () {
    final t = dropOff({
      DropsheetTask.kIntersectionKey: 'Forest Dr & Central Sq',
      DropsheetTask.kIntersectionAtKey: '-33.9000,18.5000',
    });
    expect(t.hasCurrentIntersection, isFalse);
    expect(DropsheetMaps.locationLabel(t), 'Pinelands');
  });

  test('"no streets nearby" counts as resolved but shows the work area', () {
    final t = dropOff({
      DropsheetTask.kIntersectionKey: '',
      DropsheetTask.kIntersectionAtKey: '-33.9371,18.5040',
    });
    expect(t.hasCurrentIntersection, isTrue, reason: 'no endless retries');
    expect(DropsheetMaps.locationLabel(t), 'Pinelands');
  });

  test('tasks without a point have nothing to resolve', () {
    const t = DropsheetTask(id: 'x', type: DropsheetTaskType.dropOff);
    expect(t.pointKey, isNull);
    expect(t.hasCurrentIntersection, isFalse);
  });

  test('jobs with work-area polygons never show a corner', () {
    final t = dropOff({
      DropsheetTask.kPointOnlyKey: false,
      DropsheetTask.kIntersectionKey: 'Forest Dr & Central Sq',
      DropsheetTask.kIntersectionAtKey: '-33.9371,18.5040',
    });
    expect(t.wantsIntersection, isFalse);
    expect(DropsheetMaps.locationLabel(t), 'Pinelands');
  });
}
