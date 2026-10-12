import '../models/custom_invoice_status.dart';
import '../models/custom_job_list_status.dart';
import '../models/company.dart';
import '../models/job_list_item.dart';
import '../models/xero_invoice.dart';
import '../models/zoho_invoice.dart';

/// Pure decision rules for the points where a job's lifecycle and its invoice
/// have to agree.
///
/// These live apart from the widgets that call them for one reason: each is a
/// rule that is easy to get subtly wrong and impossible to check by reading the
/// UI. Keeping them free of `ref`, `BuildContext` and Firestore is what makes
/// them testable, so the rules are covered by
/// `test/job_lifecycle_rules_test.dart` rather than by clicking through the
/// grid.

/// Label of the status a copied job opens in — the start of the order
/// lifecycle, whatever state the job it was copied from had reached.
const String kCopyJobStatusLabel = 'Order Confirmed';

/// Seeded document id for [kCopyJobStatusLabel], used only when the label has
/// been renamed. Statuses are user-editable from the Job List settings screen,
/// so an id alone would rot silently; a label alone would break on a rename.
const String kCopyJobStatusFallbackId = 'order_confirmed_not_paid';

/// Labels accepted for the "invoice not created" status, most canonical
/// first. A copy drops the source's invoice link and number, so there is no
/// invoice yet — "outstanding" would claim a bill nobody has sent.
const List<String> kCopyInvoiceStatusLabels = [
  'INV_NOT CREATED',
  'INV_NOT_CREATED',
  'INV NOT CREATED',
  'Invoice Not Created',
];

/// Seeded document id of the "invoice not created" status, used when the
/// label has been renamed beyond recognition.
const String kNoInvoiceStatusFallbackId = 'pending';

/// The job status a copy should open in, resolved against the live statuses.
///
/// Falls back through label → seeded id → the source job's own status, so a
/// renamed or deleted status can never leave a copy pointing at an id that no
/// status document has. Returning [sourceStatusId] is the "change nothing"
/// outcome, matching the behaviour before copies reset the lifecycle at all.
String resolveCopyJobStatusId({
  required List<CustomJobListStatus> statuses,
  required String sourceStatusId,
}) {
  for (final status in statuses) {
    if (status.label == kCopyJobStatusLabel) return status.id;
  }
  for (final status in statuses) {
    if (status.id == kCopyJobStatusFallbackId) return kCopyJobStatusFallbackId;
  }
  return sourceStatusId;
}

/// The invoice status a copy should open in, resolved against the live
/// statuses. Labels are matched case-insensitively so both the code-style
/// `PAY_OUTSTANDING` and a prettified rename resolve.
String resolveCopyInvoiceStatusId({
  required List<CustomInvoiceStatus> statuses,
  required String sourceStatusId,
}) {
  for (final wanted in kCopyInvoiceStatusLabels) {
    for (final status in statuses) {
      if (status.label.toLowerCase() == wanted.toLowerCase()) return status.id;
    }
  }
  for (final status in statuses) {
    if (status.id == kNoInvoiceStatusFallbackId) return status.id;
  }
  return sourceStatusId;
}

// ── Invoice Status column ↔ the books ───────────────────────────────────────
//
// The sync settings map *book statuses* onto your own `customInvoiceStatuses`.
// The map is keyed by Zoho's wire values (`sent`, `overdue`, `paid`, …); Xero
// statuses are translated onto the same keys so one mapping serves both.
//
// The rule: a job linked to an invoice shows what the books say. The single
// exception is a job marked Paid by hand — cash, EFT straight to the account —
// which the books may never hear about, so Paid is never taken away by a sync.

/// Book-status keys the sync map uses.
const String kBookDraft = 'draft';
const String kBookSent = 'sent';
const String kBookOverdue = 'overdue';
const String kBookPartiallyPaid = 'partially_paid';
const String kBookPaid = 'paid';
const String kBookVoid = 'void';

/// The book status a live Xero invoice corresponds to. Xero has no OVERDUE or
/// PARTIALLY PAID state — both are AUTHORISED — so they are derived here,
/// overdue first because it is the one that needs chasing.
String xeroBookStatusKey(XeroInvoice invoice) {
  switch (invoice.status) {
    case XeroInvoiceStatus.paid:
      return kBookPaid;
    case XeroInvoiceStatus.voided:
    case XeroInvoiceStatus.deleted:
      return kBookVoid;
    case XeroInvoiceStatus.draft:
    case XeroInvoiceStatus.submitted:
      return kBookDraft;
    case XeroInvoiceStatus.authorised:
      if (invoice.isOverdue) return kBookOverdue;
      if (invoice.amountPaid > 0) return kBookPartiallyPaid;
      return kBookSent;
    case XeroInvoiceStatus.unknown:
      return '';
  }
}

