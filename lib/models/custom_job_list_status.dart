import 'package:flutter/material.dart';

class CustomJobListStatus {
  final String id;
  final String label;
  final Color color;
  final bool isDefault;

  const CustomJobListStatus({
    required this.id,
    required this.label,
    required this.color,
    this.isDefault = false,
  });

  // Convert from Firestore document
  factory CustomJobListStatus.fromMap(Map<String, dynamic> map) {
    return CustomJobListStatus(
      id: map['id'] as String,
      label: map['label'] as String,
      color: Color(map['color'] as int),
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'color': color.toARGB32(),
      'isDefault': isDefault,
    };
  }

  // Create a copy with some properties changed
  CustomJobListStatus copyWith({
    String? id,
    String? label,
    Color? color,
    bool? isDefault,
  }) {
    return CustomJobListStatus(
      id: id ?? this.id,
      label: label ?? this.label,
      color: color ?? this.color,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomJobListStatus &&
        other.id == id &&
        other.label == label &&
        other.color == color &&
        other.isDefault == isDefault;
  }

  @override
  int get hashCode => Object.hash(id, label, color, isDefault);

  @override
  String toString() {
    return 'CustomJobListStatus(id: $id, label: $label, color: $color, isDefault: $isDefault)';
  }
}
