// shareable_maps/widgets/client_map_allocation_panel.dart
//
// "Allocate" side panel of the client-map editor: give this map's areas to
// the distributors who carry its Job List client on the schedule, take them
// off again, or move them between distributors. Areas are linked
// (`JobAreaLink`), never copied — see ClientMapAllocationService for the
// rules and FirestoreService.applyAreaLinkChanges for the write.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../../models/job_area_link.dart';
import '../../models/job_list_item.dart';
import '../../services/client_map_allocation_service.dart';
import '../../services/firestore_service.dart';
import '../adapters/firestore_adapter.dart';
import '../adapters/schedule_job_adapter.dart' show kUnfinishedAreasLayerId;
import '../providers/shareable_map_provider.dart';
import 'map_overlay.dart';

/// Whether the allocation panel is open. Shared by the app-bar toggle and
/// the editor body, which are separate widgets.
final ValueNotifier<bool> clientMapAllocationPanelVisible =
    ValueNotifier<bool>(false);

/// True when the editor's current map can be allocated: a stored client map
/// made for a Job List job.
bool canAllocateCurrentMap(ShareableMapProvider provider) {
  final id = provider.currentMap?.jobListItemId;
  return provider.adapter is FirestoreMapAdapter && id != null && id.isNotEmpty;
}

/// One allocatable polygon of the open map.
class _Area {
  final String layerId;
  final int index;
  final CustomPolygon polygon;
  const _Area(this.layerId, this.index, this.polygon);

  /// Selection key — the polygon id, or its position while it has no id yet
  /// (drawn this session and not saved).
  String get key => polygon.id ?? 'idx:$layerId:$index';
  String get name =>
      polygon.name.trim().isNotEmpty ? polygon.name : 'Unnamed area';
}

List<_Area> _areasOf(ShareableMapProvider provider) {
  final map = provider.currentMap;
  if (map == null) return const [];
  return [
    for (final layer in map.layers)
      if (layer.id != kUnfinishedAreasLayerId)
        for (var i = 0; i < layer.polygons.length; i++)
          if (layer.polygons[i].isPolygon &&
              layer.polygons[i].points.length >= 3)
            _Area(layer.id, i, layer.polygons[i]),
  ];
}

class ClientMapAllocationPanel extends riverpod.ConsumerStatefulWidget {
  const ClientMapAllocationPanel({super.key});

  @override
  riverpod.ConsumerState<ClientMapAllocationPanel> createState() =>
      _ClientMapAllocationPanelState();
}

