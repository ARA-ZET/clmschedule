import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Admin-set confirmation state for a single schedule day, surfaced to
/// distributors on the public clmworking.web.app roster so they know
/// whether the day's assignments are final or still subject to change.
enum ScheduleConfirmationStatus {
  pending,
  confirmed,
  notConfirmed;

  static ScheduleConfirmationStatus fromString(String? value) {
    return ScheduleConfirmationStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ScheduleConfirmationStatus.notConfirmed,
    );
  }

  String get displayName {
    switch (this) {
      case ScheduleConfirmationStatus.pending:
        return 'Pending';
      case ScheduleConfirmationStatus.confirmed:
        return 'Confirmed';
      case ScheduleConfirmationStatus.notConfirmed:
        return 'Not Confirmed';
    }
  }

  Color get color {
    switch (this) {
      case ScheduleConfirmationStatus.pending:
        return Colors.orange;
      case ScheduleConfirmationStatus.confirmed:
        return Colors.green;
      case ScheduleConfirmationStatus.notConfirmed:
        return Colors.red;
    }
  }

  IconData get icon {
    switch (this) {
      case ScheduleConfirmationStatus.pending:
        return Icons.hourglass_empty;
      case ScheduleConfirmationStatus.confirmed:
        return Icons.check_circle;
      case ScheduleConfirmationStatus.notConfirmed:
        return Icons.error;
    }
  }
}

/// Confirmation status for a schedule day plus who confirmed it and when.
class ScheduleDayConfirmation {
  final ScheduleConfirmationStatus status;
  final DateTime? confirmedAt;
  final String? confirmedBy;

  const ScheduleDayConfirmation({
    this.status = ScheduleConfirmationStatus.notConfirmed,
    this.confirmedAt,
    this.confirmedBy,
  });

  factory ScheduleDayConfirmation.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const ScheduleDayConfirmation();
    final ts = data['confirmedAt'];
    return ScheduleDayConfirmation(
      status: ScheduleConfirmationStatus.fromString(
        data['confirmationStatus'] as String?,
      ),
      confirmedAt: ts is Timestamp ? ts.toDate() : null,
      confirmedBy: data['confirmedBy'] as String?,
    );
  }
}