/// The book statuses consistent with the job's **cached** invoice status,
/// preferred first. Empty when the job has no invoice or the status is
/// unreadable — the column is then left alone.
///
/// A cached Xero AUTHORISED could be sent, overdue or part-paid; only a live
/// read can tell, so all three are accepted and the live refresh decides.
///
/// A job split across several invoices (see `JobListItem.splitInvoices`) is
/// judged on all of them: it is paid only when every live invoice is paid, and
/// void only when every one is void. Otherwise the outstanding invoices decide,
/// primary first — with partly paid added when some share has been settled.
List<String> cachedBookStatusKeys(JobListItem job) {
  if (!job.hasSplitInvoices) {
    if (!job.hasAccountingInvoice) return const [];
    return bookKeysForCachedStatus(
        job.resolvedInvoiceProviderId, job.resolvedInvoiceStatus);
  }

  final perInvoice = [
    for (final invoice in job.allInvoices)
      bookKeysForCachedStatus(invoice.providerId, invoice.status),
  ];
  // An unreadable status says nothing for certain about the whole job.
  if (perInvoice.any((keys) => keys.isEmpty)) return const [];

  final live = perInvoice.where((keys) => !keys.contains(kBookVoid)).toList();
  if (live.isEmpty) return const [kBookVoid];

  final unpaid = live.where((keys) => !keys.contains(kBookPaid)).toList();
  if (unpaid.isEmpty) return const [kBookPaid];

  final out = <String>[];
  for (final keys in unpaid) {
    for (final key in keys) {
      if (!out.contains(key)) out.add(key);
    }
  }
  if (unpaid.length < live.length && !out.contains(kBookPartiallyPaid)) {
    out.add(kBookPartiallyPaid);
  }
  return out;
}

/// The book statuses consistent with one invoice's cached status — see
/// [cachedBookStatusKeys].
List<String> bookKeysForCachedStatus(String providerId, String raw) {
  if (raw.isEmpty) return const [];

  if (providerId == AccountingProvider.xero.name) {
    switch (XeroInvoiceStatus.parse(raw)) {
      case XeroInvoiceStatus.paid:
        return const [kBookPaid];
      case XeroInvoiceStatus.voided:
      case XeroInvoiceStatus.deleted:
        return const [kBookVoid];
      case XeroInvoiceStatus.draft:
      case XeroInvoiceStatus.submitted:
        return const [kBookDraft];
      case XeroInvoiceStatus.authorised:
        return const [kBookSent, kBookOverdue, kBookPartiallyPaid];
      case XeroInvoiceStatus.unknown:
        return const [];
    }
  }

  final zoho = ZohoInvoiceStatus.parse(raw);
  switch (zoho) {
    case ZohoInvoiceStatus.unknown:
      return const [];
    // Zoho turns these overdue on its own schedule, and the app only hears of
    // Zoho changes it made itself — so a cached "sent" may already be overdue.
    case ZohoInvoiceStatus.sent:
    case ZohoInvoiceStatus.viewed:
    case ZohoInvoiceStatus.unpaid:
      return [zoho.apiValue, kBookOverdue];
    case ZohoInvoiceStatus.partiallyPaid:
      return const [kBookPartiallyPaid, kBookOverdue];
    default:
      return [zoho.apiValue];
  }
}

/// The invoice status id a job should be moved to so it matches the books, or
/// null when it already does (or nothing is mapped, so nothing can be said).
///
/// [bookKeys] are the book statuses consistent with what is known, preferred
/// first — one key from a live read, possibly several from a cache.
/// [statusMap] is book key → your status id, from the sync settings.
String? desiredInvoiceStatusId({
  required String currentStatusId,
  required List<String> bookKeys,
  required Map<String, String> statusMap,
}) {
  final acceptable = [
    for (final key in bookKeys)
      if ((statusMap[key] ?? '').isNotEmpty) statusMap[key]!,
  ];
  if (acceptable.isEmpty) return null;
  if (acceptable.contains(currentStatusId)) return null;

  // Marked Paid by hand: the books may never record a cash payment, so a sync
  // must not drag the job back to "outstanding".
  final paidId = statusMap[kBookPaid] ?? '';
  if (paidId.isNotEmpty && currentStatusId == paidId) return null;

  return acceptable.first;
}

/// Whether a hand-picked invoice status may be applied to [job].
///
/// Jobs with no invoice are free. A linked job may only be set to Paid (the
/// manual override) or to a status consistent with its books — anything else
/// would contradict the invoice and be reverted by the next sync anyway.
bool isManualInvoiceStatusAllowed({
  required JobListItem job,
  required String newStatusId,
  required Map<String, String> statusMap,
}) {
  final keys = cachedBookStatusKeys(job);
  final acceptable = [
    for (final key in keys)
      if ((statusMap[key] ?? '').isNotEmpty) statusMap[key]!,
  ];
  if (acceptable.isEmpty) return true;
  if (acceptable.contains(newStatusId)) return true;
  final paidId = statusMap[kBookPaid] ?? '';
  return paidId.isNotEmpty && newStatusId == paidId;
}

/// Whether moving a job from [before] to [after] should offer to void its
/// invoice.
///
/// Fires only on the **transition** into the nominated cancelled status: a job
/// that is already cancelled must not re-prompt on every unrelated edit. A job
/// with no invoice has nothing to offer, and an empty [cancelledStatusId] means
/// no cancelled status has been nominated in the Zoho sync settings yet — in
/// which case this must never guess, or an ordinary status change would offer
/// to void a live invoice.
bool shouldOfferVoidOnCancel({
  required JobListItem before,
  required JobListItem after,
  required String cancelledStatusId,
}) {
  if (cancelledStatusId.isEmpty) return false;
  if (!after.hasAccountingInvoice) return false;
  if (after.jobStatusId != cancelledStatusId) return false;
  if (before.jobStatusId == cancelledStatusId) return false;
  return true;
}
