class CustomJobType {
  final String id;
  final String label;
  final bool isDefault;
  final int order;

  const CustomJobType({
    required this.id,
    required this.label,
    this.isDefault = false,
    this.order = 0,
  });

  factory CustomJobType.fromMap(Map<String, dynamic> data) {
    return CustomJobType(
      id: data['id'] as String,
      label: data['label'] as String,
      isDefault: data['isDefault'] as bool? ?? false,
      order: data['order'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'isDefault': isDefault,
      'order': order,
    };
  }

  CustomJobType copyWith({
    String? id,
    String? label,
    bool? isDefault,
    int? order,
  }) {
    return CustomJobType(
      id: id ?? this.id,
      label: label ?? this.label,
      isDefault: isDefault ?? this.isDefault,
      order: order ?? this.order,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomJobType &&
        other.id == id &&
        other.label == label &&
        other.isDefault == isDefault &&
        other.order == order;
  }

  @override
  int get hashCode =>
      id.hashCode ^ label.hashCode ^ isDefault.hashCode ^ order.hashCode;

  @override
  String toString() =>
      'CustomJobType(id: $id, label: $label, isDefault: $isDefault, order: $order)';

  /// Default job types matching the legacy JobType enum values
  static List<CustomJobType> getDefaults() {
    return const [
      CustomJobType(
          id: 'flyersPrintingOnly',
          label: 'Flyers - Printing only',
          isDefault: true,
          order: 0),
      CustomJobType(
          id: 'junkCollection',
          label: 'Junk Collection',
          isDefault: true,
          order: 1),
      CustomJobType(
          id: 'flyersAndPosters',
          label: 'Flyers and Posters',
          isDefault: true,
          order: 2),
      CustomJobType(
          id: 'furnitureMove',
          label: 'Furniture Move',
          isDefault: true,
          order: 3),
      CustomJobType(
          id: 'flyerDistribution',
          label: 'Flyer Distribution',
          isDefault: true,
          order: 4),
      CustomJobType(
          id: 'flyerPrintingAndDistribution',
          label: 'Flyer Printing and Distribution',
          isDefault: true,
          order: 5),
      CustomJobType(
          id: 'windowCleaning',
          label: 'Window Cleaning',
          isDefault: true,
          order: 6),
      CustomJobType(
          id: 'solarPanelCleaning',
          label: 'Solar Panel Cleaning',
          isDefault: true,
          order: 7),
      CustomJobType(
          id: 'calendersDistribution',
          label: 'Calenders Distribution',
          isDefault: true,
          order: 8),
      CustomJobType(
          id: 'trailerTowing',
          label: 'Trailer Towing',
          isDefault: true,
          order: 9),
      CustomJobType(
          id: 'postering', label: 'Postering', isDefault: true, order: 10),
    ];
  }
}
