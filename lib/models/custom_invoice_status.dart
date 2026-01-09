import 'package:flutter/material.dart';

class CustomInvoiceStatus {
  final String id;
  final String label;
  final Color color;
  final bool isDefault;

  const CustomInvoiceStatus({
    required this.id,
    required this.label,
    required this.color,
    this.isDefault = false,
  });

  // Convert from Firestore document
  factory CustomInvoiceStatus.fromMap(Map<String, dynamic> map) {
    return CustomInvoiceStatus(
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
  CustomInvoiceStatus copyWith({
    String? id,
    String? label,
    Color? color,
    bool? isDefault,
  }) {
    return CustomInvoiceStatus(
      id: id ?? this.id,
      label: label ?? this.label,
      color: color ?? this.color,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomInvoiceStatus && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
