// track_editor/widgets/te_processing_panel.dart
//
// "Processing" mode left-panel: pick multiple GPX files, auto-match
// Track/Waypoints pairs, open each pair as a tab, and manually pair leftovers.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/te_gpx_file_entry.dart';
import '../providers/te_processing_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../../providers/schedule_provider.dart';

class TEProcessingPanel extends riverpod.ConsumerWidget {
  const TEProcessingPanel({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final proc = ref.watch(teProcessingRiverpod);
    final tabsProvider = ref.read(teTabsRiverpod);
    final scheduleProvider = ref.read(scheduleRiverpod);

    final pairs = proc.matchedPairs;
    final unmatched = proc.unmatchedFiles;
    final hasFiles = proc.files.isNotEmpty;

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          const Row(
            spacing: 8,
            children: [
              Icon(Icons.settings_suggest, color: Colors.blueGrey, size: 20),
              Text(
                'Processing',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Divider(height: 1),

          // ── Pick files ──────────────────────────────────────────────────
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: proc.loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.upload_file, size: 18),
                  label: Text(proc.loading && proc.progressMessage.isNotEmpty
                      ? proc.progressMessage
                      : 'Select GPX Files'),
                  onPressed: (proc.loading || proc.openingTabs)
                      ? null
                      : () => proc.pickFiles(),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade600,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              if (hasFiles)
                IconButton.outlined(
                  onPressed: (proc.loading || proc.openingTabs)
                      ? null
                      : proc.clearFiles,
                  icon: const Icon(Icons.clear_all, size: 20),
                  tooltip: 'Clear all files',
                  style: IconButton.styleFrom(
                    side: BorderSide(color: Colors.red.shade200),
                    foregroundColor: Colors.red.shade400,
                  ),
                ),
            ],
          ),

          // ── Progress indicator during tab opening ───────────────────────
          if (proc.openingTabs) ...[
            Column(
              spacing: 6,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  spacing: 8,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    Text(
                      proc.progressMessage,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.blueGrey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: proc.openProgress,
                    minHeight: 6,
                    backgroundColor: Colors.blueGrey.shade100,
                    valueColor: AlwaysStoppedAnimation(Colors.green.shade600),
                  ),
                ),
              ],
            ),
          ],

          // ── Nothing staged yet ──────────────────────────────────────────
          if (!hasFiles)
            _EmptyHint(
              text:
                  'Select Track and Waypoints .gpx files.\nMatching pairs will be opened together as one tab.',
            ),

          // ── Matched pairs ───────────────────────────────────────────────
          if (pairs.isNotEmpty && !proc.tabsOpened && !proc.openingTabs) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _SectionLabel(
                    icon: Icons.check_circle_outline,
                    color: Colors.green.shade600,
                    label:
                        '${pairs.length} matched pair${pairs.length == 1 ? '' : 's'}'),
                TextButton.icon(
                  onPressed: () async {
                    await proc.openMatchedTabs(tabsProvider, scheduleProvider);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              'Opened ${pairs.length} tab${pairs.length == 1 ? '' : 's'}'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.tab, size: 16),
                  label: const Text('Open Tabs'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.green.shade700,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ],
            ),
            ...pairs.map((pair) => _MatchedPairTile(
                  pair: pair,
                  onOpen: () async {
                    await proc.openMatchedTabs(tabsProvider, scheduleProvider);
                  },
                )),
          ],

          // ── Unmatched files ─────────────────────────────────────────────
          if (unmatched.isNotEmpty) ...[
            _SectionLabel(
                icon: Icons.warning_amber_outlined,
                color: Colors.orange.shade700,
                label:
                    '${unmatched.length} unmatched file${unmatched.length == 1 ? '' : 's'}'),
            ...unmatched.map(
              (f) => _UnmatchedFileTile(
                entry: f,
                unmatched: unmatched,
                onManualPair: (track, wpts) async {
                  await proc.addManualPair(
                      track, wpts, tabsProvider, scheduleProvider);
                },
                onRemove: () => proc.removeFile(f),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;

  const _SectionLabel(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 6,
      children: [
        Icon(icon, size: 16, color: color),
        Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w600, color: color, fontSize: 13)),
      ],
    );
  }
}

// ── Empty state hint ──────────────────────────────────────────────────────────
class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueGrey.shade100),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: Colors.black54)),
    );
  }
}

// ── One matched pair row ──────────────────────────────────────────────────────
class _MatchedPairTile extends StatelessWidget {
  final TEGpxMatchedPair pair;
  final Future<void> Function() onOpen;

