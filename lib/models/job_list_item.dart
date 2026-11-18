import 'package:cloud_firestore/cloud_firestore.dart';
import '../providers/job_type_provider.dart';
import 'company.dart';
import '../utils/appointment_slots.dart';
import '../utils/schedule_time.dart';
import 'job_list_item_update.dart';
import 'custom_polygon.dart';
import 'job_reminder.dart';
import 'happy_sun_shared.dart';
import 'collection_job.dart';
import 'job_invoice_link.dart';

/// Sentinel for [JobListItem.copyWith] so that `toolsNeeded` can be left
/// unchanged (default), explicitly updated, or cleared to `null`. Without it,
/// a nullable field cannot tell "not provided" apart from "set to null".
const Object _toolsNeededUnchanged = Object();

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

class JobListItem {
  final String id;
  final String invoice;
  final double amount;
  final String client;

  /// Who to ask for on the day and their number, for the drivers: the
  /// dropsheet's Contact and Tel. Typed on the Add/Edit Job form beside the
  /// client; there is no Job List column for them. Blank on older jobs, which
  /// fall back to a number typed on the end of the client name ([siteContact]).
  final String contactPerson;
  final String contactPhone;
  final String jobStatusId; // Changed from JobListStatus enum to String
  final String invoiceStatusId; // Invoice status (separate from job status)
  final String jobTypeId; // Changed from JobType enum to String
  final String area;
  final int quantity;
  final double manDays;
  final DateTime date;
  final String collectionAddress;
  final DateTime collectionDate;

  /// Community Life Media jobs: the flyers have to be collected before they
  /// can be distributed. Ticked on the Add Job form and in the Job List's
  /// "Flyer Col." column. Always written, so unticking reaches the server.
  final bool needsFlyerCollection;
  final String specialInstructions;
  final int quantityDistributed;
  final String invoiceDetails;
  final String reportAddresses;
  final String whoToInvoice;
  final String collectionJobId; // Link to collection schedule job
  final List<JobListItemUpdate> updates; // Track all changes
  final List<CustomPolygon> customPolygons; // Custom polygons for map areas
  final List<JobReminder> reminders; // List of reminders for invoice chase
  final CategorizedTools?
      toolsNeeded; // Tools needed for Happy Sun jobs (window/solar cleaning)
  final String shareableMapId; // Link to ShareableMap document

  /// The regular client plan (`regularClients/{id}`) this job was created
  /// from, or empty. Drives the schedule allocation preview on save.
  final String regularClientId;
  final String storageFolderPath; // Cloud Storage folder for tracks/waypoints
  final String
      vehicleTrailerCombo; // Vehicle+trailer enum name for collection jobs
  /// Offloading address for two-stop jobs (e.g. furniture moves, trailer towing).
  /// Only populated when the job type has `hasTwoStops = true`.
  final String offloadingAddress;

  /// Amount excluding VAT. For old records this defaults to [amount].
  final double amountExclVat;

  /// Amount including VAT. Zero means it was not explicitly stored (compute
  /// on the fly from [amountExclVat] using the current VAT percentage).
  final double amountInclVat;

  /// Whether the user entered the price as an incl-VAT figure.
  /// Old records default to false (all legacy prices were excl VAT).
  final bool priceIsInclVat;

  // ── Collection Schedule fields ─────────────────────────────────────────────
  // The Collection Schedule renders a derived `CollectionJob` view of this
  // record (see CollectionScheduleProvider). These four fields give that view
  // real storage. Before they existed the schedule squatted on unrelated
  // columns — duration on `quantityDistributed` (which is also the Job List's
  // "Qty Distributed" column), start time on the time component of `date`,
  // staff count on `manDays`, and staff names appended into
  // `specialInstructions`. Reads fall back to those legacy derivations so
  // existing documents keep rendering unchanged.

  /// Collection start time as "HH:MM". Empty means fall back to the time
  /// component of [date]. Authoritative once set — schedule writes keep the
  /// time component of [collectionDate] in sync with it.
  final String timeSlot;

  /// Duration in 30-minute slots. Zero means fall back to
  /// [quantityDistributed], then to 1.
  final int timeSlots;

  /// Staff assigned to the collection. Empty for legacy records, whose staff
  /// names were only ever written into [specialInstructions] as free text.
  final List<String> assignedStaff;

  /// Number of staff required. Zero means fall back to `manDays.ceil()`.
  final int staffCount;

  // ── Zoho Books links ───────────────────────────────────────────────────────
  // These mirror Zoho state; Zoho remains the source of truth. They are kept
  // separate from [invoice] and [invoiceStatusId] on purpose — those belong to
  // your own numbering and your user-defined `customInvoiceStatuses`, and are
  // never overwritten from Zoho.

  /// Zoho contact_id for this job's customer. Empty until invoiced or linked.
  final String zohoContactId;

  /// Zoho invoice_id, once an invoice has been raised for this job.
  final String zohoInvoiceId;

  /// The invoice number Zoho settled on — may differ from [invoice] if Zoho
  /// auto-numbering was left to assign it.
  final String zohoInvoiceNumber;

  /// Last known Zoho status wire value (draft/sent/overdue/paid/…).
  /// A cache for display; re-read from Zoho before acting on it.
  final String zohoInvoiceStatus;

