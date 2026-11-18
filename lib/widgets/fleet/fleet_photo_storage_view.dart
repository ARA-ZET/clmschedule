// widgets/fleet/fleet_photo_storage_view.dart
//
// Fleet → Photos: a gallery of the inspection photos still stored, how much
// space they take by age, and clearing old ones early (before the 90-day
// automatic delete) when storage needs freeing. Clearing removes the image
// files only; the inspection record stays.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../models/vehicle_inspection.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import '../app_toast.dart';
import 'fleet_dashboard.dart' show FleetColors, FleetPanel;

/// Age choices for "clear photos older than".
const List<int> _ageChoices = [7, 14, 30, 60];

/// Age bands for the usage table: (label, min days, max days exclusive).
const List<(String, int, int?)> _bands = [
  ('Under 7 days', 0, 7),
  ('7–30 days', 7, 30),
  ('30–60 days', 30, 60),
  ('60–90 days', 60, 90),
  ('Over 90 days', 90, null),
];

class FleetPhotoStorageView extends StatefulWidget {
  /// Every inspection (VehicleInspectionService.fetchAll).
  final Future<List<VehicleInspection>> Function() load;

  /// Deletes one inspection's photo files (VehicleInspectionService.clearPhotos).
  final Future<void> Function(VehicleInspection) clear;

  /// Only admins may clear photos; everyone else sees the usage only.
  final bool canClear;

  /// Schedule civil today.
  final DateTime today;

  /// Download URL for a photo path, or null once it is gone
  /// (VehicleInspectionService.photoUrl).
  final Future<String?> Function(String path) photoUrl;

  /// Opens the full inspection.
  final void Function(VehicleInspection) onOpen;

  const FleetPhotoStorageView({
    super.key,
    required this.load,
    required this.clear,
    required this.canClear,
    required this.today,
    required this.photoUrl,
    required this.onOpen,
  });

  @override
  State<FleetPhotoStorageView> createState() => _FleetPhotoStorageViewState();
}

class _FleetPhotoStorageViewState extends State<FleetPhotoStorageView> {
  List<VehicleInspection>? _all;
  Object? _error;

  int _olderThanDays = 30;
  bool _keepPending = true;
  bool _keepDefects = true;

  /// (done, total) while clearing.
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final all = await widget.load();
      if (mounted) setState(() => _all = all);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int _ageDays(VehicleInspection i) {
    final d = DateTime.tryParse(i.date);
    if (d == null) return 0;
    return DateTime.utc(widget.today.year, widget.today.month, widget.today.day)
        .difference(DateTime.utc(d.year, d.month, d.day))
        .inDays;
  }

  /// Inspections whose photos are still stored.
  List<VehicleInspection> get _stored => [
        for (final i in _all ?? const <VehicleInspection>[])
          if (!i.photosCleared && i.photos.values.any((p) => p.path.isNotEmpty))
            i,
      ];

  List<VehicleInspection> get _toClear => [
        for (final i in _stored)
          if (_ageDays(i) > _olderThanDays &&
              !(_keepPending &&
                  i.review.status == InspectionReviewStatus.pending) &&
              !(_keepDefects && i.hasDefects))
            i,
      ];

  DateTime get _cutoff => widget.today.subtract(Duration(days: _olderThanDays));

