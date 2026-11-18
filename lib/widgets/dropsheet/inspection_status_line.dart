import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../models/vehicle_inspection.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../services/vehicle_inspection_service.dart';
import '../../utils/schedule_time.dart';
import '../fleet/inspection_detail_page.dart';

/// "Start-of-day inspection ✓ 07:12 · Needs review" under a driver's Inspect
/// row, from what the driver actually submitted in clmgpx — the row's tick
/// alone proves nothing.
class InspectionStatusLine extends riverpod.ConsumerWidget {
  final InspectionKind kind;
  final VehicleInspection? inspection;
  final bool overdue;
  final List<VehicleInspection> dayInspections;

  const InspectionStatusLine._({
    required this.kind,
    required this.inspection,
    required this.overdue,
    required this.dayInspections,
  });

  /// The line for [task], or null when the task is not Inspect.
  static Widget? forTask({
    required DropsheetTask task,
    required DropsheetDriverSection section,
    required DateTime date,
    required List<VehicleInspection> inspections,
  }) {
    // Only the morning check is required, so only the Inspect row has one.
    if (task.type != DropsheetTaskType.inspect) return null;
    const kind = InspectionKind.start;
    if (section.isOwnTransport) return null;

    VehicleInspection? match;
    for (final i in inspections) {
      if (i.kind != kind) continue;
      final sameVehicle =
          section.vehicle != null && i.vehicleKey == section.vehicle!.name;
      if (sameVehicle) {
        match = i;
        break;
      }
      if (section.vehicle == null && i.driverId == section.driverId) {
        match ??= i;
      }
    }

    final today = scheduleToday();
    final overdue = date.isBefore(today) ||
        (date == today && kind == InspectionKind.start);
    return InspectionStatusLine._(
      kind: kind,
      inspection: match,
      overdue: overdue,
      dayInspections: inspections,
    );
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final i = inspection;
    final label =
        kind == InspectionKind.start ? 'Start-of-day inspection' : 'End-of-day inspection';

    if (i == null) {
      final color = overdue ? Colors.red.shade700 : Colors.grey.shade600;
      return _line(
        icon: Icons.photo_camera_outlined,
        color: color,
        text: '$label: not done in clmgpx',
      );
    }

    final time = i.completedAt == null
        ? ''
        : ' ${DateFormat('HH:mm').format(toScheduleCivil(i.completedAt!))}';
    final review = switch (i.review.status) {
      InspectionReviewStatus.approved => 'approved',
      InspectionReviewStatus.rejected => 'REJECTED',
      InspectionReviewStatus.pending => 'needs review',
    };
    final defects = i.isUnsafe
        ? ' · UNSAFE'
        : i.hasDefects
            ? ' · ${i.defects.length} defect${i.defects.length == 1 ? '' : 's'}'
            : '';
    final color = i.isUnsafe || i.review.status == InspectionReviewStatus.rejected
        ? Colors.red.shade700
        : i.hasDefects
            ? Colors.orange.shade800
            : Colors.green.shade700;

    return InkWell(
      onTap: () {
        final depot = ref.read(dropsheetTaskConfigRiverpod).depot;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => InspectionDetailPage(
            inspection: i,
            history: dayInspections,
            depot: depot,
            service: VehicleInspectionService(),
          ),
        ));
      },
      child: _line(
        icon: Icons.fact_check,
        color: color,
        text: '$label ✓$time · $review$defects',
      ),
    );
  }

  Widget _line({
    required IconData icon,
    required Color color,
    required String text,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 3),
        child: Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: color,
                )),
          ),
        ]),
      );
}
