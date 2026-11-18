// shareable_maps/providers/schedule_allocation_controller.dart
//
// State of the client-map editor's "Schedule allocation" view, shared by its
// left panel, the polygon info window and the map colouring: the Job List job
// the map belongs to, the live schedule jobs that carry its client, who holds
// which area, and a colour per distributor.
//
// The map is coloured through ShareableMapProvider.setPolygonStyleOverride —
// at draw time only — so the client map keeps its own colours when it
// autosaves. Rules for who may hold what live in ClientMapAllocationService.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/custom_polygon.dart';
import '../../models/job.dart';
import '../../models/job_list_item.dart';
import '../../services/client_map_allocation_service.dart';
import '../../services/firestore_service.dart';
import '../adapters/firestore_adapter.dart';
import '../adapters/map_data_adapter.dart';
import '../adapters/schedule_job_adapter.dart' show kUnfinishedAreasLayerId;
import '../utils/linked_map_polygons.dart' show mapPointAsWorkMap;
import 'shareable_map_provider.dart';

/// The open schedule allocation view, or null when it is off. Shared by the
/// app-bar toggle, the editor body and the info window.
final ValueNotifier<ScheduleAllocationController?> scheduleAllocation =
    ValueNotifier<ScheduleAllocationController?>(null);

/// True when the editor's current map can be allocated: a stored client map
/// made for a Job List job.
bool canAllocateCurrentMap(ShareableMapProvider provider) {
  final id = provider.currentMap?.jobListItemId;
  return provider.adapter is FirestoreMapAdapter && id != null && id.isNotEmpty;
}

/// Turn the schedule allocation view on for [provider]'s map, or off.
void toggleScheduleAllocation(ShareableMapProvider provider) {
  if (scheduleAllocation.value != null) {
    closeScheduleAllocation();
  } else {
    scheduleAllocation.value = ScheduleAllocationController(provider);
  }
}

/// Turn the view off. [quiet] when the editor itself is going away: the map
/// provider is then not notified, as nothing is left to repaint.
void closeScheduleAllocation({bool quiet = false}) {
  final controller = scheduleAllocation.value;
  if (controller == null) return;
  scheduleAllocation.value = null;
  controller._close(quiet: quiet);
}

/// One allocatable element of the open map — an area, or a point (a traffic
/// light, a handout spot) — and where the editor finds it.
class AllocationArea {
  final String layerId;

  /// Position in the layer's `polygons`, or in its `points` for a point.
  final int index;

  /// The element as a schedule job holds it; a point is a point-type
  /// polygon carrying the point's id.
  final CustomPolygon polygon;

  final bool isPoint;

  const AllocationArea(this.layerId, this.index, this.polygon,
      {this.isPoint = false});

  /// Selection key — the element id, or its position while it has no id
  /// yet (drawn this session and not saved).
  String get key =>
      polygon.id ?? 'idx:$layerId:${isPoint ? 'pt' : 'pg'}:$index';
  String get name => polygon.name.trim().isNotEmpty
      ? polygon.name
      : (isPoint ? 'Unnamed point' : 'Unnamed area');
}

class ScheduleAllocationController extends ChangeNotifier {
  final ShareableMapProvider _map;
  final ClientMapAllocationService _service;
  final MapDataAdapter? _adapter;
  final DateFormat dateFormat = DateFormat('EEE d MMM');

  ScheduleAllocationController(this._map, {ClientMapAllocationService? service})
      : _service = service ?? ClientMapAllocationService(),
        _adapter = _map.adapter {
    _map.addListener(_onMapChanged);
    _load();
  }

  bool _closed = false;
  bool loading = true;
  String? problem;
  JobListItem? item;
  String? mapId;
  String? monthKey;

  List<Job> _jobs = const [];
  StreamSubscription<List<Job>>? _jobsSub;
  Map<String, String> _names = const {};

  bool _busy = false;
  bool get busy => _busy;

  /// Whether this view has saved the map yet. The first allocation always
  /// saves, so the polygon ids the links point at are stored on the map and
  /// not just derived in memory from an older, id-less document.
  bool _idsStored = false;

  // Derived — recomputed when the jobs or the map change.
  Object? _derivedFor;
  List<AllocationArea> _areas = const [];
  Map<String, List<AreaHolding>> _holdings = const {};
  Map<String, Color> _colours = const {};
  List<Job> _candidates = const [];
  List<AllocationGroup> _groups = const [];

