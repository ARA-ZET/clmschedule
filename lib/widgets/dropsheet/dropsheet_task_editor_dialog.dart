import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../models/job.dart';
import '../../models/job_list_item.dart';
import '../../providers/job_list_provider.dart';
import '../../providers/job_type_provider.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../services/firestore_service.dart';
import '../../services/geocoding_service.dart';
import '../../shareable_maps/services/places_autocomplete_service.dart';
import '../../utils/dropsheet_maps.dart';

/// Type-aware editor for a [DropsheetTask].
///
/// For new tasks, the caller passes in a fresh [DropsheetTask] with the
/// desired [DropsheetTaskType] already set. The editor renders fields
/// appropriate to that type and returns the edited task on SAVE.
class DropsheetTaskEditorDialog extends riverpod.ConsumerStatefulWidget {
  final DropsheetTask initial;

  /// Date of the dropsheet — used by the dropOff/pickUp/collection
  /// pickers to filter their candidate lists.
  final DateTime sheetDate;

  const DropsheetTaskEditorDialog({
    super.key,
    required this.initial,
    required this.sheetDate,
  });

  @override
  riverpod.ConsumerState<DropsheetTaskEditorDialog> createState() =>
      _DropsheetTaskEditorDialogState();
}

class _DropsheetTaskEditorDialogState
    extends riverpod.ConsumerState<DropsheetTaskEditorDialog> {
  late final TextEditingController _job;
  late final TextEditingController _details;
  late final TextEditingController _startTime;
  late final TextEditingController _location;
  late final TextEditingController _contact;
  late final TextEditingController _tel;

  // Type-specific controllers (created lazily; only used when the type
  // matches). Putting them all here keeps state tidy.
  final TextEditingController _loadingAddress = TextEditingController();
  final TextEditingController _offloadAddress = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _collectionAddress = TextEditingController();
  final TextEditingController _serviceTime = TextEditingController();

  bool _isSaving = false;

  late Map<String, dynamic> _typeData;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _job = TextEditingController(
      text: t.job.isNotEmpty ? t.job : DropsheetMaps.defaultJobLabel(t.type),
    );
    _details = TextEditingController(text: t.details);
    _startTime = TextEditingController(text: t.startTime);
    _location = TextEditingController(text: t.location);
    _contact = TextEditingController(text: t.contact);
    _tel = TextEditingController(text: t.tel);
    _typeData = Map<String, dynamic>.from(t.typeData);

    _loadingAddress.text = (_typeData['loadingAddress'] as String?) ?? '';
    _offloadAddress.text = (_typeData['offloadAddress'] as String?) ?? '';
    _notes.text = (_typeData['notes'] as String?) ?? '';
    _collectionAddress.text = (_typeData['address'] as String?) ?? '';
    _serviceTime.text =
        t.serviceTimeMinutes == null ? '' : '${t.serviceTimeMinutes}';
  }

  @override
  void dispose() {
    _job.dispose();
    _details.dispose();
    _startTime.dispose();
    _location.dispose();
    _contact.dispose();
    _tel.dispose();
    _loadingAddress.dispose();
    _offloadAddress.dispose();
    _notes.dispose();
    _collectionAddress.dispose();
    _serviceTime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.initial;
    return AlertDialog(
      title: Row(
        children: [
          Text(_titleFor(t)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(_dynamicTypeLabel(t) ?? t.type.displayName,
                style: const TextStyle(fontSize: 11, color: Colors.blue)),
          ),
          if (t.isMandatory) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Mandatory',
                  style: TextStyle(fontSize: 11, color: Colors.brown)),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._buildFieldsFor(t.type),
              if (!t.isMandatory) ...[
                const SizedBox(height: 12),
                _serviceTimeField(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('SAVE'),
        ),
      ],
    );
  }

  String _titleFor(DropsheetTask t) {
    final dynamicLabel = _dynamicTypeLabel(t);
    if (dynamicLabel != null) {
      return t.job.isEmpty && t.details.isEmpty
          ? 'New $dynamicLabel'
          : 'Edit $dynamicLabel';
    }
    if (t.job.isEmpty && t.details.isEmpty) return 'New ${t.type.displayName}';
    return 'Edit ${t.type.displayName}';
  }

  /// Returns the label of the user-defined dynamic type if this task has one,
  /// otherwise null.
  String? _dynamicTypeLabel(DropsheetTask t) {
    final id = t.typeData['dynamicTypeId'] as String?;
    if (id == null || id.isEmpty) return null;
    final def = ref.read(dropsheetTaskConfigRiverpod).dynamicTypeById(id);
    return def?.label.isNotEmpty == true ? def!.label : 'Custom';
  }

  // ---------------------------------------------------------------------------
  // Field builders per type
  // ---------------------------------------------------------------------------

  List<Widget> _buildFieldsFor(DropsheetTaskType type) {
    // User-defined dynamic types: route to the correct field builder based on
    // the type's configured section (distributor / additional / mandatory / custom).
    final dynamicTypeId = widget.initial.typeData['dynamicTypeId'] as String?;
    if (dynamicTypeId != null && dynamicTypeId.isNotEmpty) {
      final def =
          ref.read(dropsheetTaskConfigRiverpod).dynamicTypeById(dynamicTypeId);
      final label = def?.label.isNotEmpty == true ? def!.label : 'item';
      switch (def?.section ?? DynamicTaskSection.custom) {
        case DynamicTaskSection.distributor:
          return _distributorFields(DropsheetTaskType.custom);
        case DynamicTaskSection.additional:
          return _collectionFields(type, labelOverride: label);
        case DynamicTaskSection.mandatory:
        case DynamicTaskSection.custom:
          return _genericFields();
      }
    }

    switch (type) {
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
      case DropsheetTaskType.custom:
        return _genericFields();
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        return _distributorFields(type);
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
        return _collectionFields(type);
      case DropsheetTaskType.furnitureMove:
        return _furnitureFields();
    }
  }

  List<Widget> _genericFields() {
    return [
      _jobField(),
      const SizedBox(height: 8),
      TextField(
        controller: _details,
        decoration: const InputDecoration(labelText: 'Details'),
      ),
      const SizedBox(height: 8),
      _startAndLocationRow(),
      const SizedBox(height: 8),
      _contactTelRow(),
    ];
  }

  List<Widget> _distributorFields(DropsheetTaskType type) {
    final selectedName = (_typeData['distributorName'] as String?) ?? '';
    final workArea = (_typeData['workArea'] as String?) ?? '';
    final hasCoord = _typeData['lat'] != null && _typeData['lng'] != null;

    return [
      _jobField(),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => _pickDistributorJob(type),
        icon: const Icon(Icons.search),
        label: Text(selectedName.isEmpty
            ? 'Choose distributor for ${widget.sheetDate.toIso8601String().substring(0, 10)}'
            : 'Distributor: $selectedName'),
      ),
      if (workArea.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Work area: $workArea',
              style: const TextStyle(color: Colors.black87)),
        ),
      if (selectedName.isNotEmpty && !hasCoord)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '⚠ This distributor job has no drop-off point set. The Maps link will be unavailable.',
            style: TextStyle(color: Colors.orange, fontSize: 12),
          ),
        ),
      const SizedBox(height: 8),
      TextField(
        controller: _details,
        decoration: const InputDecoration(
          labelText: 'Notes',
          hintText: 'e.g. flyer count, special instructions',
        ),
      ),
      const SizedBox(height: 8),
      _startAndLocationRow(showLocation: false),
      const SizedBox(height: 8),
      _contactTelRow(),
    ];
  }

  List<Widget> _collectionFields(DropsheetTaskType type,
      {String? labelOverride}) {
    final client = (_typeData['client'] as String?) ?? '';
    final typeLabel = labelOverride ??
        switch (type) {
          DropsheetTaskType.jobReturn => 'return',
          DropsheetTaskType.pickFlyers => 'flyers',
          _ => 'collection',
        };
    return [
      _jobField(),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _pickJobListItem,
        icon: const Icon(Icons.search),
        label: Text(client.isEmpty ? 'Choose $typeLabel' : 'Client: $client'),
      ),
      const SizedBox(height: 8),
      _GeoAddressField(
        controller: _collectionAddress,
        label: 'Collection address',
        helperText: '"Western Cape, South Africa" appended automatically',
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _details,
        decoration: const InputDecoration(labelText: 'Notes'),
      ),
      const SizedBox(height: 8),
      _startAndLocationRow(showLocation: false),
      const SizedBox(height: 8),
      _contactTelRow(),
    ];
  }

  List<Widget> _furnitureFields() {
    final client = (_typeData['client'] as String?) ?? '';
    return [
      _jobField(),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _pickJobListItem,
        icon: const Icon(Icons.search),
        label:
            Text(client.isEmpty ? 'Choose furniture move' : 'Client: $client'),
      ),
      const SizedBox(height: 8),
      _GeoAddressField(
        controller: _loadingAddress,
        label: 'Loading address',
        helperText: 'Auto-filled from job list — edit if needed',
      ),
      const SizedBox(height: 8),
      _GeoAddressField(
        controller: _offloadAddress,
        label: 'Offload address',
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _notes,
        maxLines: 3,
        decoration: const InputDecoration(labelText: 'Notes'),
      ),
      const SizedBox(height: 8),
      _startAndLocationRow(showLocation: false),
      const SizedBox(height: 8),
      _contactTelRow(),
    ];
  }

  // ---------------------------------------------------------------------------
  // Reusable field rows
  // ---------------------------------------------------------------------------

  Widget _jobField() => TextField(
        controller: _job,
        decoration: const InputDecoration(labelText: 'Label'),
      );

  Widget _startAndLocationRow({bool showLocation = true}) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _startTime,
            readOnly: true,
            onTap: _pickTime,
            decoration: const InputDecoration(
              labelText: 'Start time',
              hintText: 'HH:mm',
              suffixIcon: Icon(Icons.access_time),
            ),
          ),
        ),
        if (showLocation) ...[
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Location'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _contactTelRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _contact,
            decoration: const InputDecoration(labelText: 'Contact'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _tel,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Tel'),
          ),
        ),
      ],
    );
  }

  Widget _serviceTimeField() {
    final config = ref.watch(dropsheetTaskConfigRiverpod);
    final defaultMinutes = _resolveTypeDefaultServiceMinutes(config);
    final hint = defaultMinutes > 0
        ? 'Default for this type: $defaultMinutes min'
        : 'No default — leave blank to skip';
    return Row(
      children: [
        const Icon(Icons.schedule_outlined, size: 18, color: Colors.black54),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _serviceTime,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Time at stop (min) — override',
              helperText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  /// Resolves the service-time default for *this* task's effective type
  /// (dynamic type → enum config → 0).
  int _resolveTypeDefaultServiceMinutes(DropsheetTaskConfigProvider config) {
    final dynId = widget.initial.typeData['dynamicTypeId'] as String?;
    if (dynId != null && dynId.isNotEmpty) {
      return config.dynamicTypeById(dynId)?.serviceTimeMinutes ?? 0;
    }
    return config.configFor(widget.initial.type).serviceTimeMinutes;
  }

  // ---------------------------------------------------------------------------
  // Pickers
  // ---------------------------------------------------------------------------

  Future<void> _pickDistributorJob(DropsheetTaskType type) async {
    final svc = FirestoreService();
    final jobs = await svc.fetchJobsForDate(widget.sheetDate);
    if (!mounted) return;

    final selected = await showDialog<Job>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
            'Distributors scheduled on ${widget.sheetDate.toIso8601String().substring(0, 10)}'),
        children: jobs.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No distributors scheduled on this date.'),
                ),
              ]
            : (() {
                final distributors = ref.read(scheduleRiverpod).distributors;
                final distById = {for (final d in distributors) d.id: d};
                return jobs
                    .map(
                      (j) => SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, j),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              distById[j.distributorId]?.name ??
                                  j.distributorId,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              j.workingAreas.isEmpty
                                  ? (j.dropOffPoint == null
                                      ? '⚠ no drop-off point'
                                      : 'No work area')
                                  : j.workingAreas.join(', '),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList();
              })(),
      ),
    );

    if (selected == null) return;
    final distributors = ref.read(scheduleRiverpod).distributors;
    final distById = {for (final d in distributors) d.id: d};
    final dist = distById[selected.distributorId];
    final distName = dist?.name ?? selected.distributorId;
    final distPhone = dist?.phone1 ?? '';
    final workArea = selected.workingAreas.join(', ');

    setState(() {
      // Mirror the same typeData shape that _buildDistributorDropOffTask
      // produces during schedule sync so every downstream consumer
      // (day-planner map, dropsheet row, print map) sees consistent data.
      _typeData = {
        'distributorJobId': selected.id,
        'distributorId': selected.distributorId,
        'distributorName': distName,
        'workArea': workArea,
        if (selected.dropOffPoint != null) ...{
          'lat': selected.dropOffPoint!.latitude,
          'lng': selected.dropOffPoint!.longitude,
        },
      };

      // job  → "Drop off: <distributor name>"  (matches sync)
      final defaultLabel = DropsheetMaps.defaultJobLabel(widget.initial.type);
      if (_job.text.trim() == defaultLabel || _job.text.trim().isEmpty) {
        _job.text =
            distName.isEmpty ? defaultLabel : '$defaultLabel: $distName';
      }

      // details → work area  (matches sync)
      if (_details.text.trim().isEmpty) {
        _details.text = workArea;
      }

      // location → work area  (matches sync)
      _location.text = workArea;

      // contact / tel → distributor name + phone  (matches sync)
      if (_contact.text.trim().isEmpty) _contact.text = distName;
      if (_tel.text.trim().isEmpty) _tel.text = distPhone;
    });
  }

  /// Returns job-type IDs whose label matches the given keywords (lower-case).
  Set<String> _jobTypeIdsMatching(
      JobTypeProvider jtProvider, List<String> keywords) {
    return {
      for (final jt in jtProvider.jobTypes)
        if (keywords.any((kw) => jt.label.toLowerCase().contains(kw))) jt.id,
    };
  }

  /// Filters [items] to those relevant for the current task type.
  /// If the task has a `dynamicTypeId` in its typeData, that type's configured
  /// job type IDs are used first. Otherwise the enum-type config is checked,
  /// and finally falls back to keyword-based smart defaults. Configured job
  /// type IDs are treated as the preferred suggestion list; if none match, the
  /// picker shows an empty preferred result instead of unrelated jobs.
  List<JobListItem> _filterItemsForTaskType(
      List<JobListItem> items, JobTypeProvider jtProvider) {
    final type = widget.initial.type;
    final configProvider = ref.read(dropsheetTaskConfigRiverpod);

    // ── Check dynamic (user-defined) type first ───────────────────────
    final dynamicTypeId = widget.initial.typeData['dynamicTypeId'] as String?;
    if (dynamicTypeId != null && dynamicTypeId.isNotEmpty) {
      final dynIds = configProvider.allowedJobTypeIdsForDynamic(dynamicTypeId);
      if (dynIds.isNotEmpty) {
        final filtered =
            items.where((it) => dynIds.contains(it.jobTypeId)).toList();
        return filtered;
      }
      // Dynamic type with no job type config — show all items.
      return items;
    }

    // ── Check configured job type IDs for enum type ──────────────────
    final configuredIds = configProvider.allowedJobTypeIds(type);
    if (configuredIds.isNotEmpty) {
      final filtered =
          items.where((it) => configuredIds.contains(it.jobTypeId)).toList();
      return filtered;
    }

    // ── Keyword-based smart defaults ─────────────────────────────────
    List<JobListItem> filtered;
    switch (type) {
      case DropsheetTaskType.furnitureMove:
        final ids = _jobTypeIdsMatching(jtProvider, ['furniture']);
        ids.add('furnitureMove'); // always include the default id
        filtered = items.where((it) => ids.contains(it.jobTypeId)).toList();
      case DropsheetTaskType.collection:
        final collectionIds = {
          for (final jt in jtProvider.jobTypes)
            if (jtProvider.appearsOnCollectionSchedule(jt.id)) jt.id,
        };
        filtered =
            items.where((it) => collectionIds.contains(it.jobTypeId)).toList();
      case DropsheetTaskType.jobReturn:
        final ids = _jobTypeIdsMatching(jtProvider, ['return']);
        filtered = items.where((it) => ids.contains(it.jobTypeId)).toList();
      case DropsheetTaskType.pickFlyers:
        final ids = _jobTypeIdsMatching(
            jtProvider, ['flyer', 'poster', 'calender', 'distribution']);
        filtered = items.where((it) => ids.contains(it.jobTypeId)).toList();
      default:
        filtered = items;
    }
    // Fall back to all items if the filter matched nothing.
    return filtered.isEmpty ? items : filtered;
  }

  Future<void> _pickJobListItem() async {
    final items = ref.read(jobListRiverpod).allJobListItems;
    final jobTypeProvider = ref.read(jobTypeRiverpod);
    final dayMatches =
        items.where((it) => _sameDay(it.date, widget.sheetDate)).toList();
    final filtered = _filterItemsForTaskType(dayMatches, jobTypeProvider);
    final isFiltered = filtered.length < dayMatches.length;
    if (!mounted) return;

    final selected = await showDialog<JobListItem>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
            'Job list items on ${widget.sheetDate.toIso8601String().substring(0, 10)}'),
        children: filtered.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(dayMatches.isEmpty
                      ? 'No job list items on this date.'
                      : 'No preferred job-list suggestions match this task type on this date.'),
                ),
              ]
            : [
                if (isFiltered)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      'Showing ${filtered.length} of ${dayMatches.length} items',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                  ),
                ...filtered.map(
                  (it) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, it),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.client,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          jobTypeProvider.getJobTypeLabel(it.jobTypeId),
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.blue,
                              fontWeight: FontWeight.w500),
                        ),
                        Text(
                          it.collectionAddress.isEmpty
                              ? '(no collection address)'
                              : it.collectionAddress,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
      ),
    );

    if (selected == null) return;
    final address = _addressForJobListItem(selected);
    final location =
        selected.area.trim().isNotEmpty ? selected.area.trim() : address;
    final contactTel = _contactTelFromClient(selected.client);
    final jobTypeLabel = jobTypeProvider.getJobTypeLabel(selected.jobTypeId);
    final dynamicTypeId = _typeData['dynamicTypeId'] as String? ??
        widget.initial.typeData['dynamicTypeId'] as String?;
    setState(() {
      _typeData = {
        if (dynamicTypeId != null && dynamicTypeId.isNotEmpty)
          'dynamicTypeId': dynamicTypeId,
        'jobListItemId': selected.id,
        'client': selected.client,
        'address': address,
        'jobType': selected.jobTypeId,
        'jobTypeLabel': jobTypeLabel,
        if (selected.area.isNotEmpty) 'area': selected.area,
        if (selected.quantity > 0) 'quantity': selected.quantity,
        if (selected.invoice.isNotEmpty) 'invoice': selected.invoice,
        if (selected.specialInstructions.isNotEmpty)
          'specialInstructions': selected.specialInstructions,
      };
      if (widget.initial.type == DropsheetTaskType.furnitureMove) {
        final area = selected.area.trim();
        final colAddr = selected.collectionAddress.trim();
        final si = selected.specialInstructions.trim();
        // Loading: area → collectionAddress, only if currently empty
        if (_loadingAddress.text.trim().isEmpty) {
          _typeData['loadingAddress'] = address;
          _loadingAddress.text = address;
        }
        // Offload: if area filled loading use collectionAddress,
        // otherwise fall back to specialInstructions, only if currently empty
        if (_offloadAddress.text.trim().isEmpty) {
          final offload =
              (area.isNotEmpty && !_isMapLinkOrUrl(area) && colAddr.isNotEmpty)
                  ? colAddr
                  : si.isNotEmpty
                      ? si
                      : '';
          if (offload.isNotEmpty) {
            _typeData['offloadAddress'] = offload;
            _offloadAddress.text = offload;
          }
        }
      } else {
        _collectionAddress.text = address;
      }

      // Use the task type label if the user hasn't customised it.
      if (_job.text.trim() ==
              DropsheetMaps.defaultJobLabel(widget.initial.type) ||
          _job.text.trim().isEmpty) {
        final clientName = selected.client.trim();
        final dynamicId = widget.initial.typeData['dynamicTypeId'] as String?;
        final typeLabel = dynamicId != null
            ? (ref
                    .read(dropsheetTaskConfigRiverpod)
                    .dynamicTypeById(dynamicId)
                    ?.label ??
                jobTypeLabel)
            : switch (widget.initial.type) {
                DropsheetTaskType.collection => 'Collection',
                DropsheetTaskType.jobReturn => 'Return',
                DropsheetTaskType.pickFlyers => 'Pick flyers',
                DropsheetTaskType.furnitureMove => 'Furniture move',
                _ => jobTypeLabel,
              };
        _job.text = clientName.isEmpty ? typeLabel : '$typeLabel: $clientName';
      }

      // Details come straight from joblist special instructions.
      // Preserve the raw text verbatim — no trim/split — so multi-line
      // notes and leading/trailing punctuation are kept intact.
      if (_details.text.trim().isEmpty) {
        _details.text = selected.specialInstructions;
      }

      if (jobTypeProvider.needsTimeSlot(selected.jobTypeId)) {
        _startTime.text = _formatTime(selected.date);
      }

      // Location comes from the JobList area field.
      _location.text = location;
      _contact.text = contactTel.contact;
      _tel.text = contactTel.tel;
    });
  }

  String _addressForJobListItem(JobListItem item) {
    final area = item.area.trim();
    if (area.isNotEmpty && !_isMapLinkOrUrl(area)) return area;
    final collectionAddress = item.collectionAddress.trim();
    if (collectionAddress.isNotEmpty) return collectionAddress;
    return area;
  }

  _ContactTel _contactTelFromClient(String client) {
    final trimmed = client.trim();
    if (trimmed.isEmpty) return const _ContactTel('', '');

    final phoneMatch =
        RegExp(r'(?:\+?27|0)[0-9\s()\-]{8,}$').firstMatch(trimmed);
    if (phoneMatch == null) return _ContactTel(trimmed, '');

    final tel = phoneMatch.group(0)!.trim();
    final contact = trimmed.substring(0, phoneMatch.start).trim();
    return _ContactTel(contact.isEmpty ? trimmed : contact, tel);
  }

  String _formatTime(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

  bool _isMapLinkOrUrl(String text) {
    final value = text.trim().toLowerCase();
    if (value.isEmpty) return false;
    return value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.contains('clm-maps.web.app/map/') ||
        value.contains('google.com/maps') ||
        value.contains('maps.app.goo.gl') ||
        value.contains('goo.gl/maps');
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pickTime() async {
    final parts = _startTime.text.split(':');
    int h = 7, m = 0;
    if (parts.length == 2) {
      h = int.tryParse(parts[0]) ?? 7;
      m = int.tryParse(parts[1]) ?? 0;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: h, minute: m),
    );
    if (picked != null) {
      _startTime.text =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    }
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  void _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final t = widget.initial;

    // Roll up type-specific fields back into typeData on save.
    final newTypeData = Map<String, dynamic>.from(_typeData);
    String? sourceJobListItemId = t.sourceJobListItemId;
    String location = _location.text.trim();
    final dynamicTypeId = newTypeData['dynamicTypeId'] as String?;

    // Tracks which address fields changed (so we only re-geocode when needed).
    final geocoder = GeocodingService();
    final addressesToGeocode = <String, String>{};

    switch (t.type) {
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
        final addr = _collectionAddress.text.trim();
        newTypeData['address'] = addr;
        sourceJobListItemId = newTypeData['jobListItemId'] as String?;
        if (_addressChanged(
            previous: (t.typeData['address'] as String?) ?? '',
            current: addr,
            currentLat: newTypeData['lat'],
            currentLng: newTypeData['lng'])) {
          addressesToGeocode['address'] = addr;
          newTypeData.remove('lat');
          newTypeData.remove('lng');
        }
        break;
      case DropsheetTaskType.furnitureMove:
        final loading = _loadingAddress.text.trim();
        final offload = _offloadAddress.text.trim();
        newTypeData['loadingAddress'] = loading;
        newTypeData['offloadAddress'] = offload;
        newTypeData['notes'] = _notes.text.trim();
        if (_addressChanged(
            previous: (t.typeData['loadingAddress'] as String?) ?? '',
            current: loading,
            currentLat: newTypeData['loadingLat'],
            currentLng: newTypeData['loadingLng'])) {
          addressesToGeocode['loadingAddress'] = loading;
          newTypeData.remove('loadingLat');
          newTypeData.remove('loadingLng');
        }
        if (_addressChanged(
            previous: (t.typeData['offloadAddress'] as String?) ?? '',
            current: offload,
            currentLat: newTypeData['offloadLat'],
            currentLng: newTypeData['offloadLng'])) {
          addressesToGeocode['offloadAddress'] = offload;
          newTypeData.remove('offloadLat');
          newTypeData.remove('offloadLng');
        }
        break;
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
      case DropsheetTaskType.custom:
        if (dynamicTypeId != null && dynamicTypeId.isNotEmpty) {
          final addr = _collectionAddress.text.trim();
          newTypeData['address'] = addr;
          sourceJobListItemId = newTypeData['jobListItemId'] as String?;
          if (_addressChanged(
              previous: (t.typeData['address'] as String?) ?? '',
              current: addr,
              currentLat: newTypeData['lat'],
              currentLng: newTypeData['lng'])) {
            addressesToGeocode['address'] = addr;
            newTypeData.remove('lat');
            newTypeData.remove('lng');
          }
        }
        break;
    }

    // Eager geocode any changed addresses. Best-effort: failures just
    // leave lat/lng off the task and the user can re-edit later.
    for (final entry in addressesToGeocode.entries) {
      final raw = entry.value;
      if (raw.isEmpty) continue;
      final query = raw.toLowerCase().contains('south africa')
          ? raw
          : '$raw, Western Cape, South Africa';
      debugPrint('[DropsheetEditor] geocoding ${entry.key}="$query"');
      final res = await geocoder.geocodeAddress(query);
      if (res != null) {
        switch (entry.key) {
          case 'address':
            newTypeData['lat'] = res['lat'];
            newTypeData['lng'] = res['lng'];
            break;
          case 'loadingAddress':
            newTypeData['loadingLat'] = res['lat'];
            newTypeData['loadingLng'] = res['lng'];
            break;
          case 'offloadAddress':
            newTypeData['offloadLat'] = res['lat'];
            newTypeData['offloadLng'] = res['lng'];
            break;
        }
      } else {
        debugPrint('[DropsheetEditor] geocode FAILED for ${entry.key}');
      }
    }

    // Parse service-time override (blank/invalid → null → fall back to type default).
    final rawMinutes = _serviceTime.text.trim();
    final parsedMinutes = int.tryParse(rawMinutes);
    final clearedMinutes = rawMinutes.isEmpty;

    final updated = t.copyWith(
      job: _job.text.trim(),
      details: _details.text.trim(),
      startTime: _startTime.text.trim(),
      location: location,
      contact: _contact.text.trim(),
      tel: _tel.text.trim(),
      typeData: newTypeData,
      sourceJobListItemId: sourceJobListItemId,
      serviceTimeMinutes: parsedMinutes,
      clearServiceTimeMinutes: clearedMinutes,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    Navigator.pop(context, updated);
  }

  bool _addressChanged({
    required String previous,
    required String current,
    required dynamic currentLat,
    required dynamic currentLng,
  }) {
    if (current.isEmpty) return false;
    if (previous.trim() != current) return true;
    // Same address but no coords cached → geocode now.
    return currentLat == null || currentLng == null;
  }
}

/// Picker dialog used when the user taps "Add task" — they pick a type
/// before the editor opens. Returns a [TaskTypeSelection].
class DropsheetTaskTypePicker extends riverpod.ConsumerWidget {
  const DropsheetTaskTypePicker({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final taskConfig = ref.watch(dropsheetTaskConfigRiverpod);
    const addable = [
      DropsheetTaskType.dropOff,
      DropsheetTaskType.pickUp,
      DropsheetTaskType.collection,
      DropsheetTaskType.jobReturn,
      DropsheetTaskType.pickFlyers,
      DropsheetTaskType.furnitureMove,
      DropsheetTaskType.custom,
    ];
    return SimpleDialog(
      title: const Text('Add task'),
      children: [
        // Built-in enum types
        ...addable.map(
          (t) => SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, TaskTypeSelection.enumType(t)),
            child: Row(
              children: [
                Icon(_iconFor(t), size: 20),
                const SizedBox(width: 12),
                Text(taskConfig.effectiveLabelFor(t)),
              ],
            ),
          ),
        ),
        // User-defined dynamic types
        if (taskConfig.customTypes.isNotEmpty) ...[
          const Divider(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Custom types',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black45),
            ),
          ),
          ...taskConfig.customTypes.map(
            (def) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context,
                  TaskTypeSelection.dynamic(DropsheetTaskType.custom, def)),
              child: Row(
                children: [
                  const Icon(Icons.add_task, size: 20),
                  const SizedBox(width: 12),
                  Text(def.label.isNotEmpty ? def.label : '(unnamed)'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  IconData _iconFor(DropsheetTaskType t) {
    switch (t) {
      case DropsheetTaskType.dropOff:
        return Icons.local_shipping_outlined;
      case DropsheetTaskType.pickUp:
        return Icons.move_to_inbox_outlined;
      case DropsheetTaskType.collection:
        return Icons.inventory_2_outlined;
      case DropsheetTaskType.jobReturn:
        return Icons.assignment_return_outlined;
      case DropsheetTaskType.pickFlyers:
        return Icons.newspaper_outlined;
      case DropsheetTaskType.furnitureMove:
        return Icons.chair_outlined;
      case DropsheetTaskType.custom:
        return Icons.note_alt_outlined;
      case DropsheetTaskType.inspect:
        return Icons.search;
      case DropsheetTaskType.pack:
        return Icons.backpack_outlined;
      case DropsheetTaskType.leave:
        return Icons.directions_car_outlined;
      case DropsheetTaskType.arrive:
        return Icons.home_outlined;
    }
  }
}

/// An address text field that shows Google Places autocomplete suggestions.
/// Uses [PlacesAutocompleteService] which handles CORS on web via JS interop.
class _GeoAddressField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? helperText;

  const _GeoAddressField({
    required this.controller,
    required this.label,
    this.helperText,
  });

  @override
  State<_GeoAddressField> createState() => _GeoAddressFieldState();
}

class _GeoAddressFieldState extends State<_GeoAddressField> {
  late final FocusNode _focusNode;
  final _places = PlacesAutocompleteService();

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<Iterable<PlaceSuggestion>> _optionsBuilder(
      TextEditingValue value) async {
    final query = value.text.trim();
    if (query.length < 3) return const [];
    // Debounce: wait 350 ms then bail if the field text has changed.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return const [];
    if (query != widget.controller.text.trim()) return const [];
    return _places.getSuggestions(query);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<PlaceSuggestion>(
      textEditingController: widget.controller,
      focusNode: _focusNode,
      optionsBuilder: _optionsBuilder,
      displayStringForOption: (s) => s.description,
      onSelected: (suggestion) {
        widget.controller.text = suggestion.description;
        _focusNode.unfocus();
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: widget.helperText,
            suffixIcon: const Icon(Icons.location_searching, size: 18),
          ),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 460),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final s = options.elementAt(index);
                  return InkWell(
                    onTap: () => onSelected(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on_outlined,
                              size: 16, color: Colors.black54),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.mainText.isNotEmpty
                                      ? s.mainText
                                      : s.description,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                if (s.secondaryText.isNotEmpty)
                                  Text(
                                    s.secondaryText,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.black45),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ContactTel {
  final String contact;
  final String tel;

  const _ContactTel(this.contact, this.tel);
}
