import 'package:flutter/material.dart';

class CustomJobListStatus {
  final String id;
  final String label;
  final Color color;
  final bool isDefault;
  final List<String> hiddenForJobTypes;

  const CustomJobListStatus({
    required this.id,
    required this.label,
    required this.color,
    this.isDefault = false,
    this.hiddenForJobTypes = const [],
  });

  // Convert from Firestore document
  factory CustomJobListStatus.fromMap(Map<String, dynamic> map) {
    return CustomJobListStatus(
      id: map['id'] as String,
      label: map['label'] as String,
      color: Color((map['color'] as num).toInt()),
      isDefault: map['isDefault'] as bool? ?? false,
      hiddenForJobTypes: (map['hiddenForJobTypes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  // Convert to Firestore document
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'color': color.toARGB32(),
      'isDefault': isDefault,
      'hiddenForJobTypes': hiddenForJobTypes,
    };
  }

  // Create a copy with some properties changed
  CustomJobListStatus copyWith({
    String? id,
    String? label,
    Color? color,
    bool? isDefault,
    List<String>? hiddenForJobTypes,
  }) {
    return CustomJobListStatus(
      id: id ?? this.id,
      label: label ?? this.label,
      color: color ?? this.color,
      isDefault: isDefault ?? this.isDefault,
      hiddenForJobTypes: hiddenForJobTypes ?? this.hiddenForJobTypes,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomJobListStatus &&
        other.id == id &&
        other.label == label &&
        other.color == color &&
        other.isDefault == isDefault &&
        _listEquals(other.hiddenForJobTypes, hiddenForJobTypes);
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
      id, label, color, isDefault, Object.hashAll(hiddenForJobTypes));

  @override
  String toString() {
    return 'CustomJobListStatus(id: $id, label: $label, color: $color, isDefault: $isDefault, hiddenForJobTypes: $hiddenForJobTypes)';
  }
}
