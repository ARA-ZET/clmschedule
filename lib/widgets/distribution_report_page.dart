import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/distribution_report.dart';
import '../models/distribution_report_draft.dart';
import '../models/distribution_report_template.dart';
import '../models/distributor.dart';
import '../models/invoice_message_subject.dart';
import '../models/job_invoice_link.dart';
import '../models/job_list_item.dart';
import '../models/xero_invoice.dart';
import '../models/zoho_invoice.dart';
import '../models/track_upload.dart' show normalizePersonName;
import '../providers/distribution_report_template_provider.dart';
import '../providers/distributor_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/cloud_file_manager_provider.dart';
import '../providers/job_type_provider.dart';
import '../providers/zoho_invoices_provider.dart';
import '../services/distribution_report_draft_service.dart';
import '../services/distribution_report_service.dart';
import '../services/job_list_service.dart';
import '../services/xero_accounting_service.dart';
import '../shareable_maps/services/map_link_service.dart';
import '../track_editor/pages/te_report_preview_page.dart';
import '../track_editor/providers/te_report_provider.dart';
import '../track_editor/services/te_gpx_matching.dart';
import '../track_editor/services/te_report_generate.dart';
import '../track_editor/widgets/te_report_days.dart';
import '../utils/browser_file_drop.dart';
import '../services/cloud_archive_service.dart' show formatBytes;
import '../utils/gmail_compose.dart';
import '../utils/gmail_draft.dart';
import '../utils/invoice_dates.dart';
import '../utils/invoice_personnel.dart';
import '../utils/rich_clipboard.dart';
import '../utils/schedule_time.dart';
import '../utils/zoho_org.dart';
import 'xero/xero_invoice_editor.dart';
import 'zoho/zoho_invoice_editor.dart';
import 'zoho/invoice_share.dart' show invoiceFileName;

/// "Chand Environmental - INV-1042.pdf": the customer exactly as Xero (or
/// Zoho) has it on the invoice, then the invoice number — the name the Job
/// List's invoice download gives the same PDF.
///
/// [customerName] is read off the invoice itself; until it has loaded, the
/// link's own customer (split invoices) or the job's client stands in.
@visibleForTesting
String reportInvoiceFileName(
  JobInvoiceLink link,
  JobListItem job, {
  String? customerName,
}) {
  final fromInvoice = customerName?.trim() ?? '';
  final client = fromInvoice.isNotEmpty
      ? fromInvoice
      : link.contactName.trim().isNotEmpty
          ? link.contactName
          : job.client;
  final name = invoiceFileName(InvoiceMessageSubject(
    clientName: client,
    invoiceNumber: link.invoiceNumber,
    total: 0,
    amountDue: 0,
  ));
  return '$name.pdf';
}

/// Compile and send the client-facing distribution report for [item], on a
/// page of its own over the Job List.
///
/// Opens straight into a loading state and compiles on the way — the data
/// comes from three round-trips and there is nothing useful to show first.
///
/// [editJob] is the Job List's own edit flow — the Add/Edit Job dialog and
/// the writes after it — so the report edits a job and its invoice through
/// the one invoice section the rest of the app uses.
Future<void> openDistributionReport(
  BuildContext context,
  JobListItem item, {
  ReportJobEditor? editJob,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => DistributionReportPage(item: item, editJob: editJob),
  ));
}

/// Opens a job in the Add/Edit Job dialog and writes the result, completing
/// true once something was saved. The report uses it to create an invoice.
typedef ReportJobEditor = Future<bool> Function(
  BuildContext context,
  JobListItem job,
);

/// Settings on the left, the email as the client will read it on the right
/// (tabs on a narrow screen), and a readiness list over the preview saying
/// what is still missing.
class DistributionReportPage extends riverpod.ConsumerStatefulWidget {
  final JobListItem item;

  /// Stands in for [DistributionReportService.compile] in widget tests,
  /// which have no Firebase to compile from.
  @visibleForTesting
  final Future<DistributionReport> Function(JobListItem job)? compileJob;

  /// The Job List's edit flow. Null where the page is opened without one;
  /// invoices are then edited in the invoice editor alone.
  final ReportJobEditor? editJob;

  /// Stands in for the Storage scan of the flyer handout report in widget
  /// tests.
  @visibleForTesting
  final Future<void> Function(TEReportProvider report, List<String> folders)?
      scanHandouts;

  const DistributionReportPage({
    super.key,
    required this.item,
    this.compileJob,
    this.editJob,
    this.scanHandouts,
  });

  @override
  riverpod.ConsumerState<DistributionReportPage> createState() =>
      _DistributionReportPageState();
}

