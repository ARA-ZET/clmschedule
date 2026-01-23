import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/happy_sun_job.dart';

/// Service for managing Happy Sun jobs (window cleaning & solar panel cleaning)
/// Stores jobs in monthly documents: /happySun/{YYYY-MM}/jobs array
class HappySunJobService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String collectionName = 'happySun';

  /// Get the monthly document ID for a given date
  String _getMonthlyDocId(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  /// Create a new Happy Sun job (synced with JobListItem)
  Future<void> createJob(HappySunJob job) async {
    try {
      final monthlyDocId = _getMonthlyDocId(job.date);
      final docRef = _firestore.collection(collectionName).doc(monthlyDocId);

      // Add job to the jobs array
      await docRef.set({
        'month': monthlyDocId,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await docRef.update({
        'jobs': FieldValue.arrayUnion([job.toMap()]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error creating Happy Sun job: $e');
      rethrow;
    }
  }

  /// Update an existing Happy Sun job
  Future<void> updateJob(HappySunJob job) async {
    try {
      final monthlyDocId = _getMonthlyDocId(job.date);
      final docRef = _firestore.collection(collectionName).doc(monthlyDocId);

      final doc = await docRef.get();
      if (!doc.exists) {
        throw Exception('Monthly document not found');
      }

      final data = doc.data()!;
      final jobs = (data['jobs'] as List<dynamic>?)
              ?.map((j) => j as Map<String, dynamic>)
              .toList() ??
          [];

      // Find and update the job
      final index = jobs.indexWhere((j) => j['id'] == job.id);
      if (index == -1) {
        throw Exception('Job not found in monthly document');
      }

      jobs[index] = job.copyWith(updatedAt: DateTime.now()).toMap();

      await docRef.update({
        'jobs': jobs,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating Happy Sun job: $e');
      rethrow;
    }
  }

  /// Delete a Happy Sun job
  Future<void> deleteJob(String jobId, DateTime date) async {
    try {
      final monthlyDocId = _getMonthlyDocId(date);
      final docRef = _firestore.collection(collectionName).doc(monthlyDocId);

      final doc = await docRef.get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final jobs = (data['jobs'] as List<dynamic>?)
              ?.map((j) => j as Map<String, dynamic>)
              .toList() ??
          [];

      // Remove the job
      jobs.removeWhere((j) => j['id'] == jobId);

      await docRef.update({
        'jobs': jobs,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error deleting Happy Sun job: $e');
      rethrow;
    }
  }

  /// Get a specific Happy Sun job by ID
  Future<HappySunJob?> getJob(String jobId, DateTime date) async {
    try {
      final monthlyDocId = _getMonthlyDocId(date);
      final doc =
          await _firestore.collection(collectionName).doc(monthlyDocId).get();

      if (!doc.exists) return null;

      final data = doc.data()!;
      final jobs = (data['jobs'] as List<dynamic>?)
              ?.map((j) => j as Map<String, dynamic>)
              .toList() ??
          [];

      final jobData = jobs.firstWhere(
        (j) => j['id'] == jobId,
        orElse: () => <String, dynamic>{},
      );

      if (jobData.isEmpty) return null;

      return HappySunJob.fromMap(jobId, jobData);
    } catch (e) {
      print('Error getting Happy Sun job: $e');
      rethrow;
    }
  }

  /// Get all Happy Sun jobs for a specific month
  Stream<List<HappySunJob>> getJobsForMonth(int year, int month) {
    final monthlyDocId = '$year-${month.toString().padLeft(2, '0')}';

    return _firestore
        .collection(collectionName)
        .doc(monthlyDocId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return <HappySunJob>[];

      final data = doc.data()!;
      final jobs = (data['jobs'] as List<dynamic>?)
              ?.map((j) => j as Map<String, dynamic>)
              .toList() ??
          [];

      return jobs
          .map((jobData) =>
              HappySunJob.fromMap(jobData['id'] as String, jobData))
          .toList();
    });
  }

  /// Get all Happy Sun jobs for a date range
  Stream<List<HappySunJob>> getJobsForDateRange(
      DateTime startDate, DateTime endDate) {
    // Generate list of monthly doc IDs needed
    final months = <String>[];
    var current = DateTime(startDate.year, startDate.month);
    final end = DateTime(endDate.year, endDate.month);

    while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
      months.add(_getMonthlyDocId(current));
      current = DateTime(current.year, current.month + 1);
    }

    if (months.isEmpty) {
      return Stream.value([]);
    }

    // Fetch all monthly documents
    return _firestore
        .collection(collectionName)
        .where(FieldPath.documentId, whereIn: months)
        .snapshots()
        .map((snapshot) {
      final allJobs = <HappySunJob>[];

      for (var doc in snapshot.docs) {
        if (!doc.exists) continue;

        final data = doc.data();
        final jobs = (data['jobs'] as List<dynamic>?)
                ?.map((j) => j as Map<String, dynamic>)
                .toList() ??
            [];

        for (var jobData in jobs) {
          final job = HappySunJob.fromMap(jobData['id'] as String, jobData);
          // Filter by date range
          if (job.date.isAfter(startDate.subtract(const Duration(days: 1))) &&
              job.date.isBefore(endDate.add(const Duration(days: 1)))) {
            allJobs.add(job);
          }
        }
      }

      return allJobs;
    });
  }

  /// Update tools needed for a job (planned before checkout)
  Future<void> updateToolsNeeded(
    String jobId,
    DateTime date,
    List<HappySunToolUsage> toolsNeeded,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(toolsNeeded: toolsNeeded);
    await updateJob(updatedJob);
  }

  /// Update categorized tools needed for a job
  Future<void> updateToolsNeededCategorized(
    String jobId,
    DateTime date,
    CategorizedTools categorizedTools,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(toolsNeededCategorized: categorizedTools);
    await updateJob(updatedJob);
  }

  /// Update only individual tools (keeps team tools and extras unchanged)
  Future<void> updateIndividualTools(
    String jobId,
    DateTime date,
    List<GroupedToolItem> individualTools,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    // Keep existing team tools and extras, only update individual tools
    final updatedCategorized = CategorizedTools(
      teamTools: job.toolsNeededCategorized?.teamTools ?? [],
      individualTools: individualTools,
      extras: job.toolsNeededCategorized?.extras ?? [],
    );

    final updatedJob = job.copyWith(toolsNeededCategorized: updatedCategorized);
    await updateJob(updatedJob);
  }

  /// Update categorized tools used during checkout
  Future<void> updateToolsUsedCategorized(
    String jobId,
    DateTime date,
    CategorizedTools categorizedTools,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(toolsUsedCategorized: categorizedTools);
    await updateJob(updatedJob);
  }

  /// Add tools to a job
  Future<void> addToolsToJob(
    String jobId,
    DateTime date,
    List<HappySunToolUsage> tools,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedTools = List<HappySunToolUsage>.from(job.toolsUsed)
      ..addAll(tools);
    final updatedJob = job.copyWith(toolsUsed: updatedTools);

    await updateJob(updatedJob);
  }

  /// Update job status (synced from JobListItem)
  Future<void> updateJobStatus(
      String jobId, DateTime date, String statusId) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(statusId: statusId);
    await updateJob(updatedJob);
  }

  /// Record start time
  Future<void> recordStartTime(
      String jobId, DateTime date, DateTime startTime) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(startTime: startTime);
    await updateJob(updatedJob);
  }

  /// Record end time
  Future<void> recordEndTime(
      String jobId, DateTime date, DateTime endTime) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(endTime: endTime);
    await updateJob(updatedJob);
  }

  /// Update notes
  Future<void> updateNotes(String jobId, DateTime date, String notes) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(notes: notes);
    await updateJob(updatedJob);
  }

  /// Update checklist data
  Future<void> updateChecklistData(
    String jobId,
    DateTime date,
    ChecklistData checklistData,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedJob = job.copyWith(
      checklistData: checklistData,
      updatedAt: DateTime.now(),
    );
    await updateJob(updatedJob);
  }

  /// Add team members
  Future<void> addTeamMembers(
    String jobId,
    DateTime date,
    List<String> teamMemberIds,
  ) async {
    final job = await getJob(jobId, date);
    if (job == null) {
      throw Exception('Job not found');
    }

    final updatedTeamMembers = List<String>.from(job.teamMemberIds)
      ..addAll(teamMemberIds);
    final updatedJob = job.copyWith(teamMemberIds: updatedTeamMembers);

    await updateJob(updatedJob);
  }
}
