import '../utils/schedule_time.dart';

/// Where a report's distribution date came from.
///
/// Recorded rather than discarded so the dialog can say when the date was
/// inferred instead of measured — a guessed date on a client-facing report
/// should not look identical to one taken off the GPS.
enum DistributionDateSource {
  /// Earliest `<trkpt><time>` in the folder's tracks. The real thing.
  trackTimes('from GPS track times'),

  /// The `dd MMM yyyy` embedded in a GPX filename.
  fileName('from the GPX filename'),

  /// When the folder was last compiled — upload time, not distribution time.
  compiledAt('from the file upload date'),

  /// The Job List row's own date. Nothing in the cloud folder had a date.
  jobDate('from the job date'),

  /// No date at all.
  none('unknown');

  const DistributionDateSource(this.label);
  final String label;

  /// Whether this source is a measurement rather than an inference.
  bool get isMeasured => this == DistributionDateSource.trackTimes;
}

/// One cloud folder's contribution to a report.
///
/// A job that ran over several rounds has several folders, and a map that has
/// been reused across months can carry folders that belong to an earlier job —
/// which is why these stay separate and individually selectable rather than
/// being summed on the way in.
class DistributionReportFolder {
  final String path;
  final int waypointCount;
  final int trackCount;
  final int fileCount;
  final DateTime? earliestStart;
  final DateTime? compiledAt;
  final DistributionDateSource dateSource;

  /// Set when this folder could not be read. The folder still appears in the
  /// dialog so a missing count is visible rather than silently absent.
  final String? error;

  const DistributionReportFolder({
    required this.path,
    this.waypointCount = 0,
    this.trackCount = 0,
    this.fileCount = 0,
    this.earliestStart,
    this.compiledAt,
    this.dateSource = DistributionDateSource.none,
    this.error,
  });

  /// Last path segment — "Round 1" — for display. The full path is long and
  /// mostly repeated across a map's folders.
  String get label {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return path;
    return parts.length >= 2
        ? '${parts[parts.length - 2]} / ${parts.last}'
        : parts.last;
  }

  /// The best date this folder can offer, already SAST-civil.
  DateTime? get date {
    final instant = earliestStart ?? compiledAt;
    return instant == null ? null : toScheduleCivil(instant);
  }
}

/// The aggregate across whichever folders the user has selected.
class DistributionReportTotals {
  final int quantityDistributed;

  /// SAST civil date, or null when nothing supplied one.
  final DateTime? startDate;
  final DistributionDateSource dateSource;

  const DistributionReportTotals({
    required this.quantityDistributed,
    this.startDate,
    this.dateSource = DistributionDateSource.none,
  });
}

/// Everything needed to write a distribution report for one Job List row.
///
/// Compiled by `DistributionReportService`; rendered by
/// `DistributionReportTemplate`. Holds no widgets and no Firestore handles, so
/// it is straightforward to build in a test.
class DistributionReport {
  /// The Job List row this was compiled from.
  final String jobId;
  final String client;

  /// The row's own date, SAST-civil. The date of last resort when nothing in
  /// the cloud folders carries one.
  final DateTime jobDate;

  /// Ordered quantity, for comparison against what was actually distributed.
  final int quantityOrdered;

  /// What `quantityDistributed` currently reads on the row, so the dialog can
  /// tell whether writing the compiled figure back would change anything.
  final int recordedQuantityDistributed;

  final String mapName;

  /// Public share URL, or empty when the map could not be resolved.
  final String mapLink;

  /// Why there is no map. Null when one was found.
  final String? mapError;

  /// Polygon names from the map's non-system layers, de-duplicated in the
  /// order they appear.
  final List<String> areas;

  final List<DistributionReportFolder> folders;

  /// Parsed out of the row's free-text Report Addresses column.
  final List<String> recipients;

  final String invoiceNumber;

  /// Whether the invoice is settled. Decides the default for the
  /// "Your invoice is attached." line.
  final bool invoiceIsPaid;

  /// True when the row carries an invoice at all.
  final bool hasInvoice;

  const DistributionReport({
    required this.jobId,
    required this.client,
    required this.jobDate,
    this.quantityOrdered = 0,
    this.recordedQuantityDistributed = 0,
    this.mapName = '',
    this.mapLink = '',
    this.mapError,
    this.areas = const [],
    this.folders = const [],
    this.recipients = const [],
    this.invoiceNumber = '',
    this.invoiceIsPaid = false,
    this.hasInvoice = false,
  });

  bool get hasMap => mapLink.isNotEmpty;

  /// Folders that were read without error — the ones worth selecting.
  List<DistributionReportFolder> get readableFolders =>
      folders.where((f) => f.error == null).toList();

  /// Aggregate over [selectedPaths].
  ///
  /// Quantities sum. The date is the **earliest** across the selection, and
  /// reports the source of the folder that supplied it — not of the others,
  /// which did not contribute the date being shown.
  ///
  /// With nothing selected, or no selected folder carrying a date, this falls
  /// back to [jobDate] so the report always states *some* date rather than
  /// rendering an empty sentence.
  DistributionReportTotals totalsFor(Set<String> selectedPaths) {
    var quantity = 0;
    DateTime? earliest;
    var source = DistributionDateSource.none;

    for (final folder in folders) {
      if (folder.error != null) continue;
      if (!selectedPaths.contains(folder.path)) continue;

      quantity += folder.waypointCount;

      final date = folder.date;
      if (date == null) continue;
      if (earliest == null || date.isBefore(earliest)) {
        earliest = date;
        source = folder.dateSource;
      }
    }

    return DistributionReportTotals(
      quantityDistributed: quantity,
      startDate: earliest ?? jobDate,
      dateSource:
          earliest == null ? DistributionDateSource.jobDate : source,
    );
  }
}
