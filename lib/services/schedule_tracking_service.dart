import '../models/distributor.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';

/// Data model for tracking sheet entries
class TrackingSheetEntry {
  final String distributorId;
  final String distributorName;
  final String? phone1;
  final String? phone2;
  final List<Job> jobs;
  final DistributorStatus status;
  final DateTime date;

  TrackingSheetEntry({
    required this.distributorId,
    required this.distributorName,
    this.phone1,
    this.phone2,
    required this.jobs,
    required this.status,
    required this.date,
  });

  /// Get formatted working areas string
  String get workingAreasText {
    if (jobs.isEmpty) return 'No assignments';

    final areas = jobs.expand((job) => job.workingAreas).toSet().toList();

    return areas.join(', ');
  }

  /// Get formatted clients string
  String get clientsText {
    if (jobs.isEmpty) return 'No assignments';

    final clients = jobs.expand((job) => job.clients).toSet().toList();

    return clients.join(', ');
  }

  /// Get primary phone for display
  String get primaryPhone => phone1 ?? phone2 ?? 'No phone';

  /// Get secondary phone for display
  String get secondaryPhone => phone2 ?? '';

  /// Check if distributor is available for work
  bool get isAvailable => status == DistributorStatus.active && jobs.isNotEmpty;
}

/// Service for generating schedule tracking sheets
class ScheduleTrackingService {
  final ScheduleProvider _scheduleProvider;

  ScheduleTrackingService(this._scheduleProvider);

  /// Generate tracking sheet data for a specific date
  /// Only includes active distributors
  List<TrackingSheetEntry> generateTrackingSheet(DateTime date) {
    final activeDistributors = _scheduleProvider.distributors
        .where((d) => d.status == DistributorStatus.active)
        .toList();

    // Sort by index for consistent ordering
    activeDistributors.sort((a, b) => a.index.compareTo(b.index));

    final trackingEntries = <TrackingSheetEntry>[];

    for (final distributor in activeDistributors) {
      final jobs = _scheduleProvider.getJobsForDistributorAndDate(
        distributor.id,
        date,
      );

      final entry = TrackingSheetEntry(
        distributorId: distributor.id,
        distributorName: distributor.name,
        phone1: distributor.phone1,
        phone2: distributor.phone2,
        jobs: jobs,
        status: distributor.status,
        date: date,
      );

      trackingEntries.add(entry);
    }

    return trackingEntries;
  }

  /// Generate tracking sheet data for a date range
  Map<DateTime, List<TrackingSheetEntry>> generateTrackingSheetForRange(
    DateTime startDate,
    DateTime endDate,
  ) {
    final sheets = <DateTime, List<TrackingSheetEntry>>{};

    DateTime currentDate = startDate;
    while (currentDate.isBefore(endDate) ||
        currentDate.isAtSameMomentAs(endDate)) {
      sheets[currentDate] = generateTrackingSheet(currentDate);
      currentDate = currentDate.add(const Duration(days: 1));
    }

    return sheets;
  }

  /// Generate tracking sheet for the current week
  Map<DateTime, List<TrackingSheetEntry>> generateWeeklyTrackingSheet(
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Find Monday of the week
    final monday = targetDate.subtract(Duration(days: targetDate.weekday - 1));

    // Get Friday of the same week (5 working days)
    final friday = monday.add(const Duration(days: 4));

    return generateTrackingSheetForRange(monday, friday);
  }

  /// Generate tracking sheet for the current month
  Map<DateTime, List<TrackingSheetEntry>> generateMonthlyTrackingSheet(
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // First day of the month
    final firstDay = DateTime(targetDate.year, targetDate.month, 1);

    // Last day of the month
    final lastDay = DateTime(targetDate.year, targetDate.month + 1, 0);

    return generateTrackingSheetForRange(firstDay, lastDay);
  }

  /// Get tracking summary statistics
  TrackingSheetSummary getTrackingSummary(List<TrackingSheetEntry> entries) {
    final totalDistributors = entries.length;
    final assignedDistributors = entries.where((e) => e.jobs.isNotEmpty).length;
    final totalJobs =
        entries.fold<int>(0, (sum, entry) => sum + entry.jobs.length);
    final availableDistributors = entries.where((e) => e.isAvailable).length;

    return TrackingSheetSummary(
      totalDistributors: totalDistributors,
      assignedDistributors: assignedDistributors,
      availableDistributors: availableDistributors,
      unassignedDistributors: totalDistributors - assignedDistributors,
      totalJobs: totalJobs,
    );
  }

  /// Export tracking sheet data to CSV format (for Google Sheets compatibility)
  String exportToCSV(List<TrackingSheetEntry> entries, DateTime date) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln(
        'Date,Distributor,Phone 1,Phone 2,Status,Clients,Working Areas,Jobs Count');

    // Data rows
    for (final entry in entries) {
      final row = [
        date.toString().split(' ')[0], // Date only
        entry.distributorName,
        entry.phone1 ?? '',
        entry.phone2 ?? '',
        entry.status.displayName,
        '"${entry.clientsText}"', // Quoted for CSV
        '"${entry.workingAreasText}"', // Quoted for CSV
        entry.jobs.length.toString(),
      ].join(',');

      buffer.writeln(row);
    }

    return buffer.toString();
  }
}

/// Summary statistics for tracking sheets
class TrackingSheetSummary {
  final int totalDistributors;
  final int assignedDistributors;
  final int availableDistributors;
  final int unassignedDistributors;
  final int totalJobs;

  TrackingSheetSummary({
    required this.totalDistributors,
    required this.assignedDistributors,
    required this.availableDistributors,
    required this.unassignedDistributors,
    required this.totalJobs,
  });

  double get assignmentRate => totalDistributors > 0
      ? (assignedDistributors / totalDistributors) * 100
      : 0.0;

  double get availabilityRate => totalDistributors > 0
      ? (availableDistributors / totalDistributors) * 100
      : 0.0;
}
