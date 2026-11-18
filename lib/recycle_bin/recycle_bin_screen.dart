// recycle_bin/recycle_bin_screen.dart
//
// One Recycle Bin for the whole app, with a section per area. Anyone signed
// in can restore; only admins see "Delete forever" and "Empty".
import 'package:clmschedule/utils/text_search.dart';
import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../providers/auth_provider.dart';
import '../utils/friendly_error.dart';
import 'recycle_bin_entry.dart';
import 'recycle_bin_service.dart';

/// Opens the bin on [tab] — for a screen's "Recently deleted" button. Pushes
/// on the nearest navigator, which inside the dashboard is the body
/// navigator, so the app bar stays visible.
Future<void> openRecycleBin(BuildContext context, RecycleBinTab tab) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => RecycleBinScreen(initialTab: tab),
  ));
}

/// The "Recently deleted" icon button a screen puts in its toolbar.
class RecentlyDeletedButton extends StatelessWidget {
  final RecycleBinTab tab;
  final Color? color;
  const RecentlyDeletedButton({super.key, required this.tab, this.color});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.delete_sweep_outlined),
      color: color,
      visualDensity: VisualDensity.compact,
      tooltip: 'Recently deleted (Recycle Bin)',
      onPressed: () => openRecycleBin(context, tab),
    );
  }
}

