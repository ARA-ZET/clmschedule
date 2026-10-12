// shareable_maps/widgets/regular_client_allocation_panel.dart
//
// Side panel of a regular client's map: the numbered distributor slots, their
// man days (one bucket per day), which areas each slot works on each day, and
// what is still unallocated. Every change is written straight to the plan via
// RegularClientMapAdapter.applyPlan, which also recolours the map.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/regular_client.dart';
import '../adapters/regular_client_map_adapter.dart';
import '../providers/shareable_map_provider.dart';
import 'map_overlay.dart';

class RegularClientAllocationPanel extends riverpod.ConsumerStatefulWidget {
  final RegularClientMapAdapter adapter;

  const RegularClientAllocationPanel({super.key, required this.adapter});

  @override
  riverpod.ConsumerState<RegularClientAllocationPanel> createState() =>
      _RegularClientAllocationPanelState();
}

class _RegularClientAllocationPanelState
    extends riverpod.ConsumerState<RegularClientAllocationPanel> {
  bool _collapsed = false;
  bool _busy = false;
  final Set<String> _selected = {};

  RegularClientMapAdapter get _adapter => widget.adapter;

  Future<void> _apply(RegularClient next) async {
    setState(() => _busy = true);
    try {
      await _adapter.applyPlan(next, ref.read(shareableMapRiverpod));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save the plan: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _focus(RegularClientArea area) =>
      ref.read(shareableMapRiverpod).focusOnPolygon(area.layerId, area.index);

  Future<void> _renameSlot(RegularClientSlot slot) async {
    final controller = TextEditingController(text: slot.label);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename slot'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == slot.label) return;
    await _apply(_adapter.client.replaceSlot(slot.copyWith(label: trimmed)));
  }

  Future<void> _removeSlot(RegularClientSlot slot) async {
    if (slot.polygonIds.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Remove ${slot.label}?'),
          content: Text('Its ${slot.polygonIds.length} area(s) go back to '
              'unallocated unless another slot also holds them.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _apply(_adapter.client.removeSlot(slot.id));
  }

  Future<void> _setManDays(RegularClientSlot slot, int days) async {
    if (days < 1) return;
    final current = slot.days;
    if (days < current.length &&
        current.skip(days).any((d) => d.polygonIds.isNotEmpty)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Drop the last day?'),
          content: const Text(
              'Its areas will be removed from this slot.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Drop'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _apply(_adapter.client.replaceSlot(slot.copyWith(days: [
      for (var i = 0; i < days; i++)
        i < current.length ? current[i] : const RegularClientDay(),
    ])));
  }

  Future<void> _assignSelected(String slotId, int dayIndex) async {
    final ids = _selected.toList();
    _selected.clear();
    await _apply(_adapter.client.addPolygons(slotId, dayIndex, ids));
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the adapter swaps in a restyled map.
    ref.watch(shareableMapRiverpod);
    final client = _adapter.client;
    final areas = _adapter.areas;
    final byId = {for (final a in areas) a.id: a};
    final unallocated = [
      for (final id in client.unallocatedIds(byId.keys)) byId[id]!,
    ];
    final missing = client.missingIds(byId.keys);
    _selected.removeWhere((id) => !byId.containsKey(id));

    return Positioned(
      right: 0,
      top: 0,
      bottom: _collapsed ? null : 0,
      child: MapOverlay(
        child: Container(
          width: 360,
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 8,
                offset: const Offset(-2, 0),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: _collapsed ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(client, areas.length, unallocated.length),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (!_collapsed)
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      if (missing.isNotEmpty) _missingBanner(client, missing),
                      for (final slot in client.slots) _slotCard(slot, byId),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _apply(client.copyWith(
                                  slots: [...client.slots, client.newSlot()])),
                          icon: const Icon(Icons.person_add_alt_1, size: 18),
                          label: const Text('Add distributor slot'),
                        ),
                      ),
                      const Divider(height: 1),
                      _unallocatedSection(client, unallocated),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(RegularClient client, int areaCount, int unallocated) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      color: Colors.indigo.shade50,
      child: Row(
        children: [
          const Icon(Icons.groups_outlined, color: Colors.indigo),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                    overflow: TextOverflow.ellipsis),
                Text(
                  '${client.slots.length} distributor'
                  '${client.slots.length == 1 ? '' : 's'} · '
                  '${client.totalManDays} man days · '
                  '$unallocated of $areaCount unallocated',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _collapsed ? 'Expand' : 'Collapse',
            icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less),
            onPressed: () => setState(() => _collapsed = !_collapsed),
          ),
        ],
      ),
    );
  }

  Widget _missingBanner(RegularClient client, Set<String> missing) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.orange.shade800, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${missing.length} allocated area(s) are no longer on the map '
              'and will be skipped.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _apply(client.copyWith(slots: [
                      for (final s in client.slots)
                        s.copyWith(days: [
                          for (final d in s.days)
                            d.copyWith(polygonIds: [
                              for (final id in d.polygonIds)
                                if (!missing.contains(id)) id,
                            ]),
                        ]),
                    ])),
            child: const Text('Clean up'),
          ),
        ],
      ),
    );
  }

  Widget _slotCard(
      RegularClientSlot slot, Map<String, RegularClientArea> byId) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: slot.color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 7, backgroundColor: slot.color),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: _busy ? null : () => _renameSlot(slot),
                    child: Text(slot.label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'One man day fewer',
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: _busy || slot.manDays <= 1
                      ? null
                      : () => _setManDays(slot, slot.manDays - 1),
                ),
                Text('${slot.manDays} day${slot.manDays == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'One man day more',
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  onPressed:
                      _busy ? null : () => _setManDays(slot, slot.manDays + 1),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove slot',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _busy ? null : () => _removeSlot(slot),
                ),
              ],
            ),
            for (var d = 0; d < slot.days.length; d++)
              _dayRow(slot, d, byId),
          ],
        ),
      ),
    );
  }

  Widget _dayRow(
      RegularClientSlot slot, int dayIndex, Map<String, RegularClientArea> byId) {
    final ids = slot.days[dayIndex].polygonIds;
    final present = [for (final id in ids) if (byId[id] != null) byId[id]!];
    final letterboxes =
        present.fold<int>(0, (t, a) => t + a.polygon.letterBoxEstimate);
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Day ${dayIndex + 1} · ${present.length} area'
            '${present.length == 1 ? '' : 's'}'
            '${letterboxes > 0 ? ' · $letterboxes letterboxes' : ''}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          if (present.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Tap an area on the map, or tick unallocated areas below.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              for (final a in present)
                InputChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(a.name, style: const TextStyle(fontSize: 11)),
                  onPressed: () => _focus(a),
                  onDeleted: _busy
                      ? null
                      : () => _apply(_adapter.client
                          .togglePolygon(slot.id, dayIndex, a.id)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unallocatedSection(
      RegularClient client, List<RegularClientArea> unallocated) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                  radius: 7,
                  backgroundColor: RegularClientMapAdapter.unallocatedColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Unallocated (${unallocated.length})',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (_selected.isNotEmpty && client.slots.isNotEmpty)
                PopupMenuButton<(String, int)>(
                  tooltip: 'Assign ticked areas',
                  onSelected: (v) => _assignSelected(v.$1, v.$2),
                  itemBuilder: (_) => [
                    for (final s in client.slots)
                      for (var d = 0; d < s.days.length; d++)
                        PopupMenuItem(
                          value: (s.id, d),
                          child: Row(children: [
                            CircleAvatar(radius: 6, backgroundColor: s.color),
                            const SizedBox(width: 8),
                            Text('${s.label} · Day ${d + 1}'),
                          ]),
                        ),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.assignment_ind, size: 16),
                    label: Text('Assign ${_selected.length}…'),
                  ),
                ),
            ],
          ),
          if (client.slots.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Add a distributor slot to start allocating.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          if (unallocated.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Every area is allocated.',
                  style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
            ),
          for (final a in unallocated)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(a.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(a.id);
                } else {
                  _selected.remove(a.id);
                }
              }),
              title: Text(a.name, style: const TextStyle(fontSize: 13)),
              subtitle: a.polygon.letterBoxEstimate > 0
                  ? Text('${a.polygon.letterBoxEstimate} letterboxes',
                      style: const TextStyle(fontSize: 11))
                  : null,
              secondary: IconButton(
                tooltip: 'Show on map',
                icon: const Icon(Icons.center_focus_strong, size: 18),
                onPressed: () => _focus(a),
              ),
            ),
        ],
      ),
    );
  }
}