  List<AllocationArea> get areas => _derive()._areas;
  Map<String, List<AreaHolding>> get holdings => _derive()._holdings;
  List<Job> get candidates => _derive()._candidates;
  List<AllocationGroup> get groups => _derive()._groups;

  Color colourOf(String distributorId) =>
      _derive()._colours[distributorId] ?? kUnallocatedAreaColor;

  /// Areas nobody holds — not even a day already worked.
  List<AllocationArea> get unallocated => [
        for (final a in areas)
          if (holdings[a.polygon.id]?.isEmpty ?? true) a,
      ];

  DateTime? get windowStart => item == null
      ? null
      : ClientMapAllocationService.windowStart(item!.date);

  DateTime? get windowEnd =>
      item == null ? null : ClientMapAllocationService.windowEnd(item!.date);

  String who(Job job) => _names[job.distributorId] ?? job.distributorId;
  String nameOf(String distributorId) => _names[distributorId] ?? distributorId;
  String jobLabel(Job job) => '${who(job)} · ${dateFormat.format(job.date)}';

  /// The element behind an editor element id — `layerId_polygon_N` for an
  /// area, the point's own id for a point — or null.
  AllocationArea? areaForElement(String elementId) {
    final m = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
    if (m != null) {
      final layerId = m.group(1)!;
      final index = int.parse(m.group(2)!);
      for (final a in areas) {
        if (!a.isPoint && a.layerId == layerId && a.index == index) return a;
      }
    }
    for (final a in areas) {
      if (a.isPoint && a.polygon.id == elementId) return a;
    }
    return null;
  }

  /// Centre the map on [area].
  void focus(AllocationArea area) {
    if (area.isPoint) {
      _map.focusOnPoint(area.layerId, area.polygon.id!);
    } else {
      _map.focusOnPolygon(area.layerId, area.index);
    }
  }

  // ── Loading & live updates ─────────────────────────────────────────────

  Future<void> _load() async {
    final adapter = _map.adapter;
    final map = _map.currentMap;
    if (adapter is! FirestoreMapAdapter || map == null) {
      _fail('Only a saved client map can be allocated.');
      return;
    }
    if (adapter.docId == null) {
      // A brand-new map gets its document on first save.
      await _map.saveToAdapter();
    }
    mapId = adapter.docId;
    monthKey = adapter.monthKey;

    final found = await _service.jobListItemFor(map, adapter.monthKey);
    if (_closed) return;
    if (found == null) {
      _fail('The Job List job this map was made for could not be found, so '
          'there is no client or date to allocate against.');
      return;
    }

    try {
      final distributors = await FirestoreService().fetchDistributorsOnce();
      _names = {for (final d in distributors) d.id: d.name};
    } catch (e) {
      debugPrint('[Allocation] distributors: $e');
    }
    if (_closed) return;

    item = found;
    loading = false;
    _jobsSub = _service
        .watchJobs(ClientMapAllocationService.windowStart(found.date),
            ClientMapAllocationService.windowEnd(found.date))
        .listen((jobs) {
      _jobs = jobs;
      _restyle();
    }, onError: (Object e) {
      debugPrint('[Allocation] schedule stream: $e');
    });
    _restyle();
  }

  void _fail(String message) {
    if (_closed) return;
    loading = false;
    problem = message;
    notifyListeners();
  }

  /// Repaint the map and the panel after the jobs changed. A new closure, so
  /// the map provider sees a change and redraws.
  void _restyle() {
    if (_closed) return;
    _derivedFor = null;
    _map.setStyleOverrides(
      polygon: (p) => ClientMapAllocationService.styleFor(
          p, holdings[p.id], _derive()._colours),
      point: (p) =>
          ClientMapAllocationService.colourFor(holdings[p.id], _derive()._colours),
    );
    notifyListeners();
  }

  void _onMapChanged() {
    if (_closed) return;
    if (!identical(_map.adapter, _adapter)) {
      // Another map was opened in this editor; this view belonged to the old
      // one. Closed after the current notification finishes.
      scheduleMicrotask(() {
        if (identical(scheduleAllocation.value, this)) {
          closeScheduleAllocation();
        }
      });
      return;
    }
    if (!identical(_derivedFor, _map.currentMap)) {
      // The map is mid-notification and repaints anyway; the panel follows.
      notifyListeners();
    }
  }