class _DistributionReportPageState extends riverpod
    .ConsumerState<DistributionReportPage> with SingleTickerProviderStateMixin {
  /// The job, re-read after it is edited from this page — amount, invoice
  /// and status can all change in the Edit Job dialog.
  late JobListItem _item = widget.item;

  final _greeting = TextEditingController();
  final _subject = TextEditingController();

  DistributionReport? _report;
  String? _compileError;
  bool _loading = true;

  /// Selected template's **id**, not the object — the provider replaces its
  /// whole list on reload and the template has no value equality, which would
  /// leave the dropdown with a value matching none of its items.
  String? _templateId;

  final Set<String> _selectedFolders = {};

  /// Null until the user overrides the invoice-derived default.
  bool? _includeInvoiceLine;

  bool _writeBackQuantity = false;

  // ── Flyers & Posters ─────────────────────────────────────────────────────
  // Only used when the chosen template needs them. The clicked row fills one
  // slot (leaflet or poster job) and the user picks the other.

  final _heading = TextEditingController();
  final _leafletName = TextEditingController();
  final _suburb = TextEditingController();

  /// Once typed in, the suburb is the user's and is no longer prefilled.
  bool _suburbTouched = false;

  /// Whether the clicked row is the poster job rather than the leaflet job.
  late bool _clickedIsPoster = _item.jobTypeId == 'postering';

  /// The job paired with the clicked row, and its compiled report.
  JobListItem? _otherItem;
  DistributionReport? _otherReport;
  final Set<String> _otherFolders = {};
  bool _otherLoading = false;
  String? _otherError;

  /// Jobs offered for the other slot, same client and nearest date first.
  /// Null while loading.
  List<JobListItem>? _candidates;

  /// Distributor ids chosen by hand, keyed by the lower-cased file-name
  /// spelling — for a name `matchDistributor` placed wrongly or not at all.
  final Map<String, String> _pickedDistributor = {};

  /// IDs typed on the page, keyed by [_PersonRow.key]. Not written back to
  /// the distributor's profile.
  final Map<String, String> _typedIds = {};
  final Set<String> _removedPeople = {};

  // Fields the readiness list can jump to.
  final _templateFocus = FocusNode();
  final _greetingFocus = FocusNode();
  final _headingFocus = FocusNode();
  final _leafletNameFocus = FocusNode();
  final _suburbFocus = FocusNode();

  /// Setup / Preview on a narrow screen.
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// Link taps in the preview, renewed every build.
  final List<TapGestureRecognizer> _recognizers = [];

  // ── Saved progress ───────────────────────────────────────────────────────
  // Everything the user decides is saved to distributionReportDrafts/{jobId}
  // a moment after it changes, and restored on the way back in.

  late final DistributionReportDraftService _drafts =
      ref.read(distributionReportDraftServiceRiverpod);
  late final Future<DistributionReportDraft?> _draftLoad = _loadDraft();
  Future<void>? _candidatesLoad;

  /// False until the saved draft (or the lack of one) has been applied.
  /// Nothing is saved before then — the defaults would overwrite the draft.
  bool _restored = false;

  /// Content of the last save (or of the draft as restored).
  String? _savedJson;
  String? _inFlightJson;
  DistributionReportDraft? _pendingDraft;
  String? _pendingJson;
  Timer? _saveTimer;

  _SaveState _saveState = _SaveState.none;
  DateTime? _savedAt;

  // ── Attachments ──────────────────────────────────────────────────────────
  // Sent with the Gmail draft: the jobs' invoice PDFs, fetched from Zoho or
  // Xero, and files the user adds. Only where Gmail drafts are set up — a
  // draft link cannot carry files.

  /// Invoice PDFs by invoice id, each fetched once per page.
  final Map<String, _Attachment> _invoiceFiles = {};

  /// Invoice id → attach or not, where the user changed the default.
  final Map<String, bool> _invoiceChoices = {};

  /// Files added from the computer. Not kept in the saved draft — only
  /// their bytes would say what they were.
  final List<_Attachment> _addedFiles = [];
  int _fileSeq = 0;

  BrowserFileDrop? _fileDrop;
  bool _dropActive = false;

  /// Invoices saved with the personnel added (kept in the draft).
  final Set<String> _invoicesWithPersonnel = {};

  /// Invoices loaded in full from Xero/Zoho for the editor under the
  /// preview, by invoice id. Also where the PDF's customer name comes from.
  final Map<String, _InvoiceDetail> _invoiceDetails = {};

  /// Personnel added in the editor but not saved to Xero/Zoho yet.
  final Set<String> _personnelUnsaved = {};

  /// The poster job is being re-read after photos were uploaded.
  bool _checkingPhotos = false;

  // ── Flyer handout report ─────────────────────────────────────────────────
  // The traffic-light handout report is a PDF, built here from the ticked
  // folders' tracks and photos the same way Track Editor Report mode builds
  // it, and attached to the email.

  /// The promoter days, photos and typed text — this page's own, not the
  /// Track Editor's.
  final TEReportProvider _handouts = TEReportProvider();

  /// The ticked folders the last scan covered; a different set rescans.
  String? _handoutScanKey;

  /// The built PDF, and [TEReportProvider.revision] when it was built — a
  /// later revision means the days or photos changed since.
  _Attachment? _handoutPdf;
  int _handoutPdfRevision = -1;

  bool get _handoutPdfStale =>
      _handoutPdf != null && _handoutPdfRevision != _handouts.revision;

  /// Whether the template in force is the flyer handout report.
  bool get _handoutMode =>
      _resolveTemplate(ref.read(distributionReportTemplateRiverpod).available)
          ?.usesFlyerHandouts ??
      false;

  @override
  void initState() {
    super.initState();
    _draftLoad; // Started now, alongside the compile, not after it.
    _handouts.addListener(_onHandoutsChanged);
    prepareGmailDrafts();
    if (gmailDraftsAvailable) {
      _fileDrop = listenForFileDrops(
        onOver: (_) {
          if (!_acceptsDrops) return;
          if (!_dropActive) setState(() => _dropActive = true);
        },
        onLeave: () {
          if (mounted && _dropActive) setState(() => _dropActive = false);
        },
        onDrop: (_, pending) async {
          final accept = _acceptsDrops;
          if (mounted && _dropActive) setState(() => _dropActive = false);
          if (!accept) return;
          await _addFiles(await pending);
        },
      );
    }
    _compile();
    _candidatesLoad = _loadCandidates();
  }

  @override
  void dispose() {
    _fileDrop?.dispose();
    // Leaving mid-typing still keeps the last change. Not awaited: the write
    // is queued by Firestore and outlives the page.
    _saveTimer?.cancel();
    final pending = _pendingDraft;
    if (pending != null) {
      _drafts.save(pending).catchError((Object e) =>
          debugPrint('[DistributionReport] draft save failed: $e'));
    }
    _greeting.dispose();
    _subject.dispose();
    _heading.dispose();
    _leafletName.dispose();
    _suburb.dispose();
    _templateFocus.dispose();
    _greetingFocus.dispose();
    _headingFocus.dispose();
    _leafletNameFocus.dispose();
    _suburbFocus.dispose();
    _tabs.dispose();
    for (final r in _recognizers) {
      r.dispose();
    }
    _handouts
      ..removeListener(_onHandoutsChanged)
      ..dispose();
    super.dispose();
  }

  void _onHandoutsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _compile() async {
    if (!_loading) {
      setState(() {
        _loading = true;
        _compileError = null;
      });
    }
    try {
      final report = await _compileJob(_item);
      if (!mounted) return;
      setState(() {
        _report = report;
        _selectedFolders
          ..clear()
          ..addAll(report.readableFolders.map((f) => f.path));
        // Only offer the write-back when the row has no figure of its own.
        // Silently replacing a manually entered number would be worse than
        // making the user tick a box.
        _writeBackQuantity = report.recordedQuantityDistributed == 0;
        _subject.text = _defaultSubject(report);
        _loading = false;
        _prefillSuburb();
      });
      await _restoreDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _compileError = '$e';
        _loading = false;
      });
    }
  }

  Future<DistributionReport> _compileJob(JobListItem job) =>
      widget.compileJob?.call(job) ?? DistributionReportService().compile(job);

  /// The same subject for every report, whatever the client or template.
  String _defaultSubject(DistributionReport report) => kDefaultReportSubject;

  /// Swaps the subject to suit the template picked, unless one was typed.
  void _followTemplateSubject(
      List<DistributionReportTemplate> available, String? id) {
    final picked = available.where((t) => t.id == id).firstOrNull;
    final current = _subject.text.trim();
    if (current.isNotEmpty &&
        current != kDefaultReportSubject &&
        current != kFlyerHandoutReportSubject) {
      return;
    }
    _subject.text = (picked?.usesFlyerHandouts ?? false)
        ? kFlyerHandoutReportSubject
        : kDefaultReportSubject;
  }

  /// What the subject was generated as before the fixed one — "Distribution
  /// Report — Seeff — 12 August 2026". A draft holding that was never typed
  /// by anyone, so it gives way to [kDefaultReportSubject].
  static bool _isOldGeneratedSubject(String subject) =>
      subject.trim().startsWith('Distribution Report — ');

  // ---------------------------------------------------------------------------
  // Derived values
  // ---------------------------------------------------------------------------

  /// On when any of the report's invoices is unpaid — by Xero/Zoho's own
  /// status, not the Job List's, which is set by hand and can lag the books.
  bool get _invoiceLineDefault {
    final report = _report;
    if (report == null) return false;
    final invoices = _invoices;
    if (invoices.isEmpty) return report.hasInvoice && !report.invoiceIsPaid;
    return invoices.any((i) => !_invoicePaid(i.link));
  }

  bool get _includeInvoice => _includeInvoiceLine ?? _invoiceLineDefault;

  /// The template in force.
  ///
  /// A single template is unambiguous, so it is treated as chosen without the
  /// user picking it. With a choice, nothing is chosen until they say so — the
  /// wrong wording sent to a client cannot be taken back.
  ///
  /// Derived rather than assigned, so nothing writes state during `build`.
  DistributionReportTemplate? _resolveTemplate(
    List<DistributionReportTemplate> available,
  ) {
    if (available.isEmpty) return null;
    final id =
        _templateId ?? (available.length == 1 ? available.first.id : null);
    if (id == null) return null;
    for (final t in available) {
      if (t.id == id) return t;
    }
    // Deleted or re-ordered while the page was open.
    return null;
  }

  /// The values a template renders against. With [preview], fields still to
  /// fill come out as `‹Label›`, which the preview draws as amber
  /// placeholders; sending is blocked until they are filled.
  DistributionReportValues _values(
    DistributionReportTemplate template, {
    bool preview = false,
  }) {
    String typed(TextEditingController c, String label) {
      final value = c.text.trim();
      return preview && value.isEmpty ? '‹$label›' : value;
    }

    final report = _report!;
    final totals = report.totalsFor(_selectedFolders);
    final base = DistributionReportValues(
      greetingName: typed(_greeting, 'Greeting name'),
      startDate: _formatDate(totals.startDate),
      quantityDistributed:
          DistributionReportFormat.quantity.format(totals.quantityDistributed),
      distributionAreas: DistributionReportFormat.areaList(report.areas),
      mapLink: report.mapLink,
      client: report.client,
      includeInvoiceLine: _includeInvoice,
    );
    if (template.usesFlyerHandouts) {
      final dates = DistributionReportFormat.dateList(
          _handouts.selectedDays.map((d) => d.date));
      return DistributionReportValues(
        greetingName: base.greetingName,
        startDate: base.startDate,
        quantityDistributed: base.quantityDistributed,
        distributionAreas: base.distributionAreas,
        mapLink: base.mapLink,
        client: base.client,
        includeInvoiceLine: base.includeInvoiceLine,
        handoutDates: preview && dates.isEmpty ? '‹Handout dates›' : dates,
      );
    }
    if (!template.usesFlyersAndPosters) return base;

    final leaflet = _leafletReport;
    final poster = _posterReport;
    final leafletTotals = leaflet?.totalsFor(_leafletFolders);
    final posterTotals = poster?.totalsFor(_posterFolders);
    final people = _people();

    return DistributionReportValues(
      greetingName: base.greetingName,
      client: base.client,
      includeInvoiceLine: base.includeInvoiceLine,
      startDate:
          _formatDate(leafletTotals?.startDate ?? posterTotals?.startDate),
      quantityDistributed: _formatQuantity(leafletTotals),
      distributionAreas:
          DistributionReportFormat.areaList((leaflet ?? poster)?.areas ?? []),
      mapLink: leaflet?.mapLink ?? '',
      heading: typed(_heading, 'Heading'),
      leafletName: typed(_leafletName, 'Leaflet name'),
      leafletQuantity: _formatQuantity(leafletTotals),
      leafletDate: _formatDate(leafletTotals?.startDate),
      suburb: typed(_suburb, 'Suburb'),
      leafletDistributorCount: DistributionReportFormat.countOf(
          people.where((p) => p.inLeaflets).length, 'distributor'),
      posterQuantity: _formatQuantity(posterTotals),
      posterDate: _formatDate(posterTotals?.startDate),
      posterDistributorCount: DistributionReportFormat.countOf(
          people.where((p) => p.inPosters).length, 'distributor'),
      posterMapLink: poster?.mapLink ?? '',
      posterPhotosLink: (poster?.shareCode ?? '').isEmpty
          ? (preview ? '‹Photos link›' : '')
          : MapLinkService.buildPhotosUrl(poster!.shareCode),
      people: [
        for (final p in people)
          DistributionReportPerson(name: p.displayName, idNumber: _idFor(p)),
      ],
      hasLeaflets: leaflet != null,
      hasPosters: poster != null,
    );
  }

  static String _formatDate(DateTime? date) =>
      date == null ? '' : DistributionReportFormat.date.format(date);

  static String _formatQuantity(DistributionReportTotals? totals) => totals ==
          null
      ? ''
      : DistributionReportFormat.quantity.format(totals.quantityDistributed);

  // ---------------------------------------------------------------------------
  // Flyers & Posters
  // ---------------------------------------------------------------------------

  DistributionReport? get _leafletReport =>
      _clickedIsPoster ? _otherReport : _report;
  Set<String> get _leafletFolders =>
      _clickedIsPoster ? _otherFolders : _selectedFolders;
  DistributionReport? get _posterReport =>
      _clickedIsPoster ? _report : _otherReport;
  Set<String> get _posterFolders =>
      _clickedIsPoster ? _selectedFolders : _otherFolders;

  /// The suburb follows the leaflet map's areas (the poster map's when there
  /// is no leaflet job) until the user types their own.
  void _prefillSuburb() {
    if (_suburbTouched) return;
    final areas = (_leafletReport ?? _posterReport)?.areas ?? const [];
    _suburb.text = DistributionReportFormat.areaList(areas);
  }

  /// Same-client jobs a month either side of the clicked row, then whatever
  /// else the Job List has loaded — the poster job is normally the former,
  /// but is sometimes booked under a slightly different name.
  Future<void> _loadCandidates() async {
    final item = _item;
    final civil = toScheduleCivil(item.date);
    var sameClient = const <JobListItem>[];
    try {
      sameClient =
          await ref.read(jobListServiceRiverpod).getJobListItemsForClients(
        [item.client],
        [
          DateTime(civil.year, civil.month - 1),
          DateTime(civil.year, civil.month),
          DateTime(civil.year, civil.month + 1),
        ],
      );
    } catch (e) {
      debugPrint('[DistributionReport] candidate lookup failed: $e');
    }
    if (!mounted) return;

    final byId = <String, JobListItem>{
      for (final j in [
        ...sameClient,
        ...ref.read(jobListRiverpod).jobListItems
      ])
        if (j.id != item.id) j.id: j,
    };
    final client = normalizePersonName(item.client);
    int rank(JobListItem j) => normalizePersonName(j.client) == client ? 0 : 1;
    Duration gap(JobListItem j) => j.date.difference(item.date).abs();
    final list = byId.values.toList()
      ..sort((a, b) {
        final byClient = rank(a).compareTo(rank(b));
        return byClient != 0 ? byClient : gap(a).compareTo(gap(b));
      });
    setState(() => _candidates = list.take(80).toList());
  }

  /// [unselected] are folders a restored draft had unticked.
  Future<void> _pickOther(
    String? id, {
    Iterable<String> unselected = const [],
  }) async {
    final job =
        id == null ? null : _candidates?.where((j) => j.id == id).firstOrNull;
    setState(() {
      _otherItem = job;
      _otherReport = null;
      _otherFolders.clear();
      _otherError = null;
      _otherLoading = job != null;
      _prefillSuburb();
    });
    if (job == null) return;

    try {
      final report = await _compileJob(job);
      // Picked something else while this one compiled.
      if (!mounted || _otherItem?.id != job.id) return;
      setState(() {
        _otherReport = report;
        _otherFolders
          ..addAll(report.readableFolders.map((f) => f.path))
          ..removeAll(unselected);
        _otherLoading = false;
        _prefillSuburb();
      });
    } catch (e) {
      if (!mounted || _otherItem?.id != job.id) return;
      setState(() {
        _otherError = 'Could not compile that job: $e';
        _otherLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Flyer handout report
  // ---------------------------------------------------------------------------

  /// Scans the ticked folders when they differ from the last scan's. Called
  /// from build; the scan itself starts after the frame. Waits for the draft,
  /// whose unticked days and photo choices the scan applies.
  void _ensureHandoutScan(bool handoutMode) {
    if (!handoutMode || !_restored) return;
    final folders = _selectedFolders.toList()..sort();
    final key = folders.join('\n');
    if (key == _handoutScanKey) return;
    _handoutScanKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _handoutScanKey == key) _scanHandouts(folders);
    });
  }

  Future<void> _scanHandouts(List<String> folders) {
    final scan = widget.scanHandouts;
    if (scan != null) return scan(_handouts, folders);
    return _handouts.scanFolders(
      folders,
      distributors: ref.read(distributorRiverpod).distributors,
      keepChoices: true,
    );
  }

  void _rescanHandouts() => setState(() => _handoutScanKey = null);

  String get _handoutPdfName {
    final client = _item.client.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    return '${client.isEmpty ? 'Flyer' : client} - Flyer handout report.pdf';
  }

  /// Builds the PDF for the ticked days — the check of where everyone
  /// worked comes up first — and puts it with the attachments.
  Future<void> _buildHandoutPdf() async {
    final report = _handouts;
    if (report.isGenerating || report.selectedDays.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final built = await generateHandoutReport(context, ref, report);
      if (built == null || !mounted) return;
      setState(() {
        _handoutPdf = _Attachment(
          key: 'handout-pdf',
          name: _handoutPdfName,
          mimeType: 'application/pdf',
          bytes: built.bytes,
        );
        _handoutPdfRevision = report.revision;
      });
      if (built.mapsMissing > 0) {
        messenger.showToast(SnackBar(
          content: Text('${built.mapsMissing} of ${built.maps} street maps '
              "couldn't load — those routes print on a plain background. "
              'Build again to retry.'),
          duration: const Duration(seconds: 8),
        ));
      }
    } catch (e) {
      messenger.showToast(SnackBar(
        content: Text('Could not build the PDF: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _previewHandoutPdf() {
    final pdf = _handoutPdf?.bytes;
    if (pdf == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TEReportPreviewPage(pdfBytes: pdf),
    ));
  }

  // ---------------------------------------------------------------------------
  // Saved progress
  // ---------------------------------------------------------------------------

  Future<DistributionReportDraft?> _loadDraft() async {
    try {
      return await _drafts.load(_item.id);
    } catch (e) {
      debugPrint('[DistributionReport] draft load failed: $e');
      return null;
    }
  }

  /// Put a saved draft back, once the report it belongs to has compiled.
  Future<void> _restoreDraft() async {
    if (_restored) return; // A retry after an error compiles again.
    final draft = await _draftLoad;
    if (!mounted) return;

    if (draft != null) {
      setState(() {
        _templateId = draft.templateId;
        _greeting.text = draft.greeting;
        if (draft.subject.trim().isNotEmpty &&
            !_isOldGeneratedSubject(draft.subject)) {
          _subject.text = draft.subject;
        } else {
          _followTemplateSubject(
              ref.read(distributionReportTemplateRiverpod).available,
              draft.templateId);
        }
        _heading.text = draft.heading;
        _leafletName.text = draft.leafletName;
        _suburbTouched = draft.suburbTouched;
        if (draft.suburbTouched) _suburb.text = draft.suburb;
        _clickedIsPoster = draft.clickedIsPoster;
        _selectedFolders.removeAll(draft.unselectedFolders);
        _includeInvoiceLine = draft.includeInvoiceLine;
        if (draft.writeBackQuantity != null) {
          _writeBackQuantity = draft.writeBackQuantity!;
        }
        _pickedDistributor.addAll(draft.pickedDistributor);
        _typedIds.addAll(draft.typedIds);
        _removedPeople.addAll(draft.removedPeople);
        _invoiceChoices.addAll(draft.invoiceChoices);
        _invoicesWithPersonnel.addAll(draft.invoicesWithPersonnel);
        _handouts.restoreChoices(
          unselected: draft.handoutUnselectedDays.toSet(),
          where: draft.handoutWhere,
          links: draft.handoutLinks,
          chosenPhotos: draft.handoutChosenPhotos.toSet(),
          photoDates: {
            for (final MapEntry(key: path, value: day)
                in draft.handoutPhotoDates.entries)
              if (DateTime.tryParse(day) case final date?) path: date,
          },
        );
        _prefillSuburb();
        _saveState = _SaveState.saved;
        _savedAt = draft.updatedAt;
      });

      final otherId = draft.otherJobId;
      if (otherId != null) {
        await _candidatesLoad;
        if (!mounted) return;
        if (_candidates?.any((j) => j.id == otherId) ?? false) {
          await _pickOther(otherId, unselected: draft.otherUnselectedFolders);
        } else {
          setState(() => _otherError =
              'The job paired in your saved draft is no longer in the list. '
                  'Choose it again.');
        }
      }
    }

    if (!mounted) return;
    _savedJson = jsonEncode(_currentDraft().toContentMap());
    _restored = true;
  }

  DistributionReportDraft _currentDraft() {
    List<String> unticked(DistributionReport? report, Set<String> ticked) => [
          for (final f in report?.readableFolders ?? const [])
            if (!ticked.contains(f.path)) f.path,
        ];

    return DistributionReportDraft(
      jobId: _item.id,
      templateId: _templateId,
      greeting: _greeting.text,
      subject: _subject.text,
      heading: _heading.text,
      leafletName: _leafletName.text,
      suburb: _suburb.text,
      suburbTouched: _suburbTouched,
      clickedIsPoster: _clickedIsPoster,
      otherJobId: _otherItem?.id,
      unselectedFolders: unticked(_report, _selectedFolders),
      otherUnselectedFolders: unticked(_otherReport, _otherFolders),
      includeInvoiceLine: _includeInvoiceLine,
      writeBackQuantity: _writeBackQuantity,
      pickedDistributor: Map.of(_pickedDistributor),
      typedIds: Map.of(_typedIds),
      removedPeople: _removedPeople.toList(),
      invoiceChoices: Map.of(_invoiceChoices),
      invoicesWithPersonnel: _invoicesWithPersonnel.toList(),
      handoutUnselectedDays: _handouts.unselectedKeys.toList(),
      handoutWhere: _handouts.whereOverrides,
      handoutLinks: _handouts.mapLinkOverrides,
      handoutChosenPhotos: _handouts.chosenPhotoPaths.toList(),
      handoutPhotoDates: {
        for (final MapEntry(key: path, value: date)
            in _handouts.photoDates.entries)
          path: DateFormat('yyyy-MM-dd').format(date),
      },
    );
  }

  /// Called from every build: saves a moment after the content last changed.
  /// Typing a word is one save, not one per letter.
  void _scheduleSave() {
    if (!_restored) return;
    final draft = _currentDraft();
    final json = jsonEncode(draft.toContentMap());
    if (json == _savedJson || json == _inFlightJson || json == _pendingJson) {
      return;
    }
    _pendingDraft = draft;
    _pendingJson = json;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _flushSave);
  }

  Future<void> _flushSave() async {
    final draft = _pendingDraft;
    final json = _pendingJson;
    if (draft == null || json == null) return;
    _pendingDraft = null;
    _pendingJson = null;
    _inFlightJson = json;
    if (mounted) setState(() => _saveState = _SaveState.saving);
    try {
      await _drafts.save(draft);
      _savedJson = json;
      if (mounted) {
        setState(() {
          _saveState = _SaveState.saved;
          _savedAt = DateTime.now();
        });
      }
    } catch (e) {
      debugPrint('[DistributionReport] draft save failed: $e');
      if (mounted) setState(() => _saveState = _SaveState.failed);
    } finally {
      if (_inFlightJson == json) _inFlightJson = null;
    }
  }

  /// Delete the saved draft and reopen the page fresh.
  Future<void> _startOver() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text(
          'This deletes the saved draft for this report — what you typed, '
          'the paired job and your choices. The compiled figures are read '
          'fresh either way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start over'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Stop saving first, or a pending save would recreate the draft.
    _restored = false;
    _saveTimer?.cancel();
    _pendingDraft = null;
    try {
      await _drafts.delete(_item.id);
    } catch (e) {
      debugPrint('[DistributionReport] draft delete failed: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => DistributionReportPage(
        item: _item,
        compileJob: widget.compileJob,
        editJob: widget.editJob,
        scanHandouts: widget.scanHandouts,
      ),
    ));
  }

  /// "Draft saved 14:05", or what went wrong — shown under the title.
  String? get _saveLabel {
    switch (_saveState) {
      case _SaveState.none:
        return null;
      case _SaveState.saving:
        return 'Saving…';
      case _SaveState.failed:
        return 'Couldn\'t save draft';
      case _SaveState.saved:
        final at = _savedAt;
        if (at == null) return 'Draft saved';
        final now = DateTime.now();
        final today =
            at.year == now.year && at.month == now.month && at.day == now.day;
        return 'Draft saved ${DateFormat(today ? 'HH:mm' : 'd MMM, HH:mm').format(at)}';
    }
  }

  /// Everyone named in the selected folders' file names, matched to a
  /// distributor, one row each.
  ///
  /// Names equal to either job's client are dropped: Track Editor files saved
  /// without a distributor carry the client in that position.
  List<_PersonRow> _people({bool includeRemoved = false}) {
    final distributors = ref.read(distributorRiverpod).distributors;
    final clients = {
      for (final r in [_report, _otherReport])
        if (r != null) normalizePersonName(r.client),
    };
    final rows = <String, _PersonRow>{};

    void add(DistributionReport? report, Set<String> folders,
        {required bool leaflets}) {
      if (report == null) return;
      for (final name in report.totalsFor(folders).workerNames) {
        if (clients.contains(normalizePersonName(name))) continue;
        final picked = _pickedDistributor[name.toLowerCase()];
        final distributor = picked != null
            ? distributors.where((d) => d.id == picked).firstOrNull
            : matchDistributor(name, distributors);
        final key = distributor?.id ?? 'name:${name.toLowerCase()}';
        final row = rows.putIfAbsent(key, () => _PersonRow(key, distributor));
        row.fileNames.add(name);
        if (leaflets) {
          row.inLeaflets = true;
        } else {
          row.inPosters = true;
        }
      }
    }

    add(_leafletReport, _leafletFolders, leaflets: true);
    add(_posterReport, _posterFolders, leaflets: false);
    return rows.values
        .where((r) => includeRemoved || !_removedPeople.contains(r.key))
        .toList();
  }

  String _idFor(_PersonRow row) =>
      _typedIds[row.key] ?? row.distributor?.idNumber?.trim() ?? '';

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _maybeWriteBackQuantity() async {
    final report = _report;
    if (report == null || !_writeBackQuantity) return;

    final totals = report.totalsFor(_selectedFolders);
    if (totals.quantityDistributed == _item.quantityDistributed) return;

    try {
      await ref.read(jobListRiverpod).updateJobListItemWithTracking(
            _item,
            _item.copyWith(quantityDistributed: totals.quantityDistributed),
          );
    } catch (e) {
      debugPrint('[DistributionReport] quantity write-back failed: $e');
    }
  }

  /// [html] is set for templates whose table only survives as HTML.
  Future<void> _copy(String body, String? html) async {
    final rich =
        html != null && await copyRichText(html: html, plainText: body);
    if (html == null) await Clipboard.setData(ClipboardData(text: body));
    await _maybeWriteBackQuantity();
    if (!mounted) return;
    _close(rich
        ? 'Formatted report copied — paste it into your email.'
        : 'Report copied to clipboard.');
  }

  // ---------------------------------------------------------------------------
  // Attachments
  // ---------------------------------------------------------------------------

  /// Every invoice on the report's jobs — the paired job's too — with the job
  /// it belongs to, which decides the Zoho organisation.
  List<({JobInvoiceLink link, JobListItem job})> get _invoices {
    final seen = <String>{};
    return [
      for (final job in [_item, if (_otherItem != null) _otherItem!])
        for (final link in job.allInvoices)
          if (link.invoiceId.isNotEmpty && seen.add(link.invoiceId))
            (link: link, job: job),
    ];
  }

  /// The invoice's status as Xero/Zoho holds it now, read with the invoice
  /// itself. Until that arrives (or if it cannot be read) the status stored
  /// on the job stands in.
  String _liveStatus(JobInvoiceLink link) {
    final detail = _invoiceDetails[link.invoiceId];
    return detail?.xero?.status.apiValue ??
        detail?.zoho?.status.apiValue ??
        link.status;
  }

  bool _invoicePaid(JobInvoiceLink link) =>
      isInvoiceStatusPaid(link.providerId, _liveStatus(link));

  /// Unpaid invoices go with the email unless unticked; paid ones only if
  /// ticked.
  bool _invoiceAttached(JobInvoiceLink link) =>
      _invoiceChoices[link.invoiceId] ?? !_invoicePaid(link);

  /// The PDF for [link], fetched the first time it is asked for.
  _Attachment _invoiceFile(JobInvoiceLink link, JobListItem job) {
    return _invoiceFiles.putIfAbsent(link.invoiceId, () {
      final file = _Attachment(
        key: 'inv:${link.invoiceId}',
        name: _invoiceAttachmentName(link, job),
        mimeType: 'application/pdf',
        invoice: link,
        job: job,
      );
      file.load = _fetchInvoice(file, link, job);
      return file;
    });
  }

  Future<void> _fetchInvoice(
      _Attachment file, JobInvoiceLink link, JobListItem job) async {
    try {
      final bytes = link.providerId == 'xero'
          ? await ref
              .read(xeroAccountingServiceRiverpod)
              .getInvoicePdf(link.invoiceId)
          : await ref
              .read(zohoInvoicesRiverpod(ZohoOrg.forJob(job)))
              .getInvoicePdf(link.invoiceId);
      if (!mounted) return;
      setState(() {
        file.bytes = bytes;
        file.error = null;
      });
    } catch (e) {
      debugPrint('[DistributionReport] invoice PDF failed: $e');
      if (!mounted) return;
      setState(() => file.error = 'Could not fetch the PDF from '
          '${link.providerId == 'xero' ? 'Xero' : 'Zoho'}.');
    }
  }

  void _retryInvoice(_Attachment file) {
    final match =
        _invoices.where((i) => i.link.invoiceId == file.invoice?.invoiceId);
    if (match.isEmpty) return;
    setState(() => file.error = null);
    file.load = _fetchInvoice(file, match.first.link, match.first.job);
  }

  /// What goes with the email right now: the handout report PDF, then
  /// invoices, then added files.
  List<_Attachment> get _attachments => [
        if (gmailDraftsAvailable && _handoutPdf != null && _handoutMode)
          _handoutPdf!,
        if (gmailDraftsAvailable)
          for (final i in _invoices)
            if (_invoiceAttached(i.link)) _invoiceFile(i.link, i.job),
        ..._addedFiles,
      ];

  int get _attachmentBytes =>
      _attachments.fold(0, (sum, a) => sum + (a.bytes?.length ?? 0));

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    await _addFiles([
      for (final f in result.files)
        if (f.bytes != null)
          LocalUploadFile(
            relativePath: f.name,
            size: f.size,
            read: () async => f.bytes!,
          ),
    ]);
  }

  Future<void> _addFiles(List<LocalUploadFile> files) async {
    for (final f in files) {
      try {
        final bytes = await f.read();
        if (!mounted) return;
        setState(() => _addedFiles.add(_Attachment(
              key: 'file:${_fileSeq++}',
              name: f.name,
              mimeType: CloudFileManagerProvider.contentTypeFor(f.name) ??
                  'application/octet-stream',
              bytes: bytes,
            )));
      } catch (e) {
        debugPrint('[DistributionReport] could not read ${f.name}: $e');
      }
    }
  }

  /// Open [job] in the Job List's edit flow — job details and its invoice
  /// section — then re-read it.
  Future<void> _editJob(JobListItem job) async {
    final editJob = widget.editJob;
    if (editJob == null) return;
    final saved = await editJob(context, job);
    if (saved && mounted) await _refreshJobs();
  }

  /// Re-read the jobs after an edit, and drop invoice PDFs fetched before
  /// it so the attachments are the invoices as they are now.
  Future<void> _refreshJobs() async {
    final service = ref.read(jobListServiceRiverpod);
    Future<JobListItem?> reread(JobListItem job) async {
      try {
        return await service.getJobListItemById(job.id, job.date);
      } catch (e) {
        debugPrint('[DistributionReport] re-read ${job.id} failed: $e');
        return null;
      }
    }

    final item = await reread(_item);
    final other = _otherItem == null ? null : await reread(_otherItem!);
    if (!mounted) return;
    setState(() {
      // Not found means it moved month; the copy here stays as it was.
      if (item != null) _item = item;
      if (other != null) _otherItem = other;
      _invoiceFiles.clear();
    });
  }

  /// Whether Zoho/Xero would accept changes: not once paid or voided.
  bool _invoiceEditable(JobInvoiceLink link) {
    final status = _liveStatus(link).toLowerCase();
    return !_invoicePaid(link) &&
        status != 'void' &&
        status != 'voided' &&
        status != 'deleted';
  }

  String _invoiceAttachmentName(JobInvoiceLink link, JobListItem job) =>
      reportInvoiceFileName(link, job,
          customerName: _invoiceDetails[link.invoiceId]?.customerName);

  /// The invoice in full, loaded the first time it is asked for.
  _InvoiceDetail _invoiceDetail(JobInvoiceLink link, JobListItem job) {
    return _invoiceDetails.putIfAbsent(link.invoiceId, () {
      final detail = _InvoiceDetail(orgId: ZohoOrg.forJob(job));
      detail.load = _fetchDetail(detail, link, job);
      return detail;
    });
  }

  Future<void> _fetchDetail(
      _InvoiceDetail detail, JobInvoiceLink link, JobListItem job) async {
    // Started from build; nothing below may run (or fail, and set state)
    // until the build has finished.
    await Future<void>.value();
    try {
      if (link.providerId == 'xero') {
        final invoice = await ref
            .read(xeroAccountingServiceRiverpod)
            .getInvoice(link.invoiceId);
        if (!mounted) return;
        setState(() => detail.xero = invoice);
      } else {
        final invoice = await ref
            .read(zohoInvoicesRiverpod(detail.orgId))
            .getInvoiceForCopy(link.invoiceId);
        if (!mounted) return;
        setState(() => detail.zoho = invoice);
      }
      if (!mounted) return;
      setState(() {
        detail.error = null;
        // The PDF can now be named after the customer as the books have it.
        _invoiceFiles[link.invoiceId]?.name = _invoiceAttachmentName(link, job);
      });
    } catch (e) {
      debugPrint('[DistributionReport] invoice load failed: $e');
      if (!mounted) return;
      setState(() => detail.error = 'Could not load ${link.invoiceNumber} '
          'from ${link.providerId == 'xero' ? 'Xero' : 'Zoho'}.');
    }
  }

  void _retryDetail(JobInvoiceLink link, JobListItem job) {
    final detail = _invoiceDetails[link.invoiceId];
    if (detail == null) return;
    setState(() => detail.error = null);
    detail.load = _fetchDetail(detail, link, job);
  }

  /// Write the personnel's legal names and IDs into the lines in the invoice
  /// editor. Nothing is saved until the editor's Save.
  void _addPersonnelInEditor(JobInvoiceLink link) {
    final people = _people();
    final leaflets = [
      for (final p in people)
        if (p.inLeaflets)
          DistributionReportPerson(name: p.displayName, idNumber: _idFor(p)),
    ];
    final posters = [
      for (final p in people)
        if (p.inPosters)
          DistributionReportPerson(name: p.displayName, idNumber: _idFor(p)),
    ];
    List<DistributionReportPerson> forLine(String text) =>
        personnelForLine(lineText: text, leaflets: leaflets, posters: posters);

    final state = _invoiceDetails[link.invoiceId]?.editorKey.currentState;
    if (state is XeroInvoiceEditorState) {
      state.rewriteDescriptions((description) =>
          withPersonnelBlock(description, forLine(description)));
    } else if (state is ZohoInvoiceEditorState) {
      state.rewriteDescriptions((name, description) =>
          withPersonnelBlock(description, forLine('$name $description')));
    } else {
      return;
    }
    setState(() => _personnelUnsaved.add(link.invoiceId));
  }

  /// After the editor saved to Xero/Zoho: keep the job in step with its
  /// invoice, and attach the invoice as it now is.
  Future<void> _onInvoiceSaved(
    JobInvoiceLink link,
    JobListItem job, {
    XeroInvoice? xero,
    ZohoInvoice? zoho,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final detail = _invoiceDetails[link.invoiceId];
    setState(() {
      if (detail != null) {
        if (xero != null) detail.xero = xero;
        if (zoho != null) detail.zoho = zoho;
        // A fresh editor from the saved invoice — new lines now carry the ids
        // Xero/Zoho gave them, and a second save amends rather than recreates.
        detail.editorKey = GlobalKey();
      }
      if (_personnelUnsaved.remove(link.invoiceId)) {
        _invoicesWithPersonnel.add(link.invoiceId);
      }
      _invoiceFiles.remove(link.invoiceId);
    });

    final relinkError = await _relinkJob(link, job, xero: xero, zoho: zoho);
    await _refreshJobs();
    if (!mounted) return;
    final where = xero != null ? 'Xero' : 'Zoho';
    messenger.showToast(SnackBar(
      content: Text(relinkError == null
          ? '${link.invoiceNumber} saved to $where and the job updated.'
          : '${link.invoiceNumber} saved to $where, but the job\'s amount '
              'could not be updated: $relinkError'),
      backgroundColor: relinkError == null ? null : Colors.orange.shade800,
    ));
  }

  /// Write the saved invoice's number, status and totals onto its job — the
  /// same links the invoicing flows make, so the Job List's amount matches
  /// what was billed once lines change here. Returns an error, or null.
  Future<String?> _relinkJob(
    JobInvoiceLink link,
    JobListItem job, {
    XeroInvoice? xero,
    ZohoInvoice? zoho,
  }) async {
    final service = ref.read(jobListServiceRiverpod);
    try {
      if (!link.isPrimary) {
        await service.linkSplitInvoiceTxn(
          jobId: job.id,
          date: job.date,
          link: JobInvoiceLink(
            providerId: link.providerId,
            contactId: link.contactId,
            contactName:
                xero?.contactName ?? zoho?.customerName ?? link.contactName,
            invoiceId: link.invoiceId,
            invoiceNumber: xero?.invoiceNumber ??
                zoho?.invoiceNumber ??
                link.invoiceNumber,
            status:
                xero?.status.apiValue ?? zoho?.status.apiValue ?? link.status,
            subTotal: xero?.subTotal ?? zoho?.subTotal ?? link.subTotal,
            total: xero?.total ?? zoho?.total ?? link.total,
            syncedAt: DateTime.now(),
          ),
        );
      } else if (xero != null) {
        await service.linkAccountingInvoiceTxn(
          jobId: job.id,
          date: job.date,
          providerId: 'xero',
          contactId: xero.contactId,
          invoiceId: xero.invoiceId,
          invoiceNumber: xero.invoiceNumber,
          invoiceStatus: xero.status.apiValue,
          subTotal: xero.subTotal,
          total: xero.total,
        );
      } else if (zoho != null) {
        if (job.accountingInvoiceId == zoho.invoiceId) {
          await service.linkAccountingInvoiceTxn(
            jobId: job.id,
            date: job.date,
            providerId: 'zoho',
            contactId: zoho.customerId,
            invoiceId: zoho.invoiceId,
            invoiceNumber: zoho.invoiceNumber,
            invoiceStatus: zoho.status.apiValue,
            subTotal: zoho.subTotal,
            total: zoho.total,
          );
        } else {
          await service.linkZohoInvoiceTxn(
            jobId: job.id,
            date: job.date,
            zohoContactId: zoho.customerId,
            zohoInvoiceId: zoho.invoiceId,
            zohoInvoiceNumber: zoho.invoiceNumber,
            zohoInvoiceStatus: zoho.status.apiValue,
            amount: zoho.subTotal,
          );
        }
      }
      return null;
    } catch (e) {
      debugPrint('[DistributionReport] job relink failed: $e');
      return '$e';
    }
  }

  /// Only the page on top takes dropped files — not one under a dialog.
  bool get _acceptsDrops =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  /// Send by Gmail. Where Gmail drafts are set up, the draft is created
  /// through the Gmail API with the HTML body — real table, links — and
  /// opened; otherwise, or if that fails, a draft link carries the plain text.
  Future<void> _openGmail(String body, String html,
      {required bool richCopy}) async {
    final report = _report!;

    // Captured before the first await: this page closes partway through, so
    // its context is gone by the time the result needs reporting.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final subject = _subject.text.trim();

    String? fallbackReason;
    final attachments = _attachments;
    if (gmailDraftsAvailable) {
      try {
        // Permission first, before anything slow is awaited: Google's popup
        // only opens straight after the click.
        await ensureGmailAccess();

        // Invoice PDFs normally arrived while the page was open; wait for any
        // still on their way, and for the invoices themselves, whose customer
        // name the PDFs are named after.
        await Future.wait([
          for (final a in attachments)
            if (a.bytes == null && a.load != null) a.load!,
          for (final a in attachments)
            if (a.invoice != null && a.job != null)
              _invoiceDetail(a.invoice!, a.job!).load ?? Future.value(),
        ]);
        for (final a in attachments) {
          if (a.invoice != null && a.job != null) {
            a.name = _invoiceAttachmentName(a.invoice!, a.job!);
          }
        }
        final missing = attachments.where((a) => a.bytes == null).toList();
        if (missing.isNotEmpty) {
          // Sending without the invoice the email says is attached would be
          // worse than not sending yet.
          messenger.showToast(SnackBar(
            content:
                Text('Could not get ${missing.map((a) => a.name).join(', ')}'
                    ' — retry it, or untick it, then send again.'),
            backgroundColor: Colors.red,
          ));
          return;
        }

        final draftUrl = await createGmailDraft(
          to: report.recipients,
          subject: subject,
          text: body,
          html: html,
          attachments: [
            for (final a in attachments)
              GmailAttachment(
                  name: a.name, mimeType: a.mimeType, bytes: a.bytes!),
          ],
        );
        await _maybeWriteBackQuantity();
        navigator.pop();
        final opened = await launchUrl(draftUrl, webOnlyWindowName: '_blank');
        messenger.showToast(SnackBar(
          content: Text('Draft created in Gmail'
              '${attachments.isEmpty ? '' : ' with ${_plural(attachments.length, 'attachment')}'}'
              '${opened ? ' and opened in a new tab.' : ' — it is in your Drafts.'}'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Open draft',
            onPressed: () => launchUrl(draftUrl, webOnlyWindowName: '_blank'),
          ),
        ));
        return;
      } on GmailDraftException catch (e) {
        if (e.cancelled) {
          // Stay on the page; nothing was created and nothing is lost.
          messenger.showToast(const SnackBar(
            content: Text('Gmail permission not given — no draft was made.'),
          ));
          return;
        }
        fallbackReason = e.message;
      } catch (e) {
        fallbackReason = '$e';
      }
    }

    // A copy on the clipboard too — the formatted one when the report has a
    // table — for when the draft link is too long, or to paste over the
    // plain-text table.
    final rich = richCopy && await copyRichText(html: html, plainText: body);
    if (!richCopy) await Clipboard.setData(ClipboardData(text: body));
    final url = buildGmailComposeUrl(
      to: report.recipients,
      subject: subject,
      body: body,
    );
    await _maybeWriteBackQuantity();

    navigator.pop();

    try {
      final ok = await launchUrl(url.uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showToast(const SnackBar(
          content: Text('Could not open Gmail. The report is on your '
              'clipboard.'),
          backgroundColor: Colors.red,
        ));
        return;
      }
      if (fallbackReason != null) {
        messenger.showToast(SnackBar(
          content: Text('Could not create the draft with its table '
              '($fallbackReason). Opened a plain-text draft instead'
              '${rich ? ' — the formatted copy is on your clipboard' : ''}'
              '${attachments.isEmpty ? '' : '. Attach the files yourself'}.'),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 10),
        ));
        return;
      }
      messenger.showToast(SnackBar(
        content: Text(!url.bodyIncluded
            ? 'Report too long for the draft URL — paste it into the '
                'draft (it is on your clipboard).'
            : rich
                ? 'Gmail draft opened with the report. A copy with a '
                    'bordered table is on your clipboard to paste over it.'
                : 'Gmail draft opened. Report also copied to your clipboard.'),
        backgroundColor: url.bodyIncluded ? null : Colors.orange.shade800,
        duration: Duration(seconds: rich ? 8 : 4),
      ));
    } catch (e) {
      messenger.showToast(SnackBar(
        content: Text('Could not open Gmail: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _close(String message) {
    // Messenger resolved before the pop: afterwards this page's context is
    // defunct and the snackbar would have nowhere to land.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showToast(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Readiness
  // ---------------------------------------------------------------------------

  /// What stands between the report and sending it. Blocking checks disable
  /// the send buttons; the rest are worth a look but do not stop it.
  List<_Check> _checks(DistributionReportTemplate? template) {
    final report = _report!;
    final checks = <_Check>[];

    if (template == null) {
      checks.add(_Check('Choose a template', focus: _templateFocus));
    }
    if (_greeting.text.trim().isEmpty) {
      checks.add(_Check('Type the greeting name', focus: _greetingFocus));
    }

    if (template?.usesFlyersAndPosters ?? false) {
      if (_otherLoading) checks.add(const _Check('Compiling the other job…'));
      if (_heading.text.trim().isEmpty) {
        checks.add(_Check('Type a heading', focus: _headingFocus));
      }
      if (_leafletReport != null && _leafletName.text.trim().isEmpty) {
        checks.add(_Check('Type the leaflet name', focus: _leafletNameFocus));
      }
      if (_suburb.text.trim().isEmpty) {
        checks.add(_Check('Type the suburb or area', focus: _suburbFocus));
      }
      final poster = _posterReport;
      if (poster != null && poster.shareCode.isEmpty) {
        checks.add(const _Check(
            'Link a shared map to the poster job — its map and photos '
            'links need one'));
      }

      final people = _people();
      if (people.isEmpty) {
        checks.add(const _Check('No distributors found in the file names',
            blocking: false));
      }
      final missingIds = people.where((p) => _idFor(p).isEmpty).length;
      if (missingIds > 0) {
        checks.add(_Check(
            '${_plural(missingIds, 'ID')} missing from the distributors table',
            blocking: false));
      }
      final unmatched = people.where((p) => p.distributor == null).length;
      if (unmatched > 0) {
        checks.add(_Check(
            '${_plural(unmatched, 'name')} not matched to a distributor',
            blocking: false));
      }
      for (final i in _invoices) {
        if (_personnelUnsaved.contains(i.link.invoiceId)) {
          // Sending now would attach the invoice without them.
          checks.add(_Check('Save ${i.link.invoiceNumber} — the personnel '
              'added to its lines are not saved yet'));
        } else if (people.isNotEmpty &&
            _invoiceEditable(i.link) &&
            !_invoicesWithPersonnel.contains(i.link.invoiceId)) {
          checks.add(_Check(
              'Add the personnel to ${i.link.invoiceNumber} '
              '— see Invoice, under the email',
              blocking: false));
        }
      }
      checks.addAll(_invoiceDateChecks(_flyersAndPostersWorkDates()));
      final posterTotals = poster?.totalsFor(_posterFolders);
      if (posterTotals != null && posterTotals.photoCount == 0) {
        // The email links the client to the photos page; an empty one is the
        // first thing they would see.
        checks.add(const _Check(
            'No photos in the poster folder — upload them in Cloud Files, '
            'then press Check again on the poster job'));
      } else if (posterTotals != null &&
          posterTotals.photoCount != posterTotals.quantityDistributed) {
        checks.add(_Check(
            '${_plural(posterTotals.quantityDistributed, 'poster')} but '
            '${_plural(posterTotals.photoCount, 'photo')} found',
            blocking: false));
      }
    }

    if (template?.usesFlyerHandouts ?? false) checks.addAll(_handoutChecks());

    if (report.recipients.isEmpty) {
      checks.add(const _Check(
          'No Report Addresses on this job — add recipients in Gmail',
          blocking: false));
    }
    final totals = report.totalsFor(_selectedFolders);
    if (!totals.dateSource.isMeasured) {
      checks.add(
          _Check('Date taken ${totals.dateSource.label}', blocking: false));
    }
    if (report.folders.any((f) => f.error != null)) {
      checks.add(
          const _Check('A cloud folder could not be read', blocking: false));
    }
    for (final i in _invoices) {
      final detail = _invoiceDetails[i.link.invoiceId];
      final books = i.link.providerId == 'xero' ? 'Xero' : 'Zoho';
      if (detail != null && detail.error != null) {
        checks.add(_Check(
            'Could not read ${i.link.invoiceNumber} from $books — its paid '
            'status is taken from the Job List',
            blocking: false));
      } else if (detail == null || !detail.loaded) {
        // What is attached, and whether the email says so, both follow the
        // books' status — wait the moment it takes to read it.
        checks.add(
            _Check('Checking ${i.link.invoiceNumber}\'s status with $books…'));
      }
    }

    if (gmailDraftsAvailable) {
      final attachments = _attachments;
      for (final a in attachments.where((a) => a.error != null)) {
        checks.add(_Check('${a.name}: ${a.error} Retry it or untick it'));
      }
      final bytes = _attachmentBytes;
      if (bytes > kGmailAttachmentLimitBytes) {
        checks.add(_Check('Attachments come to ${formatBytes(bytes)} — Gmail '
            'takes up to ${formatBytes(kGmailAttachmentLimitBytes)}'));
      }
      if (_includeInvoice &&
          _invoices.isNotEmpty &&
          !attachments.any((a) => a.invoice != null)) {
        checks.add(const _Check(
            'The email says the invoice is attached, but none is ticked',
            blocking: false));
      }
    } else if (_includeInvoice) {
      checks.add(const _Check('Attach the invoice PDF in Gmail yourself',
          blocking: false));
    }
    return checks;
  }

  /// The days the leaflets and posters went out: each ticked folder's date
  /// from its track times, or the job's own date when no folder has one.
  List<DateTime> _flyersAndPostersWorkDates() {
    final dates = <DateTime>{};
    for (final (report, ticked) in [
      (_leafletReport, _leafletFolders),
      (_posterReport, _posterFolders),
    ]) {
      if (report == null) continue;
      final measured = [
        for (final f in report.folders)
          if (f.error == null &&
              ticked.contains(f.path) &&
              f.dateSource.isMeasured &&
              f.date != null)
            f.date!,
      ];
      final startDate = report.totalsFor(ticked).startDate;
      dates.addAll(measured.isNotEmpty
          ? measured
          : [if (startDate != null) startDate]);
    }
    return dates.toList();
  }

  /// Invoices are usually made by copying the client's last one, and a date
  /// left in a line description from it is easy to miss: flag any date in
  /// the saved lines that isn't a day the work was done.
  List<_Check> _invoiceDateChecks(List<DateTime> workDates) {
    if (workDates.isEmpty) return const [];
    final checks = <_Check>[];
    for (final i in _invoices) {
      final detail = _invoiceDetails[i.link.invoiceId];
      final lines = [
        for (final l in detail?.xero?.lineItems ?? const <XeroLineItem>[])
          l.description,
        for (final l in detail?.zoho?.lineItems ?? const <ZohoLineItem>[])
          '${l.name}\n${l.description}',
      ];
      final wrong = <String>{
        for (final line in lines)
          for (final d in invoiceDatesOutside(line, workDates)) d.text,
      };
      if (wrong.isEmpty) continue;
      checks.add(_Check(
          '${i.link.invoiceNumber} says ${wrong.join(', ')}, but the '
          'distribution was on ${DistributionReportFormat.dateList(workDates)} '
          '— check the dates in its description, under Invoice',
          blocking: false));
    }
    return checks;
  }

  List<_Check> _handoutChecks() {
    final h = _handouts;
    switch (h.status) {
      case TEReportScanStatus.idle:
      case TEReportScanStatus.scanning:
        return [
          _Check(h.scanStatus ?? 'Scanning the folders for tracks and photos…')
        ];
      case TEReportScanStatus.error:
        return [_Check(h.errorMessage ?? 'Could not scan the folders')];
      case TEReportScanStatus.done:
        break;
    }
    final checks = <_Check>[];
    if (h.days.isEmpty) {
      checks.add(const _Check('No promoter tracks found in the ticked folders'));
    } else if (h.selectedDays.isEmpty) {
      checks.add(const _Check('Tick at least one promoter day'));
    } else if (h.isGenerating) {
      checks.add(_Check(h.generateStatus ?? 'Building the PDF…'));
    } else if (_handoutPdf == null) {
      checks.add(const _Check('Build the PDF — under Promoter days'));
    } else if (_handoutPdfStale) {
      checks.add(const _Check(
          'The days or photos changed since the PDF was built — build it '
          'again'));
    }
    if (h.undatedPhotos.isNotEmpty) {
      checks.add(_Check(
          '${_plural(h.undatedPhotos.length, 'photo')} with no date — left '
          'out of the PDF',
          blocking: false));
    }
    if (h.days.isNotEmpty && h.photoCount == 0) {
      checks.add(_Check(
          h.availablePhotoCount == 0
              ? 'No photos in the report'
              : 'No photos chosen — ${_plural(h.availablePhotoCount, 'photo')} '
                  'to choose from',
          blocking: false));
    }
    if (h.unresolved.isNotEmpty) {
      checks.add(_Check(
          "${_plural(h.unresolved.length, 'track file')} couldn't be put on a "
          'promoter day',
          blocking: false));
    }
    if (!gmailDraftsAvailable && _handoutPdf != null) {
      checks.add(const _Check(
          'Attach the PDF in Gmail yourself — Preview it to download',
          blocking: false));
    }
    return checks;
  }

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  /// Jump to the field a check is about, switching to the Setup tab first
  /// on a narrow screen.
  void _goTo(FocusNode node) {
    if (_tabs.index != 0) {
      _tabs.animateTo(0);
      Future.delayed(kTabScrollDuration, () {
        if (mounted) node.requestFocus();
      });
    } else {
      node.requestFocus();
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  static const double _wideBreakpoint = 1080;
  static final DateFormat _shortDate = DateFormat('d MMM yyyy');
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    // Recognisers from the last preview; a new set is made each build.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    _scheduleSave();

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= _wideBreakpoint;
      final report = _report;
      final ready =
          !_loading && _compileError == null && report != null && report.hasMap;

      final available = ref.watch(distributionReportTemplateRiverpod).available;
      final template = ready ? _resolveTemplate(available) : null;
      _ensureHandoutScan(template?.usesFlyerHandouts ?? false);
      if (ready) {
        // Read every invoice from the books up front — its live status
        // decides what is attached, wherever the panel is on screen.
        for (final i in _invoices) {
          _invoiceDetail(i.link, i.job);
        }
      }
      final checks = ready ? _checks(template) : const <_Check>[];

      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: _appBar(wide, ready, template, checks),
        body: !ready
            ? _stateBody()
            : _withDropOverlay(wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: (constraints.maxWidth * 0.42).clamp(460, 600),
                        child: _setupPane(available, template),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _previewPane(template, checks, wide)),
                    ],
                  )
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _setupPane(available, template),
                      _previewPane(template, checks, wide),
                    ],
                  )),
      );
    });
  }

  /// Outline and label while files from the computer hover over the page.
  Widget _withDropOverlay(Widget child) {
    if (!_dropActive) return child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              margin: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.05),
                border: Border.all(color: scheme.primary, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.bottomCenter,
              padding: const EdgeInsets.only(bottom: 24),
              child: Material(
                color: scheme.primary,
                elevation: 4,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.attach_file,
                          color: scheme.onPrimary, size: 20),
                      const SizedBox(width: 10),
                      Text('Drop to attach to the email',
                          style: TextStyle(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  PreferredSizeWidget _appBar(
    bool wide,
    bool ready,
    DistributionReportTemplate? template,
    List<_Check> checks,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = _item;
    final canSend = ready && !checks.any((c) => c.blocking);

    String body = '';
    String html = '';
    var richCopy = false;
    if (canSend && template != null) {
      final values = _values(template);
      body = template.render(values);
      html = template.renderHtml(values);
      // Only a table needs the formatted copy; plain prose pastes as well
      // without it.
      richCopy = template.usesFlyersAndPosters;
    }

    return AppBar(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 64,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Distribution report',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '${item.client} · '
                      '${_shortDate.format(toScheduleCivil(item.date))}'),
              if (_saveLabel != null)
                TextSpan(
                  text: ' · $_saveLabel',
                  style: _saveState == _SaveState.failed
                      ? TextStyle(color: scheme.error)
                      : null,
                ),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        if (ready && wide) ...[
          OutlinedButton.icon(
            onPressed:
                canSend ? () => _copy(body, richCopy ? html : null) : null,
            icon: const Icon(Icons.content_copy_outlined, size: 18),
            label: const Text('Copy report'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: canSend
                ? () => _openGmail(body, html, richCopy: richCopy)
                : null,
            icon: const Icon(Icons.send_outlined, size: 18),
            label: const Text('Open Gmail'),
          ),
          const SizedBox(width: 4),
        ] else if (ready) ...[
          IconButton(
            tooltip: 'Copy report',
            onPressed:
                canSend ? () => _copy(body, richCopy ? html : null) : null,
            icon: const Icon(Icons.content_copy_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton.filled(
              tooltip: 'Open Gmail',
              onPressed: canSend
                  ? () => _openGmail(body, html, richCopy: richCopy)
                  : null,
              icon: const Icon(Icons.send_outlined),
            ),
          ),
        ],
        if (ready)
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (_) => _startOver(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'startOver',
                child: ListTile(
                  leading: Icon(Icons.restart_alt),
                  title: Text('Start over'),
                  subtitle: Text('Delete the saved draft'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        if (ready && wide) const SizedBox(width: 12),
      ],
      bottom: ready && !wide
          ? TabBar(
              controller: _tabs,
              tabs: [
                const Tab(text: 'Setup'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Preview'),
                      if (checks.any((c) => c.blocking)) ...[
                        const SizedBox(width: 6),
                        Badge(
                          label:
                              Text('${checks.where((c) => c.blocking).length}'),
                          backgroundColor: Colors.amber.shade800,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            )
          : PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: _loading
                  ? const LinearProgressIndicator(minHeight: 1)
                  : Divider(height: 1, color: scheme.outlineVariant),
            ),
    );
  }

  // ── Loading, error and no-map states ─────────────────────────────────────

  Widget _stateBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return _stateMessage(
        icon: Icons.summarize_outlined,
        color: scheme.primary,
        title: 'Compiling the report',
        message: 'Reading the job\'s map and its cloud folders. This takes a '
            'few seconds.',
        progress: true,
      );
    }
    if (_compileError != null) {
      return _stateMessage(
        icon: Icons.error_outline,
        color: scheme.error,
        title: 'Could not compile the report',
        message: _compileError!,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back'),
          ),
          FilledButton.icon(
            onPressed: _compile,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    return _stateMessage(
      icon: Icons.map_outlined,
      color: Colors.amber.shade800,
      title: 'No map linked to this job',
      message: _report?.mapError ??
          'Link a shareable map in the Area column, then compile again.',
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to Job List'),
        ),
      ],
    );
  }

  Widget _stateMessage({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
    bool progress = false,
    List<Widget> actions = const [],
  }) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 34, color: color),
              ),
              const SizedBox(height: 20),
              Text(title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, height: 1.45)),
              if (progress) ...[
                const SizedBox(height: 20),
                const SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(minHeight: 3),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Setup pane ───────────────────────────────────────────────────────────

  Widget _setupPane(
    List<DistributionReportTemplate> available,
    DistributionReportTemplate? template,
  ) {
    final report = _report!;
    final flyersAndPosters = template?.usesFlyersAndPosters ?? false;
    final handouts = template?.usesFlyerHandouts ?? false;

    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 520;
      final gutter = narrow ? 16.0 : 24.0;
      return ListView(
        padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 48),
        children: [
          flyersAndPosters
              ? _flyersAndPostersStats()
              : handouts
                  ? _handoutStats()
                  : _standardStats(report),
          _section(
            'Email',
            [
              if (available.length > 1)
                DropdownButtonFormField<String>(
                  focusNode: _templateFocus,
                  initialValue: template?.id,
                  isExpanded: true,
                  hint: const Text('Choose a report…'),
                  decoration: _inputDecoration('Template'),
                  items: [
                    for (final t in available)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text(t.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) => setState(() {
                    _templateId = id;
                    _followTemplateSubject(available, id);
                  }),
                ),
              _recipients(report),
              TextField(
                controller: _greeting,
                focusNode: _greetingFocus,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: _inputDecoration(
                  'Greeting name',
                  hint: 'Who to address, e.g. Nikita',
                  helper: 'The name after "Hi" — not the account name.',
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _subject,
                decoration: _inputDecoration('Subject'),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          if (flyersAndPosters) ...[
            _section(
              'Jobs',
              [_jobSlots()],
              caption: 'Pair this job with its leaflet or poster job. Leave '
                  'one empty for a flyers-only or posters-only report.',
            ),
            _section('Report details', [
              TextField(
                controller: _heading,
                focusNode: _headingFocus,
                decoration: _inputDecoration(
                  'Heading',
                  hint: 'e.g. MyCiTi Phase 2A — Claremont construction update',
                ),
                onChanged: (_) => setState(() {}),
              ),
              _pair(
                narrow,
                TextField(
                  controller: _leafletName,
                  focusNode: _leafletNameFocus,
                  enabled: _leafletReport != null,
                  decoration: _inputDecoration(
                    'Leaflet name',
                    helper: 'Goes before "leaflets"',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _suburb,
                  focusNode: _suburbFocus,
                  decoration: _inputDecoration(
                    'Suburb / area',
                    helper: 'Filled in from the map',
                  ),
                  onChanged: (_) => setState(() => _suburbTouched = true),
                ),
              ),
            ]),
            _distributorsSection(narrow),
          ] else
            _section(
              'Cloud folders',
              [
                _folderList(report, _selectedFolders),
              ],
              caption: report.folders.length > 1
                  ? 'This map has more than one folder. Untick any that '
                      'belong to a different job.'
                  : null,
            ),
          if (handouts) _handoutSection(),
          _attachmentsSection(),
          _beforeSending(report),
        ],
      );
    });
  }

  InputDecoration _inputDecoration(String label,
      {String? hint, String? helper}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      isDense: true,
      border: const OutlineInputBorder(),
    );
  }

  /// Two fields side by side, or stacked when the pane is narrow.
  Widget _pair(bool narrow, Widget a, Widget b) {
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [a, const SizedBox(height: 12), b],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ],
    );
  }

  /// A titled group of controls — a quiet label and spacing rather than a
  /// card, so the pane never nests boxes inside boxes.
  Widget _section(
    String title,
    List<Widget> children, {
    String? caption,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(caption,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          const SizedBox(height: 14),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            children[i],
          ],
        ],
      ),
    );
  }

  // ── Flyer handout report ─────────────────────────────────────────────────

  Widget _handoutStats() {
    final h = _handouts;
    final days = h.selectedDays;
    final handouts = days.fold<int>(0, (n, d) => n + d.analysis.totalHandouts);
    final dates = {for (final d in days) DateUtils.dateOnly(d.date)};
    final available = h.availablePhotoCount;
    return _statRow([
      _Stat(
        'Handed out',
        h.status == TEReportScanStatus.done
            ? DistributionReportFormat.quantity.format(handouts)
            : '—',
        note: 'flyers',
      ),
      _Stat(
        'Promoter days',
        '${days.length}',
        note: dates.isEmpty
            ? 'none ticked'
            : _plural(dates.length, 'date'),
      ),
      _Stat(
        'Photos',
        '${h.photoCount}',
        note: available == 0 ? 'none found' : 'of $available chosen',
        warn: available > 0 && h.photoCount == 0,
      ),
    ]);
  }

  Widget _handoutSection() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final h = _handouts;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    final List<Widget> body;
    switch (h.status) {
      case TEReportScanStatus.idle:
      case TEReportScanStatus.scanning:
        body = [
          Row(children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  h.scanStatus ?? 'Scanning the folders for tracks and photos…',
                  style: muted),
            ),
          ]),
        ];
      case TEReportScanStatus.error:
        body = [
          Text(h.errorMessage ?? 'Could not scan the folders.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
        ];
      case TEReportScanStatus.done:
        body = [
          if (h.days.isEmpty)
            Text(
                'No promoter tracks were found in the ticked folders. '
                'Upload the GPX files to the job folder, then scan again.',
                style: muted)
          else ...[
            TEReportPhotoNotices(report: h),
            TEReportDayChecklist(report: h),
          ],
          if (h.unresolved.isNotEmpty) TEUnresolvedFiles(items: h.unresolved),
          _handoutBuildRow(),
        ];
    }

    return _section(
      'Promoter days',
      body,
      caption: 'Tick the shifts that go in the PDF. Photos are read from the '
          'folders beside the tracks and put on the day they were taken; '
          'only the ones you choose go in. Building the PDF asks you to '
          'choose them first.',
      trailing: h.status == TEReportScanStatus.scanning
          ? null
          : TextButton.icon(
              onPressed: _rescanHandouts,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Scan again'),
            ),
    );
  }

  Widget _handoutBuildRow() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final h = _handouts;
    final built = _handoutPdf != null;
    final stale = _handoutPdfStale;
    final canBuild = h.selectedDays.isNotEmpty && !h.isGenerating;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: canBuild ? _buildHandoutPdf : null,
          icon: h.isGenerating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: Text(h.isGenerating
              ? (h.generateStatus ?? 'Building PDF…')
              : built
                  ? 'Build PDF again'
                  : 'Build PDF'),
        ),
        if (built && !h.isGenerating)
          OutlinedButton.icon(
            onPressed: _previewHandoutPdf,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Preview'),
          ),
        if (stale && !h.isGenerating)
          Text('Out of date — the days or photos changed',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.amber.shade900)),
        if (!built && !h.isGenerating && canBuild)
          Text('You choose the photos and check where everyone worked first.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  /// The handout PDF's row under Attachments.
  Widget _handoutPdfRow() {
    final scheme = Theme.of(context).colorScheme;
    final pdf = _handoutPdf;
    final stale = _handoutPdfStale;
    return _attachmentFrame(
      icon: Icons.picture_as_pdf_outlined,
      title: pdf?.name ?? _handoutPdfName,
      meta: pdf == null
          ? 'Not built yet — Build PDF, under Promoter days'
          : stale
              ? '${formatBytes(pdf.bytes!.length)} · out of date, build again'
              : formatBytes(pdf.bytes!.length),
      metaColor: pdf == null || stale ? Colors.amber.shade900 : null,
      badge: _pill('Report', scheme.secondaryContainer,
          scheme.onSecondaryContainer),
      trailing: pdf == null
          ? null
          : IconButton(
              tooltip: 'Preview',
              icon: const Icon(Icons.visibility_outlined, size: 20),
              onPressed: _previewHandoutPdf,
            ),
    );
  }

  // ── Stats ────────────────────────────────────────────────────────────────

  Widget _standardStats(DistributionReport report) {
    final totals = report.totalsFor(_selectedFolders);
    final quantity = DistributionReportFormat.quantity;
    return _statRow([
      _Stat(
        'Distributed',
        quantity.format(totals.quantityDistributed),
        note: report.quantityOrdered > 0
            ? 'of ${quantity.format(report.quantityOrdered)} ordered'
            : 'letterboxes',
      ),
      _Stat(
        'Started',
        totals.startDate == null ? '—' : _shortDate.format(totals.startDate!),
        note: totals.dateSource.isMeasured
            ? 'from GPS times'
            : totals.dateSource.label,
        warn: !totals.dateSource.isMeasured,
      ),
      _Stat(
        'Areas',
        '${report.areas.length}',
        note: report.areas.isEmpty
            ? 'none named on the map'
            : DistributionReportFormat.areaList(report.areas),
        warn: report.areas.isEmpty,
      ),
    ]);
  }

  Widget _flyersAndPostersStats() {
    final quantity = DistributionReportFormat.quantity;
    final leaflet = _leafletReport?.totalsFor(_leafletFolders);
    final poster = _posterReport?.totalsFor(_posterFolders);
    final people = _people();
    final missingIds = people.where((p) => _idFor(p).isEmpty).length;
    return _statRow([
      _Stat(
        'Leaflets',
        leaflet == null ? '—' : quantity.format(leaflet.quantityDistributed),
        note: leaflet?.startDate == null
            ? 'no leaflet job'
            : _shortDate.format(leaflet!.startDate!),
      ),
      _Stat(
        'Posters',
        poster == null ? '—' : quantity.format(poster.quantityDistributed),
        note: poster == null
            ? 'no poster job'
            : _plural(poster.photoCount, 'photo'),
        warn: poster != null && poster.photoCount != poster.quantityDistributed,
      ),
      _Stat(
        'Distributors',
        '${people.length}',
        note: people.isEmpty
            ? 'none found'
            : missingIds == 0
                ? 'all IDs on file'
                : '${_plural(missingIds, 'ID')} missing',
        warn: people.isEmpty || missingIds > 0,
      ),
    ]);
  }

  Widget _statRow(List<_Stat> stats) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: _statTile(stats[i])),
        ],
      ],
    );
  }

  Widget _statTile(_Stat stat) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stat.label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            stat.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: _tabular,
            ),
          ),
          if (stat.note != null) ...[
            const SizedBox(height: 2),
            Text(
              stat.note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    stat.warn ? Colors.amber.shade900 : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Email ────────────────────────────────────────────────────────────────

  Widget _recipients(DistributionReport report) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 12),
          child: Text('To',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: report.recipients.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'No Report Addresses on this job — add recipients in '
                    'Gmail.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.amber.shade900),
                  ),
                )
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in report.recipients)
                      Chip(
                        avatar: const Icon(Icons.mail_outline, size: 16),
                        label: Text(r),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  // ── Jobs (Flyers & Posters) ──────────────────────────────────────────────

  Widget _jobSlots() {
    final leafletSlot =
        _jobSlot(role: 'Leaflet job', clicked: !_clickedIsPoster);
    final posterSlot = _jobSlot(role: 'Poster job', clicked: _clickedIsPoster);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        leafletSlot,
        Center(
          child: IconButton(
            tooltip: 'Swap leaflet and poster jobs',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => setState(() {
              _clickedIsPoster = !_clickedIsPoster;
              _prefillSuburb();
            }),
          ),
        ),
        posterSlot,
      ],
    );
  }

  /// One side of the pairing: the job this page was opened from, or a
  /// picker for the other one.
  Widget _jobSlot({required String role, required bool clicked}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = clicked ? _report : _otherReport;
    final folders = clicked ? _selectedFolders : _otherFolders;
    final item = clicked ? _item : _otherItem;
    final jobTypes = ref.read(jobTypeRiverpod);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(role,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (clicked)
                _pill('This job', scheme.primaryContainer,
                    scheme.onPrimaryContainer),
            ],
          ),
          const SizedBox(height: 10),
          if (clicked)
            Text(
              '${item!.client} · ${_shortDate.format(toScheduleCivil(item.date))}'
              ' · ${jobTypes.getJobTypeLabel(item.jobTypeId)}',
              style: theme.textTheme.bodyMedium,
            )
          else
            _otherJobPicker(),
          if (!clicked && _otherLoading) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (!clicked && _otherError != null) ...[
            const SizedBox(height: 8),
            Text(_otherError!,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          ],
          if (report != null && !report.hasMap) ...[
            const SizedBox(height: 8),
            Text(report.mapError ?? 'That job has no map.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.amber.shade900)),
          ],
          if (report != null && report.hasMap) ...[
            const SizedBox(height: 8),
            _jobFacts(report, folders),
            if (role == 'Poster job') _photosRow(report, folders),
            if (report.folders.length > 1) ...[
              const SizedBox(height: 4),
              _folderList(report, folders, dense: true),
            ],
          ],
        ],
      ),
    );
  }

  Widget _jobFacts(DistributionReport report, Set<String> folders) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = report.totalsFor(folders);
    final style =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Row(
      children: [
        Icon(Icons.place_outlined, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            [
              DistributionReportFormat.quantity
                  .format(totals.quantityDistributed),
              if (totals.startDate != null)
                _shortDate.format(totals.startDate!),
              _plural(report.folders.length, 'folder'),
            ].join(' · '),
            style: style?.copyWith(fontFeatures: _tabular),
          ),
        ),
        IconButton(
          tooltip: 'Open the map',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.open_in_new, size: 18),
          onPressed: () => launchUrl(Uri.parse(report.mapLink),
              mode: LaunchMode.externalApplication),
        ),
      ],
    );
  }

  /// How many photos the photos link will show — the client opens it from
  /// the email, so an empty page is worth catching before sending.
  Widget _photosRow(DistributionReport report, Set<String> folders) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photos = report.totalsFor(folders).photoCount;
    final none = photos == 0;
    final color = none ? Colors.amber.shade900 : scheme.onSurfaceVariant;

    return Row(
      children: [
        Icon(
            none ? Icons.no_photography_outlined : Icons.photo_library_outlined,
            size: 16,
            color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            none
                ? 'No photos in the poster folder — upload them in Cloud '
                    'Files, then check again'
                : '${_plural(photos, 'photo')} on the photos page',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: none ? FontWeight.w600 : null,
              fontFeatures: _tabular,
            ),
          ),
        ),
        TextButton(
          onPressed: _checkingPhotos ? null : _recheckPhotos,
          child: _checkingPhotos
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Check again'),
        ),
        if (!none && report.shareCode.isNotEmpty)
          IconButton(
            tooltip: 'Open the photos page',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.open_in_new, size: 18),
            onPressed: () => launchUrl(
                Uri.parse(MapLinkService.buildPhotosUrl(report.shareCode)),
                mode: LaunchMode.externalApplication),
          ),
      ],
    );
  }

  /// Re-read the poster job's folders after photos were uploaded. Folders
  /// the user unticked stay unticked; folders that appeared are counted.
  Future<void> _recheckPhotos() async {
    final job = _clickedIsPoster ? _item : _otherItem;
    final before = _posterReport;
    if (job == null || before == null) return;
    final ticked = _posterFolders;
    final unticked = {
      for (final f in before.readableFolders)
        if (!ticked.contains(f.path)) f.path,
    };

    setState(() => _checkingPhotos = true);
    try {
      final report = await _compileJob(job);
      if (!mounted) return;
      setState(() {
        if (_clickedIsPoster) {
          _report = report;
        } else {
          _otherReport = report;
        }
        ticked
          ..clear()
          ..addAll(report.readableFolders
              .map((f) => f.path)
              .where((p) => !unticked.contains(p)));
      });
    } catch (e) {
      debugPrint('[DistributionReport] photo recheck failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(SnackBar(
          content: Text('Could not check the poster folder again: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _checkingPhotos = false);
    }
  }

  Widget _otherJobPicker() {
    final candidates = _candidates;
    if (candidates == null) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final jobTypes = ref.read(jobTypeRiverpod);
    return DropdownButtonFormField<String?>(
      // Keyed on the role so a swap does not leave a stale selection behind.
      key: ValueKey('other_$_clickedIsPoster'),
      initialValue: _otherItem?.id,
      isExpanded: true,
      decoration: _inputDecoration('Choose a job'),
      items: [
        const DropdownMenuItem<String?>(
            value: null, child: Text('None — leave this part out')),
        for (final j in candidates)
          DropdownMenuItem<String?>(
            value: j.id,
            child: Text(
              '${_shortDate.format(toScheduleCivil(j.date))} · ${j.client}'
              ' · ${jobTypes.getJobTypeLabel(j.jobTypeId)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _pickOther,
    );
  }

  Widget _pill(String text, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
    );
  }

  // ── Cloud folders ────────────────────────────────────────────────────────

  /// Each folder with its count and date. Tick boxes only when there is a
  /// choice to make — maps reused across months carry earlier jobs' folders,
  /// and summing those silently would overstate a client's figure.
  Widget _folderList(
    DistributionReport report,
    Set<String> selected, {
    bool dense = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final choosable = report.folders.length > 1;
    if (report.folders.isEmpty) {
      return Text('No cloud folders are linked to this map.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: Colors.amber.shade900));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final folder in report.folders)
          _folderRow(folder, selected, choosable, dense, theme, scheme),
      ],
    );
  }

  Widget _folderRow(
    DistributionReportFolder folder,
    Set<String> selected,
    bool choosable,
    bool dense,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final failed = folder.error != null;
    final meta = failed
        ? folder.error!
        : [
            '${DistributionReportFormat.quantity.format(folder.waypointCount)} '
                'letterboxes',
            if (folder.date != null) _shortDate.format(folder.date!),
            if (folder.photoCount > 0) _plural(folder.photoCount, 'photo'),
          ].join(' · ');

    void toggle() => setState(() {
          if (!selected.remove(folder.path)) selected.add(folder.path);
        });

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: choosable && !failed ? toggle : null,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
        child: Row(
          children: [
            if (choosable)
              Checkbox(
                value: selected.contains(folder.path),
                onChanged: failed ? null : (_) => toggle(),
              )
            else
              Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  failed ? Icons.error_outline : Icons.folder_outlined,
                  size: 20,
                  color: failed ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(folder.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                  Text(meta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: failed ? scheme.error : scheme.onSurfaceVariant,
                        fontFeatures: _tabular,
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Distributors ─────────────────────────────────────────────────────────

  Widget _distributorsSection(bool narrow) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _people();
    final removed = _people(includeRemoved: true).length - rows.length;

    return _section(
      'Distributors',
      [
        if (rows.isEmpty)
          Text(
            'No distributor names found in the selected folders\' file names.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.amber.shade900),
          ),
        for (final row in rows) _personRow(row, narrow),
        if (removed > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(_removedPeople.clear),
              icon: const Icon(Icons.undo, size: 18),
              label: Text('Restore ${_plural(removed, 'person')} left out'),
            ),
          ),
      ],
      caption: 'Matched from the track and photo file names. Full names and '
          'IDs come from each distributor\'s profile; an ID typed here is '
          'used for this report only.',
      trailing: rows.isEmpty
          ? null
          : _pill('${rows.length}', scheme.secondaryContainer,
              scheme.onSecondaryContainer),
    );
  }

  Widget _personRow(_PersonRow row, bool narrow) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final distributors = ref.watch(distributorRiverpod).distributors;
    final id = _idFor(row);
    final noFullName = (row.distributor?.fullName ?? '').trim().isEmpty;
    final warn = row.distributor == null || noFullName;

    final meta = [
      'from "${row.fileNames.join('", "')}"',
      [
        if (row.inLeaflets) 'leaflets',
        if (row.inPosters) 'posters',
      ].join(' + '),
      if (row.distributor == null)
        'not matched'
      else if (noFullName)
        'no full name on profile',
    ].join(' · ');

    final idField = TextFormField(
      // Keyed on the row so a re-match shows the new profile's ID instead of
      // keeping the old field's text.
      key: ValueKey('id_${row.key}'),
      initialValue: id,
      style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: _tabular),
      decoration: InputDecoration(
        hintText: 'ID / Passport number',
        isDense: true,
        border: const OutlineInputBorder(),
        enabledBorder: id.isEmpty
            ? OutlineInputBorder(
                borderSide: BorderSide(color: Colors.amber.shade700))
            : null,
      ),
      onChanged: (v) => setState(() => _typedIds[row.key] = v.trim()),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip: 'Match to a different distributor',
          icon: const Icon(Icons.person_search_outlined, size: 20),
          itemBuilder: (_) => [
            for (final r
                in rankDistributorsByName(row.fileNames.first, distributors)
                    .take(15))
              PopupMenuItem(
                  value: r.distributor.id, child: Text(r.distributor.name)),
          ],
          onSelected: (picked) => setState(() {
            for (final name in row.fileNames) {
              _pickedDistributor[name.toLowerCase()] = picked;
            }
          }),
        ),
        IconButton(
          tooltip: 'Leave out of the report',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => setState(() => _removedPeople.add(row.key)),
        ),
      ],
    );

    final identity = Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor:
              warn ? Colors.amber.shade100 : scheme.primaryContainer,
          foregroundColor:
              warn ? Colors.amber.shade900 : scheme.onPrimaryContainer,
          child: Text(_initials(row.displayName),
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
              Text(meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color:
                        warn ? Colors.amber.shade900 : scheme.onSurfaceVariant,
                  )),
            ],
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [Expanded(child: identity), actions]),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 48, right: 8),
                  child: idField,
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: identity),
                const SizedBox(width: 12),
                SizedBox(width: 180, child: idField),
                actions,
              ],
            ),
    );
  }

  static String _initials(String name) {
    final words =
        name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    final first = words.first[0];
    final last = words.length > 1 ? words.last[0] : '';
    return '$first$last'.toUpperCase();
  }

  // ── Attachments ──────────────────────────────────────────────────────────

  Widget _attachmentsSection() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final invoices = _invoices;

    final handouts = _handoutMode;
    if (!gmailDraftsAvailable) {
      return _section('Attachments', [
        if (handouts) _handoutPdfRow(),
        Text(
          'Once Gmail drafts are set up, the invoice and any files you add '
          'go with the email automatically. Until then, attach them in Gmail '
          'yourself${handouts ? ' — Preview the PDF to download it' : ''}.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
        ),
      ]);
    }

    final bytes = _attachmentBytes;
    final over = bytes > kGmailAttachmentLimitBytes;
    final count = _attachments.length;

    return _section(
      'Attachments',
      [
        if (handouts) _handoutPdfRow(),
        for (final i in invoices) _invoiceRow(i.link, i.job),
        for (final f in _addedFiles) _fileRow(f),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('Add files'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'or drop them anywhere on this page',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
      caption: invoices.isEmpty
          ? 'No invoice is linked to this job. Files you add here are not '
              'kept in the saved draft.'
          : 'Invoices are named "Client - Invoice number". Files you add '
              'here are not kept in the saved draft.',
      trailing: count == 0
          ? null
          : _pill(
              '$count · ${formatBytes(bytes)}',
              over ? scheme.errorContainer : scheme.secondaryContainer,
              over ? scheme.onErrorContainer : scheme.onSecondaryContainer,
            ),
    );
  }

  Widget _invoiceRow(JobInvoiceLink link, JobListItem job) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final attached = _invoiceAttached(link);
    final file = attached ? _invoiceFile(link, job) : null;
    final paid = _invoicePaid(link);

    final meta = file == null
        ? (paid ? 'Paid — not attached' : 'Not attached')
        : file.error ??
            (file.bytes == null
                ? 'Fetching from ${link.providerId == 'xero' ? 'Xero' : 'Zoho'}…'
                : formatBytes(file.bytes!.length));

    return _attachmentFrame(
      leading: Checkbox(
        value: attached,
        onChanged: (on) =>
            setState(() => _invoiceChoices[link.invoiceId] = on ?? false),
      ),
      icon: Icons.picture_as_pdf_outlined,
      title: file?.name ?? _invoiceAttachmentName(link, job),
      meta: meta,
      metaColor: file?.error != null ? scheme.error : null,
      badge: _pill(
        paid ? 'Paid' : 'Unpaid',
        paid ? scheme.surfaceContainerHigh : Colors.amber.shade100,
        paid ? scheme.onSurfaceVariant : Colors.amber.shade900,
      ),
      trailing: file?.error != null
          ? IconButton(
              tooltip: 'Try again',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => _retryInvoice(file!),
            )
          : (file != null && file.bytes == null)
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
    );
  }

  Widget _fileRow(_Attachment file) {
    return _attachmentFrame(
      icon: file.mimeType.startsWith('image/')
          ? Icons.image_outlined
          : file.mimeType == 'application/pdf'
              ? Icons.picture_as_pdf_outlined
              : Icons.insert_drive_file_outlined,
      title: file.name,
      meta: formatBytes(file.bytes?.length ?? 0),
      trailing: IconButton(
        tooltip: 'Remove',
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => setState(() => _addedFiles.remove(file)),
      ),
    );
  }

  Widget _attachmentFrame({
    Widget? leading,
    required IconData icon,
    required String title,
    required String meta,
    Color? metaColor,
    Widget? badge,
    Widget? trailing,
    Widget? footer,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = Row(
      children: [
        if (leading != null) leading,
        Icon(icon, size: 22, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium),
              Text(meta,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: metaColor ?? scheme.onSurfaceVariant,
                    fontFeatures: _tabular,
                  )),
            ],
          ),
        ),
        if (badge != null) ...[badge, const SizedBox(width: 4)],
        if (trailing != null) trailing else const SizedBox(width: 12),
      ],
    );
    return Container(
      padding: EdgeInsets.fromLTRB(leading == null ? 12 : 2, 6, 4, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: footer == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row,
                Padding(
                  padding:
                      EdgeInsets.fromLTRB(leading == null ? 32 : 78, 4, 8, 6),
                  child: Align(alignment: Alignment.centerLeft, child: footer),
                ),
              ],
            ),
    );
  }

  Widget _attachmentChips(TextStyle? labelStyle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 64, child: Text('Attached', style: labelStyle)),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in _attachments)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(a.name),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Before sending ───────────────────────────────────────────────────────

  Widget _beforeSending(DistributionReport report) {
    final totals = report.totalsFor(_selectedFolders);
    final showWriteBack =
        totals.quantityDistributed != report.recordedQuantityDistributed;
    final invoices = _invoices;
    final hasInvoice = report.hasInvoice || invoices.isNotEmpty;
    if (!hasInvoice && !showWriteBack) return const SizedBox.shrink();
    final quantity = DistributionReportFormat.quantity;

    return _section('Before sending', [
      if (hasInvoice)
        _switchRow(
          value: _includeInvoice,
          onChanged: (on) => setState(() => _includeInvoiceLine = on),
          title: 'Say "$kInvoiceAttachedLine"',
          subtitle: _invoiceLineSubtitle(report, invoices),
        ),
      if (showWriteBack)
        _switchRow(
          value: _writeBackQuantity,
          onChanged: (on) => setState(() => _writeBackQuantity = on),
          title: 'Update Qty Distributed on this job',
          subtitle:
              'From ${quantity.format(report.recordedQuantityDistributed)}'
              ' to ${quantity.format(totals.quantityDistributed)}, the compiled '
              'figure',
        ),
    ]);
  }

  /// What the books say about the report's invoices, and what happens to them.
  String _invoiceLineSubtitle(
    DistributionReport report,
    List<({JobInvoiceLink link, JobListItem job})> invoices,
  ) {
    if (invoices.isEmpty) {
      return report.invoiceIsPaid
          ? '${report.invoiceNumber} is paid, so this is off by default.'
          : '${report.invoiceNumber} is unpaid.';
    }
    final books = invoices.first.link.providerId == 'xero' ? 'Xero' : 'Zoho';
    final checking = invoices.any((i) {
      final detail = _invoiceDetails[i.link.invoiceId];
      return detail == null || (!detail.loaded && detail.error == null);
    });
    if (checking) return 'Checking the invoice status with $books…';
    final unpaid = [
      for (final i in invoices)
        if (!_invoicePaid(i.link)) i.link.invoiceNumber,
    ];
    final attach = gmailDraftsAvailable
        ? ' Ticked invoices are attached to the Gmail draft.'
        : ' Attach the PDF in Gmail yourself — the invoice icon in the Job '
            'List downloads it.';
    if (unpaid.isEmpty) {
      return '${invoices.map((i) => i.link.invoiceNumber).join(', ')} '
          '${invoices.length == 1 ? 'is' : 'are'} paid in $books, so this is '
          'off by default.';
    }
    return '${unpaid.join(', ')} ${unpaid.length == 1 ? 'is' : 'are'} unpaid '
        'in $books.$attach';
  }

  Widget _switchRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  // ── Preview pane ─────────────────────────────────────────────────────────

  Widget _previewPane(
    DistributionReportTemplate? template,
    List<_Check> checks,
    bool wide,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: EdgeInsets.symmetric(
            horizontal: wide ? 32 : 12, vertical: wide ? 24 : 16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _readiness(checks),
                  const SizedBox(height: 16),
                  _emailSheet(template),
                  _invoicePanel(template),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Invoice, under the preview ───────────────────────────────────────────

  /// The jobs' invoices, each open in the same editor the invoice screens
  /// use, so lines (a flyers line and a posters line on a shared invoice),
  /// reference and personnel are edited and saved right here.
  Widget _invoicePanel(DistributionReportTemplate? template) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final flyersAndPosters = template?.usesFlyersAndPosters ?? false;
    final invoices = _invoices;
    // Both jobs on the report and one invoice between them.
    final shared =
        flyersAndPosters && _otherItem != null && invoices.length == 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 28, 4, 10),
          child: Text(
            'INVOICE',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        if (invoices.isEmpty)
          _invoiceSheet(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No invoice is linked to this job yet.',
                      style: theme.textTheme.bodyMedium),
                  if (flyersAndPosters && _otherItem != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'The leaflet and poster jobs can share one invoice — '
                      'create it on this job, then add a line for each.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (widget.editJob != null) ...[
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      // Invoices are raised and linked to their job in the
                      // Edit Job dialog, like everywhere else.
                      onPressed: () => _editJob(_item),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Create invoice'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        for (final i in invoices) ...[
          _invoiceEditorSheet(i.link, i.job,
              flyersAndPosters: flyersAndPosters, shared: shared),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// Same surface as the email sheet above it.
  Widget _invoiceSheet({required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 2,
              offset: const Offset(0, 1)),
        ],
      ),
      child: child,
    );
  }

  Widget _invoiceEditorSheet(
    JobInvoiceLink link,
    JobListItem job, {
    required bool flyersAndPosters,
    required bool shared,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = _invoiceDetail(link, job);
    final paid = _invoicePaid(link);
    final editable = _invoiceEditable(link);
    final provider = link.providerId == 'xero' ? 'Xero' : 'Zoho';
    final customer = detail.customerName ??
        (link.contactName.trim().isNotEmpty ? link.contactName : job.client);
    final hasPeople = flyersAndPosters && _people().isNotEmpty;
    final unsaved = _personnelUnsaved.contains(link.invoiceId);
    final done = _invoicesWithPersonnel.contains(link.invoiceId);

    Widget body;
    if (detail.error != null) {
      body = Row(
        children: [
          Expanded(
            child: Text(detail.error!,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          ),
          TextButton.icon(
            onPressed: () => _retryDetail(link, job),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Try again'),
          ),
        ],
      );
    } else if (!detail.loaded) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Loading ${link.invoiceNumber} from $provider…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
      );
    } else if (!editable) {
      body = Text(
        'Paid or void — $provider will not accept changes to it.',
        style:
            theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    } else if (detail.xero != null) {
      body = XeroInvoiceEditor(
        key: detail.editorKey,
        invoice: detail.xero!,
        onSaved: (updated) => _onInvoiceSaved(link, job, xero: updated),
      );
    } else {
      body = ZohoInvoiceEditor(
        key: detail.editorKey,
        orgId: detail.orgId,
        invoice: detail.zoho!,
        onSaved: (updated) => _onInvoiceSaved(link, job, zoho: updated),
      );
    }

    return _invoiceSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined,
                    size: 22, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${link.invoiceNumber.isEmpty ? 'Invoice' : link.invoiceNumber}'
                        ' · $customer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        [
                          provider,
                          if (shared) 'shared by the leaflet and poster jobs',
                          if (!link.isPrimary) 'split invoice',
                          'attached as ${_invoiceAttachmentName(link, job)}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                _pill(
                  paid ? 'Paid' : 'Unpaid',
                  paid ? scheme.surfaceContainerHigh : Colors.amber.shade100,
                  paid ? scheme.onSurfaceVariant : Colors.amber.shade900,
                ),
              ],
            ),
          ),
          if (flyersAndPosters && editable && detail.loaded)
            Padding(
              padding: const EdgeInsets.fromLTRB(54, 0, 20, 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed:
                        hasPeople ? () => _addPersonnelInEditor(link) : null,
                    icon: Icon(
                      done && !unsaved
                          ? Icons.check_circle
                          : Icons.badge_outlined,
                      size: 18,
                      color: done && !unsaved ? Colors.green.shade700 : null,
                    ),
                    label: Text(unsaved
                        ? 'Personnel added — save below'
                        : done
                            ? 'Personnel saved · Add again'
                            : 'Add personnel to lines'),
                  ),
                  if (shared)
                    Text('Add a line for the posters with "Add line".',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (!hasPeople)
                    Text('No personnel found yet',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.amber.shade900)),
                ],
              ),
            ),
          Divider(
              height: 1, color: scheme.outlineVariant.withValues(alpha: 0.7)),
          Padding(padding: const EdgeInsets.all(20), child: body),
        ],
      ),
    );
  }

  /// Ready, or the list of what is left — each item jumps to its field.
  Widget _readiness(List<_Check> checks) {
    final theme = Theme.of(context);
    final blocking = checks.where((c) => c.blocking).toList();
    final warnings = checks.where((c) => !c.blocking).toList();
    final ready = blocking.isEmpty;
    final green = Colors.green.shade700;
    final amber = Colors.amber.shade800;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (ready ? green : amber).withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Icon(
                    ready ? Icons.check_circle : Icons.pending_outlined,
                    size: 20,
                    color: ready ? green : amber,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      ready
                          ? 'Ready to send'
                          : '${_plural(blocking.length, 'thing')} to finish '
                              'before sending',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            for (final check in [...blocking, ...warnings])
              _checkRow(check, theme),
            if (checks.isNotEmpty) const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _checkRow(_Check check, ThemeData theme) {
    final color = check.blocking
        ? Colors.amber.shade900
        : theme.colorScheme.onSurfaceVariant;
    final focus = check.focus;
    return InkWell(
      onTap: focus == null ? null : () => _goTo(focus),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          children: [
            Icon(
              check.blocking
                  ? Icons.radio_button_unchecked
                  : Icons.info_outline,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(check.label,
                  style: theme.textTheme.bodySmall?.copyWith(color: color)),
            ),
            if (focus != null)
              Icon(Icons.chevron_right,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// The email as the client will read it: To and Subject over the body,
  /// with fields still to fill shown as amber placeholders.
  Widget _emailSheet(DistributionReportTemplate? template) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report!;
    final headerStyle =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 2,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _headerLine(
                    'To',
                    report.recipients.isEmpty
                        ? '—'
                        : report.recipients.join(', '),
                    headerStyle),
                const SizedBox(height: 6),
                _headerLine(
                  'Subject',
                  _subject.text.trim().isEmpty ? '—' : _subject.text.trim(),
                  headerStyle,
                  strong: true,
                ),
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _attachmentChips(headerStyle),
                ],
              ],
            ),
          ),
          Divider(
              height: 1, color: scheme.outlineVariant.withValues(alpha: 0.7)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: template == null
                ? Text('Choose a template to see the report.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant))
                : _emailBody(template),
          ),
        ],
      ),
    );
  }

  Widget _headerLine(String label, String value, TextStyle? labelStyle,
      {bool strong = false}) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 64, child: Text(label, style: labelStyle)),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: strong ? FontWeight.w600 : FontWeight.w400),
          ),
        ),
      ],
    );
  }

  Widget _emailBody(DistributionReportTemplate template) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!
        .copyWith(height: 1.55, color: theme.colorScheme.onSurface);
    final blocks = template.renderBlocks(_values(template, preview: true));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          blocks[i].isTable
              ? _previewTable(base)
              : SelectableText.rich(
                  TextSpan(style: base, children: _spans(blocks[i].text, base)),
                ),
        ],
      ],
    );
  }

  static final RegExp _inline =
      RegExp(r'\*\*(.+?)\*\*|https?://[^\s<>"]+|‹[^›]*›');

  /// Bold, links and amber placeholders out of one rendered paragraph.
  List<InlineSpan> _spans(String text, TextStyle base) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final match = m.group(0)!;
      if (m.group(1) != null) {
        final bold = base.copyWith(fontWeight: FontWeight.w700);
        spans.add(TextSpan(style: bold, children: _spans(m.group(1)!, bold)));
      } else if (match.startsWith('‹')) {
        spans.add(TextSpan(
          text: match.substring(1, match.length - 1),
          style: base.copyWith(
            color: Colors.amber.shade900,
            backgroundColor: Colors.amber.shade100,
            fontWeight: FontWeight.w600,
          ),
        ));
      } else {
        final url = DistributionReportTemplate.trimUrl(match);
        final recognizer = TapGestureRecognizer()
          ..onTap = () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        _recognizers.add(recognizer);
        spans.add(TextSpan(
          text: url,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
          style: base.copyWith(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.5),
          ),
        ));
        if (url.length < match.length) {
          spans.add(TextSpan(text: match.substring(url.length)));
        }
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  /// The Name / ID table as it will look pasted into Gmail.
  Widget _previewTable(TextStyle base) {
    final scheme = Theme.of(context).colorScheme;
    final people = _people();
    final border = scheme.outline.withValues(alpha: 0.5);
    Widget cell(String text, {bool header = false, bool missing = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            missing ? 'ID missing' : text,
            style: base.copyWith(
              height: 1.3,
              fontWeight: header ? FontWeight.w700 : FontWeight.w400,
              fontFeatures: _tabular,
              color: missing ? Colors.amber.shade900 : null,
              backgroundColor: missing ? Colors.amber.shade100 : null,
            ),
          ),
        );

    return Table(
      border: TableBorder.all(color: border),
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        TableRow(
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
          children: [
            cell('Name', header: true),
            cell('ID / Passport Number', header: true),
          ],
        ),
        for (final p in people)
          TableRow(children: [
            cell(p.displayName),
            cell(_idFor(p), missing: _idFor(p).isEmpty),
          ]),
        if (people.isEmpty)
          TableRow(children: [
            cell('No distributors found', missing: false),
            cell(''),
          ]),
      ],
    );
  }
}

