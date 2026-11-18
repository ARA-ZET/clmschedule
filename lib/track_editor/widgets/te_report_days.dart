// track_editor/widgets/te_report_days.dart
//
// The promoter days a report scan found, grouped by date: tick whole dates
// or single shifts, and choose or add each date's proof photos (the chooser
// is te_photo_picker_dialog.dart). Above them, a note of the folder photos
// that couldn't be put on a date; below, the files that couldn't be placed. Shared by Track Editor Report mode and the Job List
// report page, each passing its own TEReportProvider.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/te_promoter_day.dart';
import '../providers/te_report_provider.dart';
import '../services/te_report_scanner.dart';
import 'te_photo_picker_dialog.dart';

final _dayFmt = DateFormat('EEE d MMM yyyy');

String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// Every date [report] found, oldest first — the order the PDF uses.
class TEReportDayChecklist extends StatelessWidget {
  final TEReportProvider report;
  const TEReportDayChecklist({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final date in report.dates) _DateGroup(date: date, report: report),
      ],
    );
  }
}

/// One date: select every shift on it at once, attach that day's proof
/// photos, then each distributor's shift beneath.
class _DateGroup extends StatelessWidget {
  final DateTime date;
  final TEReportProvider report;
  const _DateGroup({required this.date, required this.report});

  @override
  Widget build(BuildContext context) {
    final shifts = report.days
        .where((d) =>
            d.date.year == date.year &&
            d.date.month == date.month &&
            d.date.day == date.day)
        .toList()
      ..sort((a, b) => a.distributor.name.compareTo(b.distributor.name));
    final allSelected = shifts.every(report.isSelected);
    final someSelected = shifts.any(report.isSelected);
    final handouts =
        shifts.fold<int>(0, (a, d) => a + d.analysis.totalHandouts);
    final photos = report.photosFor(date);
    final chosen = photos.where(report.isChosen).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => report.selectAllForDate(date, !allSelected),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Row(
                children: [
                  Checkbox(
                    value: allSelected ? true : (someSelected ? null : false),
                    tristate: true,
                    // A tristate checkbox steps ticked → partly ticked, so
                    // its own next value would re-select everything. Flip
                    // from what is actually selected instead.
                    onChanged: (_) =>
                        report.selectAllForDate(date, !allSelected),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_dayFmt.format(date),
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600)),
                        Text(
                          '${_plural(shifts.length, 'distributor')} · '
                          '$handouts handouts',
                          style: const TextStyle(
                              fontSize: 11.5, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(58, 0, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      photos.isEmpty
                          ? 'No photos'
                          : '${chosen.length} of ${_plural(photos.length, 'photo')} '
                              'chosen',
                      style: TextStyle(
                        fontSize: 12,
                        color: photos.isNotEmpty && chosen.isEmpty
                            ? Colors.amber.shade900
                            : Colors.black54,
                      ),
                    ),
                    if (photos.isNotEmpty)
                      TextButton.icon(
                        onPressed: () =>
                            showTEPhotoPicker(context, report, onlyDate: date),
                        icon:
                            const Icon(Icons.photo_library_outlined, size: 17),
                        label: const Text('Choose'),
                      ),
                    TextButton.icon(
                      onPressed: () => report.attachPhotos(date),
                      icon: const Icon(Icons.add_a_photo_outlined, size: 17),
                      label: const Text('Add photos'),
                    ),
                  ],
                ),
                if (chosen.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final photo in chosen)
                          _PhotoThumb(
                            photo: photo,
                            onRemove: () => report.setPhotoChosen(photo, false),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final shift in shifts) _ShiftRow(day: shift, report: report),
        ],
      ),
    );
  }
}

class _ShiftRow extends StatelessWidget {
  final TEPromoterDay day;
  final TEReportProvider report;
  const _ShiftRow({required this.day, required this.report});

  @override
  Widget build(BuildContext context) {
    final a = day.analysis;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0EFEC))),
      ),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Checkbox(
            value: report.isSelected(day),
            onChanged: (v) => report.toggleDay(day, v ?? false),
          ),
          Expanded(
            child: Text(day.distributor.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 6),
          Text(
            '${a.totalHandouts} handouts · ${a.distanceKm.toStringAsFixed(1)} km',
            style: const TextStyle(fontSize: 11.5, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final TEProofPhoto photo;
  final VoidCallback onRemove;

  const _PhotoThumb({required this.photo, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: photo.takenAt == null
          ? photo.fileName
          : '${photo.fileName}\n'
              '${DateFormat('d MMM yyyy, HH:mm').format(photo.takenAt!)}',
      // The close button sits over the corner but inside the box: a child
      // hanging outside its parent breaks the semantics tree in a list.
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(photo.bytes,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  cacheWidth: 132,
                  errorBuilder: (_, __, ___) => Container(
                        width: 44,
                        height: 44,
                        color: Colors.grey.shade200,
                        child:
                            const Icon(Icons.broken_image_outlined, size: 18),
                      )),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(10),
              child: const CircleAvatar(
                radius: 9,
                backgroundColor: Colors.black87,
                child: Icon(Icons.close, size: 12, color: Colors.white),
              ),
            ),
          ),
          // Added by hand and still going up to the folder.
          if (photo.url == null && photo.storagePath == null)
            const Positioned(
              bottom: 2,
              right: 8,
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// Folder photos the report can't use yet: ones with no date (put on a
/// date in the photo chooser) and ones that wouldn't download.
class TEReportPhotoNotices extends StatelessWidget {
  final TEReportProvider report;
  const TEReportPhotoNotices({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final undated = report.undatedPhotos;
    final failed = report.failedPhotos;
    if (undated.isEmpty && failed.isEmpty) return const SizedBox.shrink();
    final amber = Colors.amber.shade900;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        border: Border.all(color: Colors.amber.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (undated.isNotEmpty) ...[
            Text(
              '${_plural(undated.length, 'photo')} with no date',
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: amber),
            ),
            const SizedBox(height: 2),
            Text(
              'Neither the file name nor the camera says which day '
              '${undated.length == 1 ? 'it was' : 'they were'} taken, or it '
              'was a day nobody in the report worked. To use one, put it on '
              'a date in the photo chooser.',
              style: TextStyle(fontSize: 11.5, color: amber),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showTEPhotoPicker(context, report),
                icon: const Icon(Icons.photo_library_outlined, size: 17),
                label: const Text('Choose photos'),
              ),
            ),
          ],
          if (failed.isNotEmpty) ...[
            if (undated.isNotEmpty) const SizedBox(height: 6),
            Text(
              "${_plural(failed.length, 'photo')} couldn't be downloaded: "
              '${failed.map((p) => p.split('/').last).join(', ')}',
              style: TextStyle(fontSize: 11.5, color: amber),
            ),
          ],
        ],
      ),
    );
  }
}

/// Files the scan found but couldn't put on a promoter day.
class TEUnresolvedFiles extends StatelessWidget {
  final List<TEUnresolvedReportFile> items;
  const TEUnresolvedFiles({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        border: Border.all(color: Colors.amber.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_plural(items.length, 'file')} could not be placed',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Colors.amber.shade900),
          ),
          const SizedBox(height: 4),
          for (final u in items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${u.matchKey} — '
                '${[
                  if (u.missingDistributor) 'no matching distributor',
                  if (u.missingDate) 'no date found',
                ].join(', ')}',
                style: TextStyle(fontSize: 11.5, color: Colors.amber.shade900),
              ),
            ),
        ],
      ),
    );
  }
}