  Future<void> _clear() async {
    final targets = _toClear;
    if (targets.isEmpty) return;
    final photos = targets.fold<int>(0, (s, i) => s + i.photos.length);
    final bytes = targets.fold<int>(0, (s, i) => s + i.photoBytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Clear inspection photos?'),
        content: Text(
          'This permanently deletes ${_count(photos, 'photo')} '
          '(${_size(bytes)}) from ${_count(targets.length, 'inspection')} '
          'dated before ${DateFormat('d MMM yyyy').format(_cutoff)}.\n\n'
          'The inspections themselves stay: answers, defects, odometer and '
          'fuel are kept. The photos cannot be brought back.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete photos'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _progress = (0, targets.length));
    var failed = 0;
    Object? lastError;
    for (final i in targets) {
      try {
        await widget.clear(i);
      } catch (e) {
        failed++;
        lastError = e;
      }
      if (mounted) {
        setState(() => _progress = (_progress!.$1 + 1, targets.length));
      }
    }
    if (!mounted) return;
    setState(() => _progress = null);
    final cleared = targets.length - failed;
    messenger.showToast(SnackBar(
      backgroundColor: failed == 0 ? Colors.green.shade700 : Colors.orange,
      content: Text(failed == 0
          ? 'Cleared the photos of ${_count(cleared, 'inspection')} '
              '(${_size(bytes)})'
          : 'Cleared $cleared of ${targets.length}; $failed failed — '
              '${friendlyFirebaseError(lastError!, action: 'delete the photos')}'),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Widget usage;
    if (_error != null) {
      usage = Row(children: [
        Expanded(
            child: Text(friendlyFirebaseError(_error!,
                action: 'read the inspections'))),
        TextButton(onPressed: _load, child: const Text('Try again')),
      ]);
    } else if (_all == null) {
      usage = const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    } else {
      usage = _UsageTable(
        stored: _stored,
        ageDays: _ageDays,
      );
    }

    final targets = _all == null ? const <VehicleInspection>[] : _toClear;
    final targetPhotos = targets.fold<int>(0, (s, i) => s + i.photos.length);
    final targetBytes = targets.fold<int>(0, (s, i) => s + i.photoBytes);
    final progress = _progress;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FleetPanel(
              title: 'Photos',
              subtitle: 'Newest first · kept for 90 days, then deleted '
                  'automatically',
              child: _all == null
                  ? const SizedBox.shrink()
                  : _Gallery(
                      stored: _stored,
                      photoUrl: widget.photoUrl,
                      onOpen: widget.onOpen,
                    ),
            ),
            const SizedBox(height: 16),
            FleetPanel(
              title: 'Space used',
              subtitle: 'Photos still stored, by the age of the inspection',
              trailing: IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: progress == null ? _load : null,
              ),
              child: usage,
            ),
            const SizedBox(height: 16),
            FleetPanel(
              title: 'Clear photos early',
              subtitle: 'Free storage before the 90 days are up. Only the '
                  'image files are deleted; the inspections stay.',
              // Checkbox tiles paint their ink on the nearest Material,
              // which the panel's coloured box would otherwise hide.
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Clear photos older than',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final d in _ageChoices)
                        ChoiceChip(
                          label: Text('$d days'),
                          selected: _olderThanDays == d,
                          onSelected: progress != null
                              ? null
                              : (_) => setState(() => _olderThanDays = d),
                        ),
                    ]),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Keep photos still waiting for review'),
                      value: _keepPending,
                      onChanged: progress != null
                          ? null
                          : (v) => setState(() => _keepPending = v ?? true),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title:
                          const Text('Keep photos of inspections with defects'),
                      subtitle: const Text(
                          'Proof of damage, e.g. for an insurance claim'),
                      value: _keepDefects,
                      onChanged: progress != null
                          ? null
                          : (v) => setState(() => _keepDefects = v ?? true),
                    ),
                    const SizedBox(height: 8),
                    if (progress != null) ...[
                      LinearProgressIndicator(
                          value: progress.$2 == 0
                              ? null
                              : progress.$1 / progress.$2),
                      const SizedBox(height: 8),
                      Text('Clearing ${progress.$1} of '
                          '${_count(progress.$2, 'inspection')}…'),
                    ] else
                      Row(children: [
                        Expanded(
                          child: Text(
                            _all == null
                                ? ''
                                : targets.isEmpty
                                    ? 'Nothing to clear before '
                                        '${DateFormat('d MMM yyyy').format(_cutoff)}.'
                                    : 'Clears ${_count(targetPhotos, 'photo')} '
                                        '(${_size(targetBytes)}) from '
                                        '${_count(targets.length, 'inspection')} '
                                        'dated before '
                                        '${DateFormat('d MMM yyyy').format(_cutoff)}.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Tooltip(
                          message: widget.canClear
                              ? ''
                              : 'Only admins can clear photos',
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                backgroundColor: scheme.error,
                                foregroundColor: scheme.onError),
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('Clear photos'),
                            onPressed: widget.canClear && targets.isNotEmpty
                                ? _clear
                                : null,
                          ),
                        ),
                      ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stored photos, one strip per inspection, newest first.
class _Gallery extends StatefulWidget {
  final List<VehicleInspection> stored;
  final Future<String?> Function(String path) photoUrl;
  final void Function(VehicleInspection) onOpen;

  const _Gallery({
    required this.stored,
    required this.photoUrl,
    required this.onOpen,
  });

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  static const _pageSize = 5;
  int _shown = _pageSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = [...widget.stored]..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0
            ? byDate
            : a.vehicleDisplay.compareTo(b.vehicleDisplay);
      });
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('No inspection photos are stored.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    final shown = list.take(_shown).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final i in shown) ...[
        _InspectionStrip(
            inspection: i, photoUrl: widget.photoUrl, onOpen: widget.onOpen),
        const SizedBox(height: 14),
      ],
      if (list.length > shown.length)
        Center(
          child: TextButton.icon(
            icon: const Icon(Icons.expand_more_rounded),
            label: Text('Show more (${list.length - shown.length} left)'),
            onPressed: () => setState(() => _shown += _pageSize),
          ),
        ),
    ]);
  }
}

