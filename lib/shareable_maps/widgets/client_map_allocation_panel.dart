// shareable_maps/widgets/client_map_allocation_panel.dart
//
// "Schedule allocation" view of a client map: a left panel listing each
// distributor who carries the map's Job List client on the schedule, their
// days and the areas they work each day, plus what is still unallocated —
// and, in the polygon info window, a chip per distributor-day to give the
// area to. The map is coloured per distributor (grey = unallocated) by
// ScheduleAllocationController, at draw time only.
//
// Areas are linked (`JobAreaLink`), never copied; a copied area is converted
// to a link when it is moved. See ClientMapAllocationService for the rules
// and FirestoreService.applyAreaLinkChanges for the write.
import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/job.dart';
import '../../services/client_map_allocation_service.dart';
import '../../utils/schedule_time.dart';
import '../providers/schedule_allocation_controller.dart';
import '../providers/shareable_map_provider.dart';
import 'map_overlay.dart';

// ── Shared flows (panel + info window) ───────────────────────────────────

/// "3 areas · 2 points", leaving out a kind there is none of.
String _what(int areas, int points) => [
      if (areas > 0 || points == 0) '$areas area${areas == 1 ? '' : 's'}',
      if (points > 0) '$points point${points == 1 ? '' : 's'}',
    ].join(' · ');

/// Whether [h] holds a point rather than an area — from the map, else from
/// what the job itself holds.
bool _holdsPoint(AreaHolding h, Map<String?, AllocationArea> byId) =>
    byId[h.polygonId]?.isPoint ??
    (h.copy ?? h.link?.frozen)?.isPoint ??
    false;

String _whatHeld(
    Iterable<AreaHolding> held, Map<String?, AllocationArea> byId) {
  final points = held.where((h) => _holdsPoint(h, byId)).length;
  return _what(held.length - points, points);
}

/// Runs [body], then reports its message (green) or its error (red).
Future<void> _guard(
    BuildContext context, Future<String?> Function() body) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final message = await body();
    if (message != null) {
      messenger?.showToast(
          SnackBar(content: Text(message), backgroundColor: Colors.green));
    }
  } catch (e) {
    messenger?.showToast(SnackBar(
      content: Text('Allocation failed: $e'),
      backgroundColor: Colors.red.shade800,
    ));
  }
}

/// Give the areas under [keys] to [target], asking move-or-split when
/// someone else currently holds one of them.
Future<void> _allocate(BuildContext context, ScheduleAllocationController c,
    Set<String> keys, Job target) {
  return _guard(context, () async {
    final polygons = await c.polygonsWithIds(keys);
    if (polygons == null) throw 'The map could not be saved';
    final others = c.otherHolders(polygons, target);
    var move = false;
    if (others.isNotEmpty) {
      if (!context.mounted) return null;
      final choice = await _askMoveOrSplit(context, others);
      if (choice == null) return null;
      move = choice;
    }
    await c.allocate(polygons, target, move: move);
    final points = polygons.where((p) => p.isPoint).length;
    return '${_what(polygons.length - points, points)} '
        '${move ? 'moved' : 'allocated'} to '
        '${c.jobLabel(target)}';
  });
}

Future<void> _move(BuildContext context, ScheduleAllocationController c,
    AreaHolding holding) async {
  final target = await _pickTarget(context, c,
      title: 'Move "${holding.name}" to…', exclude: holding.job.id);
  if (target == null || !context.mounted) return;
  await _guard(context, () async {
    await c.move(holding, target);
    return 'Moved to ${c.jobLabel(target)}';
  });
}

Future<void> _unallocate(BuildContext context, ScheduleAllocationController c,
    AreaHolding holding) async {
  if (holding.isHistory) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unallocate a worked area?'),
        content: Text('${c.jobLabel(holding.job)} has already been worked. '
            'Unallocating removes this area from that day\'s record — the '
            'print map and track processing will no longer show it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unallocate')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  await _guard(context, () async {
    await c.unallocate(holding);
    return 'Unallocated from ${c.jobLabel(holding.job)}';
  });
}

