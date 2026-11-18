// track_editor/widgets/te_photo_picker_dialog.dart
//
// Choosing which photos go into the Flyer Handout Report. A job folder can
// hold far more traffic-light photos than the report wants, so none of the
// folder's photos is in the PDF until it is chosen here: every date's photos
// in a grid, tap to put one in or take it out, open one large to judge it.
// Photos with no date are put on a date here too. Building the PDF opens
// this first; each date's "Choose" opens it for that date alone.
//
// The choices are kept here and handed to the report in one go as the
// dialog closes, however it closes. Besides being one change rather than
// dozens, that keeps the page behind from growing while the dialog covers
// it: Flutter's semantics tree trips over a scrolled list that changes size
// under a dialog after a tap inside it.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/cloud_archive_service.dart' show formatBytes;
import '../models/te_promoter_day.dart';
import '../providers/te_report_provider.dart';

final _dayFmt = DateFormat('EEE d MMM yyyy');
final _shortDayFmt = DateFormat('EEE d MMM');
final _timeFmt = DateFormat('HH:mm');

String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// Shows the photos of [report] to choose from — only [onlyDate]'s when
/// given, otherwise every date with a ticked shift, plus the undated ones.
/// The choices are kept however the dialog closes. True when closed with
/// [doneLabel], false when closed with [cancelLabel] or dismissed.
Future<bool> showTEPhotoPicker(
  BuildContext context,
  TEReportProvider report, {
  DateTime? onlyDate,
  String doneLabel = 'Done',
  String? cancelLabel,
}) async {
  final choices = _Choices(report);
  try {
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => _PhotoPickerDialog(
        report: choices,
        onlyDate: onlyDate,
        doneLabel: doneLabel,
        cancelLabel: cancelLabel,
      ),
    );
    return go ?? false;
  } finally {
    report.applyPhotoChoices(
        assigned: choices.assigned, chosen: choices.chosen);
    choices.dispose();
  }
}

/// The choices being made, over [report]'s photos, until the dialog closes.
class _Choices extends ChangeNotifier {
  final TEReportProvider source;
  final Set<TEProofPhoto> chosen;
  final Map<TEProofPhoto, DateTime> assigned = {};

  _Choices(this.source)
      : chosen = {
          for (final list in source.photosByDate.values)
            for (final p in list)
              if (source.isChosen(p)) p,
        };

  List<TEPromoterDay> get selectedDays => source.selectedDays;
  List<DateTime> get dates => source.dates;

  List<TEProofPhoto> photosFor(DateTime date) {
    final moved = [
      for (final MapEntry(key: p, value: d) in assigned.entries)
        if (d == date) p,
    ];
    if (moved.isEmpty) return source.photosFor(date);
    return [...source.photosFor(date), ...moved]..sort((a, b) =>
        (a.takenAt ?? DateTime(9999)).compareTo(b.takenAt ?? DateTime(9999)));
  }

  List<TEProofPhoto> get undatedPhotos => [
        for (final p in source.undatedPhotos)
          if (!assigned.containsKey(p)) p,
      ];

  bool isChosen(TEProofPhoto photo) => chosen.contains(photo);

  void setPhotoChosen(TEProofPhoto photo, bool on) {
    if (on && undatedPhotos.contains(photo)) return;
    if (on ? chosen.add(photo) : chosen.remove(photo)) notifyListeners();
  }

  void setChosenForDate(DateTime date, bool on) {
    final photos = photosFor(date);
    on ? chosen.addAll(photos) : chosen.removeAll(photos);
    notifyListeners();
  }

  /// Puts an undated photo on [date] and chooses it.
  void assignPhoto(TEProofPhoto photo, DateTime date) {
    assigned[photo] = DateTime(date.year, date.month, date.day);
    chosen.add(photo);
    notifyListeners();
  }
}

class _PhotoPickerDialog extends StatelessWidget {
  final _Choices report;
  final DateTime? onlyDate;
  final String doneLabel;
  final String? cancelLabel;

  const _PhotoPickerDialog({
    required this.report,
    required this.onlyDate,
    required this.doneLabel,
    required this.cancelLabel,
  });

