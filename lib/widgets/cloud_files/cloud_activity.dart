// widgets/cloud_files/cloud_activity.dart
//
// Drive-style activity card in the bottom-right corner of Cloud Files:
// "Preparing download…", "Preparing archive · Oct 2026", each with live
// progress and a follow-up action (Download again, Review).
//
// Archive items follow the server's cloudArchives docs through
// CloudArchiveService.watchBatch; local items (downloads) are driven by the
// screen.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/cloud_archive_service.dart';

enum ActivityState { running, done, error }

class ActivityItem {
  final String id;
  final IconData icon;
  String title;
  String? detail;
  double? progress;
  ActivityState state;
  String? actionLabel;
  VoidCallback? onAction;

  ActivityItem({
    required this.id,
    required this.icon,
    required this.title,
    this.detail,
    this.progress,
    this.state = ActivityState.running,
    this.actionLabel,
    this.onAction,
  });
}

class CloudActivity extends ChangeNotifier {
  final List<ActivityItem> _items = [];
  final Map<String, StreamSubscription<List<CloudArchive>>> _jobSubs = {};
  bool collapsed = false;
  int _seq = 0;

  List<ActivityItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get runningCount =>
      _items.where((i) => i.state == ActivityState.running).length;

  ActivityItem start({
    required IconData icon,
    required String title,
    String? detail,
    double? progress,
  }) {
    final item = ActivityItem(
      id: 'a${_seq++}',
      icon: icon,
      title: title,
      detail: detail,
      progress: progress,
    );
    _items.insert(0, item);
    collapsed = false;
    notifyListeners();
    return item;
  }

  void update(
    ActivityItem item, {
    String? title,
    String? detail,
    double? progress,
    ActivityState? state,
    String? actionLabel,
    VoidCallback? onAction,
    bool clearAction = false,
  }) {
    if (title != null) item.title = title;
    if (detail != null) item.detail = detail;
    if (progress != null || state != null) item.progress = progress;
    if (state != null) item.state = state;
    if (clearAction) {
      item.actionLabel = null;
      item.onAction = null;
    }
    if (actionLabel != null) item.actionLabel = actionLabel;
    if (onAction != null) item.onAction = onAction;
    notifyListeners();
  }

  /// Follow an archive batch (a month, or a year's months) while its ZIPs
  /// are built. Once nothing is building any more the item offers "Review",
  /// where the user downloads the ZIPs and confirms removal.
  void trackArchive(
    String batchId, {
    required String label,
    required void Function(String batchId) onReview,
  }) {
    final item = start(
      icon: Icons.inventory_2_outlined,
      title: 'Preparing archive · $label',
      detail: 'Queued…',
    );
    _jobSubs[batchId] = CloudArchiveService().watchBatch(batchId).listen(
      (docs) {
        final parts = docs.where((d) => !d.isYearParent).toList();
        final parent = docs.where((d) => d.id == batchId).firstOrNull;
        if (parts.isEmpty || (parent != null && parent.isBuilding)) {
          if (parent?.isError ?? false) {
            update(item,
                title: 'Archive failed · $label',
                detail: parent!.error ?? 'Something went wrong',
                state: ActivityState.error);
            _jobSubs.remove(batchId)?.cancel();
          } else if (parent?.status == 'empty') {
            update(item,
                title: 'Nothing to archive · $label',
                detail: 'Only compiled map data is left here.',
                state: ActivityState.done);
            _jobSubs.remove(batchId)?.cancel();
          }
          return;
        }
        final building = parts.where((p) => p.isBuilding).toList();
        final ready = parts.where((p) => p.isReady).toList();
        final failed = parts.where((p) => p.isError).toList();
        if (building.isNotEmpty) {
          final b = building.first;
          update(
            item,
            detail: [
              if (parts.length > 1)
                '${parts.length - building.length} of ${parts.length} months ready',
              b.stage == 'zipping'
                  ? 'Zipping ${b.name} · ${b.zippedFiles} of ${b.totalFiles} files'
                  : 'Preparing ${b.name}…',
            ].join(' · '),
            progress: parts.length > 1
                ? (parts.length - building.length) / parts.length
                : b.buildProgress,
          );
          return;
        }
        _jobSubs.remove(batchId)?.cancel();
        if (ready.isEmpty) {
          update(
            item,
            title: failed.isNotEmpty
                ? 'Archive failed · $label'
                : 'Nothing to archive · $label',
            detail: failed.isNotEmpty
                ? (failed.first.error ?? 'Something went wrong')
                : 'Only compiled map data is left here.',
            state: failed.isNotEmpty ? ActivityState.error : ActivityState.done,
          );
          return;
        }
        final bytes = ready.fold<int>(0, (n, p) => n + p.zipBytes);
        update(
          item,
          title: 'Archive ready · $label',
          detail: '${ready.length} ZIP${ready.length == 1 ? '' : 's'} · '
              '${formatBytes(bytes)}'
              '${failed.isNotEmpty ? ' · ${failed.length} failed' : ''}',
          state: ActivityState.done,
          actionLabel: 'Review',
          onAction: () => onReview(batchId),
        );
        onReview(batchId);
      },
      onError: (Object e) {
        update(item,
            detail: 'Lost track of the archive: $e',
            state: ActivityState.error);
      },
    );
  }

  void dismissFinished() {
    _items.removeWhere((i) => i.state != ActivityState.running);
    notifyListeners();
  }

  void toggleCollapsed() {
    collapsed = !collapsed;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _jobSubs.values) {
      s.cancel();
    }
    _jobSubs.clear();
    super.dispose();
  }
}

class CloudActivityPanel extends StatelessWidget {
  final CloudActivity activity;
  const CloudActivityPanel({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: activity,
      builder: (context, _) {
        if (activity.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final running = activity.runningCount;
        final total = activity.items.length;
        final title = running > 0
            ? '$running task${running == 1 ? '' : 's'} in progress'
            : '$total task${total == 1 ? '' : 's'} complete';
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Material(
            elevation: 6,
            color: scheme.surfaceContainerHigh,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      IconButton(
                        tooltip: activity.collapsed ? 'Expand' : 'Minimise',
                        icon: Icon(activity.collapsed
                            ? Icons.expand_less
                            : Icons.expand_more),
                        onPressed: activity.toggleCollapsed,
                      ),
                      IconButton(
                        tooltip: running > 0 ? 'Clear finished' : 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: activity.dismissFinished,
                      ),
                    ],
                  ),
                ),
                if (!activity.collapsed)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final item in activity.items)
                          _ActivityRow(item: item),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ActivityItem item;
  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget status;
    switch (item.state) {
      case ActivityState.running:
        status = SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: item.progress,
          ),
        );
        break;
      case ActivityState.done:
        status = const Icon(Icons.check_circle, color: Color(0xFF1E8E3E));
        break;
      case ActivityState.error:
        status = Icon(Icons.error, color: scheme.error);
        break;
    }
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      margin: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          Icon(item.icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                if (item.detail != null && item.detail!.isNotEmpty)
                  Text(item.detail!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (item.actionLabel != null && item.onAction != null)
            TextButton(onPressed: item.onAction, child: Text(item.actionLabel!))
          else
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: status,
            ),
        ],
      ),
    );
  }
}
