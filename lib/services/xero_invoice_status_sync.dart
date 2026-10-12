import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/company.dart';
import '../models/job_invoice_link.dart';
import '../models/job_list_item.dart';
import '../models/xero_invoice.dart';
import '../providers/zoho_sync_settings_provider.dart';
import '../utils/job_lifecycle_rules.dart';
import 'job_list_service.dart';
import 'xero_accounting_service.dart';

/// One job whose cached invoice status no longer matches Xero.
///
/// [invoiceStatusId] is the Job List's own Invoice Status to move to, or null
/// to leave that column alone.
typedef AccountingStatusUpdate = ({
  String jobId,
  DateTime date,
  String status,
  String? invoiceStatusId,
});

/// Keeps `accountingInvoiceStatus` on Job List rows in step with Xero, in one
/// API call rather than one per row.
///
/// **This is a budget problem before it is a correctness problem.** The app's
/// Xero connection is an uncertified one, capped at 1,000 calls a day. A Job
/// List of 200 invoiced CLM jobs, each fetching its own invoice, is a fifth of
/// that budget spent rendering a single screen. `GET /Invoices` accepts a
/// comma-separated `InvoiceNumbers=` filter and pages up to 1000 rows, so the
/// same refresh costs one call — which is why nothing here ever loops over
/// jobs making requests.
///
/// The cache on the job is what makes that affordable, so it is treated as
/// load-bearing rather than as a nicety: a status younger than [staleAfter] is
/// left alone instead of being re-read on every rebuild.
class XeroInvoiceStatusSync {
  XeroInvoiceStatusSync(this._xero, this._jobs,
      {Map<String, String> Function()? statusMap})
      : _statusMap = statusMap ?? (() => const {});

  final XeroAccountingService _xero;
  final JobListService _jobs;

  /// Book status → Invoice Status id, read fresh on every refresh so a change
  /// in the sync settings applies without a restart.
  final Map<String, String> Function() _statusMap;

  /// A cached status younger than this is taken at face value.
  static const staleAfter = Duration(minutes: 10);

  /// Invoice numbers per request.
  ///
  /// They travel in the query string, so the ceiling is URL length rather than
  /// anything Xero documents. Xero's own limit is around 8KB; at ~10 characters
  /// per number plus a separator, 100 leaves an order of magnitude of headroom
  /// while still refreshing all but the largest months in a single call.
  static const chunkSize = 100;

  /// Earliest time another refresh may call Xero.
  ///
  /// Held in memory rather than derived from the jobs, so that a run which
  /// found nothing to change — or failed — still throttles the next one. Without
  /// it, a screen that rebuilds freely would call Xero on every frame.
  DateTime? _nextEligible;
  bool _inFlight = false;

  /// After a failure, retry sooner than a successful run would. A transient
  /// outage should not blank out refreshes for the full staleness window.
  static const _retryAfter = Duration(minutes: 1);

  /// Whether a refresh would do anything right now.
  bool get isRefreshing => _inFlight;

  /// The jobs a refresh should ask about.
  ///
  /// Pure and static so the filtering — which decides how much of the daily
  /// budget gets spent — can be tested without a network or a clock.
  ///
  /// Excluded, in order: jobs not invoiced through Xero (Junk & Stuff's Zoho
  /// rows share this list); jobs with no invoice number to look up; invoices
  /// in a terminal state, since VOIDED and DELETED never change again; and
  /// anything refreshed within [staleAfter].
  @visibleForTesting
  static List<JobListItem> jobsDueRefresh(
    List<JobListItem> jobs, {
    required DateTime now,
    Duration staleAfter = staleAfter,
  }) {
    return jobs.where((job) {
      if (job.resolvedInvoiceProviderId != AccountingProvider.xero.name) {
        return false;
      }
      if (job.resolvedInvoiceNumber.isEmpty) return false;

      final status = XeroInvoiceStatus.parse(job.resolvedInvoiceStatus);
      if (status == XeroInvoiceStatus.voided ||
          status == XeroInvoiceStatus.deleted) {
        return false;
      }

      final syncedAt = job.resolvedSyncedAt;
      if (syncedAt == null) return true;
      return now.difference(syncedAt) >= staleAfter;
    }).toList();
  }

  /// The split invoices a refresh should ask about, by the same rules as
  /// [jobsDueRefresh] applied to each split entry.
  @visibleForTesting
  static List<({JobListItem job, JobInvoiceLink link})> splitsDueRefresh(
    List<JobListItem> jobs, {
    required DateTime now,
    Duration staleAfter = staleAfter,
  }) {
    return [
      for (final job in jobs)
        for (final link in job.splitInvoices)
          if (link.providerId == AccountingProvider.xero.name &&
              link.invoiceNumber.isNotEmpty &&
              !_isTerminal(XeroInvoiceStatus.parse(link.status)) &&
              (link.syncedAt == null ||
                  now.difference(link.syncedAt!) >= staleAfter))
            (job: job, link: link),
    ];
  }

  static bool _isTerminal(XeroInvoiceStatus status) =>
      status == XeroInvoiceStatus.voided || status == XeroInvoiceStatus.deleted;