  /// The dates whose photos can go in: [onlyDate], or each date at least
  /// one ticked shift is on (photos on other dates would not print).
  List<DateTime> get _dates {
    if (onlyDate != null) {
      return [DateTime(onlyDate!.year, onlyDate!.month, onlyDate!.day)];
    }
    final ticked = {
      for (final d in report.selectedDays)
        DateTime(d.date.year, d.date.month, d.date.day),
    };
    return report.dates.where(ticked.contains).toList();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final content = ListenableBuilder(
      listenable: report,
      builder: (context, _) => _content(context, narrow),
    );
    if (narrow) return Dialog.fullscreen(child: content);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 860),
        child: content,
      ),
    );
  }

  Widget _content(BuildContext context, bool narrow) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dates = _dates;
    final undated =
        onlyDate == null ? report.undatedPhotos : const <TEProofPhoto>[];
    final dated = [for (final d in dates) ...report.photosFor(d)];
    final chosen = dated.where(report.isChosen).toList();
    final bytes = chosen.fold<int>(0, (n, p) => n + p.bytes.length);
    final gutter = narrow ? 16.0 : 24.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 18, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      onlyDate == null
                          ? 'Choose the photos for the report'
                          : 'Photos for ${_dayFmt.format(dates.first)}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap a photo to put it in the report or take it out. '
                      'Only the chosen ones go into the PDF.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: dated.isEmpty && undated.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No photos found for these days. Put them in the job '
                      'folder beside the tracks and scan again, or use Add '
                      'photos on a date.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    for (final date in dates)
                      if (report.photosFor(date).isNotEmpty)
                        ..._dateSlivers(context, date, gutter),
                    if (undated.isNotEmpty)
                      ..._undatedSlivers(context, undated, dates, gutter),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 10, gutter, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  chosen.isEmpty
                      ? 'No photos chosen'
                      : '${_plural(chosen.length, 'photo')} chosen · '
                          'about ${formatBytes(bytes)} in the PDF',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (cancelLabel != null) ...[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(cancelLabel!),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(doneLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _dateSlivers(
      BuildContext context, DateTime date, double gutter) {
    final theme = Theme.of(context);
    final photos = report.photosFor(date);
    final chosen = photos.where(report.isChosen).length;
    final all = chosen == photos.length;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 8),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: _dayFmt.format(date),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(
                      text: '  $chosen of ${photos.length} chosen',
                      style:
                          TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ]),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => report.setChosenForDate(date, !all),
                child: Text(all ? 'Clear' : 'Choose all'),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: photos.length,
          itemBuilder: (context, i) {
            final photo = photos[i];
            return _PickTile(
              photo: photo,
              chosen: report.isChosen(photo),
              onTap: () =>
                  report.setPhotoChosen(photo, !report.isChosen(photo)),
              onZoom: () => _showLarge(context, report, photo),
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _undatedSlivers(BuildContext context, List<TEProofPhoto> photos,
      List<DateTime> dates, double gutter) {
    final theme = Theme.of(context);
    final amber = Colors.amber.shade900;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 8),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('No date — ${_plural(photos.length, 'photo')}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600, color: amber)),
              Text(
                'Neither the file name nor the camera says which day these '
                'were taken, or it was a day nobody in the report worked. '
                'Tap one to put it on a date; that also chooses it.',
                style: theme.textTheme.bodySmall?.copyWith(color: amber),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: photos.length,
          itemBuilder: (context, i) {
            final photo = photos[i];
            return PopupMenuButton<DateTime>(
              tooltip: 'Put on a date',
              enabled: dates.isNotEmpty,
              onSelected: (d) => report.assignPhoto(photo, d),
              itemBuilder: (_) => [
                for (final d in dates)
                  PopupMenuItem(value: d, child: Text(_shortDayFmt.format(d))),
              ],
              child: _PickTile(
                photo: photo,
                chosen: false,
                onZoom: () => _showLarge(context, report, photo),
              ),
            );
          },
        ),
      ),
    ];
  }
}

/// One photo in the grid: full colour with a tick when chosen, faded when
/// not.
class _PickTile extends StatelessWidget {
  final TEProofPhoto photo;
  final bool chosen;
  final VoidCallback? onTap;
  final VoidCallback onZoom;

  const _PickTile({
    required this.photo,
    required this.chosen,
    required this.onZoom,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = Image.memory(
      photo.bytes,
      fit: BoxFit.cover,
      cacheWidth: 320,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
    final tile = Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: chosen ? 1 : 0.55,
            child: image,
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: chosen ? scheme.primary : scheme.outlineVariant,
              width: chosen ? 3 : 1,
            ),
          ),
        ),
        Positioned(
          top: 6,
          left: 6,
          child: CircleAvatar(
            radius: 12,
            backgroundColor: chosen ? scheme.primary : Colors.black38,
            child: Icon(chosen ? Icons.check : Icons.circle_outlined,
                size: 16, color: Colors.white),
          ),
        ),
        if (photo.takenAt != null)
          Positioned(
            left: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_timeFmt.format(photo.takenAt!),
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
        Positioned(
          right: 2,
          bottom: 2,
          child: IconButton(
            tooltip: 'View larger',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
            icon: const Icon(Icons.zoom_in, size: 18, color: Colors.white),
            onPressed: onZoom,
          ),
        ),
      ],
    );
    return Tooltip(
      message: photo.fileName,
      waitDuration: const Duration(milliseconds: 600),
      child: onTap == null
          ? tile
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: tile,
            ),
    );
  }
}

/// [photo] as big as the screen allows, to zoom and pan, with its choose
/// button.
void _showLarge(BuildContext context, _Choices report, TEProofPhoto photo) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: report,
        builder: (context, _) {
          final undated = report.undatedPhotos.contains(photo);
          final chosen = report.isChosen(photo);
          return Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Image.memory(photo.bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          photo.fileName,
                          if (photo.takenAt != null)
                            DateFormat('d MMM yyyy, HH:mm')
                                .format(photo.takenAt!),
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                    if (!undated)
                      FilledButton.icon(
                        onPressed: () => report.setPhotoChosen(photo, !chosen),
                        icon: Icon(chosen ? Icons.check : Icons.add, size: 18),
                        label: Text(chosen ? 'Chosen' : 'Choose'),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