/// true = move, false = split (both keep it), null = cancel.
Future<bool?> _askMoveOrSplit(BuildContext context, List<String> holders) =>
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Already allocated'),
        content: Text('Some of these areas are already allocated to:\n\n'
            '${holders.map((h) => '•  $h').join('\n')}\n\n'
            'Move them to the new distributor, or split — both keep them '
            '(e.g. a big area worked over two days)?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Split')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Move')),
        ],
      ),
    );

Future<Job?> _pickTarget(BuildContext context, ScheduleAllocationController c,
    {required String title, String? exclude}) {
  final candidates = c.candidates.where((j) => j.id != exclude).toList();
  return showDialog<Job>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: candidates.isEmpty
            ? Text(_noCandidatesText(c))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final job in candidates)
                    ListTile(
                      dense: true,
                      leading: CircleAvatar(
                          radius: 7,
                          backgroundColor: c.colourOf(job.distributorId)),
                      title: Text(c.who(job)),
                      subtitle: Text(c.dateFormat.format(job.date)),
                      onTap: () => Navigator.pop(ctx, job),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ],
    ),
  );
}

String _noCandidatesText(ScheduleAllocationController c) =>
    'No schedule jobs carry "${c.item?.client ?? ''}" from '
    '${c.windowStart == null ? '' : c.dateFormat.format(c.windowStart!)} '
    'onwards. Add the client to the distributors on the schedule first.';

// ── Left panel ───────────────────────────────────────────────────────────

class ClientMapAllocationPanel extends riverpod.ConsumerStatefulWidget {
  final ScheduleAllocationController controller;

  const ClientMapAllocationPanel({super.key, required this.controller});

  @override
  riverpod.ConsumerState<ClientMapAllocationPanel> createState() =>
      _ClientMapAllocationPanelState();
}

