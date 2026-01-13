import 'package:cloud_firestore/cloud_firestore.dart';

enum ReminderStatus {
  active,
  completed,
  cancelled,
}

class JobReminder {
  final DateTime dueDate;
  final String notes;
  final DateTime createdAt;
  final ReminderStatus status;
  final DateTime? completedAt;

  JobReminder({
    required this.dueDate,
    required this.notes,
    required this.createdAt,
    this.status = ReminderStatus.active,
    this.completedAt,
  });

  factory JobReminder.fromMap(Map<String, dynamic> data) {
    return JobReminder(
      dueDate: (data['dueDate'] as Timestamp).toDate(),
      notes: data['notes'] as String? ?? '',
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      status: ReminderStatus.values.firstWhere(
        (e) => e.name == (data['status'] as String? ?? 'active'),
        orElse: () => ReminderStatus.active,
      ),
      completedAt: data['completedAt'] != null
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'dueDate': Timestamp.fromDate(dueDate),
      'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      'status': status.name,
      'completedAt':
          completedAt != null ? Timestamp.fromDate(completedAt!) : null,
    };
  }

  bool get isOverdue {
    return status == ReminderStatus.active && DateTime.now().isAfter(dueDate);
  }

  bool get isActive {
    return status == ReminderStatus.active;
  }

  JobReminder copyWith({
    DateTime? dueDate,
    String? notes,
    DateTime? createdAt,
    ReminderStatus? status,
    DateTime? completedAt,
  }) {
    return JobReminder(
      dueDate: dueDate ?? this.dueDate,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}
