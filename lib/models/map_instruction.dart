class MapInstruction {
  final String id;
  final String text;
  final int order;

  const MapInstruction({
    required this.id,
    required this.text,
    this.order = 0,
  });

  factory MapInstruction.fromMap(String id, Map<String, dynamic> data) {
    return MapInstruction(
      id: id,
      text: data['text'] as String? ?? '',
      order: (data['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'order': order,
    };
  }

  MapInstruction copyWith({String? id, String? text, int? order}) {
    return MapInstruction(
      id: id ?? this.id,
      text: text ?? this.text,
      order: order ?? this.order,
    );
  }

  static List<MapInstruction> getDefaults() {
    return const [
      MapInstruction(id: 'house_only', text: 'Do house only', order: 0),
      MapInstruction(id: 'shaded_only', text: 'Shaded areas only', order: 1),
      MapInstruction(
          id: 'unshaded_only', text: 'Unshaded areas only', order: 2),
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapInstruction && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);

  @override
  String toString() => 'MapInstruction(id: $id, text: $text, order: $order)';
}