class _ClientMapAllocationPanelState
    extends riverpod.ConsumerState<ClientMapAllocationPanel> {
  bool _collapsed = false;
  final Set<String> _selected = {};

  ScheduleAllocationController get _c => widget.controller;


  Future<void> _assignSelected(Job target) async {
    final keys = {..._selected};
    await _allocate(context, _c, keys, target);
    if (mounted) setState(() => _selected.removeAll(keys));
  }

  @override
  Widget build(BuildContext context) {
    // The map provider is watched so live polygon edits show; the
    // controller for schedule changes.
    ref.watch(shareableMapRiverpod);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        // Left side: the drawing toolbar sits top-right.
        return Positioned(
          left: 0,
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
                    offset: const Offset(2, 0),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: _collapsed ? MainAxisSize.min : MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  if (_c.busy) const LinearProgressIndicator(minHeight: 2),
                  if (!_collapsed) Expanded(child: _body()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    final item = _c.item;
    final ready = !_c.loading && _c.problem == null;
    final total = ready ? _c.areas.length : 0;
    final open = ready ? _c.unallocated.length : 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      color: Colors.teal.shade50,
      child: Row(
        children: [
          const Icon(Icons.assignment_ind_outlined, color: Colors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Schedule allocation',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                if (item != null)
                  Text(
                    '${item.client}  ·  Job List '
                    '${_c.dateFormat.format(item.date)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (ready)
                  Text(
                    '${total - open} of $total allocated',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: open == 0
                          ? Colors.green.shade700
                          : Colors.orange.shade800,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: _collapsed ? 'Expand' : 'Collapse',
            icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less),
            onPressed: () => setState(() => _collapsed = !_collapsed),
          ),
          IconButton(
            tooltip: 'Close schedule allocation',
            icon: const Icon(Icons.close),
            onPressed: closeScheduleAllocation,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_c.loading) return const Center(child: CircularProgressIndicator());
    if (_c.problem != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_c.problem!, style: TextStyle(color: Colors.grey.shade800)),
      );
    }

    final areas = _c.areas;
    final unallocated = _c.unallocated;
    // Drop selections of areas that have since gone or been allocated.
    _selected.retainAll(unallocated.map((a) => a.key));
    final groups = _c.groups;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_noCandidatesText(_c),
                style: TextStyle(color: Colors.grey.shade800)),
          ),
        for (final g in groups) _distributorCard(g),
        const SizedBox(height: 12),
        const Divider(height: 1),
        if (areas.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('This map has no areas or points yet'),
          )
        else
          _unallocatedSection(unallocated),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          child: Text(
            'Shows the schedule from '
            '${_c.dateFormat.format(_c.windowStart!)} to '
            '${_c.dateFormat.format(_c.windowEnd!)}. Colours are for this '
            'view only — the map keeps its own.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  Widget _distributorCard(AllocationGroup g) {
    final byId = {for (final a in _c.areas) a.polygon.id: a};
    final held = g.days.expand((d) => d.holdings);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: g.color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 7, backgroundColor: g.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_c.nameOf(g.distributorId),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                Text(
                  '${g.days.length} day${g.days.length == 1 ? '' : 's'} · '
                  '${_whatHeld(held, byId)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
            for (final day in g.days) _dayRow(day),
          ],
        ),
      ),
    );
  }

  Widget _dayRow(AllocationDay day) {
    final byId = {for (final a in _c.areas) a.polygon.id: a};
    final letterboxes = day.holdings.fold<int>(
        0, (t, h) => t + (byId[h.polygonId]?.polygon.letterBoxEstimate ?? 0));
    final worked = day.job.date.isBefore(scheduleToday());
    final isCandidate = _c.candidates.any((j) => j.id == day.job.id);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (worked)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.check_circle_outline,
                      size: 14, color: Colors.grey.shade600),
                ),
              Expanded(
                child: Text(
                  '${_c.dateFormat.format(day.job.date)} · '
                  '${_whatHeld(day.holdings, byId)}'
                  '${letterboxes > 0 ? ' · $letterboxes letterboxes' : ''}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                ),
              ),
              if (_selected.isNotEmpty && isCandidate)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _c.busy ? null : () => _assignSelected(day.job),
                  child: Text('Assign ${_selected.length} here'),
                ),
            ],
          ),
          if (day.holdings.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Tap an area or point on the map, or tick unallocated ones '
                'below.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [for (final h in day.holdings) _holdingChip(h, byId)],
          ),
        ],
      ),
    );
  }

  Widget _holdingChip(AreaHolding h, Map<String?, AllocationArea> byId) {
    final area = byId[h.polygonId];
    final history = h.isHistory;
    final label = area?.name ?? (h.name.isNotEmpty ? h.name : 'Removed area');
    return PopupMenuButton<String>(
      tooltip: [
        if (area == null) 'No longer on the map',
        if (history) 'Worked',
        if (h.isCopy) 'Copied onto the job — moving it makes it a link',
      ].join(' · '),
      enabled: !_c.busy,
      onSelected: (v) {
        if (v == 'show' && area != null) _c.focus(area);
        if (v == 'move') _move(context, _c, h);
        if (v == 'remove') _unallocate(context, _c, h);
      },
      itemBuilder: (_) => [
        if (area != null)
          const PopupMenuItem(value: 'show', child: Text('Show on map')),
        if (!history)
          const PopupMenuItem(value: 'move', child: Text('Move to…')),
        const PopupMenuItem(value: 'remove', child: Text('Unallocate')),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: history || h.isCopy || area == null || _holdsPoint(h, byId)
            ? Icon(
                area == null
                    ? Icons.warning_amber
                    : history
                        ? Icons.check_circle_outline
                        : h.isCopy
                            ? Icons.content_copy
                            : Icons.place,
                size: 14,
                color: area == null
                    ? Colors.orange.shade800
                    : Colors.grey.shade600,
              )
            : null,
        label: Text(label, style: const TextStyle(fontSize: 11)),
        backgroundColor: history ? Colors.grey.shade100 : null,
      ),
    );
  }

  Widget _unallocatedSection(List<AllocationArea> unallocated) {
    final candidates = _c.candidates;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CircleAvatar(
                  radius: 7, backgroundColor: kUnallocatedAreaColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Unallocated (${unallocated.length})',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (unallocated.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == unallocated.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(unallocated.map((a) => a.key));
                    }
                  }),
                  child: Text(_selected.length == unallocated.length
                      ? 'Clear'
                      : 'Select all'),
                ),
              if (_selected.isNotEmpty && candidates.isNotEmpty)
                PopupMenuButton<Job>(
                  tooltip: 'Assign ticked areas',
                  enabled: !_c.busy,
                  onSelected: _assignSelected,
                  itemBuilder: (_) => [
                    for (final j in candidates)
                      PopupMenuItem(
                        value: j,
                        child: Row(children: [
                          CircleAvatar(
                              radius: 6,
                              backgroundColor: _c.colourOf(j.distributorId)),
                          const SizedBox(width: 8),
                          Text(_c.jobLabel(j)),
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
          if (unallocated.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Everything is allocated.',
                  style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
            ),
          for (final a in unallocated)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(a.key),
              onChanged: _c.busy
                  ? null
                  : (v) => setState(() => v == true
                      ? _selected.add(a.key)
                      : _selected.remove(a.key)),
              title: Row(children: [
                if (a.isPoint)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.place,
                        size: 16, color: Colors.grey.shade600),
                  ),
                Expanded(
                    child: Text(a.name, style: const TextStyle(fontSize: 13))),
              ]),
              subtitle: a.isPoint
                  ? const Text('Point', style: TextStyle(fontSize: 11))
                  : a.polygon.letterBoxEstimate > 0
                      ? Text('${a.polygon.letterBoxEstimate} letterboxes',
                          style: const TextStyle(fontSize: 11))
                      : null,
              secondary: IconButton(
                tooltip: 'Show on map',
                icon: const Icon(Icons.center_focus_strong, size: 18),
                onPressed: () => _c.focus(a),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Info window ──────────────────────────────────────────────────────────

/// The allocation section of a client-map polygon's info window: who works
/// it on which day, and a chip per distributor-day to give it to.
class ScheduleAllocationInfoSection extends riverpod.ConsumerWidget {
  final ScheduleAllocationController controller;
  final String elementId;

  const ScheduleAllocationInfoSection({
    super.key,
    required this.controller,
    required this.elementId,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    ref.watch(shareableMapRiverpod);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        if (c.loading || c.problem != null) return const SizedBox.shrink();
        final area = c.areaForElement(elementId);
        if (area == null) return const SizedBox.shrink();
        final held = c.holdings[area.polygon.id] ?? const <AreaHolding>[];
        final heldBy = {for (final h in held) h.job.id: h};
        final owners = ClientMapAllocationService.currentOwners(held);
        final lead = owners.isNotEmpty
            ? owners.first
            : (held.isNotEmpty ? held.last : null);

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                held.isEmpty
                    ? 'Not allocated'
                    : 'Allocated to ${held.map((h) => c.jobLabel(h.job) + (h.isHistory ? ' (worked)' : '')).join(', ')}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: lead == null
                      ? Colors.grey.shade700
                      : c.colourOf(lead.job.distributorId),
                ),
              ),
              const SizedBox(height: 6),
              if (c.candidates.isEmpty)
                Text(_noCandidatesText(c),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600))
              else
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final job in c.candidates)
                      FilterChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        avatar: CircleAvatar(
                            radius: 5,
                            backgroundColor: c.colourOf(job.distributorId)),
                        label: Text(c.jobLabel(job),
                            style: const TextStyle(fontSize: 11)),
                        selected: heldBy.containsKey(job.id),
                        selectedColor: c
                            .colourOf(job.distributorId)
                            .withValues(alpha: 0.2),
                        onSelected: c.busy
                            ? null
                            : (on) => on
                                ? _allocate(context, c, {area.key}, job)
                                : _unallocate(context, c, heldBy[job.id]!),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
