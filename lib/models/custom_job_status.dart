import 'package:flutter/material.dart';

class CustomJobStatus {
  final String id;
  final String label;
  final Color color;
  final bool
      isDefault; // Whether this is a default status that can't be deleted
  final int order; // Display order

  const CustomJobStatus({
    required this.id,
    required this.label,
    required this.color,
    this.isDefault = false,
    this.order = 0,
  });

  // Convert from Firestore
  factory CustomJobStatus.fromMap(Map<String, dynamic> data) {
    return CustomJobStatus(
      id: data['id'] as String,
      label: data['label'] as String,
      color: Color(data['color'] as int),
      isDefault: data['isDefault'] as bool? ?? false,
      order: data['order'] as int? ?? 0,
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'color': color.value,
      'isDefault': isDefault,
      'order': order,
    };
  }

  // Create a copy with some fields updated
  CustomJobStatus copyWith({
    String? id,
    String? label,
    Color? color,
    bool? isDefault,
    int? order,
  }) {
    return CustomJobStatus(
      id: id ?? this.id,
      label: label ?? this.label,
      color: color ?? this.color,
      isDefault: isDefault ?? this.isDefault,
      order: order ?? this.order,
    );
  }

  @override
  String toString() {
    return 'CustomJobStatus(id: $id, label: $label, color: $color, isDefault: $isDefault, order: $order)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomJobStatus &&
        other.id == id &&
        other.label == label &&
        other.color == color &&
        other.isDefault == isDefault &&
        other.order == order;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        label.hashCode ^
        color.hashCode ^
        isDefault.hashCode ^
        order.hashCode;
  }

  // Default statuses for initial setup
  static List<CustomJobStatus> getDefaultStatuses() {
    return [
      const CustomJobStatus(
        id: 'standby',
        label: 'Standby',
        color: Color.fromARGB(255, 97, 97, 97), // Darker grey
        isDefault: true,
        order: 0,
      ),
      const CustomJobStatus(
        id: 'scheduled',
        label: 'Scheduled',
        color: Color.fromARGB(255, 120, 69, 0), // Darker orange
        isDefault: true,
        order: 1,
      ),
      const CustomJobStatus(
        id: 'done',
        label: 'Done',
        color: Color.fromARGB(255, 0, 105, 4), // Darker green
        isDefault: true,
        order: 2,
      ),
      const CustomJobStatus(
        id: 'urgent',
        label: 'Urgent',
        color: Color.fromARGB(255, 120, 8, 0), // Darker red
        isDefault: true,
        order: 3,
      ),
    ];
  }
}
