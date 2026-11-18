// widgets/fleet/driver_issues_view.dart
//
// Apps → Fleet → Issues: problems drivers report from the clmgpx dropsheet
// that are not on the vehicle inspection checklist (breakdowns, short loads,
// closed sites…). Open ones first, urgent at the top; the office resolves
// each with an optional note.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';

import '../../models/driver_issue.dart';
import '../../services/driver_issue_service.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import '../app_toast.dart';
import 'fleet_dashboard.dart' show FleetColors;

/// Days of reports the view holds.
const int _windowDays = 30;

enum _IssueFilter { open, resolved, all }

class DriverIssuesView extends StatefulWidget {
  const DriverIssuesView({super.key});

  @override
  State<DriverIssuesView> createState() => _DriverIssuesViewState();
}

class _DriverIssuesViewState extends State<DriverIssuesView> {
  final _service = DriverIssueService();
  StreamSubscription<List<DriverIssue>>? _sub;
  List<DriverIssue>? _issues;
  Object? _error;
  _IssueFilter _filter = _IssueFilter.open;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _load() {
    _sub?.cancel();
    setState(() {
      _issues = null;
      _error = null;
    });
    _sub = _service
        .streamSince(
            scheduleToday().subtract(const Duration(days: _windowDays - 1)))
        .listen((list) {
      if (mounted) setState(() => _issues = list);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  Future<void> _resolve(DriverIssue issue) async {
    final comment = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Resolve: ${issue.category.label}'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: comment,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What was done? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Resolve')),
        ],
      ),
    );
    final text = comment.text;
    comment.dispose();
    if (ok != true || !mounted) return;
    await _setResolved(issue, true, comment: text);
  }

  Future<void> _setResolved(DriverIssue issue, bool resolved,
      {String comment = ''}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.setResolved(issue.id,
          resolved: resolved, comment: comment);
      messenger.showToast(SnackBar(
          content: Text(resolved ? 'Issue resolved' : 'Issue reopened')));
    } catch (e) {
      messenger.showToast(SnackBar(
          content: Text(friendlyFirebaseError(e, action: 'update the issue'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final issues = _issues;
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, size: 40),
          const SizedBox(height: 12),
          Text(friendlyFirebaseError(_error!, action: 'load the issues'),
              textAlign: TextAlign.center),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ]),
      );
    }
    if (issues == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final openCount = issues.where((i) => !i.resolved).length;
    final shown = issues
        .where((i) => switch (_filter) {
              _IssueFilter.open => !i.resolved,
              _IssueFilter.resolved => i.resolved,
              _IssueFilter.all => true,
            })
        .toList()
      ..sort((a, b) {
        if (a.resolved != b.resolved) return a.resolved ? 1 : -1;
        if (!a.resolved && a.urgent != b.urgent) return a.urgent ? -1 : 1;
        return b.when.compareTo(a.when);
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Wrap(spacing: 8, children: [
          for (final f in _IssueFilter.values)
            ChoiceChip(
              label: Text(switch (f) {
                _IssueFilter.open => 'Open ($openCount)',
                _IssueFilter.resolved => 'Resolved',
                _IssueFilter.all => 'All · last $_windowDays days',
              }),
              selected: _filter == f,
              onSelected: (_) => setState(() => _filter = f),
            ),
        ]),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(children: [
              Icon(Icons.task_alt_rounded,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(_filter == _IssueFilter.open
                  ? 'No open issues from drivers.'
                  : 'No issues to show.'),
            ]),
          ),
        for (final issue in shown)
          _IssueCard(
            issue: issue,
            photoUrl: _service.photoUrl,
            onResolve: () => _resolve(issue),
            onReopen: () => _setResolved(issue, false),
          ),
      ],
    );
  }
}

class _IssueCard extends StatelessWidget {
  final DriverIssue issue;
  final Future<String?> Function(String path) photoUrl;
  final VoidCallback onResolve;
  final VoidCallback onReopen;

  const _IssueCard({
    required this.issue,
    required this.photoUrl,
    required this.onResolve,
    required this.onReopen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = issue.resolved
        ? FleetColors.good
        : issue.urgent
            ? FleetColors.critical
            : FleetColors.serious;
    final meta = [
      if (issue.driverName.isNotEmpty) issue.driverName,
      if (issue.vehicleLabel.isNotEmpty) issue.vehicleLabel,
      DateFormat('EEE d MMM · HH:mm').format(issue.when),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(issue.category.icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(issue.category.label,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (issue.urgent && !issue.resolved) ...[
                        const SizedBox(width: 8),
                        _Badge(label: 'URGENT', color: FleetColors.critical),
                      ],
                      if (issue.resolved) ...[
                        const SizedBox(width: 8),
                        _Badge(label: 'RESOLVED', color: FleetColors.good),
                      ],
                    ]),
                    Text(meta,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (issue.resolved)
                TextButton(onPressed: onReopen, child: const Text('Reopen'))
              else
                FilledButton.icon(
                  onPressed: onResolve,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Resolve'),
                ),
            ]),
            const SizedBox(height: 10),
            SelectableText(issue.description,
                style: theme.textTheme.bodyMedium),
            if (issue.photos.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in issue.photos)
                  _PhotoThumb(path: p.path, photoUrl: photoUrl),
              ]),
            ],
            if (issue.lat != null && issue.lng != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact),
                onPressed: () => launchUrl(
                  Uri.parse('https://www.google.com/maps/search/?api=1'
                      '&query=${issue.lat},${issue.lng}'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.place_outlined, size: 16),
                label: const Text('Where it was reported'),
              ),
            ],
            if (issue.resolved &&
                (issue.comment.isNotEmpty || issue.resolvedBy.isNotEmpty)) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: FleetColors.good.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  [
                    if (issue.comment.isNotEmpty) issue.comment,
                    [
                      if (issue.resolvedBy.isNotEmpty) issue.resolvedBy,
                      if (issue.resolvedAt != null)
                        DateFormat('d MMM HH:mm').format(issue.resolvedAt!),
                    ].join(' · '),
                  ].where((s) => s.isNotEmpty).join('\n'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: color)),
      );
}

class _PhotoThumb extends StatelessWidget {
  final String path;
  final Future<String?> Function(String path) photoUrl;
  const _PhotoThumb({required this.path, required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: photoUrl(path),
      builder: (context, snap) {
        final url = snap.data;
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: url == null
              ? null
              : () => showDialog<void>(
                    context: context,
                    builder: (_) => Dialog(
                      child: InteractiveViewer(child: Image.network(url)),
                    ),
                  ),
          child: Container(
            width: 120,
            height: 90,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: url != null
                ? Image.network(url, fit: BoxFit.cover)
                : Center(
                    child: snap.connectionState == ConnectionState.waiting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.image_not_supported_outlined,
                            color: scheme.onSurfaceVariant),
                  ),
          ),
        );
      },
    );
  }
}
