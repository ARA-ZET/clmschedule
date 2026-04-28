import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/dropsheet_task.dart';
import '../../models/job.dart';
import '../../models/job_list_item.dart';
import '../../providers/job_list_provider.dart';
import '../../services/firestore_service.dart';
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
            child: Text(t.type.displayName,
                style: const TextStyle(fontSize: 11, color: Colors.blue)),
          ),
          if (t.isMandatory) ...[
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            children: _buildFieldsFor(t.type),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(onPressed: _save, child: const Text('SAVE')),
      ],
    );
  }

  String _titleFor(DropsheetTask t) {
    if (t.job.isEmpty && t.details.isEmpty) return 'New ${t.type.displayName}';
    return 'Edit ${t.type.displayName}';
  }

  // ---------------------------------------------------------------------------
  // Field builders per type
  // ---------------------------------------------------------------------------

  List<Widget> _buildFieldsFor(DropsheetTaskType type) {
    switch (type) {
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.custom:
        return _genericFields();
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        return _distributorFields(type);
      case DropsheetTaskType.collection:
        return _collectionFields();
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
    final selectedName =
        (_typeData['distributorName'] as String?) ?? '';
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

  List<Widget> _collectionFields() {
    final client = (_typeData['client'] as String?) ?? '';
    return [
      _jobField(),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _pickJobListItem,
        icon: const Icon(Icons.search),
        label: Text(client.isEmpty
            ? 'Choose collection from job list'
            : 'Client: $client'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _collectionAddress,
        decoration: const InputDecoration(
          labelText: 'Collection address',
          helperText: '"Western Cape, South Africa" appended automatically',
        ),
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
    return [
      _jobField(),
      const SizedBox(height: 8),
      TextField(
        controller: _loadingAddress,
        decoration: const InputDecoration(labelText: 'Loading address'),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _offloadAddress,
        decoration: const InputDecoration(labelText: 'Offload address'),
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
            : jobs
                .map(
                  (j) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, j),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          j.workingAreas.isEmpty
                              ? '(no work area)'
                              : j.workingAreas.join(', '),
                          style:
                              const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          j.dropOffPoint == null
                              ? 'distributorId: ${j.distributorId}  ⚠ no drop-off point'
                              : 'distributorId: ${j.distributorId}  •  ${j.dropOffPoint!.latitude.toStringAsFixed(5)}, ${j.dropOffPoint!.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
      ),
    );

    if (selected == null) return;
    setState(() {
      _typeData = {
        'distributorJobId': selected.id,
        'distributorName':
            selected.distributorId, // best we have without a Distributor lookup
        'workArea': selected.workingAreas.join(', '),
        if (selected.dropOffPoint != null) ...{
          'lat': selected.dropOffPoint!.latitude,
          'lng': selected.dropOffPoint!.longitude,
        },
      };
      // Mirror onto the legacy `location` field for sort/filter compatibility.
      _location.text = selected.workingAreas.join(', ');

      // If the user hasn't customised the row label, use "<Type>: <area>".
      final defaultLabel =
          DropsheetMaps.defaultJobLabel(widget.initial.type);
      if (_job.text.trim() == defaultLabel || _job.text.trim().isEmpty) {
        final wa = selected.workingAreas.join(', ');
        _job.text = wa.isEmpty ? defaultLabel : '$defaultLabel: $wa';
      }

      // Pre-fill notes with the area name if details is still blank — the
      // driver can extend it (flyer count etc.) before saving.
      if (_details.text.trim().isEmpty &&
          selected.workingAreas.isNotEmpty) {
        _details.text = selected.workingAreas.join(', ');
      }
    });
  }

  Future<void> _pickJobListItem() async {
    final items = ref.read(jobListRiverpod).allJobListItems;
    final dayMatches = items.where((it) => _sameDay(it.date, widget.sheetDate)).toList();
    if (!mounted) return;

    final selected = await showDialog<JobListItem>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
            'Job list items on ${widget.sheetDate.toIso8601String().substring(0, 10)}'),
        children: dayMatches.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No job list items on this date.'),
                ),
              ]
            : dayMatches
                .map(
                  (it) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, it),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.client,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
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
                )
                .toList(),
      ),
    );

    if (selected == null) return;
    setState(() {
      _typeData = {
        'jobListItemId': selected.id,
        'client': selected.client,
        'address': selected.collectionAddress,
        'jobType': selected.jobTypeId,
        if (selected.area.isNotEmpty) 'area': selected.area,
        if (selected.quantity > 0) 'quantity': selected.quantity,
        if (selected.invoice.isNotEmpty) 'invoice': selected.invoice,
        if (selected.specialInstructions.isNotEmpty)
          'specialInstructions': selected.specialInstructions,
      };
      _collectionAddress.text = selected.collectionAddress;

      // Use the client name as the row's `Label` if the user hasn't
      // customised it (still equal to the type's default).
      if (_job.text.trim() ==
              DropsheetMaps.defaultJobLabel(widget.initial.type) ||
          _job.text.trim().isEmpty) {
        _job.text = selected.client.isNotEmpty
            ? selected.client
            : DropsheetMaps.defaultJobLabel(widget.initial.type);
      }

      // Build a useful Details string from job-type + qty + special
      // instructions. Don't overwrite if the user already typed details.
      if (_details.text.trim().isEmpty) {
        final parts = <String>[
          if (selected.jobTypeId.isNotEmpty) selected.jobTypeId,
          if (selected.quantity > 0) '${selected.quantity}x',
          if (selected.area.isNotEmpty) selected.area,
        ];
        final summary = parts.join(' • ');
        _details.text = [
          if (summary.isNotEmpty) summary,
          if (selected.specialInstructions.isNotEmpty)
            selected.specialInstructions,
        ].join('\n');
      }

      // Mirror onto legacy `location` so search/sort still work.
      _location.text = selected.collectionAddress;
    });
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

  void _save() {
    final t = widget.initial;

    // Roll up type-specific fields back into typeData on save.
    final newTypeData = Map<String, dynamic>.from(_typeData);
    String? sourceJobListItemId = t.sourceJobListItemId;
    String location = _location.text.trim();

    switch (t.type) {
      case DropsheetTaskType.collection:
        newTypeData['address'] = _collectionAddress.text.trim();
        sourceJobListItemId = newTypeData['jobListItemId'] as String?;
        break;
      case DropsheetTaskType.furnitureMove:
        newTypeData['loadingAddress'] = _loadingAddress.text.trim();
        newTypeData['offloadAddress'] = _offloadAddress.text.trim();
        newTypeData['notes'] = _notes.text.trim();
        break;
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.custom:
        break;
    }

    final updated = t.copyWith(
      job: _job.text.trim(),
      details: _details.text.trim(),
      startTime: _startTime.text.trim(),
      location: location,
      contact: _contact.text.trim(),
      tel: _tel.text.trim(),
      typeData: newTypeData,
      sourceJobListItemId: sourceJobListItemId,
    );
    Navigator.pop(context, updated);
  }
}

/// Picker dialog used when the user taps "Add task" — they pick a type
/// before the editor opens. Returns the picked [DropsheetTaskType].
class DropsheetTaskTypePicker extends StatelessWidget {
  const DropsheetTaskTypePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final addable = [
      DropsheetTaskType.dropOff,
      DropsheetTaskType.pickUp,
      DropsheetTaskType.collection,
      DropsheetTaskType.furnitureMove,
      DropsheetTaskType.custom,
    ];
    return SimpleDialog(
      title: const Text('Add task'),
      children: addable
          .map(
            (t) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Row(
                children: [
                  Icon(_iconFor(t), size: 20),
                  const SizedBox(width: 12),
                  Text(t.displayName),
                ],
              ),
            ),
          )
          .toList(),
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
    }
  }
}
