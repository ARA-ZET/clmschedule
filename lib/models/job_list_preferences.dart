import 'package:cloud_firestore/cloud_firestore.dart';

/// Model for storing user-specific job list column preferences
class JobListPreferences {
  final String userId;
  final Map<String, bool> columnVisibility;
  final DateTime lastUpdated;

  JobListPreferences({
    required this.userId,
    required this.columnVisibility,
    required this.lastUpdated,
  });

  // Default column visibility - date, client, jobStatus, refresh, and actions are always visible
  static Map<String, bool> get defaultColumnVisibility => {
        'date': true, // Always visible
        'client': true, // Always visible
        'jobStatus': true, // Always visible
        'reminder': true,
        'invoiceStatus': true,
        'jobType': true,
        'area': true,
        'quantity': true,
        'manDays': true,
        'collectionAddress': true,
        'specialInstructions': true,
        'collectionDate': true,
        'invoice': true,
        'amount': true,
        'quantityDistributed': true,
        'invoiceDetails': true,
        'reportAddresses': true,
        'whoToInvoice': true,
        'refresh': true, // Always visible
        'actions': true, // Always visible
      };

  // Columns that cannot be hidden
  static Set<String> get requiredColumns => {
        'date',
        'client',
        'jobStatus',
        'refresh',
        'actions',
      };

  factory JobListPreferences.defaultPreferences(String userId) {
    return JobListPreferences(
      userId: userId,
      columnVisibility: defaultColumnVisibility,
      lastUpdated: DateTime.now(),
    );
  }

  factory JobListPreferences.fromMap(String userId, Map<String, dynamic> data) {
    // Merge with defaults to ensure all columns are present
    final savedVisibility =
        Map<String, bool>.from(data['columnVisibility'] ?? {});
    final mergedVisibility = {...defaultColumnVisibility, ...savedVisibility};

    return JobListPreferences(
      userId: userId,
      columnVisibility: mergedVisibility,
      lastUpdated:
          (data['lastUpdated'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'columnVisibility': columnVisibility,
      'lastUpdated': Timestamp.fromDate(lastUpdated),
    };
  }

  JobListPreferences copyWith({
    String? userId,
    Map<String, bool>? columnVisibility,
    DateTime? lastUpdated,
  }) {
    return JobListPreferences(
      userId: userId ?? this.userId,
      columnVisibility: columnVisibility ?? this.columnVisibility,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  bool isColumnVisible(String columnKey) {
    return columnVisibility[columnKey] ?? true;
  }

  bool canToggleColumn(String columnKey) {
    return !requiredColumns.contains(columnKey);
  }
}