  /// When [zohoInvoiceStatus] was last refreshed from Zoho.
  final DateTime? zohoSyncedAt;

  // ── Accounting links (provider-neutral) ────────────────────────────────────
  // The fields above are Zoho-specific and predate CLM invoicing through Xero.
  // Rather than bolt on a parallel set of `xero*` fields — which would make
  // every call site `hasZohoInvoice || hasXeroInvoice` forever — new writes go
  // here, and the `resolved*` getters fall back to the Zoho fields so historical
  // records keep rendering unchanged. Same pattern as
  // `CustomJobType.resolvedCompanyId`.
  //
  // The Zoho path still writes its own fields as well, so nothing is migrated
  // and nothing breaks. A backfill can retire them later.

  /// Which accounting provider raised this job's invoice — `zoho` or `xero`.
  /// Matches [AccountingProvider.name]. Empty on records written before this
  /// existed; use [resolvedInvoiceProviderId].
  final String invoiceProviderId;

  /// Provider contact id for this job's customer.
  final String accountingContactId;

  /// Provider invoice id, once an invoice has been raised.
  final String accountingInvoiceId;

  /// The invoice number the provider settled on — may differ from [invoice]
  /// when the provider auto-numbered it.
  final String accountingInvoiceNumber;

  /// Last known provider status wire value. Zoho's is lowercase
  /// (`draft`/`sent`/…), Xero's uppercase (`DRAFT`/`AUTHORISED`/…) — each
  /// provider's own enum parses it. A cache for display; re-read before acting.
  final String accountingInvoiceStatus;

  /// When [accountingInvoiceStatus] was last refreshed.
  final DateTime? accountingSyncedAt;

  /// Ids of void invoices that were unlinked from this job so it could be
  /// invoiced again (see `JobListService.unlinkVoidedInvoiceTxn`). History,
  /// and the revision counter in Xero idempotency keys — without it a re-issue
  /// would reuse the first invoice's key and get the voided invoice back.
  final List<String> voidedInvoiceIds;

  /// Extra invoices raised for this job when two or more clients split the
  /// bill. The primary invoice stays on the fields above; these are the rest.
  /// The job's money fields are the total across all of them.
  final List<JobInvoiceLink> splitInvoices;

  JobListItem({
    required this.id,
    required this.invoice,
    required this.amount,
    required this.client,
    this.contactPerson = '',
    this.contactPhone = '',
    required this.jobStatusId,
    this.invoiceStatusId = 'pending', // Default to pending invoice status
    required this.jobTypeId,
    required this.area,
    required this.quantity,
    required this.manDays,
    required this.date,
    required this.collectionAddress,
    required this.collectionDate,
    this.needsFlyerCollection = false,
    required this.specialInstructions,
    required this.quantityDistributed,
    required this.invoiceDetails,
    required this.reportAddresses,
    required this.whoToInvoice,
    this.collectionJobId = '', // Optional link to collection job
    this.updates = const [], // Default to empty list
    this.customPolygons = const [], // Default to empty list
    this.reminders = const [], // Default to empty list
    this.toolsNeeded, // Optional tools for Happy Sun jobs
    this.shareableMapId = '', // Optional link to shareable map
    this.regularClientId = '',
    this.storageFolderPath = '', // Optional cloud storage folder path
    this.vehicleTrailerCombo =
        '', // Optional vehicle+trailer combo for collection jobs
    this.offloadingAddress = '',
    this.amountExclVat = 0.0,
    this.amountInclVat = 0.0,
    this.priceIsInclVat = false,
    this.timeSlot = '', // Falls back to the time component of `date`
    this.timeSlots = 0, // Falls back to quantityDistributed, then 1
    this.assignedStaff = const [],
    this.staffCount = 0, // Falls back to manDays.ceil()
    this.zohoContactId = '',
    this.zohoInvoiceId = '',
    this.zohoInvoiceNumber = '',
    this.zohoInvoiceStatus = '',
    this.zohoSyncedAt,
    this.invoiceProviderId = '',
    this.accountingContactId = '',
    this.accountingInvoiceId = '',
    this.accountingInvoiceNumber = '',
    this.accountingInvoiceStatus = '',
    this.accountingSyncedAt,
    this.voidedInvoiceIds = const [],
    this.splitInvoices = const [],
  });

  /// Whether an invoice has been raised in Zoho for this job.
  bool get hasZohoInvoice => zohoInvoiceId.isNotEmpty;

  /// Who the driver asks for and the number to ring — the dropsheet's
  /// Contact and Tel. The contact person and phone when they are filled in;
  /// otherwise the client, with a number typed on the end of the name split
  /// off (the old way: "Mrs Smith 082 123 4567").
  ({String contact, String tel}) get siteContact {
    final fromClient = splitClientPhone(client);
    final person = contactPerson.trim();
    final phone = contactPhone.trim();
    return (
      contact: person.isNotEmpty ? person : fromClient.contact,
      tel: phone.isNotEmpty ? phone : fromClient.tel,
    );
  }