enum _SaveState { none, saving, saved, failed }

/// A file going with the email: an invoice PDF (fetched from Zoho or Xero)
/// or one the user added.
class _Attachment {
  final String key;

  /// Not final: an invoice's name follows its customer name once the
  /// invoice has loaded.
  String name;
  final String mimeType;

  /// Set for an invoice, which is fetched rather than picked.
  final JobInvoiceLink? invoice;
  final JobListItem? job;

  Uint8List? bytes;
  Future<void>? load;
  String? error;

  _Attachment({
    required this.key,
    required this.name,
    required this.mimeType,
    this.invoice,
    this.job,
    this.bytes,
  });
}

/// An invoice as Xero or Zoho holds it, for the editor under the preview.
class _InvoiceDetail {
  /// Zoho organisation of the job the invoice belongs to.
  final String orgId;

  XeroInvoice? xero;
  ZohoInvoice? zoho;
  Future<void>? load;
  String? error;

  /// The editor's state, so "Add personnel" can write into its lines.
  /// Replaced after a save to start a fresh editor from the saved invoice.
  GlobalKey editorKey = GlobalKey();

  _InvoiceDetail({required this.orgId});

  bool get loaded => xero != null || zoho != null;

  /// The customer exactly as the books name it, or null until loaded.
  String? get customerName {
    final name = (xero?.contactName ?? zoho?.customerName ?? '').trim();
    return name.isEmpty ? null : name;
  }
}

/// One headline figure in the stat row.
class _Stat {
  final String label;
  final String value;
  final String? note;
  final bool warn;

  const _Stat(this.label, this.value, {this.note, this.warn = false});
}

/// Something between the report and sending it.
class _Check {
  final String label;

  /// Stops the send buttons; otherwise it is only worth a look.
  final bool blocking;

  /// The field to jump to, if any.
  final FocusNode? focus;

  const _Check(this.label, {this.blocking = true, this.focus});
}

/// One person in the Name / ID table, merged across both jobs' folders.
class _PersonRow {
  /// The distributor id, or `name:<spelling>` when nobody matched.
  final String key;
  final Distributor? distributor;

  /// Spellings seen in file names that resolved to this row.
  final Set<String> fileNames = {};
  bool inLeaflets = false;
  bool inPosters = false;

  _PersonRow(this.key, this.distributor);

  /// The full legal name when the profile has one.
  String get displayName {
    final full = distributor?.fullName?.trim() ?? '';
    if (full.isNotEmpty) return full;
    return distributor?.name ?? fileNames.first;
  }
}