class _ClientMapAllocationPanelState
    extends riverpod.ConsumerState<ClientMapAllocationPanel> {
  final _service = ClientMapAllocationService();
  final _dateFmt = DateFormat('EEE d MMM');

  bool _loading = true;
  String? _problem;
  JobListItem? _item;
  String? _mapId;
  String? _monthKey;

  List<Job> _jobs = const [];
  StreamSubscription<List<Job>>? _jobsSub;
  Map<String, String> _distributorNames = const {};

  final Set<String> _selected = {};
  bool _busy = false;

  /// Whether this panel has saved the map yet. The first allocation always
  /// saves, so the polygon ids the links point at are stored on the map and
  /// not just derived in memory from an older, id-less document.
  bool _idsStored = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _jobsSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final provider = ref.read(shareableMapRiverpod);
    final adapter = provider.adapter;
    final map = provider.currentMap;
    if (adapter is! FirestoreMapAdapter || map == null) {
      setState(() {
        _loading = false;
        _problem = 'Only a saved client map can be allocated.';
      });
      return;
    }
    if (adapter.docId == null) {
      // A brand-new map gets its document on first save.
      await provider.saveToAdapter();
    }
    _mapId = adapter.docId;
    _monthKey = adapter.monthKey;

    final item = await _service.jobListItemFor(map, adapter.monthKey);
    if (!mounted) return;
    if (item == null) {
      setState(() {
        _loading = false;
        _problem = 'The Job List job this map was made for could not be '
            'found, so there is no client or date to allocate against.';
      });
      return;
    }

    try {
      final distributors = await FirestoreService().fetchDistributorsOnce();
      _distributorNames = {for (final d in distributors) d.id: d.name};
    } catch (e) {
      debugPrint('[Allocation] distributors: $e');
    }
    if (!mounted) return;

    _jobsSub = _service
        .watchJobs(ClientMapAllocationService.windowStart(item.date),
            ClientMapAllocationService.windowEnd(item.date))
        .listen((jobs) {
      if (mounted) setState(() => _jobs = jobs);
    }, onError: (Object e) {
      debugPrint('[Allocation] schedule stream: $e');
    });

    setState(() {
      _item = item;
      _loading = false;
    });
  }

  String _who(Job job) =>
      _distributorNames[job.distributorId] ?? job.distributorId;

  String _jobLabel(Job job) => '${_who(job)} · ${_dateFmt.format(job.date)}';

  List<Job> get _candidates => _item == null
      ? const []
      : ClientMapAllocationService.candidates(_jobs, _item!.client,
          ClientMapAllocationService.windowStart(_item!.date));

  // ── Actions ────────────────────────────────────────────────────────────

  /// The selected areas with stable ids, saving the map first on the first
  /// allocation and whenever there are unsaved edits (ids are given on save).
  Future<List<CustomPolygon>?> _selectedPolygonsWithIds() async {
    final provider = ref.read(shareableMapRiverpod);
    var areas = _areasOf(provider).where((a) => _selected.contains(a.key));
    final positions = [for (final a in areas) (a.layerId, a.index)];
    if (!_idsStored ||
        areas.any((a) => a.polygon.id == null) ||
        provider.hasUnsavedChanges) {
      final ok = await provider.saveToAdapter();
      if (!ok) return null;
      _idsStored = true;
      final now = _areasOf(provider);
      areas = [
        for (final (layerId, index) in positions)
          ...now.where((a) => a.layerId == layerId && a.index == index),
      ];
    }
    return [for (final a in areas) a.polygon];
  }

  Future<void> _allocateSelected() async {
    final target = await _pickTarget(
      title: 'Allocate ${_selected.length} '
          'area${_selected.length == 1 ? '' : 's'} to…',
    );
    if (target == null || !mounted) return;

    await _run(() async {
      final polygons = await _selectedPolygonsWithIds();
      if (polygons == null) throw 'The map could not be saved';
      final holdings =
          ClientMapAllocationService.holdingsByPolygon(_jobs, _mapId!);

      // Anyone else currently holding one of these?
      final others = <String>{};
      for (final p in polygons) {
        for (final h
            in ClientMapAllocationService.currentOwners(holdings[p.id])) {
          if (h.job.id != target.id) others.add(_jobLabel(h.job));
        }
      }
      var move = false;
      if (others.isNotEmpty) {
        final choice = await _askMoveOrSplit(others.toList()..sort());
        if (choice == null) return;
        move = choice;
      }

      await _service.apply(
        ClientMapAllocationService.allocationChanges(
          mapId: _mapId!,
          monthKey: _monthKey!,
          polygons: polygons,
          target: target,
          holdings: holdings,
          move: move,
        ),
        action: move ? 'moveAreas' : 'allocateAreas',
      );
      if (mounted) setState(_selected.clear);
      _toast('${polygons.length} area${polygons.length == 1 ? '' : 's'} '
          '${move ? 'moved' : 'allocated'} to ${_jobLabel(target)}');
    });
  }

  Future<void> _moveHolding(AreaHolding holding) async {
    final target = await _pickTarget(
      title: 'Move "${holding.link.name}" to…',
      exclude: holding.job.id,
    );
    if (target == null) return;
    await _run(() async {
      await _service.apply([
        AreaLinkChange(jobId: target.id, date: target.date, add: [
          JobAreaLink(
            mapId: holding.link.mapId,
            monthKey: holding.link.monthKey,
            polygonId: holding.link.polygonId,
            name: holding.link.name,
          ),
        ]),
        AreaLinkChange(
            jobId: holding.job.id,
            date: holding.job.date,
            removeKeys: {holding.link.key}),
      ], action: 'moveAreas');
      _toast('Moved to ${_jobLabel(target)}');
    });
  }

  Future<void> _unallocate(AreaHolding holding) async {
    if (holding.isHistory) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unallocate a worked area?'),
          content: Text('${_jobLabel(holding.job)} has already been worked. '
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
      if (ok != true) return;
    }
    await _run(() async {
      await _service.unallocate(holding.job, holding.link);
      _toast('Unallocated from ${_jobLabel(holding.job)}');
    });
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Allocation failed: $e'),
          backgroundColor: Colors.red.shade800,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green));
  }

  /// true = move, false = split (both keep it), null = cancel.
  Future<bool?> _askMoveOrSplit(List<String> holders) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already allocated'),
          content: Text('Some of these areas are already allocated to:\n\n'
              '${holders.map((h) => '•  $h').join('\n')}\n\n'
              'Move them to the new distributor, or split — both keep them '
              '(e.g. a big area worked over two days)?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Split')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Move')),
          ],
        ),
      );

  Future<Job?> _pickTarget({required String title, String? exclude}) {
    final candidates = _candidates.where((j) => j.id != exclude).toList();
    final item = _item!;
    return showDialog<Job>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: candidates.isEmpty
              ? Text('No schedule jobs carry "${item.client}" from '
                  '${_dateFmt.format(ClientMapAllocationService.windowStart(item.date))}'
                  ' onwards. Add the client to the distributors on the '
                  'schedule first.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final job in candidates)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_pin_circle_outlined),
                        title: Text(_who(job)),
                        subtitle: Text(_dateFmt.format(job.date) +
                            (job.areaLinks.isEmpty
                                ? ''
                                : '  ·  ${job.areaLinks.length} area'
                                    '${job.areaLinks.length == 1 ? '' : 's'} '
                                    'allocated')),
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

  // ── UI ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _body(provider)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final item = _item;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      color: Colors.teal.shade50,
      child: Row(
        children: [
          const Icon(Icons.assignment_ind_outlined, color: Colors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Allocate areas',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                if (item != null)
                  Text(
                    '${item.client}  ·  Job List ${_dateFmt.format(item.date)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => clientMapAllocationPanelVisible.value = false,
          ),
        ],
      ),
    );
  }

  Widget _body(ShareableMapProvider provider) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_problem != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_problem!, style: TextStyle(color: Colors.grey.shade800)),
      );
    }

    final areas = _areasOf(provider);
    final holdings =
        ClientMapAllocationService.holdingsByPolygon(_jobs, _mapId!);
    final unallocated = areas
        .where((a) =>
            ClientMapAllocationService.currentOwners(holdings[a.polygon.id])
                .isEmpty)
        .toList();
    // Drop selections of areas that have since gone from the map.
    _selected.retainAll(areas.map((a) => a.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Text(
                '${areas.length - unallocated.length} of ${areas.length} '
                'allocated',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const Spacer(),
              TextButton(
                onPressed: unallocated.isEmpty
                    ? null
                    : () => setState(() => _selected
                      ..clear()
                      ..addAll(unallocated.map((a) => a.key))),
                child: const Text('Select unallocated'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: FilledButton.icon(
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: Text(_selected.isEmpty
                ? 'Select areas to allocate'
                : 'Allocate ${_selected.length} '
                    'area${_selected.length == 1 ? '' : 's'}…'),
            onPressed: _selected.isEmpty || _busy ? null : _allocateSelected,
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: areas.isEmpty
              ? const Center(child: Text('This map has no areas yet'))
              : ListView.separated(
                  itemCount: areas.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _areaTile(
                      provider, areas[i], holdings[areas[i].polygon.id]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            'Shows allocations from '
            '${_dateFmt.format(ClientMapAllocationService.windowStart(_item!.date))}'
            ' to '
            '${_dateFmt.format(ClientMapAllocationService.windowEnd(_item!.date))}.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  Widget _areaTile(
      ShareableMapProvider provider, _Area area, List<AreaHolding>? held) {
    final selected = _selected.contains(area.key);
    final estimate = area.polygon.letterBoxEstimate;
    return InkWell(
      onTap: () => provider.focusOnPolygon(area.layerId, area.index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selected,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => v == true
                      ? _selected.add(area.key)
                      : _selected.remove(area.key)),
            ),
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 15, right: 8),
              decoration: BoxDecoration(
                color: area.polygon.color,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(area.name,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    if (estimate > 0)
                      Text('$estimate letterboxes',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    if (held == null || held.isEmpty)
                      Text('Not allocated',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade800))
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [for (final h in held) _holdingChip(h)],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _holdingChip(AreaHolding h) {
    final history = h.isHistory;
    return PopupMenuButton<String>(
      tooltip: history ? 'Worked — ${_jobLabel(h.job)}' : _jobLabel(h.job),
      enabled: !_busy,
      onSelected: (v) {
        if (v == 'move') _moveHolding(h);
        if (v == 'remove') _unallocate(h);
      },
      itemBuilder: (_) => [
        if (!history)
          const PopupMenuItem(value: 'move', child: Text('Move to…')),
        const PopupMenuItem(value: 'remove', child: Text('Unallocate')),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: Icon(
          history ? Icons.check_circle_outline : Icons.person,
          size: 16,
          color: history ? Colors.grey.shade600 : Colors.teal.shade700,
        ),
        label: Text(_jobLabel(h.job), style: const TextStyle(fontSize: 12)),
        backgroundColor: history ? Colors.grey.shade100 : Colors.teal.shade50,
      ),
    );
  }
}