/// SnackBar shown right after a delete: "Moved to Recycle Bin" + Restore.
void showMovedToBinSnackBar(
  BuildContext context,
  riverpod.WidgetRef ref, {
  required String what,
  required String? entryId,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final service = ref.read(recycleBinServiceRiverpod);
  messenger
    ..hideCurrentToast()
    ..showToast(SnackBar(
      content: Text('$what moved to the Recycle Bin'),
      duration: const Duration(seconds: 6),
      action: entryId == null
          ? null
          : SnackBarAction(
              label: 'Restore',
              onPressed: () async {
                try {
                  await service.restoreById(entryId);
                  messenger
                      .showToast(SnackBar(content: Text('$what restored')));
                } catch (e) {
                  messenger.showToast(SnackBar(
                    content: Text(_restoreErrorText(what, e)),
                    backgroundColor: Colors.orange.shade800,
                  ));
                }
              },
            ),
    ));
}

String _restoreErrorText(String what, Object e) => e is RestoreConflict
    ? "Couldn't restore $what — $e."
    : friendlyFirebaseError(e, action: 'restore $what');

// ── Screen ───────────────────────────────────────────────────────────────────
//
// Layout, top to bottom: a header saying what the bin is and how long things
// stay, one pill per app area (with live counts), a search + filter row, and
// the deleted items grouped by when they were deleted. Selecting items (tap
// the icon, long-press, or hover on desktop) raises a floating action bar.

enum _Sort { newest, expiringSoon, name }

/// One accent per area, used for the item icon tiles.
const Map<RecycleBinTab, Color> _accent = {
  RecycleBinTab.jobList: Color(0xFF4F46E5),
  RecycleBinTab.schedule: Color(0xFF0D9488),
  RecycleBinTab.maps: Color(0xFF16A34A),
  RecycleBinTab.cloudFiles: Color(0xFF2563EB),
  RecycleBinTab.clients: Color(0xFFEA580C),
  RecycleBinTab.settings: Color(0xFF64748B),
};

const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

String _typeLabel(RecycleBinType t) => switch (t) {
      RecycleBinType.jobListItem => 'Job',
      RecycleBinType.scheduleJob => 'Schedule job',
      RecycleBinType.shareableMap => 'Map',
      RecycleBinType.clientArea => 'Client area',
      RecycleBinType.workArea => 'Work area',
      RecycleBinType.cloudFile => 'File',
      RecycleBinType.cloudFolder => 'Folder',
      RecycleBinType.regularClient => 'Regular client',
      RecycleBinType.distributor => 'Distributor',
      RecycleBinType.driver => 'Driver',
      RecycleBinType.unfinishedWorkArea => 'Unfinished area',
      RecycleBinType.jobType => 'Job type',
      RecycleBinType.jobStatus => 'Schedule status',
      RecycleBinType.jobListStatus => 'Job List status',
      RecycleBinType.invoiceStatus => 'Invoice status',
      RecycleBinType.mapInstruction => 'Map instruction',
    };

/// Where the item lived, in words.
String _whereLabel(RecycleBinEntry e) {
  final parts = e.originalPath.split('/');
  String part(int i) => parts.length > i ? parts[i] : '';
  switch (e.type) {
    case RecycleBinType.jobListItem:
      return 'Job List · ${part(1)}';
    case RecycleBinType.scheduleJob:
      final key = e.payload['dateKey'] as String?;
      final date = key == null ? null : DateTime.tryParse(key);
      return date == null
          ? 'Schedule'
          : 'Schedule · ${DateFormat('EEE d MMM yyyy').format(date)}';
    case RecycleBinType.shareableMap:
      return 'Maps gallery · ${part(1)}';
    case RecycleBinType.clientArea:
      return 'Client areas library';
    case RecycleBinType.workArea:
      return 'Work areas library';
    case RecycleBinType.cloudFile:
    case RecycleBinType.cloudFolder:
      return 'Cloud Files · ${e.originalPath}';
    case RecycleBinType.regularClient:
      return 'Regular clients';
    case RecycleBinType.distributor:
      return 'Distributors';
    case RecycleBinType.driver:
      return 'Dropsheet drivers';
    case RecycleBinType.unfinishedWorkArea:
      return 'Unfinished work areas';
    case RecycleBinType.jobType:
      return 'Settings · Job types';
    case RecycleBinType.jobStatus:
      return 'Settings · Schedule statuses';
    case RecycleBinType.jobListStatus:
      return 'Settings · Job List statuses';
    case RecycleBinType.invoiceStatus:
      return 'Settings · Invoice statuses';
    case RecycleBinType.mapInstruction:
      return 'Settings · Map instructions';
  }
}

/// "2 invoice links, 1 share link" — what comes back with the item.
String? _relatedSummary(RecycleBinEntry e) {
  final invoices = <String>{};
  var links = 0;
  var projects = 0;
  for (final r in e.related) {
    final segs = r.path.split('/');
    switch (segs.first) {
      case 'zohoInvoiceLinks':
      case 'accountingInvoiceLinks':
        invoices.add(segs.last);
      case 'mapLinks':
        links++;
      case 'happySunProjects':
        projects++;
    }
  }
  String n(int c, String one) => '$c $one${c == 1 ? '' : 's'}';
  final parts = [
    if (invoices.isNotEmpty) n(invoices.length, 'invoice link'),
    if (links > 0) n(links, 'share link'),
    if (projects > 0) n(projects, 'Happy Sun project'),
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

String _relative(DateTime? t) {
  if (t == null) return 'just now';
  final now = DateTime.now();
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 12 && t.day == now.day) return '${d.inHours} h ago';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final time = DateFormat('HH:mm').format(t);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Yesterday $time';
  if (days < 7) return '${DateFormat('EEE').format(t)} $time';
  return DateFormat(t.year == now.year ? 'd MMM' : 'd MMM yyyy').format(t);
}

String _bucket(DateTime? t) {
  if (t == null) return 'Today';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'Earlier this week';
  return 'Older';
}

class RecycleBinScreen extends riverpod.ConsumerStatefulWidget {
  final RecycleBinTab initialTab;
  const RecycleBinScreen({super.key, this.initialTab = RecycleBinTab.jobList});

  @override
  riverpod.ConsumerState<RecycleBinScreen> createState() =>
      _RecycleBinScreenState();
}

class _RecycleBinScreenState extends riverpod.ConsumerState<RecycleBinScreen> {
  late RecycleBinTab _tab = widget.initialTab;
  final Map<RecycleBinTab, List<RecycleBinEntry>> _entries = {};
  final Map<RecycleBinTab, Object> _errors = {};
  final Map<RecycleBinTab, StreamSubscription<List<RecycleBinEntry>>> _subs =
      {};
  final Set<String> _selected = {};
  final Set<String> _working = {};
  final TextEditingController _search = TextEditingController();
  String _query = '';
  RecycleBinType? _typeFilter;
  _Sort _sort = _Sort.newest;

  /// Last non-zero selection count, so the bar doesn't read "0 selected"
  /// while it slides away.
  int _barCount = 0;

  @override
  void initState() {
    super.initState();
    for (final t in RecycleBinTab.values) {
      _subscribe(t);
    }
  }

  void _subscribe(RecycleBinTab tab) {
    _subs[tab]?.cancel();
    _subs[tab] = ref.read(recycleBinServiceRiverpod).watchTab(tab).listen(
      (list) {
        if (!mounted) return;
        setState(() {
          _entries[tab] = list;
          _errors.remove(tab);
          if (tab == _tab) {
            final ids = {for (final e in list) e.id};
            _selected.removeWhere((id) => !ids.contains(id));
          }
        });
      },
      onError: (Object e) {
        if (mounted) setState(() => _errors[tab] = e);
      },
    );
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _search.dispose();
    super.dispose();
  }

  void _selectTab(RecycleBinTab tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      _selected.clear();
      _typeFilter = null;
    });
  }

  List<RecycleBinEntry> get _all => _entries[_tab] ?? const [];

  List<RecycleBinEntry> get _visible {
    final search = TextSearch(_query);
    final list = [
      for (final e in _all)
        if ((_typeFilter == null || e.type == _typeFilter) &&
            search.matches([e.label, e.deletedByName, _typeLabel(e.type)]))
          e,
    ];
    switch (_sort) {
      case _Sort.newest:
        break; // the query's order
      case _Sort.expiringSoon:
        list.sort((a, b) => (a.expiresAt ?? DateTime(9999))
            .compareTo(b.expiresAt ?? DateTime(9999)));
      case _Sort.name:
        list.sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    }
    return list;
  }

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
        if (_selected.isNotEmpty) _barCount = _selected.length;
      });

  void _clearSelection() => setState(_selected.clear);

  // ── Actions ────────────────────────────────────────────────────────────────

  void _snack(String text, {bool warn = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentToast()
      ..showToast(SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        width: MediaQuery.sizeOf(context).width > 640 ? 440 : null,
        backgroundColor: warn ? cs.errorContainer : null,
        showCloseIcon: warn,
        closeIconColor: warn ? cs.onErrorContainer : null,
        duration: Duration(seconds: warn ? 8 : 3),
      ));
  }

  Future<void> _restore(List<RecycleBinEntry> entries) async {
    final service = ref.read(recycleBinServiceRiverpod);
    setState(() => _working.addAll(entries.map((e) => e.id)));
    var restored = 0;
    final problems = <String>[];
    for (final e in entries) {
      try {
        await service.restore(e);
        restored++;
      } catch (err) {
        problems.add(_restoreErrorText('"${e.label}"', err));
      }
    }
    if (!mounted) return;
    setState(() {
      _working.removeAll(entries.map((e) => e.id));
      _selected.clear();
    });
    if (problems.isEmpty) {
      _snack(restored == 1
          ? 'Restored "${entries.single.label}"'
          : 'Restored $restored items');
    } else if (problems.length == 1 && restored == 0) {
      _snack(problems.single, warn: true);
    } else {
      await _showProblems(restored, problems);
    }
  }

  Future<void> _showProblems(int restored, List<String> problems) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.info_outline),
        title: Text(restored == 0
            ? 'Nothing was restored'
            : 'Restored $restored, ${problems.length} skipped'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in problems)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('• $p'),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDestructive({
    required String title,
    required String body,
    required String action,
  }) async {
    final cs = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_forever_outlined, color: cs.error),
        title: Text(title),
        content: SizedBox(width: 400, child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _purge(List<RecycleBinEntry> entries) async {
    final n = entries.length;
    if (!await _confirmDestructive(
      title: n == 1 ? 'Delete forever?' : 'Delete $n items forever?',
      body: n == 1
          ? '"${entries.single.label}" will be permanently deleted. '
              'This cannot be undone.'
          : 'These $n items will be permanently deleted. '
              'This cannot be undone.',
      action: 'Delete forever',
    )) {
      return;
    }
    await _runAdmin(
        entries.map((e) => e.id),
        () => ref.read(recycleBinServiceRiverpod).purge([
              for (final e in entries) e.id,
            ]));
  }

  Future<void> _empty() async {
    if (!await _confirmDestructive(
      title: 'Empty ${_tab.label}?',
      body: 'All ${_all.length} items in this part of the Recycle Bin will be '
          'permanently deleted. This cannot be undone.',
      action: 'Empty',
    )) {
      return;
    }
    await _runAdmin(_all.map((e) => e.id),
        () => ref.read(recycleBinServiceRiverpod).emptyTab(_tab));
  }

  Future<void> _runAdmin(
      Iterable<String> ids, Future<int> Function() run) async {
    final idList = ids.toList();
    setState(() => _working.addAll(idList));
    try {
      final n = await run();
      _snack('Permanently deleted $n item${n == 1 ? '' : 's'}');
      if (mounted) setState(_selected.clear);
    } catch (e) {
      _snack(friendlyFirebaseError(e, action: 'delete those items'),
          warn: true);
    } finally {
      if (mounted) setState(() => _working.removeAll(idList));
    }
  }

  Future<void> _showDetails(RecycleBinEntry e, bool isAdmin) async {
    final service = ref.read(recycleBinServiceRiverpod);
    final action = await showDialog<String>(
      context: context,
      builder: (_) => _DetailsDialog(
        entry: e,
        isAdmin: isAdmin,
        canRestore: service.canRestore(e),
      ),
    );
    if (!mounted) return;
    if (action == 'restore') await _restore([e]);
    if (action == 'purge') await _purge([e]);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isAdmin = ref.watch(authRiverpod).isAdmin;
    final service = ref.read(recycleBinServiceRiverpod);
    final total = _entries.values.fold<int>(0, (n, l) => n + l.length);
    final visible = _visible;
    final selectedEntries = [
      for (final e in _all)
        if (_selected.contains(e.id)) e,
    ];
    final showBar = _selected.isNotEmpty;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: cs.surfaceContainerLowest,
          body: SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Header(total: total),
                        _TabStrip(
                          selected: _tab,
                          counts: {
                            for (final t in RecycleBinTab.values)
                              t: _entries[t]?.length,
                          },
                          onSelect: _selectTab,
                        ),
                        _Toolbar(
                          controller: _search,
                          onQuery: (v) => setState(() => _query = v),
                          sort: _sort,
                          onSort: (s) => setState(() => _sort = s),
                          canEmpty: isAdmin && _all.isNotEmpty,
                          onEmpty: _empty,
                          tabLabel: _tab.label,
                        ),
                        _TypeFilters(
                          entries: _all,
                          selected: _typeFilter,
                          onSelect: (t) => setState(() => _typeFilter = t),
                        ),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: KeyedSubtree(
                              key: ValueKey(_tab),
                              child: _content(visible, isAdmin, service),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 20,
                  child: IgnorePointer(
                    ignoring: !showBar,
                    child: AnimatedSlide(
                      offset: showBar ? Offset.zero : const Offset(0, 1.6),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: showBar ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: Center(
                          child: _SelectionBar(
                            count: _barCount,
                            total: visible.length,
                            isAdmin: isAdmin,
                            busy: _working.isNotEmpty,
                            onSelectAll: () => setState(() {
                              _selected.addAll(visible.map((e) => e.id));
                              _barCount = _selected.length;
                            }),
                            onClear: _clearSelection,
                            onRestore: () => _restore(selectedEntries
                                .where(service.canRestore)
                                .toList()),
                            onPurge: () => _purge(selectedEntries),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
      List<RecycleBinEntry> visible, bool isAdmin, RecycleBinService service) {
    final error = _errors[_tab];
    if (error != null && !_entries.containsKey(_tab)) {
      return _MessageState(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load the Recycle Bin",
        body: friendlyFirebaseError(error, action: 'load the Recycle Bin'),
        actionLabel: 'Try again',
        onAction: () {
          setState(() => _errors.remove(_tab));
          _subscribe(_tab);
        },
      );
    }
    if (!_entries.containsKey(_tab)) return const _SkeletonList();
    if (_all.isEmpty) {
      return _MessageState(
        icon: _tab.icon,
        title: 'Nothing deleted from ${_tab.label}',
        body: 'Anything deleted here waits in the Recycle Bin for '
            '${kRecycleBinRetention.inDays} days, so it can be put back.',
      );
    }
    if (visible.isEmpty) {
      return _MessageState(
        icon: Icons.search_off,
        title: 'No matches',
        body: _query.trim().isEmpty
            ? 'Nothing of this type in ${_tab.label}.'
            : 'Nothing in ${_tab.label} matches "${_query.trim()}".',
        actionLabel: 'Clear filters',
        onAction: () => setState(() {
          _search.clear();
          _query = '';
          _typeFilter = null;
        }),
      );
    }

    // Flatten into headers + rows (headers only for the newest-first view).
    final items = <Object>[];
    String? group;
    for (final e in visible) {
      if (_sort == _Sort.newest) {
        final b = _bucket(e.deletedAt);
        if (b != group) {
          group = b;
          items.add(b);
        }
      }
      items.add(e);
    }
    final selectionMode = _selected.isNotEmpty;
    final wide = MediaQuery.sizeOf(context).width >= 640;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 112),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        if (item is String) {
          final count = visible.where((e) => _bucket(e.deletedAt) == item);
          return _GroupHeader(label: item, count: count.length);
        }
        final e = item as RecycleBinEntry;
        return Padding(
          key: ValueKey(e.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: _BinRow(
            entry: e,
            accent: _accent[e.tab]!,
            selected: _selected.contains(e.id),
            selectionMode: selectionMode,
            busy: _working.contains(e.id),
            isAdmin: isAdmin,
            canRestore: service.canRestore(e),
            wide: wide,
            onToggle: () => _toggle(e.id),
            onOpen: () => _showDetails(e, isAdmin),
            onRestore: () => _restore([e]),
            onPurge: () => _purge([e]),
          ),
        );
      },
    );
  }
}

// ── Header & navigation ─────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final int total;
  const _Header({required this.total});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canPop = Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(canPop ? 4 : 16, 12, 16, 8),
      child: Row(
        children: [
          if (canPop) const BackButton(),
          if (canPop) const SizedBox(width: 4),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: cs.secondaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.delete_outline_rounded,
                color: cs.onSecondaryContainer),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recycle Bin',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  MediaQuery.sizeOf(context).width < 640
                      ? 'Kept for ${kRecycleBinRetention.inDays} days, then '
                          'removed for good.'
                      : 'Deleted items wait here for '
                          '${kRecycleBinRetention.inDays} days. Anyone can '
                          'restore them; only admins can delete them for '
                          'good.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (total > 0) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$total item${total == 1 ? '' : 's'}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontFeatures: _tabular,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  final RecycleBinTab selected;
  final Map<RecycleBinTab, int?> counts;
  final ValueChanged<RecycleBinTab> onSelect;
  const _TabStrip({
    required this.selected,
    required this.counts,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: RecycleBinTab.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final t = RecycleBinTab.values[i];
          return _TabPill(
            tab: t,
            count: counts[t],
            selected: t == selected,
            onTap: () => onSelect(t),
          );
        },
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  final RecycleBinTab tab;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  const _TabPill({
    required this.tab,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? cs.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : cs.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(tab.icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  tab.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if ((count ?? 0) > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: selected
                          ? cs.onSecondaryContainer.withValues(alpha: 0.12)
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: fg,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onQuery;
  final _Sort sort;
  final ValueChanged<_Sort> onSort;
  final bool canEmpty;
  final VoidCallback onEmpty;
  final String tabLabel;
  const _Toolbar({
    required this.controller,
    required this.onQuery,
    required this.sort,
    required this.onSort,
    required this.canEmpty,
    required this.onEmpty,
    required this.tabLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (_, value, __) => TextField(
                controller: controller,
                onChanged: onQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  hintText: 'Search by name, type or who deleted it',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            controller.clear();
                            onQuery('');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: cs.primary, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<_Sort>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort_rounded),
            initialValue: sort,
            onSelected: onSort,
            itemBuilder: (_) => [
              _sortItem(_Sort.newest, 'Newest first'),
              _sortItem(_Sort.expiringSoon, 'Expiring soonest'),
              _sortItem(_Sort.name, 'Name A–Z'),
            ],
          ),
          if (canEmpty)
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (_) => onEmpty(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'empty',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        Icon(Icons.delete_forever_outlined, color: cs.error),
                    title: Text('Empty $tabLabel',
                        style: TextStyle(color: cs.error)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  PopupMenuItem<_Sort> _sortItem(_Sort value, String label) =>
      CheckedPopupMenuItem(
        value: value,
        checked: sort == value,
        child: Text(label),
      );
}

class _TypeFilters extends StatelessWidget {
  final List<RecycleBinEntry> entries;
  final RecycleBinType? selected;
  final ValueChanged<RecycleBinType?> onSelect;
  const _TypeFilters({
    required this.entries,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final counts = <RecycleBinType, int>{};
    for (final e in entries) {
      counts[e.type] = (counts[e.type] ?? 0) + 1;
    }
    // Only worth showing when a tab mixes types.
    if (counts.length < 2) return const SizedBox(height: 4);
    final textTheme = Theme.of(context).textTheme;
    Widget chip(String label, int count, bool on, VoidCallback tap) =>
        FilterChip(
          label: Text('$label  $count',
              style: textTheme.labelMedium?.copyWith(fontFeatures: _tabular)),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          shape: const StadiumBorder(),
          onSelected: (_) => tap(),
        );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        children: [
          chip('All', entries.length, selected == null, () => onSelect(null)),
          for (final e in counts.entries) ...[
            const SizedBox(width: 6),
            chip(_typeLabel(e.key), e.value, selected == e.key,
                () => onSelect(selected == e.key ? null : e.key)),
          ],
        ],
      ),
    );
  }
}

// ── Rows ────────────────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  const _GroupHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      fontFeatures: _tabular,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Text('${label.toUpperCase()} · $count', style: style),
    );
  }
}

class _TypeTile extends StatelessWidget {
  final RecycleBinType type;
  final Color accent;
  final double size;
  const _TypeTile({required this.type, required this.accent, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        type.icon,
        size: size * 0.5,
        color: dark ? Color.lerp(accent, Colors.white, 0.35) : accent,
      ),
    );
  }
}

class _ExpiryPill extends StatelessWidget {
  final int? daysLeft;
  const _ExpiryPill({required this.daysLeft});

  @override
  Widget build(BuildContext context) {
    final days = daysLeft;
    if (days == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (Color bg, Color fg, String text) = switch (days) {
      <= 1 => (
          cs.errorContainer,
          cs.onErrorContainer,
          days <= 0 ? 'Removed tonight' : '1 day left'
        ),
      <= 7 => theme.brightness == Brightness.dark
          ? (
              const Color(0xFF4A3410),
              const Color(0xFFFFD08A),
              '$days days left'
            )
          : (
              const Color(0xFFFFE8C2),
              const Color(0xFF7A4B00),
              '$days days left'
            ),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant, '$days days left'),
    };
    return Tooltip(
      message: 'Removed for good after this',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BinRow extends StatefulWidget {
  final RecycleBinEntry entry;
  final Color accent;
  final bool selected;
  final bool selectionMode;
  final bool busy;
  final bool isAdmin;
  final bool canRestore;
  final bool wide;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  const _BinRow({
    required this.entry,
    required this.accent,
    required this.selected,
    required this.selectionMode,
    required this.busy,
    required this.isAdmin,
    required this.canRestore,
    required this.wide,
    required this.onToggle,
    required this.onOpen,
    required this.onRestore,
    required this.onPurge,
  });

  @override
  State<_BinRow> createState() => _BinRowState();
}

class _BinRowState extends State<_BinRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = widget.entry;
    final showCheck = widget.selectionMode || widget.selected || _hover;
    final bg = widget.selected
        ? cs.secondaryContainer.withValues(alpha: 0.55)
        : _hover
            ? cs.surfaceContainerLow
            : cs.surface;
    final border = widget.selected
        ? cs.secondary.withValues(alpha: 0.45)
        : cs.outlineVariant.withValues(alpha: 0.6);

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
          boxShadow: _hover && !widget.selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.busy
                ? null
                : (widget.selectionMode ? widget.onToggle : widget.onOpen),
            onLongPress: widget.busy ? null : widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
              child: Row(
                children: [
                  // The icon tile turns into a checkbox while selecting (or
                  // on hover), so it doubles as the selection target.
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: ScaleTransition(
                          scale: Tween(begin: 0.85, end: 1.0).animate(a),
                          child: child,
                        ),
                      ),
                      child: showCheck
                          ? Checkbox(
                              key: const ValueKey('check'),
                              value: widget.selected,
                              onChanged:
                                  widget.busy ? null : (_) => widget.onToggle(),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5)),
                            )
                          : Center(
                              key: const ValueKey('tile'),
                              child: _TypeTile(
                                  type: e.type, accent: widget.accent),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          e.label,
                          maxLines: widget.wide ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        _Meta(entry: e, compact: !widget.wide),
                        if (!widget.wide) ...[
                          const SizedBox(height: 6),
                          _ExpiryPill(daysLeft: e.daysLeft),
                        ],
                      ],
                    ),
                  ),
                  if (widget.wide) ...[
                    const SizedBox(width: 12),
                    _ExpiryPill(daysLeft: e.daysLeft),
                    const SizedBox(width: 10),
                  ],
                  if (widget.busy)
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (widget.canRestore)
                    widget.wide
                        ? FilledButton.tonalIcon(
                            onPressed: widget.onRestore,
                            icon: const Icon(Icons.restore_rounded, size: 18),
                            label: const Text('Restore'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                            ),
                          )
                        : IconButton.filledTonal(
                            tooltip: 'Restore',
                            onPressed: widget.onRestore,
                            icon: const Icon(Icons.restore_rounded),
                          ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    enabled: !widget.busy,
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) =>
                        v == 'purge' ? widget.onPurge() : widget.onOpen(),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'details',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.info_outline),
                          title: Text('Details'),
                        ),
                      ),
                      if (widget.isAdmin)
                        PopupMenuItem(
                          value: 'purge',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.delete_forever_outlined,
                                color: cs.error),
                            title: Text('Delete forever',
                                style: TextStyle(color: cs.error)),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Gentle entrance; a row being restored dims while it works.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t * (widget.busy ? 0.55 : 1),
        child:
            Transform.translate(offset: Offset(0, (1 - t) * 6), child: child),
      ),
      child: row,
    );
  }
}

