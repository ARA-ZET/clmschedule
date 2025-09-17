class Distributor {
  final String id;
  final String name;

  Distributor({required this.id, required this.name});

  // Create from Firestore
  factory Distributor.fromMap(String id, Map<String, dynamic> data) {
    return Distributor(id: id, name: data['name'] as String);
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {'name': name};
  }

  @override
  String toString() => 'Distributor(id: $id, name: $name)';
}
