import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/monthly_service.dart';

Future<void> seedData() async {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final MonthlyService monthlyService = MonthlyService(firestore);
  final DateTime currentMonth = DateTime.now();

  // Ensure monthly document exists for current month (for jobs)
  await monthlyService.ensureScheduleMonthlyDocExists(currentMonth);

  // Sample distributors - Add to root collection
  final List<Map<String, dynamic>> distributors = [
    {'name': 'John Smith', 'index': 0},
    {'name': 'Sarah Johnson', 'index': 1},
    {'name': 'Michael Brown', 'index': 2},
  ];

  // Add distributors to root collection (not monthly)
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
      'workingArea': 'Downtown',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'scheduled',
    },
    {
      'client': 'XYZ Corp',
      'workAreaId': '',
      'workingArea': 'Suburb Area',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'scheduled',
    },
    {
      'client': '123 Industries',
      'workAreaId': '',
      'workingArea': 'Business Park',
      'distributorId': distributorIds[2],
      'date': DateTime(now.year, now.month, now.day),
      'status': 'done',
    },
    {
      'client': 'Global Solutions',
      'workAreaId': '',
      'workingArea': 'Tech Hub',
      'distributorId': distributorIds[0],
      'date': DateTime(now.year, now.month, now.day + 1),
      'status': 'scheduled',
    },
    {
      'client': 'Local Store',
      'workAreaId': '',
      'workingArea': 'Shopping Mall',
      'distributorId': distributorIds[1],
      'date': DateTime(now.year, now.month, now.day + 1),
      'status': 'scheduled',
    },
  ];

  // Add jobs to monthly collection
  for (var job in jobs) {
    // Convert DateTime objects to Timestamps for Firestore
    job['date'] = Timestamp.fromDate(job['date'] as DateTime);

    await monthlyService.getJobsCollection(currentMonth).add(job);
  }
}
