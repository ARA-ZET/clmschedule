// track_editor/services/te_report_generate.dart
//
// Builds the Flyer Handout Report PDF for a TEReportProvider's ticked days:
// the photos chosen to go in, company details, the intersections each promoter worked at, the client
// map links, the "Check where worked" dialog, the street maps, the photos,
// then the PDF itself. Track Editor Report mode and the Job List report
// page both build through here, so the two give the same PDF.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';
import '../../services/job_list_service.dart';
import '../providers/te_report_provider.dart';
import '../widgets/te_photo_picker_dialog.dart';
import '../widgets/te_where_worked_dialog.dart';
import 'te_place_names.dart';
import 'te_report_images.dart';
import 'te_report_map_links.dart';
import 'te_report_maps.dart';
import 'te_report_pdf.dart';

/// A built report.
class TEReportBuild {
  final Uint8List bytes;

  /// Street maps that couldn't be fetched (their routes print on a blank
  /// background), out of [maps].
  final int mapsMissing;
  final int maps;

  const TEReportBuild(
      {required this.bytes, required this.mapsMissing, required this.maps});
}

/// Builds the PDF for [report]'s selected days, reporting each step through
/// [TEReportProvider.setGenerateStatus], with [TEReportProvider.isGenerating]
/// on from once the photos are chosen. Null when the photos or the check
/// are backed out of.
Future<TEReportBuild?> generateHandoutReport(
  BuildContext context,
  riverpod.WidgetRef ref,
  TEReportProvider report,
) async {
  if (report.isGenerating) return null;
  // A folder can hold far more photos than the report wants: the ones that
  // go in are chosen first, before the slow lookups below.
  if (report.availablePhotoCount > 0 || report.undatedPhotos.isNotEmpty) {
    final go = await showTEPhotoPicker(context, report,
        doneLabel: 'Continue', cancelLabel: 'Back');
    if (!go || !context.mounted) return null;
  }
  report.setGenerating(true);
  try {
    return await _build(context, ref, report);
  } finally {
    report.setGenerating(false);
  }
}

Future<TEReportBuild?> _build(
  BuildContext context,
  riverpod.WidgetRef ref,
  TEReportProvider report,
) async {
  final selected = report.selectedDays;
  // The business details under the logo come from the same company
  // settings the payslips use. A failed read prints the defaults rather
  // than blocking the report.
  PayrollSettings? company;
  try {
    company = await ref.read(payrollServiceRiverpod).getSettings();
  } catch (e) {
    debugPrint('Report: company settings unavailable: $e');
  }
  // Intersection names for where each distributor worked. Map servers can
  // be slow or down; after the time limit the check below shows whatever
  // names did come back, with a retry and hand editing for the rest.
  final spots = [
    for (final d in selected)
      for (final h in teWorkSpots(d.analysis))
        (h.centre.latitude, h.centre.longitude),
  ];
  var places = <String, TEPlaceName>{};
  // Set on time-out so the abandoned lookup stops and stops reporting
  // progress to the button.
  var abandoned = false;
  try {
    places = await resolvePlaceNames(
      spots,
      isCancelled: () => abandoned,
      onProgress: (p) {
        if (abandoned || p.finished) return;
        final last = p.done + p.current.length;
        report.setGenerateStatus('Finding intersections '
            '${last > p.done + 1 ? '${p.done + 1}–$last' : last} '
            'of ${p.total}'
            '${p.round > 1 ? ' (servers busy, asking again)' : ''}…');
      },
    ).timeout(const Duration(seconds: 90));
  } catch (e) {
    abandoned = true;
    debugPrint('Report: place names incomplete: $e');
    places = cachedPlaceNames(spots);
  }
  // The client map each promoter's map links to, through the Job List job
  // whose folder holds their files.
  report.setGenerateStatus('Finding the client maps…');
  final linkGroups = await resolveReportMapLinks(
    selected,
    jobs: ref.read(jobListServiceRiverpod),
  );
  report.setGenerateStatus(null);
  if (!context.mounted) return null;
  final checked = await showWhereWorkedDialog(
    context,
    days: selected,
    places: places,
    linkGroups: linkGroups,
    report: report,
  );
  if (checked == null) return null;
  final mapLinks = <String, String>{
    for (final g in linkGroups)
      if (_isWebLink(teGroupLink(report, g)))
        for (final d in g.days) d.key: teGroupLink(report, g).trim(),
  };
  // The street map behind each promoter's route map. One that can't be
  // fetched prints its route on a blank background rather than holding the
  // report up.
  final mapImages = await fetchReportMaps(
    selected,
    onProgress: (done, total) => report.setGenerateStatus(
        'Loading maps ${math.min(done + 1, total)} of $total…'),
  );
  // Photos straight off a phone are megabytes each; they go in scaled to
  // what print needs.
  final photos = await teCompressProofPhotos(
    report.chosenPhotosByDate,
    onProgress: (done, total) => report.setGenerateStatus(
        'Preparing photos ${math.min(done + 1, total)} of $total…'),
  );
  report.setGenerateStatus('Building PDF…');
  final bytes = await buildReportPdf(
    selected,
    photosByDate: photos,
    company: company,
    placeNames: checked,
    whereOverrides: report.whereOverrides,
    mapImages: mapImages,
    mapLinks: mapLinks,
  );
  final mapped =
      selected.fold<int>(0, (n, d) => n + teReportMaps(teMapRoute(d)).length);
  return TEReportBuild(
    bytes: bytes,
    maps: mapped,
    mapsMissing: math.max(0, mapped - mapImages.length),
  );
}

/// A full http(s) link, fit to put behind a map in the PDF.
bool _isWebLink(String text) {
  final uri = Uri.tryParse(text.trim());
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}
