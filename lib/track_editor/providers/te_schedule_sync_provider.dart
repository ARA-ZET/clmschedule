// track_editor/providers/te_schedule_sync_provider.dart
//
// Keeps open processing tabs in step with the schedule. Each tab is tied to
// a distributor and a day; this watches that day's schedule document and,
// when the tab's jobs change (clients, work areas, drop-offs), pulls the
// change into the tab — no re-upload of the track needed.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/job.dart';
import '../../providers/schedule_provider.dart';
import '../models/tab_item.dart';
import 'te_cloud_save_state_provider.dart';
import 'te_mode_provider.dart';
import 'te_processing_provider.dart';
import 'te_tabs_provider.dart';

final teScheduleSyncRiverpod = riverpod.Provider<TEScheduleSync>((ref) {
  final sync = TEScheduleSync(
    watchJobs: (distributorId, date) => ref
        .read(scheduleRiverpod)
        .watchJobsForDistributorAndDate(distributorId, date),
    tabs: () => ref.read(teTabsRiverpod),
    cloudSave: () => ref.read(teCloudSaveRiverpod),
  );
  ref.listen<TETabsProvider>(
    teTabsRiverpod,
    (_, tabs) => sync.reconcile(tabs),
    fireImmediately: true,
  );
  ref.onDispose(sync.dispose);
  return sync;
});

class TEScheduleSync {
  TEScheduleSync({
    required Stream<List<Job>> Function(String distributorId, DateTime date)
        watchJobs,
    required TETabsProvider Function() tabs,
    required TECloudSaveStateProvider Function() cloudSave,
  })  : _watchJobs = watchJobs,
        _tabs = tabs,
        _cloudSave = cloudSave;

  final Stream<List<Job>> Function(String, DateTime) _watchJobs;
  final TETabsProvider Function() _tabs;
  final TECloudSaveStateProvider Function() _cloudSave;

  /// One live subscription per distributor-day that an open tab covers.
  final Map<String, StreamSubscription<List<Job>>> _subs = {};

  /// Latest jobs per distributor-day, so the save panel resolves clients
  /// from what the stream just delivered rather than a lagging cache.
  final Map<String, List<Job>> _latest = {};

  /// Last seen signatures per distributor-day. The first delivery only sets
  /// the baseline: the tab was built from that same data moments earlier.
  final Map<String, int> _areasSig = {};
  final Map<String, int> _metaSig = {};

  static String? _keyOf(TETabItem tab) {
    final id = tab.distributorId;
    final date = tab.trackDate;
    if (id == null || id.isEmpty || date == null) return null;
    return '$id|${date.year}-${date.month}-${date.day}';
  }

  /// The freshest schedule jobs for [tab], or null when not watched yet.
  List<Job>? latestJobsFor(TETabItem tab) {
    final key = _keyOf(tab);
    return key == null ? null : _latest[key];
  }

  /// Watch exactly the distributor-days of the open processing tabs.
  void reconcile(TETabsProvider tabs) {
    final wanted = <String, TETabItem>{};
    for (final tab in tabs.tabsFor(TEMode.processing)) {
      final key = _keyOf(tab);
      if (key != null) wanted.putIfAbsent(key, () => tab);
    }
    for (final key in _subs.keys.toList()) {
      if (wanted.containsKey(key)) continue;
      _subs.remove(key)?.cancel();
      _latest.remove(key);
      _areasSig.remove(key);
      _metaSig.remove(key);
    }
    wanted.forEach((key, tab) {
      if (_subs.containsKey(key)) return;
      _subs[key] = _watchJobs(tab.distributorId!, tab.trackDate!).listen(
        (jobs) => _onJobs(key, jobs),
        onError: (Object e) =>
            debugPrint('⚠️ TEScheduleSync: watch $key failed: $e'),
      );
    });
  }

  void _onJobs(String key, List<Job> jobs) {
    _latest[key] = jobs;
    final sorted = [...jobs]..sort((a, b) => a.id.compareTo(b.id));
    final areasSig = _areasSignature(sorted);
    final metaSig = _metaSignature(sorted);
    final prevAreas = _areasSig[key];
    final prevMeta = _metaSig[key];
    _areasSig[key] = areasSig;
    _metaSig[key] = metaSig;
    if (prevAreas == null || prevMeta == null) return;

    final areasChanged = areasSig != prevAreas;
    final metaChanged = metaSig != prevMeta;
    if (!areasChanged && !metaChanged) return;

    final tabsProvider = _tabs();
    final matching = tabsProvider
        .tabsFor(TEMode.processing)
        .where((t) => _keyOf(t) == key)
        .toList();
    for (final tab in matching) {
      final updated = tabsProvider.applyScheduleData(
        tab,
        // Only when the areas really changed, so a client-only change keeps
        // any reshaping done on this tab. Areas drawn here that were never
        // filed to a job are kept either way.
        polygons: areasChanged
            ? [
                ...tab.polygons.where((p) => !p.id.startsWith('workmap_')),
                for (final job in sorted)
                  for (final wm in job.workMaps.where((wm) => wm.isPolygon))
                    TEProcessingProvider.customPolygonToStyled(wm),
              ]
            : null,
        jobIds: metaChanged ? [for (final j in sorted) j.id] : null,
        dropOffPoints: metaChanged ? _dropOffs(sorted) : null,
      );
      if (updated != null) _cloudSave().markStale(tab, updated);
    }
    debugPrint('🔄 TEScheduleSync: $key changed on the schedule — '
        'updated ${matching.length} tab(s)');
  }

  static int _areasSignature(List<Job> jobs) => Object.hashAll([
        for (final job in jobs)
          for (final wm in job.workMaps.where((wm) => wm.isPolygon)) ...[
            job.id,
            wm.name,
            wm.color.toARGB32(),
            for (final p in wm.points) ...[p.latitude, p.longitude],
          ],
      ]);

  static int _metaSignature(List<Job> jobs) => Object.hashAll([
        for (final job in jobs) ...[
          job.id,
          ...job.clients,
          '|',
          ...job.workingAreas,
          '|',
          job.dropOffPoint?.latitude,
          job.dropOffPoint?.longitude,
        ],
      ]);

  /// Same labels the tab gets when it is first opened.
  static List<TEDropOffPoint> _dropOffs(List<Job> jobs) => [
        for (final job in jobs)
          if (job.dropOffPoint != null)
            TEDropOffPoint(
              label: job.clients.isNotEmpty
                  ? 'Drop-off · ${job.clients.first}'
                  : 'Drop-off',
              position: job.dropOffPoint!,
              jobId: job.id,
            ),
      ];

  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    _subs.clear();
  }
}