  /// What is wrong with [value] as a contact phone, or null when it is fine.
  /// Blank is fine (the number is optional); fewer than 9 digits cannot be
  /// dialled — a typo the driver would only find out about on the road.
  static String? contactPhoneProblem(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    if (digits.length < 9) return 'Too short for a phone number';
    return null;
  }

  /// [client] as a name and a South African number typed on its end:
  /// "Mrs Smith 082 123 4567" → ("Mrs Smith", "082 123 4567"). No number
  /// leaves the whole text as the name.
  static ({String contact, String tel}) splitClientPhone(String client) {
    final trimmed = client.trim();
    if (trimmed.isEmpty) return (contact: '', tel: '');
    final phoneMatch =
        RegExp(r'(?:\+?27|0)[0-9\s()\-]{8,}$').firstMatch(trimmed);
    if (phoneMatch == null) return (contact: trimmed, tel: '');
    final tel = phoneMatch.group(0)!.trim();
    final contact = trimmed.substring(0, phoneMatch.start).trim();
    return (contact: contact.isEmpty ? trimmed : contact, tel: tel);
  }

  /// Whether this is a Community Life Media job — the jobs that can need
  /// their flyers collected ([needsFlyerCollection]).
  bool get isCommunityLifeMediaJob => isCommunityLifeMediaJobType(jobTypeId);

  /// Whether job type [jobTypeId] belongs to Community Life Media. False
  /// while the job types have not loaded.
  static bool isCommunityLifeMediaJobType(String jobTypeId) =>
      JobTypeProvider.instance?.getJobTypeById(jobTypeId)?.resolvedCompanyId ==
      Company.clmId;

  // ── Provider-neutral reads ─────────────────────────────────────────────────
  // Always read invoice links through these. A job invoiced before the neutral
  // fields existed has only the `zoho*` ones, and reading those directly would
  // make every Xero-aware widget blind to Zoho history.

  /// `zoho`, `xero`, or empty when this job has no invoice.
  String get resolvedInvoiceProviderId {
    if (invoiceProviderId.isNotEmpty) return invoiceProviderId;
    return zohoInvoiceId.isNotEmpty ? 'zoho' : '';
  }

  String get resolvedContactId =>
      accountingContactId.isNotEmpty ? accountingContactId : zohoContactId;

  String get resolvedInvoiceId =>
      accountingInvoiceId.isNotEmpty ? accountingInvoiceId : zohoInvoiceId;

  String get resolvedInvoiceNumber => accountingInvoiceNumber.isNotEmpty
      ? accountingInvoiceNumber
      : zohoInvoiceNumber;

  String get resolvedInvoiceStatus => accountingInvoiceStatus.isNotEmpty
      ? accountingInvoiceStatus
      : zohoInvoiceStatus;

  DateTime? get resolvedSyncedAt => accountingSyncedAt ?? zohoSyncedAt;

  /// Whether an invoice has been raised for this job with any provider.
  bool get hasAccountingInvoice => resolvedInvoiceId.isNotEmpty;

  /// Whether this job's bill is split across more than one invoice.
  bool get hasSplitInvoices => splitInvoices.isNotEmpty;

  /// Every invoice linked to this job, primary first.
  ///
  /// The primary's [JobInvoiceLink.subTotal] / [JobInvoiceLink.total] are its
  /// share of the job's money fields — the job total less the split invoices —
  /// since the primary's own figures are not stored separately.
  List<JobInvoiceLink> get allInvoices {
    if (!hasAccountingInvoice) return splitInvoices;
    final splitSub = splitInvoices.fold<double>(0, (r, i) => r + i.subTotal);
    final splitTotal = splitInvoices.fold<double>(0, (r, i) => r + i.total);
    final incl = amountInclVat > 0 ? amountInclVat : amountExclVat;
    return [
      JobInvoiceLink(
        providerId: resolvedInvoiceProviderId,
        contactId: resolvedContactId,
        invoiceId: resolvedInvoiceId,
        invoiceNumber: resolvedInvoiceNumber,
        status: resolvedInvoiceStatus,
        subTotal: amountExclVat - splitSub,
        total: incl - splitTotal,
        syncedAt: resolvedSyncedAt,
        isPrimary: true,
      ),
      ...splitInvoices,
    ];
  }

  /// Every invoice number on this job, for display — the primary's (or the
  /// hand-typed [invoice] when nothing is linked) followed by the splits.
  List<String> get allInvoiceNumbers {
    final primary =
        resolvedInvoiceNumber.isNotEmpty ? resolvedInvoiceNumber : invoice;
    return [
      if (primary.isNotEmpty) primary,
      for (final s in splitInvoices)
        if (s.invoiceNumber.isNotEmpty) s.invoiceNumber,
    ];
  }

  /// This job with its invoice link removed, for a void invoice that has just
  /// been unlinked. The money fields stay — they are the job's price, not the
  /// invoice's. The sync timestamps cannot be nulled through [copyWith] and
  /// are left; without an invoice id nothing reads them.
  JobListItem withoutInvoiceLink() {
    final unlinkedId = resolvedInvoiceId;
    return copyWith(
      invoice: invoice == resolvedInvoiceNumber ? '' : invoice,
      zohoContactId: '',
      zohoInvoiceId: '',
      zohoInvoiceNumber: '',
      zohoInvoiceStatus: '',
      invoiceProviderId: '',
      accountingContactId: '',
      accountingInvoiceId: '',
      accountingInvoiceNumber: '',
      accountingInvoiceStatus: '',
      voidedInvoiceIds: [
        ...voidedInvoiceIds,
        if (unlinkedId.isNotEmpty && !voidedInvoiceIds.contains(unlinkedId))
          unlinkedId,
      ],
    );
  }

