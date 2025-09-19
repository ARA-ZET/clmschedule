import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job_list_item.dart';
import '../services/job_list_service.dart';

Future<void> seedJobListData() async {
  final jobListService = JobListService(FirebaseFirestore.instance);

  final sampleJobs = [
    JobListItem(
      id: '',
      invoice: '8695',
      amount: 1146.00,
      client: 'Max (Jawitz)',
      jobStatus: JobListStatus.orderConfirmedNotPaid,
      jobType: JobType.flyersPrintingOnly,
      area: 'Contact at Webprinter, deliver to Jawitz,2000',
      quantity: 17,
      manDays: 2.5,
      date: DateTime(2025, 7, 1),
      collectionAddress: 'Webprinter',
      collectionDate: DateTime(2025, 7, 1),
      specialInstructions: '40m, 1 July - Deliver to Jawitz office on 1 July',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
    JobListItem(
      id: '',
      invoice: '2145',
      amount: 890.00,
      client: 'COLLECTION: Sunningdale',
      jobStatus: JobListStatus.jobUnderWay,
      jobType: JobType.junkCollection,
      area: '1 Sunny Side Road, Sunningdale',
      quantity: 1,
      manDays: 1.0,
      date: DateTime(2025, 7, 2),
      collectionAddress: '10:00 AM',
      collectionDate: DateTime(2025, 7, 2),
      specialInstructions: 'David 083 626 3025',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
    JobListItem(
      id: '',
      invoice: '8710',
      amount: 1074.20,
      client: 'Chand E2 for Day Leaflets',
      jobStatus: JobListStatus.jobDone,
      jobType: JobType.flyersAndPosters,
      area: 'Chand',
      quantity: 3,
      manDays: 1.5,
      date: DateTime(2025, 7, 10),
      collectionAddress: 'Chand',
      collectionDate: DateTime(2025, 7, 2),
      specialInstructions: '2 July',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
    JobListItem(
      id: '',
      invoice: '2147',
      amount: 1200.00,
      client: 'FURNITURE MOVE: Stellenbosch to Muizenberg',
      jobStatus: JobListStatus.reportCompliled,
      jobType: JobType.furnitureMove,
      area: '1 Skadu Road, Dalsig, Stellenbosch to 3 Hyndrd 4 July',
      quantity: 1,
      manDays: 2.0,
      date: DateTime(2025, 7, 4),
      collectionAddress: '9:30 in Stellenbosch Daniel 072 750 32',
      collectionDate: DateTime(2025, 7, 4),
      specialInstructions: 'Take plastic sheeting to cover the trailer',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
    JobListItem(
      id: '',
      invoice: '2148',
      amount: 900.00,
      client: 'COLLECTION: Otterstoer',
      jobStatus: JobListStatus.outstanding,
      jobType: JobType.junkCollection,
      area: '56 Lower Weldon Road, Otterstoer',
      quantity: 1,
      manDays: 0.5,
      date: DateTime(2025, 7, 5),
      collectionAddress: '2:00 PM',
      collectionDate: DateTime(2025, 7, 5),
      specialInstructions:
          'Cath 083 272 6533 - Sent Remedy - this will call back',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
    JobListItem(
      id: '',
      invoice: '8705',
      amount: 735.00,
      client: 'Anton Liebenberg (Staff)',
      jobStatus: JobListStatus.invoiceSent,
      jobType: JobType.flyerDistribution,
      area: 'Staff Constantia - before 5 July',
      quantity: 1000,
      manDays: 3.0,
      date: DateTime(2025, 7, 5),
      collectionAddress: 'Staff Constantia - before 5 July',
      collectionDate: DateTime(2025, 7, 5),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    ),
  ];

  // Add sample jobs to Firestore
  for (final job in sampleJobs) {
    try {
      await jobListService.addJobListItem(job);
    } catch (e) {
      print('Error adding job ${job.invoice}: $e');
    }
  }

  print('Sample job list data has been seeded successfully!');
}
