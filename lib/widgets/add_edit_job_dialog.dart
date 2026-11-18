import 'package:clmschedule/utils/text_search.dart';
import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:printing/printing.dart';
import '../models/job_list_item.dart';
import '../models/job_list_item_update.dart';
import '../models/collection_job.dart';
import '../models/custom_job_list_status.dart';
import '../models/custom_job_type.dart';
import '../models/custom_polygon.dart';
import '../models/happy_sun_shared.dart';
import '../models/regular_client.dart';
import '../providers/regular_clients_provider.dart';
import '../services/client_address_pin.dart';
import '../services/regular_client_matcher.dart';
import '../services/regular_client_service.dart';
import '../shareable_maps/models/map_layer.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../shareable_maps/utils/linked_map_polygons.dart'
    show mapPointAsWorkMap;
import '../shareable_maps/utils/map_copy_description.dart';
import '../providers/company_provider.dart';
import '../providers/xero_items_provider.dart';
import '../providers/zoho_item_autofill_provider.dart';
import '../providers/zoho_items_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/job_list_status_provider.dart';
import '../providers/invoice_status_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/collection_schedule_provider.dart';
import '../providers/inventory_provider.dart';
import '../providers/tool_settings_provider.dart';
import '../providers/job_type_provider.dart';
import '../providers/day_off_provider.dart';
import '../providers/vat_settings_provider.dart';
import '../services/job_draft_service.dart';
import '../services/xero_accounting_service.dart';
import '../services/job_assignment_service.dart';
import '../shareable_maps/services/map_link_service.dart';
import 'address_point_search_dialog.dart';
import 'job_assignment_preview_dialog.dart';
import 'time_slot_strip.dart';
import 'happy_sun_tools_dialog.dart';
import '../models/zoho_customer.dart';
import '../models/company.dart';
import '../models/invoice_message_subject.dart';
import '../models/xero_contact.dart';
import '../models/xero_invoice.dart';
import '../models/zoho_item_autofill.dart';
import '../models/zoho_invoice.dart';
import '../providers/zoho_customers_provider.dart';
import '../providers/zoho_invoices_provider.dart';
import '../providers/zoho_sync_settings_provider.dart';
import '../services/job_list_service.dart';
import '../services/zoho_books_service.dart';
import '../utils/accounting_error.dart';
import '../utils/save_with_picker.dart';
import '../utils/distribution_lag.dart';
import '../utils/appointment_slots.dart';
import '../utils/save_timeline.dart';
import '../utils/schedule_time.dart';
import 'zoho/customer_picker_field.dart';
import 'xero/xero_contact_picker.dart';
import 'xero/xero_line_items_editor.dart';
import 'xero/xero_status_chip.dart';
import 'zoho/invoice_save_saga.dart';
import 'zoho/invoice_share.dart';
import 'zoho/line_items_editor.dart';
import 'zoho/saga_progress_panel.dart';
import 'zoho/unlink_void_invoice.dart';
import '../utils/job_lifecycle_rules.dart';
import 'zoho/void_invoice_prompt.dart';
import 'job_invoices_sheet.dart';
import '../models/job_invoice_link.dart';
import '../utils/zoho_org.dart';
import 'zoho/zoho_status_chip.dart';
import 'zoho/zoho_table.dart';
import 'slow_action_hint.dart';

class AddEditJobDialog extends riverpod.ConsumerStatefulWidget {
  final JobListItem? jobToEdit;

  /// When true, shows a read-only "Map will be copied" notice in the Area
  /// field to indicate that the linked map from the source job will be
  /// cloned after the copy is saved.
  final bool mapWillBeCopied;

  /// When copying a job, the Zoho invoice id of the **source** job. Its line
  /// items, descriptions and customer are fetched and pre-filled so a repeat
  /// job does not have to be re-typed.
  ///
  /// Deliberately separate from `jobToEdit.zohoInvoiceId`, which the copy
  /// clears — the new job must raise its own invoice, not re-link the old one.
  final String? sourceZohoInvoiceId;

  const AddEditJobDialog({
    super.key,
    this.jobToEdit,
    this.mapWillBeCopied = false,
    this.sourceZohoInvoiceId,
  });

  @override
  riverpod.ConsumerState<AddEditJobDialog> createState() =>
      _AddEditJobDialogState();
}

