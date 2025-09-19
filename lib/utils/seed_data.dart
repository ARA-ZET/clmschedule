import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> seedData() async {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  // Sample distributors
  final List<Map<String, dynamic>> distributors = [
    {'name': 'John Smith'},
    {'name': 'Sarah Johnson'},
    {'name': 'Michael Brown'},
  ];

  // Add distributors
  List<String> distributorIds = [];
  for (var distributor in distributors) {
    final docRef = await firestore.collection('distributors').add(distributor);
    distributorIds.add(docRef.id);
  }

  // Sample jobs
  final now = DateTime.now();
  final List<Map<String, dynamic>> jobs = [
    {
      'client': 'ABC Company',
      'workAreaId': '', // Will be set when work areas are created
      'workName': 'Downtown',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'scheduled',
    },
    {
      'client': 'XYZ Corp',
      'workAreaId': '',
      'workName': 'Suburb Area',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'scheduled',
    },
    {
      'client': '123 Industries',
      'workAreaId': '',
      'workName': 'Business Park',
      'distributorId': distributorIds[2],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'done',
    },
    {
      'client': 'Global Solutions',
      'workAreaId': '',
      'workName': 'Tech Hub',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day + 1),
      'status': 'scheduled',
    },
    {
      'client': 'Local Store',
      'workAreaId': '',
      'workName': 'Shopping Mall',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day + 1),
      'status': 'scheduled',
    },
  ];

  // Add jobs
  for (var job in jobs) {
    // Convert DateTime objects to Timestamps for Firestore
    job['date'] = Timestamp.fromDate(job['date'] as DateTime);

    await firestore.collection('jobs').add(job);
  }
}
