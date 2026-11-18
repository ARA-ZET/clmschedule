import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/distributor.dart';
import '../../models/dropsheet_day.dart';
import '../../models/dropsheet_task.dart';
import '../../models/dropsheet_task_type_config.dart';
import '../../models/job.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../providers/dropsheet_provider.dart';
import '../../providers/dropsheet_task_config_provider.dart';
import '../../providers/schedule_provider.dart';
import '../../shareable_maps/providers/map_gesture_provider.dart';
import '../date_schedule_map_page.dart';
import '../../utils/shared_drop_points.dart';
import '../../utils/dropsheet_maps.dart';
import 'day_planner_palette.dart';
import 'day_planner_panel.dart';
import '../../shareable_maps/widgets/map_overlay.dart';
import '../../undo/undo_redo_buttons.dart';
import '../../undo/undo_shortcuts.dart';

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

  /// Every stop pin as last drawn (shared points expanded) — what a dragged
  /// pin can snap onto.
  List<_MarkerSpec> _stopSpecs = const [];
  bool _markersLoading = false;

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
  riverpod.ProviderSubscription<bool>? _labelsSub;

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
      if (!mounted) return;
      // Reset per-session toggles for this navigation.
      ref.read(sectionPickUpViewProvider.notifier).state = {};
      ref.read(markerLabelsProvider.notifier).state = true;
      ref.read(dropsheetRiverpod).setDate(widget.date);
      // The map and panel read this day's jobs from the schedule provider.
      ref.read(scheduleRiverpod).ensureDateLoaded(widget.date);
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
      (_, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scheduleMarkerRefresh();
          // Schedule → dropsheet sync is handled by DropsheetProvider's own
          // _scheduleSub (debounced 400ms). Calling syncFromSchedule() here
          // too would race with that debounced call and bypass its burst
          // protection, potentially causing two concurrent sync writes.
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
    // When the label-toggle changes, force a full marker rebuild.
    _labelsSub = ref.listenManual<bool>(
      markerLabelsProvider,
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
    _labelsSub?.close();
    super.dispose();
  }

  void _scheduleMarkerRefresh() {
    if (!mounted) return;
    final dropsheet = ref.read(dropsheetRiverpod);
    final schedule = ref.read(scheduleRiverpod);
    final config = ref.read(dropsheetTaskConfigRiverpod);
    final pickUpView = ref.read(sectionPickUpViewProvider);
    final showLabels = ref.read(markerLabelsProvider);
    final jobs = schedule.getJobsForDate(widget.date);
    final signature = _signatureOf(dropsheet.day, jobs, config, pickUpView);
    final fullSignature = '$signature|labels:$showLabels';
    if (fullSignature == _markersSignature) return;
    _markersSignature = fullSignature;
    final mySeq = ++_rebuildSeq;
    setState(() => _markersLoading = true);
    _rebuildMarkers(dropsheet.day, {for (final j in jobs) j.id: j}, config,
        pickUpView, mySeq, showLabels);
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
          UndoRedoButtons(
            undoKey: dropsheet.undoKey,
            color: const Color(0xFF5F6368),
          ),
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
      body: UndoShortcuts(
        undoKey: dropsheet.undoKey,
        child: LayoutBuilder(
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
              webGestureHandling: ref.watch(mapGestureRiverpod).gestureHandling,
              onTap: (_) {
                // The click that landed on a panel or dialog over the map.
                if (ref.read(mapGestureRiverpod).isHeld) return;
                setState(() => _selectedMarker = null);
              },
              onCameraMove: (_) => _updateInfoWindowPosition(),
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
            if (_busyMessage != null || _savingCount > 0)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(child: _buildBusyChip()),
              ),
            // Show a small indicator while bitmaps are being generated so the
            // map never partially shows markers.
            if (_markersLoading)
              Positioned(
                right: 12,
                bottom: 12,
                child: PointerInterceptor(
                  child: MapOverlay(
                    child: Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Loading markers…',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
      child: PointerInterceptor(
        child: MapOverlay(
          child: spec.isGroup
              ? _SharedPointInfoCard(
                  spec: spec,
                  onClose: () => setState(() => _selectedMarker = null),
                  onSplit: (member) => _splitOff(spec, member),
                  onMoveAll: (toSectionId) {
                    setState(() => _selectedMarker = null);
                    ref.read(dropsheetRiverpod).moveTasksTogether(
                        [for (final m in spec.members) m.taskId], toSectionId);
                  },
                )
              : _MarkerInfoCard(
            spec: spec,
            day: day,
            onClose: () => setState(() => _selectedMarker = null),
            onReassign: (toSectionId) {
              setState(() => _selectedMarker = null);
              // By id: the marker's index is from when it was drawn, and a
              // sync or reorder since then made it move a different task.
              ref
                  .read(dropsheetRiverpod)
                  .moveTasksTogether([spec.taskId], toSectionId);
            },
          ),
        ),
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
    // Include the section's color (which is derived from its position in
    // the sections list). If a task moves between drivers the section
    // composition can change → the polyline must repaint with the new
    // colour. Without writing the colour the length-only signature would
    // miss this case.
    for (var i = 0; i < day.sections.length; i++) {
      final s = day.sections[i];
      sb
        ..write(s.id)
        ..write('#')
        ..write(i) // position drives colorForSection
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
    bool showLabels,
  ) async {
    // ── Office / depot marker ─────────────────────────────────────────────────
    // Collected from the first leave task that has geocoded depot coordinates.
    LatLng? officePos;
    String officeAddress = '';
    for (final section in day.sections) {
      for (final t in section.tasks) {
        if (t.type == DropsheetTaskType.leave && t.isMandatory) {
          final lat = t.typeData['lat'] as double?;
          final lng = t.typeData['lng'] as double?;
          if (lat != null && lng != null) {
            officePos = LatLng(lat, lng);
            officeAddress = t.location;
          }
          break;
        }
      }
      if (officePos != null) break;
    }
    final driverCount =
        day.sections.where((s) => s.driverName.isNotEmpty).length;
    _MarkerSpec? officeSpec;
    if (officePos != null) {
      officeSpec = _MarkerSpec(
        id: 'office_depot',
        position: officePos,
        color: const Color(0xFF5F6368),
        number: 0,
        primaryLabel: showLabels ? 'Office' : '',
        secondaryLabel: showLabels
            ? '$driverCount ${driverCount == 1 ? "driver" : "drivers"}'
            : '',
        job: null,
        task: null,
        driverName: officeAddress.isNotEmpty ? officeAddress : 'Office',
        sectionId: '',
        taskId: '',
        taskAbsoluteIndex: -1,
        isOffice: true,
      );
    }

    // ── Per-task stop markers ─────────────────────────────────────────────────
    final pending = <_MarkerSpec>[];
    for (final section in day.sections) {
      final color = colorForSection(section.id, day.sections);
      // Determine whether this section is showing pick-up or drop-off view.
      final sectionInPickUpView = pickUpViewBySectionId[section.id] ?? false;
      final sectionHasPickUp =
          section.tasks.any((t) => t.type == DropsheetTaskType.pickUp);
      // Same numbering as the panel and the printed dropsheet.
      final numbers = stopNumbersFor(section,
          stopCount: (t) => plannerStops(t, jobById).length);
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
        final job = plannerJobFor(t, jobById);
        final stops = plannerStops(t, jobById);
        if (stops.isEmpty) continue;
        // Own transport is unnumbered (0): its pins show a walking icon.
        var order = section.isOwnTransport ? -1 : numbers[t.id]! - 1;
        for (final stop in stops) {
          if (!section.isOwnTransport) order += 1;
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
            number: section.isOwnTransport ? 0 : order,
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

    final stopSpecs = pending;
    // One driver's drop-offs (or pick-ups) within kSharedDropRadiusM of
    // each other are one stop: drawn as a single pin naming everyone.
    // A Junk & Stuff / Happy Sun job and the people dropped at it are one
    // pin too, named after the job.
    final display = _groupSharedStops(pending, {
      for (final section in day.sections) ...jobSitesInSection(section),
    });

    final markers = <Marker>{};
    // Render all marker bitmaps in parallel rather than awaiting one at
    // a time. Canvas operations release the main thread between frames,
    // so this turns N sequential awaits into a single batched wait.
    final bitmaps = await Future.wait(display.map(
      (spec) => _markerCache.get(
        color: spec.color,
        number: spec.number,
        primaryLabel: showLabels ? spec.primaryLabel : '',
        secondaryLabel: showLabels ? spec.secondaryLabel : '',
        isPickUp: spec.isPickUp,
        iconCodePoint: spec.sectionId == kOwnTransportSectionId
            ? Icons.directions_walk.codePoint
            : null,
        // A shared point is one stop: it shows its first stop number and
        // lists each distributor on a line of its own so no name is cut off.
        numberText: spec.isGroup
            ? '${spec.members.map((m) => m.number).reduce(math.min)}'
            : null,
        lines: showLabels && spec.isGroup ? spec.labelLines : const [],
      ),
    ));
    // Several distributors dropped at the same spot would draw their bitmaps
    // exactly on top of each other, hiding all but one. Stack them instead:
    // every marker keeps its true position (so drag, routing and ETAs are
    // untouched), and the k-th one at a spot has its anchor pushed k bitmap
    // heights below the image, which lifts it into a readable column above
    // the first. Pixel-based, so it holds at every zoom level.
    final stackIndex = <int>[];
    final seenAtSpot = <String, int>{};
    for (final spec in display) {
      final key = '${spec.position.latitude.toStringAsFixed(4)},'
          '${spec.position.longitude.toStringAsFixed(4)}';
      final k = seenAtSpot[key] ?? 0;
      seenAtSpot[key] = k + 1;
      stackIndex.add(k);
    }

    for (var i = 0; i < display.length; i++) {
      final spec = display[i];
      final markerBitmap = bitmaps[i];
      final k = stackIndex[i];
      markers.add(
        Marker(
          markerId: MarkerId(spec.id),
          position: spec.position,
          icon: markerBitmap.icon,
          anchor: k == 0
              ? markerBitmap.anchor
              : Offset(markerBitmap.anchor.dx,
                  markerBitmap.anchor.dy + k * _stackStep),
          zIndexInt: k,
          draggable: true,
          onTap: () => _onMarkerTap(spec),
          onDragEnd: (LatLng pos) => _onStopDragged(spec, pos),
        ),
      );
    }

    // ── Office marker (icon-style, non-draggable) ─────────────────────────────
    if (officeSpec != null) {
      final os = officeSpec;
      final officeBitmap = await _markerCache.getIconMarker(
        color: const Color(0xFF5F6368),
        iconCodePoint: Icons.business.codePoint,
        primaryLabel: os.primaryLabel,
        secondaryLabel: os.secondaryLabel,
      );
      markers.add(Marker(
        markerId: MarkerId(os.id),
        position: os.position,
        icon: officeBitmap.icon,
        anchor: officeBitmap.anchor,
        draggable: false,
        onTap: () => _onMarkerTap(os),
      ));
    }

    if (!mounted) return;
    // Drop stale results if a newer rebuild has been queued.
    if (seq != _rebuildSeq) return;
    setState(() {
      _markers = markers;
      _stopSpecs = stopSpecs;
      _markersLoading = false;
      // A shared-point card follows its pin as stops join or leave it.
      final selected = _selectedMarker;
      if (selected != null && selected.isGroup) {
        final ids = selected.members.map((m) => m.taskId).toSet();
        _selectedMarker = display
            .where((d) =>
                d.isGroup && d.members.any((m) => ids.contains(m.taskId)))
            .firstOrNull;
      }
    });
  }

  /// [specs] with each driver's shareable stops (drop-offs, pick-ups) that
  /// lie within [kSharedDropRadiusM] of each other merged into one marker.
  /// The same rule the dropsheet uses ([sharedStopsByTaskId]).
  /// A job site ([sites]) is merged into one marker named after its job.
  List<_MarkerSpec> _groupSharedStops(
      List<_MarkerSpec> specs, Map<String, JobSite> sites) {
    final out = <_MarkerSpec>[];
    final bySite = <String, List<_MarkerSpec>>{};
    for (final s in specs) {
      final site = s.task == null || s.isPickUp ? null : sites[s.task!.id];
      if (site != null) {
        bySite.putIfAbsent('${s.sectionId}|${site.job.id}', () => []).add(s);
      }
    }
    final placed = <String>{};
    final byDriverAndPass = <String, List<_MarkerSpec>>{};
    for (final s in specs) {
      final site = s.task == null || s.isPickUp ? null : sites[s.task!.id];
      final siteSpecs =
          site == null ? null : bySite['${s.sectionId}|${site.job.id}'];
      // Only while the job's own pin is drawn; else its crew stand alone.
      final host =
          siteSpecs?.where((m) => m.taskId == site!.job.id).firstOrNull;
      if (siteSpecs != null && host != null && siteSpecs.length > 1) {
        if (placed.add(host.id)) out.add(_jobSiteSpec(host, siteSpecs));
        continue;
      }
      final t = s.task;
      // Nobody drops Own transport people off — never a shared point.
      if (t == null ||
          !isShareableStop(t) ||
          s.sectionId == kOwnTransportSectionId) {
        out.add(s);
        continue;
      }
      byDriverAndPass.putIfAbsent('${s.sectionId}|${s.isPickUp}', () => []).add(s);
    }
    for (final list in byDriverAndPass.values) {
      for (final g in clusterByDistance(list, (s) => s.position)) {
        out.add(g.length == 1 ? g.single : _sharedPointSpec(g));
      }
    }
    return out;
  }

  /// One pin for a job site: the job's label, then a line per crew member.
  _MarkerSpec _jobSiteSpec(_MarkerSpec host, List<_MarkerSpec> group) {
    final crew = group.where((m) => m.taskId != host.taskId).toList();
    final job = host.task!.job.trim().isEmpty
        ? host.primaryLabel
        : host.task!.job.trim();
    return _MarkerSpec(
      id: 'site_${host.id}',
      position: host.position,
      color: host.color,
      number: group.map((m) => m.number).reduce(math.min),
      primaryLabel: job,
      secondaryLabel: 'Crew · ${crew.length}',
      job: null,
      task: host.task,
      driverName: host.driverName,
      sectionId: host.sectionId,
      taskId: host.taskId,
      taskAbsoluteIndex: host.taskAbsoluteIndex,
      members: [host, ...crew],
      siteJob: host,
      labelLines: [
        job,
        for (final m in crew) '–  ${crewMemberName(m.task!)}',
      ],
    );
  }

  _MarkerSpec _sharedPointSpec(List<_MarkerSpec> group) {
    final first = group.first;
    final names = group
        .map((m) => stopPersonName(m.task!))
        .where((n) => n.isNotEmpty)
        .toList();
    final what = first.isPickUp ? 'Shared pick-up' : 'Shared drop';
    return _MarkerSpec(
      id: 'g_${first.id}',
      position: first.position,
      color: first.color,
      number: first.number,
      primaryLabel: names.join(' + '),
      secondaryLabel: '$what point · ${group.length} people',
      job: null,
      driverName: first.driverName,
      sectionId: first.sectionId,
      taskId: first.taskId,
      taskAbsoluteIndex: first.taskAbsoluteIndex,
      isPickUp: first.isPickUp,
      members: group,
      labelLines: [
        for (final m in group)
          '${m.number}. ${stopPersonName(m.task!).isEmpty ? m.primaryLabel : stopPersonName(m.task!)}',
      ],
    );
  }

  Future<void> _onMarkerTap(_MarkerSpec spec) async {
    // Only marker taps call this; a held map means the click was for UI.
    if (ref.read(mapGestureRiverpod).isHeld) return;
    final ctrl = await _mapController.future;
    final sc = await ctrl.getScreenCoordinate(spec.position);
    if (!mounted) return;
    setState(() {
      _selectedMarker = spec;
      _infoWindowOffset = Offset(sc.x.toDouble(), sc.y.toDouble());
    });
  }

  /// Recalculate the info window's screen offset whenever the camera
  /// moves so the card tracks its marker during pan/zoom instead of
  /// staying glued to the original screen pixel.
  Future<void> _updateInfoWindowPosition() async {
    final spec = _selectedMarker;
    if (spec == null) return;
    if (!_mapController.isCompleted) return;
    final ctrl = await _mapController.future;
    final sc = await ctrl.getScreenCoordinate(spec.position);
    if (!mounted || _selectedMarker?.id != spec.id) return;
    final next = Offset(sc.x.toDouble(), sc.y.toDouble());
    if (_infoWindowOffset == next) return;
    setState(() => _infoWindowOffset = next);
  }

  /// A pin was dropped at [dropped]. A shared-point pin moves all its stops.
  /// Dropped within [kSharedDropRadiusM] of another drop-off (or pick-up)
  /// pin, it snaps onto that exact spot so they become one stop.
  Future<void> _onStopDragged(_MarkerSpec spec, LatLng dropped) async {
    final stops = spec.stops;
    final movingIds = stops.map((m) => m.id).toSet();
    final shareable =
        stops.every((m) => m.task != null && isShareableStop(m.task!));
    _MarkerSpec? target;
    if (shareable) {
      var best = kSharedDropRadiusM;
      for (final other in _stopSpecs) {
        if (movingIds.contains(other.id)) continue;
        if (other.isPickUp != spec.isPickUp) continue;
        if (other.task == null) continue;
        // Drop-offs also snap onto a Junk & Stuff / Happy Sun job's house,
        // joining its crew.
        final isSite = !spec.isPickUp && isJobSiteTask(other.task!);
        if (!isShareableStop(other.task!) && !isSite) continue;
        final d = distanceMeters(other.position, dropped);
        if (d <= best) {
          best = d;
          target = other;
        }
      }
    }
    final at = target?.position ?? dropped;
    if (stops.length == 1 && target == null) {
      await _persistStop(stops.single, at);
      return;
    }
    final count = stops.length + (target == null ? 0 : 1);
    await _runWithFeedback(
      target == null ? 'Moving $count stops…' : 'Combining $count stops…',
      (applied) => _persistStops(stops, at, onApplied: applied),
    );
    if (target != null && mounted) _announceSharedPoint(stops, target);
  }

  // ── Progress feedback ─────────────────────────────────────────────────────
  //
  // Combining stops rewrites several jobs and the dropsheet, and redraws the
  // schedule, map and panel. The message is painted before any of that
  // starts; once the change shows, a small "Saving…" chip stays until the
  // schedule save lands (it keeps retrying offline), and the map stays usable.

  /// Shown while a change is being applied; null when idle.
  String? _busyMessage;

  /// Map saves still running in the background.
  int _savingCount = 0;

  /// Runs [work] with [message] on the map until [work] reports the change
  /// applied (or finishes), then "Saving…" until it finishes.
  Future<void> _runWithFeedback(
    String message,
    Future<void> Function(VoidCallback onApplied) work,
  ) async {
    setState(() {
      _busyMessage = message;
      _savingCount++;
    });
    // Let the message paint before the heavy synchronous part starts.
    await WidgetsBinding.instance.endOfFrame;
    void applied() {
      if (mounted && _busyMessage == message) {
        setState(() => _busyMessage = null);
      }
    }

    try {
      await work(applied);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (_busyMessage == message) _busyMessage = null;
          _savingCount--;
        });
      }
    }
  }

  Widget _buildBusyChip() {
    final busy = _busyMessage;
    final text = busy ??
        (_savingCount == 1 ? 'Saving…' : 'Saving $_savingCount changes…');
    // Informational only: clicks pass straight through to the map.
    return IgnorePointer(
      child: Card(
        elevation: busy != null ? 6 : 3,
        color: busy != null ? const Color(0xFF202124) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: busy != null ? 16 : 12, vertical: busy != null ? 10 : 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: busy != null ? Colors.white : null,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                text,
                style: TextStyle(
                  fontSize: busy != null ? 13 : 12,
                  fontWeight: FontWeight.w600,
                  color: busy != null ? Colors.white : const Color(0xFF202124),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Saves all [stops] at [position] as one change: the jobs in one
  /// schedule write, task-only pins in one dropsheet save. Saving them one
  /// by one redrew everything once per stop and froze the page.
  Future<void> _persistStops(List<_MarkerSpec> stops, LatLng position,
      {VoidCallback? onApplied}) {
    final jobsById = <String, Job>{};
    final pinSectionByTaskId = <String, String>{};
    for (final stop in stops) {
      final isWorkAreaPin = stop.task?.typeData['workAreaPin'] == true;
      if (stop.job == null || isWorkAreaPin) {
        pinSectionByTaskId[stop.taskId] = stop.sectionId;
        continue;
      }
      final job = jobsById[stop.job!.id] ?? _liveJob(stop.job!);
      jobsById[job.id] = stop.task?.type == DropsheetTaskType.pickUp
          ? job.copyWith(pickUpPoint: position)
          : job.copyWith(dropOffPoint: position);
    }
    final pins = ref.read(dropsheetRiverpod).updateTasksCoords(
        pinSectionByTaskId, position.latitude, position.longitude);
    final jobs = ref
        .read(scheduleRiverpod)
        .updateJobs(jobsById.values.toList(), onApplied: onApplied);
    return Future.wait([pins, jobs]);
  }

  /// Saves [stop] at [position]: a job's drop-off / pick-up point, or the
  /// task's own coordinate for per-area pins and tasks without a job.
  Future<void> _persistStop(_MarkerSpec stop, LatLng position) {
    // Per-area pins store their coordinate on the task, so dragging one
    // must not move the job's primary drop-off/pick-up point.
    final isWorkAreaPin = stop.task?.typeData['workAreaPin'] == true;
    if (stop.job == null || isWorkAreaPin) {
      return _persistTaskCoords(stop, position);
    }
    if (stop.task?.type == DropsheetTaskType.pickUp) {
      return _persistPickUp(stop.job!, position);
    }
    return _persistDropOff(stop.job!, position);
  }

  /// "Thabo now shares a drop point with Sipho" — offering to put them on
  /// the same driver when the spot is on another driver's run.
  void _announceSharedPoint(List<_MarkerSpec> moved, _MarkerSpec target) {
    final who = moved
        .map((m) => stopPersonName(m.task!))
        .where((n) => n.isNotEmpty)
        .join(', ');
    final site = isJobSiteTask(target.task!);
    final with_ = site
        ? (target.task!.job.trim().isEmpty
            ? target.primaryLabel
            : target.task!.job.trim())
        : stopPersonName(target.task!);
    final what = target.isPickUp ? 'pick-up' : 'drop';
    final otherDriver = target.sectionId != moved.first.sectionId &&
        target.sectionId != kUnassignedSectionId;
    final day = ref.read(dropsheetRiverpod).day;
    final driver = day.sections
            .where((s) => s.id == target.sectionId)
            .firstOrNull
            ?.driverName ??
        '';
    ScaffoldMessenger.of(context).showToast(SnackBar(
      content: Text(
          '${who.isEmpty ? 'Stop' : who} '
          '${site ? 'is now on the crew for' : 'now shares a $what point with'} '
          '${with_.isEmpty ? 'another stop' : with_}'
          '${otherDriver ? ' on ${driver.isEmpty ? 'another driver' : driver}\'s run' : ''}.'),
      duration: const Duration(seconds: 6),
      action: otherDriver
          ? SnackBarAction(
              label: 'Move to ${driver.isEmpty ? 'driver' : driver}',
              onPressed: () => ref.read(dropsheetRiverpod).moveTasksTogether(
                    [for (final m in moved) m.taskId],
                    target.sectionId,
                    afterTaskId: target.taskId,
                  ),
            )
          : null,
    ));
  }

  /// Takes [member] off the shared point [group]: back to the middle of its
  /// own work area when that is far enough away, else
  /// [kSharedDropRadiusM] × 1.5 off to one side.
  Future<void> _splitOff(_MarkerSpec group, _MarkerSpec member) async {
    final here = group.position;
    LatLng? home;
    final job = member.job == null ? null : _liveJob(member.job!);
    if (job != null) {
      final polygon = job.workMaps
          .where((w) => w.isPolygon && w.points.isNotEmpty)
          .firstOrNull;
      if (polygon != null) home = centroidOf(polygon.points);
    }
    if (home == null || distanceMeters(home, here) <= kSharedDropRadiusM) {
      final i = group.members.indexOf(member);
      final bearing = (i * 72) * math.pi / 180;
      const d = kSharedDropRadiusM * 1.5;
      home = LatLng(
        here.latitude + d * math.cos(bearing) / 111320,
        here.longitude +
            d *
                math.sin(bearing) /
                (111320 * math.cos(here.latitude * math.pi / 180)),
      );
    }
    final name = member.task == null ? '' : stopPersonName(member.task!);
    await _runWithFeedback(
      'Splitting off ${name.isEmpty ? 'stop' : name}…',
      (applied) => _persistStops([member], home!, onApplied: applied),
    );
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
      ScaffoldMessenger.of(context).showToast(
        SnackBar(content: Text('Could not save position: $e')),
      );
    }
  }

  /// The job as the schedule holds it now. The marker's [Job] is the one it
  /// was built with; saving a copy of that would undo any edit made since.
  Job _liveJob(Job job) =>
      ref.read(scheduleRiverpod).jobs.where((j) => j.id == job.id).firstOrNull ??
      job;

  // ScheduleProvider.updateJob moves the dropsheet's linked tasks too (this
  // sheet and any other date's), at once rather than after the save lands.
  Future<void> _persistDropOff(Job job, LatLng position) async {
    final schedule = ref.read(scheduleRiverpod);
    try {
      await schedule.updateJob(_liveJob(job).copyWith(dropOffPoint: position));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showToast(
        SnackBar(content: Text('Could not save drop-off: $e')),
      );
    }
  }

  Future<void> _persistPickUp(Job job, LatLng position) async {
    final schedule = ref.read(scheduleRiverpod);
    try {
      await schedule.updateJob(_liveJob(job).copyWith(pickUpPoint: position));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showToast(
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
        return task.displayJob; // with an appointment's booked time
      case MarkerLabelField.details:
        return task.detailsText;
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
        final stops = plannerStops(t, jobsById);
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
    // Include depot coords so the office marker rebuilds when the address changes.
    for (final s in day.sections) {
      for (final t in s.tasks) {
        if (t.type == DropsheetTaskType.leave && t.isMandatory) {
          final lat = t.typeData['lat'];
          final lng = t.typeData['lng'];
          if (lat != null) sb.write('|depot:$lat,$lng');
          break;
        }
      }
      break; // same depot across all sections
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
    // Also include joblist task coordinates (collections, furniture moves, etc.)
    // so workers without distributor polygons still get a sensible map zoom.
    final day = ref.read(dropsheetRiverpod).day;
    for (final section in day.sections) {
      for (final task in section.tasks) {
        if (task.type == DropsheetTaskType.furnitureMove) {
          final ll = (task.typeData['loadingLat'] as num?)?.toDouble();
          final lo = (task.typeData['loadingLng'] as num?)?.toDouble();
          if (ll != null && lo != null) allPoints.add(LatLng(ll, lo));
          final ol = (task.typeData['offloadLat'] as num?)?.toDouble();
          final og = (task.typeData['offloadLng'] as num?)?.toDouble();
          if (ol != null && og != null) allPoints.add(LatLng(ol, og));
        } else {
          final lat = (task.typeData['lat'] as num?)?.toDouble();
          final lng = (task.typeData['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) allPoints.add(LatLng(lat, lng));
        }
      }
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

/// Vertical spacing between stacked co-located markers, in bitmap heights.
const double _stackStep = 1.05;

class _MarkerSpec {
  final String id;
  final LatLng position;
  final Color color;
  final int number;
  final String primaryLabel;
  final String secondaryLabel;
  final Job? job;
  final DropsheetTask? task;
  final String driverName;
  final String sectionId;
  final String taskId;
  final int taskAbsoluteIndex;
  final bool isPickUp;
  final bool isOffice;

  /// The stops one shared-point marker stands for, in route order; empty for
  /// an ordinary single-stop marker.
  final List<_MarkerSpec> members;

  /// A shared point's badge: one line per distributor.
  final List<String> labelLines;

  /// For a job site's marker: the job's own stop; [members] holds it first,
  /// then the crew.
  final _MarkerSpec? siteJob;

  bool get isGroup => members.length > 1;

  /// The stops this marker moves when dragged.
  List<_MarkerSpec> get stops => isGroup ? members : [this];

  _MarkerSpec({
    required this.id,
    required this.position,
    required this.color,
    required this.number,
    required this.primaryLabel,
    this.secondaryLabel = '',
    required this.job,
    this.task,
    required this.driverName,
    required this.sectionId,
    required this.taskId,
    required this.taskAbsoluteIndex,
    this.isPickUp = false,
    this.isOffice = false,
    this.members = const [],
    this.labelLines = const [],
    this.siteJob,
  });
}

// =============================================================================
// Custom info-window card — overlaid on the map via Stack + Positioned
// =============================================================================

class _MarkerInfoCard extends riverpod.ConsumerWidget {
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
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    // Re-resolve the live task from the dropsheet so edits made elsewhere
    // (task editor, reorder, time change) reflect in the info window while
    // it's open. Falls back to the captured snapshot if the live lookup
    // misses (e.g. task transiently absent during a re-sort).
    final liveDay = ref.watch(dropsheetRiverpod).day;

    // Office marker has its own dedicated info card.
    if (spec.isOffice) return _buildOfficeCard(liveDay);

    DropsheetTask? liveTask;
    String liveSectionId = spec.sectionId;
    for (final s in liveDay.sections) {
      for (final t in s.tasks) {
        if (t.id == spec.taskId) {
          liveTask = t;
          liveSectionId = s.id;
          break;
        }
      }
      if (liveTask != null) break;
    }
    // If the task has been deleted from the dropsheet, dismiss the card
    // on the next frame rather than continuing to render stale content.
    if (liveTask == null && liveDay.sections.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onClose());
    }
    final task = liveTask ?? spec.task;
    if (task == null) return const SizedBox.shrink();
    final otherSections =
        liveDay.sections.where((s) => s.id != liveSectionId).toList();

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
                                colorForSection(s.id, liveDay.sections),
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

  /// Info card shown when the office/depot marker is tapped. Displays
  /// the depot address and each driver's leave time + arrive ETA.
  Widget _buildOfficeCard(DropsheetDay liveDay) {
    const officeColor = Color(0xFF5F6368);
    // address stored in spec.driverName when building the office spec
    final address = spec.driverName != 'Office' ? spec.driverName : '';

    final drivers = <({String name, String leaveTime, String arriveEta})>[];
    for (final s in liveDay.sections) {
      if (s.driverName.isEmpty) continue;
      String leaveTime = '';
      String arriveEta = '';
      for (final t in s.tasks) {
        if (t.type == DropsheetTaskType.leave && t.isMandatory) {
          leaveTime = t.startTime;
        }
        if (t.type == DropsheetTaskType.arrive && t.isMandatory) {
          arriveEta = (t.typeData['eta'] as String?) ?? '';
        }
      }
      drivers.add(
          (name: s.driverName, leaveTime: leaveTime, arriveEta: arriveEta));
    }

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            color: officeColor,
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                const Icon(Icons.business, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Office',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: onClose,
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (address.isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.location_on_outlined,
                          size: 14, color: officeColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          address,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (drivers.isEmpty)
                  const Text('No drivers assigned',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                for (final d in drivers) ...[
                  Row(
                    children: [
                      const Icon(Icons.person_outline,
                          size: 14, color: Colors.grey),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          d.name,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20, top: 2, bottom: 6),
                    child: Row(
                      children: [
                        if (d.leaveTime.isNotEmpty)
                          Text('Leave ${d.leaveTime}',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade600)),
                        if (d.leaveTime.isNotEmpty && d.arriveEta.isNotEmpty)
                          Text('  →  ',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade400)),
                        if (d.arriveEta.isNotEmpty)
                          Text('Arrive ~${d.arriveEta}',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade600)),
                        if (d.leaveTime.isEmpty && d.arriveEta.isEmpty)
                          Text('No times set',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade400)),
                      ],
                    ),
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

    if (t.job.isNotEmpty) rows.add((label: 'Label', value: t.displayJob));
    if (t.appointmentTime.isNotEmpty) {
      rows.add((label: 'Booked', value: t.appointmentTime));
    }
    if (t.appointmentWaitMinutes > 0) {
      rows.add((
        label: 'Early',
        value: '${t.appointmentWaitMinutes} min — wait',
      ));
    }
    if (t.appointmentLateMinutes > 0) {
      rows.add((label: 'LATE', value: '${t.appointmentLateMinutes} min'));
    }
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
      case DropsheetTaskType.distribute:
        return Icons.directions_walk;
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

// =============================================================================
// Shared drop point card — every distributor dropped (or collected) there
// =============================================================================

class _SharedPointInfoCard extends riverpod.ConsumerWidget {
  final _MarkerSpec spec;
  final VoidCallback onClose;
  final ValueChanged<_MarkerSpec> onSplit;
  final ValueChanged<String> onMoveAll;

  const _SharedPointInfoCard({
    required this.spec,
    required this.onClose,
    required this.onSplit,
    required this.onMoveAll,
  });

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final liveDay = ref.watch(dropsheetRiverpod).day;
    final liveById = {
      for (final s in liveDay.sections)
        for (final t in s.tasks) t.id: t,
    };
    final otherSections =
        liveDay.sections.where((s) => s.id != spec.sectionId).toList();
    final what = spec.isPickUp ? 'pick-up' : 'drop';
    // A job site: the job heads the card, its crew are listed below.
    final siteJob = spec.siteJob;
    final listed = siteJob == null
        ? spec.members
        : spec.members.where((m) => m.taskId != siteJob.taskId).toList();

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: spec.color,
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                const Icon(Icons.groups, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    siteJob != null
                        ? spec.primaryLabel
                        : 'Shared $what point · ${spec.members.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  spec.driverName.isEmpty ? 'Driver' : spec.driverName,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClose,
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
              children: [
                if (siteJob != null)
                  _siteJob(liveById[siteJob.taskId] ?? siteJob.task,
                      listed.length),
                for (final m in listed)
                  _member(m, liveById[m.taskId] ?? m.task),
              ],
            ),
          ),
          if (otherSections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Move all to driver:',
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
                                colorForSection(s.id, liveDay.sections),
                          ),
                          label: Text(
                            s.driverName.isEmpty ? 'Driver' : s.driverName,
                            style: const TextStyle(fontSize: 11),
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onMoveAll(s.id),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The job site's own line: where, when, and how many are on its crew.
  Widget _siteJob(DropsheetTask? task, int crewCount) {
    final where = task == null ? '' : DropsheetMaps.locationLabel(task);
    final booked = task?.appointmentTime ?? '';
    final eta = (task?.typeData['eta'] as String?) ?? '';
    final details = [
      if (where.isNotEmpty) where,
      if (booked.isNotEmpty) 'booked $booked',
      if (eta.isNotEmpty) 'arr $eta',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty)
            Text(details,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(
            'Crew · $crewCount',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF00796B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _member(_MarkerSpec m, DropsheetTask? task) {
    final name = task == null
        ? ''
        : spec.siteJob != null
            ? crewMemberName(task)
            : stopPersonName(task);
    final area = task?.shortWorkArea ?? '';
    final tel = task?.tel.trim() ?? '';
    final eta = (task?.typeData['eta'] as String?) ?? '';
    final details = [
      if (area.isNotEmpty) area,
      if (tel.isNotEmpty) tel,
      if (eta.isNotEmpty) 'arr $eta',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: spec.color, shape: BoxShape.circle),
            child: Text(
              '${m.number}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? (task?.displayJob ?? 'Stop') : name,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              textStyle: const TextStyle(fontSize: 11),
            ),
            onPressed: () => onSplit(m),
            child: const Text('Split off'),
          ),
        ],
      ),
    );
  }
}
