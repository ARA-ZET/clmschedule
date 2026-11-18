// shareable_maps/utils/linked_map_polygons.dart
//
// Pure helpers for working with a linked client map's polygons. Kept out of
// the widget layer so adapters (`ScheduleJobAdapter`) can use them without
// depending on a dialog.
import 'package:flutter/material.dart';

import '../../models/custom_polygon.dart';
import '../models/map_point.dart';
import '../models/shareable_map.dart';

/// One layer's worth of pickable polygons.
class LinkedMapPolygonGroup {
  final String name;
  final List<CustomPolygon> polygons;
  const LinkedMapPolygonGroup(this.name, this.polygons);
}

/// Identity of a polygon's outline, so adopting the same polygon twice (or
/// re-linking the same map) never stacks duplicates.
String polygonGeometryKey(CustomPolygon p) => p.points
    .map((pt) =>
        '${pt.latitude.toStringAsFixed(6)},${pt.longitude.toStringAsFixed(6)}')
    .join('|');

/// The pickable polygons of [map], grouped by layer. Unnamed polygons are
/// given a name — without one they would be invisible in `workingAreas` and
/// unlabelled on the day planner.
List<LinkedMapPolygonGroup> linkedMapPolygonGroups(ShareableMap map) {
  final groups = <LinkedMapPolygonGroup>[];
  for (final layer in map.layers) {
    final polys = <CustomPolygon>[];
    for (final p in layer.polygons) {
      if (!p.isPolygon || p.points.length < 3) continue;
      polys.add(p.name.trim().isNotEmpty
          ? p
          : p.copyWith(
              name: '${layer.name.trim().isNotEmpty ? layer.name : map.name}'
                  ' ${polys.length + 1}'));
    }
    if (polys.isNotEmpty) groups.add(LinkedMapPolygonGroup(layer.name, polys));
  }
  return groups;
}

/// The style an allocated polygon carries: a darker, heavier outline than the
/// client map drew it with, so on any map that shows both it is obvious which
/// ground has already been given to a distributor and which is still just the
/// client's. Applied when a polygon is adopted into the work areas, so the
/// distinction travels with the job (schedule, day planner, print, track
/// editor) rather than living only in the editor.
CustomPolygon allocatedPolygonStyle(CustomPolygon p) {
  final hsl = HSLColor.fromColor(p.color);
  final darker = hsl
      .withLightness((hsl.lightness * 0.55).clamp(0.08, 1.0))
      .withSaturation((hsl.saturation * 1.1).clamp(0.0, 1.0))
      .toColor();
  return p.copyWith(
    color: darker,
    strokeWidth: p.strokeWidth < 4 ? 4 : p.strokeWidth,
  );
}

/// A client-map point in the form a schedule job keeps work maps in: a
/// point-type [CustomPolygon] carrying the point's id.
CustomPolygon mapPointAsWorkMap(MapPoint p) => CustomPolygon(
      id: p.id,
      name: p.name,
      description: p.description,
      points: [p.position],
      color: p.color,
      type: MapElementType.point,
      pointCategory: p.pointCategory,
    );