  ScheduleAllocationController _derive() {
    final map = _map.currentMap;
    if (_derivedFor != null && identical(_derivedFor, map)) return this;
    _derivedFor = map;

    _areas = map == null
        ? const []
        : [
            for (final layer in map.layers)
              if (layer.id != kUnfinishedAreasLayerId) ...[
                for (var i = 0; i < layer.polygons.length; i++)
                  if (layer.polygons[i].isPolygon &&
                      layer.polygons[i].points.length >= 3)
                    AllocationArea(layer.id, i, layer.polygons[i]),
                for (var i = 0; i < layer.points.length; i++)
                  AllocationArea(
                      layer.id, i, mapPointAsWorkMap(layer.points[i]),
                      isPoint: true),
              ],
          ];
    final client = item?.client;
    final id = mapId;
    if (client == null || id == null) {
      _holdings = const {};
      _candidates = const [];
      _colours = const {};
      _groups = const [];
      return this;
    }
    _holdings = ClientMapAllocationService.holdingsByPolygon(
      _jobs,
      id,
      client: client,
      mapPolygons: [for (final a in _areas) a.polygon],
    );
    _candidates =
        ClientMapAllocationService.candidates(_jobs, client, windowStart!);
    final holders = {
      for (final list in _holdings.values)
        for (final h in list) h.job.id: h.job,
    };
    _colours = ClientMapAllocationService.distributorColours(
      [..._candidates, ...holders.values],
      names: _names,
    );
    _groups =
        ClientMapAllocationService.groups(_candidates, _holdings, _colours);
    return this;
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<T> _run<T>(Future<T> Function() body) async {
    if (_busy) throw StateError('Another allocation is still saving');
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy = false;
      if (!_closed) notifyListeners();
    }
  }

  /// The areas under [keys] with stable ids, saving the map first on the
  /// first allocation and whenever there are unsaved edits (ids are given on
  /// save). Null when the save failed.
  Future<List<CustomPolygon>?> polygonsWithIds(Set<String> keys) async {
    var picked = areas.where((a) => keys.contains(a.key));
    final positions = [
      for (final a in picked) (a.layerId, a.index, a.isPoint)
    ];
    if (!_idsStored ||
        picked.any((a) => a.polygon.id == null) ||
        _map.hasUnsavedChanges) {
      final ok = await _map.saveToAdapter();
      if (!ok) return null;
      _idsStored = true;
      _derivedFor = null;
      final now = areas;
      picked = [
        for (final (layerId, index, isPoint) in positions)
          ...now.where((a) =>
              a.layerId == layerId &&
              a.index == index &&
              a.isPoint == isPoint),
      ];
    }
    return [for (final a in picked) a.polygon];
  }

  /// Labels of the jobs, other than [target], currently holding any of
  /// [polygons] — the people a move would take them from.
  List<String> otherHolders(List<CustomPolygon> polygons, Job target) {
    final out = <String>{};
    for (final p in polygons) {
      for (final h in ClientMapAllocationService.currentOwners(holdings[p.id])) {
        if (h.job.id != target.id) out.add(jobLabel(h.job));
      }
    }
    return out.toList()..sort();
  }

  /// Give [polygons] to [target]. With [move], other current owners lose
  /// them; without, they share them.
  Future<void> allocate(List<CustomPolygon> polygons, Job target,
          {required bool move}) =>
      _run(() => _service.apply(
            ClientMapAllocationService.allocationChanges(
              mapId: mapId!,
              monthKey: monthKey!,
              polygons: polygons,
              target: target,
              holdings: holdings,
              move: move,
            ),
            action: move ? 'moveAreas' : 'allocateAreas',
          ));

  Future<void> move(AreaHolding holding, Job target) =>
      _run(() => _service.apply(
            ClientMapAllocationService.moveChanges(
              mapId: mapId!,
              monthKey: monthKey!,
              holding: holding,
              target: target,
              holdings: holdings,
            ),
            action: 'moveAreas',
          ));

  Future<void> unallocate(AreaHolding holding) =>
      _run(() => _service.unallocate(holding));

  void _close({required bool quiet}) {
    if (_closed) return;
    _closed = true;
    _map.removeListener(_onMapChanged);
    _jobsSub?.cancel();
    if (identical(_map.adapter, _adapter)) {
      if (quiet) {
        _map.clearStyleOverridesQuietly();
      } else {
        _map.setStyleOverrides();
      }
    }
    dispose();
  }
}