class _InspectionStrip extends StatelessWidget {
  final VehicleInspection inspection;
  final Future<String?> Function(String path) photoUrl;
  final void Function(VehicleInspection) onOpen;

  const _InspectionStrip({
    required this.inspection,
    required this.photoUrl,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photos = _orderedPhotos(inspection);
    final date = DateTime.tryParse(inspection.date);
    final title = [
      if (date != null) DateFormat('EEE d MMM').format(date),
      inspection.vehicleDisplay,
      if (inspection.driverName.isNotEmpty) inspection.driverName,
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        if (inspection.hasDefects)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.report_problem_rounded,
                size: 18,
                color: inspection.isUnsafe
                    ? FleetColors.critical
                    : FleetColors.serious),
          ),
        TextButton(
          onPressed: () => onOpen(inspection),
          child: const Text('Open'),
        ),
      ]),
      const SizedBox(height: 6),
      SizedBox(
        height: 112,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: photos.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, n) => _GalleryThumb(
            photo: photos[n],
            photoUrl: photoUrl,
            onTap: () => _showPhotoViewer(context,
                photos: photos, start: n, title: title, photoUrl: photoUrl),
          ),
        ),
      ),
      Divider(height: 20, color: scheme.outlineVariant.withValues(alpha: 0.6)),
    ]);
  }
}

List<InspectionPhoto> _orderedPhotos(VehicleInspection i) => [
      for (final p in i.photos.values)
        if (p.path.isNotEmpty) p,
    ]..sort((a, b) {
        final at = a.capturedAt, bt = b.capturedAt;
        if (at != null && bt != null) return at.compareTo(bt);
        return a.slot.compareTo(b.slot);
      });

String _photoCaption(InspectionPhoto p) {
  final label = inspectionSlotLabel(p.slot);
  if (p.capturedAt == null) return label;
  return '$label · ${DateFormat('HH:mm').format(toScheduleCivil(p.capturedAt!))}';
}

class _GalleryThumb extends StatelessWidget {
  final InspectionPhoto photo;
  final Future<String?> Function(String path) photoUrl;
  final VoidCallback onTap;

  const _GalleryThumb({
    required this.photo,
    required this.photoUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 120,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 120,
              height: 90,
              child: _NetworkPhoto(
                  path: photo.path, photoUrl: photoUrl, fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(_photoCaption(photo),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall),
      ]),
    );
  }
}

class _NetworkPhoto extends StatelessWidget {
  final String path;
  final Future<String?> Function(String path) photoUrl;
  final BoxFit fit;

