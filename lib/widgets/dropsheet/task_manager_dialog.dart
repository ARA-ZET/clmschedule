import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../providers/job_type_provider.dart';
import '../../services/geocoding_service.dart';

/// Dialog that lets the user configure each dropsheet task type:
///   - Custom label (overrides the default display name)
///   - Which job-list job types are suggested when picking a job
///   - Add / edit / delete user-defined task types
class TaskManagerDialog extends riverpod.ConsumerStatefulWidget {
  const TaskManagerDialog({super.key});

  @override
  riverpod.ConsumerState<TaskManagerDialog> createState() =>
      _TaskManagerDialogState();
}

class _TaskManagerDialogState
    extends riverpod.ConsumerState<TaskManagerDialog> {
  // Working copy for enum-based types
  late Map<DropsheetTaskType, _WorkingConfig> _working;
  // Working copy for user-defined types
  late List<_DynamicWorking> _dynamicTypes;
  // Working copy for global depot/start-of-day settings.
  late _DepotWorking _depot;
  // Collapsed section keys: 'depot', 'mandatory', 'distributor', 'additional', 'custom'
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    final provider = ref.read(dropsheetTaskConfigRiverpod);
    _working = {
      for (final t in configurableDropsheetTaskTypes)
        t: _WorkingConfig.from(provider.configFor(t)),
    };
    _dynamicTypes =
        provider.customTypes.map((d) => _DynamicWorking.from(d)).toList();
    _depot = _DepotWorking.from(provider.depot);
  }

  Future<void> _save() async {
    // Best-effort geocode of the depot address if it changed and we don't
    // already have coordinates.
    final depotAddr = _depot.address.trim();
    if (depotAddr.isNotEmpty && (_depot.lat == null || _depot.lng == null)) {
      final query = depotAddr.toLowerCase().contains('south africa')
          ? depotAddr
          : '$depotAddr, Western Cape, South Africa';
      debugPrint('[TaskManager] geocoding depot="$query"');
      final res = await GeocodingService().geocodeAddress(query);
      if (res != null) {
        _depot = _depot.copyWith(lat: res['lat'], lng: res['lng']);
      } else {
        debugPrint('[TaskManager] depot geocode FAILED');
      }
    }

    final updatedConfigs = <DropsheetTaskType, DropsheetTaskTypeConfig>{};
    for (final entry in _working.entries) {
      updatedConfigs[entry.key] = entry.value.toConfig(entry.key);
    }
    final updatedDynamic = _dynamicTypes.map((d) => d.toDef()).toList();
    await ref.read(dropsheetTaskConfigRiverpod).saveAll(
          configs: updatedConfigs,
          customTypes: updatedDynamic,
          depot: _depot.toConfig(),
        );
    if (mounted) Navigator.pop(context);
  }

  void _addDynamicType(
      [DynamicTaskSection section = DynamicTaskSection.custom]) {
    final newItem = _DynamicWorking(
      id: 'dyn_${DateTime.now().millisecondsSinceEpoch}',
      label: '',
      selectedJobTypeIds: [],
      section: section,
      isNew: true,
    );
    setState(() {
      // Insert before the first existing item of the same section so it
      // appears at the top of its group, visible immediately.
      final firstIdx = _dynamicTypes.indexWhere((d) => d.section == section);
      if (firstIdx >= 0) {
        _dynamicTypes.insert(firstIdx, newItem);
      } else {
        _dynamicTypes.add(newItem);
      }
      // Auto-expand the target section so the new form is visible.
      _collapsed.remove(section.storageKey);
    });
  }

  void _removeDynamicType(int index) {
    setState(() => _dynamicTypes.removeAt(index));
  }

  void _toggleSection(String key) {
    setState(() {
      if (_collapsed.contains(key)) {
        _collapsed.remove(key);
      } else {
        _collapsed.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final jobTypeProvider = ref.watch(jobTypeRiverpod);
    final allJobTypes = jobTypeProvider.jobTypes;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Header ───────────────────────────────────────────────
            Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Task Manager',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Configure each task type: set a custom label and choose which job types '
                'from the job list are suggested when picking a job. '
                'Leave job types empty to use smart defaults.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            const Divider(height: 1),
            // ─── Scrollable body ──────────────────────────────────────
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // ── Depot / start-of-day ─────────────────────
                  _GroupHeader(
                    label: 'Office · Start of day',
                    subtitle: 'Default depot address and departure time.',
                    expanded: !_collapsed.contains('depot'),
                    onToggle: () => _toggleSection('depot'),
                  ),
                  if (!_collapsed.contains('depot'))
                    _DepotRow(
                      working: _depot,
                      onChanged: (updated) => setState(() => _depot = updated),
                    ),
                  const Divider(height: 24),
                  // ── Mandatory tasks ───────────────────────────
                  _GroupHeader(
                    label: 'Mandatory tasks',
                    subtitle: 'Pinned at the top of every driver section.',
                    expanded: !_collapsed.contains('mandatory'),
                    onToggle: () => _toggleSection('mandatory'),
                    onAddCustom: () =>
                        _addDynamicType(DynamicTaskSection.mandatory),
                  ),
                  if (!_collapsed.contains('mandatory')) ...[
                    for (final type in [
                      DropsheetTaskType.inspect,
                      DropsheetTaskType.pack,
                      DropsheetTaskType.leave,
                      DropsheetTaskType.arrive,
                    ])
                      _TaskTypeRow(
                        type: type,
                        working: _working[type]!,
                        allJobTypes: allJobTypes,
                        onChanged: (updated) =>
                            setState(() => _working[type] = updated),
                      ),
                    for (var i = 0; i < _dynamicTypes.length; i++)
                      if (_dynamicTypes[i].section ==
                          DynamicTaskSection.mandatory)
                        _DynamicTypeRow(
                          working: _dynamicTypes[i],
                          allJobTypes: allJobTypes,
                          onChanged: (updated) =>
                              setState(() => _dynamicTypes[i] = updated),
                          onDelete: () => _removeDynamicType(i),
                        ),
                  ],
                  const Divider(height: 24),
                  // ── Distributor tasks ─────────────────────────
                  _GroupHeader(
                    label: 'Distributor tasks',
                    subtitle: 'Auto-populated from the daily schedule.',
                    expanded: !_collapsed.contains('distributor'),
                    onToggle: () => _toggleSection('distributor'),
                    onAddCustom: () =>
                        _addDynamicType(DynamicTaskSection.distributor),
                  ),
                  if (!_collapsed.contains('distributor')) ...[
                    for (final type in [
                      DropsheetTaskType.dropOff,
                      DropsheetTaskType.pickUp,
                    ])
                      _TaskTypeRow(
                        type: type,
                        working: _working[type]!,
                        allJobTypes: allJobTypes,
                        onChanged: (updated) =>
                            setState(() => _working[type] = updated),
                      ),
                    for (var i = 0; i < _dynamicTypes.length; i++)
                      if (_dynamicTypes[i].section ==
                          DynamicTaskSection.distributor)
                        _DynamicTypeRow(
                          working: _dynamicTypes[i],
                          allJobTypes: allJobTypes,
                          onChanged: (updated) =>
                              setState(() => _dynamicTypes[i] = updated),
                          onDelete: () => _removeDynamicType(i),
                        ),
                  ],
                  const Divider(height: 24),
                  // ── Additional tasks ──────────────────────────
                  _GroupHeader(
                    label: 'Additional tasks',
                    subtitle: 'Manually added by the dispatcher.',
                    expanded: !_collapsed.contains('additional'),
                    onToggle: () => _toggleSection('additional'),
                    onAddCustom: () =>
                        _addDynamicType(DynamicTaskSection.additional),
                  ),
                  if (!_collapsed.contains('additional')) ...[
                    for (final type in [
                      DropsheetTaskType.collection,
                      DropsheetTaskType.jobReturn,
                      DropsheetTaskType.pickFlyers,
                      DropsheetTaskType.furnitureMove,
                      DropsheetTaskType.custom,
                    ])
                      _TaskTypeRow(
                        type: type,
                        working: _working[type]!,
                        allJobTypes: allJobTypes,
                        onChanged: (updated) =>
                            setState(() => _working[type] = updated),
                      ),
                    for (var i = 0; i < _dynamicTypes.length; i++)
                      if (_dynamicTypes[i].section ==
                          DynamicTaskSection.additional)
                        _DynamicTypeRow(
                          working: _dynamicTypes[i],
                          allJobTypes: allJobTypes,
                          onChanged: (updated) =>
                              setState(() => _dynamicTypes[i] = updated),
                          onDelete: () => _removeDynamicType(i),
                        ),
                  ],
                  const Divider(height: 24),
                  // ── Custom (user-defined, free-form) types ────
                  _GroupHeader(
                    label: 'Custom task types',
                    subtitle: 'Free-form — all fields entered manually.',
                    count: _dynamicTypes
                        .where((d) => d.section == DynamicTaskSection.custom)
                        .length,
                    expanded: !_collapsed.contains('custom'),
                    onToggle: () => _toggleSection('custom'),
                    onAddCustom: () =>
                        _addDynamicType(DynamicTaskSection.custom),
                  ),
                  if (!_collapsed.contains('custom')) ...[
                    for (var i = 0; i < _dynamicTypes.length; i++)
                      if (_dynamicTypes[i].section == DynamicTaskSection.custom)
                        _DynamicTypeRow(
                          working: _dynamicTypes[i],
                          allJobTypes: allJobTypes,
                          onChanged: (updated) =>
                              setState(() => _dynamicTypes[i] = updated),
                          onDelete: () => _removeDynamicType(i),
                        ),
                    if (!_dynamicTypes
                        .any((d) => d.section == DynamicTaskSection.custom))
                      const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        child: Text(
                          'No custom types yet. Tap "+ Add" to create one.',
                          style: TextStyle(fontSize: 12, color: Colors.black45),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            // ─── Footer ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Row for a built-in enum task type
// ─────────────────────────────────────────────────────────────────────────────

class _TaskTypeRow extends StatefulWidget {
  final DropsheetTaskType type;
  final _WorkingConfig working;
  final List<dynamic> allJobTypes;
  final ValueChanged<_WorkingConfig> onChanged;

  const _TaskTypeRow({
    required this.type,
    required this.working,
    required this.allJobTypes,
    required this.onChanged,
  });

  @override
  State<_TaskTypeRow> createState() => _TaskTypeRowState();
}

class _TaskTypeRowState extends State<_TaskTypeRow> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _serviceCtrl;
  late final TextEditingController _defaultDetailsCtrl;
  late final TextEditingController _defaultStartTimeCtrl;
  late final TextEditingController _defaultContactCtrl;
  late final TextEditingController _defaultTelCtrl;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.working.customLabel);
    _serviceCtrl = TextEditingController(
        text: widget.working.serviceTimeMinutes == 0
            ? ''
            : '${widget.working.serviceTimeMinutes}');
    _defaultDetailsCtrl =
        TextEditingController(text: widget.working.defaultDetails);
    _defaultStartTimeCtrl =
        TextEditingController(text: widget.working.defaultStartTime);
    _defaultContactCtrl =
        TextEditingController(text: widget.working.defaultContact);
    _defaultTelCtrl = TextEditingController(text: widget.working.defaultTel);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _serviceCtrl.dispose();
    _defaultDetailsCtrl.dispose();
    _defaultStartTimeCtrl.dispose();
    _defaultContactCtrl.dispose();
    _defaultTelCtrl.dispose();
    super.dispose();
  }

  void _toggleJobType(String id) {
    final current = Set<String>.from(widget.working.selectedJobTypeIds);
    if (current.contains(id)) {
      current.remove(id);
    } else {
      current.add(id);
    }
    widget.onChanged(widget.working.copyWith(
      selectedJobTypeIds: current.toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final defaultName = widget.type.displayName;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: Colors.black12,
        child: Icon(_iconFor(widget.type), size: 15, color: Colors.black54),
      ),
      title: Text(
        widget.working.customLabel.trim().isNotEmpty
            ? widget.working.customLabel.trim()
            : defaultName,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: widget.working.selectedJobTypeIds.isEmpty
          ? const Text('Smart defaults · tap to configure',
              style: TextStyle(fontSize: 11, color: Colors.black45))
          : Text(
              '${widget.working.selectedJobTypeIds.length} job type(s) configured',
              style: const TextStyle(fontSize: 11, color: Colors.blue),
            ),
      children: [
        TextField(
          controller: _labelCtrl,
          decoration: InputDecoration(
            labelText: 'Custom label',
            hintText: defaultName,
            helperText: 'Leave blank to use "$defaultName"',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) =>
              widget.onChanged(widget.working.copyWith(customLabel: v)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serviceCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: widget.type == DropsheetTaskType.leave
                ? 'Preparation time at office (min)'
                : widget.type == DropsheetTaskType.arrive
                    ? 'Wrap-up time at office (min)'
                    : 'Estimated time at stop (min)',
            helperText: 'Used by route optimisation. 0 = no default.',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) => widget.onChanged(widget.working
              .copyWith(serviceTimeMinutes: int.tryParse(v.trim()) ?? 0)),
        ),
        if (widget.type == DropsheetTaskType.leave) ..._leaveInfo(),
        if (widget.type == DropsheetTaskType.arrive) ..._arriveInfo(),
        if (_showsJobList) ...[
          const SizedBox(height: 12),
          _JobTypeChips(
            allJobTypes: widget.allJobTypes,
            selected: widget.working.selectedJobTypeIds,
            onToggle: _toggleJobType,
            onClear: () => widget
                .onChanged(widget.working.copyWith(selectedJobTypeIds: [])),
          ),
        ],
        const SizedBox(height: 12),
        _MarkerFieldPickers(
          primary: widget.working.markerPrimaryField,
          secondary: widget.working.markerSecondaryField,
          onPrimaryChanged: (v) =>
              widget.onChanged(widget.working.copyWith(markerPrimaryField: v)),
          onSecondaryChanged: (v) => widget
              .onChanged(widget.working.copyWith(markerSecondaryField: v)),
        ),
        if (_showsDefaultFields) ...[
          const SizedBox(height: 16),
          _DefaultFieldsSection(
            detailsCtrl: _defaultDetailsCtrl,
            startTimeCtrl: _defaultStartTimeCtrl,
            contactCtrl: _defaultContactCtrl,
            telCtrl: _defaultTelCtrl,
            onDetailsChanged: (v) =>
                widget.onChanged(widget.working.copyWith(defaultDetails: v)),
            onStartTimeChanged: (v) =>
                widget.onChanged(widget.working.copyWith(defaultStartTime: v)),
            onContactChanged: (v) =>
                widget.onChanged(widget.working.copyWith(defaultContact: v)),
            onTelChanged: (v) =>
                widget.onChanged(widget.working.copyWith(defaultTel: v)),
          ),
        ],
      ],
    );
  }

  /// Types that expose free-text default fields.
  bool get _showsDefaultFields => !const {
        DropsheetTaskType.dropOff,
        DropsheetTaskType.pickUp,
      }.contains(widget.type);
  bool get _showsJobList => !const {
        DropsheetTaskType.inspect,
        DropsheetTaskType.pack,
        DropsheetTaskType.leave,
        DropsheetTaskType.arrive,
        DropsheetTaskType.dropOff,
        DropsheetTaskType.pickUp,
      }.contains(widget.type);

  List<Widget> _leaveInfo() => [
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFE3F2FD),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF90CAF9)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 16, color: Color(0xFF1565C0)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The Leave task always departs from the Office address '
                  'configured above. Each driver\'s departure time is set '
                  'directly on the dropsheet and is used as the route start '
                  'time in the Day Planner.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF1565C0)),
                ),
              ),
            ],
          ),
        ),
      ];

  List<Widget> _arriveInfo() => [
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFE3F2FD),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF90CAF9)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 16, color: Color(0xFF1565C0)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The Arrive task always returns to the Office address '
                  'configured above and is pinned to the bottom of every '
                  'driver section. It cannot be deleted or reordered.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF1565C0)),
                ),
              ),
            ],
          ),
        ),
      ];

  IconData _iconFor(DropsheetTaskType t) {
    switch (t) {
      case DropsheetTaskType.inspect:
        return Icons.search_outlined;
      case DropsheetTaskType.pack:
        return Icons.inventory_outlined;
      case DropsheetTaskType.leave:
        return Icons.logout_outlined;
      case DropsheetTaskType.arrive:
        return Icons.home_outlined;
      case DropsheetTaskType.dropOff:
        return Icons.local_shipping_outlined;
      case DropsheetTaskType.pickUp:
        return Icons.upload_outlined;
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
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Row for a user-defined (dynamic) task type
// ─────────────────────────────────────────────────────────────────────────────

class _DynamicTypeRow extends StatefulWidget {
  final _DynamicWorking working;
  final List<dynamic> allJobTypes;
  final ValueChanged<_DynamicWorking> onChanged;
  final VoidCallback onDelete;

  const _DynamicTypeRow({
    required this.working,
    required this.allJobTypes,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_DynamicTypeRow> createState() => _DynamicTypeRowState();
}

class _DynamicTypeRowState extends State<_DynamicTypeRow> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _serviceCtrl;
  late final TextEditingController _defaultDetailsCtrl;
  late final TextEditingController _defaultStartTimeCtrl;
  late final TextEditingController _defaultContactCtrl;
  late final TextEditingController _defaultTelCtrl;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.working.label);
    _serviceCtrl = TextEditingController(
        text: widget.working.serviceTimeMinutes == 0
            ? ''
            : '${widget.working.serviceTimeMinutes}');
    _defaultDetailsCtrl =
        TextEditingController(text: widget.working.defaultDetails);
    _defaultStartTimeCtrl =
        TextEditingController(text: widget.working.defaultStartTime);
    _defaultContactCtrl =
        TextEditingController(text: widget.working.defaultContact);
    _defaultTelCtrl = TextEditingController(text: widget.working.defaultTel);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _serviceCtrl.dispose();
    _defaultDetailsCtrl.dispose();
    _defaultStartTimeCtrl.dispose();
    _defaultContactCtrl.dispose();
    _defaultTelCtrl.dispose();
    super.dispose();
  }

  void _toggleJobType(String id) {
    final current = Set<String>.from(widget.working.selectedJobTypeIds);
    if (current.contains(id)) {
      current.remove(id);
    } else {
      current.add(id);
    }
    widget.onChanged(widget.working.copyWith(
      selectedJobTypeIds: current.toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.working.label.trim();
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      initiallyExpanded: widget.working.isNew,
      leading: const CircleAvatar(
        radius: 14,
        backgroundColor: Color(0xFFE3F2FD),
        child: Icon(Icons.add_task, size: 15, color: Colors.blue),
      ),
      title: Text(
        label.isNotEmpty ? label : '(unnamed)',
        style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: label.isEmpty ? Colors.black38 : null),
      ),
      subtitle: Text(
          '${widget.working.section.displayName}'
          '${widget.working.selectedJobTypeIds.isEmpty ? '' : ' · ${widget.working.selectedJobTypeIds.length} job type(s)'}',
          style: const TextStyle(fontSize: 11, color: Colors.black45)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
            tooltip: 'Delete type',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete type?'),
                  content: Text(
                      'Remove "${label.isNotEmpty ? label : 'this type'}" from the task manager?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirmed == true) widget.onDelete();
            },
          ),
          const Icon(Icons.expand_more),
        ],
      ),
      children: [
        TextField(
          controller: _labelCtrl,
          decoration: const InputDecoration(
            labelText: 'Task type name',
            hintText: 'e.g. Delivery, Setup, Inspection',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => widget.onChanged(widget.working.copyWith(label: v)),
        ),
        const SizedBox(height: 12),
        // ── Section picker ─────────────────────────────────────────────
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Section',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in DynamicTaskSection.values)
                  ChoiceChip(
                    label: Text(s.displayName,
                        style: const TextStyle(fontSize: 12)),
                    selected: widget.working.section == s,
                    onSelected: (_) =>
                        widget.onChanged(widget.working.copyWith(section: s)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.working.section.description,
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serviceCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Estimated time at stop (min)',
            helperText: 'Used by route optimisation. 0 = no default.',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => widget.onChanged(widget.working
              .copyWith(serviceTimeMinutes: int.tryParse(v.trim()) ?? 0)),
        ),
        if (widget.working.section == DynamicTaskSection.additional) ...[
          const SizedBox(height: 12),
          _JobTypeChips(
            allJobTypes: widget.allJobTypes,
            selected: widget.working.selectedJobTypeIds,
            onToggle: _toggleJobType,
            onClear: () => widget
                .onChanged(widget.working.copyWith(selectedJobTypeIds: [])),
          ),
        ],
        const SizedBox(height: 12),
        _MarkerFieldPickers(
          primary: widget.working.markerPrimaryField,
          secondary: widget.working.markerSecondaryField,
          onPrimaryChanged: (v) =>
              widget.onChanged(widget.working.copyWith(markerPrimaryField: v)),
          onSecondaryChanged: (v) => widget
              .onChanged(widget.working.copyWith(markerSecondaryField: v)),
        ),
        const SizedBox(height: 16),
        _DefaultFieldsSection(
          detailsCtrl: _defaultDetailsCtrl,
          startTimeCtrl: _defaultStartTimeCtrl,
          contactCtrl: _defaultContactCtrl,
          telCtrl: _defaultTelCtrl,
          onDetailsChanged: (v) =>
              widget.onChanged(widget.working.copyWith(defaultDetails: v)),
          onStartTimeChanged: (v) =>
              widget.onChanged(widget.working.copyWith(defaultStartTime: v)),
          onContactChanged: (v) =>
              widget.onChanged(widget.working.copyWith(defaultContact: v)),
          onTelChanged: (v) =>
              widget.onChanged(widget.working.copyWith(defaultTel: v)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared default-field-values editor (used by both built-in and dynamic rows)
// ─────────────────────────────────────────────────────────────────────────────

class _DefaultFieldsSection extends StatelessWidget {
  final TextEditingController detailsCtrl;
  final TextEditingController startTimeCtrl;
  final TextEditingController contactCtrl;
  final TextEditingController telCtrl;
  final ValueChanged<String> onDetailsChanged;
  final ValueChanged<String> onStartTimeChanged;
  final ValueChanged<String> onContactChanged;
  final ValueChanged<String> onTelChanged;

  const _DefaultFieldsSection({
    required this.detailsCtrl,
    required this.startTimeCtrl,
    required this.contactCtrl,
    required this.telCtrl,
    required this.onDetailsChanged,
    required this.onStartTimeChanged,
    required this.onContactChanged,
    required this.onTelChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Default field values',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Pre-filled when creating a new task of this type. Leave blank for no default.',
          style: TextStyle(fontSize: 11, color: Colors.black45),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: detailsCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Default notes / details',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: onDetailsChanged,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: startTimeCtrl,
          decoration: const InputDecoration(
            labelText: 'Default start time',
            hintText: 'HH:mm',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: onStartTimeChanged,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: contactCtrl,
                decoration: const InputDecoration(
                  labelText: 'Default contact',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: onContactChanged,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: telCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Default tel',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: onTelChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared job-type chip picker
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Marker label field pickers (shared between built-in and dynamic rows)
// ─────────────────────────────────────────────────────────────────────────────

class _MarkerFieldPickers extends StatelessWidget {
  final MarkerLabelField primary;
  final MarkerLabelField secondary;
  final ValueChanged<MarkerLabelField> onPrimaryChanged;
  final ValueChanged<MarkerLabelField> onSecondaryChanged;

  const _MarkerFieldPickers({
    required this.primary,
    required this.secondary,
    required this.onPrimaryChanged,
    required this.onSecondaryChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = MarkerLabelField.values
        .map((f) => DropdownMenuItem(value: f, child: Text(f.displayName)))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Map marker label',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<MarkerLabelField>(
                initialValue: primary,
                decoration: const InputDecoration(
                  labelText: 'Primary (title)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: items,
                onChanged: (v) {
                  if (v != null) onPrimaryChanged(v);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<MarkerLabelField>(
                initialValue: secondary,
                decoration: const InputDecoration(
                  labelText: 'Secondary (subtitle)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: items,
                onChanged: (v) {
                  if (v != null) onSecondaryChanged(v);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _JobTypeChips extends StatelessWidget {
  final List<dynamic> allJobTypes;
  final List<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  const _JobTypeChips({
    required this.allJobTypes,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Suggested job types from job list',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final jt in allJobTypes)
              FilterChip(
                label: Text(jt.label, style: const TextStyle(fontSize: 12)),
                selected: selected.contains(jt.id),
                onSelected: (_) => onToggle(jt.id),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            if (selected.isNotEmpty)
              ActionChip(
                label: const Text('Clear all',
                    style: TextStyle(fontSize: 11, color: Colors.red)),
                avatar: const Icon(Icons.clear, size: 14, color: Colors.red),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
              ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local working state
// ─────────────────────────────────────────────────────────────────────────────

class _WorkingConfig {
  final String customLabel;
  final List<String> selectedJobTypeIds;
  final int serviceTimeMinutes;
  final MarkerLabelField markerPrimaryField;
  final MarkerLabelField markerSecondaryField;
  final String defaultDetails;
  final String defaultStartTime;
  final String defaultContact;
  final String defaultTel;

  const _WorkingConfig({
    required this.customLabel,
    required this.selectedJobTypeIds,
    this.serviceTimeMinutes = 0,
    this.markerPrimaryField = MarkerLabelField.taskLabel,
    this.markerSecondaryField = MarkerLabelField.none,
    this.defaultDetails = '',
    this.defaultStartTime = '',
    this.defaultContact = '',
    this.defaultTel = '',
  });

  factory _WorkingConfig.from(DropsheetTaskTypeConfig config) => _WorkingConfig(
        customLabel: config.customLabel,
        selectedJobTypeIds: List.from(config.allowedJobTypeIds),
        serviceTimeMinutes: config.serviceTimeMinutes,
        markerPrimaryField: config.markerPrimaryField,
        markerSecondaryField: config.markerSecondaryField,
        defaultDetails: config.defaultDetails,
        defaultStartTime: config.defaultStartTime,
        defaultContact: config.defaultContact,
        defaultTel: config.defaultTel,
      );

  _WorkingConfig copyWith({
    String? customLabel,
    List<String>? selectedJobTypeIds,
    int? serviceTimeMinutes,
    MarkerLabelField? markerPrimaryField,
    MarkerLabelField? markerSecondaryField,
    String? defaultDetails,
    String? defaultStartTime,
    String? defaultContact,
    String? defaultTel,
  }) =>
      _WorkingConfig(
        customLabel: customLabel ?? this.customLabel,
        selectedJobTypeIds: selectedJobTypeIds ?? this.selectedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes ?? this.serviceTimeMinutes,
        markerPrimaryField: markerPrimaryField ?? this.markerPrimaryField,
        markerSecondaryField: markerSecondaryField ?? this.markerSecondaryField,
        defaultDetails: defaultDetails ?? this.defaultDetails,
        defaultStartTime: defaultStartTime ?? this.defaultStartTime,
        defaultContact: defaultContact ?? this.defaultContact,
        defaultTel: defaultTel ?? this.defaultTel,
      );

  DropsheetTaskTypeConfig toConfig(DropsheetTaskType type) =>
      DropsheetTaskTypeConfig(
        type: type,
        customLabel: customLabel,
        allowedJobTypeIds: selectedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes,
        markerPrimaryField: markerPrimaryField,
        markerSecondaryField: markerSecondaryField,
        defaultDetails: defaultDetails,
        defaultStartTime: defaultStartTime,
        defaultContact: defaultContact,
        defaultTel: defaultTel,
      );
}

class _DynamicWorking {
  final String id;
  final String label;
  final List<String> selectedJobTypeIds;
  final int serviceTimeMinutes;
  final bool isNew;
  final DynamicTaskSection section;
  final MarkerLabelField markerPrimaryField;
  final MarkerLabelField markerSecondaryField;
  final String defaultDetails;
  final String defaultStartTime;
  final String defaultContact;
  final String defaultTel;

  const _DynamicWorking({
    required this.id,
    required this.label,
    required this.selectedJobTypeIds,
    this.serviceTimeMinutes = 0,
    this.isNew = false,
    this.section = DynamicTaskSection.custom,
    this.markerPrimaryField = MarkerLabelField.taskLabel,
    this.markerSecondaryField = MarkerLabelField.none,
    this.defaultDetails = '',
    this.defaultStartTime = '',
    this.defaultContact = '',
    this.defaultTel = '',
  });

  factory _DynamicWorking.from(DynamicTaskTypeDef def) => _DynamicWorking(
        id: def.id,
        label: def.label,
        selectedJobTypeIds: List.from(def.allowedJobTypeIds),
        serviceTimeMinutes: def.serviceTimeMinutes,
        section: def.section,
        markerPrimaryField: def.markerPrimaryField,
        markerSecondaryField: def.markerSecondaryField,
        defaultDetails: def.defaultDetails,
        defaultStartTime: def.defaultStartTime,
        defaultContact: def.defaultContact,
        defaultTel: def.defaultTel,
      );

  _DynamicWorking copyWith({
    String? label,
    List<String>? selectedJobTypeIds,
    int? serviceTimeMinutes,
    DynamicTaskSection? section,
    MarkerLabelField? markerPrimaryField,
    MarkerLabelField? markerSecondaryField,
    String? defaultDetails,
    String? defaultStartTime,
    String? defaultContact,
    String? defaultTel,
  }) =>
      _DynamicWorking(
        id: id,
        label: label ?? this.label,
        selectedJobTypeIds: selectedJobTypeIds ?? this.selectedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes ?? this.serviceTimeMinutes,
        section: section ?? this.section,
        markerPrimaryField: markerPrimaryField ?? this.markerPrimaryField,
        markerSecondaryField: markerSecondaryField ?? this.markerSecondaryField,
        defaultDetails: defaultDetails ?? this.defaultDetails,
        defaultStartTime: defaultStartTime ?? this.defaultStartTime,
        defaultContact: defaultContact ?? this.defaultContact,
        defaultTel: defaultTel ?? this.defaultTel,
        isNew: false,
      );

  DynamicTaskTypeDef toDef() => DynamicTaskTypeDef(
        id: id,
        label: label.trim(),
        allowedJobTypeIds: selectedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes,
        section: section,
        markerPrimaryField: markerPrimaryField,
        markerSecondaryField: markerSecondaryField,
        defaultDetails: defaultDetails,
        defaultStartTime: defaultStartTime,
        defaultContact: defaultContact,
        defaultTel: defaultTel,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Depot / start-of-day (global)
// ─────────────────────────────────────────────────────────────────────────────

class _DepotWorking {
  final String address;
  final double? lat;
  final double? lng;
  final String startTime;

  const _DepotWorking({
    required this.address,
    required this.lat,
    required this.lng,
    required this.startTime,
  });

  factory _DepotWorking.from(DepotConfig d) => _DepotWorking(
        address: d.address,
        lat: d.lat,
        lng: d.lng,
        startTime: d.startTime,
      );

  _DepotWorking copyWith({
    String? address,
    double? lat,
    double? lng,
    String? startTime,
    bool clearCoords = false,
  }) =>
      _DepotWorking(
        address: address ?? this.address,
        lat: clearCoords ? null : (lat ?? this.lat),
        lng: clearCoords ? null : (lng ?? this.lng),
        startTime: startTime ?? this.startTime,
      );

  DepotConfig toConfig() => DepotConfig(
        address: address.trim(),
        lat: lat,
        lng: lng,
        startTime: startTime,
      );
}

class _DepotRow extends StatefulWidget {
  final _DepotWorking working;
  final ValueChanged<_DepotWorking> onChanged;
  const _DepotRow({required this.working, required this.onChanged});

  @override
  State<_DepotRow> createState() => _DepotRowState();
}

class _DepotRowState extends State<_DepotRow> {
  late final TextEditingController _addr;
  late final TextEditingController _start;

  @override
  void initState() {
    super.initState();
    _addr = TextEditingController(text: widget.working.address);
    _start = TextEditingController(text: widget.working.startTime);
  }

  @override
  void dispose() {
    _addr.dispose();
    _start.dispose();
    super.dispose();
  }

  Future<void> _pickStartTime() async {
    final parts = widget.working.startTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.elementAt(0)) ?? 7,
      minute: int.tryParse(parts.elementAtOrNull(1) ?? '30') ?? 30,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    _start.text = '$hh:$mm';
    widget.onChanged(widget.working.copyWith(startTime: '$hh:$mm'));
  }

  @override
  Widget build(BuildContext context) {
    final hasCoords = widget.working.lat != null && widget.working.lng != null;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      initiallyExpanded: !hasCoords,
      leading: const CircleAvatar(
        radius: 14,
        backgroundColor: Color(0xFFFFF3E0),
        child:
            Icon(Icons.warehouse_outlined, size: 15, color: Color(0xFFEF6C00)),
      ),
      title: const Text(
        'Office · start of day',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        '${widget.working.address.trim().isEmpty ? '(no address)' : widget.working.address} · ${widget.working.startTime}'
        '${hasCoords ? '' : ' · ⚠ not geocoded yet'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: hasCoords ? Colors.black54 : Colors.deepOrange,
        ),
      ),
      children: [
        TextField(
          controller: _addr,
          decoration: const InputDecoration(
            labelText: 'Office address',
            helperText:
                'Used as the start point for every driver\'s optimised route.',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => widget.onChanged(
              widget.working.copyWith(address: v, clearCoords: true)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _start,
                readOnly: true,
                onTap: _pickStartTime,
                decoration: const InputDecoration(
                  labelText: 'Start time',
                  helperText: 'Drivers leave the office at this time.',
                  isDense: true,
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.access_time, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Icon(
                    hasCoords ? Icons.check_circle : Icons.location_searching,
                    size: 16,
                    color: hasCoords ? Colors.green : Colors.deepOrange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasCoords ? 'Geocoded ✓' : 'Will geocode on save',
                      style: TextStyle(
                        fontSize: 11,
                        color: hasCoords ? Colors.green : Colors.deepOrange,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Group header used inside the task type list
// ─────────────────────────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  final String subtitle;
  final int? count;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onAddCustom;

  const _GroupHeader({
    required this.label,
    required this.subtitle,
    required this.expanded,
    required this.onToggle,
    this.count,
    this.onAddCustom,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.0 : -0.25,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.expand_more,
                  size: 18, color: Colors.black54),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      if (count != null && count! > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('$count',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.blue)),
                        ),
                      ],
                    ],
                  ),
                  if (expanded)
                    Text(
                      subtitle,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black45),
                    ),
                ],
              ),
            ),
            if (onAddCustom != null && expanded)
              TextButton.icon(
                onPressed: onAddCustom,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4)),
              ),
          ],
        ),
      ),
    );
  }
}
