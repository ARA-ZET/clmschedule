import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/models/job_linked_map.dart';
import 'package:clmschedule/utils/schedule_job_merge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

CustomPolygon _poly(String name, {String? id}) => CustomPolygon(
      id: id,
      name: name,
      description: '',
      points: const [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1)],
      color: Colors.blue,
    );

Job _job(
  String id, {
  List<String> clients = const [],
  List<String> clientInstructions = const [],
  List<String> workingAreas = const [],
  List<CustomPolygon> workMaps = const [],
  String mapInstructions = '',
  LatLng? dropOffPoint,
  LatLng? pickUpPoint,
  List<JobAreaLink> areaLinks = const [],
}) =>
    Job(
      id: id,
      clients: clients,
      clientInstructions: clientInstructions,
      workingAreas: workingAreas,
      workMaps: workMaps,
      distributorId: 'd-$id',
      date: DateTime(2026, 10, 6),
      statusId: 'scheduled',
      mapInstructions: mapInstructions,
      dropOffPoint: dropOffPoint,
      pickUpPoint: pickUpPoint,
      areaLinks: areaLinks,
    );

void main() {
  test('linked maps from both jobs are kept, without duplicates', () {
    const a = JobLinkedMap(mapId: 'mapA', monthKey: '10-2026', name: 'A');
    const b = JobLinkedMap(mapId: 'mapB', monthKey: '10-2026', name: 'B');
    final target = _job('t', clients: ['T']).withLinkedMaps([a]);
    final incoming = _job('i', clients: ['I']).withLinkedMaps([b, a]);

    final merged = mergeScheduleJobs(target: target, incoming: incoming);
    expect(merged.linkedMaps, [a, b]);
    expect(merged.linkedMapId, 'mapA');
    expect(merged.toMap()['linkedMaps'], hasLength(2));
  });

  test('legacy single-link fields on the incoming job are carried over', () {
    final target = _job('t', clients: ['T']);
    final incoming = _job('i', clients: ['I'])
        .copyWith(linkedMapId: 'old', linkedMapMonthKey: '09-2026');

    final merged = mergeScheduleJobs(target: target, incoming: incoming);
    expect(merged.linkedMaps.single.mapId, 'old');
    expect(merged.linkedMapMonthKey, '09-2026');
  });

  test('client instructions stay with their client', () {
    final target = _job('t',
        clients: ['Acme', 'Beta'], clientInstructions: ['', 'beta note']);
    final incoming = _job('i',
        clients: ['Gamma', 'acme'],
        clientInstructions: ['gamma note', 'acme note']);

    final merged = mergeScheduleJobs(target: target, incoming: incoming);
    expect(merged.clients, ['Acme', 'Beta', 'Gamma']);
    expect(merged.clientInstructions, ['acme note', 'beta note', 'gamma note']);
  });

  test('jobs without client instructions stay without them', () {
    final merged = mergeScheduleJobs(
      target: _job('t', clients: ['A']),
      incoming: _job('i', clients: ['B']),
    );
    expect(merged.clientInstructions, isEmpty);
  });

  test('linked client-map areas are kept as links, not written as copies', () {
    const link = JobAreaLink(
        mapId: 'cm', monthKey: '10-2026', polygonId: 'p1', name: 'Pinelands');
    final incoming = _job('i', clients: ['I'], areaLinks: [link])
        .withResolvedAreas([_poly('Pinelands', id: link.resolvedId)]);
    final target = _job('t',
        clients: ['T'], workingAreas: ['Oak'], workMaps: [_poly('Oak')]);

    final merged = mergeScheduleJobs(target: target, incoming: incoming);
    expect(merged.areaLinks.map((l) => l.key), [link.key]);
    expect(merged.workingAreas, containsAll(['Oak', 'Pinelands']));
    expect(merged.workMaps.map((p) => p.name), ['Oak', 'Pinelands']);

    final stored = merged.toMap();
    expect(stored['workingAreas'], ['Oak']);
    expect((stored['workMaps'] as List).length, 1);
    expect(stored['areaLinks'], hasLength(1));
  });

  test('colliding own areas are renamed, never dropped', () {
    final merged = mergeScheduleJobs(
      target: _job('t', workMaps: [_poly('Zone')]),
      incoming: _job('i', workMaps: [_poly('Zone'), _poly('Zone')]),
    );
    expect(
        merged.workMaps.map((p) => p.name), ['Zone', 'Zone gap', 'Zone gap1']);
  });

  test('instructions merge and points fall back to the incoming job', () {
    const drop = LatLng(-33.9, 18.4);
    const pick = LatLng(-33.8, 18.5);
    final merged = mergeScheduleJobs(
      target: _job('t', mapInstructions: 'Gate code 12'),
      incoming: _job('i',
          mapInstructions: 'Park at back',
          dropOffPoint: drop,
          pickUpPoint: pick),
    );
    expect(merged.mapInstructions, 'Gate code 12\nPark at back');
    expect(merged.dropOffPoint, drop);
    expect(merged.pickUpPoint, pick);
    expect(merged.id, 't');
    expect(merged.distributorId, 'd-t');
  });
}