  const _NetworkPhoto({
    required this.path,
    required this.photoUrl,
    required this.fit,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return FutureBuilder<String?>(
      future: photoUrl(path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final url = snap.data;
        final missing = Center(
            child: Icon(Icons.image_not_supported_outlined, color: muted));
        if (url == null) return missing;
        return Image.network(url,
            fit: fit, errorBuilder: (_, __, ___) => missing);
      },
    );
  }
}

/// Full-screen viewer: swipe or arrow through one inspection's photos,
/// pinch/scroll to zoom.
Future<void> _showPhotoViewer(
  BuildContext context, {
  required List<InspectionPhoto> photos,
  required int start,
  required String title,
  required Future<String?> Function(String path) photoUrl,
}) {
  final controller = PageController(initialPage: start);
  var index = start;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        void go(int to) {
          if (to < 0 || to >= photos.length) return;
          controller.animateToPage(to,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }

        return Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(children: [
            PageView.builder(
              controller: controller,
              itemCount: photos.length,
              onPageChanged: (n) => setState(() => index = n),
              itemBuilder: (_, n) => InteractiveViewer(
                maxScale: 5,
                child: _NetworkPhoto(
                    path: photos[n].path,
                    photoUrl: photoUrl,
                    fit: BoxFit.contain),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      '$title\n${_photoCaption(photos[index])} · '
                      '${index + 1} of ${photos.length}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    color: Colors.white,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                ]),
              ),
            ),
            if (index > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filledTonal(
                    tooltip: 'Previous',
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => go(index - 1),
                  ),
                ),
              ),
            if (index < photos.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filledTonal(
                    tooltip: 'Next',
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: () => go(index + 1),
                  ),
                ),
              ),
          ]),
        );
      },
    ),
  ).whenComplete(controller.dispose);
}

class _UsageTable extends StatelessWidget {
  final List<VehicleInspection> stored;
  final int Function(VehicleInspection) ageDays;

  const _UsageTable({required this.stored, required this.ageDays});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalPhotos = stored.fold<int>(0, (s, i) => s + i.photos.length);
    final totalBytes = stored.fold<int>(0, (s, i) => s + i.photoBytes);

    TableRow row(List<String> cells,
            {bool header = false, bool total = false}) =>
        TableRow(
          decoration: header || total
              ? BoxDecoration(
                  border: Border(
                    top: total
                        ? BorderSide(color: scheme.outlineVariant)
                        : BorderSide.none,
                    bottom: header
                        ? BorderSide(color: scheme.outlineVariant)
                        : BorderSide.none,
                  ),
                )
              : null,
          children: [
            for (var c = 0; c < cells.length; c++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Text(
                  cells[c],
                  textAlign: c == 0 ? TextAlign.start : TextAlign.end,
                  style: header
                      ? theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)
                      : theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: total ? FontWeight.w700 : null,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
          ],
        );

    final n = NumberFormat.decimalPattern();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.photo_library_outlined, color: FleetColors.accent(context)),
        const SizedBox(width: 10),
        Text(_size(totalBytes),
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
              'in ${_count(totalPhotos, 'photo')} from '
              '${_count(stored.length, 'inspection')}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
      const SizedBox(height: 12),
      Table(
        columnWidths: const {
          0: FlexColumnWidth(2),
          1: FlexColumnWidth(),
          2: FlexColumnWidth(),
          3: FlexColumnWidth(),
        },
        children: [
          row(['Age', 'Inspections', 'Photos', 'Size'], header: true),
          for (final (label, min, max) in _bands)
            () {
              final inBand = stored.where((i) {
                final a = ageDays(i);
                return a >= min && (max == null || a < max);
              }).toList();
              return row([
                label,
                n.format(inBand.length),
                n.format(inBand.fold<int>(0, (s, i) => s + i.photos.length)),
                _size(inBand.fold<int>(0, (s, i) => s + i.photoBytes)),
              ]);
            }(),
          row([
            'Total',
            n.format(stored.length),
            n.format(totalPhotos),
            _size(totalBytes),
          ], total: true),
        ],
      ),
    ]);
  }
}

String _count(int n, String noun) =>
    '${NumberFormat.decimalPattern().format(n)} $noun${n == 1 ? '' : 's'}';

String _size(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
  if (mb >= 10) return '${mb.round()} MB';
  return '${mb.toStringAsFixed(1)} MB';
}