class _Meta extends StatelessWidget {
  final RecycleBinEntry entry;

  /// Phone width: drop the type and avatar so the name has room.
  final bool compact;
  const _Meta({required this.entry, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: _tabular,
    );
    final name = entry.deletedByName;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Row(
      children: [
        if (!compact) ...[
          Flexible(
            child: Text(
              _typeLabel(entry.type),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text('  ·  ', style: style),
          CircleAvatar(
            radius: 8,
            backgroundColor: cs.surfaceContainerHighest,
            child: Text(initial,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 9, color: cs.onSurfaceVariant)),
          ),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Text('  ·  ', style: style),
        Tooltip(
          message: entry.deletedAt == null
              ? 'Just now'
              : DateFormat('EEEE d MMMM yyyy, HH:mm').format(entry.deletedAt!),
          child: Text(_relative(entry.deletedAt), style: style),
        ),
      ],
    );
  }
}

// ── Details ─────────────────────────────────────────────────────────────────

class _DetailsDialog extends StatelessWidget {
  final RecycleBinEntry entry;
  final bool isAdmin;
  final bool canRestore;
  const _DetailsDialog({
    required this.entry,
    required this.isAdmin,
    required this.canRestore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = entry;
    final fmt = DateFormat('EEE d MMM yyyy, HH:mm');
    final related = _relatedSummary(e);
    final days = e.daysLeft;

    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: Text(label,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ),
              Expanded(
                child: SelectableText(value,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontFeatures: _tabular)),
              ),
            ],
          ),
        );

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _TypeTile(type: e.type, accent: _accent[e.tab]!, size: 48),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.label,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(_typeLabel(e.type),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: cs.outlineVariant.withValues(alpha: 0.6)),
              const SizedBox(height: 4),
              row(Icons.place_outlined, 'Was in', _whereLabel(e)),
              row(Icons.person_outline, 'Deleted by', e.deletedByName),
              row(Icons.event_outlined, 'Deleted',
                  e.deletedAt == null ? 'Just now' : fmt.format(e.deletedAt!)),
              if (e.expiresAt != null)
                row(
                  Icons.hourglass_bottom_rounded,
                  'Removed for good',
                  '${fmt.format(e.expiresAt!)}'
                      '${days == null ? '' : days == 0 ? ' (tonight)' : ' (in $days day${days == 1 ? '' : 's'})'}',
                ),
              if (related != null)
                row(Icons.link_rounded, 'Comes back with', related),
              if (!canRestore)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    "This kind of item can't be restored from here.",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (isAdmin)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: cs.error),
                      onPressed: () => Navigator.of(context).pop('purge'),
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: const Text('Delete forever'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  if (canRestore) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop('restore'),
                      icon: const Icon(Icons.restore_rounded),
                      label: const Text('Restore'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Selection bar ───────────────────────────────────────────────────────────

class _SelectionBar extends StatelessWidget {
  final int count;
  final int total;
  final bool isAdmin;
  final bool busy;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onRestore;
  final VoidCallback onPurge;
  const _SelectionBar({
    required this.count,
    required this.total,
    required this.isAdmin,
    required this.busy,
    required this.onSelectAll,
    required this.onClear,
    required this.onRestore,
    required this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = cs.onInverseSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: cs.inverseSurface,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Clear selection (Esc)',
                  color: fg,
                  onPressed: onClear,
                  icon: const Icon(Icons.close),
                ),
                Text(
                  '$count selected',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: fg, fontFeatures: _tabular),
                ),
                const SizedBox(width: 4),
                if (count < total)
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: cs.inversePrimary),
                    onPressed: onSelectAll,
                    child: Text('Select all $total',
                        style: const TextStyle(fontFeatures: _tabular)),
                  ),
                const SizedBox(width: 8),
                if (isAdmin) ...[
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Color.lerp(cs.error, Colors.white, 0.45),
                    ),
                    onPressed: busy ? null : onPurge,
                    icon: const Icon(Icons.delete_forever_outlined, size: 18),
                    label: const Text('Delete forever'),
                  ),
                  const SizedBox(width: 6),
                ],
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.inversePrimary,
                    foregroundColor: cs.onPrimaryContainer,
                    minimumSize: const Size(0, 40),
                  ),
                  onPressed: busy ? null : onRestore,
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('Restore'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Loading / empty / error ─────────────────────────────────────────────────

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        itemCount: 6,
        itemBuilder: (_, i) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(180.0 + (i % 3) * 40, 12),
                    const SizedBox(height: 8),
                    bar(120, 10),
                  ],
                ),
              ),
              bar(84, 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 34, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 18),
                FilledButton.tonal(
                    onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