  const _MatchedPairTile({required this.pair, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.shade100),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            pair.tabTitle,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
          Row(
            spacing: 8,
            children: [
              _FileBadge(
                  icon: Icons.timeline,
                  label: pair.trackFile.filename,
                  color: Colors.blue.shade600),
              _FileBadge(
                  icon: Icons.place,
                  label: pair.waypointsFile.filename,
                  color: Colors.teal.shade600),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Small coloured file badge ─────────────────────────────────────────────────
class _FileBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _FileBadge(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          spacing: 4,
          children: [
            Icon(icon, size: 12, color: color),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 10, color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── One unmatched file row ─────────────────────────────────────────────────────
class _UnmatchedFileTile extends StatelessWidget {
  final TEGpxFileEntry entry;
  final List<TEGpxFileEntry> unmatched;
  final Future<void> Function(TEGpxFileEntry track, TEGpxFileEntry wpts)
      onManualPair;
  final VoidCallback onRemove;

  const _UnmatchedFileTile({
    required this.entry,
    required this.unmatched,
    required this.onManualPair,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final typeLabel = switch (entry.type) {
      TEGpxFileType.track => 'Track',
      TEGpxFileType.waypoints => 'Waypoints',
      TEGpxFileType.unknown => 'Unknown',
    };
    final typeColor = switch (entry.type) {
      TEGpxFileType.track => Colors.blue.shade600,
      TEGpxFileType.waypoints => Colors.teal.shade600,
      TEGpxFileType.unknown => Colors.grey,
    };

    return Container(
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade100),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        spacing: 8,
        children: [
          // Type chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(typeLabel,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: typeColor)),
          ),
          // Filename
          Expanded(
            child: Text(
              entry.filename,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Manual match button
          IconButton(
            icon: const Icon(Icons.compare_arrows, size: 18),
            tooltip: 'Match manually',
            color: Colors.orange.shade700,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _showManualMatchDialog(context),
          ),
          // Remove
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Remove file',
            color: Colors.grey.shade500,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }

  void _showManualMatchDialog(BuildContext context) {
    // Find candidates of the opposite type
    final oppositeType = entry.type == TEGpxFileType.track
        ? TEGpxFileType.waypoints
        : TEGpxFileType.track;
    final candidates = unmatched.where((f) => f.type == oppositeType).toList();

    showDialog<void>(
      context: context,
      builder: (_) => _ManualMatchDialog(
        source: entry,
        candidates: candidates,
        onMatched: onManualPair,
      ),
    );
  }
}

// ── Manual match dialog ───────────────────────────────────────────────────────
class _ManualMatchDialog extends StatefulWidget {
  final TEGpxFileEntry source;
  final List<TEGpxFileEntry> candidates;
  final Future<void> Function(TEGpxFileEntry track, TEGpxFileEntry wpts)
      onMatched;

  const _ManualMatchDialog({
    required this.source,
    required this.candidates,
    required this.onMatched,
  });

  @override
  State<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends State<_ManualMatchDialog> {
  TEGpxFileEntry? _selected;

  @override
  Widget build(BuildContext context) {
    final isTrackSource = widget.source.type == TEGpxFileType.track;
    final oppositeLabel = isTrackSource ? 'Waypoints' : 'Track';

    return AlertDialog(
      title: const Row(
        spacing: 8,
        children: [
          Icon(Icons.compare_arrows, color: Colors.blueGrey),
          Text('Manual Match'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            // Source file
            _DialogFileRow(
              label: isTrackSource ? 'Track' : 'Waypoints',
              filename: widget.source.filename,
              color: Colors.blueGrey.shade600,
            ),
            Row(
              children: [
                Expanded(child: Divider(color: Colors.grey.shade300)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_downward,
                      color: Colors.grey.shade400, size: 16),
                ),
                Expanded(child: Divider(color: Colors.grey.shade300)),
              ],
            ),
            // Pick the opposite
            Text('Pick a $oppositeLabel file to pair with:',
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
            if (widget.candidates.isEmpty)
              Text(
                'No unmatched $oppositeLabel files available.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              )
            else
              ...widget.candidates.map(
                (c) => RadioListTile<TEGpxFileEntry>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.filename, style: const TextStyle(fontSize: 12)),
                  value: c,
                  groupValue: _selected,
                  onChanged: (v) => setState(() => _selected = v),
                  activeColor: Colors.blueGrey,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _selected == null
              ? null
              : () async {
                  Navigator.of(context).pop();
                  final track = isTrackSource ? widget.source : _selected!;
                  final wpts = isTrackSource ? _selected! : widget.source;
                  await widget.onMatched(track, wpts);
                },
          icon: const Icon(Icons.tab, size: 16),
          label: const Text('Open as Tab'),
          style:
              FilledButton.styleFrom(backgroundColor: Colors.blueGrey.shade600),
        ),
      ],
    );
  }
}

class _DialogFileRow extends StatelessWidget {
  final String label;
  final String filename;
  final Color color;

  const _DialogFileRow(
      {required this.label, required this.filename, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        spacing: 8,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
          Expanded(
            child: Text(filename,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
