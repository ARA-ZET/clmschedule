import 'package:flutter/material.dart';

import '../../models/work_suburb.dart';
import '../models/letterbox_suburb.dart';
import '../providers/letterbox_provider.dart';
import '../theme/letterbox_theme.dart';

/// 2656 -> "2 656". Counts here run to thousands and are read at a glance.
String formatCount(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String statusLabel(LetterboxSuburbStatus status) {
  switch (status) {
    case LetterboxSuburbStatus.unseeded:
      return 'Not seeded';
    case LetterboxSuburbStatus.seeded:
      return 'Seeded';
    case LetterboxSuburbStatus.inProgress:
      return 'In progress';
    case LetterboxSuburbStatus.verified:
      return 'Verified';
  }
}

Color statusColour(LetterboxSuburbStatus status) {
  return switch (status) {
    LetterboxSuburbStatus.unseeded => LetterboxTheme.unseeded,
    LetterboxSuburbStatus.seeded => LetterboxTheme.seeded,
    LetterboxSuburbStatus.inProgress => LetterboxTheme.inProgress,
    LetterboxSuburbStatus.verified => LetterboxTheme.verified,
  };
}

/// The 613 suburbs, with curation status and a progress summary.
class LetterboxSuburbList extends StatefulWidget {
  final LetterboxProvider provider;
  final ValueChanged<WorkSuburb> onSelect;

  const LetterboxSuburbList({
    super.key,
    required this.provider,
    required this.onSelect,
  });

  @override
  State<LetterboxSuburbList> createState() => _LetterboxSuburbListState();
}

class _LetterboxSuburbListState extends State<LetterboxSuburbList> {
  String _query = '';
  LetterboxSuburbStatus? _filter;

  /// Selection mode for bulk verification. Off by default so the common case —
  /// clicking a suburb to open it — stays a single click.
  bool _selecting = false;
  final Set<String> _selected = {};

  void _toggleSelecting() => setState(() {
        _selecting = !_selecting;
        if (!_selecting) _selected.clear();
      });

  Future<void> _verifySelected(List<WorkSuburb> visible) async {
    final provider = widget.provider;
    final chosen = _selected.toList();
    if (chosen.isEmpty) return;

    final withBoxes =
        chosen.where((id) => (provider.metaFor(id)?.count ?? 0) > 0).length;
    final empty = chosen.length - withBoxes;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Verify $withBoxes suburb(s)?'),
        content: Text(
          'Verifying means you have checked these letterboxes and stand behind '
          'the numbers. They become quotable, and they become the benchmark a '
          'distributor is measured against.\n\n'
          '${empty == 0 ? '' : '$empty selected suburb(s) have no letterboxes and will be skipped.\n\n'}'
          'Only do this for suburbs you have actually reviewed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await provider.verifySuburbs(chosen);
    if (mounted) setState(() => _selected.clear());
  }

  Future<void> _unverifySelected() async {
    final provider = widget.provider;
    final chosen = _selected
        .where((id) => provider.statusOf(id) == LetterboxSuburbStatus.verified)
        .toList();
    if (chosen.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unverify ${chosen.length} suburb(s)?'),
        content: const Text(
          'Their letterboxes stay exactly as they are — only the sign-off is '
          'removed. They stop counting towards the trusted total, and any '
          'quote or distributor review covering them will flag them as '
          'uncurated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unverify'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await provider.unverifySuburbs(chosen);
    if (mounted) setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final scheme = Theme.of(context).colorScheme;

    if (provider.isLoadingCatalogue) {
      return const Center(child: CircularProgressIndicator());
    }
    // An error is shown as a banner above the list rather than instead of it:
    // curation status can fail to load while the suburb boundaries are
    // perfectly fine, and hiding all 613 suburbs behind that would be wrong.
    if (provider.error != null && provider.suburbs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(LetterboxTheme.s4),
        child: Text(provider.error!),
      );
    }

    final query = _query.trim().toLowerCase();
    final visible = provider.suburbs.where((s) {
      if (query.isNotEmpty && !s.name.toLowerCase().contains(query)) {
        return false;
      }
      if (_filter != null && provider.statusOf(s.id) != _filter) return false;
      return true;
    }).toList();

    return ColoredBox(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (provider.error != null) _ErrorBanner(message: provider.error!),
          _Header(provider: provider),
          _SelectionBar(
            selecting: _selecting,
            selectedCount: _selected.length,
            onToggleMode: _toggleSelecting,
            onSelectAllShown: () =>
                setState(() => _selected.addAll(visible.map((s) => s.id))),
            onClear: () => setState(_selected.clear),
            onVerify: () => _verifySelected(visible),
            onUnverify: _unverifySelected,
            verifiedInSelection: _selected
                .where((id) =>
                    provider.statusOf(id) == LetterboxSuburbStatus.verified)
                .length,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                LetterboxTheme.s3, 0, LetterboxTheme.s3, LetterboxTheme.s2),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                hintText: 'Find a suburb',
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 17),
                        onPressed: () => setState(() => _query = ''),
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: LetterboxTheme.s3),
              children: [
                _filterChip(null, 'All', provider.suburbs.length),
                for (final s in LetterboxSuburbStatus.values)
                  _filterChip(
                    s,
                    statusLabel(s),
                    provider.statusCounts[s] ?? 0,
                  ),
              ],
            ),
          ),
          const SizedBox(height: LetterboxTheme.s2),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      'No suburbs match',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(LetterboxTheme.s2, 0,
                        LetterboxTheme.s2, LetterboxTheme.s4),
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final suburb = visible[i];
                      return _SuburbRow(
                        suburb: suburb,
                        meta: provider.metaFor(suburb.id),
                        status: provider.statusOf(suburb.id),
                        selected: provider.selected?.id == suburb.id,
                        selecting: _selecting,
                        checked: _selected.contains(suburb.id),
                        onTap: () {
                          if (_selecting) {
                            setState(() {
                              if (!_selected.remove(suburb.id)) {
                                _selected.add(suburb.id);
                              }
                            });
                          } else {
                            widget.onSelect(suburb);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(LetterboxSuburbStatus? status, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(right: LetterboxTheme.s2),
      child: FilterChip(
        label: Text('$label  $count'),
        selected: _filter == status,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => setState(() => _filter = status),
      ),
    );
  }
}

/// Progress across the whole job, which is the number you want when the task
/// is 613 suburbs long.
class _Header extends StatelessWidget {
  final LetterboxProvider provider;
  const _Header({required this.provider});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = provider.suburbs.length;
    final done = provider.verifiedCount;
    final fraction = total == 0 ? 0.0 : done / total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(LetterboxTheme.s4, LetterboxTheme.s4,
          LetterboxTheme.s4, LetterboxTheme.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatCount(provider.verifiedLetterboxTotal),
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.05,
                  letterSpacing: -1,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: LetterboxTheme.s2),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'trusted letterboxes',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: LetterboxTheme.s3),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: const AlwaysStoppedAnimation(LetterboxTheme.verified),
            ),
          ),
          const SizedBox(height: LetterboxTheme.s2),
          Text(
            '$done of $total suburbs verified',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SuburbRow extends StatelessWidget {
  final WorkSuburb suburb;
  final LetterboxSuburb? meta;
  final LetterboxSuburbStatus status;
  final bool selected;
  final bool selecting;
  final bool checked;
  final VoidCallback onTap;

  const _SuburbRow({
    required this.suburb,
    required this.meta,
    required this.status,
    required this.selected,
    required this.selecting,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = meta?.count ?? 0;
    final highlight = selecting ? checked : selected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: highlight ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: LetterboxTheme.s3, vertical: LetterboxTheme.s2 + 2),
            child: Row(
              children: [
                if (selecting) ...[
                  Icon(
                    checked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: checked ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: LetterboxTheme.s2 + 2),
                ],
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColour(status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: LetterboxTheme.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suburb.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              highlight ? FontWeight.w600 : FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        count == 0
                            ? statusLabel(status)
                            : '${formatCount(count)} letterboxes',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (meta?.hasNewCandidates ?? false)
                  Tooltip(
                    message: 'New GPS drops to review',
                    child: Icon(Icons.circle_notifications_rounded,
                        size: 17, color: scheme.primary),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Enters and drives multi-select for bulk verification.
///
/// Kept out of the way until asked for: opening a suburb is the common action
/// and must stay one click.
class _SelectionBar extends StatelessWidget {
  final bool selecting;
  final int selectedCount;
  final VoidCallback onToggleMode;
  final VoidCallback onSelectAllShown;
  final VoidCallback onClear;
  final VoidCallback onVerify;
  final VoidCallback onUnverify;
  final int verifiedInSelection;

  const _SelectionBar({
    required this.selecting,
    required this.selectedCount,
    required this.onToggleMode,
    required this.onSelectAllShown,
    required this.onClear,
    required this.onVerify,
    required this.onUnverify,
    required this.verifiedInSelection,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            LetterboxTheme.s3, 0, LetterboxTheme.s3, LetterboxTheme.s2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onToggleMode,
            icon: const Icon(Icons.checklist_rounded, size: 17),
            label: const Text('Select to verify'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding:
                  const EdgeInsets.symmetric(horizontal: LetterboxTheme.s2),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(
          LetterboxTheme.s3, 0, LetterboxTheme.s3, LetterboxTheme.s2),
      padding: const EdgeInsets.all(LetterboxTheme.s2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(LetterboxTheme.radiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: LetterboxTheme.s1),
              Text(
                '$selectedCount selected',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton(
                onPressed: onSelectAllShown,
                style:
                    TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('All shown'),
              ),
              TextButton(
                onPressed: selectedCount == 0 ? null : onClear,
                style:
                    TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('None'),
              ),
              IconButton(
                onPressed: onToggleMode,
                icon: const Icon(Icons.close_rounded, size: 17),
                tooltip: 'Exit selection',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: LetterboxTheme.s1),
          FilledButton.icon(
            onPressed: selectedCount == 0 ? null : onVerify,
            icon: const Icon(Icons.verified_outlined, size: 17),
            label: Text('Verify $selectedCount'),
          ),
          if (verifiedInSelection > 0) ...[
            const SizedBox(height: LetterboxTheme.s1),
            OutlinedButton.icon(
              onPressed: onUnverify,
              icon: const Icon(Icons.remove_moderator_outlined, size: 17),
              label: Text('Unverify $verifiedInSelection'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.all(LetterboxTheme.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded,
              size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: LetterboxTheme.s2),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
