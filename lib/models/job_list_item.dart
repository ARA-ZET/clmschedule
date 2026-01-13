import 'package:cloud_firestore/cloud_firestore.dart';
import 'job_list_item_update.dart';
import 'custom_polygon.dart';
import 'job_reminder.dart';

// Legacy enum for backwards compatibility during migration
enum JobListStatus {
  orderConfirmedNotPaid('Order Confirmed Not Paid'),
  jobUnderWay('Job Under Way'),
  jobDone('Job Done'),
  reportCompliled('Report Compliled'),
  outstanding('Outstanding'),
  invoiceSent('Invoice sent'),
  standby('Standby'),
  printingOrderConfirmed('Printing - order confirmed'),
  printingArtworkSubmitted('Printing - Artwork submitted'),
  printingArtworkApproved('Printing - Artwork approved'),
  printingAwaitingPayment('Printing - Awaiting payment'),
  printingUnderWay('Printing under way'),
  printingReadyForCollection('Printing - ready for collection'),
  query('Query'),
  orderConfirmedPaid('Order Confirmed Paid'),
  reportSent('Report Sent'),
  paid('Paid');

  const JobListStatus(this.displayName);
  final String displayName;

  // Helper method to convert enum to custom status ID
  String get customStatusId {
    switch (this) {
      case JobListStatus.orderConfirmedNotPaid:
        return 'order_confirmed_not_paid';
      case JobListStatus.jobUnderWay:
        return 'job_under_way';
      case JobListStatus.jobDone:
        return 'job_done';
      case JobListStatus.reportCompliled:
        return 'report_compliled';
      case JobListStatus.outstanding:
        return 'outstanding';
      case JobListStatus.invoiceSent:
        return 'invoice_sent';
      case JobListStatus.standby:
        return 'standby';
      case JobListStatus.printingOrderConfirmed:
        return 'printing_order_confirmed';
      case JobListStatus.printingArtworkSubmitted:
        return 'printing_artwork_submitted';
      case JobListStatus.printingArtworkApproved:
        return 'printing_artwork_approved';
      case JobListStatus.printingAwaitingPayment:
        return 'printing_awaiting_payment';
      case JobListStatus.printingUnderWay:
        return 'printing_under_way';
      case JobListStatus.printingReadyForCollection:
        return 'printing_ready_for_collection';
      case JobListStatus.query:
        return 'query';
      case JobListStatus.orderConfirmedPaid:
        return 'order_confirmed_paid';
      case JobListStatus.reportSent:
        return 'report_sent';
      case JobListStatus.paid:
        return 'paid';
    }
  }
}

enum JobType {
  flyersPrintingOnly('Flyers - Printing only'),
  junkCollection('Junk Collection'),
  flyersAndPosters('Flyers and Posters'),
  furnitureMove('Furniture Move'),
  flyerDistribution('Flyer Distribution'),
  flyerPrintingAndDistribution('Flyer Printing and Distribution'),
  windowCleaning('Window Cleaning'),
  solarPanelCleaning('Solar Panel Cleaning'),
  calendersDistribution('Calenders Distribution'),
  trailerTowing('Trailer Towing'),
  postering('Postering');

  const JobType(this.displayName);
  final String displayName;
}

class JobListItem {
  final String id;
  final String invoice;
  final double amount;
  final String client;
  final String jobStatusId; // Changed from JobListStatus enum to String
  final String invoiceStatusId; // Invoice status (separate from job status)
  final JobType jobType;
  final String area;
  final int quantity;
  final double manDays;
  final DateTime date;
  final String collectionAddress;
  final DateTime collectionDate;
  final String specialInstructions;
  final int quantityDistributed;
  final String invoiceDetails;
  final String reportAddresses;
  final String whoToInvoice;
  final String collectionJobId; // Link to collection schedule job
  final List<JobListItemUpdate> updates; // Track all changes
  final List<CustomPolygon> customPolygons; // Custom polygons for map areas
  final List<JobReminder> reminders; // List of reminders for invoice chase

