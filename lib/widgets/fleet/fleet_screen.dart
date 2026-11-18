// widgets/fleet/fleet_screen.dart
//
// Apps → Fleet: the dashboard management uses to review the vehicle
// inspections drivers submit from clmgpx at the start and end of every
// shift (see fleet_dashboard.dart), the other issues drivers report from
// the dropsheet (driver_issues_view.dart), plus the fleet list where plates
// are kept. Opening an inspection shows the checklist, every photo and the
// review flags; management approves or rejects there.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart' show DateFormat;

import '../../models/vehicle_inspection.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dropsheet_provider.dart' show kUnassignedSectionId;
import '../../providers/dropsheet_task_config_provider.dart';
import '../../services/dropsheet_service.dart';
import '../../services/vehicle_inspection_service.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import '../app_toast.dart';
import 'driver_issues_view.dart';
import 'fleet_dashboard.dart';
import 'fleet_photo_storage_view.dart';
import 'fleet_vehicles_view.dart';
import 'inspection_detail_page.dart';

/// Days of inspections the dashboard holds: the review queue, the flags'
/// history (odometer, reused photos) and the recent defects.
const int _windowDays = 30;

/// Days of dropsheets read for the trend — which vehicles owed inspections.
const int _trendDays = 14;

enum _FleetView { dashboard, issues, vehicles, storage }

class FleetScreen extends riverpod.ConsumerStatefulWidget {
  const FleetScreen({super.key});

