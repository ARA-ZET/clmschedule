// Picking a work area onto a round: what gets added, and what is recognised as
// already there.
//
// The name rule is the whole of it. A work area reaches a tab as a polygon
// that keeps only its name, and the same ground arrives from work areas, KML
// imports and schedule work maps — none of which share an id. Get this wrong
// and tapping an area you already have files a second copy of it, on the tab
// and on the schedule job behind it.
import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/work_area.dart';
import 'package:clmschedule/track_editor/services/te_work_area_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

List<LatLng> box(double minLat, double minLng, double size) => [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ];

WorkArea area(String name, {int letterboxes = 0, String description = ''}) =>
    WorkArea(
      id: 'id_$name',
      name: name,
      description: description,
      polygonPoints: box(-33.94, 18.40, 0.01),
      kmlFileName: '',
      letterBoxEstimate: letterboxes,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('planWorkAreaImport', () {
    test('adds an area the tab does not have', () {
      final plan = planWorkAreaImport([area('Pinelands North')], const []);

      expect(plan.added.map((a) => a.name), ['Pinelands North']);
      expect(plan.alreadyPresent, isEmpty);
      expect(plan.addedCount, 1);
    });

    test('recognises one the tab already has', () {
      final plan = planWorkAreaImport(
        [area('Pinelands North')],
        const ['Pinelands North'],
      );

      expect(plan.added, isEmpty);
      expect(plan.alreadyPresent.map((a) => a.name), ['Pinelands North']);
      expect(plan.isEmpty, isTrue);
    });

    test('matches regardless of case and stray spacing', () {
      // A KML import and a work area rarely agree on either.
      final plan = planWorkAreaImport(
        [area('Pinelands North')],
        const ['  pinelands north '],
      );

      expect(plan.added, isEmpty);
    });

    test('the same area picked twice in one selection is added once', () {
      final plan = planWorkAreaImport(
        [area('Pinelands North'), area('Pinelands North')],
        const [],
      );

      expect(plan.addedCount, 1);
      expect(plan.alreadyPresent, hasLength(1));
    });

    test('takes the new ones and leaves the rest', () {
      final plan = planWorkAreaImport(
        [area('Pinelands North'), area('Thornton'), area('Maitland')],
        const ['Thornton'],
      );

      expect(plan.added.map((a) => a.name), ['Pinelands North', 'Maitland']);
      expect(plan.alreadyPresent.map((a) => a.name), ['Thornton']);
    });

    test('two areas with different names both come through', () {
      final plan =
          planWorkAreaImport([area('Round 1'), area('Round 2')], const []);

      expect(plan.addedCount, 2);
    });
  });

  group('workMapsToAppend', () {
    test('carries the name, description and letterbox estimate across', () {
      final appended = workMapsToAppend(
        const [],
        [area('Pinelands North', letterboxes: 1200, description: 'Round 3')],
      );

      expect(appended, hasLength(1));
      expect(appended.single.name, 'Pinelands North');
      expect(appended.single.description, 'Round 3');
      expect(appended.single.letterBoxEstimate, 1200,
          reason: 'the schedule map should not have to recount known ground');
      expect(appended.single.points, hasLength(4));
    });

    test('skips a work map the job already carries', () {
      final existing = [
        CustomPolygon(
          name: 'Pinelands North',
          description: '',
          points: box(-33.94, 18.40, 0.01),
          color: Colors.red,
        ),
      ];

      expect(workMapsToAppend(existing, [area('Pinelands North')]), isEmpty);
      expect(workMapsToAppend(existing, [area('  PINELANDS NORTH')]), isEmpty);
    });

    test('appends only the ones missing from the job', () {
      final existing = [
        CustomPolygon(
          name: 'Thornton',
          description: '',
          points: box(-33.90, 18.50, 0.01),
          color: Colors.red,
        ),
      ];

      final appended =
          workMapsToAppend(existing, [area('Thornton'), area('Maitland')]);

      expect(appended.map((p) => p.name), ['Maitland']);
    });

    test('does not mutate the job list it was handed', () {
      final existing = <CustomPolygon>[];
      workMapsToAppend(existing, [area('Maitland')]);
      expect(existing, isEmpty);
    });
  });

  group('teStyledPolygonFor', () {
    test('gives the polygon a work-area id that cannot clash with a drawn one',
        () {
      final polygon = teStyledPolygonFor(area('Pinelands North'));

      expect(polygon.id, 'wa_id_Pinelands North');
      expect(polygon.name, 'Pinelands North');
      expect(polygon.points, hasLength(4));
    });

    test('copies the points, so editing the polygon cannot edit the catalogue',
        () {
      final source = area('Pinelands North');
      final polygon = teStyledPolygonFor(source);

      polygon.points.add(const LatLng(-33.9, 18.4));

      expect(source.polygonPoints, hasLength(4));
    });
  });
}