/// The allocation section of a regular-client polygon's info window: who
/// holds it, and a chip per slot-day to toggle it.
class RegularClientInfoSection extends riverpod.ConsumerStatefulWidget {
  final RegularClientMapAdapter adapter;
  final String elementId;

  const RegularClientInfoSection({
    super.key,
    required this.adapter,
    required this.elementId,
  });

  @override
  riverpod.ConsumerState<RegularClientInfoSection> createState() =>
      _RegularClientInfoSectionState();
}

class _RegularClientInfoSectionState
    extends riverpod.ConsumerState<RegularClientInfoSection> {
  bool _busy = false;

  Future<void> _apply(RegularClient next) async {
    setState(() => _busy = true);
    try {
      await widget.adapter.applyPlan(next, ref.read(shareableMapRiverpod));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(shareableMapRiverpod);
    final area = widget.adapter.areaForElement(widget.elementId);
    if (area == null) return const SizedBox.shrink();
    final client = widget.adapter.client;
    final holdings = client.holdingsOf(area.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            holdings.isEmpty
                ? 'Not allocated'
                : 'Allocated to ${holdings.map((h) => h.label).join(', ')}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: holdings.isEmpty
                  ? Colors.grey.shade700
                  : holdings.first.slot.color,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in client.slots)
                for (var d = 0; d < s.days.length; d++)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    avatar: CircleAvatar(radius: 5, backgroundColor: s.color),
                    label: Text(
                        s.days.length == 1 ? s.label : '${s.label} · D${d + 1}',
                        style: const TextStyle(fontSize: 11)),
                    selected: s.days[d].polygonIds.contains(area.id),
                    selectedColor: s.color.withValues(alpha: 0.2),
                    onSelected: _busy
                        ? null
                        : (_) => _apply(client.togglePolygon(s.id, d, area.id)),
                  ),
              ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: const Icon(Icons.add, size: 14),
                label: const Text('New slot', style: TextStyle(fontSize: 11)),
                onPressed: _busy
                    ? null
                    : () {
                        final slot = client.newSlot();
                        _apply(client.copyWith(slots: [
                          ...client.slots,
                          slot.copyWith(days: [
                            RegularClientDay(polygonIds: [area.id]),
                          ]),
                        ]));
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
