import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

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
}

enum JobType {
  flyersPrintingOnly('Flyers - printing only'),
  junkCollection('Junk collection'),
  flyersAndPosters('Flyers and posters'),
  furnitureMove('Furniture move'),
  flyerDistribution('Flyer distribution'),
  flyerPrintingAndDistribution('Flyer printing and distribution');

  const JobType(this.displayName);
  final String displayName;
}

class JobListItem {
  final String id;
  final String invoice;
  final double amount;
  final String client;
  final JobListStatus jobStatus;
  final JobType jobType;
  final String area;
  final int quantity;
  final DateTime date;
  final String collectionAddress;
  final DateTime collectionDate;
  final String specialInstructions;
  final int quantityDistributed;
  final String invoiceDetails;
  final String reportAddresses;
  final String whoToInvoice;

  JobListItem({
    required this.id,
    required this.invoice,
    required this.amount,
    required this.client,
    required this.jobStatus,
    required this.jobType,
    required this.area,
    required this.quantity,
    required this.date,
    required this.collectionAddress,
    required this.collectionDate,
    required this.specialInstructions,
    required this.quantityDistributed,
    required this.invoiceDetails,
    required this.reportAddresses,
    required this.whoToInvoice,
  });

  // Create from Firestore
  factory JobListItem.fromMap(String id, Map<String, dynamic> data) {
    return JobListItem(
      id: id,
      invoice: data['invoice'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
      client: data['client'] as String? ?? '',
      jobStatus: JobListStatus.values.firstWhere(
        (e) => e.name == data['jobStatus'],
        orElse: () => JobListStatus.standby,
      ),
      jobType: JobType.values.firstWhere(
        (e) => e.name == data['jobType'],
        orElse: () => JobType.flyersPrintingOnly,
      ),
      area: data['area'] as String? ?? '',
      quantity: data['quantity'] as int? ?? 0,
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
    );
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'invoice': invoice,
      'amount': amount,
      'client': client,
      'jobStatus': jobStatus.name,
      'jobType': jobType.name,
      'area': area,
      'quantity': quantity,
      'date': Timestamp.fromDate(date),
      'collectionAddress': collectionAddress,
      'collectionDate': Timestamp.fromDate(collectionDate),
      'specialInstructions': specialInstructions,
      'quantityDistributed': quantityDistributed,
      'invoiceDetails': invoiceDetails,
      'reportAddresses': reportAddresses,
      'whoToInvoice': whoToInvoice,
    };
  }

  // Create a copy with some fields updated
  JobListItem copyWith({
    String? invoice,
    double? amount,
    String? client,
    JobListStatus? jobStatus,
    JobType? jobType,
    String? area,
    int? quantity,
    DateTime? date,
    String? collectionAddress,
    DateTime? collectionDate,
    String? specialInstructions,
    int? quantityDistributed,
    String? invoiceDetails,
    String? reportAddresses,
    String? whoToInvoice,
  }) {
    return JobListItem(
      id: id,
      invoice: invoice ?? this.invoice,
      amount: amount ?? this.amount,
      client: client ?? this.client,
      jobStatus: jobStatus ?? this.jobStatus,
      jobType: jobType ?? this.jobType,
      area: area ?? this.area,
      quantity: quantity ?? this.quantity,
      date: date ?? this.date,
      collectionAddress: collectionAddress ?? this.collectionAddress,
      collectionDate: collectionDate ?? this.collectionDate,
      specialInstructions: specialInstructions ?? this.specialInstructions,
      quantityDistributed: quantityDistributed ?? this.quantityDistributed,
      invoiceDetails: invoiceDetails ?? this.invoiceDetails,
      reportAddresses: reportAddresses ?? this.reportAddresses,
      whoToInvoice: whoToInvoice ?? this.whoToInvoice,
    );
  }

  // Get status color
  Color getStatusColor() {
    switch (jobStatus) {
      case JobListStatus.orderConfirmedNotPaid:
      case JobListStatus.orderConfirmedPaid:
        return Colors.blue;
      case JobListStatus.jobUnderWay:
      case JobListStatus.printingUnderWay:
        return Colors.orange;
      case JobListStatus.jobDone:
      case JobListStatus.reportCompliled:
      case JobListStatus.paid:
        return Colors.green;
      case JobListStatus.outstanding:
      case JobListStatus.query:
        return Colors.red;
      case JobListStatus.standby:
        return Colors.grey;
      case JobListStatus.invoiceSent:
      case JobListStatus.reportSent:
        return Colors.purple;
      case JobListStatus.printingOrderConfirmed:
      case JobListStatus.printingArtworkSubmitted:
      case JobListStatus.printingArtworkApproved:
      case JobListStatus.printingAwaitingPayment:
      case JobListStatus.printingReadyForCollection:
        return Colors.teal;
    }
  }

  @override
  String toString() {
    return 'JobListItem(id: $id, invoice: $invoice, client: $client, '
        'jobStatus: $jobStatus, amount: $amount)';
  }
}
