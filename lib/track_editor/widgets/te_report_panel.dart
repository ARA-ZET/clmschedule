// track_editor/widgets/te_report_panel.dart
//
// The Report-mode left panel (shown full-width — Report mode has no map):
// pick a Storage folder, review the promoter days the scan found grouped by
// date, choose "full report" or a hand-picked subset, optionally attach
// proof-of-handout photos per date, then generate the PDF.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';
import '../../providers/schedule_provider.dart';
import '../models/te_promoter_day.dart';
import '../providers/te_report_provider.dart';
import '../services/te_place_names.dart';
import '../services/te_report_pdf.dart';
import '../services/te_report_scanner.dart';
import '../pages/te_report_preview_page.dart';
import 'te_folder_picker_dialog.dart';

final _dayFmt = DateFormat('EEE d MMM yyyy');

class TEReportPanel extends riverpod.ConsumerWidget {
  const TEReportPanel({super.key});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final report = ref.watch(teReportRiverpod);

    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(report: report),
            const SizedBox(height: 16),
            if (report.status == TEReportScanStatus.scanning)
              const _ScanningIndicator()
            else if (report.status == TEReportScanStatus.error)
              _ErrorBanner(
                  message: report.errorMessage ?? 'Something went wrong')
            else if (report.status == TEReportScanStatus.done) ...[
              _TeamSummary(days: report.selectedDays),
              const SizedBox(height: 20),
              if (report.days.isEmpty)
                const _EmptyFolderNotice()
              else ...[
                _SelectionModeToggle(report: report),
                const SizedBox(height: 12),
                _DayChecklist(report: report),
              ],
              if (report.unresolved.isNotEmpty) ...[
                const SizedBox(height: 16),
                _UnresolvedList(items: report.unresolved),
              ],
              const SizedBox(height: 20),
              _GenerateButton(report: report),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// HEADER
// ════════════════════════════════════════════════════════════════════════════

class _Header extends riverpod.ConsumerWidget {
  final TEReportProvider report;
  const _Header({required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Client report',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(
                report.hasFolder
                    ? report.folderPath!
                    : 'Pick a Storage folder to scan for distributor GPX files.',
                style: TextStyle(
                    fontSize: 12.5,
                    color: report.hasFolder ? Colors.black87 : Colors.black54),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final path = await showTEFolderPicker(context);
            if (path == null) return;
            if (!context.mounted) return;
            final distributors = ref.read(scheduleRiverpod).distributors;
            await ref
                .read(teReportRiverpod)
                .scanFolder(path, distributors: distributors);
          },
          icon: const Icon(Icons.folder_open, size: 18),
          label: Text(report.hasFolder ? 'Change folder' : 'Choose folder'),
        ),
      ],
    );
  }
}

class _ScanningIndicator extends StatelessWidget {
  const _ScanningIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Scanning folder for GPX files…',
              style: TextStyle(color: Colors.black54)),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        border: Border.all(color: Colors.red.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style:
                      TextStyle(color: Colors.red.shade800, fontSize: 12.5))),
        ],
      ),
    );
  }
}

class _EmptyFolderNotice extends StatelessWidget {
  const _EmptyFolderNotice();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'No promoter days were found in that folder — every GPX in it '
      'either had no distributor match or no date.',
      style: TextStyle(color: Colors.black54, fontSize: 12.5),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TEAM SUMMARY
// ════════════════════════════════════════════════════════════════════════════

class _TeamSummary extends StatelessWidget {
  final List<TEPromoterDay> days;
  const _TeamSummary({required this.days});

