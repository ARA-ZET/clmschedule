// models/driver_issue.dart
//
// An issue a driver reports from the clmgpx dropsheet that is not on the
// vehicle inspection checklist. Contract shared with clmgpx — see
// lib/features/issues/models/driver_issue.dart there, and validDriverIssue in
// firestore.rules.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum IssueCategory {
  breakdown('Breakdown', Icons.car_crash_rounded),
  accident('Accident', Icons.emergency_rounded),
  load('Load / stock', Icons.inventory_2_rounded),
  customer('Customer / site', Icons.storefront_rounded),
  route('Route / access', Icons.alt_route_rounded),
  safety('Safety / security', Icons.shield_rounded),
  other('Other', Icons.more_horiz_rounded);

  const IssueCategory(this.label, this.icon);
  final String label;
  final IconData icon;

  static IssueCategory parse(String? name) => IssueCategory.values
      .firstWhere((c) => c.name == name, orElse: () => IssueCategory.other);
}

class DriverIssuePhoto {
  final String path;
  final DateTime? capturedAt;

  const DriverIssuePhoto({required this.path, this.capturedAt});
}

class DriverIssue {
  final String id;
  final String date;
  final IssueCategory category;
  final String description;
  final bool urgent;
  final String driverName;
  final String vehicleLabel;
  final DateTime? createdAt;
  final DateTime? submittedAt;
  final double? lat;
  final double? lng;
  final List<DriverIssuePhoto> photos;

  /// 'open' or 'resolved'.
  final bool resolved;
  final String resolvedBy;
  final DateTime? resolvedAt;
  final String comment;

  const DriverIssue({
    required this.id,
    required this.date,
    required this.category,
    required this.description,
    required this.urgent,
    required this.driverName,
    required this.vehicleLabel,
    required this.photos,
    required this.resolved,
    this.createdAt,
    this.submittedAt,
    this.lat,
    this.lng,
    this.resolvedBy = '',
    this.resolvedAt,
    this.comment = '',
  });

  DateTime get when =>
      submittedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory DriverIssue.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final location = d['location'] is Map ? d['location'] as Map : const {};
    final status = d['status'] is Map ? d['status'] as Map : const {};
    DateTime? ts(Object? v) => v is Timestamp ? v.toDate() : null;
    return DriverIssue(
      id: doc.id,
      date: d['date'] as String? ?? '',
      category: IssueCategory.parse(d['category'] as String?),
      description: d['description'] as String? ?? '',
      urgent: d['urgent'] as bool? ?? false,
      driverName: d['driverName'] as String? ?? '',
      vehicleLabel: d['vehicleLabel'] as String? ?? '',
      createdAt: ts(d['createdAt']),
      submittedAt: ts(d['submittedAt']),
      lat: (location['lat'] as num?)?.toDouble(),
      lng: (location['lng'] as num?)?.toDouble(),
      photos: [
        for (final p in (d['photos'] as List? ?? const []))
          if (p is Map && p['path'] is String)
            DriverIssuePhoto(
                path: p['path'] as String, capturedAt: ts(p['capturedAt'])),
      ],
      resolved: status['state'] == 'resolved',
      resolvedBy: status['by'] as String? ?? '',
      resolvedAt: ts(status['at']),
      comment: status['comment'] as String? ?? '',
    );
  }
}
