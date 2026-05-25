import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/distributor.dart';
import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../models/job.dart';
import '../../providers/dropsheet_provider.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../providers/schedule_provider.dart';
import '../date_schedule_map_page.dart';
import 'day_planner_palette.dart';
import 'day_planner_panel.dart';

/// Split-screen page launched from the schedule grid's date map button.
///
/// Left side renders all distributor work-areas for the day on a Google
/// Map, with each polygon and numbered drop-off marker coloured by the
/// driver section the distributor is currently assigned to on the day's
/// dropsheet. The right side hosts a compact dropsheet panel for live
/// drag-and-drop reassignment and reordering.
class DayPlannerPage extends riverpod.ConsumerStatefulWidget {
  final DateTime date;
  final List<Job> jobs;
  final List<Distributor> distributors;

  const DayPlannerPage({
    super.key,
    required this.date,
    required this.jobs,
    required this.distributors,
  });

  @override
  riverpod.ConsumerState<DayPlannerPage> createState() =>
      _DayPlannerPageState();
}

class _DayPlannerPageState extends riverpod.ConsumerState<DayPlannerPage> {
  final Completer<GoogleMapController> _mapController =
      Completer<GoogleMapController>();
  final NumberedMarkerCache _markerCache = NumberedMarkerCache();

  Set<Marker> _markers = const {};
  String _markersSignature = '';

  /// Tracks the set of job IDs from the last schedule update.
  /// Used to detect real changes and skip the initial load so we don't
  /// double-fire syncFromSchedule alongside _maybeAutoSeed.
  String _lastScheduleJobsKey = '';
  bool _initialFitDone = false;
  int _rebuildSeq = 0;

  // Drives the custom info-window overlay on the map.
  _MarkerSpec? _selectedMarker;
  Offset? _infoWindowOffset;

  // Provider subscriptions (registered once in initState, closed in dispose).
  riverpod.ProviderSubscription<DropsheetProvider>? _dropsheetSub;
  riverpod.ProviderSubscription<ScheduleProvider>? _scheduleSub;
  riverpod.ProviderSubscription<DropsheetTaskConfigProvider>? _configSub;
  riverpod.ProviderSubscription<Map<String, bool>>? _viewSub;

  // Memoised derived data — recomputed only when the relevant input
  // signature changes, not on every build.
  String _polygonsSignature = '';
  Set<Polygon> _cachedPolygons = const {};
  String _polylinesSignature = '';
  Set<Polyline> _cachedPolylines = const {};
  String _jobToSectionSignature = '';
  Map<String, String> _cachedJobToSection = const {};

