import 'package:cloud_firestore/cloud_firestore.dart';

class JobListItemUpdate {
  final String userId;
  final String fieldName;
  final dynamic oldValue;
  final dynamic newValue;
  final DateTime timestamp;
  final String userDisplayName; // Optional display name for UI
  final String? oldValueDisplay; // Optional readable label for oldValue
  final String? newValueDisplay; // Optional readable label for newValue

  JobListItemUpdate({
    required this.userId,
    required this.fieldName,
    required this.oldValue,
    required this.newValue,
    required this.timestamp,
    this.userDisplayName = '',
    this.oldValueDisplay,
    this.newValueDisplay,
  });

  // Create from Firestore
  factory JobListItemUpdate.fromMap(Map<String, dynamic> data) {
    return JobListItemUpdate(
      userId: data['userId'] as String? ?? '',
      fieldName: data['fieldName'] as String? ?? '',
      oldValue: data['oldValue'],
      newValue: data['newValue'],
      timestamp: data['timestamp'] != null
          ? (data['timestamp'] as Timestamp).toDate()
          : DateTime.now(),
      userDisplayName: data['userDisplayName'] as String? ?? '',
      oldValueDisplay: data['oldValueDisplay'] as String?,
      newValueDisplay: data['newValueDisplay'] as String?,
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'fieldName': fieldName,
      'oldValue': _serializeValue(oldValue),
      'newValue': _serializeValue(newValue),
      'timestamp': Timestamp.fromDate(timestamp),
      'userDisplayName': userDisplayName,
      'oldValueDisplay': oldValueDisplay,
      'newValueDisplay': newValueDisplay,
    };
  }

  // Helper method to serialize values for Firestore storage
  dynamic _serializeValue(dynamic value) {
    if (value is DateTime) {
      return Timestamp.fromDate(value);
    } else {
      return value;
    }
  }

  // Helper method to deserialize values from Firestore
  static dynamic deserializeValue(dynamic value, String fieldName) {
    if (value is Timestamp) {
      return value.toDate();
    } else {
      return value;
    }
  }

  // Get formatted display text for the change
  String getChangeDescription({String? jobTypeId}) {
    final oldValueText = _getValueDisplayText(oldValue, jobTypeId: jobTypeId);
    final newValueText = _getValueDisplayText(newValue, jobTypeId: jobTypeId);

    switch (fieldName) {
      case 'jobStatusId':
        return 'Status changed from "$oldValueText" to "$newValueText"';
      case 'amount':
        return 'Amount changed from R$oldValueText to R$newValueText';
      case 'date':
      case 'collectionDate':
        return '${_getFieldDisplayName(fieldName)} changed from $oldValueText to $newValueText';
      case 'jobType':
        return 'Job type changed from "$oldValueText" to "$newValueText"';
      default:
        return '${_getFieldDisplayName(fieldName)} changed from "$oldValueText" to "$newValueText"';
    }
  }

  // Backwards compatibility - keep the original method
  String getChangeDescriptionLegacy() {
    return getChangeDescription();
  }

  String _getValueDisplayText(dynamic value, {String? jobTypeId}) {
    if (value == null || value == '') return 'empty';

    // Use stored display labels if available (for status IDs and quantity)
    if (value == oldValue && oldValueDisplay != null) {
      return oldValueDisplay!;
    }
    if (value == newValue && newValueDisplay != null) {
      return newValueDisplay!;
    }

    if (value is DateTime) {
      // For date fields, check if we should show time based on job type
      if (fieldName == 'date' || fieldName == 'collectionDate') {
        final shouldShowTime = _shouldShowTime(jobTypeId) &&
            (value.hour != 0 || value.minute != 0);
        if (shouldShowTime) {
          return _formatDateTimeReadable(value);
        }
      }
      return _formatDateOnly(value);
    } else if (value is double) {
      return value.toStringAsFixed(2);
    } else {
      return value.toString();
    }
  }

  // Format date and time in readable format: "16 Oct 2025 10:00 AM"
  String _formatDateTimeReadable(DateTime dateTime) {
    final months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];

    final day = dateTime.day;
    final month = months[dateTime.month];
    final year = dateTime.year;

    // Convert to 12-hour format
    int hour12 = dateTime.hour;
    String period = 'AM';

    if (hour12 == 0) {
      hour12 = 12; // Midnight
    } else if (hour12 > 12) {
      hour12 = hour12 - 12;
      period = 'PM';
    } else if (hour12 == 12) {
      period = 'PM';
    }

    final minute = dateTime.minute.toString().padLeft(2, '0');

    return '$day $month $year $hour12:$minute $period';
  }

  // Format date only: "16 Oct 2025"
  String _formatDateOnly(DateTime dateTime) {
    final months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];

    final day = dateTime.day;
    final month = months[dateTime.month];
    final year = dateTime.year;

    return '$day $month $year';
  }

  // Helper method to determine if time should be shown for this job type
  bool _shouldShowTime(String? jobTypeId) {
    if (jobTypeId == null) return false;
    return jobTypeId == 'junkCollection' ||
        jobTypeId == 'furnitureMove' ||
        jobTypeId == 'trailerTowing' ||
        jobTypeId == 'windowCleaning' ||
        jobTypeId == 'solarPanelCleaning';
  }

  String _getFieldDisplayName(String fieldName) {
    switch (fieldName) {
      case 'invoice':
        return 'Invoice';
      case 'amount':
        return 'Amount';
      case 'client':
        return 'Client';
      case 'jobStatusId':
        return 'Status';
      case 'jobType':
        return 'Job Type';
      case 'area':
        return 'Area';
      case 'quantity':
        return 'Quantity';
      case 'manDays':
        return 'Man-Days';
      case 'date':
        return 'Date';
      case 'collectionAddress':
        return 'Collection Address';
      case 'collectionDate':
        return 'Collection Date';
      case 'specialInstructions':
        return 'Special Instructions';
      case 'quantityDistributed':
        return 'Quantity Distributed';
      case 'invoiceDetails':
        return 'Invoice Details';
      case 'reportAddresses':
        return 'Report Addresses';
      case 'whoToInvoice':
        return 'Who to Invoice';
      default:
        return fieldName;
    }
  }

  @override
  String toString() {
    return 'JobListItemUpdate(userId: $userId, fieldName: $fieldName, '
        'oldValue: $oldValue, newValue: $newValue, timestamp: $timestamp)';
  }
}
