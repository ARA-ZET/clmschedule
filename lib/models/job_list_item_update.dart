import 'package:cloud_firestore/cloud_firestore.dart';
import 'job_list_item.dart';

class JobListItemUpdate {
  final String userId;
  final String fieldName;
  final dynamic oldValue;
  final dynamic newValue;
  final DateTime timestamp;
  final String userDisplayName; // Optional display name for UI

  JobListItemUpdate({
    required this.userId,
    required this.fieldName,
    required this.oldValue,
    required this.newValue,
    required this.timestamp,
    this.userDisplayName = '',
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
    };
  }

  // Helper method to serialize values for Firestore storage
  dynamic _serializeValue(dynamic value) {
    if (value is DateTime) {
      return Timestamp.fromDate(value);
    } else if (value is JobType) {
      return value.name;
    } else {
      return value;
    }
  }

  // Helper method to deserialize values from Firestore
  static dynamic deserializeValue(dynamic value, String fieldName) {
    if (value is Timestamp) {
      return value.toDate();
    } else if (fieldName == 'jobType' && value is String) {
      try {
        return JobType.values.firstWhere((e) => e.name == value);
      } catch (e) {
        return JobType.flyersPrintingOnly; // Default fallback
      }
    } else {
      return value;
    }
  }

  // Get formatted display text for the change
  String getChangeDescription() {
    final oldValueText = _getValueDisplayText(oldValue);
    final newValueText = _getValueDisplayText(newValue);

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

  String _getValueDisplayText(dynamic value) {
    if (value == null || value == '') return 'empty';

    if (value is DateTime) {
      return '${value.day}/${value.month}/${value.year}';
    } else if (value is JobType) {
      return value.displayName;
    } else if (value is double) {
      return value.toStringAsFixed(2);
    } else {
      return value.toString();
    }
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
