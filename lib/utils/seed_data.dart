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
      'workingArea': 'Downtown',
      'mapLink': 'https://maps.google.com/?q=downtown',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day),
      'startTime': DateTime(now.year, now.month, now.day, 9),
      'endTime': DateTime(now.year, now.month, now.day, 11),
      'status': 'scheduled',
    },
    {
      'client': 'XYZ Corp',
      'workingArea': 'Suburb Area',
      'mapLink': 'https://maps.google.com/?q=suburb',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day),
      'startTime': DateTime(now.year, now.month, now.day, 10),
      'endTime': DateTime(now.year, now.month, now.day, 12),
      'status': 'inProgress',
    },
    {
      'client': '123 Industries',
      'workingArea': 'Business Park',
      'mapLink': 'https://maps.google.com/?q=business+park',
      'distributorId': distributorIds[2],
      'date': DateTime(now.year, now.month, now.day),
      'startTime': DateTime(now.year, now.month, now.day, 13),
      'endTime': DateTime(now.year, now.month, now.day, 15),
      'status': 'completed',
    },
    {
      'client': 'Global Solutions',
      'workingArea': 'Tech Hub',
      'mapLink': 'https://maps.google.com/?q=tech+hub',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day + 1),
      'startTime': DateTime(now.year, now.month, now.day + 1, 9),
      'endTime': DateTime(now.year, now.month, now.day + 1, 11),
      'status': 'scheduled',
    },
    {
      'client': 'Local Store',
      'workingArea': 'Shopping Mall',
      'mapLink': 'https://maps.google.com/?q=shopping+mall',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day + 1),
      'startTime': DateTime(now.year, now.month, now.day + 1, 14),
      'endTime': DateTime(now.year, now.month, now.day + 1, 16),
      'status': 'scheduled',
    },
  ];

  // Add jobs
  for (var job in jobs) {
    // Convert DateTime objects to Timestamps for Firestore
    job['date'] = Timestamp.fromDate(job['date'] as DateTime);
    job['startTime'] = Timestamp.fromDate(job['startTime'] as DateTime);
    job['endTime'] = Timestamp.fromDate(job['endTime'] as DateTime);

    await firestore.collection('jobs').add(job);
  }
}
