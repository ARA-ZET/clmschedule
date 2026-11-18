// track_editor/widgets/te_report_panel.dart
//
// The Report-mode left panel (shown full-width — Report mode has no map):
// pick a Storage folder, review the promoter days the scan found grouped by
// date, choose "full report" or a hand-picked subset, check the proof-of-
// handout photos found in the folder (or add more per date), then generate
// the PDF.
import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../providers/schedule_provider.dart';
import '../models/te_promoter_day.dart';
import '../providers/te_report_provider.dart';
import '../pages/te_report_preview_page.dart';
import '../services/te_report_generate.dart';
import 'te_folder_picker_dialog.dart';
import 'te_report_days.dart';

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
              _ScanningIndicator(status: report.scanStatus)
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
                TEReportPhotoNotices(report: report),
                TEReportDayChecklist(report: report),
              ],
              if (report.unresolved.isNotEmpty) ...[
                const SizedBox(height: 16),
                TEUnresolvedFiles(items: report.unresolved),
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
  final String? status;
  const _ScanningIndicator({this.status});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text(status ?? 'Scanning folder for GPX files and photos…',
              style: const TextStyle(color: Colors.black54)),
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
                  final report = ref.read(teReportRiverpod);
                  try {
                    final built =
                        await generateHandoutReport(context, ref, report);
                    if (built == null || !context.mounted) return;
                    if (built.mapsMissing > 0) {
                      ScaffoldMessenger.of(context).showToast(SnackBar(
                        content: Text(
                            '${built.mapsMissing} of ${built.maps} street '
                            "maps couldn't load — those routes print on a "
                            'plain background. Generate again to retry.'),
                        duration: const Duration(seconds: 8),
                      ));
                    }
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TEReportPreviewPage(pdfBytes: built.bytes),
                    ));
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showToast(
                        SnackBar(content: Text('Could not build the PDF: $e')),
                      );
                    }
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
          label: Text(report.isGenerating
              ? (report.generateStatus ?? 'Building PDF…')
              : 'Generate PDF'),
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