  @override
  void initState() {
    super.initState();
    // Make sure the global dropsheet provider is showing the same date
    // as the planner page. setDate is idempotent if already set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reset per-section view toggles for this navigation.
      ref.read(sectionPickUpViewProvider.notifier).state = {};
      ref.read(dropsheetRiverpod).setDate(widget.date);
      _scheduleMarkerRefresh();
    });

    // Register provider listeners ONCE per page lifecycle. Calling
    // ref.listen() inside build() registers a new listener on every
    // rebuild, which causes a rebuild storm. Using ref.listenManual lets
    // us register here and dispose ourselves in dispose().
    _dropsheetSub = ref.listenManual<DropsheetProvider>(
      dropsheetRiverpod,
      (_, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scheduleMarkerRefresh();
        });
      },
    );
    _scheduleSub = ref.listenManual<ScheduleProvider>(
      scheduleRiverpod,
      (_, next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scheduleMarkerRefresh();
          // Auto-sync the dropsheet whenever the schedule for this date
          // changes (drag-drop between distributors or dates, edits to
          // working areas, etc.). Skip the very first emission to avoid
          // racing with _maybeAutoSeed.
          final jobs = next.getJobsForDate(widget.date);
          final key = jobs
              .map((j) =>
                  '${j.id}|${j.distributorId}|${j.workingAreas.join(",")}')
              .join(';');
          if (_lastScheduleJobsKey.isNotEmpty && key != _lastScheduleJobsKey) {
            ref.read(dropsheetRiverpod).syncFromSchedule();
          }
          _lastScheduleJobsKey = key;
        });
      },
    );
    // When task-type config changes (e.g. the user updates which fields
    // are shown on markers), force a full marker rebuild.
    _configSub = ref.listenManual<DropsheetTaskConfigProvider>(
      dropsheetTaskConfigRiverpod,
      (_, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _markersSignature = '';
          _scheduleMarkerRefresh();
        });
      },
    );
    // When a section's drop-off/pick-up view toggle changes, rebuild markers
    // to show only the relevant stop type.
    _viewSub = ref.listenManual<Map<String, bool>>(
      sectionPickUpViewProvider,
      (_, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _markersSignature = '';
          _scheduleMarkerRefresh();
        });
      },
    );
  }

  @override
  void dispose() {
    _dropsheetSub?.close();
    _scheduleSub?.close();
    _configSub?.close();
    _viewSub?.close();
    super.dispose();
  }

  void _scheduleMarkerRefresh() {
    final dropsheet = ref.read(dropsheetRiverpod);
    final schedule = ref.read(scheduleRiverpod);
    final config = ref.read(dropsheetTaskConfigRiverpod);
    final pickUpView = ref.read(sectionPickUpViewProvider);
    final jobs = schedule.getJobsForDate(widget.date);
    final signature = _signatureOf(dropsheet.day, jobs, config, pickUpView);
    if (signature == _markersSignature) return;
    _markersSignature = signature;
    final mySeq = ++_rebuildSeq;
    _rebuildMarkers(dropsheet.day, {for (final j in jobs) j.id: j}, config,
        pickUpView, mySeq);
  }

  @override
  Widget build(BuildContext context) {
    final dropsheet = ref.watch(dropsheetRiverpod);
    final schedule = ref.watch(scheduleRiverpod);
    final jobs = schedule.getJobsForDate(widget.date);

    final jobToSection = _memoJobToSection(dropsheet.day);
    final polygons = _memoPolygons(jobs, jobToSection, dropsheet.day);
    final polylines = _memoPolylines(dropsheet.day);
    final initialCamera = _initialCamera(jobs);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF5F6368)),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Text(
          '${_dateLabel(widget.date)} — Plan day',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF202124),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Fit to bounds',
            icon: const Icon(Icons.zoom_out_map,
                size: 22, color: Color(0xFF5F6368)),
            onPressed: () => _fitToBounds(jobs),
          ),
          IconButton(
            tooltip: 'Open view-only / print map',
            icon: const Icon(Icons.print, size: 22, color: Color(0xFF5F6368)),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DateScheduleMapPage(
                    date: widget.date,
                    jobs: widget.jobs,
                    distributors: widget.distributors,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;
          final panelWidth =
              isWide ? constraints.maxWidth * 0.36 : constraints.maxWidth;
          final mapWidget =
              _buildMap(initialCamera, polygons, polylines, dropsheet.day);
          if (!isWide) {
            return Column(
              children: [
                Expanded(flex: 3, child: mapWidget),
                const Divider(height: 1),
                Expanded(
                  flex: 2,
                  child: DayPlannerPanel(date: widget.date),
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: mapWidget),
              SizedBox(
                width: panelWidth.clamp(320.0, 480.0),
                child: DayPlannerPanel(date: widget.date),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMap(
    CameraPosition initial,
    Set<Polygon> polygons,
    Set<Polyline> polylines,
    DropsheetDay day,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: initial,
              polygons: polygons,
              polylines: polylines,
              markers: _markers,
              myLocationButtonEnabled: false,
              mapToolbarEnabled: false,
              zoomControlsEnabled: false,
              onTap: (_) => setState(() => _selectedMarker = null),
              onMapCreated: (controller) {
                if (!_mapController.isCompleted) {
                  _mapController.complete(controller);
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!_initialFitDone) {
                    _initialFitDone = true;
                    final jobs =
                        ref.read(scheduleRiverpod).getJobsForDate(widget.date);
                    _fitToBounds(jobs);
                  }
                });
              },
            ),
            if (_selectedMarker != null && _infoWindowOffset != null)
              _buildInfoOverlay(constraints, day),
          ],
        );
      },
    );
  }

  /// Positions the custom info-window card above the tapped marker pin.
  Widget _buildInfoOverlay(BoxConstraints constraints, DropsheetDay day) {
    final spec = _selectedMarker!;
    const cardW = 270.0;
    final tipX = _infoWindowOffset!.dx;
    final tipY = _infoWindowOffset!.dy;
    // Place the card centered above the pin tip with a small gap.
    final rawLeft = tipX - cardW / 2;
    final rawTop = tipY - 300.0; // generous estimate for card height
    final left = rawLeft.clamp(
        8.0, (constraints.maxWidth - cardW - 8.0).clamp(8.0, double.infinity));
    final top = rawTop.clamp(8.0, constraints.maxHeight - 80.0);
    return Positioned(
      left: left,
      top: top,
      width: cardW,
      child: _MarkerInfoCard(
        spec: spec,
        day: day,
        onClose: () => setState(() => _selectedMarker = null),
        onReassign: (toSectionId) {
          setState(() => _selectedMarker = null);
          final dropsheet = ref.read(dropsheetRiverpod);
          final toSection = day.sections.firstWhere((s) => s.id == toSectionId);
          dropsheet.moveTask(
            fromSectionId: spec.sectionId,
            fromIndex: spec.taskAbsoluteIndex,
            toSectionId: toSectionId,
            toIndex: toSection.tasks.length,
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Memoised derivations — recomputed only when the input signature changes
  // ---------------------------------------------------------------------------

  Map<String, String> _memoJobToSection(DropsheetDay day) {
    final sb = StringBuffer();
    for (final s in day.sections) {
      sb
        ..write(s.id)
        ..write('@');
      for (final t in s.tasks) {
        final id = t.typeData['distributorJobId'] as String?;
        if (id != null) {
          sb
            ..write(id)
            ..write(',');
        }
      }
      sb.write(';');
    }
    final sig = sb.toString();
    if (sig == _jobToSectionSignature) return _cachedJobToSection;
    _jobToSectionSignature = sig;
    _cachedJobToSection = _buildJobToSection(day);
    return _cachedJobToSection;
  }

  Set<Polyline> _memoPolylines(DropsheetDay day) {
    final sb = StringBuffer();
    for (final s in day.sections) {
      sb
        ..write(s.id)
        ..write(':')
        ..write(s.routePolyline.length)
        ..write(';');
    }
    final sig = sb.toString();
    if (sig == _polylinesSignature) return _cachedPolylines;
    _polylinesSignature = sig;
    _cachedPolylines = _buildPolylines(day);
    return _cachedPolylines;
  }

  Set<Polygon> _memoPolygons(
    List<Job> jobs,
    Map<String, String> jobToSection,
    DropsheetDay day,
  ) {
    final sb = StringBuffer();
    for (final j in jobs) {
      sb
        ..write(j.id)
        ..write('@')
        ..write(jobToSection[j.id] ?? '')
        ..write('|')
        ..write(j.workMaps.length)
        ..write(';');
    }
    final sig = sb.toString();
    if (sig == _polygonsSignature) return _cachedPolygons;
    _polygonsSignature = sig;
    _cachedPolygons = _buildPolygons(jobs, jobToSection, day);
    return _cachedPolygons;
  }

  // ---------------------------------------------------------------------------
  // Polylines
  // ---------------------------------------------------------------------------

  Set<Polyline> _buildPolylines(DropsheetDay day) {
    final out = <Polyline>{};
    for (final section in day.sections) {
      if (section.routePolyline.length < 2) continue;
      final color = colorForSection(section.id, day.sections);
      out.add(
        Polyline(
          polylineId: PolylineId('route_${section.id}'),
          points: section.routePolyline,
          color: color,
          width: 4,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Polygons
  // ---------------------------------------------------------------------------

  Set<Polygon> _buildPolygons(
    List<Job> jobs,
    Map<String, String> jobToSection,
    DropsheetDay day,
  ) {
    final out = <Polygon>{};
    for (final job in jobs) {
      final sectionId = jobToSection[job.id];
      final color = sectionId == null
          ? kUnassignedColor
          : colorForSection(sectionId, day.sections);
      var idx = 0;
      for (final wm in job.workMaps) {
        if (wm.points.length < 3 || wm.isPoint) continue;
        out.add(
          Polygon(
            polygonId: PolygonId('p_${job.id}_${idx++}'),
            points: wm.points,
            // ignore: deprecated_member_use
            fillColor: color.withOpacity(0.25),
            strokeColor: color,
            strokeWidth: 2,
          ),
        );
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Markers
  // ---------------------------------------------------------------------------

  Future<void> _rebuildMarkers(
    DropsheetDay day,
    Map<String, Job> jobById,
    DropsheetTaskConfigProvider config,
    Map<String, bool> pickUpViewBySectionId,
    int seq,
  ) async {
    final pending = <_MarkerSpec>[];
    for (final section in day.sections) {
      final color = colorForSection(section.id, day.sections);
      // Determine whether this section is showing pick-up or drop-off view.
      final sectionInPickUpView = pickUpViewBySectionId[section.id] ?? false;
      final sectionHasPickUp =
          section.tasks.any((t) => t.type == DropsheetTaskType.pickUp);
      var order = 0;
      for (var idx = 0; idx < section.tasks.length; idx++) {
        final t = section.tasks[idx];
        if (t.isMandatory) continue;
        // Filter by view toggle: when the section has pick-up tasks, show
        // only the type matching the current view.
        if (sectionHasPickUp) {
          final isPickUp = t.type == DropsheetTaskType.pickUp;
          if (sectionInPickUpView && !isPickUp) continue;
          if (!sectionInPickUpView && isPickUp) continue;
        }
        // Distributor-linked tasks: use the job's stored coordinate.
        final jobId = t.typeData['distributorJobId'] as String?;
        Job? job;
        if ((t.type == DropsheetTaskType.dropOff ||
                t.type == DropsheetTaskType.pickUp) &&
            jobId != null) {
          job = jobById[jobId];
        }
        final stops = _stopPointsFor(t, job);
        if (stops.isEmpty) continue;
        for (final stop in stops) {
          order += 1;
          final labels = _markerLabelsFor(t, config);
          final primary = stop.suffix == null
              ? labels.primary
              : (labels.primary.isEmpty
                  ? stop.suffix!
                  : '${labels.primary} (${stop.suffix})');
          pending.add(_MarkerSpec(
            id: 'm_${section.id}_${t.id}_${stop.role}',
            position: stop.position,
            color: color,
            number: order,
            primaryLabel: primary,
            secondaryLabel: labels.secondary,
            job: job,
            task: t,
            driverName: section.driverName,
            sectionId: section.id,
            taskId: t.id,
            taskAbsoluteIndex: idx,
            isPickUp: t.type == DropsheetTaskType.pickUp,
          ));
        }
      }
    }

    final markers = <Marker>{};
    // Render all marker bitmaps in parallel rather than awaiting one at
    // a time. Canvas operations release the main thread between frames,
    // so this turns N sequential awaits into a single batched wait.
    final bitmaps = await Future.wait(pending.map(
      (spec) => _markerCache.get(
        color: spec.color,
        number: spec.number,
        primaryLabel: spec.primaryLabel,
        secondaryLabel: spec.secondaryLabel,
        isPickUp: spec.isPickUp,
      ),
    ));
    for (var i = 0; i < pending.length; i++) {
      final spec = pending[i];
      final markerBitmap = bitmaps[i];
      final hasJob = spec.job != null;
      markers.add(
        Marker(
          markerId: MarkerId(spec.id),
          position: spec.position,
          icon: markerBitmap.icon,
          anchor: markerBitmap.anchor,
          draggable: true,
          onTap: () => _onMarkerTap(spec),
          onDragEnd: (LatLng pos) {
            if (!hasJob) {
              _persistTaskCoords(spec, pos);
            } else if (spec.task.type == DropsheetTaskType.pickUp) {
              _persistPickUp(spec.job!, pos);
            } else {
              _persistDropOff(spec.job!, pos);
            }
          },
        ),
      );
    }

    if (!mounted) return;
    // Drop stale results if a newer rebuild has been queued.
    if (seq != _rebuildSeq) return;
    setState(() => _markers = markers);
  }

  Future<void> _onMarkerTap(_MarkerSpec spec) async {
    final ctrl = await _mapController.future;
    final sc = await ctrl.getScreenCoordinate(spec.position);
    if (!mounted) return;
    setState(() {
      _selectedMarker = spec;
      _infoWindowOffset = Offset(sc.x.toDouble(), sc.y.toDouble());
    });
  }

  /// Persists dragged coordinates for a non-distributor task back into its
  /// typeData lat/lng fields so the position survives a hot reload.
  Future<void> _persistTaskCoords(_MarkerSpec spec, LatLng pos) async {
    final dropsheet = ref.read(dropsheetRiverpod);
    try {
      await dropsheet.updateTaskCoords(
          spec.sectionId, spec.taskId, pos.latitude, pos.longitude);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save position: $e')),
      );
    }
  }

  Future<void> _persistDropOff(Job job, LatLng position) async {
    final schedule = ref.read(scheduleRiverpod);
    final dropsheet = ref.read(dropsheetRiverpod);
    final updated = job.copyWith(dropOffPoint: position);
    try {
      await schedule.updateJob(updated);
      // Optimistically refresh the dropsheet's cached coords so the
      // route optimiser stops reading the stale position before the
      // cloud auto-sync trigger lands.
      await dropsheet.refreshDropOffCoords(job.id, position);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save drop-off: $e')),
      );
    }
  }

  Future<void> _persistPickUp(Job job, LatLng position) async {
    final schedule = ref.read(scheduleRiverpod);
    final dropsheet = ref.read(dropsheetRiverpod);
    final updated = job.copyWith(pickUpPoint: position);
    try {
      await schedule.updateJob(updated);
      await dropsheet.refreshPickUpCoords(job.id, position);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save pick-up point: $e')),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, String> _buildJobToSection(DropsheetDay day) {
    final out = <String, String>{};
    for (final s in day.sections) {
      for (final t in s.tasks) {
        final id = t.typeData['distributorJobId'] as String?;
        if (id == null) continue;
        out[id] = s.id;
      }
    }
    return out;
  }

  /// Returns the coordinate(s) at which a task should be pinned on the map.
  ///
  /// For distributor drop-off / pick-up tasks linked to a Job, the live
  /// `dropOffPoint` (or first delivery vertex) is preferred so that
  /// markers stay in sync with edits made on the schedule grid. For all
  /// other task types we fall back to the cached `lat`/`lng` (or
  /// loading/offload variants for furniture moves) written by the editor
  /// when the address was geocoded.
  List<_StopPoint> _stopPointsFor(DropsheetTask t, Job? job) {
    final out = <_StopPoint>[];
    if (job != null) {
      // Pick-up tasks use the job's pickUpPoint (falls back to dropOffPoint);
      // drop-off tasks use dropOffPoint / work-area centroid.
      final p = t.type == DropsheetTaskType.pickUp
          ? defaultPickUpFor(job)
          : defaultDropOffFor(job);
      if (p != null) {
        out.add(_StopPoint(p, 'single'));
        return out;
      }
    }
    if (t.type == DropsheetTaskType.furnitureMove) {
      final ll = (t.typeData['loadingLat'] as num?)?.toDouble();
      final lo = (t.typeData['loadingLng'] as num?)?.toDouble();
      if (ll != null && lo != null) {
        out.add(_StopPoint(LatLng(ll, lo), 'loading', suffix: 'load'));
      }
      final ol = (t.typeData['offloadLat'] as num?)?.toDouble();
      final og = (t.typeData['offloadLng'] as num?)?.toDouble();
      if (ol != null && og != null) {
        out.add(_StopPoint(LatLng(ol, og), 'offload', suffix: 'offload'));
      }
      return out;
    }
    final lat = (t.typeData['lat'] as num?)?.toDouble();
    final lng = (t.typeData['lng'] as num?)?.toDouble();
    if (lat != null && lng != null) {
      out.add(_StopPoint(LatLng(lat, lng), 'single'));
    }
    return out;
  }

  /// Reads the configured primary/secondary marker label fields for [t] and
  /// resolves their values from the task data.
  ({String primary, String secondary}) _markerLabelsFor(
      DropsheetTask t, DropsheetTaskConfigProvider config) {
    final dynId = t.typeData['dynamicTypeId'] as String?;
    MarkerLabelField pf, sf;
    if (dynId != null && dynId.isNotEmpty) {
      final def = config.dynamicTypeById(dynId);
      pf = def?.markerPrimaryField ?? MarkerLabelField.taskLabel;
      sf = def?.markerSecondaryField ?? MarkerLabelField.none;
    } else {
      final tc = config.configFor(t.type);
      pf = tc.markerPrimaryField;
      sf = tc.markerSecondaryField;
    }
    return (primary: _extractField(t, pf), secondary: _extractField(t, sf));
  }

  /// Resolves a [MarkerLabelField] to its string value from [task]'s data.
  String _extractField(DropsheetTask task, MarkerLabelField field) {
    switch (field) {
      case MarkerLabelField.none:
        return '';
      case MarkerLabelField.taskLabel:
        return task.job;
      case MarkerLabelField.details:
        return task.details;
      case MarkerLabelField.contact:
        return task.contact;
      case MarkerLabelField.tel:
        return task.tel;
      case MarkerLabelField.startTime:
        return task.startTime;
      case MarkerLabelField.location:
        return task.location;
      case MarkerLabelField.distributorName:
        return (task.typeData['distributorName'] as String?) ?? '';
      case MarkerLabelField.workArea:
        return (task.typeData['workArea'] as String?) ?? '';
      case MarkerLabelField.client:
        return (task.typeData['client'] as String?) ?? '';
      case MarkerLabelField.address:
        return (task.typeData['address'] as String?) ?? '';
      case MarkerLabelField.jobTypeLabel:
        return (task.typeData['jobTypeLabel'] as String?) ?? '';
    }
  }

  String _signatureOf(
      DropsheetDay day,
      List<Job> jobs,
      DropsheetTaskConfigProvider config,
      Map<String, bool> pickUpViewBySectionId) {
    final jobsById = {for (final j in jobs) j.id: j};
    final sb = StringBuffer();
    for (final s in day.sections) {
      sb
        ..write(s.id)
        ..write(':')
        ..write(pickUpViewBySectionId[s.id] ?? false)
        ..write(':');
      for (final t in s.tasks) {
        if (t.isMandatory) continue;
        final jobId = t.typeData['distributorJobId'] as String?;
        Job? linkedJob;
        if ((t.type == DropsheetTaskType.dropOff ||
                t.type == DropsheetTaskType.pickUp) &&
            jobId != null) {
          linkedJob = jobsById[jobId];
        }
        final stops = _stopPointsFor(t, linkedJob);
        if (stops.isEmpty) continue;
        final labels = _markerLabelsFor(t, config);
        sb
          ..write(t.id)
          ..write('=')
          ..write(labels.primary)
          ..write('|')
          ..write(labels.secondary)
          ..write('[');
        for (final p in stops) {
          sb
            ..write(p.role)
            ..write('@')
            ..write(p.position.latitude.toStringAsFixed(5))
            ..write(',')
            ..write(p.position.longitude.toStringAsFixed(5))
            ..write('|');
        }
        sb.write('],');
      }
      sb.write(';');
    }
    sb.write('|');
    for (final j in jobs) {
      sb
        ..write(j.id)
        ..write('=')
        ..write(j.distributorId);
      final dp = j.dropOffPoint;
      if (dp != null) {
        sb.write(
            '@dp:${dp.latitude.toStringAsFixed(5)},${dp.longitude.toStringAsFixed(5)}');
      }
      final pp = j.pickUpPoint;
      if (pp != null) {
        sb.write(
            '@pu:${pp.latitude.toStringAsFixed(5)},${pp.longitude.toStringAsFixed(5)}');
      }
      sb.write(',');
    }
    return sb.toString();
  }

  CameraPosition _initialCamera(List<Job> jobs) {
    for (final j in jobs) {
      final p = defaultDropOffFor(j);
      if (p != null) return CameraPosition(target: p, zoom: 11);
    }
    return const CameraPosition(target: LatLng(-33.925, 18.425), zoom: 11);
  }

  Future<void> _fitToBounds(List<Job> jobs) async {
    final ctrl = await _mapController.future;
    final allPoints = <LatLng>[];
    for (final j in jobs) {
      for (final wm in j.workMaps) {
        allPoints.addAll(wm.points);
      }
      final dp = j.dropOffPoint;
      if (dp != null) allPoints.add(dp);
    }
    if (allPoints.isEmpty) return;
    double minLat = allPoints.first.latitude, maxLat = minLat;
    double minLng = allPoints.first.longitude, maxLng = minLng;
    for (final p in allPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    await ctrl.animateCamera(CameraUpdate.newLatLngBounds(bounds, 64));
  }

  String _dateLabel(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }
}

class _MarkerSpec {
  final String id;
  final LatLng position;
  final Color color;
  final int number;
  final String primaryLabel;
  final String secondaryLabel;
  final Job? job;
  final DropsheetTask task;
  final String driverName;
  final String sectionId;
  final String taskId;
  final int taskAbsoluteIndex;
  final bool isPickUp;

  _MarkerSpec({
    required this.id,
    required this.position,
    required this.color,
    required this.number,
    required this.primaryLabel,
    this.secondaryLabel = '',
    required this.job,
    required this.task,
    required this.driverName,
    required this.sectionId,
    required this.taskId,
    required this.taskAbsoluteIndex,
    this.isPickUp = false,
  });
}

class _StopPoint {
  final LatLng position;
  final String role;
  final String? suffix;
  const _StopPoint(this.position, this.role, {this.suffix});
}

// =============================================================================
// Custom info-window card — overlaid on the map via Stack + Positioned
// =============================================================================

class _MarkerInfoCard extends StatelessWidget {
  final _MarkerSpec spec;
  final DropsheetDay day;
  final VoidCallback onClose;
  final ValueChanged<String> onReassign;

  const _MarkerInfoCard({
    required this.spec,
    required this.day,
    required this.onClose,
    required this.onReassign,
  });

  @override
  Widget build(BuildContext context) {
    final task = spec.task;
    final otherSections =
        day.sections.where((s) => s.id != spec.sectionId).toList();

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Coloured header bar ──────────────────────────────────────
          Container(
            color: spec.color,
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    spec.driverName.isEmpty ? 'Driver' : spec.driverName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  'Stop ${spec.number}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClose,
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          // ── Body ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Task type row
                Row(
                  children: [
                    Icon(_iconForType(task.type), size: 14, color: spec.color),
                    const SizedBox(width: 6),
                    Text(
                      task.type.displayName,
                      style: TextStyle(
                        fontSize: 12,
                        color: spec.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                // Field rows
                ..._buildFields(task),
                // Reassign section
                if (otherSections.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Move to driver:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final s in otherSections)
                        ActionChip(
                          avatar: CircleAvatar(
                            radius: 6,
                            backgroundColor:
                                colorForSection(s.id, day.sections),
                          ),
                          label: Text(
                            s.driverName.isEmpty ? 'Driver' : s.driverName,
                            style: const TextStyle(fontSize: 11),
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onReassign(s.id),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFields(DropsheetTask t) {
    final rows = <({String label, String value})>[];

    if (t.job.isNotEmpty) rows.add((label: 'Label', value: t.job));
    if (t.startTime.isNotEmpty) rows.add((label: 'Start', value: t.startTime));
    if (t.location.isNotEmpty) rows.add((label: 'Location', value: t.location));
    if (t.details.isNotEmpty) rows.add((label: 'Notes', value: t.details));
    if (t.contact.isNotEmpty) rows.add((label: 'Contact', value: t.contact));
    if (t.tel.isNotEmpty) rows.add((label: 'Tel', value: t.tel));

    final dist = t.typeData['distributorName'] as String?;
    if (dist != null && dist.isNotEmpty) {
      rows.add((label: 'Distributor', value: dist));
    }
    final wa = t.typeData['workArea'] as String?;
    if (wa != null && wa.isNotEmpty) rows.add((label: 'Work area', value: wa));
    final client = t.typeData['client'] as String?;
    if (client != null && client.isNotEmpty) {
      rows.add((label: 'Client', value: client));
    }
    final addr = t.typeData['address'] as String?;
    if (addr != null && addr.isNotEmpty) {
      rows.add((label: 'Address', value: addr));
    }
    final loadAddr = t.typeData['loadingAddress'] as String?;
    if (loadAddr != null && loadAddr.isNotEmpty) {
      rows.add((label: 'Loading', value: loadAddr));
    }
    final offAddr = t.typeData['offloadAddress'] as String?;
    if (offAddr != null && offAddr.isNotEmpty) {
      rows.add((label: 'Offload', value: offAddr));
    }
    // furnitureMove stores extra notes in typeData['notes']
    final tdNotes = t.typeData['notes'] as String?;
    if (tdNotes != null && tdNotes.isNotEmpty && t.details.isEmpty) {
      rows.add((label: 'Notes', value: tdNotes));
    }

    if (rows.isEmpty) return [];

    return [
      const SizedBox(height: 8),
      ...rows.map(
        (r) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 68,
                child: Text(
                  r.label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.black45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  r.value,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF202124),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  IconData _iconForType(DropsheetTaskType t) {
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
