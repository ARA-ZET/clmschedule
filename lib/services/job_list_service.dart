import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/job_invoice_link.dart';
import '../models/job_list_item.dart';
import '../utils/job_lifecycle_rules.dart';
import 'monthly_service.dart';

final jobListServiceRiverpod = riverpod.Provider<JobListService>(
  (ref) => JobListService(FirebaseFirestore.instance),
);

class JobListService {
  final MonthlyService _monthlyService;
  final FirebaseFirestore _firestore;

  JobListService(FirebaseFirestore firestore)
      : _firestore = firestore,
        _monthlyService = MonthlyService(firestore);

  // Get collection reference for a specific date
  CollectionReference _getJobListItemsCollection(DateTime date) {
    return _monthlyService.getJobListItemsCollection(date);
  }

  /// Public accessor used by duplicate-client checks that target a month
  /// that may not be currently loaded into memory.
  CollectionReference getJobListItemsCollectionForMonth(DateTime date) {
    return _monthlyService.getJobListItemsCollection(date);
  }

  // Get all job list items for current month
  // Optional jobTypes parameter to filter by specific job types at Firebase level
  Stream<List<JobListItem>> getJobListItems(
      [DateTime? date, List<String>? jobTypes]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    // Build query
    Query query = _getJobListItemsCollection(targetDate);

    // Add jobType filter if specified (Firebase-level filtering)
    if (jobTypes != null && jobTypes.isNotEmpty) {
      // Use the string values directly for Firebase query
      final jobTypeStrings = jobTypes;
      query = query.where('jobType', whereIn: jobTypeStrings);
      // Note: Combining whereIn with orderBy requires a composite index in Firebase
      // For now, skip orderBy when filtering to avoid index requirement
      // TODO: Create composite index for (jobType, date) in Firebase Console
    } else {
      // Only apply orderBy when not filtering (avoids index requirement)
      query = query.orderBy('date', descending: true);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }).toList();
    });
  }

  // Add a new job list item
  Future<String> addJobListItem(JobListItem jobListItem,
      [DateTime? date]) async {
    final targetDate = date ?? jobListItem.date;

    // Ensure monthly document exists
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    final docRef =
        await _getJobListItemsCollection(targetDate).add(jobListItem.toMap());
    return docRef.id;
  }

  // Update a job list item
  Future<void> updateJobListItem(JobListItem jobListItem,
      [DateTime? date]) async {
    final targetDate = date ?? jobListItem.date;

    // Ensure monthly document exists before updating
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    // `storageFolderPath` is owned by the `onJobListItemWritten` Cloud
    // Function, which moves the folder when the client or month changes and
    // writes the new path back. Sending the locally cached copy here would
    // put the old path back after a move, and the next edit would then
    // "move" a folder that is no longer there.
    final data = jobListItem.toMap()..remove('storageFolderPath');
    await _getJobListItemsCollection(targetDate)
        .doc(jobListItem.id)
        .update(data);
  }

  /// Write only [fields] on a job, leaving every other field as it is.
  ///
  /// For link changes (`shareableMapId`, `area`) made outside the editing
  /// flow, where rebuilding the whole item from a local copy would reset any
  /// field that copy did not carry.
  Future<void> updateJobListItemFields(
      String jobId, DateTime date, Map<String, dynamic> fields) async {
    await _getJobListItemsCollection(date).doc(jobId).update(fields);
  }

  /// Stamp the Zoho Books invoice link onto a job, transactionally.
  ///
  /// Read-modify-write inside a Firestore transaction so a concurrent edit to
  /// the same job (someone changing the status or address while the invoice is
  /// being raised) is not clobbered — only the fields listed here are touched.
  /// Mirrors the discipline in [PayrollService].
  ///
  /// Note this is the Firestore half of a saga, not a distributed transaction:
  /// the Zoho invoice already exists by the time this runs, so a failure here
  /// leaves a valid invoice that simply is not linked yet, and is safe to
  /// retry.
  Future<void> linkZohoInvoiceTxn({
    required String jobId,
    required DateTime date,
    required String zohoContactId,
    required String zohoInvoiceId,
    required String zohoInvoiceNumber,
    required String zohoInvoiceStatus,

    /// The job's own invoice number — set when Zoho auto-numbered, so the Job
    /// List column matches the issued invoice. Null leaves it untouched.
    String? invoiceNumber,

    /// The invoiced total, so the job's amount matches what was billed.
    double? amount,
  }) async {
    await _monthlyService.ensureJobListMonthlyDocExists(date);
    final ref = _getJobListItemsCollection(date).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        throw StateError(
            'Job $jobId no longer exists — cannot link Zoho invoice '
            '$zohoInvoiceNumber. Link it manually in the Job List.');
      }

      // A split job's money fields are the total across all its invoices, so
      // the primary's figure is added to the splits rather than replacing them.
      final splits = JobListItem.fromMap(
              snap.id, Map<String, dynamic>.from(snap.data() as Map))
          .splitInvoices;
      final splitSub = splits.fold<double>(0, (r, i) => r + i.subTotal);
      final splitTotal = splits.fold<double>(0, (r, i) => r + i.total);

      txn.update(ref, {
        'zohoContactId': zohoContactId,
        'zohoInvoiceId': zohoInvoiceId,
        'zohoInvoiceNumber': zohoInvoiceNumber,
        'zohoInvoiceStatus': zohoInvoiceStatus,
        'zohoSyncedAt': Timestamp.fromDate(DateTime.now()),
        if (invoiceNumber != null && invoiceNumber.isNotEmpty)
          'invoice': invoiceNumber,
        // The issued invoice is the source of truth for what was billed, so
        // all three money fields are written together. No VAT is charged at
        // present — line items carry no tax_id — so excl == incl == total,
        // and the figure is by definition an excl-VAT one. Writing only some
        // of these would leave the job contradicting its own invoice.
        // If VAT is ever enabled, this must split the total instead.
        if (amount != null) ...{
          'amount': amount + splitSub,
          'amountExclVat': amount + splitSub,
          'amountInclVat': amount + splitTotal,
          'priceIsInclVat': false,
        },
      });
    });

    // Reverse index. Jobs live under jobLists/{month}/items/{id}, so without
    // this an invoice has no way back to its job — acting from the Invoices
    // screen would otherwise need a collection-group query and index.
    await _firestore.collection('zohoInvoiceLinks').doc(zohoInvoiceId).set({
      'jobId': jobId,
      'monthId': getMonthlyDocumentId(date),
      'jobDate': Timestamp.fromDate(date),
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });

    if (kDebugMode) {
      debugPrint('Linked Zoho invoice $zohoInvoiceNumber to job $jobId');
    }
  }

  /// Link an invoice raised with any accounting provider back to its job.
  ///
  /// The provider-neutral counterpart to [linkZohoInvoiceTxn], writing the
  /// `invoiceProviderId` / `accounting*` fields rather than the Zoho-specific
  /// ones. Used by the Xero flow; the Zoho path still uses its own method until
  /// it is migrated.
  ///
  /// **The VAT handling is the real difference.** [linkZohoInvoiceTxn] writes
  /// `amount == amountExclVat == amountInclVat` because Junk & Stuff charges no
  /// VAT, and says in as many words that enabling VAT would require splitting
  /// the total. Community Life Media does charge VAT, so this takes the split
  /// from the invoice itself — the provider computed it, rounding included —
  /// instead of recomputing it here and risking a cents-level disagreement
  /// between the Job List and the books.
  Future<void> linkAccountingInvoiceTxn({
    required String jobId,
    required DateTime date,
    required String providerId,
    required String contactId,
    required String invoiceId,
    required String invoiceNumber,
    required String invoiceStatus,

    /// Total excluding tax, as the provider computed it.
    required double subTotal,

    /// Total including tax, as the provider computed it.
    required double total,
  }) async {
    await _monthlyService.ensureJobListMonthlyDocExists(date);
    final ref = _getJobListItemsCollection(date).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        throw StateError(
            'Job $jobId no longer exists — cannot link invoice $invoiceNumber. '
            'Link it manually in the Job List.');
      }

      // A split job's money fields are the total across all its invoices, so
      // the primary's figures are added to the splits rather than replacing
      // them.
      final splits = JobListItem.fromMap(
              snap.id, Map<String, dynamic>.from(snap.data() as Map))
          .splitInvoices;
      final splitSub = splits.fold<double>(0, (r, i) => r + i.subTotal);
      final splitTotal = splits.fold<double>(0, (r, i) => r + i.total);

      txn.update(ref, {
        'invoiceProviderId': providerId,
        'accountingContactId': contactId,
        'accountingInvoiceId': invoiceId,
        'accountingInvoiceNumber': invoiceNumber,
        'accountingInvoiceStatus': invoiceStatus,
        'accountingSyncedAt': Timestamp.fromDate(DateTime.now()),
        if (invoiceNumber.isNotEmpty) 'invoice': invoiceNumber,
        // All money fields written together — the issued invoice is the source
        // of truth for what was billed, and leaving any of them stale would
        // have the job contradicting its own invoice.
        'amount': subTotal + splitSub,
        'amountExclVat': subTotal + splitSub,
        'amountInclVat': total + splitTotal,
        // The stored figures are the provider's own excl/incl pair, so the
        // "price was typed incl VAT" flag no longer describes them.
        'priceIsInclVat': false,
      });
    });

    // Reverse index, so an invoice can find its way back to its job. Jobs live
    // under jobLists/{month}/items/{id}, which a query from the Invoices screen
    // cannot reach without a collection-group index.
    await _firestore.collection('accountingInvoiceLinks').doc(invoiceId).set({
      'providerId': providerId,
      'jobId': jobId,
      'monthId': getMonthlyDocumentId(date),
      'jobDate': Timestamp.fromDate(date),
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });

    if (kDebugMode) {
      debugPrint('Linked $providerId invoice $invoiceNumber to job $jobId');
    }
  }


  // ── Split invoices ──────────────────────────────────────────────────────────
  // Extra invoices for a job whose bill is shared between clients. Stored in
  // the job's `splitInvoices` array; the primary invoice keeps its flat fields.
  // The job's money fields are always the total across every invoice, so each
  // write here moves them by exactly the split's own figures.

  /// Link a split invoice to its job, transactionally.
  ///
  /// Idempotent: linking an invoice that is already on the job replaces its
  /// entry and moves the money fields by the difference only, so a saga retry
  /// can never count the same invoice twice.
  Future<void> linkSplitInvoiceTxn({
    required String jobId,
    required DateTime date,
    required JobInvoiceLink link,
  }) async {
    await _monthlyService.ensureJobListMonthlyDocExists(date);
    final ref = _getJobListItemsCollection(date).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        throw StateError(
            'Job $jobId no longer exists — cannot link invoice '
            '${link.invoiceNumber}. Link it manually in the Job List.');
      }
      final current = JobListItem.fromMap(
          snap.id, Map<String, dynamic>.from(snap.data() as Map));

      final splits = [...current.splitInvoices];
      final at = splits.indexWhere((i) => i.invoiceId == link.invoiceId);
      final previous = at >= 0 ? splits[at] : null;
      if (at >= 0) {
        splits[at] = link;
      } else {
        splits.add(link);
      }

      final excl =
          current.amountExclVat - (previous?.subTotal ?? 0) + link.subTotal;
      final currentIncl = current.amountInclVat > 0
          ? current.amountInclVat
          : current.amountExclVat;
      final incl = currentIncl - (previous?.total ?? 0) + link.total;

      txn.update(ref, {
        'splitInvoices': splits.map((i) => i.toMap()).toList(),
        'amount': excl,
        'amountExclVat': excl,
        'amountInclVat': incl,
        'priceIsInclVat': false,
      });
    });

    await _writeSplitIndexes(link, jobId: jobId, date: date);

    if (kDebugMode) {
      debugPrint('Linked split ${link.providerId} invoice '
          '${link.invoiceNumber} to job $jobId');
    }
  }

  /// Reverse index entries for a split invoice, flagged `split` so a status
  /// sync updates the array entry rather than the job's primary fields.
  ///
  /// A Zoho split is written to `zohoInvoiceLinks` as well, because that is
  /// the index the Zoho invoice screens sync through.
  Future<void> _writeSplitIndexes(
    JobInvoiceLink link, {
    required String jobId,
    required DateTime date,
  }) async {
    final entry = {
      'providerId': link.providerId,
      'jobId': jobId,
      'monthId': getMonthlyDocumentId(date),
      'jobDate': Timestamp.fromDate(date),
      'split': true,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    };
    await _firestore
        .collection('accountingInvoiceLinks')
        .doc(link.invoiceId)
        .set(entry);
    if (link.providerId == 'zoho') {
      await _firestore
          .collection('zohoInvoiceLinks')
          .doc(link.invoiceId)
          .set(entry);
    }
  }

  /// Unlink a **void** split invoice from its job.
  ///
  /// As with [unlinkVoidedInvoiceTxn] the caller must have confirmed the
  /// invoice is void. Unlike the primary, the split's figures **are** taken off
  /// the job's money fields: they were that client's share, and leaving them
  /// would count the share twice once its replacement is linked.
  Future<void> unlinkSplitInvoiceTxn({
    required String jobId,
    required DateTime date,
    required String invoiceId,
  }) async {
    if (invoiceId.isEmpty) return;
    await _monthlyService.ensureJobListMonthlyDocExists(date);
    final ref = _getJobListItemsCollection(date).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        throw StateError('Job $jobId no longer exists.');
      }
      final current = JobListItem.fromMap(
          snap.id, Map<String, dynamic>.from(snap.data() as Map));
      final removed = current.splitInvoices
          .where((i) => i.invoiceId == invoiceId)
          .toList();
      if (removed.isEmpty) {
        throw StateError(
            'This job is no longer linked to that invoice. Refresh and check '
            'before trying again.');
      }
      final link = removed.first;
      final splits =
          current.splitInvoices.where((i) => i.invoiceId != invoiceId).toList();

      final excl = current.amountExclVat - link.subTotal;
      final currentIncl = current.amountInclVat > 0
          ? current.amountInclVat
          : current.amountExclVat;

      txn.update(ref, {
        'splitInvoices': splits.map((i) => i.toMap()).toList(),
        'amount': excl,
        'amountExclVat': excl,
        'amountInclVat': currentIncl - link.total,
        'voidedInvoiceIds': FieldValue.arrayUnion([invoiceId]),
      });
    });

    await removeZohoInvoiceLink(invoiceId);
    await removeAccountingInvoiceLink(invoiceId);

    if (kDebugMode) {
      debugPrint('Unlinked void split invoice $invoiceId from job $jobId');
    }
  }

  /// Write refreshed statuses onto split invoice entries.
  ///
  /// One transaction per job — the entries live in an array, so each write is a
  /// read-modify-write. A deleted job, or an invoice no longer on its job, is
  /// skipped. The Invoice Status column is left to the grid's reconcile, which
  /// weighs every invoice on the job rather than just the one that changed.
  Future<void> updateSplitInvoiceStatuses(
    List<({String jobId, DateTime date, String invoiceId, String status})>
        updates,
  ) async {
    if (updates.isEmpty) return;

    final byJob = <String,
        List<({String jobId, DateTime date, String invoiceId, String status})>>{};
    for (final u in updates) {
      byJob.putIfAbsent(u.jobId, () => []).add(u);
    }

    final syncedAt = DateTime.now();
    for (final group in byJob.values) {
      final ref = _getJobListItemsCollection(group.first.date)
          .doc(group.first.jobId);
      try {
        await _firestore.runTransaction((txn) async {
          final snap = await txn.get(ref);
          if (!snap.exists) return;
          final current = JobListItem.fromMap(
              snap.id, Map<String, dynamic>.from(snap.data() as Map));
          final fresh = {for (final u in group) u.invoiceId: u.status};
          if (!current.splitInvoices
              .any((i) => fresh.containsKey(i.invoiceId))) {
            return;
          }
          final splits = [
            for (final link in current.splitInvoices)
              fresh.containsKey(link.invoiceId)
                  ? link.copyWith(
                      status: fresh[link.invoiceId], syncedAt: syncedAt)
                  : link,
          ];
          txn.update(ref, {
            'splitInvoices': splits.map((i) => i.toMap()).toList(),
          });
        });
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Split status write failed for job '
              '${group.first.jobId}: $e');
        }
      }
    }
  }

  /// Unlink a **void** invoice from its job so the job can be invoiced again.
  ///
  /// The caller must have confirmed with the provider that the invoice is
  /// void — this method trusts it. The check that *is* made here is that the
  /// job still points at [invoiceId]: if someone re-invoiced it meanwhile, the
  /// live invoice must not be unlinked by a stale screen.
  ///
  /// Clears both the legacy `zoho*` and the provider-neutral `accounting*`
  /// fields (a Zoho job carries both), the job's invoice-number column when it
  /// still shows the void number, and the reverse index. The amount stays: it
  /// is the job's price. The id is appended to `voidedInvoiceIds`, which also
  /// moves the Xero idempotency key on so the re-issue is a new request.
  Future<void> unlinkVoidedInvoiceTxn({
    required String jobId,
    required DateTime date,
    required String invoiceId,

    /// Invoice status for a job with no invoice ("INV_NOT CREATED"). Empty
    /// leaves the column alone.
    String noInvoiceStatusId = '',

    /// The Paid status — a job marked Paid by hand keeps it.
    String paidStatusId = '',
  }) async {
    if (invoiceId.isEmpty) return;
    await _monthlyService.ensureJobListMonthlyDocExists(date);
    final ref = _getJobListItemsCollection(date).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        throw StateError('Job $jobId no longer exists.');
      }
      final current = JobListItem.fromMap(
          snap.id, Map<String, dynamic>.from(snap.data() as Map));
      if (current.resolvedInvoiceId != invoiceId) {
        throw StateError(
            'This job is no longer linked to that invoice — it may have been '
            're-invoiced already. Refresh and check before trying again.');
      }

      final number = current.resolvedInvoiceNumber;
      txn.update(ref, {
        'zohoContactId': FieldValue.delete(),
        'zohoInvoiceId': FieldValue.delete(),
        'zohoInvoiceNumber': FieldValue.delete(),
        'zohoInvoiceStatus': FieldValue.delete(),
        'zohoSyncedAt': FieldValue.delete(),
        'invoiceProviderId': FieldValue.delete(),
        'accountingContactId': FieldValue.delete(),
        'accountingInvoiceId': FieldValue.delete(),
        'accountingInvoiceNumber': FieldValue.delete(),
        'accountingInvoiceStatus': FieldValue.delete(),
        'accountingSyncedAt': FieldValue.delete(),
        if (number.isNotEmpty && current.invoice == number) 'invoice': '',
        // The void invoice's status ("cancelled") no longer describes a job
        // that is about to be billed again.
        if (noInvoiceStatusId.isNotEmpty &&
            (paidStatusId.isEmpty || current.invoiceStatusId != paidStatusId))
          'invoiceStatusId': noInvoiceStatusId,
        'voidedInvoiceIds': FieldValue.arrayUnion([invoiceId]),
      });
    });

    // Both indexes: a Zoho job may have rows in either, and a leftover entry
    // would route the void invoice back to this job on its next status sync.
    await removeZohoInvoiceLink(invoiceId);
    await removeAccountingInvoiceLink(invoiceId);

    if (kDebugMode) {
      debugPrint('Unlinked void invoice $invoiceId from job $jobId');
    }
  }

  /// Write refreshed accounting statuses onto their jobs in one batch.
  ///
  /// The point of the batched status refresh is that a Job List full of
  /// invoiced jobs costs **one** provider call rather than one per row. Doing
  /// the write side a document at a time would hand that saving straight back
  /// to Firestore, so the updates commit together.
  ///
  /// Unlike [linkAccountingInvoiceTxn] this is not transactional and does not
  /// read first: it writes two cache fields that the provider is the source of
  /// truth for, so there is nothing to reconcile against and a lost race just
  /// means the next refresh wins. A job deleted meanwhile is skipped rather
  /// than recreated — hence `update`, never `set`.
  ///
  /// Firestore caps a write batch at 500 operations; [updates] is chunked to
  /// match so a large month cannot fail the whole refresh.
  Future<void> updateAccountingInvoiceStatuses(
    List<({String jobId, DateTime date, String status, String? invoiceStatusId})>
        updates,
  ) async {
    if (updates.isEmpty) return;

    const batchLimit = 500;
    final syncedAt = Timestamp.fromDate(DateTime.now());

    for (var start = 0; start < updates.length; start += batchLimit) {
      final end = (start + batchLimit).clamp(0, updates.length);
      final batch = _firestore.batch();

      for (final u in updates.sublist(start, end)) {
        batch.update(_getJobListItemsCollection(u.date).doc(u.jobId), {
          'accountingInvoiceStatus': u.status,
          'accountingSyncedAt': syncedAt,
          if (u.invoiceStatusId != null) 'invoiceStatusId': u.invoiceStatusId,
        });
      }

      try {
        await batch.commit();
      } catch (e) {
        // One deleted job must not cost the whole refresh: `update` on a
        // missing document fails the entire batch, so fall back to writing
        // this chunk individually and let only the dead rows drop out.
        if (kDebugMode) {
          debugPrint('Batched status write failed ($e) — retrying per job');
        }
        for (final u in updates.sublist(start, end)) {
          try {
            await _getJobListItemsCollection(u.date).doc(u.jobId).update({
              'accountingInvoiceStatus': u.status,
              'accountingSyncedAt': syncedAt,
              if (u.invoiceStatusId != null)
                'invoiceStatusId': u.invoiceStatusId,
            });
          } catch (_) {
            /* the job is gone; its invoice outliving it is not an error */
          }
        }
      }
    }
  }

  /// Correct the Invoice Status column on jobs that disagree with their books,
  /// in batches. Computed by the caller from cached statuses with
  /// [desiredInvoiceStatusId], so this only writes. Deleted jobs are skipped.
  Future<void> updateInvoiceStatusIds(
    List<({String jobId, DateTime date, String invoiceStatusId})> updates,
  ) async {
    const batchLimit = 500;
    for (var start = 0; start < updates.length; start += batchLimit) {
      final end = (start + batchLimit).clamp(0, updates.length);
      final chunk = updates.sublist(start, end);
      final batch = _firestore.batch();
      for (final u in chunk) {
        batch.update(_getJobListItemsCollection(u.date).doc(u.jobId),
            {'invoiceStatusId': u.invoiceStatusId});
      }
      try {
        await batch.commit();
      } catch (_) {
        // One deleted job fails the whole batch; write the rest one by one.
        for (final u in chunk) {
          try {
            await _getJobListItemsCollection(u.date)
                .doc(u.jobId)
                .update({'invoiceStatusId': u.invoiceStatusId});
          } catch (_) {/* the job is gone */}
        }
      }
    }
  }

  /// Push a status change made in this app onto the job an invoice belongs
  /// to, through the `accountingInvoiceLinks` reverse index. The
  /// provider-neutral counterpart to [syncInvoiceStatusToJob].
  ///
  /// Returns false when the invoice has no job — not an error. Without this a
  /// void raised from the invoice screen left the Job List showing the old
  /// status, and the unlink-and-reinvoice action keyed off it stayed hidden
  /// until the next batched refresh.
  Future<bool> syncAccountingInvoiceStatusToJob({
    required String invoiceId,
    required String status,
  }) async {
    final link = await _firestore
        .collection('accountingInvoiceLinks')
        .doc(invoiceId)
        .get();
    if (!link.exists) return false;
    final data = link.data()!;
    final jobId = data['jobId'] as String?;
    final jobDate = (data['jobDate'] as Timestamp?)?.toDate();
    if (jobId == null || jobDate == null) return false;

    if (data['split'] == true) {
      await updateSplitInvoiceStatuses([
        (jobId: jobId, date: jobDate, invoiceId: invoiceId, status: status)
      ]);
      return true;
    }

    await updateAccountingInvoiceStatuses([
      (jobId: jobId, date: jobDate, status: status, invoiceStatusId: null)
    ]);
    return true;
  }

  /// Drop the provider-neutral reverse index entry for an invoice.
  ///
  /// The counterpart to [removeZohoInvoiceLink] for links written by
  /// [linkAccountingInvoiceTxn].
  Future<void> removeAccountingInvoiceLink(String invoiceId) async {
    if (invoiceId.isEmpty) return;
    await _firestore
        .collection('accountingInvoiceLinks')
        .doc(invoiceId)
        .delete();
  }

  /// Push a Zoho status change back onto the job it belongs to.
  ///
  /// Uses the `zohoInvoiceLinks` reverse index written by
  /// [linkZohoInvoiceTxn]. Returns false when no link exists — invoices raised
  /// before that index existed, or created directly in Zoho, simply have no
  /// job to update, which is not an error.
  ///
  /// [statusMap] is the sync settings' Zoho status → `customInvoiceStatuses`
  /// map. An unmapped status leaves the Invoice Status column untouched rather
  /// than guessing, and a job marked Paid by hand keeps it.
  Future<bool> syncInvoiceStatusToJob({
    required String zohoInvoiceId,
    required String zohoStatus,
    Map<String, String> statusMap = const {},
  }) async {
    final link = await _firestore
        .collection('zohoInvoiceLinks')
        .doc(zohoInvoiceId)
        .get();
    if (!link.exists) return false;

    final data = link.data()!;
    final jobId = data['jobId'] as String?;
    final jobDate = (data['jobDate'] as Timestamp?)?.toDate();
    if (jobId == null || jobDate == null) return false;

    if (data['split'] == true) {
      await updateSplitInvoiceStatuses([
        (
          jobId: jobId,
          date: jobDate,
          invoiceId: zohoInvoiceId,
          status: zohoStatus
        )
      ]);
      return true;
    }

    final ref = _getJobListItemsCollection(jobDate).doc(jobId);

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      // The job may have been deleted; the invoice outliving it is fine.
      if (!snap.exists) return;

      // Read inside the transaction so a Paid set by hand a moment ago is
      // seen — that override is never taken away by a sync.
      final current =
          (snap.data() as Map<String, dynamic>?)?['invoiceStatusId'] as String?;
      // On a split job the column reflects every invoice, not just this one;
      // the grid's reconcile works that out from the cached statuses.
      final isSplit =
          ((snap.data() as Map<String, dynamic>?)?['splitInvoices'] as List?)
                  ?.isNotEmpty ??
              false;
      final desired = isSplit ? null : desiredInvoiceStatusId(
        currentStatusId: current ?? '',
        bookKeys: [zohoStatus],
        statusMap: statusMap,
      );

      txn.update(ref, {
        'zohoInvoiceStatus': zohoStatus,
        'zohoSyncedAt': Timestamp.fromDate(DateTime.now()),
        if (desired != null) 'invoiceStatusId': desired,
      });
    });

    if (kDebugMode) {
      debugPrint(
          'Synced invoice $zohoInvoiceId status "$zohoStatus" to job $jobId');
    }
    return true;
  }

  /// Drop the reverse index entry for an invoice, once its job is gone.
  Future<void> removeZohoInvoiceLink(String zohoInvoiceId) async {
    await _firestore.collection('zohoInvoiceLinks').doc(zohoInvoiceId).delete();
  }

  // Delete a job list item
  Future<void> deleteJobListItem(String id, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before deleting
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    await _getJobListItemsCollection(targetDate).doc(id).delete();
  }

  // Get a single job list item by ID
  Future<JobListItem?> getJobListItemById(String id, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();
    final doc = await _getJobListItemsCollection(targetDate).doc(id).get();
    if (doc.exists && doc.data() != null) {
      return JobListItem.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data()! as Map));
    }
    return null;
  }

  // Update job status only
  Future<void> updateJobStatus(String id, JobListStatus newStatus,
      [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists before updating status
    await _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    await _getJobListItemsCollection(targetDate)
        .doc(id)
        .update({'jobStatus': newStatus.name});
  }

  // Get job list items by status
  Stream<List<JobListItem>> getJobListItemsByStatus(JobListStatus status,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .where('jobStatus', isEqualTo: status.name)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }).toList();
    });
  }

  // Get job list items by client
  Stream<List<JobListItem>> getJobListItemsByClient(String client,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .where('client', isEqualTo: client)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return JobListItem.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }).toList();
    });
  }

  // Search job list items by client name (case insensitive)
  Stream<List<JobListItem>> searchJobListItemsByClient(String searchTerm,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    // Ensure monthly document exists when streaming
    _monthlyService.ensureJobListMonthlyDocExists(targetDate);

    return _getJobListItemsCollection(targetDate)
        .orderBy('client')
        .startAt([searchTerm.toLowerCase()])
        .endAt(['${searchTerm.toLowerCase()}\uf8ff'])
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            return JobListItem.fromMap(
                doc.id, Map<String, dynamic>.from(doc.data() as Map));
          }).toList();
        });
  }

  // UTILITY METHODS

  // Get available monthly documents for job lists
  Future<List<String>> getAvailableJobListMonths() {
    return _monthlyService.getAvailableJobListMonths();
  }

  // Get current monthly document ID
  String getCurrentMonthlyDocumentId() {
    return _monthlyService.getCurrentMonthlyDocumentId();
  }

  // Get monthly document ID for a specific date
  String getMonthlyDocumentId(DateTime date) {
    return _monthlyService.getMonthlyDocumentId(date);
  }

  // Move job list item from one month to another
  Future<void> moveJobListItemToMonth(
      JobListItem jobListItem, DateTime oldDate, DateTime newDate) async {
    final oldMonthId = getMonthlyDocumentId(oldDate);
    final newMonthId = getMonthlyDocumentId(newDate);

    // If the months are the same, just do a regular update
    if (oldMonthId == newMonthId) {
      await updateJobListItem(jobListItem, newDate);
      return;
    }

    if (kDebugMode) {
      debugPrint(
          'JobListService: Moving job ${jobListItem.id} from $oldMonthId to $newMonthId');
    }

    // Ensure both monthly documents exist
    await _monthlyService.ensureJobListMonthlyDocExists(oldDate);
    await _monthlyService.ensureJobListMonthlyDocExists(newDate);

    // Atomic move — add to new month and delete from old in one transaction.
    // The new doc starts from the stored one so fields written by others
    // since this copy was loaded survive: above all `storageFolderPath`,
    // which the Cloud Function may have just changed. The create in the new
    // month is what tells the function to move the folder, so it has to see
    // the folder's real current path.
    final oldRef = _getJobListItemsCollection(oldDate).doc(jobListItem.id);
    final newRef = _getJobListItemsCollection(newDate).doc(jobListItem.id);
    await oldRef.firestore.runTransaction((txn) async {
      final stored = await txn.get(oldRef);
      final storedData = stored.data() as Map<String, dynamic>? ?? const {};
      final data = <String, dynamic>{
        ...storedData,
        ...(jobListItem.toMap()..remove('storageFolderPath')),
      };
      txn.set(newRef, data);
      txn.delete(oldRef);
    });

    if (kDebugMode) {
      debugPrint(
          'JobListService: Successfully moved job ${jobListItem.id} to $newMonthId');
    }
  }
}
