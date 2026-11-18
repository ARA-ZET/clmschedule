import 'package:clmschedule/widgets/app_toast.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/company.dart';
import '../models/custom_job_type.dart';
import '../providers/company_provider.dart';
import '../providers/job_type_provider.dart';
import '../providers/zoho_items_provider.dart';
import '../utils/zoho_org.dart';
import 'xero/xero_item_picker.dart';
import 'zoho/zoho_item_picker.dart';

/// Settings dialog for managing custom job types. Exposes every behaviour
/// flag on [CustomJobType] so that adding a new service or adjusting an
/// existing one never requires an app update.
class JobTypeManagementDialog extends riverpod.ConsumerStatefulWidget {
  const JobTypeManagementDialog({super.key});

  @override
  riverpod.ConsumerState<JobTypeManagementDialog> createState() =>
      _JobTypeManagementDialogState();
}

class _JobTypeManagementDialogState
    extends riverpod.ConsumerState<JobTypeManagementDialog> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _quantityLabelController =
      TextEditingController();
  bool _isAdding = false;
  String? _editingId;

  // Flag state for the in-progress edit/add.
  bool _isHappySunService = false;
  bool _needsTimeSlot = false;
  bool _appearsOnCollectionSchedule = false;
  bool _tracksQuantity = true;
  bool _createsCloudFolder = false;
  bool _autoAllocatesToSchedule = false;
  bool _hasTwoStops = false;
  bool _chargesVat = false;

  /// Owning company. Empty means still inferred from the legacy flags.
  String _companyId = '';
  bool _createsInvoices = true;

  /// Catalogue item this job type bills as; empty means free-text lines.
  String _accountingItemCode = '';

  /// Items this job type may bill as; empty means the whole catalogue.
  List<String> _accountingItemCodes = const [];
  String? _iconName;
  int? _colorValue;

  @override
  void dispose() {
    _labelController.dispose();
    _quantityLabelController.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _isAdding = true;
      _editingId = null;
      _labelController.clear();
      _quantityLabelController.text = 'Quantity';
      _isHappySunService = false;
      _needsTimeSlot = false;
      _appearsOnCollectionSchedule = false;
      _tracksQuantity = true;
      _createsCloudFolder = false;
      _autoAllocatesToSchedule = false;
      _hasTwoStops = false;
      _chargesVat = false;
      _companyId = '';
      _createsInvoices = true;
      _accountingItemCode = '';
      _accountingItemCodes = const [];
      _iconName = null;
      _colorValue = null;
    });
  }

  void _startEdit(CustomJobType jobType) {
    setState(() {
      _isAdding = false;
      _editingId = jobType.id;
      _labelController.text = jobType.label;
      _quantityLabelController.text = jobType.quantityLabel;
      _isHappySunService = jobType.isHappySunService;
      _needsTimeSlot = jobType.needsTimeSlot;
      _appearsOnCollectionSchedule = jobType.appearsOnCollectionSchedule;
      _tracksQuantity = jobType.tracksQuantity;
      _createsCloudFolder = jobType.createsCloudFolder;
      _autoAllocatesToSchedule = jobType.autoAllocatesToSchedule;
      _hasTwoStops = jobType.hasTwoStops;
      _chargesVat = jobType.chargesVat;
      _companyId = jobType.companyId;
      _createsInvoices = jobType.createsInvoices;
      _accountingItemCode = jobType.accountingItemCode;
      _accountingItemCodes = jobType.accountingItemCodes;
      _iconName = jobType.iconName;
      _colorValue = jobType.colorValue;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isAdding = false;
      _editingId = null;
      _labelController.clear();
      _quantityLabelController.clear();
    });
  }

  /// Whether the job type being edited bills through Xero.
  ///
  /// Uses the same resolution the Add Job dialog does, including the legacy
  /// fallback, so the item picker appears exactly when an item would be used.
  AccountingProvider get _invoiceProvider {
    final preview = CustomJobType(
      id: '_preview',
      label: '',
      companyId: _companyId,
      createsInvoices: _createsInvoices,
      appearsOnCollectionSchedule: _appearsOnCollectionSchedule,
      isHappySunService: _isHappySunService,
    );
    return AccountingProvider.forJobType(
      fromCompany: ref.read(companyRiverpod).providerForJobType(preview),
      createsInvoices: preview.createsInvoices,
      appearsOnCollectionSchedule: preview.appearsOnCollectionSchedule,
    );
  }

  /// The Zoho organisation this job type's company bills through — the item
  /// catalogue differs between Junk & Stuff and Happy Sun.
  String get _zohoOrgId {
    final preview = CustomJobType(
      id: '_preview',
      label: '',
      companyId: _companyId,
      appearsOnCollectionSchedule: _appearsOnCollectionSchedule,
      isHappySunService: _isHappySunService,
    );
    return ZohoOrg.forCompanyId(preview.resolvedCompanyId);
  }

  /// Which items the invoice picker should offer for this job type.
  ///
  /// A shortlist, not a lock: the picker still has a "show all items" escape,
  /// because whoever is raising the invoice knows more about the particular job
  /// than the job type does. Selecting none means no restriction.
  Widget _buildAllowedItemsField() {
    final provider = ref.watch(zohoItemsRiverpod(_zohoOrgId));

    if (provider.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 10),
          Text('Loading items…', style: TextStyle(fontSize: 12)),
        ]),
      );
    }

    if (provider.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Offer these items on the invoice',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            if (_accountingItemCodes.isNotEmpty)
              TextButton(
                onPressed: () =>
                    setState(() => _accountingItemCodes = const []),
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        Text(
          _accountingItemCodes.isEmpty
              ? 'None selected — the picker offers the whole catalogue.'
              : '${_accountingItemCodes.length} selected. Others stay reachable '
                  'behind "show all items".',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final item in provider.items)
              FilterChip(
                label: Text(item.displayName,
                    style: const TextStyle(fontSize: 12)),
                selected: _accountingItemCodes.contains(item.itemId),
                visualDensity: VisualDensity.compact,
                onSelected: (on) => setState(() {
                  final next = List<String>.of(_accountingItemCodes);
                  if (on) {
                    next.add(item.itemId);
                  } else {
                    next.remove(item.itemId);
                  }
                  _accountingItemCodes = next;
                }),
              ),
          ],
        ),
      ],
    );
  }

  /// Company picker, with an explicit "work it out from the flags" option.
  ///
  /// That option matters: selecting a company writes `companyId` and pins it
  /// forever. Leaving it inferred keeps the legacy derivation
  /// (`appearsOnCollectionSchedule` → Junk & Stuff, `isHappySunService` →
  /// Happy Sun, otherwise CLM), which is what lets this ship before every job
  /// type has been assigned by hand.
  Widget _buildCompanyField() {
    final companyProvider = ref.watch(companyRiverpod);
    final companies = companyProvider.companies;

    // Offer inactive companies only when one is already selected, so an old
    // assignment stays visible instead of silently resetting.
    final selectable =
        companies.where((c) => c.active || c.id == _companyId).toList();

    // What the derivation would pick, so the inferred option can say so.
    final inferred = CustomJobType(
      id: '_preview',
      label: '',
      appearsOnCollectionSchedule: _appearsOnCollectionSchedule,
      isHappySunService: _isHappySunService,
    ).resolvedCompanyId;
    final inferredName =
        companyProvider.getById(inferred)?.displayLabel ?? inferred;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _companyId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Belongs to',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem<String>(
              value: '',
              child: Text('Work it out automatically  ·  $inferredName'),
            ),
            ...selectable.map((c) => DropdownMenuItem<String>(
                  value: c.id,
                  child: Text(
                    c.active ? c.displayLabel : '${c.displayLabel} (inactive)',
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
          ],
          onChanged: (id) => setState(() => _companyId = id ?? ''),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _companyId.isEmpty
                ? 'Inferred from the behaviour flags below. Pick a company to '
                    'set it explicitly — needed if this type belongs to a '
                    'company but does not appear on its usual grid.'
                : 'Invoices through '
                    '${companyProvider.getById(_companyId)?.accountingProvider.label ?? 'nothing'}.',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(content: Text('Please enter a label')),
      );
      return;
    }

    final provider = ref.read(jobTypeRiverpod);
    final quantityLabel = _quantityLabelController.text.trim().isEmpty
        ? 'Quantity'
        : _quantityLabelController.text.trim();

    try {
      if (_isAdding) {
        final created = await provider.addJobType(label);
        // Apply any non-default flag choices to the freshly-created doc.
        await provider.updateJobTypeFields(
          created.id,
          isHappySunService: _isHappySunService,
          needsTimeSlot: _needsTimeSlot,
          appearsOnCollectionSchedule: _appearsOnCollectionSchedule,
          tracksQuantity: _tracksQuantity,
          quantityLabel: quantityLabel,
          createsCloudFolder: _createsCloudFolder,
          autoAllocatesToSchedule: _autoAllocatesToSchedule,
          hasTwoStops: _hasTwoStops,
          chargesVat: _chargesVat,
          companyId: _companyId,
          createsInvoices: _createsInvoices,
          accountingItemCode: _accountingItemCode,
          accountingItemCodes: _accountingItemCodes,
          iconName: _iconName,
          colorValue: _colorValue,
          clearIcon: _iconName == null,
          clearColor: _colorValue == null,
        );
      } else if (_editingId != null) {
        await provider.updateJobTypeFields(
          _editingId!,
          label: label,
          isHappySunService: _isHappySunService,
          needsTimeSlot: _needsTimeSlot,
          appearsOnCollectionSchedule: _appearsOnCollectionSchedule,
          tracksQuantity: _tracksQuantity,
          quantityLabel: quantityLabel,
          createsCloudFolder: _createsCloudFolder,
          autoAllocatesToSchedule: _autoAllocatesToSchedule,
          hasTwoStops: _hasTwoStops,
          chargesVat: _chargesVat,
          companyId: _companyId,
          createsInvoices: _createsInvoices,
          accountingItemCode: _accountingItemCode,
          accountingItemCodes: _accountingItemCodes,
          iconName: _iconName,
          colorValue: _colorValue,
          clearIcon: _iconName == null,
          clearColor: _colorValue == null,
        );
      }
      _cancelEdit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Counts how many existing job-list items reference the given type id.
  /// Uses a collection-group query over `jobLists/*/items`. Schedule-grid
  /// jobs are derived from the job list, so this is a reliable signal.
  ///
  /// Returns `null` if the query itself fails (e.g. missing Firestore
  /// index). The caller treats `null` as "unknown" and refuses to delete
  /// — this is deliberate: we don't want to silently drop a type that
  /// might still be referenced.
  Future<int?> _countJobsUsingType(String id) async {
    try {
      final items = await FirebaseFirestore.instance
          .collectionGroup('items')
          .where('jobTypeId', isEqualTo: id)
          .count()
          .get();
      return items.count ?? 0;
    } catch (e) {
      debugPrint('Job-type in-use check failed: $e');
      return null;
    }
  }

  Future<void> _delete(CustomJobType jt) async {
    if (jt.isDefault) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(content: Text('Default job types cannot be deleted.')),
      );
      return;
    }

    // Block deletion if any jobs still reference this type (or if the
    // check couldn't be performed at all).
    final inUse = await _countJobsUsingType(jt.id);
    if (!mounted) return;
    if (inUse == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not verify'),
          content: const Text(
              'Unable to check whether this job type is still in use. '
              'Deletion has been cancelled to avoid breaking existing jobs. '
              'Please try again later.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (inUse > 0) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cannot delete'),
          content: Text(
              '"${jt.label}" is used by $inUse existing job(s). Reassign or remove those jobs before deleting this type.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Job Type'),
        content: Text('Are you sure you want to delete "${jt.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final provider = ref.read(jobTypeRiverpod);
      try {
        await provider.deleteJobType(jt.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showToast(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(jobTypeRiverpod);
    final isEditingAny = _isAdding || _editingId != null;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.work_outline),
          const SizedBox(width: 8),
          const Text('Manage Job Types'),
          const Spacer(),
          if (!isEditingAny)
            IconButton(
              icon: const Icon(Icons.add_circle, color: Colors.green),
              onPressed: _startAdd,
              tooltip: 'Add Job Type',
            ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 600,
        child: isEditingAny
            ? SingleChildScrollView(child: _buildEditCard())
            : ListView.builder(
                itemCount: provider.jobTypes.length,
                itemBuilder: (context, index) =>
                    _buildJobTypeTile(provider.jobTypes[index]),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildJobTypeTile(CustomJobType jt) {
    final flags = <String>[
      if (jt.isHappySunService) 'Happy Sun',
      if (jt.needsTimeSlot) 'Time slot',
      if (jt.appearsOnCollectionSchedule) 'Collection',
      if (!jt.tracksQuantity) 'No quantity',
      if (jt.createsCloudFolder) 'Cloud folder',
      if (jt.autoAllocatesToSchedule) 'Auto-schedule',
      if (jt.hasTwoStops) '2 stops',
      if (jt.chargesVat) 'VAT',
    ];
    final color = jt.colorValue != null ? Color(jt.colorValue!) : null;
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: color ??
            (jt.isDefault ? Colors.grey.shade300 : Colors.blue.shade100),
        child: Icon(
          _iconDataFor(jt.iconName) ??
              (jt.isDefault ? Icons.lock_outline : Icons.work_outline),
          size: 16,
          color: color != null
              ? (color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
              : (jt.isDefault ? Colors.grey.shade700 : Colors.blue.shade700),
        ),
      ),
      title: Text(jt.label),
      subtitle: flags.isEmpty
          ? Text(
              'Id: ${jt.id}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            )
          : Wrap(
              spacing: 4,
              runSpacing: 2,
              children: flags
                  .map((f) => Chip(
                        label: Text(f, style: const TextStyle(fontSize: 10)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ))
                  .toList(),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () => _startEdit(jt),
            tooltip: 'Edit',
          ),
          if (!jt.isDefault)
            IconButton(
              icon: const Icon(Icons.delete, size: 18, color: Colors.red),
              onPressed: () => _delete(jt),
              tooltip: 'Delete',
            ),
        ],
      ),
    );
  }

  Widget _buildEditCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isAdding ? 'Add New Job Type' : 'Edit Job Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Job Type Label',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            Text('Company', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            _buildCompanyField(),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Creates invoices'),
              subtitle: const Text(
                'Turn off for internal work that is never billed, e.g. '
                'returning flyers',
                style: TextStyle(fontSize: 11),
              ),
              value: _createsInvoices,
              onChanged: (v) => setState(() => _createsInvoices = v),
            ),
            // Both businesses keep a price list in their own books, so the
            // picker is per provider. `accountingItemCode` stores whichever
            // identifier those books use — Xero's `Code`, Zoho's `item_id`.
            if (_createsInvoices &&
                _invoiceProvider == AccountingProvider.xero) ...[
              const SizedBox(height: 10),
              XeroItemPicker(
                value: _accountingItemCode,
                label: 'Bills as (Xero item)',
                helperText:
                    'Pre-fills the invoice line with this item\'s description, '
                    'price, account and tax rate. Leave as free text to type '
                    'the line each time.',
                onChanged: (item) =>
                    setState(() => _accountingItemCode = item?.code ?? ''),
              ),
            ],
            if (_createsInvoices &&
                _invoiceProvider == AccountingProvider.zoho) ...[
              const SizedBox(height: 10),
              ZohoItemPicker(
                orgId: _zohoOrgId,
                value: _accountingItemCode,
                label: 'Bills as (Zoho item)',
                helperText:
                    'Pre-fills the invoice line with this item\'s name, '
                    'description and rate. Leave as free text to type the line '
                    'each time.',
                onChanged: (item) =>
                    setState(() => _accountingItemCode = item?.itemId ?? ''),
              ),
              const SizedBox(height: 12),
              _buildAllowedItemsField(),
            ],
            const SizedBox(height: 16),
            Text('Behaviour', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Happy Sun service'),
              subtitle: const Text(
                'Syncs to Happy Sun and shows the tools panel in the dialog',
                style: TextStyle(fontSize: 11),
              ),
              value: _isHappySunService,
              onChanged: (v) => setState(() => _isHappySunService = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Needs time slot'),
              subtitle: const Text(
                'Date picker also asks for a time (HH:mm)',
                style: TextStyle(fontSize: 11),
              ),
              value: _needsTimeSlot,
              onChanged: (v) => setState(() => _needsTimeSlot = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Appears on Collection Schedule'),
              subtitle: const Text(
                'Requires vehicle + trailer, filtered into the collection grid',
                style: TextStyle(fontSize: 11),
              ),
              value: _appearsOnCollectionSchedule,
              onChanged: (v) =>
                  setState(() => _appearsOnCollectionSchedule = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Tracks quantity'),
              subtitle: const Text(
                'Show the quantity field in the add/edit dialog',
                style: TextStyle(fontSize: 11),
              ),
              value: _tracksQuantity,
              onChanged: (v) => setState(() => _tracksQuantity = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Creates cloud folder'),
              subtitle: const Text(
                'Auto-create a Cloud Storage folder per job; folder is renamed/'
                'moved when client name or distribution date changes',
                style: TextStyle(fontSize: 11),
              ),
              value: _createsCloudFolder,
              onChanged: (v) => setState(() => _createsCloudFolder = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-allocates to schedule'),
              subtitle: const Text(
                'Adding a job of this type automatically creates an entry on '
                'the Schedule grid for the same date, ready for a distributor',
                style: TextStyle(fontSize: 11),
              ),
              value: _autoAllocatesToSchedule,
              onChanged: (v) => setState(() => _autoAllocatesToSchedule = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Two-stop job (loading + offloading)'),
              subtitle: const Text(
                'Shows separate Loading address and Offloading address fields '
                'in the job form instead of a single collection address',
                style: TextStyle(fontSize: 11),
              ),
              value: _hasTwoStops,
              onChanged: (v) => setState(() => _hasTwoStops = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Charges VAT'),
              subtitle: const Text(
                'Adds VAT on top of the job amount (amounts are always '
                'entered excl VAT) and on its invoices',
                style: TextStyle(fontSize: 11),
              ),
              value: _chargesVat,
              onChanged: (v) => setState(() => _chargesVat = v),
            ),
            if (_tracksQuantity) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _quantityLabelController,
                decoration: const InputDecoration(
                  labelText: 'Quantity field label',
                  hintText: 'e.g. "Flyers distributed", "30-min time slots"',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Appearance', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildIconPicker()),
                const SizedBox(width: 12),
                Expanded(child: _buildColorPicker()),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _cancelEdit,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _save,
                  child: Text(_isAdding ? 'Add' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconPicker() {
    const choices = <String?, IconData?>{
      null: null,
      'work_outline': Icons.work_outline,
      'local_shipping': Icons.local_shipping,
      'home_repair_service': Icons.home_repair_service,
      'cleaning_services': Icons.cleaning_services,
      'solar_power': Icons.solar_power,
      'delete_outline': Icons.delete_outline,
      'move_to_inbox': Icons.move_to_inbox,
      'description': Icons.description,
      'article': Icons.article,
      'calendar_month': Icons.calendar_month,
      'handyman': Icons.handyman,
      'build': Icons.build,
    };
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Icon',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _iconName,
          isExpanded: true,
          items: choices.entries
              .map((e) => DropdownMenuItem<String?>(
                    value: e.key,
                    child: Row(
                      children: [
                        Icon(e.value ?? Icons.remove, size: 18),
                        const SizedBox(width: 8),
                        Text(e.key ?? '(default)',
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _iconName = v),
        ),
      ),
    );
  }

  Widget _buildColorPicker() {
    const swatches = <Color?>[
      null,
      Colors.red,
      Colors.pink,
      Colors.purple,
      Colors.indigo,
      Colors.blue,
      Colors.cyan,
      Colors.teal,
      Colors.green,
      Colors.lime,
      Colors.amber,
      Colors.orange,
      Colors.brown,
      Colors.grey,
    ];
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Colour',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: swatches.map((c) {
          final selected = _colorValue == c?.toARGB32() ||
              (c == null && _colorValue == null);
          return GestureDetector(
            onTap: () => setState(() => _colorValue = c?.toARGB32()),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c ?? Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.black : Colors.grey.shade400,
                  width: selected ? 2 : 1,
                ),
              ),
              child: c == null
                  ? const Icon(Icons.block, size: 14, color: Colors.grey)
                  : null,
            ),
          );
        }).toList(),
      ),
    );
  }

  static IconData? _iconDataFor(String? name) {
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
        return null;
    }
  }
}
