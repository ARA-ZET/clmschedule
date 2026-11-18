import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/dropsheet_day.dart';
import '../../providers/dropsheet_provider.dart';
import '../../utils/schedule_time.dart';

/// Lists the saved versions of one day's dropsheet and restores one.
///
/// Firestore keeps every version for 7 days (point-in-time recovery); the
/// `dropsheetHistory` Cloud Function reads them, since client SDKs can't.
/// Covers the day before (when sheets are usually planned) through the day
/// itself. Built after 2026-10-13, when a printed sheet was overwritten by a
/// device with a stale offline cache.
class DropsheetHistoryDialog extends riverpod.ConsumerStatefulWidget {
  final DateTime date;
  const DropsheetHistoryDialog({super.key, required this.date});

  @override
  riverpod.ConsumerState<DropsheetHistoryDialog> createState() =>
      _DropsheetHistoryDialogState();
}

class _Version {
  final String? readTime;
  final DateTime savedAt;
  final List<({String driverId, String driverName, int tasks})> sections;
  final bool current;

  _Version.fromMap(Map<String, dynamic> m)
      : readTime = m['readTime'] as String?,
        savedAt = DateTime.parse(m['updateTime'] as String),
        current = m['current'] == true,
        sections = [
          for (final s in (m['sections'] as List? ?? const []))
            (
              driverId: (s as Map)['driverId']?.toString() ?? '',
              driverName: s['driverName']?.toString() ?? '',
              tasks: (s['tasks'] as num?)?.toInt() ?? 0,
            ),
        ];

  /// Driver sections, i.e. everything except "Unassigned stops" and the
  /// Own transport list.
  int get assigned => sections
      .where((s) =>
          s.driverId != kUnassignedSectionId &&
          s.driverId != kOwnTransportSectionId)
      .length;
}

class _DropsheetHistoryDialogState
    extends riverpod.ConsumerState<DropsheetHistoryDialog> {
  final _fn = FirebaseFunctions.instance.httpsCallable(
    'dropsheetHistory',
    options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
  );
  List<_Version>? _versions;
  String? _error;
  String? _restoring;

  String get _dateId => DropsheetDay.docIdFor(widget.date);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _versions = null;
      _error = null;
    });
    try {
      final res = await _fn.call<Map<String, dynamic>>({'date': _dateId});
      final list = _jsonMap(res.data)['versions'] as List? ?? const [];
      if (!mounted) return;
      setState(() => _versions = [
            for (final v in list) _Version.fromMap(v as Map<String, dynamic>),
          ]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _message(e));
    }
  }

  Future<void> _restore(_Version v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'The dropsheet for ${DateFormat('d MMMM').format(widget.date)} will '
          'go back to how it was saved at ${_time(v.savedAt)}:\n\n'
          '${_summary(v)}\n\n'
          'The current version stays in this history, so you can switch '
          'back to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('RESTORE'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _restoring = v.readTime);
    try {
      final res = await _fn.call<Map<String, dynamic>>(
          {'date': _dateId, 'readTime': v.readTime});
      final version = _jsonMap(res.data)['version'] as Map<String, dynamic>;
      await ref.read(dropsheetRiverpod).restoreVersion(
          widget.date, version['data'] as Map<String, dynamic>);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showToast(SnackBar(
        content: Text('Restored the version saved at ${_time(v.savedAt)}.'),
      ));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoring = null);
      ScaffoldMessenger.of(context).showToast(
        SnackBar(content: Text('Restore failed: ${_message(e)}')),
      );
    }
  }

  /// Callable results arrive as nested `Map<Object?, Object?>`; round-trip
  /// through JSON to get the `Map<String, dynamic>` the models expect.
  static Map<String, dynamic> _jsonMap(Object? data) =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

  static String _message(Object e) =>
      e is FirebaseFunctionsException ? (e.message ?? e.code) : e.toString();

  static String _time(DateTime t) =>
      DateFormat('EEE d MMM, HH:mm').format(toScheduleCivil(t));

  static String _summary(_Version v) =>
      v.sections.map((s) => '${s.driverName}: ${s.tasks}').join('  ·  ');

  @override
  Widget build(BuildContext context) {
    final versions = _versions;
    return AlertDialog(
      title: Text('Version history — '
          '${DateFormat('d MMMM yyyy').format(widget.date)}'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: _error != null
            ? Center(child: Text('Couldn\'t load history: $_error'))
            : versions == null
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Reading saved versions…'),
                      ],
                    ),
                  )
                : versions.isEmpty
                    ? const Center(
                        child: Text('No saved versions in the last 7 days.'))
                    : ListView.separated(
                        itemCount: versions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _row(versions[i]),
                      ),
      ),
      actions: [
        Text(
          'Saved versions are kept for 7 days.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton(
          onPressed: versions == null && _error == null ? null : _load,
          child: const Text('REFRESH'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }

  Widget _row(_Version v) {
    final busy = _restoring != null;
    return ListTile(
      leading: Icon(
        v.assigned > 0 ? Icons.local_shipping_outlined : Icons.inbox_outlined,
        color: v.assigned > 0 ? Colors.green[700] : Colors.grey,
      ),
      title: Text('Saved ${_time(v.savedAt)}'),
      subtitle: Text(_summary(v)),
      trailing: v.current
          ? const Chip(label: Text('Current'))
          : _restoring == v.readTime
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : OutlinedButton(
                  onPressed: busy || v.readTime == null
                      ? null
                      : () => _restore(v),
                  child: const Text('Restore'),
                ),
    );
  }
}