  /// Split invoice numbers into request-sized groups, de-duplicated.
  ///
  /// Two jobs can legitimately point at the same invoice number, and asking
  /// Xero for it twice in one query wastes the very headroom this exists to
  /// protect.
  @visibleForTesting
  static List<List<String>> chunkNumbers(
    Iterable<String> numbers, {
    int size = chunkSize,
  }) {
    final unique = <String>{};
    for (final n in numbers) {
      if (n.isNotEmpty) unique.add(n);
    }

    final out = <List<String>>[];
    final all = unique.toList();
    for (var i = 0; i < all.length; i += size) {
      out.add(all.sublist(i, (i + size).clamp(0, all.length)));
    }
    return out;
  }

  /// The writes a refresh should make, given what Xero returned.
  ///
  /// Only genuine changes are returned — a new Xero status, or an Invoice
  /// Status column that disagrees with it (see [desiredInvoiceStatusId]; a
  /// job marked Paid by hand keeps Paid). An invoice Xero did not report is left
  /// untouched rather than blanked: a number missing from the response means
  /// the filter matched nothing, which is far likelier to be an invoice raised
  /// in another organisation than one that has ceased to exist.
  @visibleForTesting
  static List<AccountingStatusUpdate> updatesFor(
    List<JobListItem> jobs,
    Map<String, XeroInvoice> byNumber, {
    Map<String, String> statusMap = const {},
  }) {
    final out = <AccountingStatusUpdate>[];
    for (final job in jobs) {
      final live = byNumber[job.resolvedInvoiceNumber];
      if (live == null) continue;

      final fresh = live.status.apiValue;
      final key = xeroBookStatusKey(live);
      // A split job's column weighs every invoice; the grid's reconcile does
      // that from the cached statuses, so this one invoice must not decide it.
      final statusId = key.isEmpty || job.hasSplitInvoices
          ? null
          : desiredInvoiceStatusId(
              currentStatusId: job.invoiceStatusId,
              bookKeys: [key],
              statusMap: statusMap,
            );
      if (fresh == job.resolvedInvoiceStatus && statusId == null) continue;

      out.add((
        jobId: job.id,
        date: job.date,
        status: fresh,
        invoiceStatusId: statusId,
      ));
    }
    return out;
  }

  /// Refresh every stale Xero status in [jobs].
  ///
  /// Returns the number of jobs whose status actually changed. Never throws —
  /// this runs behind a screen the user did not ask to refresh, so an
  /// unreachable Xero must degrade to a stale status, not an error.
  Future<int> refresh(
    List<JobListItem> jobs, {
    bool force = false,
  }) async {
    if (_inFlight) return 0;

    final now = DateTime.now();
    if (!force && _nextEligible != null && now.isBefore(_nextEligible!)) {
      return 0;
    }

    final due = jobsDueRefresh(
      jobs,
      now: now,
      staleAfter: force ? Duration.zero : staleAfter,
    );
    final dueSplits = splitsDueRefresh(
      jobs,
      now: now,
      staleAfter: force ? Duration.zero : staleAfter,
    );
    if (due.isEmpty && dueSplits.isEmpty) {
      _nextEligible = now.add(staleAfter);
      return 0;
    }

    _inFlight = true;
    try {
      final byNumber = <String, XeroInvoice>{};

      // Primary and split numbers share the same requests — one call either way.
      for (final chunk in chunkNumbers([
        ...due.map((j) => j.resolvedInvoiceNumber),
        ...dueSplits.map((s) => s.link.invoiceNumber),
      ])) {
        // summaryOnly drops line items, which is what keeps a full page inside
        // the response size limit — nothing here reads them.
        final page = await _xero.listInvoices(
          invoiceNumbers: chunk,
          summaryOnly: true,
          pageSize: 1000,
        );
        for (final invoice in page.items) {
          if (invoice.invoiceNumber.isNotEmpty) {
            byNumber[invoice.invoiceNumber] = invoice;
          }
        }
      }

      final updates = updatesFor(due, byNumber, statusMap: _statusMap());
      await _jobs.updateAccountingInvoiceStatuses(updates);

      final splitUpdates = [
        for (final s in dueSplits)
          if (byNumber[s.link.invoiceNumber] case final live?)
            if (live.status.apiValue != s.link.status)
              (
                jobId: s.job.id,
                date: s.job.date,
                invoiceId: s.link.invoiceId,
                status: live.status.apiValue,
              ),
      ];
      await _jobs.updateSplitInvoiceStatuses(splitUpdates);

      _nextEligible = now.add(staleAfter);
      if (kDebugMode && (updates.isNotEmpty || splitUpdates.isNotEmpty)) {
        debugPrint('[xero] refreshed ${due.length + dueSplits.length} '
            'statuses, ${updates.length + splitUpdates.length} changed');
      }
      return updates.length + splitUpdates.length;
    } catch (e) {
      // Still throttled, or an unreachable Xero would be retried on every
      // rebuild — just for a shorter window than a successful run earns.
      _nextEligible = now.add(_retryAfter);
      if (kDebugMode) debugPrint('[xero] status refresh failed: $e');
      return 0;
    } finally {
      _inFlight = false;
    }
  }
}

/// Session-scoped so the in-memory throttle survives navigating between
/// screens — a fresh instance per build would defeat the whole point.
final xeroInvoiceStatusSyncRiverpod = riverpod.Provider<XeroInvoiceStatusSync>(
  (ref) => XeroInvoiceStatusSync(
    ref.read(xeroAccountingServiceRiverpod),
    ref.read(jobListServiceRiverpod),
    statusMap: () => ref.read(zohoSyncSettingsRiverpod).invoiceStatusMap,
  ),
);