  @override
  riverpod.ConsumerState<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends riverpod.ConsumerState<FleetScreen> {
  final _service = VehicleInspectionService();
  final _dropsheets = DropsheetService();

  _FleetView _view = _FleetView.dashboard;
  DateTime _date = scheduleToday();

  StreamSubscription<List<VehicleInspection>>? _inspectionSub;
  StreamSubscription<List<FleetVehicle>>? _fleetSub;
  List<VehicleInspection>? _inspections;
  Map<String, FleetVehicle> _fleet = const {};
  Map<String, Map<String, String>> _roster = const {};
  Object? _error;
  bool _rosterLoading = false;

  @override
  void initState() {
    super.initState();
    _fleetSub = _service.streamFleet().listen((list) {
      if (mounted) setState(() => _fleet = {for (final v in list) v.key: v});
    }, onError: (_) {});
    _load();
  }

  @override
  void dispose() {
    _inspectionSub?.cancel();
    _fleetSub?.cancel();
    super.dispose();
  }

  void _load() {
    final date = _date;
    _inspectionSub?.cancel();
    setState(() {
      _inspections = null;
      _error = null;
    });
    _inspectionSub = _service
        .streamRange(date.subtract(const Duration(days: _windowDays - 1)), date)
        .listen((list) {
      if (mounted && date == _date) setState(() => _inspections = list);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
    _loadRoster();
  }

  /// Which vehicles each day's dropsheet sent out, and who drove them.
  Future<void> _loadRoster() async {
    final date = _date;
    setState(() => _rosterLoading = true);
    final roster = <String, Map<String, String>>{};
    await Future.wait([
      for (var n = 0; n < _trendDays; n++)
        () async {
          final day = date.subtract(Duration(days: n));
          try {
            final sheet = await _dropsheets.getDay(day);
            roster[VehicleInspectionService.dateKey(day)] = {
              for (final s in sheet.sections)
                if (s.id != kUnassignedSectionId &&
                    !s.isOwnTransport &&
                    s.vehicle != null &&
                    s.tasks.isNotEmpty)
                  s.vehicle!.name: s.driverName,
            };
          } catch (_) {
            // Unknown day: the trend shows done without "owed".
          }
        }(),
    ]);
    if (!mounted || date != _date) return;
    setState(() {
      _roster = roster;
      _rosterLoading = false;
    });
  }

  void _setDate(DateTime date) {
    _date = DateTime(date.year, date.month, date.day);
    _load();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2026, 1, 1),
      lastDate: scheduleToday(),
    );
    if (picked != null && mounted) _setDate(picked);
  }

  void _open(VehicleInspection inspection) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InspectionDetailPage(
        inspection: inspection,
        history: _inspections ?? const [],
        depot: ref.read(dropsheetTaskConfigRiverpod).depot,
        service: _service,
      ),
    ));
  }

  Future<void> _quickApprove(VehicleInspection inspection) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.setReview(inspection.id,
          status: InspectionReviewStatus.approved);
      messenger.showToast(SnackBar(
        content: Text(
            'Approved ${vehicleName(inspection.vehicleKey)} · ${inspection.kind.label}'),
      ));
    } catch (e) {
      messenger.showToast(SnackBar(
          content: Text(friendlyFirebaseError(e, action: 'approve it'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final depot = ref.watch(dropsheetTaskConfigRiverpod.select((c) => c.depot));
    final inspections = _inspections;

    final Widget body;
    if (_view == _FleetView.issues) {
      body = const DriverIssuesView();
    } else if (_view == _FleetView.storage) {
      body = FleetPhotoStorageView(
        load: _service.fetchAll,
        clear: _service.clearPhotos,
        canClear: ref.watch(authRiverpod.select((a) => a.isAdmin)),
        today: scheduleToday(),
        photoUrl: _service.photoUrl,
        onOpen: _open,
      );
    } else if (_view == _FleetView.vehicles) {
      body = FleetVehiclesView(
          onSave: _service.saveFleetVehicle,
          fleet: _fleet,
          inspections: inspections ?? const []);
    } else if (_error != null) {
      body = _Message(
        icon: Icons.cloud_off_rounded,
        text: friendlyFirebaseError(_error!, action: 'load the inspections'),
        action: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    } else if (inspections == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = FleetDashboard(
        data: FleetDashboardData(
          date: _date,
          inspections: inspections,
          roster: _roster,
          fleet: _fleet,
          depot: depot,
          now: scheduleNow(),
        ),
        onOpen: _open,
        onQuickApprove: _quickApprove,
        photoUrl: _service.photoUrl,
      );
    }

    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      appBar: AppBar(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
        title: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: FleetColors.accent(context).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.local_shipping_rounded,
                color: FleetColors.accent(context), size: 20),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fleet',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text('Daily vehicle inspections from clmgpx',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ]),
        actions: [
          if (_rosterLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: 'Refresh dropsheets',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _rosterLoading ? null : _loadRoster,
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _Toolbar(
              view: _view,
              onView: (v) => setState(() => _view = v),
              date: _date,
              onDate: _setDate,
              onPickDate: _pickDate,
            ),
          ),
        ),
      ),
      body: body,
    );
  }
}

class _Toolbar extends StatelessWidget {
  final _FleetView view;
  final ValueChanged<_FleetView> onView;
  final DateTime date;
  final ValueChanged<DateTime> onDate;
  final VoidCallback onPickDate;

  const _Toolbar({
    required this.view,
    required this.onView,
    required this.date,
    required this.onDate,
    required this.onPickDate,
  });

  @override
  Widget build(BuildContext context) {
    final today = scheduleToday();
    final isToday = date == today;
    final dateControls = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Previous day',
        icon: const Icon(Icons.chevron_left_rounded),
        onPressed: () => onDate(date.subtract(const Duration(days: 1))),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.calendar_today_rounded, size: 16),
        label: Text(isToday
            ? 'Today · ${DateFormat('d MMM').format(date)}'
            : DateFormat('EEE d MMM yyyy').format(date)),
        onPressed: onPickDate,
      ),
      IconButton(
        tooltip: 'Next day',
        icon: const Icon(Icons.chevron_right_rounded),
        onPressed:
            isToday ? null : () => onDate(date.add(const Duration(days: 1))),
      ),
      if (!isToday)
        TextButton(onPressed: () => onDate(today), child: const Text('Today')),
    ]);

    return Row(children: [
      SegmentedButton<_FleetView>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _FleetView.dashboard,
            icon: Icon(Icons.space_dashboard_rounded, size: 18),
            label: Text('Dashboard'),
          ),
          ButtonSegment(
            value: _FleetView.issues,
            icon: Icon(Icons.report_rounded, size: 18),
            label: Text('Issues'),
          ),
          ButtonSegment(
            value: _FleetView.vehicles,
            icon: Icon(Icons.directions_car_rounded, size: 18),
            label: Text('Vehicles'),
          ),
          ButtonSegment(
            value: _FleetView.storage,
            icon: Icon(Icons.photo_library_outlined, size: 18),
            label: Text('Photos'),
          ),
        ],
        selected: {view},
        onSelectionChanged: (s) => onView(s.first),
      ),
      const Spacer(),
      if (view == _FleetView.dashboard)
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: dateControls,
          ),
        ),
    ]);
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ]),
      ),
    );
  }
}
