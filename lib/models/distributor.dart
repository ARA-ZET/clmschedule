class Distributor {
  final String id; // Document ID from Firestore
  final String name;
  final int index; // Position/order index for sorting and display

  Distributor({
    required this.id,
    required this.name,
    required this.index,
  });

  // Create from Firestore
  factory Distributor.fromMap(String id, Map<String, dynamic> data) {
    return Distributor(
      id: id,
      name: data['name'] as String,
      index: data['index'] as int? ?? 0, // Default to 0 if not set
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'index': index,
    };
  }

  // Create a copy with updated fields
  Distributor copyWith({
    String? id,
    String? name,
    int? index,
  }) {
    return Distributor(
      id: id ?? this.id,
      name: name ?? this.name,
      index: index ?? this.index,
    );
  }

  @override
  String toString() => 'Distributor(id: $id, name: $name, index: $index)';
}
