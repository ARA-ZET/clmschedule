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
///
/// [isFromCache] / [hasPendingWrites] come from the snapshot metadata so the
/// UI can tell a value the server has acknowledged from one that is still only
/// local. Without that distinction an offline client happily shows "Confirmed"
/// from its own cache while every other user still sees the old status.
class ScheduleDayConfirmation {
  final ScheduleConfirmationStatus status;
  final DateTime? confirmedAt;
  final String? confirmedBy;
  final bool isFromCache;
  final bool hasPendingWrites;

  const ScheduleDayConfirmation({
    this.status = ScheduleConfirmationStatus.notConfirmed,
    this.confirmedAt,
    this.confirmedBy,
    this.isFromCache = false,
    this.hasPendingWrites = false,
  });

  /// True when this value has not yet been round-tripped through the server,
  /// i.e. what it shows may differ from what other users see.
  bool get isUnsynced => isFromCache || hasPendingWrites;

  factory ScheduleDayConfirmation.fromMap(
    Map<String, dynamic>? data, {
    bool isFromCache = false,
    bool hasPendingWrites = false,
  }) {
    if (data == null) {
      return ScheduleDayConfirmation(
        isFromCache: isFromCache,
        hasPendingWrites: hasPendingWrites,
      );
    }
    final ts = data['confirmedAt'];
    return ScheduleDayConfirmation(
      status: ScheduleConfirmationStatus.fromString(
        data['confirmationStatus'] as String?,
      ),
      confirmedAt: ts is Timestamp ? ts.toDate() : null,
      confirmedBy: data['confirmedBy'] as String?,
      isFromCache: isFromCache,
      hasPendingWrites: hasPendingWrites,
    );
  }

  /// Reads the day doc together with its sync metadata.
  factory ScheduleDayConfirmation.fromSnapshot(DocumentSnapshot snap) {
    return ScheduleDayConfirmation.fromMap(
      snap.data() as Map<String, dynamic>?,
      isFromCache: snap.metadata.isFromCache,
      hasPendingWrites: snap.metadata.hasPendingWrites,
    );
  }
}
