import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/dropsheet_task_type_config.dart';
import '../models/vehicle_inspection.dart';
import '../services/sound_service.dart';
import '../services/vehicle_inspection_service.dart';
import '../utils/browser_notification.dart';
import '../utils/schedule_time.dart';
import 'auth_provider.dart';
import 'dropsheet_task_config_provider.dart';

final inspectionAlertsRiverpod =
    riverpod.ChangeNotifierProvider<InspectionAlertsProvider>((ref) {
  return InspectionAlertsProvider(
    ref.read(authRiverpod),
    depot: () => ref.read(dropsheetTaskConfigRiverpod).depot,
  );
});

/// Tells a signed-in admin about the vehicle inspections drivers submit from
/// clmgpx: the pending count for the app-bar badge, and a notification card
/// (plus a browser notification when the tab is in the background) for each
/// one that arrives, saying up front whether it has defects or anything that
/// needs attention.
///
/// Admins only — other staff get no listener at all. Flags are worked out
/// here from the last 30 days, the same way the Fleet dashboard does.
class InspectionAlertsProvider extends ChangeNotifier {
  InspectionAlertsProvider(
    this._auth, {
    required DepotConfig Function() depot,
    VehicleInspectionService? service,
  })  : _depot = depot,
        service = service ?? VehicleInspectionService() {
    _auth.addListener(_syncWithAuth);
    _syncWithAuth();
  }

  final AuthProvider _auth;
  final DepotConfig Function() _depot;
  final VehicleInspectionService service;

  StreamSubscription<List<VehicleInspection>>? _sub;
  String? _listeningUid;

  /// Ids present when the listener first loaded; anything new after that
  /// arrived while the app was open and earns a browser notification.
  Set<String>? _known;

  final Set<String> _dismissed = {};

  List<VehicleInspection> _recent = const [];
  Map<String, Set<InspectionFlag>>? _flags;
  DepotConfig? _flagsDepot;

  /// Inspections the dashboard history is drawn from (last 30 days).
  List<VehicleInspection> get recent => _recent;

  DepotConfig get depot => _depot();

  /// Recomputed when the depot changes — the task config can load after
  /// the first snapshot, and "not at the depot" depends on it.
  Set<InspectionFlag> flagsOf(VehicleInspection i) {
    final depot = _depot();
    if (_flags == null || !identical(depot, _flagsDepot)) {
      _flagsDepot = depot;
      _flags = {
        for (final r in _recent)
          r.id: VehicleInspectionService.flagsFor(r,
              history: _recent, depot: depot),
      };
    }
    return _flags![i.id] ?? const {};
  }

  List<String> attentionOf(VehicleInspection i) =>
      VehicleInspectionService.attentionPoints(i, flagsOf(i), depot: depot);

  /// A defect, an unsafe item or a flag — anything beyond a clean check.
  bool needsAttention(VehicleInspection i) =>
      i.hasDefects || flagsOf(i).isNotEmpty;

  /// Waiting for a review, newest first.
  List<VehicleInspection> get pending {
    final list = _recent
        .where((i) => i.review.status == InspectionReviewStatus.pending)
        .toList()
      ..sort((a, b) => _when(b).compareTo(_when(a)));
    return list;
  }

  int get pendingCount => pending.length;
  int get pendingAttentionCount => pending.where(needsAttention).length;

  /// Notification cards to show: today's unreviewed inspections the admin
  /// has not closed, most urgent first.
  List<VehicleInspection> get notifications {
    final today = VehicleInspectionService.dateKey(scheduleToday());
    final list = pending
        .where((i) => i.date == today && !_dismissed.contains(i.id))
        .toList();
    int weight(VehicleInspection i) =>
        i.isUnsafe ? 0 : (needsAttention(i) ? 1 : 2);
    list.sort((a, b) {
      final w = weight(a).compareTo(weight(b));
      return w != 0 ? w : _when(b).compareTo(_when(a));
    });
    return list;
  }

  void dismiss(String id) {
    if (_dismissed.add(id)) notifyListeners();
  }

  void dismissAll() {
    _dismissed.addAll(notifications.map((i) => i.id));
    notifyListeners();
  }

  static DateTime _when(VehicleInspection i) =>
      i.submittedAt ?? i.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  void _syncWithAuth() {
    final uid = _auth.user?.uid;
    final wanted = uid != null && _auth.isAdmin ? uid : null;
    if (wanted == _listeningUid) return;
    _stop();
    _listeningUid = wanted;
    if (wanted == null) {
      notifyListeners();
      return;
    }
    requestBrowserNotificationPermission();
    _sub = service
        .streamSince(scheduleToday().subtract(const Duration(days: 30)))
        .listen(_onSnapshot, onError: (Object e) {
      debugPrint('Inspection alerts listener failed: $e');
    });
  }

  void _onSnapshot(List<VehicleInspection> list) {
    _recent = list;
    _flags = null;
    final known = _known;
    _known = {for (final i in list) i.id};
    if (known != null) {
      final arrived = list.where((i) =>
          !known.contains(i.id) &&
          i.review.status == InspectionReviewStatus.pending);
      for (final i in arrived) {
        _notifyBrowser(i);
      }
      if (arrived.isNotEmpty) SoundService().playNotification();
    }
    notifyListeners();
  }

  void _notifyBrowser(VehicleInspection i) {
    final attention = attentionOf(i);
    final lines = <String>[
      for (final d
          in i.defects.where((d) => d.severity == DefectSeverity.unsafe))
        '⛔ UNSAFE — ${shortItemLabel(d.itemId)}'
            '${d.note.isEmpty ? '' : ': ${d.note}'}',
      for (final a in attention) '⚠ $a',
      for (final d
          in i.defects.where((d) => d.severity != DefectSeverity.unsafe))
        '${d.severity.label} defect — ${shortItemLabel(d.itemId)}'
            '${d.note.isEmpty ? '' : ': ${d.note}'}',
      if (attention.isEmpty && i.defects.isEmpty)
        '✓ No defects, nothing flagged',
    ];
    showBrowserNotification(
      title: 'Inspection submitted · ${i.vehicleDisplay} · ${i.driverName}',
      body: lines.join('\n'),
      tag: 'inspection-${i.id}',
    );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _known = null;
    _recent = const [];
    _flags = null;
  }

  @override
  void dispose() {
    _auth.removeListener(_syncWithAuth);
    _stop();
    super.dispose();
  }
}
