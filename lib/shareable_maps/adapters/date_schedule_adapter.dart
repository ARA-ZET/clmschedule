import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../models/distributor.dart';
import '../../models/job.dart';
import '../models/map_layer.dart';
import '../models/map_point.dart';
import '../models/map_polyline.dart';
import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Read-only adapter that aggregates all polygons from jobs scheduled on a
/// specific date into a single [ShareableMap] for viewing.
class DateScheduleAdapter extends MapDataAdapter {
  final DateTime _date;
  final List<Job> _jobs;
  final List<Distributor> _distributors;

  DateScheduleAdapter({
    required DateTime date,
    required List<Job> jobs,
    List<Distributor> distributors = const [],
  })  : _date = date,
        _jobs = jobs,
        _distributors = distributors;

  @override
  String get adapterId => 'date_schedule';

  @override
  String get displayName {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${_date.day} ${months[_date.month - 1]} – All Areas';
  }

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.viewOnly();

  @override
  Future<ShareableMap> load() async {
    final now = DateTime.now();

    // Collect all polygons and markers from all jobs on this date
    final allPolygons = <CustomPolygon>[];
    final allPolylines = <MapPolyline>[];
    final allPoints = <MapPoint>[];
    for (final job in _jobs) {
      // Resolve distributor name for display
      final distName = _distributors
          .where((d) => d.id == job.distributorId)
          .map((d) => d.name)
          .firstOrNull;
      // Collect non-empty client names
      final clientNames = job.clients.where((c) => c.isNotEmpty).toList();
      for (var mapIndex = 0; mapIndex < job.workMaps.length; mapIndex++) {
        final p = job.workMaps[mapIndex];
        final parts = <String>[
          if (distName != null) distName,
          if (clientNames.isNotEmpty) clientNames.join(', '),
          if (p.description.isNotEmpty) p.description,
        ];
        final desc = parts.join(' — ');

        if (p.isPoint && p.points.isNotEmpty) {
          allPoints.add(MapPoint(
            id: 'date_${job.id}_point_$mapIndex',
            name: p.name,
            description: desc,
            position: p.points.first,
            color: p.color,
            pointCategory: p.pointCategory,
            createdAt: now,
            updatedAt: now,
          ));
        } else if (p.isPolyline) {
          allPolylines.add(MapPolyline.create(
            name: p.name,
            description: desc,
            points: List<LatLng>.from(p.points),
            color: p.color,
            strokeWidth: p.strokeWidth.toDouble(),
            isDashed: p.isDashed,
          ));
        } else {
          allPolygons.add(
            p.copyWith(
              description: desc,
              points: List<LatLng>.from(p.points),
            ),
          );
        }
      }
    }

    final layer = MapLayer(
      id: 'date_schedule_layer',
      name: 'Scheduled Areas',
      description: 'All work areas for $displayName',
      order: 0,
      defaultColor: Colors.blue,
      polygons: allPolygons,
      polylines: allPolylines,
      points: allPoints,
      createdAt: now,
      updatedAt: now,
    );

    // Center on element bounds or fall back to Cape Town
    LatLng center = const LatLng(-33.925, 18.425);
    if (allPolygons.isNotEmpty ||
        allPolylines.isNotEmpty ||
        allPoints.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      int count = 0;
      for (final polygon in allPolygons) {
        for (final pt in polygon.points) {
          latSum += pt.latitude;
          lngSum += pt.longitude;
          count++;
        }
      }
      for (final polyline in allPolylines) {
        for (final pt in polyline.points) {
          latSum += pt.latitude;
          lngSum += pt.longitude;
          count++;
        }
      }
      for (final pt in allPoints) {
        latSum += pt.position.latitude;
        lngSum += pt.position.longitude;
        count++;
      }
      if (count > 0) {
        center = LatLng(latSum / count, lngSum / count);
      }
    }

    final totalElements =
        allPolygons.length + allPolylines.length + allPoints.length;

    return ShareableMap(
      id: 'date_${_date.toIso8601String().split('T').first}',
      name: displayName,
      description: '$totalElements element(s) from ${_jobs.length} job(s)',
      layers: [layer],
      defaultCenter: center,
      defaultZoom: 11.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Read-only adapter – nothing to save.
  }
}