  JobListItem({
    required this.id,
    required this.invoice,
    required this.amount,
    required this.client,
    required this.jobStatusId,
    this.invoiceStatusId = 'pending', // Default to pending invoice status
    required this.jobType,
    required this.area,
    required this.quantity,
    required this.manDays,
    required this.date,
    required this.collectionAddress,
    required this.collectionDate,
    required this.specialInstructions,
    required this.quantityDistributed,
    required this.invoiceDetails,
    required this.reportAddresses,
    required this.whoToInvoice,
    this.collectionJobId = '', // Optional link to collection job
    this.updates = const [], // Default to empty list
    this.customPolygons = const [], // Default to empty list
    this.reminders = const [], // Default to empty list
  });

  // Create from Firestore
  factory JobListItem.fromMap(String id, Map<String, dynamic> data) {
    // Handle backwards compatibility for jobStatus field
    String jobStatusId = data['jobStatusId'] as String? ?? '';

    // If jobStatusId is empty but jobStatus exists (old enum format), convert it
    if (jobStatusId.isEmpty && data['jobStatus'] != null) {
      try {
        final oldStatus = JobListStatus.values.firstWhere(
          (e) => e.name == data['jobStatus'],
          orElse: () => JobListStatus.standby,
        );
        jobStatusId = oldStatus.customStatusId;
      } catch (e) {
        jobStatusId = 'standby'; // Default fallback
      }
    }

    // If still empty, use default
    if (jobStatusId.isEmpty) {
      jobStatusId = 'standby';
    }

    // Handle invoice status with backwards compatibility
    String invoiceStatusId = data['invoiceStatusId'] as String? ?? 'pending';

    // Parse updates
    List<JobListItemUpdate> updates = [];
    if (data['updates'] != null) {
      final updatesData = data['updates'] as List<dynamic>;
      updates = updatesData
          .map((updateData) =>
              JobListItemUpdate.fromMap(updateData as Map<String, dynamic>))
          .toList();
    }

    // Parse custom polygons
    List<CustomPolygon> customPolygons = [];
    if (data['customPolygons'] != null) {
      final polygonsData = data['customPolygons'] as List<dynamic>;
      customPolygons = polygonsData
          .map((polygonData) =>
              CustomPolygon.fromMap(polygonData as Map<String, dynamic>))
          .toList();
    }

    // Parse reminders
    List<JobReminder> reminders = [];
    if (data['reminders'] != null) {
      final remindersData = data['reminders'] as List<dynamic>;
      reminders = remindersData
          .map((reminderData) =>
              JobReminder.fromMap(reminderData as Map<String, dynamic>))
          .toList();
    }

    return JobListItem(
      id: id,
      invoice: data['invoice'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
      client: data['client'] as String? ?? '',
      jobStatusId: jobStatusId,
      invoiceStatusId: invoiceStatusId,
      jobType: JobType.values.firstWhere(
        (e) => e.name == data['jobType'],
        orElse: () => JobType.flyersPrintingOnly,
      ),
      area: data['area'] as String? ?? '',
      quantity: data['quantity'] as int? ?? 0,
      manDays: (data['manDays'] as num?)?.toDouble() ?? 0.0,
      date: data['date'] != null
          ? (data['date'] as Timestamp).toDate()
          : DateTime.now(),
      collectionAddress: data['collectionAddress'] as String? ?? '',
      collectionDate: data['collectionDate'] != null
          ? (data['collectionDate'] as Timestamp).toDate()
          : DateTime.now(),
      specialInstructions: data['specialInstructions'] as String? ?? '',
      quantityDistributed: data['quantityDistributed'] as int? ?? 0,
      invoiceDetails: data['invoiceDetails'] as String? ?? '',
      reportAddresses: data['reportAddresses'] as String? ?? '',
      whoToInvoice: data['whoToInvoice'] as String? ?? '',
      collectionJobId: data['collectionJobId'] as String? ?? '',
      updates: updates,
      customPolygons: customPolygons,
      reminders: reminders,
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'invoice': invoice,
      'amount': amount,
      'client': client,
      'jobStatusId': jobStatusId, // Changed from jobStatus.name to jobStatusId
      'invoiceStatusId': invoiceStatusId,
      'jobType': jobType.name,
      'area': area,
      'quantity': quantity,
      'manDays': manDays,
      'date': Timestamp.fromDate(date),
      'collectionAddress': collectionAddress,
      'collectionDate': Timestamp.fromDate(collectionDate),
      'specialInstructions': specialInstructions,
      'quantityDistributed': quantityDistributed,
      'invoiceDetails': invoiceDetails,
      'reportAddresses': reportAddresses,
      'whoToInvoice': whoToInvoice,
      'collectionJobId': collectionJobId,
      'updates': updates.map((update) => update.toMap()).toList(),
      'customPolygons':
          customPolygons.map((polygon) => polygon.toMap()).toList(),
      'reminders': reminders.map((reminder) => reminder.toMap()).toList(),
    };
  }

  // Create a copy with some fields updated
  JobListItem copyWith({
    String? invoice,
    double? amount,
    String? client,
    String?
        jobStatusId, // Changed from JobListStatus? jobStatus to String? jobStatusId
    String? invoiceStatusId,
    JobType? jobType,
    String? area,
    int? quantity,
    double? manDays,
    DateTime? date,
    String? collectionAddress,
    DateTime? collectionDate,
    String? specialInstructions,
    int? quantityDistributed,
    String? invoiceDetails,
    String? reportAddresses,
    String? whoToInvoice,
    String? collectionJobId,
    List<JobListItemUpdate>? updates,
    List<CustomPolygon>? customPolygons,
    List<JobReminder>? reminders,
  }) {
    return JobListItem(
      id: id,
      invoice: invoice ?? this.invoice,
      amount: amount ?? this.amount,
      client: client ?? this.client,
      jobStatusId: jobStatusId ?? this.jobStatusId,
      invoiceStatusId: invoiceStatusId ?? this.invoiceStatusId,
      jobType: jobType ?? this.jobType,
      area: area ?? this.area,
      quantity: quantity ?? this.quantity,
      manDays: manDays ?? this.manDays,
      date: date ?? this.date,
      collectionAddress: collectionAddress ?? this.collectionAddress,
      collectionDate: collectionDate ?? this.collectionDate,
      specialInstructions: specialInstructions ?? this.specialInstructions,
      quantityDistributed: quantityDistributed ?? this.quantityDistributed,
      invoiceDetails: invoiceDetails ?? this.invoiceDetails,
      reportAddresses: reportAddresses ?? this.reportAddresses,
      whoToInvoice: whoToInvoice ?? this.whoToInvoice,
      collectionJobId: collectionJobId ?? this.collectionJobId,
      updates: updates ?? this.updates,
      customPolygons: customPolygons ?? this.customPolygons,
      reminders: reminders ?? this.reminders,
    );
  }

  // Create a copy with a tracked change
  JobListItem copyWithTrackedChange({
    required String userId,
    required String userDisplayName,
    String? invoice,
    double? amount,
    String? client,
    String? jobStatusId,
    String? invoiceStatusId,
    JobType? jobType,
    String? area,
    int? quantity,
    double? manDays,
    DateTime? date,
    String? collectionAddress,
    DateTime? collectionDate,
    String? specialInstructions,
    int? quantityDistributed,
    String? invoiceDetails,
    String? reportAddresses,
    String? whoToInvoice,
    String? collectionJobId,
    List<CustomPolygon>? customPolygons,
    // Helper functions to resolve display labels
    String? Function(String statusId)? resolveJobStatusLabel,
    String? Function(String statusId)? resolveInvoiceStatusLabel,
    String? Function(int quantity, JobType jobType)? resolveQuantityLabel,
  }) {
    final List<JobListItemUpdate> newUpdates = List.from(updates);

    // Track changes for each modified field
    if (invoice != null && invoice != this.invoice) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'invoice',
        oldValue: this.invoice,
        newValue: invoice,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (amount != null && amount != this.amount) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'amount',
        oldValue: this.amount,
        newValue: amount,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (client != null && client != this.client) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'client',
        oldValue: this.client,
        newValue: client,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (jobStatusId != null && jobStatusId != this.jobStatusId) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'jobStatusId',
        oldValue: this.jobStatusId,
        newValue: jobStatusId,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay: resolveJobStatusLabel?.call(this.jobStatusId),
        newValueDisplay: resolveJobStatusLabel?.call(jobStatusId),
      ));
    }

    if (invoiceStatusId != null && invoiceStatusId != this.invoiceStatusId) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'invoiceStatusId',
        oldValue: this.invoiceStatusId,
        newValue: invoiceStatusId,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay: resolveInvoiceStatusLabel?.call(this.invoiceStatusId),
        newValueDisplay: resolveInvoiceStatusLabel?.call(invoiceStatusId),
      ));
    }

    if (jobType != null && jobType != this.jobType) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'jobType',
        oldValue: this.jobType,
        newValue: jobType,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (area != null && area != this.area) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'area',
        oldValue: this.area,
        newValue: area,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (quantity != null && quantity != this.quantity) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'quantity',
        oldValue: this.quantity,
        newValue: quantity,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay:
            resolveQuantityLabel?.call(this.quantity, jobType ?? this.jobType),
        newValueDisplay:
            resolveQuantityLabel?.call(quantity, jobType ?? this.jobType),
      ));
    }

    if (manDays != null && manDays != this.manDays) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'manDays',
        oldValue: this.manDays,
        newValue: manDays,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (date != null && !_isSameDateAndTime(date, this.date)) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'date',
        oldValue: this.date,
        newValue: date,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (collectionAddress != null &&
        collectionAddress != this.collectionAddress) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'collectionAddress',
        oldValue: this.collectionAddress,
        newValue: collectionAddress,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (collectionDate != null &&
        !_isSameDateAndTime(collectionDate, this.collectionDate)) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'collectionDate',
        oldValue: this.collectionDate,
        newValue: collectionDate,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (specialInstructions != null &&
        specialInstructions != this.specialInstructions) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'specialInstructions',
        oldValue: this.specialInstructions,
        newValue: specialInstructions,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (quantityDistributed != null &&
        quantityDistributed != this.quantityDistributed) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'quantityDistributed',
        oldValue: this.quantityDistributed,
        newValue: quantityDistributed,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (invoiceDetails != null && invoiceDetails != this.invoiceDetails) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'invoiceDetails',
        oldValue: this.invoiceDetails,
        newValue: invoiceDetails,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (reportAddresses != null && reportAddresses != this.reportAddresses) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'reportAddresses',
        oldValue: this.reportAddresses,
        newValue: reportAddresses,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (whoToInvoice != null && whoToInvoice != this.whoToInvoice) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'whoToInvoice',
        oldValue: this.whoToInvoice,
        newValue: whoToInvoice,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (collectionJobId != null && collectionJobId != this.collectionJobId) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'collectionJobId',
        oldValue: this.collectionJobId,
        newValue: collectionJobId,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    return copyWith(
      invoice: invoice,
      amount: amount,
      client: client,
      jobStatusId: jobStatusId,
      invoiceStatusId: invoiceStatusId,
      jobType: jobType,
      area: area,
      quantity: quantity,
      manDays: manDays,
      date: date,
      collectionAddress: collectionAddress,
      collectionDate: collectionDate,
      specialInstructions: specialInstructions,
      quantityDistributed: quantityDistributed,
      invoiceDetails: invoiceDetails,
      reportAddresses: reportAddresses,
      whoToInvoice: whoToInvoice,
      collectionJobId: collectionJobId,
      updates: newUpdates,
      customPolygons: customPolygons,
    );
  }

  // Helper method to compare dates (ignoring time)
  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  // Helper method to compare dates and times appropriately for tracking changes
  bool _isSameDateAndTime(DateTime date1, DateTime date2) {
    // For job types that need time slots, compare both date AND time (but ignore seconds/milliseconds)
    if (_needsTimeDisplay()) {
      return date1.year == date2.year &&
          date1.month == date2.month &&
          date1.day == date2.day &&
          date1.hour == date2.hour &&
          date1.minute == date2.minute;
    }
    // For other job types, just compare the date (ignore time completely)
    return _isSameDay(date1, date2);
  }

  // Helper method to check if job type needs time display
  bool _needsTimeDisplay() {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove ||
        jobType == JobType.trailerTowing ||
        jobType == JobType.windowCleaning ||
        jobType == JobType.solarPanelCleaning;
  }

  // Backwards compatibility getter - converts jobStatusId back to JobListStatus enum
  JobListStatus get jobStatus {
    for (final status in JobListStatus.values) {
      if (status.customStatusId == jobStatusId) {
        return status;
      }
    }
    // Default fallback if no match found
    return JobListStatus.standby;
  }

  @override
  String toString() {
    return 'JobListItem(id: $id, invoice: $invoice, client: $client, '
        'jobStatusId: $jobStatusId, amount: $amount)';
  }
}