  @override
  Widget build(BuildContext context) {
    final totalHandouts =
        days.fold<int>(0, (a, d) => a + d.analysis.totalHandouts);
    final promoterDays = days.length;
    final distinctDates = days.map((d) => d.date).toSet().toList()..sort();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Whole team',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 10,
            children: [
              _StatColumn(value: '$totalHandouts', label: 'Handouts'),
              _StatColumn(value: '$promoterDays', label: 'Promoter days'),
              _StatColumn(
                  value: '${distinctDates.length}',
                  label:
                      distinctDates.length == 1 ? 'Day worked' : 'Days worked'),
            ],
          ),
          if (distinctDates.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              distinctDates.map(_dayFmt.format).join('  ·  '),
              style: const TextStyle(fontSize: 11.5, color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String value;
  final String label;
  const _StatColumn({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        Text(label,
            style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SELECTION MODE
// ════════════════════════════════════════════════════════════════════════════

class _SelectionModeToggle extends riverpod.ConsumerWidget {
  final TEReportProvider report;
  const _SelectionModeToggle({required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    Widget seg(String label, bool selected, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            color: selected ? Colors.blueGrey : Colors.transparent,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.black54,
              ),
            ),
          ),
        );

    final selectedCount = report.selectedDays.length;
    final allSelected = selectedCount == report.days.length;
    final noneSelected = selectedCount == 0;
    final quick = OutlinedButton.styleFrom(
      foregroundColor: Colors.blueGrey.shade700,
      side: BorderSide(color: Colors.blueGrey.shade200),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 30),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );

    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.blueGrey.shade200),
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              seg('Full report', report.fullReport,
                  () => ref.read(teReportRiverpod).setFullReport(true)),
              Container(width: 1, height: 26, color: Colors.blueGrey.shade100),
              seg('Select days', !report.fullReport,
                  () => ref.read(teReportRiverpod).setFullReport(false)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            report.fullReport
                ? 'Every promoter day found will be included.'
                : '${report.selectedDays.length} of ${report.days.length} selected.',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: allSelected
              ? null
              : () => ref.read(teReportRiverpod).selectAll(true),
          style: quick,
          icon: const Icon(Icons.check_box_outlined, size: 16),
          label: const Text('Select all'),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: noneSelected
              ? null
              : () => ref.read(teReportRiverpod).selectAll(false),
          style: quick,
          icon: const Icon(Icons.check_box_outline_blank, size: 16),
          label: const Text('Deselect all'),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DAY CHECKLIST — grouped by distributor
// ════════════════════════════════════════════════════════════════════════════

class _DayChecklist extends riverpod.ConsumerWidget {
  final TEReportProvider report;
  const _DayChecklist({required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Oldest first — the same order the dates appear in the PDF.
        for (final date in report.dates) _DateGroup(date: date, report: report),
      ],
    );
  }
}

/// One date: select every shift on it at once, attach that day's proof
/// photos, then each distributor's shift beneath.
class _DateGroup extends riverpod.ConsumerWidget {
  final DateTime date;
  final TEReportProvider report;
  const _DateGroup({required this.date, required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
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
            onTap: () =>
                ref.read(teReportRiverpod).selectAllForDate(date, !allSelected),
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
                    onChanged: (_) => ref
                        .read(teReportRiverpod)
                        .selectAllForDate(date, !allSelected),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_dayFmt.format(date),
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600)),
                        Text(
                          '${shifts.length} distributor'
                          '${shifts.length == 1 ? '' : 's'} · '
                          '$handouts handouts'
                          '${photos.isEmpty ? '' : ' · ${photos.length} photo${photos.length == 1 ? '' : 's'}'}',
                          style: const TextStyle(
                              fontSize: 11.5, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(teReportRiverpod).attachPhotos(date),
                    icon: const Icon(Icons.add_a_photo_outlined, size: 17),
                    label: const Text('Add photos'),
                  ),
                ],
              ),
            ),
          ),
          if (photos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(58, 0, 10, 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final photo in photos)
                    _PhotoThumb(
                      photo: photo,
                      onRemove: () =>
                          ref.read(teReportRiverpod).removePhoto(date, photo),
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

class _ShiftRow extends riverpod.ConsumerWidget {
  final TEPromoterDay day;
  final TEReportProvider report;
  const _ShiftRow({required this.day, required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
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
            onChanged: (v) =>
                ref.read(teReportRiverpod).toggleDay(day, v ?? false),
          ),
          Expanded(
            child: Text(day.distributor.name,
                style: const TextStyle(fontSize: 12.5)),
          ),
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
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(photo.bytes,
              width: 44, height: 44, fit: BoxFit.cover),
        ),
        Positioned(
          top: -6,
          right: -6,
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
        if (photo.url == null)
          const Positioned(
            bottom: 2,
            right: 2,
            child: SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// UNRESOLVED FILES
// ════════════════════════════════════════════════════════════════════════════

class _UnresolvedList extends StatelessWidget {
  final List<TEUnresolvedReportFile> items;
  const _UnresolvedList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
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
            '${items.length} file${items.length == 1 ? '' : 's'} could not be placed',
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

// ════════════════════════════════════════════════════════════════════════════
// GENERATE
// ════════════════════════════════════════════════════════════════════════════

class _GenerateButton extends riverpod.ConsumerWidget {
  final TEReportProvider report;
  const _GenerateButton({required this.report});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final canGenerate = report.selectedDays.isNotEmpty && !report.isGenerating;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: canGenerate
              ? () async {
                  final selected = report.selectedDays;
                  ref.read(teReportRiverpod).setGenerating(true);
                  try {
                    // The business details under the logo come from the
                    // same company settings the payslips use. A failed read
                    // prints the defaults rather than blocking the report.
                    PayrollSettings? company;
                    try {
                      company =
                          await ref.read(payrollServiceRiverpod).getSettings();
                    } catch (e) {
                      debugPrint('Report: company settings unavailable: $e');
                    }
                    // Intersection and suburb names for where each
                    // distributor worked. Map servers can be slow or down;
                    // after the time limit the report prints whatever names
                    // did come back instead of waiting.
                    final spots = [
                      for (final d in selected)
                        for (final h in teWorkSpots(d.analysis))
                          (h.centre.latitude, h.centre.longitude),
                    ];
                    var places = <String, TEPlaceName>{};
                    try {
                      places = await resolvePlaceNames(spots)
                          .timeout(const Duration(seconds: 90));
                    } catch (e) {
                      debugPrint('Report: place names incomplete: $e');
                      places = cachedPlaceNames(spots);
                    }
                    final unnamed = spots
                        .where((p) =>
                            places[tePlaceKey(p.$1, p.$2)]?.intersection ==
                            null)
                        .length;
                    if (unnamed > 0 && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            '$unnamed of ${spots.length} work spots have no '
                            'intersection name — the map servers may be busy. '
                            'Generate again in a minute to retry.'),
                        duration: const Duration(seconds: 8),
                      ));
                    }
                    final bytes = await buildReportPdf(
                      selected,
                      photosByDate: report.photosByDate,
                      company: company,
                      placeNames: places,
                    );
                    if (!context.mounted) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TEReportPreviewPage(pdfBytes: bytes),
                    ));
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not build the PDF: $e')),
                      );
                    }
                  } finally {
                    ref.read(teReportRiverpod).setGenerating(false);
                  }
                }
              : null,
          icon: report.isGenerating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.picture_as_pdf, size: 18),
          label: Text(report.isGenerating ? 'Building PDF…' : 'Generate PDF'),
        ),
        if (report.selectedDays.isEmpty && !report.isGenerating) ...[
          const SizedBox(width: 10),
          const Text('Select at least one promoter day.',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        ],
      ],
    );
  }
}