class _AddEditJobDialogState extends riverpod.ConsumerState<AddEditJobDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  // Loading state
  bool _processing = false;

  /// True from the instant a save button is pressed until its handler
  /// returns. Set synchronously, before the first await: the handlers used to
  /// mark themselves busy only after the duplicate-name lookup, so on a slow
  /// connection every click in those seconds started its own save — one
  /// impatient user raised the same invoice 12 times.
  bool _submitting = false;

  /// Every button checks this, so it covers the submit lock too.
  bool get _isProcessing => _processing || _submitting;
  set _isProcessing(bool value) => _processing = value;

  /// Runs [action] unless a save is already under way. The lock is taken
  /// before [action] awaits anything and released when it finishes.
  Future<void> _submitOnce(Future<void> Function() action) async {
    if (_isProcessing || _isSavingDraft) return;
    setState(() => _submitting = true);
    try {
      await action();
    } finally {
      _submitting = false;
      if (mounted) setState(() {});
    }
  }

  /// Times the save under way, step by step, for the browser console — see
  /// [SaveTimeline]. One per save attempt.
  SaveTimeline? _timeline;

  SaveTimeline _startTimeline(String what) {
    final name = _clientController.text.trim();
    return _timeline = SaveTimeline(name.isEmpty ? what : '$what "$name"');
  }

  /// The server's confirmation of the job this dialog added (the Job List
  /// shows it before then). Handed back to the caller as `saved`, for work
  /// that needs the job on the server, such as copying its map.
  Future<void>? _jobSaved;

  // Shareable map suggestions for the Area field (name → share URL)
  List<_MapSuggestion> _mapSuggestions = [];

  /// The suggestions, shared by every dialog opened in the next
  /// [_mapSuggestionsTtl]. Reading all of `mapLinks` (600+ documents) used to
  /// happen on every open, competing with the save for a slow connection.
  static Future<List<_MapSuggestion>>? _mapSuggestionsLoad;
  static DateTime? _mapSuggestionsLoadedAt;
  static const Duration _mapSuggestionsTtl = Duration(minutes: 10);

  /// Regular client plans read for this dialog, so the save and the
  /// allocation read each plan once.
  final Map<String, Future<RegularClient>> _regularClientCache = {};

  // Controllers for text fields
  late final TextEditingController _invoiceController;
  late final TextEditingController _amountController;
  late final TextEditingController _clientController;

  /// Who to ask for on the day and their number — the dropsheet's Contact
  /// and Tel. On the client's line; optional.
  late final TextEditingController _contactPersonController;
  late final TextEditingController _contactPhoneController;

  late final TextEditingController _areaController;
  late final TextEditingController _quantityController;
  late final TextEditingController _manDaysController;

  /// The regular client plan picked for this job, or empty. See
  /// [_buildRegularClientRow].
  String _regularClientId = '';
  late final TextEditingController _offloadingAddressController;
  late final TextEditingController _collectionAddressController;
  late final TextEditingController _specialInstructionsController;
  late final TextEditingController _quantityDistributedController;
  late final TextEditingController _invoiceDetailsController;
  late final TextEditingController _reportAddressesController;
  late final TextEditingController _whoToInvoiceController;

  // Dropdown values
  late String _selectedJobStatusId; // Now stores custom status ID
  late String _selectedJobType;
  VehicleTrailerCombo? _selectedVehicleTrailerCombo;

  // Date values
  DateTime? _selectedDate;
  DateTime? _selectedCollectionDate;

  /// "Needs flyer collection", offered on Community Life Media jobs only.
  bool _needsFlyerCollection = false;

  /// An appointment's booked slot (job types with a time slot): its start
  /// ("10:00") and length in half-hours. Null until picked.
  String? _slotStart;
  int? _slotCount;

  /// The user picked the appointment's day here. Until then a booking moved
  /// to another day on the Collection Schedule keeps that day.
  bool _appointmentDayEdited = false;

  /// Whether the selected job type belongs to Community Life Media.
  bool get _isClmJob =>
      JobListItem.isCommunityLifeMediaJobType(_selectedJobType);

  // Tools needed for Happy Sun jobs (window/solar cleaning)
  CategorizedTools? _toolsNeeded;

  // ── Zoho invoicing (collection-schedule job types only) ───────────────────
  /// Whether to raise a Zoho invoice as part of saving. On by default, but a
  /// job can be saved unbilled (price not agreed yet) and invoiced later from
  /// the schedule cell.
  bool _createZohoInvoice = true;

  /// Set when a new auto-allocate job is saved through the invoicing saga via
  /// the main "Add Job + Invoice" button (not "Skip Allocation + Invoice"), so
  /// the saga runs its "Allocate to Schedule" step right after the save.
  bool _allocateAfterInvoice = false;

  /// True once the job's void invoice was unlinked from inside this dialog.
  /// [widget.jobToEdit] still carries the old link, so every read of it that
  /// concerns the invoice must go through this — otherwise the save would
  /// write the void invoice's ids straight back onto the job.
  bool _invoiceUnlinked = false;

  ZohoCustomer? _zohoCustomer;
  List<ZohoLineItem> _zohoLineItems = [];

  /// False once the seeded Zoho line has been replaced or hand-edited, which
  /// stops a job type change from overwriting it. Mirrors the Xero flag.
  bool _zohoLineAutoSeeded = true;

  /// Bumped on every reseed and folded into [LineItemsEditor]'s key.
  ///
  /// That editor builds a controller per row in `initState`, so replacing the
  /// list alone would leave it rendering the previous line's text. Without this
  /// the reseed would appear to do nothing.
  int _zohoSeedGeneration = 0;

  /// Live during a save; drives the step panel. Retained after a failure so
  /// Retry resumes rather than restarting.
  InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>? _saga;

  // ── Xero (Community Life Media) ────────────────────────────────────────────
  // Kept separate from the Zoho fields rather than shared: the two providers'
  // contact and line-item models differ in shape, and a job type bills through
  // exactly one of them, so there is never a live value in both sets.

  /// Whether to raise a Xero invoice alongside the job.
  bool _createXeroInvoice = true;

  XeroContact? _xeroContact;
  List<XeroLineItem> _xeroLineItems = const [];

  InvoiceSaveSaga<XeroContact, XeroInvoice>? _xeroSaga;

  /// Set when Community Life Media has no Xero sales account configured, which
  /// blocks invoicing until someone fills it in under Settings → Companies.
  String? _xeroConfigError;

  /// Shown against the customer picker when a save was refused for want of a
  /// real, saved customer.
  String? _customerError;

  bool _isPrinting = false;

  /// The job's existing Zoho invoice, loaded when editing a job that has one.
  /// Its line items carry their `line_item_id`, so saving amends those lines
  /// rather than replacing them.
  ZohoInvoice? _existingInvoice;
  bool _isLoadingExistingInvoice = false;
  String? _existingInvoiceError;

  /// Copy flow: fetching the source job's invoice to pre-fill from.
  bool _isLoadingSourceInvoice = false;

  /// Number of the invoice the lines were copied from — shown so the user
  /// knows where the pre-filled values came from.
  String? _copiedFromInvoiceNumber;

  /// Non-fatal — the copy still works, just without the pre-fill.
  String? _sourceInvoiceError;

  /// Which set of books this job type bills through.
  ///
  /// Driven by the job type's company — Junk & Stuff invoices through Zoho
  /// Books, Community Life Media through Xero — which is the single source of
  /// truth for that question, and already returns [AccountingProvider.none] for
  /// a type marked as not raising invoices at all.
  ///
  /// The resolution rule, including the legacy `appearsOnCollectionSchedule`
  /// fallback that keeps a misconfigured company from making Junk & Stuff's
  /// jobs uninvoiceable, lives in [AccountingProvider.forJobType] so it can be
  /// tested without a Firestore-backed provider.
  AccountingProvider get _invoiceProvider {
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);
    if (type == null) return AccountingProvider.none;

    return AccountingProvider.forJobType(
      fromCompany: ref.read(companyRiverpod).providerForJobType(type),
      createsInvoices: type.createsInvoices,
      appearsOnCollectionSchedule: type.appearsOnCollectionSchedule,
    );
  }

  bool get _isXeroJob => _invoiceProvider == AccountingProvider.xero;

  /// The Zoho Books organisation this job's company bills through — Junk &
  /// Stuff and Happy Sun keep separate books under one Zoho login.
  String get _zohoOrgId => ZohoOrg.forJobTypeId(_selectedJobType);

  /// Whether this job belongs to a business that invoices from inside the app.
  ///
  /// Community Life Media bills through Xero; Junk & Stuff and Happy Sun
  /// through their own Zoho Books organisations.
  /// For both, the invoice is now where the money and the job detail live, so
  /// the form drops the fields that would otherwise say the same thing twice
  /// and be free to disagree.
  ///
  /// Gated on company **identity** rather than on the resolved accounting
  /// provider, deliberately. It is deterministic — no dependence on a company
  /// document having its provider recorded — and it covers job types that raise
  /// no invoice at all, which is what was asked for.
  bool get _invoicedFromInsideTheApp {
    final companyId =
        JobTypeProvider.instance?.getJobTypeById(_selectedJobType)?.resolvedCompanyId;
    return companyId == Company.clmId ||
        companyId == Company.junkAndStuffId ||
        companyId == Company.happySunId;
  }

  /// Whether this is a Junk & Stuff job.
  bool get _isJunkAndStuffJob =>
      JobTypeProvider.instance
          ?.getJobTypeById(_selectedJobType)
          ?.resolvedCompanyId ==
      Company.junkAndStuffId;

  /// Fields the invoice owns, hidden on an in-app-invoiced job.
  ///
  /// **Hidden, not discarded.** The controllers stay seeded from the job, so a
  /// value recorded before this existed — or by a job type change — survives an
  /// edit untouched rather than being blanked by a form that no longer shows
  /// it.
  bool get _hideInvoiceOwnedFields => _invoicedFromInsideTheApp;

  /// The invoicing section applies to any job type that bills through a
  /// provider this app implements. For a job that already carries an invoice it
  /// switches to *update* mode rather than being hidden, so invoice edits can
  /// be made from the same screen.
  bool get _showInvoicingSection {
    final provider = _invoiceProvider;
    return provider == AccountingProvider.zoho ||
        provider == AccountingProvider.xero;
  }

  /// True when this job already has a Zoho invoice, so saving amends that
  /// invoice instead of raising a new one. Never true for a copy — the copy
  /// flow clears the inherited link precisely so it bills separately.
  bool get _isUpdatingInvoice =>
      (widget.jobToEdit?.hasZohoInvoice ?? false) &&
      !_isCopy &&
      !_invoiceUnlinked;

  /// Name pre-filled into a **new** Zoho contact: the job's client and area
  /// joined as "client, area".
  ///
  /// Only used to seed a create — it never turns the form into an edit, since
  /// that decision keys on [ZohoCustomer.existsInZoho] and the seed carries no
  /// contact id. Either part being blank collapses gracefully rather than
  /// leaving a dangling comma.
  String get _newCustomerSeedName {
    final parts = [
      _clientController.text.trim(),
      _areaController.text.trim(),
    ].where((p) => p.isNotEmpty);
    return parts.join(', ');
  }

  /// Zoho refuses edits to void invoices, and amending a settled one would
  /// desync the recorded payment from the total.
  bool get _existingInvoiceIsEditable {
    final s = _existingInvoice?.status;
    if (s == null) return true;
    return s != ZohoInvoiceStatus.isVoid && s != ZohoInvoiceStatus.paid;
  }

  /// Whether the save should run the invoicing saga.
  /// Whether the invoicing toggle is on, for whichever provider is in play.
  ///
  /// A Xero job that already has its invoice never raises another here — the
  /// switch is shown disabled for it, but its value stays on, and reading it
  /// unguarded sent "Update Job + Invoice" down the create path a second time.
  bool get _createInvoiceEnabled => _isXeroJob
      ? (_createXeroInvoice && !_alreadyHasXeroInvoice)
      : _createZohoInvoice;

  /// Whether the save should run the invoicing saga.
  ///
  /// True for split invoices alone too, on a job whose primary invoice already
  /// exists — those still go through a saga, just without the primary one.
  bool get _willInvoice =>
      _showInvoicingSection &&
      (_createInvoiceEnabled || _activeSplitDrafts.isNotEmpty);

  /// A saga has been started for this dialog, by either provider.
  ///
  /// Both are never live at once — a job type bills through exactly one
  /// company — but the buttons must disable on whichever one is running, or an
  /// invoiced Xero job could be written a second time by "Skip Allocation".
  bool get _sagaActive =>
      _saga != null ||
      _xeroSaga != null ||
      _splitBaseJob != null ||
      _splitDrafts.any((d) => d.saga != null);

  // ── Split invoices ─────────────────────────────────────────────────────────
  // When two or more clients share a job, each is billed on its own invoice.
  // The first is the job's primary invoice, raised by the section above as
  // before; these are the rest. Each is its own saga run against the saved
  // job, one after another, and linked into `JobListItem.splitInvoices`.

  /// New split invoices being prepared in this dialog.
  final List<_SplitInvoiceDraft> _splitDrafts = [];

  /// The saved job split invoices are raised against, when there is no
  /// primary saga to take it from — a job whose primary invoice already
  /// exists.
  JobListItem? _splitBaseJob;

  bool _splitsRunning = false;

  /// Split invoices already on the job being edited. None for a new job or a
  /// copy — a copy raises its own.
  List<JobInvoiceLink> get _existingSplits =>
      (widget.jobToEdit == null || _isCopy)
          ? const []
          : widget.jobToEdit!.splitInvoices;

  /// The existing splits' share of the job amount, excluding VAT. The amount
  /// field follows the primary invoice's lines plus this.
  double get _existingSplitSubTotal =>
      _existingSplits.fold<double>(0, (r, i) => r + i.subTotal);

  /// The job already carries its primary invoice.
  bool get _jobHasPrimaryInvoice =>
      _isXeroJob ? _alreadyHasXeroInvoice : _isUpdatingInvoice;

  /// Splits only make sense next to a primary invoice — one that exists or
  /// one this save is about to raise.
  bool get _canAddSplitInvoice =>
      _showInvoicingSection &&
      (_jobHasPrimaryInvoice || _createInvoiceEnabled);

  /// The drafts this save will actually raise.
  List<_SplitInvoiceDraft> get _activeSplitDrafts =>
      _canAddSplitInvoice ? _splitDrafts : const [];

  /// "Invoice" or "Invoices", for the save buttons.
  String get _invoiceButtonNoun =>
      _activeSplitDrafts.isNotEmpty ? 'Invoices' : 'Invoice';

  /// Every split invoice has been raised and linked.
  bool get _splitsSettled => _activeSplitDrafts.every((d) => d.isDone);

  @override
  void initState() {
    super.initState();

    final job = widget.jobToEdit;
    debugPrint('\n📋 AddEditJobDialog: Opening dialog');
    debugPrint('   Mode: ${job != null ? "EDIT" : "CREATE"}');
    if (job != null) {
      debugPrint('   Job ID: ${job.id}');
      debugPrint('   Job Type: ${job.jobTypeId}');
      debugPrint('   Client: ${job.client}');
    }

    // Initialize controllers with existing values or empty
    _invoiceController = TextEditingController(text: job?.invoice ?? '');
    _amountController =
        TextEditingController(text: job?.amount.toStringAsFixed(2) ?? '');
    _clientController = TextEditingController(text: job?.client ?? '');
    _clientController.addListener(_onClientTextChanged);
    _contactPersonController =
        TextEditingController(text: job?.contactPerson ?? '');
    _contactPhoneController =
        TextEditingController(text: job?.contactPhone ?? '');
    // A copy opens on the source's name, so flag the clash straight away.
    _scheduleClientClashCheck();
    _areaController = TextEditingController(text: job?.area ?? '');
    _quantityController =
        TextEditingController(text: job?.quantity.toString() ?? '');
    _manDaysController =
        TextEditingController(text: job?.manDays.toStringAsFixed(1) ?? '')
          ..addListener(_onManDaysChanged);
    _regularClientId = job?.regularClientId ?? '';
    _offloadingAddressController =
        TextEditingController(text: job?.offloadingAddress ?? '');
    _collectionAddressController =
        TextEditingController(text: job?.collectionAddress ?? '');
    _specialInstructionsController =
        TextEditingController(text: job?.specialInstructions ?? '');
    _quantityDistributedController =
        TextEditingController(text: job?.quantityDistributed.toString() ?? '');
    _invoiceDetailsController =
        TextEditingController(text: job?.invoiceDetails ?? '');
    _reportAddressesController =
        TextEditingController(text: job?.reportAddresses ?? '');
    _whoToInvoiceController =
        TextEditingController(text: job?.whoToInvoice ?? '');

    // Initialize dropdown values
    // A new job starts as a confirmed flyer distribution — the common case.
    _selectedJobStatusId = job?.jobStatusId ??
        resolveCopyJobStatusId(
          statuses: ref.read(jobListStatusRiverpod).statuses,
          sourceStatusId: kCopyJobStatusFallbackId,
        );
    _selectedJobType = job?.jobTypeId ?? _defaultNewJobTypeId();

    // Seed the invoice with one line from the job. Editable afterwards, and
    // its sub-total drives the amount field so job and invoice cannot drift.
    //
    // Synchronous and item-free: the catalogue has not loaded this early. The
    // post-frame pass below replaces this from the job type's mapped item, if
    // it has one.
    _zohoLineItems = [
      ZohoLineItem(
        name: 'Junk collection',
        description: job?.invoiceDetails ?? '',
        rate: job?.amount ?? 0.0,
        quantity: 1,
      ),
    ];

    // Pre-match the free-text client name against a contact, so the common
    // case needs no picking at all. Runs for both providers — it used to be
    // gated on the collection-schedule flag, so a CLM job always started
    // unmatched even when the client was already in Xero.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final typed = _clientController.text.trim();

      if (_isXeroJob) {
        if (typed.isEmpty) return;
        try {
          // searchTerm, not the whole book: Xero's daily budget does not
          // stretch to loading every contact to match one name.
          final page = await ref
              .read(xeroAccountingServiceRiverpod)
              .listContacts(searchTerm: typed, pageSize: 5);
          if (!mounted) return;
          final needle = typed.toLowerCase();
          for (final contact in page.items) {
            if (contact.displayName.trim().toLowerCase() == needle) {
              setState(() => _xeroContact = contact);
              break;
            }
          }
        } catch (_) {
          // No match is the normal outcome; an unreachable Xero must not stop
          // the form opening.
        }
        return;
      }

      // Any Zoho company, not just the Collection Schedule's — Happy Sun's
      // job types bill through Zoho without appearing there.
      if (_invoiceProvider != AccountingProvider.zoho) return;
      final customers = ref.read(zohoCustomersRiverpod(_zohoOrgId));
      await customers.initialize();
      if (!mounted) return;

      final match = customers.findByName(typed);
      if (match != null) setState(() => _zohoCustomer = match);

      await _prefillFromSourceInvoice();
      await _loadExistingInvoice();

      // Last, so it sees the flags those two set: a copied or existing invoice
      // has already claimed the lines and this leaves them alone.
      _reseedZohoLineForJobType();
    });

    // After the seeding above, so restoring a draft overwrites the defaults
    // rather than racing them.
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerDraft());

    // Initialize vehicle/trailer combo from existing job
    if (VehicleTrailerCombo.isVehicleJobType(_selectedJobType) && job != null) {
      _selectedVehicleTrailerCombo =
          VehicleTrailerCombo.tryParse(job.vehicleTrailerCombo) ??
              VehicleTrailerCombo.fromLegacyQuantity(job.quantity,
                  jobTypeId: _selectedJobType);
      // Ensure the combo is valid for this job type
      final validCombos = VehicleTrailerCombo.forJobType(_selectedJobType);
      if (_selectedVehicleTrailerCombo != null &&
          !validCombos.contains(_selectedVehicleTrailerCombo)) {
        _selectedVehicleTrailerCombo = null;
      }
    }

    // Initialize dates - null for new jobs, existing values for editing
    _selectedDate = job?.date;
    // The 2000-01-01 sentinel means "no collection date": show the field
    // empty rather than as 01 Jan 2000 (saving still writes the sentinel).
    _selectedCollectionDate =
        job != null && job.hasCollectionDate ? job.collectionDate : null;
    // Ticked for a new job or a copy; an existing job shows its own.
    _needsFlyerCollection = initialNeedsFlyerCollection(job, isCopy: _isCopy);
    // The booked slot as the Collection Schedule shows it (its own time
    // slot first, then the date's time). Midnight means none was booked.
    if (job != null && job.resolvedTimeSlot != '00:00') {
      _slotStart = job.resolvedTimeSlot;
      _slotCount = job.resolvedTimeSlots;
    }

    // Initialize tools needed for Happy Sun jobs
    _toolsNeeded = job?.toolsNeeded;

    // The Area field's map suggestions load when that field is first used
    // (see _loadMapNames).
  }

  /// Job type a new job opens with: Flyer Distribution, found by label so a
  /// type re-created under another id still resolves, else its seeded id.
  String _defaultNewJobTypeId() {
    const seededId = 'flyerDistribution';
    final types = JobTypeProvider.instance?.jobTypes ?? const [];
    for (final type in types) {
      if (type.label.trim().toLowerCase() == 'flyer distribution') {
        return type.id;
      }
    }
    return seededId;
  }

  /// Fills the Area field's map suggestions. Called when the field first
  /// gets focus, not when the dialog opens, and served from the session copy
  /// when one is fresh — see [_mapSuggestionsLoad].
  bool _mapNamesRequested = false;

  Future<void> _loadMapNames() async {
    if (_mapNamesRequested) return;
    _mapNamesRequested = true;
    final loadedAt = _mapSuggestionsLoadedAt;
    if (_mapSuggestionsLoad == null ||
        (loadedAt != null &&
            DateTime.now().difference(loadedAt) > _mapSuggestionsTtl)) {
      _mapSuggestionsLoadedAt = null;
      _mapSuggestionsLoad = _fetchMapSuggestions().then((list) {
        _mapSuggestionsLoadedAt = DateTime.now();
        return list;
      }, onError: (Object e) {
        // Not kept: the next dialog tries again.
        _mapSuggestionsLoad = null;
        throw e;
      });
    }
    try {
      final suggestions = await _mapSuggestionsLoad!;
      if (mounted) setState(() => _mapSuggestions = suggestions);
    } catch (e) {
      debugPrint('Failed to load map suggestions: $e');
    }
  }

  static Future<List<_MapSuggestion>> _fetchMapSuggestions() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('mapLinks')
        .orderBy('createdAt', descending: true)
        .get();
    final suggestions = <_MapSuggestion>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final name = data['mapName'] as String? ?? '';
      if (name.isEmpty) continue;
      final url = MapLinkService.buildShareUrl(doc.id);
      // Deduplicate by name
      if (seen.add(name.toLowerCase())) {
        suggestions.add(_MapSuggestion(name: name, url: url));
      }
    }
    suggestions
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return suggestions;
  }

  // ── Client field ───────────────────────────────────────────────────────────

  String? _validateClient(String? value) {
    if (value == null || value.trim().isEmpty) return 'Client is required';
    return null;
  }

  // Two Job List jobs with one client name in a month are indistinguishable to
  // schedule allocation, the job's map and its Cloud Files folder — all of
  // them pair on the name (see `jobListClientKey`). So a name that is already
  // taken is flagged while typing and refused on save.

  /// Other jobs in the job's month already using the typed client name.
  List<JobListItem> _clientClashes = const [];
  Timer? _clientClashTimer;
  int _clientClashSeq = 0;
  String _clientClashCheckedFor = '';
  final FocusNode _clientFocus = FocusNode();

  void _onClientTextChanged() {
    // The controller also fires on cursor moves; only a new name matters.
    final key = jobListClientKey(_clientController.text);
    if (key == _clientClashCheckedFor) return;
    _scheduleClientClashCheck();
  }

  void _scheduleClientClashCheck() {
    _clientClashTimer?.cancel();
    _clientClashTimer =
        Timer(const Duration(milliseconds: 350), _refreshClientClashes);
  }

  Future<void> _refreshClientClashes() async {
    final seq = ++_clientClashSeq;
    _clientClashCheckedFor = jobListClientKey(_clientController.text);
    final clashes = await _findClientClashes(fresh: false);
    if (!mounted || seq != _clientClashSeq) return;
    setState(() => _clientClashes = clashes);
  }

  /// An edit that keeps the job's name and month is never refused: a
  /// duplicate that predates this check stays editable.
  bool get _keepsOwnName {
    final job = widget.jobToEdit;
    if (job == null || job.id.isEmpty) return false; // add or copy
    final date = _selectedDate ?? job.date;
    return jobListClientKey(job.client) ==
            jobListClientKey(_clientController.text) &&
        job.date.year == date.year &&
        job.date.month == date.month;
  }

  Future<List<JobListItem>> _findClientClashes({required bool fresh}) async {
    if (_keepsOwnName) return const [];
    try {
      return await ref.read(jobListRiverpod).findJobsWithClientName(
            _clientController.text,
            _selectedDate ?? DateTime.now(),
            excludeId: widget.jobToEdit?.id ?? '',
            fresh: fresh,
          );
    } catch (e) {
      // Non-fatal: if the check fails (e.g. offline), let the save proceed.
      debugPrint('⚠️ Duplicate client check failed: $e');
      return const [];
    }
  }

  /// Save-time gate on every save path. Re-reads the month, so a job someone
  /// else added since the dialog opened is caught too. Returns false, after
  /// explaining why, when the name is taken.
  Future<bool> _clientNameIsFree() async {
    final clashes = await _findClientClashes(fresh: true);
    if (!mounted) return false;
    if (clashes.isEmpty) return true;
    setState(() => _clientClashes = clashes);

    final name = _clientController.text.trim();
    final month = DateFormat('MMMM yyyy').format(_selectedDate ?? DateTime.now());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
        title: const Text('Job name already used'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"$name" is already on the Job List for $month:'),
            const SizedBox(height: 8),
            for (final job in clashes)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 4),
                child: Text(
                  '• ${job.client} — ${DateFormat('d MMM yyyy').format(job.date)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Schedule allocation, maps and Cloud Files tell jobs apart by '
              'name, so two jobs with the same name get mixed up. Give this '
              'job its own name, for example by adding the round or week.',
            ),
          ],
        ),
        actions: [
          FilledButton(
            // The dialog's own context: this form sits under a nested
            // navigator, and the outer context would pop the form instead.
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Rename job'),
          ),
        ],
      ),
    );
    if (mounted) {
      _clientFocus.requestFocus();
      _clientController.selection = TextSelection(
          baseOffset: 0, extentOffset: _clientController.text.length);
    }
    return false;
  }

  /// The Client field.
  ///
  /// Deliberately **not** wired to Xero or Zoho. The name on a Job List row and
  /// the name on the invoice are different things — a job might be logged
  /// against a branch, a contact or a site while the invoice goes to a head
  /// office — so suggesting accounting contacts here invited the two to be
  /// conflated. The invoice's customer is chosen in the invoicing section,
  /// where it belongs.
  ///
  /// **One builder, used by both form layouts.** They previously held
  /// byte-identical copies of this field, which is exactly the arrangement that
  /// let the desktop layout drift from the mobile one on the Zoho integration.
  Widget _buildClientField() {
    final clashes = _clientClashes;
    final warn = Colors.orange.shade800;
    return TextFormField(
      controller: _clientController,
      focusNode: _clientFocus,
      decoration: InputDecoration(
        labelText: 'Client *',
        border: const OutlineInputBorder(),
        enabledBorder: clashes.isEmpty
            ? null
            : OutlineInputBorder(borderSide: BorderSide(color: warn)),
        helperText: clashes.isEmpty
            ? null
            : 'Already used this month (${[
                for (final j in clashes)
                  DateFormat('d MMM').format(j.date),
              ].join(', ')}) — rename this job so the schedule, maps and '
                'Cloud Files can tell them apart',
        helperMaxLines: 3,
        helperStyle: TextStyle(color: warn, fontWeight: FontWeight.w600),
      ),
      validator: _validateClient,
    );
  }

  /// Row 1: Invoice and Amount (unless the app raises the invoice), then the
  /// Client with its Contact person and Phone beside it. On a narrow form
  /// Invoice and Amount take their own line, so the client's three stay
  /// together.
  Widget _buildClientLine(bool isMobile) {
    final showInvoice = !_hideInvoiceOwnedFields;
    final invoice = TextFormField(
      controller: _invoiceController,
      decoration: const InputDecoration(
        labelText: 'Invoice',
        border: OutlineInputBorder(),
      ),
    );

    if (isMobile) {
      return Column(children: [
        if (showInvoice) ...[
          invoice,
          const SizedBox(height: 12),
          _buildAmountField(),
          const SizedBox(height: 12),
        ],
        _buildClientField(),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _buildContactPersonField()),
          const SizedBox(width: 12),
          Expanded(child: _buildContactPhoneField()),
        ]),
      ]);
    }

    List<Widget> clientFields() => [
          Expanded(flex: 4, child: _buildClientField()),
          const SizedBox(width: 16),
          Expanded(flex: 3, child: _buildContactPersonField()),
          const SizedBox(width: 16),
          Expanded(flex: 3, child: _buildContactPhoneField()),
        ];

    if (!showInvoice) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: clientFields(),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 900) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: invoice),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: _buildAmountField()),
          const SizedBox(width: 16),
          ...clientFields(),
        ]);
      }
      return Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: invoice),
          const SizedBox(width: 16),
          Expanded(child: _buildAmountField()),
        ]),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: clientFields(),
        ),
      ]);
    });
  }

  /// Who the driver asks for on the day — the dropsheet's Contact.
  Widget _buildContactPersonField() => TextFormField(
        key: const ValueKey('contactPersonField'),
        controller: _contactPersonController,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Contact person',
          border: OutlineInputBorder(),
        ),
      );

  /// The number the driver rings — the dropsheet's Tel. Optional, but a
  /// number that is too short to dial is caught here, not on the road.
  Widget _buildContactPhoneField() => TextFormField(
        key: const ValueKey('contactPhoneField'),
        controller: _contactPhoneController,
        keyboardType: TextInputType.phone,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- /]')),
        ],
        decoration: const InputDecoration(
          labelText: 'Phone number',
          border: OutlineInputBorder(),
        ),
        validator: JobListItem.contactPhoneProblem,
      );

  /// Under the client field: the regular client plan that best matches the
  /// typed name, or a picker over every plan. Choosing one fills the man days
  /// from the plan, and saving then previews the schedule allocation the plan
  /// describes — each slot-day becomes a schedule job carrying that day's
  /// areas.
  Widget _buildRegularClientRow() {
    final all = ref.watch(regularClientsRiverpod).value ?? const [];
    if (all.isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _clientController,
      builder: (context, value, _) {
        final chosen =
            all.where((c) => c.id == _regularClientId).firstOrNull;
        final suggestion = chosen == null
            ? RegularClientMatcher.bestMatch(value.text, all)
            : null;
        String summary(RegularClient c) =>
            '${c.slots.length} distributor${c.slots.length == 1 ? '' : 's'}'
            ' · ${c.totalManDays} man days';

        final picker = PopupMenuButton<RegularClient>(
          tooltip: 'Choose a regular client map',
          onSelected: _useRegularClient,
          itemBuilder: (_) => [
            for (final c in all)
              PopupMenuItem(
                value: c,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name),
                  subtitle: Text(summary(c)),
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                chosen != null || suggestion != null
                    ? 'Change'
                    : 'Use a regular client map…',
                style: TextStyle(color: Colors.indigo.shade700),
              ),
              Icon(Icons.arrow_drop_down, color: Colors.indigo.shade700),
            ]),
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.groups_outlined,
                  size: 18, color: Colors.indigo.shade400),
              const SizedBox(width: 8),
              if (chosen != null) ...[
                Flexible(
                  child: Text(
                    'Regular client map: ${chosen.name} — ${summary(chosen)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _regularClientId = ''),
                  child: const Text('Clear'),
                ),
              ] else if (suggestion != null) ...[
                Flexible(
                  child: Text(
                    'Regular client map: ${suggestion.name} — '
                    '${summary(suggestion)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => _useRegularClient(suggestion),
                  child: const Text('Use'),
                ),
              ],
              picker,
            ],
          ),
        );
      },
    );
  }

  void _useRegularClient(RegularClient c) {
    setState(() {
      _regularClientId = c.id;
      if (c.totalManDays > 0) {
        _manDaysController.text = c.totalManDays.toStringAsFixed(1);
      }
      // Picking the plan names the client: the plan's name is the one the
      // client goes by, and a half-typed or stale name would otherwise stay.
      _clientController.text = c.name;
    });
    _matchCustomerToClientName();
  }

  /// Link the invoice customer to the client name, when none is chosen yet —
  /// a customer the user picked by hand is left alone.
  Future<void> _matchCustomerToClientName() async {
    final typed = _clientController.text.trim();
    if (typed.isEmpty) return;

    if (_isXeroJob) {
      if (_xeroContact != null) return;
      try {
        final page = await ref
            .read(xeroAccountingServiceRiverpod)
            .listContacts(searchTerm: typed, pageSize: 5);
        if (!mounted || _xeroContact != null) return;
        final needle = typed.toLowerCase();
        for (final contact in page.items) {
          if (contact.displayName.trim().toLowerCase() == needle) {
            setState(() => _xeroContact = contact);
            break;
          }
        }
      } catch (_) {
        // No match is the normal outcome.
      }
      return;
    }

    if (_invoiceProvider != AccountingProvider.zoho) return;
    if (_zohoCustomer != null) return;
    final customers = ref.read(zohoCustomersRiverpod(_zohoOrgId));
    await customers.initialize();
    if (!mounted || _zohoCustomer != null) return;
    final match = customers.findByName(_clientController.text.trim());
    if (match != null) setState(() => _zohoCustomer = match);
  }

  /// Handles a job type selection change. Extracted so both the compact
  /// and expanded form layouts stay in sync and behave identically.
  void _onJobTypeChanged(String newId) {
    final previousZohoOrg = _zohoOrgId;
    setState(() {
      _selectedJobType = newId;
      // Reset vehicle/trailer combo whenever the type changes. If the new
      // type participates in the Collection Schedule, also reset the
      // quantity placeholder to "1".
      _selectedVehicleTrailerCombo = null;
      if (VehicleTrailerCombo.isVehicleJobType(newId)) {
        _quantityController.text = '1';
      }
    });

    // The invoice follows the job type: a different service is a different
    // catalogue item, with its own description and price. Both providers keep
    // a price list, so both follow.
    _reseedXeroLineForJobType();
    _reseedZohoLineForJobType();

    if (_zohoOrgId != previousZohoOrg) _onZohoOrgChanged();
  }

  /// The job type moved to a company with different Zoho books. A customer
  /// picked from the old organisation does not exist in the new one, so it is
  /// dropped and the client name matched again against the new book.
  Future<void> _onZohoOrgChanged() async {
    setState(() {
      _zohoCustomer = null;
      for (final draft in _splitDrafts) {
        if (draft.linked == null) draft.zohoCustomer = null;
      }
    });
    if (_invoiceProvider != AccountingProvider.zoho) return;

    final orgId = _zohoOrgId;
    final customers = ref.read(zohoCustomersRiverpod(orgId));
    await customers.initialize();
    if (!mounted || orgId != _zohoOrgId || _zohoCustomer != null) return;
    final match = customers.findByName(_clientController.text.trim());
    if (match != null) setState(() => _zohoCustomer = match);
  }

  /// Resolves a Material [IconData] for the [CustomJobType.iconName] string.
  /// Kept in sync with the 12-option picker in `JobTypeManagementDialog`.
  IconData _iconDataForJobType(String? name) {
    switch (name) {
      case 'work_outline':
        return Icons.work_outline;
      case 'local_shipping':
        return Icons.local_shipping;
      case 'home_repair_service':
        return Icons.home_repair_service;
      case 'cleaning_services':
        return Icons.cleaning_services;
      case 'solar_power':
        return Icons.solar_power;
      case 'delete_outline':
        return Icons.delete_outline;
      case 'move_to_inbox':
        return Icons.move_to_inbox;
      case 'description':
        return Icons.description;
      case 'article':
        return Icons.article;
      case 'calendar_month':
        return Icons.calendar_month;
      case 'handyman':
        return Icons.handyman;
      case 'build':
        return Icons.build;
      default:
        return Icons.work_outline;
    }
  }

  /// Modern tap-to-open job-type selector. Renders the selected type's
  /// colored avatar + label + chevron in an outlined field; tapping opens
  /// an anchored dropdown menu positioned directly below the field.
  Widget _buildJobTypeField() {
    final provider = ref.watch(jobTypeRiverpod);
    final selected = provider.getJobTypeById(_selectedJobType);
    final accent = selected?.colorValue != null
        ? Color(selected!.colorValue!)
        : Theme.of(context).colorScheme.primary;
    final iconColor =
        accent.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

    return _PickerFieldShell(
      label: 'Job Type *',
      accent: accent,
      leading: Icon(
        _iconDataForJobType(selected?.iconName),
        size: 14,
        color: iconColor,
      ),
      text: selected?.label ?? 'Select job type',
      isPlaceholder: selected == null,
      onTap: (ctx) => _showJobTypePicker(ctx, provider.jobTypes),
    );
  }

  /// Builds the Job Status picker field matching [_buildJobTypeField]'s style.
  Widget _buildJobStatusField() {
    final statusProvider = ref.watch(jobListStatusRiverpod);
    var statuses = statusProvider.getStatusesForJobType(_selectedJobType);
    // Keep current selection valid even if the status would normally be
    // hidden for the selected job type.
    if (!statuses.any((s) => s.id == _selectedJobStatusId)) {
      final current = statusProvider.getStatusById(_selectedJobStatusId);
      if (current != null) {
        statuses = [current, ...statuses];
      }
    }
    final current = statusProvider.getStatusById(_selectedJobStatusId);
    final accent = current?.color ?? Theme.of(context).colorScheme.primary;

    return _PickerFieldShell(
      label: 'Job Status *',
      accent: accent,
      text: current?.label ?? 'Select status',
      isPlaceholder: current == null,
      onTap: (ctx) => _showJobStatusPicker(ctx, statuses),
    );
  }

  /// Builds the Vehicle & Trailer picker field matching the unified style.
  Widget _buildVehicleTrailerField() {
    final combos = VehicleTrailerCombo.forJobType(_selectedJobType);
    final selected = _selectedVehicleTrailerCombo;
    final accent = Theme.of(context).colorScheme.primary;

    return _PickerFieldShell(
      label: 'Vehicle & Trailer *',
      accent: accent,
      leading: const Icon(Icons.local_shipping, size: 14, color: Colors.white),
      text: selected?.label ?? 'Select vehicle & trailer',
      isPlaceholder: selected == null,
      onTap: (ctx) => _showVehicleTrailerPicker(ctx, combos),
    );
  }

  /// Opens an anchored dropdown menu beneath the tapped field and returns
  /// the selected job type id. Uses [showMenu] for native anchoring.
  Future<void> _showJobTypePicker(
    BuildContext anchorContext,
    List<CustomJobType> jobTypes,
  ) async {
    // Grouped by owning company, in a fixed order — Community Life Media, then
    // Junk & Stuff, then Happy Sun — with any other company after them. Order
    // within a group is the job types' own.
    const companyOrder = [
      Company.clmId,
      Company.junkAndStuffId,
      Company.happySunId,
    ];
    final groups = <String, List<CustomJobType>>{};
    for (final t in jobTypes) {
      groups.putIfAbsent(t.resolvedCompanyId, () => []).add(t);
    }
    final groupIds = [
      ...companyOrder.where(groups.containsKey),
      ...groups.keys.where((id) => !companyOrder.contains(id)),
    ];
    final companies = ref.read(companyRiverpod);

    // One menu entry holding every section, so the sections can collapse —
    // a plain list of menu items cannot change once the menu is open.
    final picked = await _showAnchoredMenu<String>(
      anchorContext: anchorContext,
      maxHeight: 520,
      items: [
        _JobTypeGroupsMenuEntry(
          groups: [
            for (final companyId in groupIds)
              _JobTypeGroup(
                companyId: companyId,
                name: companies.getById(companyId)?.name ??
                    _fallbackCompanyName(companyId),
                color: _companyColor(companies.getById(companyId), companyId),
                types: groups[companyId]!,
              ),
          ],
          selectedId: _selectedJobType,
          collapsed: _collapsedJobTypeGroups,
          iconFor: _iconDataForJobType,
        ),
      ],
    );
    if (picked != null && picked != _selectedJobType) {
      _onJobTypeChanged(picked);
    }
  }

  /// Job type menu sections collapsed by the user, by company id. Kept for the
  /// life of the dialog so a collapsed section stays collapsed on reopening.
  final Set<String> _collapsedJobTypeGroups = {};

  /// A company's section colour: its own when set in Settings → Companies,
  /// otherwise a fixed one per known company so the sections never look alike.
  static Color _companyColor(Company? company, String companyId) {
    if (company?.colorValue != null) return company!.color;
    switch (companyId) {
      case Company.clmId:
        return const Color(0xFF1E6FD9);
      case Company.junkAndStuffId:
        return const Color(0xFFE5701A);
      case Company.happySunId:
        return const Color(0xFFD4A20B);
      default:
        return const Color(0xFF7A8794);
    }
  }

  /// Heading for a company whose document has not loaded.
  static String _fallbackCompanyName(String companyId) {
    switch (companyId) {
      case Company.clmId:
        return 'Community Life Media';
      case Company.junkAndStuffId:
        return 'Junk & Stuff';
      case Company.happySunId:
        return 'Happy Sun';
      default:
        return companyId;
    }
  }

  Future<void> _showJobStatusPicker(
    BuildContext anchorContext,
    List<CustomJobListStatus> statuses,
  ) async {
    final picked = await _showAnchoredMenu<String>(
      anchorContext: anchorContext,
      items: statuses.map((s) {
        return PopupMenuItem<String>(
          value: s.id,
          padding: EdgeInsets.zero,
          height: 0,
          child: _SimplePickerRow(
            color: s.color,
            label: s.label,
            selected: s.id == _selectedJobStatusId,
          ),
        );
      }).toList(),
    );
    if (picked != null && picked != _selectedJobStatusId) {
      setState(() => _selectedJobStatusId = picked);
    }
  }

  Future<void> _showVehicleTrailerPicker(
    BuildContext anchorContext,
    List<VehicleTrailerCombo> combos,
  ) async {
    final accent = Theme.of(context).colorScheme.primary;
    final picked = await _showAnchoredMenu<VehicleTrailerCombo>(
      anchorContext: anchorContext,
      items: combos.map((c) {
        return PopupMenuItem<VehicleTrailerCombo>(
          value: c,
          padding: EdgeInsets.zero,
          height: 0,
          child: _SimplePickerRow(
            color: accent,
            icon: Icons.local_shipping,
            label: c.label,
            selected: c == _selectedVehicleTrailerCombo,
          ),
        );
      }).toList(),
    );
    if (picked != null && picked != _selectedVehicleTrailerCombo) {
      setState(() {
        _selectedVehicleTrailerCombo = picked;
        _quantityController.text =
            (picked.legacyQuantity(jobTypeId: _selectedJobType)).toString();
      });
    }
  }

  /// Generic anchored menu helper. Computes the field's global rect and
  /// opens [showMenu] just below it, constrained to the field width.
  Future<T?> _showAnchoredMenu<T>({
    required BuildContext anchorContext,
    required List<PopupMenuEntry<T>> items,
    double extraWidth = 40,
    double maxHeight = 420,
  }) async {
    final button = anchorContext.findRenderObject() as RenderBox?;
    final overlay = Navigator.of(anchorContext)
        .overlay
        ?.context
        .findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return null;
    final topLeft = button.localToGlobal(
      Offset(0, button.size.height + 4),
      ancestor: overlay,
    );
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      overlay.size.width - bottomRight.dx,
      overlay.size.height - topLeft.dy,
    );
    return showMenu<T>(
      context: anchorContext,
      position: position,
      constraints: BoxConstraints(
        minWidth: button.size.width,
        maxWidth: button.size.width + extraWidth,
        maxHeight: maxHeight,
      ),
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      items: items,
    );
  }

  /// Builds an Autocomplete widget for the Area field that suggests
  /// shareable map names as the user types. Selecting a suggestion
  /// inserts the shareable map link URL into the field.
  Widget _buildAreaAutocomplete() {
    // When copying a job that has a linked map, show a read-only hint
    // instead of an empty editable field — the map URL will be filled in
    // automatically once the cloud function finishes cloning the map.
    final areaLabel = _jobTypeHasTwoStops ? 'Loading Address' : 'Area';
    if (widget.mapWillBeCopied) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: areaLabel,
          border: const OutlineInputBorder(),
        ),
        child: const Text(
          'Map will be copied',
          style: TextStyle(
            color: Colors.blueGrey,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    return Autocomplete<_MapSuggestion>(
      initialValue: TextEditingValue(text: _areaController.text),
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return const Iterable<_MapSuggestion>.empty();
        }
        return TextSearch(textEditingValue.text)
            .rank(_mapSuggestions, (s) => [s.name])
            .take(5);
      },
      displayStringForOption: (_MapSuggestion s) => s.url,
      onSelected: (_MapSuggestion selected) {
        _areaController.text = selected.url;
      },
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        // Sync the autocomplete controller with our _areaController
        // so the form reads the correct value on save.
        textController.addListener(() {
          if (_areaController.text != textController.text) {
            _areaController.text = textController.text;
          }
        });
        // The map names are fetched the first time the field is used, not
        // whenever the dialog opens.
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (hasFocus) {
            if (hasFocus) unawaited(_loadMapNames());
          },
          child: TextFormField(
            controller: textController,
            focusNode: focusNode,
            decoration: InputDecoration(
              labelText: areaLabel,
              border: const OutlineInputBorder(),
            ),
            onFieldSubmitted: (_) => onFieldSubmitted(),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 350),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.map_outlined,
                        size: 18, color: Color(0xFF1967D2)),
                    title:
                        Text(option.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      option.url,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF5F6368)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Amount field. Amounts are always entered excluding VAT; for a job type
  /// with `chargesVat = true` the incl-VAT figure is shown beneath it.
  Widget _buildAmountField() {
    final typeChargesVat =
        JobTypeProvider.instance?.chargesVat(_selectedJobType) ?? false;

    String? helperText;
    if (typeChargesVat) {
      final vatPct = ref.watch(vatSettingsRiverpod).vatPercentage;
      final entered = double.tryParse(_amountController.text) ?? 0.0;
      if (entered > 0) {
        final incl = entered * (1 + vatPct / 100);
        helperText = '= R ${incl.toStringAsFixed(2)} incl VAT';
      }
    }

    return TextFormField(
      controller: _amountController,
      decoration: InputDecoration(
        labelText: typeChargesVat ? 'Amount (excl VAT)' : 'Amount',
        border: const OutlineInputBorder(),
        prefixText: 'R ',
        helperText: helperText,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
      ],
      onChanged: (_) => setState(() {}),
      validator: (value) {
        if (value != null && value.isNotEmpty) {
          if (double.tryParse(value) == null) {
            return 'Please enter a valid amount';
          }
        }
        return null;
      },
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _invoiceController.dispose();
    _amountController.dispose();
    _clientClashTimer?.cancel();
    _clientFocus.dispose();
    _clientController.removeListener(_onClientTextChanged);
    _clientController.dispose();
    _contactPersonController.dispose();
    _contactPhoneController.dispose();
    _areaController.dispose();
    _quantityController.dispose();
    _manDaysController.removeListener(_onManDaysChanged);
    _manDaysController.dispose();
    _offloadingAddressController.dispose();
    _collectionAddressController.dispose();
    _specialInstructionsController.dispose();
    _quantityDistributedController.dispose();
    _invoiceDetailsController.dispose();
    _reportAddressesController.dispose();
    _whoToInvoiceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // WATCHED, not read. CompanyProvider loads asynchronously from its own
    // constructor, so the first build of this dialog sees an empty company
    // list: `providerForJobType` finds no company, resolves to
    // AccountingProvider.none, and the invoicing section silently does not
    // render. With `read` the dialog never heard that the load finished, so it
    // stayed that way — a CLM job would save with no invoice and no
    // explanation. Subscribing here rebuilds once the companies arrive.
    ref.watch(companyRiverpod);

    final isEditing =
        widget.jobToEdit != null && widget.jobToEdit!.id.isNotEmpty;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 768;

    return Dialog(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SafeArea(
            child: Container(
              // Sized to the screen rather than to a fixed box. It used to be
              // capped at 900x700 on desktop, so a large monitor still scrolled
              // a form that would have fitted twice over. The caps that remain
              // are generous enough to be reached only on very large displays,
              // where an unbounded dialog would stretch lines past comfortable
              // reading width.
              width: isMobile
                  ? MediaQuery.of(context).size.width * 0.95
                  : MediaQuery.of(context).size.width * 0.9,
              height: isMobile
                  ? MediaQuery.of(context).size.height * 0.95
                  : MediaQuery.of(context).size.height * 0.92,
              constraints: BoxConstraints(
                maxWidth:
                    isMobile ? MediaQuery.of(context).size.width * 0.95 : 1500,
                maxHeight: isMobile
                    ? MediaQuery.of(context).size.height * 0.95
                    : MediaQuery.of(context).size.height * 0.92,
                minWidth: 300,
                minHeight: 400,
              ),
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          isEditing
                              ? 'Edit Job'
                              : (_isCopy ? 'Copy Job' : 'Add New Job'),
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: _isProcessing
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Form
                  Expanded(
                    child: Form(
                      key: _formKey,
                      child: Scrollbar(
                        controller: _scrollController,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          clipBehavior: Clip.hardEdge,
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            children: [
                              // Row 1: Invoice, Amount, Client.
                              //
                              // The first two are gone wherever the app raises
                              // the invoice: the provider issues the number and
                              // the invoice lines settle the amount, both
                              // written back on link. Client then takes the
                              // full row rather than leaving a gap.
                              _buildClientLine(isMobile),
                              _buildRegularClientRow(),
                              const SizedBox(height: 16),

                              // Row 2: Job Status, Job Type - Responsive Layout
                              isMobile
                                  ? Column(
                                      children: [
                                        _buildAreaAutocomplete(),
                                        const SizedBox(height: 12),
                                        _buildJobStatusField(),
                                        const SizedBox(height: 12),
                                        _buildJobTypeField(),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Flexible(
                                          child: _buildAreaAutocomplete(),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child: _buildJobStatusField(),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child: _buildJobTypeField(),
                                        ),
                                      ],
                                    ),
                              // Offloading address — only for two-stop job types
                              if (_jobTypeHasTwoStops) ...[
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _offloadingAddressController,
                                  decoration: const InputDecoration(
                                    labelText: 'Offloading Address',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ],

                              const SizedBox(height: 16),

                              // Row 3: Area, Quantity (conditional based on job type)
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: (VehicleTrailerCombo
                                            .isVehicleJobType(_selectedJobType))
                                        ? _buildVehicleTrailerField()
                                        : TextFormField(
                                            controller: _quantityController,
                                            decoration: const InputDecoration(
                                              labelText: 'Quantity / Vehicle',
                                              border: OutlineInputBorder(),
                                            ),
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly
                                            ],
                                          ),
                                  ),
                                  const SizedBox(width: 16),
                                  // Man-Days field
                                  Expanded(
                                    flex: 1,
                                    child: TextFormField(
                                      controller: _manDaysController,
                                      decoration: const InputDecoration(
                                        labelText: 'Man-Days *',
                                        border: OutlineInputBorder(),
                                      ),
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'^\d+\.?\d{0,2}'),
                                        )
                                      ],
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Man-Days is required';
                                        }
                                        final doubleValue =
                                            double.tryParse(value);
                                        if (doubleValue == null) {
                                          return 'Please enter a valid number';
                                        }
                                        if (doubleValue <= 0) {
                                          return 'Man-Days must be greater than 0';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(flex: 2, child: _buildDateField()),
                                ],
                              ),
                              // An appointment's time slot, picked in one
                              // drag. Junk & Stuff bookings show on the
                              // Collection Schedule at this time and length.
                              if (_needsTimeSelection(_selectedJobType)) ...[
                                const SizedBox(height: 16),
                                _buildTimeSlotField(),
                              ],
                              const SizedBox(height: 16),
                              // Row 4: collection — Needs flyer collection
                              // (Community Life Media only), Collection Date
                              // and Collection Address on one line.
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_isClmJob) ...[
                                    Expanded(
                                      flex: 2,
                                      child: _buildFlyerCollectionTick(),
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  // Collection Date is redundant for Junk &
                                  // Stuff: leaving it unset stores the
                                  // 2000-01-01 sentinel, and the Collection
                                  // Schedule already falls back to the job's
                                  // Date when it sees that
                                  // (collection_schedule_provider.dart
                                  // `effectiveDate`). Dragging a job on that
                                  // grid still writes a real collectionDate,
                                  // time slot included, which this no longer
                                  // competes with.
                                  if (!_isJunkAndStuffJob) ...[
                                    Expanded(
                                      flex: 2,
                                      child: _buildCollectionDateField(),
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  Expanded(
                                    flex: 3,
                                    child: TextFormField(
                                      controller: _collectionAddressController,
                                      decoration: const InputDecoration(
                                        labelText: 'Collection Address',
                                        border: OutlineInputBorder(),
                                      ),
                                      // One line like its neighbours; grows
                                      // to two for a long address.
                                      minLines: 1,
                                      maxLines: 2,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Row 5: Special Instructions
                              TextFormField(
                                controller: _specialInstructionsController,
                                decoration: const InputDecoration(
                                  labelText: 'Special Instructions',
                                  border: OutlineInputBorder(),
                                ),
                                maxLines: 2,
                              ),
                              const SizedBox(height: 16),

                              // Conditionally show fields based on job type flags.
                              // Non-Happy-Sun jobs get Quantity/Invoice/Report rows;
                              // Happy Sun jobs get the Tools Needed panel further down.
                              if (!(JobTypeProvider.instance
                                      ?.isHappySunService(_selectedJobType) ??
                                  false)) ...[
                                // Row 7: Quantity Distributed & Invoice Details.
                                // The quantity field is only shown when the
                                // selected job type tracks a quantity, and its
                                // label comes from the type's `quantityLabel`.
                                // Row 7 in full — the distributed count and
                                // Invoice Details both belong to the invoice
                                // now: its lines carry the quantities and the
                                // description.
                                if (!_hideInvoiceOwnedFields)
                                Row(
                                  children: [
                                    if (JobTypeProvider.instance
                                                ?.tracksQuantity(
                                                    _selectedJobType) ??
                                            true) ...[
                                      Expanded(
                                        child: TextFormField(
                                          controller:
                                              _quantityDistributedController,
                                          decoration: InputDecoration(
                                            labelText: JobTypeProvider.instance
                                                    ?.quantityLabel(
                                                        _selectedJobType) ??
                                                'Quantity',
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                    ],
                                    Expanded(
                                      child: TextFormField(
                                        controller: _invoiceDetailsController,
                                        decoration: const InputDecoration(
                                          labelText: 'Invoice Details',
                                          border: OutlineInputBorder(),
                                        ),
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                ),
                                // Row 8: Report Addresses & Who to Invoice.
                                // Both are said on the Xero invoice for a CLM
                                // job — the contact is who it is billed to, and
                                // the line description carries the detail.
                                if (!_hideInvoiceOwnedFields) ...[
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller:
                                              _reportAddressesController,
                                          decoration: const InputDecoration(
                                            labelText: 'Report Addresses',
                                            border: OutlineInputBorder(),
                                          ),
                                          maxLines: 1,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _whoToInvoiceController,
                                          decoration: const InputDecoration(
                                            labelText: 'Who to Invoice',
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],

                              // Tools Needed button for Happy Sun-flagged types.
                              if (JobTypeProvider.instance
                                      ?.isHappySunService(_selectedJobType) ??
                                  false) ...[
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _showToolsDialog,
                                  icon: const Icon(Icons.build),
                                  label: Text(
                                    _toolsNeeded != null &&
                                            _toolsNeeded!.totalCount > 0
                                        ? 'Tools Needed (${_toolsNeeded!.totalCount})'
                                        : 'Add Tools Needed',
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ],

                              // Invoicing — Zoho or Xero, per the job type's
                              // company. Hidden for types that raise none.
                              //
                              // When a job type belongs to a business that DOES
                              // invoice but the provider will not resolve, say
                              // so rather than rendering nothing: a missing
                              // section is indistinguishable from "this job is
                              // not invoiced", which is how a CLM job could be
                              // saved uninvoiced without anyone noticing.
                              if (!_showInvoicingSection &&
                                  _invoicedFromInsideTheApp) ...[
                                const SizedBox(height: 20),
                                _buildInvoicingUnavailableNotice(),
                              ],
                              if (_showInvoicingSection) ...[
                                const SizedBox(height: 20),
                                _buildInvoicingSection(),
                                const SizedBox(height: 12),
                                _buildSplitInvoicesSection(),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // A save still running on a slow connection says so —
                  // the invoice run has its own panel with the same hint.
                  SlowActionHint(
                      busy: _isProcessing && !_sagaActive,
                      action: 'Saving the job'),

                  const SizedBox(height: 16),

                  // Action buttons
                  isMobile
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!isEditing && _jobTypeAutoAllocates)
                              ElevatedButton(
                                // Disabled once the invoicing saga has run —
                                // the job is already written, so this would
                                // save a second copy.
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : _saveJobWithoutAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color.fromARGB(255, 247, 224, 189),
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : Text(_willInvoice
                                        ? 'Skip Allocation + $_invoiceButtonNoun'
                                        : 'Skip Allocation'),
                              ),
                            if (!isEditing && _jobTypeAutoAllocates)
                              const SizedBox(height: 8),
                            if (isEditing && _jobTypeAutoAllocates)
                              ElevatedButton(
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : _saveJobWithAutomaticAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Automatic Allocation'),
                              ),
                            if (isEditing && _jobTypeAutoAllocates)
                              const SizedBox(height: 8),
                            // Escape hatch for an edit whose invoice cannot
                            // be pushed — no Zoho/Xero contact resolved, line
                            // items incomplete, a settled invoice. Those guards
                            // belong to the invoice, not to the job, and were
                            // blocking ordinary Job List edits outright.
                            if (isEditing && _willInvoice && !_sagaActive) ...[
                              OutlinedButton(
                                onPressed: _isProcessing ? null : _saveJob,
                                child: const Text('Update Job Only'),
                              ),
                              const SizedBox(height: 8),
                            ],
                            // With invoicing on, the save runs the saga and
                            // the dialog stays open until the user confirms;
                            // its own Done button closes it, so hide this one
                            // once the sequence has started.
                            if (!(_willInvoice && _sagaActive))
                              ElevatedButton(
                                // Also off once an invoice run has started:
                                // the job is already written, so saving again
                                // would add a second copy.
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : (_willInvoice
                                        ? _saveJobWithInvoiceAndAllocation
                                        : _saveJob),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.green),
                                        ),
                                      )
                                    : Text(_willInvoice
                                        ? (isEditing
                                            ? 'Update Job + $_invoiceButtonNoun'
                                            : 'Add Job + $_invoiceButtonNoun')
                                        : (isEditing
                                            ? 'Update Job'
                                            : 'Add Job')),
                              ),
                            const SizedBox(height: 8),
                            if (_canDraft)
                              TextButton.icon(
                                onPressed: (_isProcessing ||
                                        _isSavingDraft ||
                                        _sagaActive)
                                    ? null
                                    : _saveDraftAndClose,
                                icon: _isSavingDraft
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.bookmark_border,
                                        size: 18),
                                label: const Text('Save for later'),
                              ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                          ],
                        )
                      : Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_canDraft)
                              TextButton.icon(
                                onPressed: (_isProcessing ||
                                        _isSavingDraft ||
                                        _sagaActive)
                                    ? null
                                    : _saveDraftAndClose,
                                icon: _isSavingDraft
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.bookmark_border,
                                        size: 18),
                                label: const Text('Save for later'),
                              ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                            if (!isEditing && _jobTypeAutoAllocates)
                              ElevatedButton(
                                // Disabled once the invoicing saga has run —
                                // the job is already written, so this would
                                // save a second copy.
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : _saveJobWithoutAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color.fromARGB(255, 248, 225, 191),
                                  foregroundColor: Colors.black,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : Text(_willInvoice
                                        ? 'Skip Allocation + $_invoiceButtonNoun'
                                        : 'Skip Allocation'),
                              ),
                            if (isEditing && _jobTypeAutoAllocates)
                              ElevatedButton(
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : _saveJobWithAutomaticAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Automatic Allocation'),
                              ),
                            // Mirrors the mobile Column branch above.
                            if (isEditing && _willInvoice && !_sagaActive)
                              OutlinedButton(
                                onPressed: _isProcessing ? null : _saveJob,
                                child: const Text('Update Job Only'),
                              ),
                            // Must mirror the mobile Column branch above: with
                            // invoicing on, this runs the saga and the dialog
                            // stays open until the user confirms, so it hides
                            // once the sequence has started.
                            if (!(_willInvoice && _sagaActive))
                              ElevatedButton(
                                // Also off once an invoice run has started:
                                // the job is already written, so saving again
                                // would add a second copy.
                                onPressed: (_isProcessing || _sagaActive)
                                    ? null
                                    : (_willInvoice
                                        ? _saveJobWithInvoiceAndAllocation
                                        : _saveJob),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : Text(_willInvoice
                                        ? (isEditing
                                            ? 'Update Job + $_invoiceButtonNoun'
                                            : 'Add Job + $_invoiceButtonNoun')
                                        : (isEditing
                                            ? 'Update Job'
                                            : 'Add Job')),
                              ),
                          ],
                        ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The job's own Invoice Status, moved automatically so it does not have to
  /// be set by hand.
  ///
  /// Only fires on a **transition**, never on every save — otherwise a status
  /// you set deliberately (say Paid) would be dragged back to "outstanding"
  /// the next time the job was edited for an unrelated reason.
  ///
  /// A job carrying a Zoho invoice is left alone entirely: its status is owned
  /// by the Zoho → invoice-status mapping in sync settings.
  String _resolveInvoiceStatusId() {
    final current = widget.jobToEdit?.invoiceStatusId ?? 'pending';
    final settings = ref.read(zohoSyncSettingsRiverpod);

    // Zoho owns the status once an invoice exists or is about to.
    if (_isUpdatingInvoice || _willInvoice) return current;

    final previousNumber = widget.jobToEdit?.invoice.trim() ?? '';
    final enteredNumber = _invoiceController.text.trim();

    // An invoice number typed in by hand means billed but unpaid.
    if (previousNumber.isEmpty && enteredNumber.isNotEmpty) {
      final id = settings.invoiceEnteredStatusId;
      if (id.isNotEmpty) return id;
    }

    // A new or copied job saved with no invoice at all: INV_NOT CREATED.
    final isNewOrCopy = widget.jobToEdit == null || _isCopy;
    if (isNewOrCopy && enteredNumber.isEmpty) {
      final id = settings.noInvoiceStatusId;
      return id.isNotEmpty ? id : kNoInvoiceStatusFallbackId;
    }

    return current;
  }

  /// The job's date. For an appointment it is the day only — the time is
  /// picked in the Time slot field beside it.
  Widget _buildDateField() {
    final appointment = _needsTimeSelection(_selectedJobType);
    final job = widget.jobToEdit;
    // A booking dragged to another day on the Collection Schedule shows
    // there on that day; say so, until a day is picked here.
    String? scheduleNote;
    if (appointment &&
        !_appointmentDayEdited &&
        job != null &&
        job.collectionDate.year != 2000 &&
        _selectedDate != null &&
        !DateUtils.isSameDay(job.collectionDate, _selectedDate) &&
        (JobTypeProvider.instance
                ?.appearsOnCollectionSchedule(_selectedJobType) ??
            false)) {
      scheduleNote = 'On the Collection Schedule: '
          '${DateFormat('EEE d MMM').format(job.collectionDate)}';
    }
    return FormField<DateTime>(
      initialValue: _selectedDate,
      validator: (_) {
        if (_selectedDate == null) {
          return appointment
              ? 'Appointment date is required'
              : 'Distribution Date is required';
        }
        // Adding or copying: not in the past. A job copied from May with
        // its date left alone landed back in May.
        return _pastDateProblem(_selectedDate);
      },
      builder: (FormFieldState<DateTime> state) {
        return InkWell(
          onTap: () async {
            final date = await _pickJobDate(_selectedDate);
            if (date == null || !mounted) return;
            setState(() {
              _selectedDate = date;
              _appointmentDayEdited = true;
            });
            // The clash is per month.
            _scheduleClientClashCheck();
            state.didChange(date);
            if (state.hasError) state.validate();
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText:
                  appointment ? 'Appointment Date *' : 'Distribution Date *',
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.calendar_today),
              errorText: state.errorText,
              errorMaxLines: 2,
              helperText: scheduleNote,
              helperMaxLines: 2,
            ),
            child: Text(_selectedDate != null
                ? DateFormat('dd MMM yyyy').format(_selectedDate!)
                : appointment
                    ? 'Select Appointment Date'
                    : 'Select Distribution Date'),
          ),
        );
      },
    );
  }

  /// Other bookings of the chosen vehicle on the appointment's day (Junk &
  /// Stuff vehicle jobs); empty for anything else.
  List<CollectionJob> _sameVehicleBookings() {
    final combo = _selectedVehicleTrailerCombo;
    final date = _selectedDate;
    if (combo == null ||
        date == null ||
        !VehicleTrailerCombo.isVehicleJobType(_selectedJobType)) {
      return const [];
    }
    final ownId = widget.jobToEdit?.id ?? '';
    return ref
        .watch(collectionScheduleRiverpod)
        .getJobsForDate(date)
        .where((b) =>
            b.vehicleType == combo.vehicleType &&
            (ownId.isEmpty || b.id != ownId))
        .toList();
  }

  /// The appointment's time slot, picked in one go on the Collection
  /// Schedule's half-hour rows: drag across the times, or tap one to move
  /// the booking there. Overlapping another booking of the same vehicle is
  /// flagged, not refused — as on the Collection Schedule itself.
  Widget _buildTimeSlotField() {
    final start = _slotStart;
    final count = start != null && slotLengthOptions(start).contains(_slotCount)
        ? _slotCount
        : null;

    final bookings = _sameVehicleBookings();
    String who(CollectionJob b) =>
        b.clients.isNotEmpty ? b.clients.first : 'Another job';
    final clashes = start == null || count == null
        ? const <CollectionJob>[]
        : [
            for (final b in bookings)
              if (slotsOverlap(start, count, b.timeSlot, b.timeSlots)) b,
          ];
    final vehicle = _selectedVehicleTrailerCombo?.vehicleType.name
            .toUpperCase() ??
        'The vehicle';
    final clashText = clashes.isEmpty
        ? null
        : '⚠️ $vehicle is also booked '
            '${clashes.map((b) => '${slotRange(b.timeSlot, b.timeSlots)} (${who(b)})').join(', ')}'
            ' — it can still be booked';

    final theme = Theme.of(context);
    return FormField<String>(
      validator: (_) {
        if (!_needsTimeSelection(_selectedJobType)) return null;
        if (_slotStart == null ||
            !slotLengthOptions(_slotStart!).contains(_slotCount)) {
          return 'Drag across the times to pick the time slot';
        }
        return null;
      },
      builder: (FormFieldState<String> state) {
        return InputDecorator(
          isEmpty: false,
          decoration: InputDecoration(
            labelText: 'Time slot *',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
            errorText: state.errorText,
            helperText: clashText,
            helperMaxLines: 3,
            helperStyle: const TextStyle(color: Colors.orange),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (start != null && count != null)
                    Text(
                      '${slotRange(start, count)}  ·  ${slotLength(count)}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  Text(
                    start != null && count != null
                        ? 'Drag to change it, or tap a time to move it'
                        : 'Drag across the times — press on the start, '
                            'let go on the end',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TimeSlotStrip(
                start: start,
                slots: count,
                enabled: !_isProcessing,
                booked: [
                  for (final b in bookings)
                    (start: b.timeSlot, slots: b.timeSlots, label: who(b)),
                ],
                onChanged: (newStart, slots) {
                  setState(() {
                    _slotStart = newStart;
                    _slotCount = slots;
                  });
                  state.didChange('$newStart/$slots');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// The "Needs flyer collection" tick, boxed like the fields beside it
  /// (Collection Date, Collection Address) and the same height.
  Widget _buildFlyerCollectionTick() {
    final enabled = !_isProcessing;
    void toggle() =>
        setState(() => _needsFlyerCollection = !_needsFlyerCollection);
    return Tooltip(
      message: 'Tick if the flyers must be collected before they can be '
          'distributed',
      child: InkWell(
        onTap: enabled ? toggle : null,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          isEmpty: false,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            // 12 + 32 (compact checkbox) + 12 = a standard 56 px field.
            contentPadding: EdgeInsets.fromLTRB(4, 12, 12, 12),
          ),
          child: Row(
            children: [
              Checkbox(
                value: _needsFlyerCollection,
                onChanged: enabled ? (_) => toggle() : null,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 4),
              const Flexible(
                child: Text(
                  'Needs flyer collection',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Collection Date. Optional: left unset it stores the 2000-01-01
  /// sentinel (see [_buildJobListItem]).
  Widget _buildCollectionDateField() {
    return FormField<DateTime>(
      initialValue: _selectedCollectionDate,
      validator: (_) => _pastDateProblem(_selectedCollectionDate),
      builder: (FormFieldState<DateTime> state) {
        void set(DateTime? date) {
          setState(() => _selectedCollectionDate = date);
          state.didChange(date);
          if (state.hasError) state.validate();
        }

        return InkWell(
          onTap: () async {
            final date = await _pickJobDate(_selectedCollectionDate);
            if (date != null && mounted) set(date);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Collection Date',
              border: const OutlineInputBorder(),
              // A copied job can bring the old job's collection date with
              // it, so the date can be cleared as well as changed.
              suffixIcon: _selectedCollectionDate == null
                  ? const Icon(Icons.calendar_today)
                  : IconButton(
                      key: const ValueKey('clearCollectionDate'),
                      tooltip: 'Clear the collection date',
                      icon: const Icon(Icons.clear),
                      onPressed: _isProcessing ? null : () => set(null),
                    ),
              errorText: state.errorText,
              errorMaxLines: 2,
            ),
            child: Text(_selectedCollectionDate != null
                ? DateFormat('dd MMM yyyy').format(_selectedCollectionDate!)
                : 'Select Collection Date'),
          ),
        );
      },
    );
  }

  JobListItem _buildJobListItem() {
    final bool isNew = widget.jobToEdit == null;

    // Preserve existing updates, or initialize empty list
    List<JobListItemUpdate> currentUpdates =
        widget.jobToEdit?.updates.toList() ?? [];

    // Log creation if this is a new job
    if (isNew) {
      final authProvider = mounted ? ref.read(authRiverpod) : null;
      final userId = authProvider?.user?.uid ?? 'system';
      final userName = authProvider?.appUser?.name ??
          authProvider?.user?.displayName ??
          'System';

      currentUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'created',
        oldValue: null,
        newValue: 'Job created',
        timestamp: DateTime.now(),
        userDisplayName: userName,
      ));
    }

    final enteredAmount = double.tryParse(_amountController.text) ?? 0.0;
    final vatProvider = ref.read(vatSettingsRiverpod);
    // Amounts are always entered excluding VAT.
    final exclAmount = enteredAmount;
    final inclAmount = vatProvider.inclFromExcl(enteredAmount);

    final built = JobListItem(
      id: widget.jobToEdit?.id ?? '',
      invoice: _invoiceController.text.trim(),
      amount: enteredAmount,
      client: _clientController.text.trim(),
      contactPerson: _contactPersonController.text.trim(),
      contactPhone: _contactPhoneController.text.trim(),
      jobStatusId: _selectedJobStatusId,
      invoiceStatusId: _resolveInvoiceStatusId(),
      jobTypeId: _selectedJobType,
      area: _areaController.text.trim(),
      quantity: int.tryParse(_quantityController.text) ?? 0,
      manDays: double.tryParse(_manDaysController.text) ?? 0.0,
      regularClientId: _regularClientId,
      date: _selectedDate ?? DateTime.now(),
      collectionAddress: _collectionAddressController.text.trim(),
      collectionDate: _selectedCollectionDate ?? DateTime(2000, 1, 1),
      // Only a Community Life Media job can need its flyers collected; a
      // job moved to another company's type drops the tick.
      needsFlyerCollection: _isClmJob && _needsFlyerCollection,
      specialInstructions: _specialInstructionsController.text.trim(),
      quantityDistributed:
          int.tryParse(_quantityDistributedController.text) ?? 0,
      invoiceDetails: _invoiceDetailsController.text.trim(),
      reportAddresses: _reportAddressesController.text.trim(),
      whoToInvoice: _whoToInvoiceController.text.trim(),
      toolsNeeded: _toolsNeeded,
      updates: currentUpdates,
      customPolygons: widget.jobToEdit?.customPolygons ?? const [],
      reminders: widget.jobToEdit?.reminders ?? const [],
      collectionJobId: widget.jobToEdit?.collectionJobId ?? '',
      vehicleTrailerCombo: _selectedVehicleTrailerCombo?.name ?? '',
      offloadingAddress: _offloadingAddressController.text.trim(),
      amountExclVat: exclAmount,
      amountInclVat: inclAmount,
      priceIsInclVat: false,
      // Fields the form has no inputs for are carried across explicitly —
      // see JobListItem.withPreservedSystemFields for why omitting them
      // destroys data on a month move.
    ).withPreservedSystemFields(_invoiceUnlinked
        ? widget.jobToEdit?.withoutInvoiceLink()
        : widget.jobToEdit);
    return _withAppointmentSlot(built);
  }

  /// [item] booked for the picked time slot, when its job type takes one:
  /// the date carries the start time (the Dropsheet and Happy Sun read it),
  /// and the Collection Schedule's own copy — time slot, length, and a
  /// collection day set by dragging there — follows.
  JobListItem _withAppointmentSlot(JobListItem item) {
    if (!_needsTimeSelection(_selectedJobType)) return item;
    final start = slotMinutes(_slotStart);
    final count = _slotCount;
    if (start == null || count == null) return item; // the form refuses it
    final day = item.date;
    return item.withAppointment(
      DateTime(day.year, day.month, day.day, start ~/ 60, start % 60),
      slots: count,
      onCollectionSchedule: JobTypeProvider.instance
              ?.appearsOnCollectionSchedule(_selectedJobType) ??
          false,
      moveCollectionDay: _appointmentDayEdited,
    );
  }

  /// Unlink the job's void invoice and switch the invoicing section over to
  /// raising a new one. The live status is re-checked before anything changes.
  Future<void> _unlinkVoidInvoice() async {
    final job = widget.jobToEdit;
    if (job == null) return;
    final unlinked =
        await unlinkVoidedInvoice(context: context, ref: ref, job: job);
    if (!unlinked || !mounted) return;
    setState(() {
      _invoiceUnlinked = true;
      _existingInvoice = null;
      _existingInvoiceError = null;
      // The void number must not be reused for the replacement — Zoho would
      // reject the duplicate, and Xero would carry it as a misleading reference.
      if (_invoiceController.text.trim() == job.resolvedInvoiceNumber) {
        _invoiceController.clear();
      }
      // The void invoice's lines stay as a starting point; a create omits
      // their line_item_ids, so they become new lines on the new invoice.
      _createZohoInvoice = true;
      _createXeroInvoice = true;
    });
  }

  /// True when this dialog is duplicating an existing job. The copy flow
  /// passes the source job with its id cleared.
  bool get _isCopy => widget.jobToEdit != null && widget.jobToEdit!.id.isEmpty;

  /// Adding or copying a job, not editing an existing one. Only then are
  /// past dates refused (see [pastJobDateProblem]).
  bool get _isNewOrCopy => widget.jobToEdit == null || _isCopy;

  /// [pastJobDateProblem] for this dialog's job.
  String? _pastDateProblem(DateTime? picked) => pastJobDateProblem(picked,
      isNewOrCopy: _isNewOrCopy, today: scheduleToday());

  /// A date picker opened on [current]. When adding or copying a job, past
  /// days are greyed out.
  Future<DateTime?> _pickJobDate(DateTime? current) {
    final today = scheduleToday();
    final first =
        earliestPickableJobDate(isNewOrCopy: _isNewOrCopy, today: today);
    final day = current == null
        ? null
        : DateTime(current.year, current.month, current.day);
    return showDatePicker(
      context: context,
      initialDate: day == null || day.isBefore(first) ? today : day,
      firstDate: first,
      lastDate: DateTime(2030),
    );
  }

  /// Pull the source job's invoice across when copying, so a repeat job keeps
  /// its client, line items, descriptions and amounts without retyping.
  ///
  /// Only the *content* is copied. The source `line_item_id`s are dropped —
  /// they belong to the source invoice, and reusing them on a new invoice
  /// would be wrong. The invoice number is deliberately left blank so Zoho
  /// issues a fresh one rather than colliding with the original.
  Future<void> _prefillFromSourceInvoice() async {
    final sourceId = widget.sourceZohoInvoiceId;
    if (sourceId == null || sourceId.isEmpty || !_isCopy) return;

    setState(() => _isLoadingSourceInvoice = true);
    try {
      final source =
          await ref.read(zohoInvoicesRiverpod(_zohoOrgId)).getInvoiceForCopy(sourceId);
      if (!mounted) return;

      final lines = source.lineItems
          .map((li) => ZohoLineItem(
                // lineItemId intentionally omitted — a new invoice's lines.
                itemId: li.itemId,
                name: li.name,
                description: li.description,
                rate: li.rate,
                quantity: li.quantity,
                unit: li.unit,
              ))
          .toList();

      // Prefer the invoice's own customer over the name-matched one — it is
      // the contact actually billed last time.
      final byId = ref.read(zohoCustomersRiverpod(_zohoOrgId)).getById(source.customerId);

      setState(() {
        if (lines.isNotEmpty) {
          _zohoLineItems = lines;
          // Copied from a previous invoice — no longer ours to overwrite.
          _zohoLineAutoSeeded = false;
          final total =
              lines.fold<double>(0, (running, li) => running + li.amount);
          _amountController.text = total.toStringAsFixed(2);
        }
        if (byId != null) _zohoCustomer = byId;
        if (source.notes.isNotEmpty &&
            _invoiceDetailsController.text.trim().isEmpty) {
          _invoiceDetailsController.text = source.notes;
        }
        _copiedFromInvoiceNumber = source.invoiceNumber;
        _isLoadingSourceInvoice = false;
      });
    } catch (e) {
      // Non-fatal: the job still copies, just without the invoice pre-fill.
      if (mounted) {
        setState(() {
          _isLoadingSourceInvoice = false;
          _sourceInvoiceError = 'Could not load the previous invoice: $e';
        });
      }
    }
  }

  /// Load the invoice this job is already linked to, so its lines can be
  /// edited here and pushed back to Zoho on save.
  ///
  /// Read from Zoho rather than trusting the job's cached
  /// `zohoInvoiceNumber` / `zohoInvoiceStatus`: those are a display cache and
  /// may be stale if the invoice was paid or voided in Zoho since.
  Future<void> _loadExistingInvoice() async {
    if (!_isUpdatingInvoice) return;
    final invoiceId = widget.jobToEdit!.zohoInvoiceId;

    setState(() => _isLoadingExistingInvoice = true);
    try {
      final invoice =
          await ref.read(zohoInvoicesRiverpod(_zohoOrgId)).getInvoiceForCopy(invoiceId);
      if (!mounted) return;

      final customers = ref.read(zohoCustomersRiverpod(_zohoOrgId));
      final linked = customers.getById(invoice.customerId);

      setState(() {
        _existingInvoice = invoice;
        // Lines keep their line_item_id so Zoho amends them in place.
        if (invoice.lineItems.isNotEmpty) {
          _zohoLineItems = List.of(invoice.lineItems);
          // These are the live invoice's own lines; a job type change must
          // never rewrite them.
          _zohoLineAutoSeeded = false;
        }
        if (linked != null) _zohoCustomer = linked;
        if (invoice.notes.isNotEmpty &&
            _invoiceDetailsController.text.trim().isEmpty) {
          _invoiceDetailsController.text = invoice.notes;
        }
        if (invoice.invoiceNumber.isNotEmpty) {
          _invoiceController.text = invoice.invoiceNumber;
        }
        // A settled or void invoice cannot be amended, so do not offer to.
        if (!_existingInvoiceIsEditable) _createZohoInvoice = false;
        _isLoadingExistingInvoice = false;
      });
    } catch (e) {
      // Non-fatal — the job is still editable, just not its invoice.
      if (mounted) {
        setState(() {
          _isLoadingExistingInvoice = false;
          _createZohoInvoice = false;
          _existingInvoiceError = 'Could not load invoice from Zoho: $e';
        });
      }
    }
  }

  /// The Zoho invoicing block: toggle, customer picker, line items, and — once
  /// a save has been attempted — the per-step result panel.
  /// Explains why there is no invoicing section on a job that should have one.
  ///
  /// Three separable causes, and the fix differs for each — so it names which
  /// one applies instead of a generic "unavailable".
  Widget _buildInvoicingUnavailableNotice() {
    final companies = ref.watch(companyRiverpod);
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);

    final String message;
    if (companies.isLoading || companies.companies.isEmpty) {
      message = 'Loading company settings…';
    } else if (type != null && !type.createsInvoices) {
      message = '“${type.label}” is set not to create invoices. '
          'Change that under Settings → Job Types if it should.';
    } else {
      final company = type == null ? null : companies.forJobType(type);
      message = company == null
          ? 'This job type’s company could not be found, so there is nothing '
              'to invoice through.'
          : '${company.displayLabel} has no accounting provider set, so no '
              'invoice can be raised. Set one under Settings → Companies.';
    }

    final loading = companies.isLoading || companies.companies.isEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: loading ? ZohoPalette.pageBackground : Colors.orange.shade50,
        border: Border.all(
          color: loading ? ZohoPalette.border : Colors.orange.shade200,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.info_outline, size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: loading
                    ? ZohoPalette.textMuted
                    : Colors.orange.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The invoicing panel for whichever provider this job type bills through.
  Widget _buildInvoicingSection() =>
      _isXeroJob ? _buildXeroInvoicingSection() : _buildZohoInvoicingSection();

  Widget _buildZohoInvoicingSection() {
    final saga = _saga;
    final locked = _isProcessing || (saga?.savedJob != null);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZohoPalette.pageBackground,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long, size: 18, color: ZohoPalette.link),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isUpdatingInvoice
                      ? 'Invoice ${_existingInvoice?.invoiceNumber ?? widget.jobToEdit?.zohoInvoiceNumber ?? ''} (Zoho Books)'
                      : 'Invoicing (Zoho Books)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ZohoPalette.textPrimary,
                  ),
                ),
              ),
              if (_existingInvoice != null) ...[
                ZohoStatusChip(status: _existingInvoice!.status, dense: true),
                const SizedBox(width: 10),
              ],
              Switch(
                // A void or paid invoice cannot be amended in Zoho, so the
                // toggle is disabled rather than failing on save.
                value: _createZohoInvoice,
                onChanged: (locked ||
                        _isLoadingExistingInvoice ||
                        (_isUpdatingInvoice && !_existingInvoiceIsEditable))
                    ? null
                    : (v) => setState(() => _createZohoInvoice = v),
              ),
            ],
          ),
          if (_isLoadingExistingInvoice)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Loading this job’s invoice from Zoho…',
                      style: TextStyle(
                          fontSize: 12, color: ZohoPalette.textMuted)),
                ],
              ),
            ),
          if (_existingInvoiceError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$_existingInvoiceError — the job can still be saved, but its '
                'invoice will not be changed.',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
              ),
            ),
          if (_isUpdatingInvoice && !_existingInvoiceIsEditable)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'This invoice is ${_existingInvoice!.status.label.toLowerCase()} '
                'and cannot be changed. Zoho rejects edits to void invoices, '
                'and amending a settled one would leave the recorded payment '
                'disagreeing with the total.',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
              ),
            ),
          if (_isUpdatingInvoice &&
              _existingInvoice?.status == ZohoInvoiceStatus.isVoid)
            _unlinkVoidInvoiceButton(locked),
          if (!_createZohoInvoice && !_isLoadingExistingInvoice)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _isUpdatingInvoice
                    ? 'Job changes will be saved. The invoice in Zoho will be '
                        'left exactly as it is.'
                    : 'Job will be saved without an invoice. You can invoice '
                        'it later from its Collection Schedule cell.',
                style:
                    const TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
            ),
          if (_createZohoInvoice) ...[
            if (_isUpdatingInvoice)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    const Icon(Icons.sync, size: 14, color: ZohoPalette.link),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Changes below are pushed to the existing invoice — '
                        'no new invoice is created and the number stays '
                        '${_existingInvoice?.invoiceNumber ?? ''}.',
                        style: const TextStyle(
                            fontSize: 11, color: ZohoPalette.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            if (_isLoadingSourceInvoice)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Loading the previous invoice…',
                      style:
                          TextStyle(fontSize: 12, color: ZohoPalette.textMuted),
                    ),
                  ],
                ),
              ),
            if (_copiedFromInvoiceNumber != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    const Icon(Icons.content_copy,
                        size: 14, color: ZohoPalette.link),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pre-filled from invoice $_copiedFromInvoiceNumber. '
                        'Edit anything below — a new invoice number will be '
                        'issued.',
                        style: const TextStyle(
                            fontSize: 11, color: ZohoPalette.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            if (_sourceInvoiceError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '$_sourceInvoiceError — fill the lines in manually.',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
                ),
              ),
            const SizedBox(height: 12),
            if (_customerError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _customerError!,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade800),
                ),
              ),
            CustomerPickerField(
              orgId: _zohoOrgId,
              selected: _zohoCustomer,
              enabled: !locked,
              initialQuery: _clientController.text.trim(),
              newCustomerSeedName: _newCustomerSeedName,
              onSelected: (c) => setState(() {
                _zohoCustomer = c;
                // Keep the job's client name aligned with the Zoho contact.
                if (c != null && _clientController.text.trim().isEmpty) {
                  _clientController.text = c.displayName;
                }
              }),
            ),
            const SizedBox(height: 12),
            _buildCopyLastInvoice(
              enabled: _zohoCustomer?.existsInZoho ?? false,
            ),
            const SizedBox(height: 14),
            LineItemsEditor(
              // LineItemsEditor seeds its controllers in initState, so it must
              // be rebuilt whenever an async load replaces the lines — either
              // the copy pre-fill or the existing invoice being fetched.
              key: ValueKey('${_copiedFromInvoiceNumber ?? ''}'
                  '|${_existingInvoice?.invoiceId ?? 'new'}'
                  '|$_zohoSeedGeneration'),
              orgId: _zohoOrgId,
              lineItems: _zohoLineItems,
              enabled: !locked,
              allowedItemIds: _allowedItemCodes,
              tokens: _itemAutofillTokens,
              onChanged: (items) {
                _zohoLineItems = items;
                _zohoLineAutoSeeded = false;
                // The job's amount follows the invoice sub-total so the two
                // can never disagree about what was billed.
                final total =
                    items.fold<double>(0, (running, li) => running + li.amount);
                _amountController.text =
                    (total + _existingSplitSubTotal).toStringAsFixed(2);
              },
            ),
            const SizedBox(height: 6),
            // The Invoice field this used to point at is gone from the form,
            // so Zoho now always issues the number.
            const Text(
              'No VAT applied. Zoho issues the invoice number.',
              style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
            ),
          ],
          if (saga != null) ...[
            const SizedBox(height: 14),
            SagaProgressPanel(
              saga: saga,
              onRetry: _retryPrimary,
            ),
            if (saga.isFinished) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  // Saves as "Customer - INV-001234.pdf" — only this path can
                  // set the filename on web.
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isPrinting
                          ? null
                          : () => _printCreatedInvoice(download: true),
                      icon: _isPrinting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 16),
                      label: const Text('Download'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _isPrinting ? null : () => _printCreatedInvoice(),
                      icon: const Icon(Icons.print, size: 16),
                      label: const Text('Print'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saga.invoice == null
                          ? null
                          : () => showInvoiceShareSheet(
                                context,
                                InvoiceMessageSubject.fromZoho(saga.invoice!),
                                customerEmail: saga.customer.email,
                              ),
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('Share'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF25D366),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      // Held until any split invoices are through too.
                      onPressed: (_splitsSettled && !_splitsRunning)
                          ? _finishInvoicedSave
                          : null,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Done'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E9E4F),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Xero invoicing (Community Life Media) ─────────────────────────────────

  /// The company this job type belongs to, rather than a hardcoded CLM — a
  /// second Xero-billing company would otherwise silently use CLM's settings.
  Company? get _xeroCompany {
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);
    if (type == null) return null;
    return ref.read(companyRiverpod).forJobType(type);
  }

  String get _xeroSalesAccountCode =>
      _xeroCompany?.providerConfig['salesAccountCode'] ?? '';

  String get _xeroSalesTaxType =>
      _xeroCompany?.providerConfig['salesTaxType'] ?? '';

  /// Whether the lines are VAT-exclusive or untaxed. Amounts are always
  /// entered excluding VAT, so this follows the job type's VAT setting alone.
  XeroLineAmountType get _xeroLineAmountType {
    final chargesVat =
        JobTypeProvider.instance?.chargesVat(_selectedJobType) ?? false;
    return XeroLineAmountType.forJob(
      chargesVat: chargesVat,
      priceIsInclVat: false,
    );
  }

  bool _xeroLinesSeeded = false;

  int _xeroSeedGeneration = 0;

  /// The invoice line this job type implies.
  ///
  /// Prefers the job type's catalogue item, which carries the description,
  /// price, revenue account and tax rate that CLM actually charges — the whole
  /// reason for keeping a Products & Services list in Xero. Falls back to a
  /// free-text line built from the job when no item is mapped, which is how
  /// every job type behaved before items existed.
  XeroLineItem _xeroSeedLine() {
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);
    final item = ref.read(xeroItemsRiverpod).byCode(type?.accountingItemCode ?? '');

    final typeLabel = type?.label ?? '';
    final area = _areaController.text.trim();
    final jobAmount = double.tryParse(_amountController.text.trim()) ?? 0;

    // Man-days, not the Quantity / Vehicle figure: man-days are the unit CLM
    // sells, so they are what a catalogue rate is priced against. Quantity is
    // how many flyers went out, which is not what the invoice multiplies.
    //
    // Fractional on purpose — half a day is a real booking.
    //
    // Whether it can be carried at all depends on there being a unit rate to
    // multiply; see XeroLineItem.lineFigures.
    final jobQuantity = double.tryParse(_manDaysController.text.trim()) ?? 0;

    if (item != null) {
      // The area still belongs on the line — the item says what was done, the
      // job says where.
      final description = area.isEmpty
          ? item.lineDescription
          : '${item.lineDescription} — $area';

      final figures = XeroLineItem.lineFigures(
        jobQuantity: jobQuantity,
        jobAmount: jobAmount,
        itemUnitPrice: item.unitPrice,
      );

      return XeroLineItem(
        itemCode: item.code,
        description: description,
        quantity: figures.quantity,
        unitAmount: figures.unitAmount,
        accountCode:
            item.accountCode.isNotEmpty ? item.accountCode : _xeroSalesAccountCode,
        taxType: _xeroLineAmountType == XeroLineAmountType.noTax
            ? ''
            : (item.taxType.isNotEmpty ? item.taxType : _xeroSalesTaxType),
      );
    }

    return XeroLineItem(
      description: [
        if (typeLabel.isNotEmpty) typeLabel,
        if (area.isNotEmpty) area,
      ].join(' — '),
      // No catalogue rate here, so the job's amount is a total and its
      // quantity cannot be multiplied against it.
      quantity: XeroLineItem.lineFigures(
        jobQuantity: jobQuantity,
        jobAmount: jobAmount,
        itemUnitPrice: 0,
      ).quantity,
      unitAmount: jobAmount,
      accountCode: _xeroSalesAccountCode,
      // Empty means "use the account's default", which is right for an
      // untaxed invoice and harmless otherwise.
      taxType: _xeroLineAmountType == XeroLineAmountType.noTax
          ? ''
          : _xeroSalesTaxType,
    );
  }

  /// Put one line on a new invoice, from what the job already says.
  ///
  /// Deferred to a post-frame callback rather than done during build, which
  /// cannot call setState. Runs once; the job-type re-seed is separate.
  void _seedXeroLinesIfNeeded() {
    if (_xeroLinesSeeded || _xeroLineItems.isNotEmpty) return;
    _xeroLinesSeeded = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The catalogue is cached for the session, so this is one call at most.
      await ref.read(xeroItemsRiverpod).ensureLoaded();
      if (!mounted) return;
      setState(() {
        _xeroLineItems = [_xeroSeedLine()];
        _xeroSeedGeneration++;
      });
    });
  }

  /// Items this job type may bill as. Empty means the whole catalogue.
  List<String> get _allowedItemCodes =>
      JobTypeProvider.instance
          ?.getJobTypeById(_selectedJobType)
          ?.allowedItemCodes ??
      const [];

  /// The job's values, substituted into an item's autofill templates.
  ///
  /// Read live from the form rather than captured once, so a line filled after
  /// the area or quantity was typed picks up what is actually on screen.
  Map<ItemAutofillToken, String> get _itemAutofillTokens {
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);
    final date = _selectedDate;

    return {
      ItemAutofillToken.client: _clientController.text.trim(),
      ItemAutofillToken.area: _areaController.text.trim(),
      ItemAutofillToken.quantity: _quantityController.text.trim(),
      ItemAutofillToken.jobType: type?.label ?? '',
      ItemAutofillToken.date:
          date == null ? '' : DateFormat('d MMM y').format(date),
    };
  }

  // ── Draft: pause a half-filled Add Job and come back ──────────────────────

  /// Only new jobs get drafts. An edit already has a source of truth in
  /// Firestore, and restoring a stale copy over it would be a data loss bug.
  bool get _canDraft => widget.jobToEdit == null;

  bool _isSavingDraft = false;

  /// Set once a draft has been offered, so the prompt appears at most once per
  /// dialog rather than on every rebuild.
  bool _draftPromptShown = false;

  /// Everything the form is holding, flattened for storage.
  ///
  /// Deliberately explicit rather than reflective: a field silently missing
  /// from here comes back blank on resume, which is worse than not offering the
  /// draft at all, so the list is meant to be read and checked against the form.
  Map<String, dynamic> _draftFields() {
    return {
      'invoice': _invoiceController.text,
      'amount': _amountController.text,
      'client': _clientController.text,
      'contactPerson': _contactPersonController.text,
      'contactPhone': _contactPhoneController.text,
      'area': _areaController.text,
      'quantity': _quantityController.text,
      'manDays': _manDaysController.text,
      'regularClientId': _regularClientId,
      'collectionAddress': _collectionAddressController.text,
      'specialInstructions': _specialInstructionsController.text,
      'quantityDistributed': _quantityDistributedController.text,
      'invoiceDetails': _invoiceDetailsController.text,
      'reportAddresses': _reportAddressesController.text,
      'whoToInvoice': _whoToInvoiceController.text,
      'jobTypeId': _selectedJobType,
      'jobStatusId': _selectedJobStatusId,
      if (_selectedDate != null)
        'date': Timestamp.fromDate(_selectedDate!),
      if (_selectedCollectionDate != null)
        'collectionDate': Timestamp.fromDate(_selectedCollectionDate!),
      'needsFlyerCollection': _needsFlyerCollection,
      if (_slotStart != null) 'slotStart': _slotStart,
      if (_slotCount != null) 'slotCount': _slotCount,
      'appointmentDayEdited': _appointmentDayEdited,

      // The chosen customer, by id — both providers create customers up front,
      // so the id is enough to find it again and the rest can be re-read.
      'xeroContactId': _xeroContact?.contactId ?? '',
      'xeroContactName': _xeroContact?.name ?? '',
      'zohoCustomerId': _zohoCustomer?.contactId ?? '',
      'zohoCustomerName': _zohoCustomer?.displayName ?? '',

      'xeroLines': _xeroLineItems
          .map((l) => {
                'itemCode': l.itemCode,
                'description': l.description,
                'quantity': l.quantity,
                'unitAmount': l.unitAmount,
                'accountCode': l.accountCode,
                'taxType': l.taxType,
              })
          .toList(),
      'zohoLines': _zohoLineItems
          .map((l) => {
                'itemId': l.itemId,
                'name': l.name,
                'description': l.description,
                'rate': l.rate,
                'quantity': l.quantity,
                'unit': l.unit,
              })
          .toList(),
    };
  }

  /// Put a saved draft back into the form.
  void _restoreDraft(Map<String, dynamic> d) {
    String str(String k) => d[k] as String? ?? '';
    DateTime? date(String k) => (d[k] as Timestamp?)?.toDate();

    setState(() {
      _invoiceController.text = str('invoice');
      _amountController.text = str('amount');
      _clientController.text = str('client');
      _contactPersonController.text = str('contactPerson');
      _contactPhoneController.text = str('contactPhone');
      _areaController.text = str('area');
      _quantityController.text = str('quantity');
      _manDaysController.text = str('manDays');
      _regularClientId = str('regularClientId');
      _collectionAddressController.text = str('collectionAddress');
      _specialInstructionsController.text = str('specialInstructions');
      _quantityDistributedController.text = str('quantityDistributed');
      _invoiceDetailsController.text = str('invoiceDetails');
      _reportAddressesController.text = str('reportAddresses');
      _whoToInvoiceController.text = str('whoToInvoice');

      if (str('jobTypeId').isNotEmpty) _selectedJobType = str('jobTypeId');
      if (str('jobStatusId').isNotEmpty) {
        _selectedJobStatusId = str('jobStatusId');
      }
      _selectedDate = date('date') ?? _selectedDate;
      _scheduleClientClashCheck();
      final collection = date('collectionDate');
      _selectedCollectionDate = collection == null ||
              (collection.year == 2000 &&
                  collection.month == 1 &&
                  collection.day == 1)
          ? null
          : collection;
      // A draft from before the tick existed keeps the dialog's default.
      _needsFlyerCollection =
          d['needsFlyerCollection'] as bool? ?? _needsFlyerCollection;
      if (d['slotStart'] is String) _slotStart = d['slotStart'] as String;
      if (d['slotCount'] is num) _slotCount = (d['slotCount'] as num).toInt();
      _appointmentDayEdited = d['appointmentDayEdited'] == true;

      _xeroLineItems = ((d['xeroLines'] as List<dynamic>?) ?? const [])
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return XeroLineItem(
              itemCode: m['itemCode'] as String? ?? '',
              description: m['description'] as String? ?? '',
              quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
              unitAmount: (m['unitAmount'] as num?)?.toDouble() ?? 0,
              accountCode: m['accountCode'] as String? ?? '',
              taxType: m['taxType'] as String? ?? '',
            );
          })
          .toList();

      _zohoLineItems = ((d['zohoLines'] as List<dynamic>?) ?? const [])
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return ZohoLineItem(
              itemId: m['itemId'] as String? ?? '',
              name: m['name'] as String? ?? '',
              description: m['description'] as String? ?? '',
              rate: (m['rate'] as num?)?.toDouble() ?? 0,
              quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
              unit: m['unit'] as String? ?? '',
            );
          })
          .toList();

      // Restored lines are the user's, not the job type's.
      _xeroSeedGeneration++;
      _zohoSeedGeneration++;
      _zohoLineAutoSeeded = false;
      _xeroLinesSeeded = true;
    });

    // The customer is re-read rather than reconstructed: a stored name could be
    // stale, and an id-less stand-in would fail the "must exist" guard on save.
    _restoreDraftCustomer(d);
  }

  Future<void> _restoreDraftCustomer(Map<String, dynamic> d) async {
    final xeroId = d['xeroContactId'] as String? ?? '';
    if (xeroId.isNotEmpty) {
      try {
        final contact =
            await ref.read(xeroAccountingServiceRiverpod).getContact(xeroId);
        if (mounted) setState(() => _xeroContact = contact);
      } catch (_) {
        /* deleted or unreachable — the picker simply starts empty */
      }
      return;
    }

    final zohoId = d['zohoCustomerId'] as String? ?? '';
    if (zohoId.isEmpty) return;
    try {
      final customers = ref.read(zohoCustomersRiverpod(_zohoOrgId));
      await customers.initialize();
      final match = customers.getById(zohoId);
      if (match != null && mounted) setState(() => _zohoCustomer = match);
    } catch (_) {
      /* same */
    }
  }

  /// Save what is on the form and close, so it can be resumed later.
  Future<void> _saveDraftAndClose() async {
    setState(() => _isSavingDraft = true);

    final saved =
        await ref.read(jobDraftServiceRiverpod).save(_draftFields());
    if (!mounted) return;

    setState(() => _isSavingDraft = false);
    ScaffoldMessenger.of(context).showToast(
      SnackBar(
        content: Text(saved
            ? 'Draft saved — reopen Add Job to carry on.'
            : 'Could not save the draft.'),
        backgroundColor: saved ? Colors.green : Colors.red,
      ),
    );
    if (saved) Navigator.of(context).pop();
  }

  /// Offer a stored draft, once, shortly after the dialog opens.
  Future<void> _offerDraft() async {
    if (!_canDraft || _draftPromptShown) return;
    _draftPromptShown = true;

    // Prefetched by the Job List, so usually already in hand and the prompt
    // shows on the dialog's first frame rather than seconds later.
    final service = ref.read(jobDraftServiceRiverpod);
    final draft = service.isKnown ? service.cached : await service.load();
    if (draft == null || !mounted) return;

    final savedAt = (draft['savedAt'] as Timestamp?)?.toDate();
    final client = (draft['client'] as String? ?? '').trim();

    final resume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Carry on with your unfinished job?'),
        content: Text(
          [
            if (client.isNotEmpty) 'You started adding a job for "$client".',
            if (client.isEmpty) 'You have an unfinished job saved.',
            if (savedAt != null)
              'Saved ${DateFormat('d MMM y, HH:mm').format(savedAt)}.',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Start fresh'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Carry on'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (resume == true) {
      _restoreDraft(draft);
    } else {
      // Declining discards it, so the same prompt does not reappear tomorrow.
      await ref.read(jobDraftServiceRiverpod).clear();
    }
  }

  // ── Copy the customer's last invoice ──────────────────────────────────────

  /// True while fetching the previous invoice to copy from.
  bool _isCopyingLastInvoice = false;

  /// Number of the invoice the lines were copied from, for the confirmation.
  String? _copiedFromLastInvoiceNumber;

  String? _copyLastInvoiceError;

  /// Pull the selected customer's most recent invoice lines onto this one.
  ///
  /// Most of this client's jobs are the same work at the same price, so the
  /// last invoice is a far better starting point than an empty line — and
  /// retyping it is where wrong figures come from.
  ///
  /// Two calls, not one: the list is fetched `summaryOnly` (which is what keeps
  /// a page inside Xero's response limit and omits line items), then the chosen
  /// invoice is read in full. Only on an explicit press, so the daily budget is
  /// not spent on people who did not ask.
  Future<void> _copyLastXeroInvoice() async {
    final contact = _xeroContact;
    if (contact == null || !contact.existsInXero) return;

    setState(() {
      _isCopyingLastInvoice = true;
      _copyLastInvoiceError = null;
    });

    try {
      final service = ref.read(xeroAccountingServiceRiverpod);
      final page = await service.listInvoices(
        contactIds: [contact.contactId],
        order: 'Date DESC',
        summaryOnly: true,
        pageSize: 10,
      );

      // Skip annulled invoices — copying a voided one propagates whatever was
      // wrong with it.
      XeroInvoice? newest;
      for (final inv in page.items) {
        if (inv.status.isStruckThrough) continue;
        newest = inv;
        break;
      }

      if (newest == null) {
        if (!mounted) return;
        setState(() {
          _isCopyingLastInvoice = false;
          _copyLastInvoiceError =
              'No previous invoice for ${contact.displayName}.';
        });
        return;
      }

      final full = await service.getInvoice(newest.invoiceId);
      if (!mounted) return;

      // Strip the identity: these are new lines on a new invoice, and carrying
      // lineItemId across would make Xero try to amend the original's lines.
      final lines = full.lineItems
          .map((l) => XeroLineItem(
                description: l.description,
                quantity: l.quantity,
                unitAmount: l.unitAmount,
                accountCode: l.accountCode,
                taxType: l.taxType,
                itemCode: l.itemCode,
              ))
          .toList();

      if (lines.isEmpty) {
        setState(() {
          _isCopyingLastInvoice = false;
          _copyLastInvoiceError =
              'Invoice ${full.invoiceNumber} has no lines to copy.';
        });
        return;
      }

      setState(() {
        _xeroLineItems = lines;
        _xeroSeedGeneration++;
        _copiedFromLastInvoiceNumber = full.invoiceNumber;
        _isCopyingLastInvoice = false;
      });

      final total = lines.fold<double>(0, (r, l) => r + l.amount);
      _amountController.text = total.toStringAsFixed(2);
    } on XeroException catch (e) {
      if (!mounted) return;
      setState(() {
        _isCopyingLastInvoice = false;
        _copyLastInvoiceError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCopyingLastInvoice = false;
        _copyLastInvoiceError = '$e';
      });
    }
  }

  /// The Zoho counterpart. Same reasoning, different API shape: Zoho's list
  /// carries line items already, but they arrive with their `line_item_id`, so
  /// those still have to be stripped.
  Future<void> _copyLastZohoInvoice() async {
    final customer = _zohoCustomer;
    if (customer == null || !customer.existsInZoho) return;

    setState(() {
      _isCopyingLastInvoice = true;
      _copyLastInvoiceError = null;
    });

    try {
      final provider = ref.read(zohoInvoicesRiverpod(_zohoOrgId));
      final page = await provider.listInvoicesForCustomer(customer.contactId);

      ZohoInvoice? newest;
      for (final inv in page) {
        if (inv.status == ZohoInvoiceStatus.isVoid) continue;
        newest = inv;
        break;
      }

      if (newest == null) {
        if (!mounted) return;
        setState(() {
          _isCopyingLastInvoice = false;
          _copyLastInvoiceError =
              'No previous invoice for ${customer.displayName}.';
        });
        return;
      }

      final full = await provider.getInvoiceForCopy(newest.invoiceId);
      if (!mounted) return;

      final lines = full.lineItems
          .map((l) => ZohoLineItem(
                itemId: l.itemId,
                name: l.name,
                description: l.description,
                rate: l.rate,
                quantity: l.quantity,
                unit: l.unit,
              ))
          .toList();

      if (lines.isEmpty) {
        setState(() {
          _isCopyingLastInvoice = false;
          _copyLastInvoiceError =
              'Invoice ${full.invoiceNumber} has no lines to copy.';
        });
        return;
      }

      setState(() {
        _zohoLineItems = lines;
        _zohoSeedGeneration++;
        // The lines are the customer's, not the job type's, so a later job
        // type change must not overwrite them.
        _zohoLineAutoSeeded = false;
        _copiedFromLastInvoiceNumber = full.invoiceNumber;
        _isCopyingLastInvoice = false;
      });

      final total = lines.fold<double>(0, (r, l) => r + l.amount);
      _amountController.text = total.toStringAsFixed(2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCopyingLastInvoice = false;
        _copyLastInvoiceError = '$e';
      });
    }
  }

  /// The "copy last invoice" affordance, shown once a real customer is chosen.
  Widget _buildCopyLastInvoice({required bool enabled}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: (!enabled || _isCopyingLastInvoice)
                  ? null
                  : (_isXeroJob ? _copyLastXeroInvoice : _copyLastZohoInvoice),
              icon: _isCopyingLastInvoice
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.content_copy, size: 16),
              label: Text(_isCopyingLastInvoice
                  ? 'Fetching…'
                  : "Copy this customer's last invoice"),
              style: OutlinedButton.styleFrom(
                foregroundColor: ZohoPalette.link,
                side: const BorderSide(color: ZohoPalette.border),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (_copiedFromLastInvoiceNumber != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Copied from $_copiedFromLastInvoiceNumber. Edit anything below — '
              'a new invoice number will be issued.',
              style:
                  const TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
            ),
          ),
        if (_copyLastInvoiceError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _copyLastInvoiceError!,
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
            ),
          ),
      ],
    );
  }

  /// The Zoho invoice line this job type implies.
  ///
  /// Prefers the job type's catalogue item, so a standard service carries the
  /// name, description and rate that Junk & Stuff actually charges instead of
  /// the hardcoded "Junk collection" placeholder.
  ZohoLineItem _zohoSeedLine() {
    final type = JobTypeProvider.instance?.getJobTypeById(_selectedJobType);
    final item = ref.read(zohoItemsRiverpod(_zohoOrgId)).byId(type?.accountingItemCode ?? '');

    final jobAmount = double.tryParse(_amountController.text.trim()) ??
        (widget.jobToEdit?.amount ?? 0.0);
    final details = _invoiceDetailsController.text.trim();

    if (item != null) {
      // Same precedence the line editor uses: the item's configured template
      // beats the catalogue text, and a note typed on the job beats both — it
      // is about this job, not the service in general.
      final autofill = ref.read(zohoItemAutofillRiverpod).forItem(item.itemId);
      final tokens = _itemAutofillTokens;
      final name =
          ZohoItemAutofill.render(autofill?.nameTemplate ?? '', tokens);
      final description =
          ZohoItemAutofill.render(autofill?.descriptionTemplate ?? '', tokens);

      return ZohoLineItem(
        itemId: item.itemId,
        name: name.isNotEmpty ? name : item.displayName,
        description: details.isNotEmpty
            ? details
            : (description.isNotEmpty ? description : item.lineDescription),
        // Likewise a figure already quoted beats the list price.
        rate: jobAmount > 0 ? jobAmount : item.rate,
        quantity: 1,
        unit: item.unit,
      );
    }

    return ZohoLineItem(
      name: type?.label.isNotEmpty == true ? type!.label : 'Junk collection',
      description: details,
      rate: jobAmount,
      quantity: 1,
    );
  }

  /// Follow a job type change onto the Zoho invoice.
  ///
  /// Guarded harder than the Xero equivalent because this is the live Junk &
  /// Stuff path: it never runs while amending an existing invoice, never on a
  /// copied set of lines, and never once the user has touched them.
  void _reseedZohoLineForJobType() {
    if (_isXeroJob || _isUpdatingInvoice) return;
    if (_existingInvoice != null || _copiedFromInvoiceNumber != null) return;
    if (!_zohoLineAutoSeeded || _zohoLineItems.length > 1) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ref.read(zohoItemsRiverpod(_zohoOrgId)).ensureLoaded();
      await ref.read(zohoItemAutofillRiverpod).ensureLoaded();
      if (!mounted || !_zohoLineAutoSeeded) return;
      setState(() {
        _zohoLineItems = [_zohoSeedLine()];
        _zohoSeedGeneration++;
        _zohoLineAutoSeeded = true;
      });
    });
  }

  /// Keep the invoice line's quantity in step with Man Days.
  ///
  /// Man-days are the unit CLM sells, so the figure on the job and the quantity
  /// on the invoice are the same number said twice. Letting them drift means
  /// changing the days on a job silently bills the old ones.
  ///
  /// Only ever touches a **single** line, and only while the invoice is still
  /// being composed. A multi-line invoice is no longer a plain job-shaped one,
  /// and a raised or in-flight invoice must not be rewritten underneath itself.
  void _onManDaysChanged() {
    if (!_isXeroJob || _alreadyHasXeroInvoice) return;
    if (_isProcessing || _sagaActive) return;
    if (_xeroLineItems.length != 1) return;

    final days = double.tryParse(_manDaysController.text.trim()) ?? 0;
    final quantity = days > 0 ? days : 1.0;

    final line = _xeroLineItems.first;
    if (line.quantity == quantity) return;

    setState(() {
      _xeroLineItems = [line.copyWith(quantity: quantity)];
      // The editor builds a controller per row, so the model alone would leave
      // the old quantity on screen.
      _xeroSeedGeneration++;
    });

    // The job's amount follows the line, the same way the editor's own
    // onChanged keeps it in step.
    _amountController.text =
        _xeroLineItems.first.amount.toStringAsFixed(2);
  }

  /// Follow a job type change onto the invoice.
  ///
  /// Rewrites a **single** line outright, even one that has been edited: a
  /// different job type is a different service, so the description, price and
  /// item left over from the previous one describe something this invoice is no
  /// longer for. Leaving them would be worse than losing an edit.
  ///
  /// Once the invoice has more than one line it is no longer a plain
  /// job-type-shaped invoice, and nothing here touches it.
  void _reseedXeroLineForJobType() {
    if (!_isXeroJob || _alreadyHasXeroInvoice) return;
    if (_xeroLineItems.length > 1) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ref.read(xeroItemsRiverpod).ensureLoaded();
      if (!mounted) return;
      setState(() {
        _xeroLineItems = [_xeroSeedLine()];
        _xeroSeedGeneration++;
      });
    });
  }

  Widget _buildXeroInvoicingSection() {
    final saga = _xeroSaga;
    final locked = _isProcessing || (saga?.savedJob != null);
    final accountCode = _xeroSalesAccountCode;
    final lineAmountType = _xeroLineAmountType;

    if (_createXeroInvoice && !locked) _seedXeroLinesIfNeeded();

    final subTotal = _xeroLineItems.fold<double>(0, (r, li) => r + li.amount);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZohoPalette.pageBackground,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long, size: 18, color: ZohoPalette.link),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Invoicing (Xero)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ZohoPalette.textPrimary,
                  ),
                ),
              ),
              if (_alreadyHasXeroInvoice) ...[
                XeroStatusChip(
                  status: XeroInvoiceStatus.parse(
                      widget.jobToEdit?.resolvedInvoiceStatus),
                  dense: true,
                ),
                const SizedBox(width: 10),
              ],
              Switch(
                value: _createXeroInvoice,
                onChanged: (locked || _alreadyHasXeroInvoice)
                    ? null
                    : (v) => setState(() => _createXeroInvoice = v),
              ),
            ],
          ),

          // A job that already has a Xero invoice is not re-invoiced from
          // here. Amending it needs the invoice screen, which knows what Xero
          // will and will not accept in each state; offering an edit here
          // would either duplicate that logic or quietly bill twice.
          if (_alreadyHasXeroInvoice)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'This job is already on invoice '
                '${widget.jobToEdit?.resolvedInvoiceNumber ?? ''}. Job changes '
                'will be saved; open the invoice from the Job List to amend it.',
                style: const TextStyle(
                    fontSize: 11, color: ZohoPalette.textMuted),
              ),
            ),
          if (_alreadyHasXeroInvoice && jobInvoiceLooksVoid(widget.jobToEdit!))
            _unlinkVoidInvoiceButton(locked),
          if (!_alreadyHasXeroInvoice && !_createXeroInvoice)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Job will be saved without an invoice. You can invoice it '
                'later from its Job List row.',
                style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
            ),

          // Only before the saga starts. Unlike their Zoho counterparts the
          // Xero picker and line editor take no `enabled` flag, so leaving them
          // mounted afterwards would invite edits to an invoice already raised.
          if (_createXeroInvoice && !_alreadyHasXeroInvoice && saga == null) ...[
            if (accountCode.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No Xero sales account is configured for '
                  '${_xeroCompany?.name ?? 'this company'}. Set it in '
                  'Settings → Companies before invoicing.',
                  style:
                      TextStyle(fontSize: 11, color: Colors.orange.shade900),
                ),
              ),
            if (_xeroConfigError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _xeroConfigError!,
                  style:
                      TextStyle(fontSize: 11, color: Colors.orange.shade900),
                ),
              ),
            const SizedBox(height: 12),
            if (_customerError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _customerError!,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade800),
                ),
              ),
            XeroContactPicker(
              value: _xeroContact,
              seedName: _newCustomerSeedName,
              onChanged: (c) => setState(() {
                _xeroContact = c;
                // Keep the job's client name aligned with the Xero contact.
                if (c != null && _clientController.text.trim().isEmpty) {
                  _clientController.text = c.displayName;
                }
              }),
            ),
            const SizedBox(height: 12),
            _buildCopyLastInvoice(
              enabled: _xeroContact?.existsInXero ?? false,
            ),
            const SizedBox(height: 14),
            XeroLineItemsEditor(
              // No key needed: the editor reads `lineItems` straight off its
              // widget and its rows are keyed individually, so the async seed
              // lands without forcing a rebuild of the whole editor.
              lineItems: _xeroLineItems,
              lineAmountType: lineAmountType,
              seedGeneration: _xeroSeedGeneration,
              defaultAccountCode: accountCode,
              defaultTaxType: lineAmountType == XeroLineAmountType.noTax
                  ? ''
                  : _xeroSalesTaxType,
              onChanged: (items) {
                setState(() => _xeroLineItems = items);
                // The job's amount follows the invoice's excluding-VAT total,
                // which is what linkAccountingInvoiceTxn writes back to it.
                final total =
                    items.fold<double>(0, (r, li) => r + li.amount);
                _amountController.text =
                    (total + _existingSplitSubTotal).toStringAsFixed(2);
              },
            ),
            const SizedBox(height: 6),
            Text(
              lineAmountType == XeroLineAmountType.noTax
                  ? 'No VAT on this job type. Xero issues the invoice number.'
                  : 'Amounts are VAT exclusive '
                      '(R ${subTotal.toStringAsFixed(2)} entered). Xero computes '
                      'the VAT split and issues the invoice number.',
              style:
                  const TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
            ),
          ],

          if (saga != null) ...[
            const SizedBox(height: 14),
            SagaProgressPanel(saga: saga, onRetry: _retryPrimary),
            if (saga.isFinished) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isPrinting
                          ? null
                          : () => _printCreatedXeroInvoice(download: true),
                      icon: _isPrinting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 16),
                      label: const Text('Download'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _isPrinting ? null : () => _printCreatedXeroInvoice(),
                      icon: const Icon(Icons.print, size: 16),
                      label: const Text('Print'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: saga.invoice == null
                          ? null
                          : () => _shareCreatedXeroInvoice(saga.invoice!),
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('Share'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF25D366),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      // Held until any split invoices are through too.
                      onPressed: (_splitsSettled && !_splitsRunning)
                          ? _finishInvoicedSave
                          : null,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Done'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E9E4F),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// "Unlink void invoice" action, shared by the Zoho and Xero sections.
  Widget _unlinkVoidInvoiceButton(bool locked) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: locked ? null : _unlinkVoidInvoice,
          icon: const Icon(Icons.link_off, size: 16),
          label: const Text('Unlink void invoice & create a new one'),
        ),
      ),
    );
  }

  /// True when the job being edited already carries a Xero invoice.
  ///
  /// Never true for a copy — the copy flow clears the inherited link precisely
  /// so the new job bills separately.
  bool get _alreadyHasXeroInvoice {
    final job = widget.jobToEdit;
    if (job == null || _isCopy || _invoiceUnlinked) return false;
    return job.resolvedInvoiceProviderId == AccountingProvider.xero.name &&
        job.resolvedInvoiceId.isNotEmpty;
  }

  /// Save the job **and** raise its Xero invoice as one confirmed sequence.
  ///
  /// The Xero counterpart to [_saveJobWithZohoInvoice], through the same
  /// [InvoiceSaveSaga] so the ordering, retry and never-bill-twice rules are
  /// one implementation rather than two that would drift.
  Future<void> _saveJobWithXeroInvoice() async {
    // Never build a second saga — see [_saveJobWithZohoInvoice].
    final existing = _xeroSaga;
    if (existing != null) {
      await existing.run();
      return;
    }
    void complain(String message) {
      ScaffoldMessenger.of(context).showToast(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }

    // Must already exist in Xero. A name typed into the picker is not a
    // customer, and the saga no longer creates one — so this is the last point
    // at which it can be caught. Checked before the form validates, so the real
    // problem is not buried under unrelated field errors.
    if (_xeroContact == null || !_xeroContact!.existsInXero) {
      setState(() => _customerError =
          'Select a valid Xero customer, or create one with "New".');
      complain('Select a valid Xero customer before invoicing.');
      return;
    }
    setState(() => _customerError = null);

    if (!_formKey.currentState!.validate()) return;

    final accountCode = _xeroSalesAccountCode;
    if (accountCode.isEmpty) {
      setState(() => _xeroConfigError =
          'No Xero sales account is configured for this company. Set it in '
          'Settings → Companies before invoicing.');
      return;
    }

    final usableLines = _xeroLineItems
        .where((li) => li.description.trim().isNotEmpty && li.quantity > 0)
        .toList();
    if (usableLines.isEmpty || usableLines.every((li) => li.amount <= 0)) {
      complain('Add at least one line item with a description and amount.');
      return;
    }

    final tl = _startTimeline('Save job + Xero invoice');

    // Duplicate-client check, same as every other save path.
    if (!await tl.step('duplicate-name check', _clientNameIsFree)) {
      tl.finish();
      return;
    }
    if (!mounted) return;

    final service = ref.read(xeroAccountingServiceRiverpod);
    final jobListService = ref.read(jobListServiceRiverpod);
    final lineAmountType = _xeroLineAmountType;
    final seed = _xeroContact!;

    // Issued today, not on the job's scheduled date — a job booked for next
    // month is still invoiced now. Anchored to SAST so a client in another
    // timezone cannot stamp yesterday's date.
    final issuedOn = scheduleToday();

    setState(() {
      _xeroConfigError = null;
      _isProcessing = true;
      _xeroSaga = InvoiceSaveSaga<XeroContact, XeroInvoice>(
        providerName: 'Xero',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        customer: seed,
        onProgress: () {
          if (mounted) setState(() {});
        },
        allocateToSchedule: _allocateAfterInvoice ? _assignToSchedule : null,
        timeline: tl,
        saveJob: _persistJob,
        // Keyed on the job alone. If an earlier attempt raised the invoice but
        // failed to link it, this replays that invoice rather than raising a
        // second one — which is exactly right. Including the amount would let
        // a corrected figure produce a duplicate in the books.
        createInvoice: (savedJob, contact) => service.createInvoice(
          XeroInvoice(
            contactId: contact.contactId,
            date: issuedOn,
            dueDate: issuedOn,
            reference: _invoiceController.text.trim(),
            lineAmountTypes: lineAmountType,
            lineItems: usableLines,
          ),
          // A job whose earlier invoice was voided and unlinked is a new
          // request: without the revision Xero would replay the void one.
          idempotencyKey: _xeroIdempotencyKey('invoice', savedJob.id,
              savedJob.voidedInvoiceIds.isEmpty
                  ? null
                  : 'r${savedJob.voidedInvoiceIds.length}'),
        ),
        linkToJob: (savedJob, contact, invoice) =>
            jobListService.linkAccountingInvoiceTxn(
          jobId: savedJob.id,
          date: savedJob.date,
          providerId: AccountingProvider.xero.name,
          contactId: contact.contactId,
          invoiceId: invoice.invoiceId,
          invoiceNumber: invoice.invoiceNumber,
          invoiceStatus: invoice.status.apiValue,
          // Xero's own split, rounding included — recomputing it here would
          // risk the Job List disagreeing with the books by cents.
          subTotal: invoice.subTotal,
          total: invoice.total,
        ),
      );
    });

    await _xeroSaga!.run();
    tl.finish();

    if (mounted) setState(() => _isProcessing = false);
    // Deliberately stays open on success — the user closes it once they have
    // seen the steps and, if they want, printed the invoice.
  }

  /// Stable across retries of the *same* logical request.
  ///
  /// A new job has no id until the saga's first step runs, so the contact key
  /// uses [_idempotencySeed] instead; the invoice key can use the real id,
  /// because by then the job has been written.
  static String _xeroIdempotencyKey(String kind, String id, [String? extra]) {
    final slug = (extra ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final key = ['clm', kind, id, if (slug.isNotEmpty) slug].join('-');
    return key.length <= 128 ? key : key.substring(0, 128);
  }

  /// Share the invoice just raised, with its pay link resolved first.
  ///
  /// The link is fetched before the sheet opens because message templates
  /// render `{pay_link}` at build time — a lazily-fetched one would be missing
  /// from the message actually sent, not merely from the preview.
  Future<void> _shareCreatedXeroInvoice(XeroInvoice invoice) async {
    final service = ref.read(xeroAccountingServiceRiverpod);
    var payLink = '';

    if (invoice.status.hasOnlineInvoice) {
      try {
        payLink = await service.getOnlineInvoiceUrl(invoice.invoiceId);
      } catch (_) {
        // A missing link only costs the message its {pay_link}.
      }
    }
    if (!mounted) return;

    await showInvoiceShareSheet(
      context,
      InvoiceMessageSubject.fromXero(invoice, payLink: payLink),
      customerEmail: _xeroSaga?.customer.emailAddress,
    );
  }

  /// Save or print the Xero-rendered PDF.
  Future<void> _printCreatedXeroInvoice({bool download = false}) async {
    final invoice = _xeroSaga?.invoice;
    // Two clicks can land before the buttons disable; a second Save dialog
    // would fail and download a stray copy.
    if (invoice == null || _isPrinting) return;

    setState(() => _isPrinting = true);
    try {
      final service = ref.read(xeroAccountingServiceRiverpod);
      final fileName = invoiceFileName(
        InvoiceMessageSubject.fromXero(invoice),
      );
      if (download) {
        // Save dialog first — it must open straight after the click; the
        // PDF loads while the user picks a folder.
        await savePdfWithFeedback(
          ScaffoldMessenger.of(context),
          fileName: fileName,
          load: () => service.getInvoicePdf(invoice.invoiceId),
        );
      } else {
        final bytes = await service.getInvoicePdf(invoice.invoiceId);
        if (!mounted) return;
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: fileName,
        );
      }
    } catch (e) {
      if (mounted) {
        final error = describeAccountingError(e,
            action: download ? 'download the PDF' : 'open the PDF for printing');
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text(error.message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  /// Save the job and raise its invoice, through whichever provider the job
  /// type bills to.
  ///
  /// A single dispatch point on purpose: this dialog has **two** button
  /// layouts — a `Column` under 768px and a `Wrap` above it — and wiring only
  /// one of them is the bug that cost a full debugging round on the Zoho
  /// integration, where the desktop button silently called the non-invoicing
  /// save. Both layouts call this, so neither can drift.
  ///
  /// Split invoices follow the primary: each is raised only once the primary
  /// has been raised and linked, so a failure never leaves a split billed on a
  /// job whose main invoice does not exist. When the primary already exists,
  /// the job is saved and the splits run on their own.
  Future<void> _saveJobWithInvoice() async {
    if (!_validateSplitDrafts()) return;

    if (_createInvoiceEnabled) {
      await (_isXeroJob ? _saveJobWithXeroInvoice() : _saveJobWithZohoInvoice());
      await _runSplitsAfterPrimary();
    } else {
      await _saveJobThenSplits();
    }
  }

  /// Retry for the primary saga's panel. A retry that gets the primary through
  /// carries straight on into the split invoices.
  Future<void> _retryPrimary() async {
    final xeroSaga = _xeroSaga;
    final zohoSaga = _saga;
    if (xeroSaga != null) await xeroSaga.run();
    if (zohoSaga != null) await zohoSaga.run();
    await _runSplitsAfterPrimary();
  }

  Future<void> _runSplitsAfterPrimary() async {
    final saga = _xeroSaga ?? _saga;
    if (saga == null || !saga.isFinished || saga.savedJob == null) return;
    if (_activeSplitDrafts.isEmpty) return;
    await _runSplitInvoices(saga.savedJob!);
  }

  /// Persist the form as a job and return it with its id.
  ///
  /// The one write every invoiced save path shares — through the sagas as
  /// their save step, and directly when only split invoices are being raised.
  Future<JobListItem> _persistJob() async {
    final jobListProvider = ref.read(jobListRiverpod);
    final jobListStatusProvider = ref.read(jobListStatusRiverpod);
    final invoiceStatusProvider = ref.read(invoiceStatusRiverpod);
    final existing = widget.jobToEdit;
    final draft = _buildJobListItem();

    if (existing != null && existing.id.isNotEmpty) {
      // Same resolvers the grid passes, so the `updates` audit trail records
      // human labels rather than raw ids.
      await jobListProvider.updateJobListItemWithTracking(
        existing,
        draft,
        resolveJobStatusLabel: (id) =>
            jobListStatusProvider.getStatusById(id)?.label,
        resolveInvoiceStatusLabel: (id) =>
            invoiceStatusProvider.getStatusById(id)?.label,
        resolveQuantityLabel: (qty, jobTypeId) =>
            VehicleTrailerCombo.fromLegacyQuantity(qty, jobTypeId: jobTypeId)
                ?.label,
      );
      return draft.copyWith(id: existing.id);
    }
    // Waits for the server: the invoice link that follows is a transaction,
    // and transactions read the job from the server.
    return _addNewJob(draft, waitForServer: true);
  }

  /// Save the job, then raise its split invoices — for a job whose primary
  /// invoice already exists, so there is no primary saga to save it.
  Future<void> _saveJobThenSplits() async {
    if (!_formKey.currentState!.validate()) return;

    if (!await _clientNameIsFree()) return;
    if (!mounted) return;

    if (_splitBaseJob == null) {
      setState(() => _isProcessing = true);
      try {
        final saved = await _persistJob();
        if (!mounted) return;
        setState(() => _splitBaseJob = saved);
      } catch (e) {
        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showToast(
            SnackBar(
              content: Text('Error saving job: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    await _runSplitInvoices(_splitBaseJob!);
  }

  /// Check every split draft before anything is written, so a half-filled one
  /// cannot stop the run after the job and its primary invoice exist.
  bool _validateSplitDrafts() {
    var ok = true;
    for (final draft in _activeSplitDrafts) {
      if (draft.saga != null) continue;
      String? error;
      if (_isXeroJob) {
        if (!(draft.xeroContact?.existsInXero ?? false)) {
          error = 'Select a Xero customer for this invoice.';
        } else if (_xeroSalesAccountCode.isEmpty) {
          error = 'No Xero sales account is configured for this company.';
        } else if (draft.usableXeroLines.isEmpty) {
          error = 'Add a line with a description and amount.';
        }
      } else {
        if (!(draft.zohoCustomer?.existsInZoho ?? false)) {
          error = 'Select a Zoho customer for this invoice.';
        } else if (draft.usableZohoLines.isEmpty) {
          error = 'Add a line with a name and amount.';
        }
      }
      draft.error = error;
      if (error != null) ok = false;
    }
    if (!ok) {
      setState(() {});
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Finish the split invoices before saving.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    return ok;
  }

  /// Raise and link the split invoices **together** — they are separate
  /// invoices with their own idempotency keys, so nothing orders them. Only
  /// their links take turns ([_linkSplitInTurn]): each is a transaction on
  /// the same job, and side by side they would only fight over it. A failed
  /// one keeps its own Retry; completed ones are never repeated — each saga
  /// keeps its own results across attempts.
  Future<void> _runSplitInvoices(JobListItem savedJob) async {
    if (_splitsRunning) return;
    setState(() {
      _splitsRunning = true;
      _isProcessing = true;
    });
    try {
      await Future.wait([
        for (final draft in _activeSplitDrafts)
          if (!draft.isDone)
            (draft.saga ??= _isXeroJob
                    ? _buildXeroSplitSaga(draft, savedJob)
                    : _buildZohoSplitSaga(draft, savedJob))
                .run(),
      ]);
    } finally {
      if (mounted) {
        setState(() {
          _splitsRunning = false;
          _isProcessing = false;
        });
      }
    }
  }

  /// The split links, one after another — see [_runSplitInvoices].
  Future<void> _splitLinkChain = Future<void>.value();

  Future<void> _linkSplitInTurn(Future<void> Function() link) {
    final mine = _splitLinkChain.then((_) => link());
    // The next link waits for this one, whatever its outcome.
    _splitLinkChain = mine.then((_) {}, onError: (_) {});
    return mine;
  }

  InvoiceSaveSaga<XeroContact, XeroInvoice> _buildXeroSplitSaga(
      _SplitInvoiceDraft draft, JobListItem savedJob) {
    final service = ref.read(xeroAccountingServiceRiverpod);
    final jobListService = ref.read(jobListServiceRiverpod);
    final lineAmountType = _xeroLineAmountType;
    final lines = draft.usableXeroLines;
    final issuedOn = scheduleToday();

    return InvoiceSaveSaga<XeroContact, XeroInvoice>(
      providerName: 'Xero',
      customerLabel: (c) => c.displayName,
      invoiceLabel: (i) => i.invoiceNumber,
      customer: draft.xeroContact!,
      alreadySavedJob: savedJob,
      saveJob: () async => savedJob,
      onProgress: () {
        if (mounted) setState(() {});
      },
      createInvoice: (job, contact) => service.createInvoice(
        XeroInvoice(
          contactId: contact.contactId,
          date: issuedOn,
          dueDate: issuedOn,
          reference: _invoiceController.text.trim(),
          lineAmountTypes: lineAmountType,
          lineItems: lines,
        ),
        // Keyed on the draft as well as the job: each split is its own
        // request, and a retry of this one must replay it, not raise another.
        idempotencyKey: _xeroIdempotencyKey('invoice', job.id, 'split-${draft.key}'),
      ),
      linkToJob: (job, contact, invoice) {
        final link = JobInvoiceLink(
          providerId: AccountingProvider.xero.name,
          contactId: contact.contactId,
          contactName: contact.displayName,
          invoiceId: invoice.invoiceId,
          invoiceNumber: invoice.invoiceNumber,
          status: invoice.status.apiValue,
          subTotal: invoice.subTotal,
          total: invoice.total,
          syncedAt: DateTime.now(),
        );
        draft.linked = link;
        return _linkSplitInTurn(() => jobListService.linkSplitInvoiceTxn(
            jobId: job.id, date: job.date, link: link));
      },
    );
  }

  InvoiceSaveSaga<ZohoCustomer, ZohoInvoice> _buildZohoSplitSaga(
      _SplitInvoiceDraft draft, JobListItem savedJob) {
    final invoicesProvider = ref.read(zohoInvoicesRiverpod(_zohoOrgId));
    final jobListService = ref.read(jobListServiceRiverpod);
    final lines = draft.usableZohoLines;
    final linesTotal = lines.fold<double>(0, (r, li) => r + li.amount);
    final issuedOn = scheduleToday();
    // One key for this saga's lifetime — see [_saveJobWithZohoInvoice].
    final createKey = newZohoIdempotencyKey('invoice');

    return InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>(
      providerName: 'Zoho',
      customerLabel: (c) => c.displayName,
      invoiceLabel: (i) => i.invoiceNumber,
      customer: draft.zohoCustomer!,
      alreadySavedJob: savedJob,
      saveJob: () async => savedJob,
      onProgress: () {
        if (mounted) setState(() {});
      },
      createInvoice: (job, customer) => invoicesProvider.createInvoice(
        ZohoInvoice(
          invoiceId: '',
          invoiceNumber: '',
          customerId: customer.contactId,
          date: issuedOn,
          dueDate: issuedOn,
          notes: _invoiceDetailsController.text.trim(),
          lineItems: lines,
        ),
        idempotencyKey: createKey,
      ),
      linkToJob: (job, customer, invoice) {
        // No VAT on Zoho, so one figure serves as both totals. Zoho's own
        // total when it returned one, the lines' otherwise.
        final total = invoice.total > 0 ? invoice.total : linesTotal;
        final link = JobInvoiceLink(
          providerId: AccountingProvider.zoho.name,
          contactId: customer.contactId,
          contactName: customer.displayName,
          invoiceId: invoice.invoiceId,
          invoiceNumber: invoice.invoiceNumber,
          status: invoice.status.apiValue,
          subTotal: total,
          total: total,
          syncedAt: DateTime.now(),
        );
        draft.linked = link;
        return _linkSplitInTurn(() => jobListService.linkSplitInvoiceTxn(
            jobId: job.id, date: job.date, link: link));
      },
    );
  }

  /// A new split invoice card. Its line starts from the job's own item at
  /// that item's **catalogue price** — the same price picking the item fills
  /// in — never the job's quoted amount, so a split never bills the whole job
  /// by default. An item with no catalogue price starts at zero.
  void _addSplitDraft() {
    final draft = _SplitInvoiceDraft(
      key: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
    );
    if (_isXeroJob) {
      final seed = _xeroSeedLine();
      final item = ref.read(xeroItemsRiverpod).byCode(seed.itemCode);
      draft.xeroLines = [
        seed.copyWith(quantity: 1, unitAmount: item?.unitPrice ?? 0),
      ];
    } else {
      final base = _zohoLineItems.isNotEmpty
          ? _zohoLineItems.first
          : const ZohoLineItem(name: 'Junk collection', rate: 0);
      final item = base.itemId.isEmpty
          ? null
          : ref.read(zohoItemsRiverpod(_zohoOrgId)).byId(base.itemId);
      draft.zohoLines = [
        // Built fresh rather than copied, so no line_item_id from the primary
        // invoice rides along onto a different invoice.
        ZohoLineItem(
          itemId: base.itemId,
          name: base.name,
          description: base.description,
          unit: base.unit,
          rate: item?.rate ?? 0,
        ),
      ];
    }
    setState(() => _splitDrafts.add(draft));
  }

  /// Split invoices: the ones already on the job, the new ones being
  /// prepared, and the button to add another.
  Widget _buildSplitInvoicesSection() {
    final locked = _isProcessing || _sagaActive;
    final existing = _existingSplits;
    final primarySaga = _xeroSaga ?? _saga;

    // With no primary saga on screen there is no Done button above, so the
    // split run provides its own.
    final showOwnDone = primarySaga == null &&
        _splitBaseJob != null &&
        !_splitsRunning &&
        _splitsSettled;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZohoPalette.pageBackground,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.call_split, size: 18, color: ZohoPalette.link),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Split invoices',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ZohoPalette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Bill other clients for their share of this job. Each gets its '
            'own invoice; the job amount becomes the total of all of them.',
            style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
          ),
          for (final link in existing)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.receipt_long, size: 18),
              title: Text('Invoice ${link.invoiceNumber}'),
              subtitle: Text([
                if (link.contactName.isNotEmpty) link.contactName,
                'R ${link.total.toStringAsFixed(2)}',
              ].join(' · ')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  JobInvoiceLinkActions(invoice: link, orgId: _zohoOrgId),
                  jobInvoiceStatusChip(link),
                ],
              ),
              onTap: () =>
                  openJobInvoice(context, link, orgId: _zohoOrgId),
            ),
          for (var n = 0; n < _splitDrafts.length; n++)
            _buildSplitDraftCard(_splitDrafts[n], n),
          if (_canAddSplitInvoice) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: locked ? null : _addSplitDraft,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add another invoice'),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Turn invoicing on above to split this job across clients.',
                style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
            ),
          if (showOwnDone) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _finishInvoicedSave,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Done'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E9E4F),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSplitDraftCard(_SplitInvoiceDraft draft, int index) {
    final saga = draft.saga;
    final editable = saga == null && !_isProcessing;
    final lineAmountType = _xeroLineAmountType;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  draft.linked != null
                      ? 'Invoice ${draft.linked!.invoiceNumber}'
                      : 'Split invoice ${_existingSplits.length + index + 2}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              // Each raised invoice is downloaded and shared on its own.
              if (draft.linked != null)
                JobInvoiceLinkActions(
                    invoice: draft.linked!, orgId: _zohoOrgId),
              if (editable)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove this invoice',
                  onPressed: () => setState(() => _splitDrafts.remove(draft)),
                ),
            ],
          ),
          if (draft.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                draft.error!,
                style: TextStyle(fontSize: 11, color: Colors.red.shade800),
              ),
            ),
          if (saga == null) ...[
            const SizedBox(height: 6),
            if (_isXeroJob) ...[
              XeroContactPicker(
                value: draft.xeroContact,
                seedName: '',
                onChanged: (c) => setState(() {
                  draft.xeroContact = c;
                  draft.error = null;
                }),
              ),
              const SizedBox(height: 12),
              XeroLineItemsEditor(
                lineItems: draft.xeroLines,
                lineAmountType: lineAmountType,
                defaultAccountCode: _xeroSalesAccountCode,
                defaultTaxType: lineAmountType == XeroLineAmountType.noTax
                    ? ''
                    : _xeroSalesTaxType,
                enabled: editable,
                onChanged: (items) => setState(() {
                  draft.xeroLines = items;
                  draft.error = null;
                }),
              ),
            ] else ...[
              CustomerPickerField(
                orgId: _zohoOrgId,
                selected: draft.zohoCustomer,
                enabled: editable,
                initialQuery: '',
                newCustomerSeedName: '',
                onSelected: (c) => setState(() {
                  draft.zohoCustomer = c;
                  draft.error = null;
                }),
              ),
              const SizedBox(height: 12),
              LineItemsEditor(
                key: ValueKey('split-${draft.key}'),
                orgId: _zohoOrgId,
                lineItems: draft.zohoLines,
                enabled: editable,
                allowedItemIds: _allowedItemCodes,
                tokens: _itemAutofillTokens,
                onChanged: (items) {
                  draft.zohoLines = items;
                  draft.error = null;
                },
              ),
            ],
          ] else ...[
            const SizedBox(height: 6),
            SagaProgressPanel(
              saga: saga,
              onRetry: () {
                final base = (_xeroSaga ?? _saga)?.savedJob ?? _splitBaseJob;
                if (base != null) _runSplitInvoices(base);
              },
            ),
          ],
        ],
      ),
    );
  }

  /// The main "Add/Update Job + Invoice" button. The saga owns the write and
  /// returns `skipAllocation: true`, so without this flag a new job of an
  /// auto-allocate type was invoiced but never reached the schedule.
  Future<void> _saveJobWithInvoiceAndAllocation() => _submitOnce(() {
        final isNew = widget.jobToEdit == null || _isCopy;
        _allocateAfterInvoice = isNew && _jobTypeAutoAllocates;
        return _saveJobWithInvoice();
      });

  /// Save the job **and** raise its Zoho invoice as one confirmed sequence.
  ///
  /// Unlike the other save paths, this one owns the database write — the user
  /// has to see that everything succeeded before the dialog closes, which is
  /// impossible if the caller writes after the dialog is gone. It signals that
  /// with the existing `skipAllocation` marker so the caller does not write
  /// again.
  ///
  /// This is a saga, not a transaction: Zoho cannot join a Firestore
  /// transaction. See [InvoiceSaveSaga] for the ordering and retry rules.
  Future<void> _saveJobWithZohoInvoice() async {
    // Never build a second saga for this dialog: a new saga knows nothing of
    // the invoice the first one raised and would raise another. Resume it.
    final existing = _saga;
    if (existing != null) {
      await existing.run();
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    // Same rule as the Xero path: a real, saved customer or nothing.
    if (_zohoCustomer == null || !_zohoCustomer!.existsInZoho) {
      setState(() => _customerError =
          'Select a valid Zoho customer, or create one with "New".');
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Select a valid Zoho customer before invoicing.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _customerError = null);

    final usableLines = _zohoLineItems
        .where((li) => li.name.isNotEmpty && li.quantity > 0)
        .toList();
    if (usableLines.isEmpty || usableLines.every((li) => li.amount <= 0)) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Add at least one line item with a name and amount.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final tl = _startTimeline(
        _existingInvoice != null ? 'Update job + Zoho invoice' : 'Save job + Zoho invoice');

    // Duplicate-client check, same as every other save path.
    if (!await tl.step('duplicate-name check', _clientNameIsFree)) {
      tl.finish();
      return;
    }
    if (!mounted) return;

    final invoiceTotal =
        usableLines.fold<double>(0, (running, li) => running + li.amount);
    final invoicesProvider = ref.read(zohoInvoicesRiverpod(_zohoOrgId));
    final jobListService = ref.read(jobListServiceRiverpod);
    // One key for this saga's lifetime: when a slow connection loses Zoho's
    // reply, the retry gets back the invoice already raised instead of
    // raising a second one (functions/lib/zoho_books.js, runIdempotent).
    final createKey = newZohoIdempotencyKey('invoice');

    setState(() {
      _isProcessing = true;
      _saga = InvoiceSaveSaga<ZohoCustomer, ZohoInvoice>(
        customer: _zohoCustomer!,
        isUpdate: _existingInvoice != null,
        providerName: 'Zoho',
        customerLabel: (c) => c.displayName,
        invoiceLabel: (i) => i.invoiceNumber,
        onProgress: () {
          if (mounted) setState(() {});
        },
        allocateToSchedule: _allocateAfterInvoice ? _assignToSchedule : null,
        timeline: tl,
        saveJob: _persistJob,
        createInvoice: (job, customer) {
          final existingInvoice = _existingInvoice;

          // Amending the invoice this job already has: keep its identity —
          // id, number and original dates — and push only the edited content.
          // Line items retain their line_item_id, so Zoho amends those lines
          // instead of dropping them and creating replacements.
          if (existingInvoice != null) {
            final amended = ZohoInvoice(
              invoiceId: existingInvoice.invoiceId,
              invoiceNumber: existingInvoice.invoiceNumber,
              customerId: customer.contactId,
              date: existingInvoice.date,
              dueDate: existingInvoice.dueDate,
              referenceNumber: existingInvoice.referenceNumber,
              notes: _invoiceDetailsController.text.trim(),
              lineItems: usableLines,
            );
            return invoicesProvider.updateInvoice(
              existingInvoice.invoiceId,
              amended.toUpdateJson(),
            );
          }

          // Invoice date and due date are the day the invoice is *issued*,
          // not the day the job is scheduled for — a job booked next month
          // still gets invoiced today. Anchored to SAST via scheduleToday()
          // rather than DateTime.now() so a client running in another
          // timezone cannot stamp yesterday's or tomorrow's date.
          final issuedOn = scheduleToday();
          return invoicesProvider.createInvoice(
            ZohoInvoice(
              invoiceId: '',
              invoiceNumber: _invoiceController.text.trim(),
              customerId: customer.contactId,
              date: issuedOn,
              dueDate: issuedOn,
              notes: _invoiceDetailsController.text.trim(),
              lineItems: usableLines,
            ),
            idempotencyKey: createKey,
          );
        },
        linkToJob: (job, customer, invoice) {
          return jobListService.linkZohoInvoiceTxn(
            jobId: job.id,
            date: job.date,
            zohoContactId: customer.contactId,
            zohoInvoiceId: invoice.invoiceId,
            zohoInvoiceNumber: invoice.invoiceNumber,
            zohoInvoiceStatus: invoice.status.apiValue,
            // Zoho may have auto-numbered; keep the Job List column truthful.
            invoiceNumber: invoice.invoiceNumber,
            amount: invoiceTotal,
          );
        },
      );
    });

    await _saga!.run();
    tl.finish();

    if (mounted) setState(() => _isProcessing = false);
    // The dialog deliberately stays open on success too — the user closes it
    // once they have seen the steps and, if they want, printed the invoice.
  }

  /// Close after a successful invoiced save, telling the caller the job is
  /// already written so it does not write a second copy.
  void _finishInvoicedSave() {
    final xeroSaga = _xeroSaga;
    final saga = _saga;
    var job = xeroSaga?.savedJob ?? saga?.savedJob ?? _splitBaseJob;
    if (job == null) {
      Navigator.of(context).pop();
      return;
    }

    // `savedJob` was captured before the link step, so it still carries the
    // pre-invoice fields. Firestore is correct; stamp the same values onto the
    // object handed back so the grid does not render a stale "not invoiced"
    // row until the stream catches up.
    if (xeroSaga != null) {
      final invoice = xeroSaga.invoice;
      final contact = xeroSaga.customer;
      if (invoice != null) {
        job = job.copyWith(
          invoiceProviderId: AccountingProvider.xero.name,
          accountingContactId: contact.contactId,
          accountingInvoiceId: invoice.invoiceId,
          accountingInvoiceNumber: invoice.invoiceNumber,
          accountingInvoiceStatus: invoice.status.apiValue,
          accountingSyncedAt: DateTime.now(),
          invoice: invoice.invoiceNumber,
          // Xero's own split, matching what linkAccountingInvoiceTxn wrote.
          amount: invoice.subTotal,
          amountExclVat: invoice.subTotal,
          amountInclVat: invoice.total,
          priceIsInclVat: false,
        );
      }
    } else {
      final invoice = saga?.invoice;
      final customer = saga?.customer;
      if (invoice != null && customer != null) {
        job = job.copyWith(
          zohoContactId: customer.contactId,
          zohoInvoiceId: invoice.invoiceId,
          zohoInvoiceNumber: invoice.invoiceNumber,
          zohoInvoiceStatus: invoice.status.apiValue,
          zohoSyncedAt: DateTime.now(),
          invoice: invoice.invoiceNumber,
        );
      }
    }
    // Same for split invoices linked in this dialog.
    final newSplits = [
      for (final d in _splitDrafts)
        if (d.linked != null) d.linked!,
    ];
    if (newSplits.isNotEmpty) {
      job = job.copyWith(splitInvoices: [...job.splitInvoices, ...newSplits]);
    }
    _clearDraft();
    // `invoiced` only distinguishes the caller's success message; the write
    // suppression is carried by `skipAllocation`, the existing convention.
    Navigator.of(context)
        .pop({'job': job, 'skipAllocation': true, 'invoiced': true});
  }

  /// Save or print the Zoho-rendered PDF. [download] saves it directly with
  /// the correct filename; otherwise the print dialog opens.
  Future<void> _printCreatedInvoice({bool download = false}) async {
    final invoice = _saga?.invoice;
    // Two clicks can land before the buttons disable; a second Save dialog
    // would fail and download a stray copy.
    if (invoice == null || _isPrinting) return;

    setState(() => _isPrinting = true);
    try {
      final provider = ref.read(zohoInvoicesRiverpod(_zohoOrgId));
      final fileName =
          invoiceFileName(InvoiceMessageSubject.fromZoho(invoice));
      if (download) {
        // OS Save-As dialog first (it must open straight after the click),
        // fetching the PDF while the user picks a folder. Falls back to an
        // ordinary download where the dialog is unavailable (Firefox,
        // Safari). Every outcome is shown as a toast.
        //
        // Either way the filename is set explicitly — unlike layoutPdf, which
        // prints a blob in an iframe and lets Chrome name the output after the
        // page title ("CLM Schedule").
        await savePdfWithFeedback(
          ScaffoldMessenger.of(context),
          fileName: fileName,
          load: () => provider.getInvoicePdf(invoice.invoiceId),
        );
      } else {
        final bytes = await provider.getInvoicePdf(invoice.invoiceId);
        if (!mounted) return;
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: fileName, // honoured on native; ignored on web
        );
      }
    } catch (e) {
      if (mounted) {
        final error = describeAccountingError(e,
            action: download ? 'download the PDF' : 'open the PDF for printing');
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text(error.message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  /// When a job is moved into the nominated "cancelled" status, offer to void
  /// its invoice so work never done does not leave a live invoice behind.
  ///
  /// Only fires on the transition into cancelled — re-saving an already
  /// cancelled job must not nag on every edit.
  Future<void> _maybeVoidOnCancel(JobListItem saved) async {
    final settings = ref.read(zohoSyncSettingsRiverpod);
    if (!settings.isCancelledStatus(saved.jobStatusId)) return;

    final wasAlreadyCancelled =
        settings.isCancelledStatus(widget.jobToEdit?.jobStatusId ?? '');
    if (wasAlreadyCancelled) return;

    if (!mounted) return;
    await maybeVoidInvoiceForJob(
      context: context,
      ref: ref,
      job: saved,
      reason: 'has been marked cancelled',
    );
  }

  /// The draft has served its purpose once the job exists.
  void _clearDraft() {
    if (_canDraft) ref.read(jobDraftServiceRiverpod).clear();
  }

  Future<void> _saveJob() => _submitOnce(_saveJobBody);

  Future<void> _saveJobBody() async {
    if (!_formKey.currentState!.validate()) return;
    final isEdit = widget.jobToEdit != null && widget.jobToEdit!.id.isNotEmpty;
    final tl = _startTimeline(isEdit ? 'Edit job' : 'Add job');

    // Async duplicate check — covers months not currently loaded in memory.
    if (!await tl.step('duplicate-name check', _clientNameIsFree)) {
      tl.finish();
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    final jobListItem = _buildJobListItem();

    try {
      // Offer address geocoding for Junk & Stuff and Happy Sun jobs with a
      // usable address — CLM distribution and community jobs are worked
      // over areas, and a pin on every schedule job only clutters the
      // dropsheet and work areas.
      // Priority: `area` field (when it's a free-text address, not a map link)
      // → `collectionAddress` field. Skip if area is a URL/map-link.
      JobListItem finalJobListItem = jobListItem;
      CustomPolygon? addressPoint;

      final areaText = jobListItem.area.trim();
      final collectionText = jobListItem.collectionAddress.trim();
      final areaIsMapLink = _isMapLinkOrUrl(areaText);

      String? addressToSearch;
      if (ClientAddressPin.isCallOutJobType(jobListItem.jobTypeId)) {
        if (areaText.isNotEmpty && !areaIsMapLink) {
          addressToSearch = areaText;
        } else if (collectionText.isNotEmpty) {
          addressToSearch = collectionText;
        }
      }

      if (addressToSearch != null) {
        final address = addressToSearch;
        addressPoint = await tl.userStep('address pin',
            () => _resolveAddressPoint(address, _selectedJobType));
        if (addressPoint != null) {
          // Attach the geocoded point to the job list item's custom polygons
          finalJobListItem = jobListItem.copyWith(
            customPolygons: [
              ...jobListItem.customPolygons,
              addressPoint,
            ],
          );
        }
      }

      // If editing an existing job (not a copy — copies have an empty id).
      if (isEdit) {
        // Offer to void the invoice when this edit moves the job into the
        // nominated cancelled status. Runs before the pop because the
        // dialog is the only place that knows both the old and new status;
        // the caller owns the DB write, so a user who confirms the void and
        // then hits a save failure would have voided early — they confirm
        // explicitly, and the invoice can be recreated.
        await tl.userStep(
            'void-invoice check', () => _maybeVoidOnCancel(finalJobListItem));
        if (!mounted) return;
        _clearDraft();
        Navigator.of(context).pop(finalJobListItem);
        tl.markClosed();
        return;
      }

      // A new or copied job. The dialog saves it itself, without waiting
      // for the server (see [_addNewJob]), and closes. With an allocation,
      // the schedule jobs and the Job List job are saved side by side once
      // the preview is confirmed.
      String message;
      if (finalJobListItem.regularClientId.isNotEmpty) {
        // A regular client's job is allocated from its own copies of the
        // plan's areas, so they are copied in first. It is saved whether
        // or not the allocation goes ahead.
        final withAreas = await tl.step('copy regular client areas',
            () => _withRegularClientPolygons(finalJobListItem));
        final allocated = await _allocateToSchedule(withAreas,
            addressPoint: addressPoint, waitForSave: false);
        finalJobListItem = withAreas;
        message = allocated != null
            ? 'Job added and allocated to the schedule!'
            : 'Job added — not allocated to the schedule. '
                'Edit the job and use Automatic Allocation to allocate.';
      } else if (_jobTypeAutoAllocates) {
        final allocated = await _allocateToSchedule(finalJobListItem,
            addressPoint: addressPoint, waitForSave: false);
        // Declined or impossible: the dialog stays open, as before.
        if (allocated == null) {
          tl.finish();
          return;
        }
        message = 'Job added and allocated to the schedule!';
      } else {
        message = 'Job added!';
      }

      final saved = await tl.step(
          'add to Job List (on screen)', () => _addNewJob(finalJobListItem));
      if (!mounted) return;
      _clearDraft();
      Navigator.of(context).pop({
        'job': saved,
        'skipAllocation': true,
        'message': message,
        'saved': _jobSaved,
      });
      tl.markClosed();
    } catch (e) {
      tl.finish();
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text('Error saving job: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _saveJobWithoutAllocation() =>
      _submitOnce(_saveJobWithoutAllocationBody);

  Future<void> _saveJobWithoutAllocationBody() async {
    // Skipping the schedule allocation must not also skip the invoice —
    // they are unrelated decisions, and a job saved here with invoicing
    // switched on was silently left unbilled. The saga already writes the
    // job itself and never touches the schedule, so it *is* the
    // skip-allocation path for an invoiced job; it returns the same
    // `skipAllocation: true` marker so the caller still does not re-write.
    if (_willInvoice) {
      debugPrint('   🧾 Invoicing is on — running the invoice saga instead '
          '(it allocates nothing either)');
      _allocateAfterInvoice = false;
      await _saveJobWithInvoice();
      return;
    }

    if (!_formKey.currentState!.validate()) return;
    final tl = _startTimeline('Add job (no allocation)');

    // Async duplicate check — covers months not currently loaded in memory.
    if (!await tl.step('duplicate-name check', _clientNameIsFree)) {
      tl.finish();
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    final jobListItem = _buildJobListItem();

    try {
      // Saved without waiting for the server (see [_addNewJob]); the dialog
      // returns the saved job — with its id — to the caller. Callers like
      // the Job List "copy" flow rely on that id to clone the linked map
      // afterwards, once `saved` says the server has the job.
      final savedJob = await tl.step(
          'add to Job List (on screen)', () => _addNewJob(jobListItem));
      _clearDraft();
      if (!mounted) return;
      Navigator.of(context).pop({
        'job': savedJob,
        'skipAllocation': true,
        'saved': _jobSaved,
      });
      tl.markClosed();
    } catch (e) {
      tl.finish();
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text('Error saving job: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _saveJobWithAutomaticAllocation() =>
      _submitOnce(_saveJobWithAutomaticAllocationBody);

  Future<void> _saveJobWithAutomaticAllocationBody() async {
    if (!_formKey.currentState!.validate()) return;
    final tl = _startTimeline('Allocate job');

    // Async duplicate check — covers months not currently loaded in memory.
    if (!await tl.step('duplicate-name check', _clientNameIsFree)) {
      tl.finish();
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    final jobListItem = _buildJobListItem();

    try {
      // For editing with automatic allocation, show assignment preview
      await _showJobAssignmentPreview(jobListItem);
    } finally {
      tl.finish();
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  /// Returns true if [text] looks like a URL or a shareable-map link (and
  /// therefore is NOT a free-text street address that should be geocoded).
  bool _isMapLinkOrUrl(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    return t.startsWith('http://') ||
        t.startsWith('https://') ||
        MapLinkService.containsShareUrl(t) ||
        t.contains('google.com/maps') ||
        t.contains('maps.app.goo.gl') ||
        t.contains('goo.gl/maps');
  }

  Future<CustomPolygon?> _resolveAddressPoint(
      String address, String jobTypeId) async {
    if (!mounted) return null;

    final isHappySun =
        JobTypeProvider.instance?.isHappySunService(jobTypeId) ?? false;
    final isFurniture = jobTypeId == 'furnitureMove';

    PointCategory category;
    String label;
    if (isHappySun) {
      category = PointCategory.cleaning;
      label = 'Cleaning Address';
    } else if (isFurniture) {
      category = PointCategory.loading;
      label = 'Furniture Address';
    } else {
      category = PointCategory.pickup;
      label = 'Collection Address';
    }

    final result = await showDialog<AddressPointResult?>(
      context: context,
      builder: (_) => AddressPointSearchDialog(
        initialAddress: address,
        label: label,
        category: category,
      ),
    );

    return result?.toCustomPolygon();
  }

  Future<void> _showJobAssignmentPreview(JobListItem jobListItem,
      {CustomPolygon? addressPoint}) async {
    final allocated = await _allocateToSchedule(jobListItem,
        addressPoint: addressPoint, waitForSave: false);
    if (allocated != null && mounted) {
      // Return the original job list item
      _clearDraft();
      Navigator.of(context).pop(jobListItem);
      _timeline?.markClosed();
    }
  }

  /// Calculate assignments, show the preview and, on confirm, create the
  /// schedule jobs. Returns the summary when the user confirmed, null when
  /// they declined or it failed (the failure is shown). Never pops this
  /// dialog — callers decide what happens next. With [waitForSave] false it
  /// returns once the jobs are on the grid; the save carries on behind.
  Future<String?> _allocateToSchedule(JobListItem jobListItem,
      {CustomPolygon? addressPoint, bool waitForSave = true}) async {
    try {
      return await _assignToSchedule(jobListItem,
          addressPoint: addressPoint, waitForSave: waitForSave);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text(e is StateError ? e.message : '$e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  /// Core of the schedule allocation, shared by the plain save and the
  /// invoicing saga's "Allocate to Schedule" step. Returns a summary when the
  /// schedule jobs were created, null when the user declined the preview, and
  /// throws when no assignment is possible or — with [waitForSave] — the
  /// schedule write fails.
  Future<String?> _assignToSchedule(JobListItem jobListItem,
      {CustomPolygon? addressPoint, bool waitForSave = true}) async {
    final tl = _timeline;
    final scheduleProvider = ref.read(scheduleRiverpod);
    final assignmentService = JobAssignmentService(
      scheduleProvider,
      dayOffProvider: ref.read(dayOffRiverpod),
    );
    final areaText = jobListItem.area.trim();
    final assignmentWorkArea =
        areaText.isNotEmpty && !_isMapLinkOrUrl(areaText)
            ? areaText
            : 'To be assigned';

    final allowOccupied = _allowsDoubleBooking(jobListItem.jobTypeId);

    String? note;
    final List<JobAssignment> proposed;
    if (jobListItem.regularClientId.isNotEmpty) {
      final maps = tl == null
          ? await _regularClientMaps(jobListItem)
          : await tl.step('read regular client plan',
              () => _regularClientMaps(jobListItem));
      proposed = assignmentService.calculateRegularClientAssignments(
        client: jobListItem.client,
        plan: maps.plan,
        map: maps.areas,
        startDate: jobListItem.date,
        allowOccupied: allowOccupied,
      );
      note = maps.note;
    } else {
      proposed = assignmentService.calculateJobAssignments(
        client: jobListItem.client,
        manDays: jobListItem.manDays,
        startDate: jobListItem.date,
        workingArea: assignmentWorkArea,
        allowOccupied: allowOccupied,
      );
    }
    if (proposed.isEmpty) {
      throw StateError(
          'Unable to assign jobs - no available distributors found.');
    }

    if (!mounted) return null;
    Future<List<JobAssignment>?> preview() => showDialog<List<JobAssignment>>(
          context: context,
          builder: (context) => JobAssignmentPreviewDialog(
            assignments: proposed,
            allowOccupied: allowOccupied,
            note: note,
            candidatesFor: (date) => assignmentService.candidatesFor(date,
                allowOccupied: allowOccupied),
            onConfirm: (edited) => Navigator.of(context).pop(edited),
            onCancel: () => Navigator.of(context).pop(),
          ),
        );
    final assignments = tl == null
        ? await preview()
        : await tl.userStep('allocation preview', preview);
    if (assignments == null || assignments.isEmpty || !mounted) return null;

    await _createScheduleJobs(assignmentService, assignments,
        addressPoint: addressPoint, waitForSave: waitForSave);
    return 'Assigned ${assignments.length} '
        '${assignments.length == 1 ? 'job' : 'jobs'} to distributors';
  }

  /// Everything a regular-client job's allocation needs: the plan and the
  /// map to take its areas from.
  ///
  /// Nothing is linked: the schedule jobs get copies of the areas. They come
  /// from the job's own copied polygons ([JobListItem.customPolygons], see
  /// [_withRegularClientPolygons]) — so an area redrawn on this job is worked
  /// as redrawn — unless the job holds none of the plan's areas, in which
  /// case they come from the plan's map.
  ///
  /// Throws a [StateError] the caller shows when the plan or its map is gone,
  /// or the plan has no slots.
  Future<_RegularClientMaps> _regularClientMaps(JobListItem job) async {
    final plan = await _regularClientWithMap(job.regularClientId);
    if (plan.slots.isEmpty) {
      throw StateError('${plan.name} has no distributor slots yet. Open it '
          'under Apps → Regular Clients and allocate its areas.');
    }
    final template = plan.map!;

    final own = [
      for (final p in job.customPolygons)
        if ((p.id ?? '').isNotEmpty && plan.allocatedIds.contains(p.id)) p,
    ];
    final ownIds = {for (final p in own) p.id};
    final areas = own.isEmpty
        ? template
        : template.copyWith(layers: [
            MapLayer(
              id: 'job_areas',
              name: MapLayer.targetAreasName,
              order: 0,
              defaultColor: Colors.blue,
              polygons: own,
              // Points the job holds no copy of (a job saved before plans
              // had points) still come from the plan's map.
              points: [
                for (final l in template.layers)
                  for (final pt in l.points)
                    if (!ownIds.contains(pt.id)) pt,
              ],
              createdAt: template.createdAt,
              updatedAt: template.updatedAt,
            ),
          ]);

    final missing = plan.missingIds(_polygonIds(areas)).length;
    final note = 'From regular client map ${plan.name}.'
        '${own.isNotEmpty ? ' Areas from this job\'s copied areas.' : ''}'
        '${missing > 0 ? ' $missing area(s) in the plan are not on the map '
            'and were skipped.' : ''}';
    return _RegularClientMaps(plan: plan, areas: areas, note: note);
  }

  /// Regular client [id] with its own map (copied, read-only, from the
  /// gallery map it was made from if it predates plans owning one).
  ///
  /// Read once per dialog: the save and the allocation both need it.
  Future<RegularClient> _regularClientWithMap(String id) =>
      _regularClientCache[id] ??= _readRegularClientWithMap(id).then(
        (plan) => plan,
        onError: (Object e, StackTrace st) {
          _regularClientCache.remove(id); // a retry reads it again
          Error.throwWithStackTrace(e, st);
        },
      );

  Future<RegularClient> _readRegularClientWithMap(String id) async {
    final service = RegularClientService();
    final plan = await service.get(id);
    if (plan == null) {
      throw StateError('The regular client map for this job was deleted.');
    }
    return service.ensureOwnMap(plan);
  }

  static Set<String> _polygonIds(ShareableMap map) => {
        for (final l in map.layers) ...[
          for (final p in l.polygons)
            if ((p.id ?? '').isNotEmpty) p.id!,
          for (final pt in l.points)
            if (pt.id.isNotEmpty) pt.id,
        ],
      };

  /// [draft] carrying copies of its regular client's areas in
  /// `customPolygons`, ids and all, so the plan still matches them. No map
  /// is made or linked: the plan's map stays in the Regular Clients library
  /// and the job owns only its copies. A draft that already holds some of
  /// the plan's areas (a copied job) is returned as it is.
  ///
  /// For a job about to be saved, where a failure must not stop the save: it
  /// is reported and the draft is returned without areas.
  Future<JobListItem> _withRegularClientPolygons(JobListItem draft) async {
    if (draft.regularClientId.isEmpty) return draft;
    try {
      final plan = await _regularClientWithMap(draft.regularClientId);
      final held = {for (final p in draft.customPolygons) p.id};
      if (plan.allocatedIds.any(held.contains)) return draft;
      return draft.copyWith(customPolygons: [
        ...draft.customPolygons,
        for (final l in plan.map!.layers) ...[
          for (final p in l.polygons)
            if (p.isPolygon && p.points.length >= 3) p,
          // Handout and poster spots, as point-type polygons with the
          // point's id so the plan still matches them.
          for (final pt in l.points)
            if (pt.id.isNotEmpty) mapPointAsWorkMap(pt),
        ],
      ]);
    } catch (e) {
      debugPrint('⚠️ Regular client areas for ${draft.client} failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(SnackBar(
          content: Text('The job is saved without its areas — they could '
              'not be copied from the regular client map: $e'),
          backgroundColor: Colors.orange.shade800,
        ));
      }
      return draft;
    }
  }

  /// Save [draft] as a new job (a create or a copy) and return it with its
  /// id. A regular-client job is saved with copies of its plan's areas and
  /// then gets its own map made from the plan's map — see
  /// [_createRegularClientJobMap].
  ///
  /// Returns as soon as the job is on the Job List: the id is made on this
  /// device and Firestore keeps the write queued until the server has it
  /// (see [JobListProvider.addJobListItemLocal]). That confirmation is kept
  /// in [_jobSaved]; [waitForServer] waits for it — the invoice saga needs
  /// the job on the server before its link transaction.
  Future<JobListItem> _addNewJob(JobListItem draft,
      {bool waitForServer = false}) async {
    // Captured up front: the map is made after the dialog may have closed.
    final provider = ref.read(jobListRiverpod);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final added =
        provider.addJobListItemLocal(await _withRegularClientPolygons(draft));
    final saved = added.job;
    _jobSaved = added.saved;
    if (!waitForServer) {
      _timeline?.background('Job List job saved on the server', added.saved);
      unawaited(added.saved.then((_) {}, onError: (Object e) {
        messenger?.showToast(SnackBar(
          content: Text('The job "${saved.client}" could not be saved: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 12),
        ));
      }));
    }
    if (saved.regularClientId.isNotEmpty) {
      // Not awaited: the allocation preview, or the dialog closing, need not
      // wait on it. Made once the server has the job, which the map links to.
      unawaited(added.saved.then(
        (_) => _createRegularClientJobMap(saved, provider, messenger),
        onError: (_) {},
      ));
    }
    if (waitForServer) await added.saved;
    return saved;
  }

  /// Give the saved regular-client [job] its own map, like a copied job gets
  /// a clone of its source's map: a new gallery map holding the plan's map
  /// layers (ids kept, so the schedule-allocation view still matches the
  /// job's copied areas), named after the client with the job's month on the
  /// description's first line, filed in the job's SAST month and linked to
  /// the job.
  ///
  /// Linking writes `shareableMapId`, and the `onJobListItemWritten` trigger
  /// then files the job's Cloud Files folder onto the map as usual. The
  /// plan's map itself stays in the Regular Clients library, untouched.
  ///
  /// Failures are reported and never thrown: the job is already saved, and a
  /// map can still be linked from the Area column.
  static Future<void> _createRegularClientJobMap(
    JobListItem job,
    JobListProvider provider,
    ScaffoldMessengerState? messenger,
  ) async {
    try {
      final service = RegularClientService();
      final stored = await service.get(job.regularClientId);
      if (stored == null) {
        throw StateError('the regular client map for this job was deleted');
      }
      final template = (await service.ensureOwnMap(stored)).map!;
      final layers = [
        for (final l in template.layers)
          if (!l.name.toLowerCase().contains('cloud')) l,
      ];

      final civil = toScheduleCivil(job.date);
      final monthKey = ShareableMapsFirestoreService.monthKeyFor(civil);
      final name = job.client.trim();
      final map = ShareableMap.createWithDefaultLayer(
        name: name,
        description: copyDescription(template.description, civil),
        defaultCenter: template.defaultCenter,
        jobListItemId: job.id,
      ).copyWith(
        layers: layers.isEmpty ? null : layers,
        defaultZoom: template.defaultZoom,
      );

      final mapId = await ShareableMapsFirestoreService()
          .createMap(map, monthKey: monthKey);
      await provider.linkExistingMapToJob(
        jobId: job.id,
        mapId: mapId,
        monthKey: monthKey,
        mapName: name,
        fallbackJob: job,
      );
      debugPrint('🗺️ Regular client map $monthKey/$mapId made for '
          '${job.client} (${job.id})');
    } catch (e) {
      debugPrint('⚠️ Regular client map for ${job.client} failed: $e');
      messenger?.showToast(SnackBar(
        content: Text('The job is saved, but its map could not be made from '
            'the regular client map: $e'),
        backgroundColor: Colors.orange.shade800,
      ));
    }
  }

  /// Puts [assignments] on the schedule as one write ([ScheduleProvider
  /// .addJobsWithUndo]). They show on the grid at once. With [waitForSave]
  /// this completes once the server has them and throws if it refuses;
  /// without, it returns straight away and the write queue saves them
  /// behind — retrying through dropped connections, with the connection
  /// banner saying so — and a refusal is reported in a toast.
  Future<void> _createScheduleJobs(
      JobAssignmentService assignmentService, List<JobAssignment> assignments,
      {CustomPolygon? addressPoint, bool waitForSave = true}) async {
    final scheduleProvider = ref.read(scheduleRiverpod);
    final messenger = ScaffoldMessenger.maybeOf(context);

    // Convert assignments to Job objects
    var jobs = assignmentService.createJobsFromAssignments(assignments);

    // Inject the geocoded address point into each schedule job's workMaps,
    // marked as the client's pin so taking the client off the job later
    // takes the pin with it.
    if (addressPoint != null) {
      jobs = jobs
          .map((j) => j.copyWith(workMaps: [
                ...j.workMaps,
                j.clients.isEmpty
                    ? addressPoint
                    : ClientAddressPin.asAutoPin(addressPoint, j.clients.first),
              ]))
          .toList();
    }

    final client = _clientController.text.trim();
    final what = '${jobs.length} schedule '
        '${jobs.length == 1 ? 'job' : 'jobs'}';
    // One transaction for the lot. They used to be saved one transaction
    // after another, a server round trip or two each.
    final write = scheduleProvider.addJobsWithUndo(jobs);

    if (waitForSave) {
      try {
        final tl = _timeline;
        await (tl == null
            ? write
            : tl.step('save $what (1 transaction)', () => write));
      } catch (e) {
        messenger?.showToast(
          SnackBar(
            content: Text('Error adding jobs to schedule: $e'),
            backgroundColor: Colors.red,
          ),
        );
        rethrow; // Re-throw so the calling method can handle it
      }
      messenger?.showToast(
        SnackBar(
          content: Text('Successfully assigned ${jobs.length} jobs to '
              'distributors!'),
          backgroundColor: Colors.green,
        ),
      );
      return;
    }

    _timeline?.background('save $what on the server (1 transaction)', write);
    unawaited(write.then((_) {}, onError: (Object e) {
      // The provider has already taken them back off the grid.
      messenger?.showToast(
        SnackBar(
          content: Text('The $what for ${client.isEmpty ? 'this job' : client} '
              'could not be saved: $e. Open the job and use Automatic '
              'Allocation to try again.'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 12),
        ),
      );
    }));
  }

  // Helper methods for time selection
  bool _needsTimeSelection(String jobTypeId) {
    final provider = JobTypeProvider.instance;
    if (provider == null) return false;
    return provider.needsTimeSlot(jobTypeId);
  }

  /// True when the selected job type has `autoAllocatesToSchedule = true`.
  /// Controls whether the "Add Job" button shows the assignment preview and
  /// whether the "Skip Allocation" override button is visible.
  ///
  /// A regular client plan counts too: picking one is asking for the
  /// allocation it describes, whatever the job type.
  bool get _jobTypeAutoAllocates =>
      _regularClientId.isNotEmpty ||
      (JobTypeProvider.instance?.autoAllocatesToSchedule(_selectedJobType) ??
          false);

  /// Junk & Stuff and Happy Sun jobs are short call-outs, so one distributor
  /// can take several in a day — the allocation may pick someone who already
  /// has a schedule job that day. CLM distribution stays one job per person.
  bool _allowsDoubleBooking(String jobTypeId) =>
      ClientAddressPin.isCallOutJobType(jobTypeId);

  /// True when the selected job type has `hasTwoStops = true`.
  /// Renames the area field to "Loading Address" and shows an additional
  /// "Offloading Address" field below it.
  bool get _jobTypeHasTwoStops =>
      JobTypeProvider.instance?.hasTwoStops(_selectedJobType) ?? false;

  void _showToolsDialog() async {
    debugPrint('\n🔧 AddEditJobDialog._showToolsDialog: Opening tools dialog');
    debugPrint('   Job Type: $_selectedJobType');
    debugPrint(
        '   Current tools: ${_toolsNeeded != null ? "${_toolsNeeded!.totalCount} tools" : "None"}');

    // Validate form before opening tools dialog
    if (!_formKey.currentState!.validate()) {
      // Scroll to top to show validation errors
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }

    final inventoryProvider = ref.read(inventoryRiverpod);
    final toolSettingsProvider = ref.read(toolSettingsRiverpod);

    // Initialize inventory if needed
    if (inventoryProvider.tools.isEmpty && !inventoryProvider.isLoading) {
      await inventoryProvider.initialize();
    }

    // Initialize tool settings if needed
    if (toolSettingsProvider.settings.teamTools.isEmpty &&
        toolSettingsProvider.settings.individualTools.isEmpty) {
      await toolSettingsProvider.loadSettings();
    }

    if (!mounted) return;

    // Auto-calculate tools based on manDays if not already set
    CategorizedTools initialTools;
    if (_toolsNeeded == null) {
      final numberOfCleaners =
          (double.tryParse(_manDaysController.text) ?? 0).ceil();

      if (numberOfCleaners > 0) {
        // Calculate categorized tools: team tools (constant) + individual tools (per cleaner) + accessories
        initialTools = toolSettingsProvider.calculateCategorizedTools(
          numberOfCleaners,
          inventoryProvider.tools,
        );

        debugPrint(
            '🔧 Auto-calculated tools for $numberOfCleaners cleaner(s):');
        debugPrint('   Team tools: ${initialTools.teamTools.length} groups');
        debugPrint(
            '   Individual tools: ${initialTools.individualTools.length} groups');
        debugPrint('   Extras: ${initialTools.extras.length} groups');
        debugPrint('   Accessories: ${initialTools.accessories.length} groups');
      } else {
        initialTools = CategorizedTools.empty();
      }
    } else {
      initialTools = _toolsNeeded!;
    }

    // Show tools dialog
    final result = await showDialog<CategorizedTools>(
      context: context,
      builder: (context) => HappySunToolsDialog(
        currentTools: initialTools,
        availableTools: inventoryProvider.tools,
      ),
    );

    if (result != null) {
      debugPrint('   ✅ Tools dialog returned with tools');
      debugPrint('   Team tools: ${result.teamTools.length}');
      debugPrint('   Individual tools: ${result.individualTools.length}');
      debugPrint('   Extras: ${result.extras.length}');
      debugPrint('   Accessories: ${result.accessories.length}');
      debugPrint('   Total count: ${result.totalCount}');
      setState(() {
        _toolsNeeded = result;
      });
    } else {
      debugPrint('   ❌ Tools dialog cancelled');
    }
  }
}

/// Simple data class for map name + share URL pairs used in autocomplete.
/// One split invoice being prepared in [AddEditJobDialog]: the customer and
/// lines for the provider in play, then the saga that raises it.
class _SplitInvoiceDraft {
  /// Stable for the life of the dialog — part of the Xero idempotency key, so
  /// a retry replays this invoice rather than raising another.
  final String key;

  XeroContact? xeroContact;
  List<XeroLineItem> xeroLines = const [];

  ZohoCustomer? zohoCustomer;
  List<ZohoLineItem> zohoLines = const [];

  String? error;

  /// Set once this invoice's save starts; kept across retries.
  InvoiceSaveSaga<Object?, Object?>? saga;

  /// The link written to the job, once it has been.
  JobInvoiceLink? linked;

  _SplitInvoiceDraft({required this.key});

  bool get isDone => linked != null;

  List<XeroLineItem> get usableXeroLines {
    final lines = xeroLines
        .where((li) => li.description.trim().isNotEmpty && li.quantity > 0)
        .toList();
    return lines.any((li) => li.amount > 0) ? lines : const [];
  }

  List<ZohoLineItem> get usableZohoLines {
    final lines =
        zohoLines.where((li) => li.name.isNotEmpty && li.quantity > 0).toList();
    return lines.any((li) => li.amount > 0) ? lines : const [];
  }
}

/// One company's job types in the job type menu.
class _JobTypeGroup {
  final String companyId;
  final String name;
  final Color color;
  final List<CustomJobType> types;

  const _JobTypeGroup({
    required this.companyId,
    required this.name,
    required this.color,
    required this.types,
  });
}

/// The job type menu's whole body as a single entry, so its sections can be
/// collapsed while it is open. Picking a type pops the menu with its id.
class _JobTypeGroupsMenuEntry extends PopupMenuEntry<String> {
  final List<_JobTypeGroup> groups;
  final String selectedId;

  /// Owned by the dialog and mutated here, so the state outlives the menu.
  final Set<String> collapsed;
  final IconData Function(String? iconName) iconFor;

  const _JobTypeGroupsMenuEntry({
    required this.groups,
    required this.selectedId,
    required this.collapsed,
    required this.iconFor,
  });

  @override
  double get height => 0;

  @override
  bool represents(String? value) => false;

  @override
  State<_JobTypeGroupsMenuEntry> createState() =>
      _JobTypeGroupsMenuEntryState();
}

class _JobTypeGroupsMenuEntryState extends State<_JobTypeGroupsMenuEntry> {
  void _toggle(String companyId) {
    setState(() {
      if (!widget.collapsed.remove(companyId)) {
        widget.collapsed.add(companyId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in widget.groups) _buildSection(context, group),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, _JobTypeGroup group) {
    final theme = Theme.of(context);
    final color = group.color;
    final isCollapsed = widget.collapsed.contains(group.companyId);
    final hasSelected = group.types.any((t) => t.id == widget.selectedId);
    final onColor =
        color.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: tap anywhere on it to collapse or expand.
          Material(
            color: color.withValues(alpha: 0.14),
            child: InkWell(
              onTap: () => _toggle(group.companyId),
              child: Container(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: color, width: 4)),
                ),
                padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: color,
                      child: Text(
                        group.name.isEmpty ? '?' : group.name[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: onColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        group.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Color.lerp(color, Colors.black, 0.35),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // A collapsed section still says it holds the selection.
                    if (isCollapsed && hasSelected)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(Icons.check_circle, size: 16, color: color),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${group.types.length}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: onColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: isCollapsed ? -0.25 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.expand_more, color: color),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: isCollapsed
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final t in group.types)
                        InkWell(
                          onTap: () => Navigator.of(context).pop(t.id),
                          child: _JobTypeRow(
                            type: t,
                            icon: widget.iconFor(t.iconName),
                            selected: t.id == widget.selectedId,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _MapSuggestion {
  final String name;
  final String url;
  const _MapSuggestion({required this.name, required this.url});
}

/// Outlined tap-to-open field used for all picker dropdowns in the dialog.
/// Provides a unified visual: colored accent dot, label text, and chevron.
class _PickerFieldShell extends StatelessWidget {
  final String label;
  final Color accent;
  final Widget? leading;
  final String text;
  final bool isPlaceholder;
  final void Function(BuildContext anchorContext) onTap;

  const _PickerFieldShell({
    required this.label,
    required this.accent,
    required this.text,
    required this.onTap,
    this.leading,
    this.isPlaceholder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Builder(
      builder: (ctx) => InkWell(
        onTap: () => onTap(ctx),
        borderRadius: BorderRadius.circular(6),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent,
                      Color.lerp(accent, Colors.black, 0.2) ?? accent,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.25),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: leading == null ? null : Center(child: leading!),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isPlaceholder ? theme.hintColor : null,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.keyboard_arrow_down, size: 22, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact single-line picker row used by the status and vehicle-trailer
/// menus (color dot + optional icon + label + check when selected).
class _SimplePickerRow extends StatelessWidget {
  final Color color;
  final String label;
  final bool selected;
  final IconData? icon;

  const _SimplePickerRow({
    required this.color,
    required this.label,
    required this.selected,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor =
        color.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;
    final bg = selected ? color.withValues(alpha: 0.14) : Colors.transparent;

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: icon == null ? null : Icon(icon, size: 13, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 18, color: color)
          else
            const SizedBox(width: 18),
        ],
      ),
    );
  }
}

/// Narrow job-type menu row: left accent stripe, gradient avatar, label,
/// and a small wrap of behaviour-flag chips underneath.
class _JobTypeRow extends StatelessWidget {
  final CustomJobType type;
  final IconData icon;
  final bool selected;

  const _JobTypeRow({
    required this.type,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = type.colorValue != null
        ? Color(type.colorValue!)
        : theme.colorScheme.primary;
    final iconColor =
        accent.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

    final chips = <Widget>[];
    if (type.needsTimeSlot) {
      chips.add(const _FlagChip(
          icon: Icons.schedule, label: 'Time', color: Colors.indigo));
    }
    if (type.appearsOnCollectionSchedule) {
      chips.add(const _FlagChip(
          icon: Icons.local_shipping, label: 'Collection', color: Colors.teal));
    }
    if (type.isHappySunService) {
      chips.add(const _FlagChip(
          icon: Icons.wb_sunny_outlined,
          label: 'Happy Sun',
          color: Colors.orange));
    }
    if (type.tracksQuantity) {
      chips.add(_FlagChip(
          icon: Icons.numbers,
          label: type.quantityLabel,
          color: Colors.blueGrey));
    }

    final bg = selected ? accent.withValues(alpha: 0.12) : Colors.transparent;

    return IntrinsicHeight(
      child: Container(
        color: bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left accent stripe
            Container(width: 4, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent,
                            Color.lerp(accent, Colors.black, 0.2) ?? accent,
                          ],
                        ),
                      ),
                      child: Icon(icon, size: 16, color: iconColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            type.label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (chips.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 4,
                              runSpacing: 3,
                              children: chips,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (selected)
                      Icon(Icons.check_circle, size: 18, color: accent),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _FlagChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// What [_AddEditJobDialogState._regularClientMaps] resolves.
class _RegularClientMaps {
  final RegularClient plan;

  /// The map whose polygons the schedule jobs are given.
  final ShareableMap areas;

  /// Shown in the allocation preview.
  final String note;

  const _RegularClientMaps({
    required this.plan,
    required this.areas,
    required this.note,
  });
}