  /// Carry across every field that the Add/Edit Job form does not render.
  ///
  /// The form rebuilds a [JobListItem] from its controllers, so anything it
  /// has no input for would come back empty. That is **not** cosmetic:
  /// `JobListService.moveJobListItemToMonth` recreates the document with
  /// `batch.set(..., toMap())` and deletes the original, so a field missing
  /// here is destroyed the moment a job's date moves to another month. A
  /// same-month save survives only because `.update()` ignores keys that
  /// `toMap()` omits — an accident, not a safety net.
  ///
  /// Passing null (a brand-new job) leaves everything at its defaults. On a
  /// copy the caller has already blanked the Zoho identifiers on [source], so
  /// preserving from it is still correct.
  ///
  /// **Add every new non-form field here**, or it will silently vanish on the
  /// next month move.
  JobListItem withPreservedSystemFields(JobListItem? source) {
    if (source == null) return this;
    return copyWith(
      shareableMapId: source.shareableMapId,
      storageFolderPath: source.storageFolderPath,
      timeSlot: source.timeSlot,
      timeSlots: source.timeSlots,
      assignedStaff: source.assignedStaff,
      staffCount: source.staffCount,
      zohoContactId: source.zohoContactId,
      zohoInvoiceId: source.zohoInvoiceId,
      zohoInvoiceNumber: source.zohoInvoiceNumber,
      zohoInvoiceStatus: source.zohoInvoiceStatus,
      zohoSyncedAt: source.zohoSyncedAt,
      invoiceProviderId: source.invoiceProviderId,
      accountingContactId: source.accountingContactId,
      accountingInvoiceId: source.accountingInvoiceId,
      accountingInvoiceNumber: source.accountingInvoiceNumber,
      accountingInvoiceStatus: source.accountingInvoiceStatus,
      accountingSyncedAt: source.accountingSyncedAt,
      voidedInvoiceIds: source.voidedInvoiceIds,
      splitInvoices: source.splitInvoices,
    );
  }

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
          .map((updateData) => JobListItemUpdate.fromMap(
              Map<String, dynamic>.from(updateData as Map)))
          .toList();
    }

    // Parse custom polygons
    List<CustomPolygon> customPolygons = [];
    if (data['customPolygons'] != null) {
      final polygonsData = data['customPolygons'] as List<dynamic>;
      customPolygons = polygonsData
          .map((polygonData) => CustomPolygon.fromMap(
              Map<String, dynamic>.from(polygonData as Map)))
          .toList();
    }

    // Parse reminders
    List<JobReminder> reminders = [];
    if (data['reminders'] != null) {
      final remindersData = data['reminders'] as List<dynamic>;
      reminders = remindersData
          .map((reminderData) => JobReminder.fromMap(
              Map<String, dynamic>.from(reminderData as Map)))
          .toList();
    }

    return JobListItem(
      id: id,
      invoice: data['invoice'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
      client: data['client'] as String? ?? '',
      contactPerson: data['contactPerson'] as String? ?? '',
      contactPhone: data['contactPhone'] as String? ?? '',
      jobStatusId: jobStatusId,
      invoiceStatusId: invoiceStatusId,
      jobTypeId: data['jobType'] as String? ?? 'flyersPrintingOnly',
      area: data['area'] as String? ?? '',
      quantity: (data['quantity'] as num?)?.toInt() ?? 0,
      manDays: (data['manDays'] as num?)?.toDouble() ?? 0.0,
      date: data['date'] != null
          ? toScheduleCivil((data['date'] as Timestamp).toDate())
          : scheduleToday(),
      collectionAddress: data['collectionAddress'] as String? ?? '',
      collectionDate: data['collectionDate'] != null
          ? toScheduleCivil((data['collectionDate'] as Timestamp).toDate())
          : scheduleToday(),
      needsFlyerCollection: data['needsFlyerCollection'] as bool? ?? false,
      specialInstructions: data['specialInstructions'] as String? ?? '',
      quantityDistributed: (data['quantityDistributed'] as num?)?.toInt() ?? 0,
      invoiceDetails: data['invoiceDetails'] as String? ?? '',
      reportAddresses: data['reportAddresses'] as String? ?? '',
      whoToInvoice: data['whoToInvoice'] as String? ?? '',
      collectionJobId: data['collectionJobId'] as String? ?? '',
      updates: updates,
      customPolygons: customPolygons,
      reminders: reminders,
      toolsNeeded: data['toolsNeeded'] != null
          ? CategorizedTools.fromMap(
              Map<String, dynamic>.from(data['toolsNeeded'] as Map))
          : null,
      shareableMapId: data['shareableMapId'] as String? ?? '',
      regularClientId: data['regularClientId'] as String? ?? '',
      storageFolderPath: data['storageFolderPath'] as String? ?? '',
      vehicleTrailerCombo: _resolveVehicleTrailerCombo(
        data['vehicleTrailerCombo'] as String?,
        (data['quantity'] as num?)?.toInt() ?? 0,
        data['jobType'] as String? ?? '',
      ),
      offloadingAddress: data['offloadingAddress'] as String? ?? '',
      // Old records had no VAT fields — amount was always excl VAT.
      priceIsInclVat: data['priceIsInclVat'] as bool? ?? false,
      amountExclVat: (data['amountExclVat'] as num?)?.toDouble() ??
          (data['amount'] as num?)?.toDouble() ??
          0.0,
      amountInclVat: (data['amountInclVat'] as num?)?.toDouble() ?? 0.0,
      timeSlot: data['timeSlot'] as String? ?? '',
      timeSlots: (data['timeSlots'] as num?)?.toInt() ?? 0,
      assignedStaff:
          (data['assignedStaff'] as List<dynamic>?)?.cast<String>() ?? const [],
      staffCount: (data['staffCount'] as num?)?.toInt() ?? 0,
      zohoContactId: data['zohoContactId'] as String? ?? '',
      zohoInvoiceId: data['zohoInvoiceId'] as String? ?? '',
      zohoInvoiceNumber: data['zohoInvoiceNumber'] as String? ?? '',
      zohoInvoiceStatus: data['zohoInvoiceStatus'] as String? ?? '',
      invoiceProviderId: data['invoiceProviderId'] as String? ?? '',
      accountingContactId: data['accountingContactId'] as String? ?? '',
      accountingInvoiceId: data['accountingInvoiceId'] as String? ?? '',
      accountingInvoiceNumber:
          data['accountingInvoiceNumber'] as String? ?? '',
      accountingInvoiceStatus:
          data['accountingInvoiceStatus'] as String? ?? '',
      accountingSyncedAt: data['accountingSyncedAt'] != null
          ? (data['accountingSyncedAt'] as Timestamp).toDate()
          : null,
      zohoSyncedAt: data['zohoSyncedAt'] != null
          ? (data['zohoSyncedAt'] as Timestamp).toDate()
          : null,
      voidedInvoiceIds:
          (data['voidedInvoiceIds'] as List<dynamic>?)?.cast<String>() ??
              const [],
      splitInvoices: (data['splitInvoices'] as List<dynamic>?)
              ?.map((e) =>
                  JobInvoiceLink.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
    );
  }

  /// An appointment's start as "HH:MM" ("00:00" when none is booked): the
  /// time on [date] when it has one, else [timeSlot].
  ///
  /// Every save from this version writes the two together
  /// ([withAppointment], the Collection Schedule), so they only differ on
  /// jobs saved before. There [date]'s time is always the newer one: older
  /// versions of Add/Edit Job and the Job List's Date cell changed [date]
  /// and left [timeSlot] behind. A midnight [date] means it carries no time
  /// (jobs added on the Collection Schedule), so [timeSlot] is the booking.
  /// The Collection Schedule, the dropsheet and Add/Edit Job all read this,
  /// so they show the same time.
  String get resolvedTimeSlot {
    if (date.hour != 0 || date.minute != 0) {
      return '${date.hour.toString().padLeft(2, '0')}:'
          '${date.minute.toString().padLeft(2, '0')}';
    }
    if (timeSlot.isNotEmpty) return timeSlot;
    return '00:00';
  }

  /// Whether [collectionDate] is a real date: 1 Jan 2000 means "none".
  bool get hasCollectionDate => !(collectionDate.year == 2000 &&
      collectionDate.month == 1 &&
      collectionDate.day == 1);

  /// Duration in 30-minute slots, falling back to the legacy
  /// [quantityDistributed] overload, then to a single slot.
  int get resolvedTimeSlots {
    if (timeSlots >= 1) return timeSlots;
    if (quantityDistributed > 0) return quantityDistributed;
    return 1;
  }

  /// The booked time slot, "10:00–11:30"; empty when no time is booked
  /// (midnight).
  String get timeSlotRangeDisplay {
    final start = resolvedTimeSlot;
    if (start == '00:00') return '';
    return slotRange(start, resolvedTimeSlots);
  }

  /// This appointment booked on [at]'s day from [at]'s time, for [slots]
  /// half-hours (unchanged when null).
  ///
  /// The Collection Schedule reads the day from a real [collectionDate]
  /// before [date], and older versions read the start from [timeSlot]
  /// before [date], so a booking that only changed [date] would not move
  /// there. This keeps all of them in step. [onCollectionSchedule] says whether the job shows there — only
  /// then is [collectionDate] the booking (for other types it is the user's
  /// own field). [moveCollectionDay] false keeps a real collectionDate's day
  /// (the booking was moved on that schedule and only its time changed here).
  /// A midnight [at] books no time: only the day moves.
  JobListItem withAppointment(
    DateTime at, {
    int? slots,
    required bool onCollectionSchedule,
    bool moveCollectionDay = true,
  }) {
    final hasTime = at.hour != 0 || at.minute != 0;
    var nextCollectionDate = collectionDate;
    if (onCollectionSchedule && hasCollectionDate) {
      final day = moveCollectionDay ? at : collectionDate;
      final time = hasTime ? at : collectionDate;
      nextCollectionDate =
          DateTime(day.year, day.month, day.day, time.hour, time.minute);
    }
    return copyWith(
      date: at,
      timeSlot: hasTime ? slotTime(at.hour * 60 + at.minute) : null,
      timeSlots: slots,
      collectionDate: nextCollectionDate,
    );
  }

  /// Staff required, falling back to the legacy `manDays.ceil()` derivation.
  int get resolvedStaffCount {
    if (staffCount > 0) return staffCount;
    return manDays.ceil();
  }

  /// Resolve vehicleTrailerCombo from Firestore data with legacy quantity fallback.
  static String _resolveVehicleTrailerCombo(
      String? stored, int quantity, String jobTypeId) {
    // If new field exists and is valid, use it
    if (stored != null &&
        stored.isNotEmpty &&
        VehicleTrailerCombo.tryParse(stored) != null) {
      return stored;
    }
    // Fall back to converting from legacy quantity for vehicle job types
    if (VehicleTrailerCombo.isVehicleJobType(jobTypeId) && quantity >= 1) {
      return VehicleTrailerCombo.fromLegacyQuantity(quantity,
                  jobTypeId: jobTypeId)
              ?.name ??
          '';
    }
    return '';
  }

  // Convert to Firestore
  Map<String, dynamic> toMap() {
    return {
      'invoice': invoice,
      'amount': amount,
      'client': client,
      // Always written, blank included: Job List edits use update(), so a
      // cleared contact would otherwise never reach the server.
      'contactPerson': contactPerson,
      'contactPhone': contactPhone,
      'jobStatusId': jobStatusId, // Changed from jobStatus.name to jobStatusId
      'invoiceStatusId': invoiceStatusId,
      'jobType': jobTypeId,
      'area': area,
      'quantity': quantity,
      'manDays': manDays,
      'date': Timestamp.fromDate(scheduleCivilToInstant(date)),
      'collectionAddress': collectionAddress,
      'collectionDate':
          Timestamp.fromDate(scheduleCivilToInstant(collectionDate)),
      'needsFlyerCollection': needsFlyerCollection,
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
      if (toolsNeeded != null) 'toolsNeeded': toolsNeeded!.toMap(),
      if (shareableMapId.isNotEmpty) 'shareableMapId': shareableMapId,
      'regularClientId': regularClientId,
      if (storageFolderPath.isNotEmpty) 'storageFolderPath': storageFolderPath,
      if (vehicleTrailerCombo.isNotEmpty)
        'vehicleTrailerCombo': vehicleTrailerCombo,
      if (offloadingAddress.isNotEmpty) 'offloadingAddress': offloadingAddress,
      'priceIsInclVat': priceIsInclVat,
      'amountExclVat': amountExclVat,
      'amountInclVat': amountInclVat,
      // Collection Schedule fields are written only when set, so records that
      // never touch the schedule stay unchanged.
      if (timeSlot.isNotEmpty) 'timeSlot': timeSlot,
      if (timeSlots > 0) 'timeSlots': timeSlots,
      if (assignedStaff.isNotEmpty) 'assignedStaff': assignedStaff,
      if (staffCount > 0) 'staffCount': staffCount,
      // Zoho links — written only once a job is actually linked to Zoho.
      if (zohoContactId.isNotEmpty) 'zohoContactId': zohoContactId,
      if (zohoInvoiceId.isNotEmpty) 'zohoInvoiceId': zohoInvoiceId,
      if (zohoInvoiceNumber.isNotEmpty) 'zohoInvoiceNumber': zohoInvoiceNumber,
      if (zohoInvoiceStatus.isNotEmpty) 'zohoInvoiceStatus': zohoInvoiceStatus,
      if (zohoSyncedAt != null)
        'zohoSyncedAt': Timestamp.fromDate(zohoSyncedAt!),
      // Provider-neutral links — written only once a job is actually invoiced.
      if (invoiceProviderId.isNotEmpty) 'invoiceProviderId': invoiceProviderId,
      if (accountingContactId.isNotEmpty)
        'accountingContactId': accountingContactId,
      if (accountingInvoiceId.isNotEmpty)
        'accountingInvoiceId': accountingInvoiceId,
      if (accountingInvoiceNumber.isNotEmpty)
        'accountingInvoiceNumber': accountingInvoiceNumber,
      if (accountingInvoiceStatus.isNotEmpty)
        'accountingInvoiceStatus': accountingInvoiceStatus,
      if (accountingSyncedAt != null)
        'accountingSyncedAt': Timestamp.fromDate(accountingSyncedAt!),
      if (voidedInvoiceIds.isNotEmpty) 'voidedInvoiceIds': voidedInvoiceIds,
      if (splitInvoices.isNotEmpty)
        'splitInvoices': splitInvoices.map((i) => i.toMap()).toList(),
    };
  }

  // Create a copy with some fields updated
  JobListItem copyWith({
    String? id,
    String? invoice,
    double? amount,
    String? client,
    String? contactPerson,
    String? contactPhone,
    String?
        jobStatusId, // Changed from JobListStatus? jobStatus to String? jobStatusId
    String? invoiceStatusId,
    String? jobTypeId,
    String? area,
    int? quantity,
    double? manDays,
    DateTime? date,
    String? collectionAddress,
    DateTime? collectionDate,
    bool? needsFlyerCollection,
    String? specialInstructions,
    int? quantityDistributed,
    String? invoiceDetails,
    String? reportAddresses,
    String? whoToInvoice,
    String? collectionJobId,
    List<JobListItemUpdate>? updates,
    List<CustomPolygon>? customPolygons,
    List<JobReminder>? reminders,
    String? shareableMapId,
    String? regularClientId,
    String? storageFolderPath,
    String? vehicleTrailerCombo,
    String? offloadingAddress,
    Object? toolsNeeded = _toolsNeededUnchanged,
    double? amountExclVat,
    double? amountInclVat,
    bool? priceIsInclVat,
    String? timeSlot,
    int? timeSlots,
    List<String>? assignedStaff,
    int? staffCount,
    String? zohoContactId,
    String? zohoInvoiceId,
    String? zohoInvoiceNumber,
    String? zohoInvoiceStatus,
    DateTime? zohoSyncedAt,
    String? invoiceProviderId,
    String? accountingContactId,
    String? accountingInvoiceId,
    String? accountingInvoiceNumber,
    String? accountingInvoiceStatus,
    DateTime? accountingSyncedAt,
    List<String>? voidedInvoiceIds,
    List<JobInvoiceLink>? splitInvoices,
  }) {
    return JobListItem(
      id: id ?? this.id,
      invoice: invoice ?? this.invoice,
      amount: amount ?? this.amount,
      client: client ?? this.client,
      contactPerson: contactPerson ?? this.contactPerson,
      contactPhone: contactPhone ?? this.contactPhone,
      jobStatusId: jobStatusId ?? this.jobStatusId,
      invoiceStatusId: invoiceStatusId ?? this.invoiceStatusId,
      jobTypeId: jobTypeId ?? this.jobTypeId,
      area: area ?? this.area,
      quantity: quantity ?? this.quantity,
      manDays: manDays ?? this.manDays,
      date: date ?? this.date,
      collectionAddress: collectionAddress ?? this.collectionAddress,
      collectionDate: collectionDate ?? this.collectionDate,
      needsFlyerCollection: needsFlyerCollection ?? this.needsFlyerCollection,
      specialInstructions: specialInstructions ?? this.specialInstructions,
      quantityDistributed: quantityDistributed ?? this.quantityDistributed,
      invoiceDetails: invoiceDetails ?? this.invoiceDetails,
      reportAddresses: reportAddresses ?? this.reportAddresses,
      whoToInvoice: whoToInvoice ?? this.whoToInvoice,
      collectionJobId: collectionJobId ?? this.collectionJobId,
      updates: updates ?? this.updates,
      customPolygons: customPolygons ?? this.customPolygons,
      reminders: reminders ?? this.reminders,
      shareableMapId: shareableMapId ?? this.shareableMapId,
      regularClientId: regularClientId ?? this.regularClientId,
      storageFolderPath: storageFolderPath ?? this.storageFolderPath,
      vehicleTrailerCombo: vehicleTrailerCombo ?? this.vehicleTrailerCombo,
      offloadingAddress: offloadingAddress ?? this.offloadingAddress,
      toolsNeeded: identical(toolsNeeded, _toolsNeededUnchanged)
          ? this.toolsNeeded
          : toolsNeeded as CategorizedTools?,
      amountExclVat: amountExclVat ?? this.amountExclVat,
      amountInclVat: amountInclVat ?? this.amountInclVat,
      priceIsInclVat: priceIsInclVat ?? this.priceIsInclVat,
      timeSlot: timeSlot ?? this.timeSlot,
      timeSlots: timeSlots ?? this.timeSlots,
      assignedStaff: assignedStaff ?? this.assignedStaff,
      staffCount: staffCount ?? this.staffCount,
      zohoContactId: zohoContactId ?? this.zohoContactId,
      zohoInvoiceId: zohoInvoiceId ?? this.zohoInvoiceId,
      zohoInvoiceNumber: zohoInvoiceNumber ?? this.zohoInvoiceNumber,
      zohoInvoiceStatus: zohoInvoiceStatus ?? this.zohoInvoiceStatus,
      zohoSyncedAt: zohoSyncedAt ?? this.zohoSyncedAt,
      invoiceProviderId: invoiceProviderId ?? this.invoiceProviderId,
      accountingContactId: accountingContactId ?? this.accountingContactId,
      accountingInvoiceId: accountingInvoiceId ?? this.accountingInvoiceId,
      accountingInvoiceNumber:
          accountingInvoiceNumber ?? this.accountingInvoiceNumber,
      accountingInvoiceStatus:
          accountingInvoiceStatus ?? this.accountingInvoiceStatus,
      accountingSyncedAt: accountingSyncedAt ?? this.accountingSyncedAt,
      voidedInvoiceIds: voidedInvoiceIds ?? this.voidedInvoiceIds,
      splitInvoices: splitInvoices ?? this.splitInvoices,
    );
  }

  // Create a copy with a tracked change
  JobListItem copyWithTrackedChange({
    required String userId,
    required String userDisplayName,
    String? invoice,
    double? amount,
    String? client,
    String? contactPerson,
    String? contactPhone,
    String? jobStatusId,
    String? invoiceStatusId,
    String? jobTypeId,
    String? area,
    int? quantity,
    double? manDays,
    DateTime? date,
    String? collectionAddress,
    DateTime? collectionDate,
    bool? needsFlyerCollection,
    String? timeSlot,
    int? timeSlots,
    String? specialInstructions,
    int? quantityDistributed,
    String? invoiceDetails,
    String? reportAddresses,
    String? whoToInvoice,
    String? collectionJobId,
    List<CustomPolygon>? customPolygons,
    List<JobReminder>? reminders,
    String? vehicleTrailerCombo,
    // Helper functions to resolve display labels
    String? Function(String statusId)? resolveJobStatusLabel,
    String? Function(String statusId)? resolveInvoiceStatusLabel,
    String? Function(int quantity, String jobTypeId)? resolveQuantityLabel,
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

    if (contactPerson != null && contactPerson != this.contactPerson) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'contactPerson',
        oldValue: this.contactPerson,
        newValue: contactPerson,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
      ));
    }

    if (contactPhone != null && contactPhone != this.contactPhone) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'contactPhone',
        oldValue: this.contactPhone,
        newValue: contactPhone,
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

    if (jobTypeId != null && jobTypeId != this.jobTypeId) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'jobType',
        oldValue: this.jobTypeId,
        newValue: jobTypeId,
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
        oldValueDisplay: resolveQuantityLabel?.call(
            this.quantity, jobTypeId ?? this.jobTypeId),
        newValueDisplay:
            resolveQuantityLabel?.call(quantity, jobTypeId ?? this.jobTypeId),
      ));
    }

    if (vehicleTrailerCombo != null &&
        vehicleTrailerCombo != this.vehicleTrailerCombo) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'vehicleTrailerCombo',
        oldValue: this.vehicleTrailerCombo,
        newValue: vehicleTrailerCombo,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay:
            VehicleTrailerCombo.tryParse(this.vehicleTrailerCombo)?.label,
        newValueDisplay:
            VehicleTrailerCombo.tryParse(vehicleTrailerCombo)?.label,
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

    if (needsFlyerCollection != null &&
        needsFlyerCollection != this.needsFlyerCollection) {
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'needsFlyerCollection',
        oldValue: this.needsFlyerCollection,
        newValue: needsFlyerCollection,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay: this.needsFlyerCollection ? 'Yes' : 'No',
        newValueDisplay: needsFlyerCollection ? 'Yes' : 'No',
      ));
    }

    // Start and length are one booking: one history line, "10:00–11:00" →
    // "14:00–15:30".
    if ((timeSlot != null && timeSlot != this.timeSlot) ||
        (timeSlots != null && timeSlots != this.timeSlots)) {
      // With the new date: its time is the start (see [resolvedTimeSlot]).
      final next =
          copyWith(date: date, timeSlot: timeSlot, timeSlots: timeSlots);
      newUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'timeSlot',
        oldValue: timeSlotRangeDisplay,
        newValue: next.timeSlotRangeDisplay,
        timestamp: DateTime.now(),
        userDisplayName: userDisplayName,
        oldValueDisplay:
            timeSlotRangeDisplay.isEmpty ? 'None' : timeSlotRangeDisplay,
        newValueDisplay: next.timeSlotRangeDisplay.isEmpty
            ? 'None'
            : next.timeSlotRangeDisplay,
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
      contactPerson: contactPerson,
      contactPhone: contactPhone,
      jobStatusId: jobStatusId,
      invoiceStatusId: invoiceStatusId,
      jobTypeId: jobTypeId,
      area: area,
      quantity: quantity,
      manDays: manDays,
      date: date,
      collectionAddress: collectionAddress,
      collectionDate: collectionDate,
      needsFlyerCollection: needsFlyerCollection,
      timeSlot: timeSlot,
      timeSlots: timeSlots,
      specialInstructions: specialInstructions,
      quantityDistributed: quantityDistributed,
      invoiceDetails: invoiceDetails,
      reportAddresses: reportAddresses,
      whoToInvoice: whoToInvoice,
      collectionJobId: collectionJobId,
      updates: newUpdates,
      customPolygons: customPolygons,
      reminders: reminders ?? this.reminders,
      vehicleTrailerCombo: vehicleTrailerCombo,
    );
  }

  /// Compute the excl-VAT amount given a VAT percentage.
  double computedExclVat(double vatPercent) {
    if (amountExclVat > 0) return amountExclVat;
    return amount; // backward compat — old records are excl VAT
  }

  /// Compute the incl-VAT amount given a VAT percentage.
  double computedInclVat(double vatPercent) {
    if (amountInclVat > 0) return amountInclVat;
    final excl = computedExclVat(vatPercent);
    return excl * (1 + vatPercent / 100);
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

  // Helper method to check if job type needs time display.
  // Resolved via the [JobTypeProvider] static instance so we stay fully
  // data-driven and never hardcode job-type ids here.
  bool _needsTimeDisplay() {
    final provider = JobTypeProvider.instance;
    if (provider == null) return false;
    return provider.needsTimeSlot(jobTypeId);
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
