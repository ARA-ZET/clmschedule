// services/distribution_report_service.dart
//
// Compiles the client-facing distribution report for one Job List row by
// walking links that already exist: the row's `area` share URL to a shareable
// map, the map to its Cloud Storage GPX folders, and those folders' compiled
// index files to a date and a letterbox count.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/distribution_report.dart';
import '../models/job_list_item.dart';
import '../models/xero_invoice.dart';
import '../models/zoho_invoice.dart';
import '../shareable_maps/models/map_layer.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/services/map_link_service.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../utils/schedule_time.dart';
import 'compiled_tracks_parser.dart';
import 'cloud_archive_service.dart';
import 'gpx_storage_service.dart';

/// Layer names the map editor generates for cloud overlays. Matched as
/// suffixes because the live names are month-prefixed ("Apr 2025 Movements").
const List<String> _kCloudLayerNameSuffixes = [
  'Movements of the Distributors',
  'Letter Boxes Reached',
  'Movements',
  'Letter Boxes',
];

/// Layer id of the injected gap-areas overlay.
///
/// Duplicated from `schedule_job_adapter.dart` rather than imported: that file
/// pulls in the whole schedule adapter stack, and this service is meant to be
/// constructible in a test without it.
const String _kUnfinishedAreasLayerId = 'unfinished_work_areas_layer';

/// Placeholder the editor shows for a polygon nobody named.
const String _kUnnamedPolygon = 'Unnamed Polygon';

/// Whether [layer] is machinery rather than a client-visible work area.
///
/// Cloud track/waypoint layers are ephemeral and normally absent from a
/// document read headlessly, but a map saved while one was materialised can
/// carry them — so this checks rather than assumes.
bool isSystemMapLayer(MapLayer layer) {
  if (layer.id == _kUnfinishedAreasLayerId) return true;
  if (layer.id.startsWith('cloud_')) return true;
  final name = layer.name.trim();
  return _kCloudLayerNameSuffixes.any((s) => name.endsWith(s));
}

/// Date embedded in a GPX filename: "Track   09 Mar 2026   Nolan   Seeff …".
final RegExp _kFileNameDate = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})');

const List<String> _kMonthAbbr = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// Parse the `dd MMM yyyy` a track file carries in its name.
///
/// Returned as UTC midnight so it survives [toScheduleCivil] unchanged — the
/// filename records a calendar day, not an instant, and must not be shifted.
@visibleForTesting
DateTime? parseGpxFileNameDate(String fileName) {
  final m = _kFileNameDate.firstMatch(fileName);
  if (m == null) return null;
  final month = _kMonthAbbr.indexOf(m.group(2)!.toLowerCase());
  if (month < 0) return null;
  final day = int.tryParse(m.group(1)!);
  final year = int.tryParse(m.group(3)!);
  if (day == null || year == null) return null;
  return DateTime.utc(year, month + 1, day)
      .subtract(kScheduleZoneOffset);
}

/// Split the Job List's free-text Report Addresses column into addresses.
///
/// Kept permissive: anything with an `@` counts. Rejecting an unusual but
/// valid address would be worse than letting a typo through, which the user
/// sees in the draft anyway.
@visibleForTesting
List<String> parseReportAddresses(String raw) {
  return raw
      .split(RegExp(r'[,;\n\r]+'))
      .map((s) => s.trim())
      .where((s) => s.contains('@'))
      .toSet()
      .toList();
}

/// Earliest `dd MMM yyyy` across [fileNames]' GPX files.
///
/// Only reached when no track carried a timestamp. Preferred over the
/// compile time because the filename records the day the distribution
/// happened, while `compiledAt` records when someone uploaded the file.
@visibleForTesting
DateTime? earliestGpxFileNameDate(Iterable<String> fileNames) {
  DateTime? earliest;
  for (final name in fileNames) {
    if (!name.toLowerCase().endsWith('.gpx')) continue;
    final date = parseGpxFileNameDate(name);
    if (date == null) continue;
    if (earliest == null || date.isBefore(earliest)) earliest = date;
  }
  return earliest;
}

bool isPhotoFileName(String name) =>
    RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(name);

/// The distributor a saved file names, as written — not yet matched.
///
/// - Track Editor GPX: `Track   09 Mar 2026   Petros   Chand   …fulltrack.gpx`
///   (fields separated by three spaces; the distributor is the third).
/// - clmgpx photos: `Petros_Poster 501_2026-10-22_12-37-26.jpg`.
///
/// Null for compiled indexes, free-form names and clmgpx's "Unknown".
@visibleForTesting
String? workerNameFromFileName(String fileName) {
  final lower = fileName.toLowerCase();
  if (fileName.startsWith('_')) return null;

  String? name;
  if (lower.endsWith('.gpx')) {
    final parts = fileName.split(RegExp(r'\s{3,}'));
    if (parts.length >= 4 && _kFileNameDate.hasMatch(parts[1])) {
      name = parts[2];
    }
  } else if (isPhotoFileName(fileName)) {
    final parts = fileName.split('_');
    // Name, waypoint/mode, date, time at least — anything shorter is not a
    // clmgpx photo.
    if (parts.length >= 4) name = parts.first;
  }

  name = name?.trim();
  if (name == null || name.isEmpty || name.toLowerCase() == 'unknown') {
    return null;
  }
  return name;
}

/// Distinct worker names across [fileNames], case-insensitively, in the
/// order first seen.
@visibleForTesting
List<String> workerNamesFromFileNames(Iterable<String> fileNames) {
  final seen = <String, String>{};
  for (final f in fileNames) {
    final name = workerNameFromFileName(f);
    if (name != null) seen.putIfAbsent(name.toLowerCase(), () => name);
  }
  return seen.values.toList();
}

/// Whether an invoice with this provider [status] is settled.
///
/// Routed by provider because the two rules genuinely differ: Zoho treats a
/// zero balance as settled, while Xero must key on the status alone — a Xero
/// DRAFT also reports `AmountDue: 0`, so Zoho's rule would file every draft
/// as paid and drop the "invoice attached" line from reports that need it.
bool isInvoiceStatusPaid(String providerId, String status) {
  if (status.isEmpty) return false;
  if (providerId == 'xero') {
    return XeroInvoiceStatus.parse(status) == XeroInvoiceStatus.paid;
  }
  return ZohoInvoiceStatus.parse(status) == ZohoInvoiceStatus.paid;
}

class DistributionReportService {
  final ShareableMapsFirestoreService _maps;
  final MapLinkService _links;
  final GpxStorageService _storage;
  final FirebaseFirestore _firestore;

  DistributionReportService({
    ShareableMapsFirestoreService? maps,
    MapLinkService? links,
    GpxStorageService? storage,
    FirebaseFirestore? firestore,
  })  : _maps = maps ?? ShareableMapsFirestoreService(),
        _links = links ?? MapLinkService(),
        _storage = storage ?? GpxStorageService(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Compile the report for [item].
  ///
  /// Never throws for missing data — a job with no map comes back with
  /// [DistributionReport.mapError] set so the dialog can explain itself.
  Future<DistributionReport> compile(JobListItem item) async {
    final resolved = await _resolveMap(item);

    final folders = await _readFolders(
      _folderPathsFor(item, resolved?.map),
    );

    return DistributionReport(
      jobId: item.id,
      client: item.client,
      jobDate: toScheduleCivil(item.date),
      quantityOrdered: item.quantity,
      recordedQuantityDistributed: item.quantityDistributed,
      mapName: resolved?.map.name ?? '',
      mapLink: resolved?.shareUrl ?? '',
      shareCode: resolved?.shareCode ?? '',
      mapError: resolved == null
          ? 'No shareable map is linked to this job. Use the link icon in the '
              'Area column to link one.'
          : null,
      areas: resolved == null ? const [] : _areaNames(resolved.map),
      folders: folders,
      recipients: parseReportAddresses(item.reportAddresses),
      invoiceNumber: item.resolvedInvoiceNumber,
      hasInvoice: item.hasAccountingInvoice,
      invoiceIsPaid: _isPaid(item),
    );
  }

  /// The public share link of [item]'s map, or null when it has none.
  Future<String?> shareUrlFor(JobListItem item) async {
    final url = (await _resolveMap(item))?.shareUrl ?? '';
    return url.isEmpty ? null : url;
  }

  // ---------------------------------------------------------------------------
  // Map resolution
  // ---------------------------------------------------------------------------

  /// Find the job's map, most authoritative route first.
  Future<_ResolvedMap?> _resolveMap(JobListItem item) async {
    // 1. The share URL in `area`. Authoritative — the link carries its own
    //    month, which is the one thing `shareableMapId` does not record.
    final code = MapLinkService.extractShareCodeFromText(item.area);
    if (code != null) {
      try {
        final link = await _links.resolveShareCode(code);
        if (link != null) {
          final map = await _maps.getMap(link.monthKey, link.mapId);
          if (map != null) {
            return _ResolvedMap(
              map: map,
              shareCode: code,
              shareUrl: MapLinkService.buildShareUrl(code),
            );
          }
        }
      } catch (e) {
        debugPrint('[DistributionReport] share-code lookup failed: $e');
      }
    }

    // 2. `shareableMapId` against the job's own month. Correct whenever the
    //    map was created in the month the job sits in, which is the norm.
    if (item.shareableMapId.isNotEmpty) {
      final monthKey = ShareableMapsFirestoreService.monthKeyFor(item.date);
      try {
        final map = await _maps.getMap(monthKey, item.shareableMapId);
        if (map != null) return await _withShareUrl(map, monthKey);
      } catch (e) {
        debugPrint('[DistributionReport] map lookup by id failed: $e');
      }
    }

    // 3. The back-reference the auto-linker writes onto the map document.
    //    Catches a map created in a different month to its job.
    try {
      final snap = await _firestore
          .collectionGroup('maps')
          .where('jobListItemId', isEqualTo: item.id)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        final doc = snap.docs.first;
        final monthKey = doc.reference.parent.parent?.id ?? '';
        final map = ShareableMap.fromMap(doc.id, doc.data());
        return await _withShareUrl(map, monthKey);
      }
    } catch (e) {
      debugPrint('[DistributionReport] reverse map lookup failed: $e');
    }

    return null;
  }

  /// Attach the public share URL to a map found without going through one.
  Future<_ResolvedMap> _withShareUrl(ShareableMap map, String monthKey) async {
    String? code;
    try {
      code = await _links.getShareCodeForMap(monthKey, map.id);
    } catch (e) {
      debugPrint('[DistributionReport] share code lookup failed: $e');
    }
    return _ResolvedMap(
      map: map,
      shareCode: code ?? '',
      shareUrl: code == null ? '' : MapLinkService.buildShareUrl(code),
    );
  }

  // ---------------------------------------------------------------------------
  // Areas
  // ---------------------------------------------------------------------------

  /// Polygon names from the map's client-visible layers, de-duplicated and
  /// kept in the order they appear.
  List<String> _areaNames(ShareableMap map) {
    final seen = <String>{};
    final names = <String>[];
    for (final layer in map.layers) {
      if (isSystemMapLayer(layer)) continue;
      for (final polygon in layer.polygons) {
        if (!polygon.isPolygon) continue;
        final name = polygon.name.trim();
        if (name.isEmpty || name == _kUnnamedPolygon) continue;
        if (seen.add(name.toLowerCase())) names.add(name);
      }
    }
    return names;
  }

  // ---------------------------------------------------------------------------
  // Cloud folders
  // ---------------------------------------------------------------------------

  /// Every cloud folder this job's data could live in, de-duplicated.
  ///
  /// A map's `primaryCloudFolderPath` returns only one, but a job that ran
  /// over several rounds has a folder each.
  List<String> _folderPathsFor(JobListItem item, ShareableMap? map) {
    final paths = <String>{};
    if (map != null) {
      paths.addAll(map.cloudFolderPaths);
      final legacy = map.storageFolderPath;
      if (legacy != null && legacy.isNotEmpty) paths.add(legacy);
    }
    if (item.storageFolderPath.isNotEmpty) paths.add(item.storageFolderPath);
    return paths.where((p) => p.trim().isNotEmpty).toList();
  }

  Future<List<DistributionReportFolder>> _readFolders(
    List<String> paths,
  ) async {
    // Folders are independent reads; a job with four rounds should not pay
    // four round-trips in sequence.
    return Future.wait(paths.map(_readFolder));
  }

  Future<DistributionReportFolder> _readFolder(String path) async {
    try {
      // One listing serves the filename date fallback, the people table and
      // the photo count.
      final names = await _fileNames(path);
      final workers = workerNamesFromFileNames(names);
      final photos = names.where(isPhotoFileName).length;

      final trackBytes =
          await _storage.downloadFileBytes('$path/_compiled_tracks.json');

      if (trackBytes != null) {
        final summary = parseCompiledTracksSummary(trackBytes);
        if (summary.earliestStart != null) {
          return DistributionReportFolder(
            path: path,
            waypointCount: summary.waypointCount,
            trackCount: summary.trackCount,
            fileCount: summary.fileCount,
            earliestStart: summary.earliestStart,
            compiledAt: summary.compiledAt,
            dateSource: DistributionDateSource.trackTimes,
            workerNames: workers,
            photoCount: photos,
          );
        }
        // Tracks with no timestamps — fall through to the weaker sources but
        // keep the counts we already have.
        final fallback = earliestGpxFileNameDate(names);
        return DistributionReportFolder(
          path: path,
          waypointCount: summary.waypointCount,
          trackCount: summary.trackCount,
          fileCount: summary.fileCount,
          earliestStart: fallback,
          compiledAt: summary.compiledAt,
          dateSource: fallback != null
              ? DistributionDateSource.fileName
              : (summary.compiledAt != null
                  ? DistributionDateSource.compiledAt
                  : DistributionDateSource.none),
          workerNames: workers,
          photoCount: photos,
        );
      }

      // No tracks file. Both writers delete it when a folder holds no tracks,
      // so a waypoint-only folder lands here legitimately.
      final wptBytes =
          await _storage.downloadFileBytes('$path/_compiled_waypoints.json');
      if (wptBytes == null) {
        return DistributionReportFolder(
          path: path,
          error: 'No compiled GPX index — the folder may still be processing.',
          workerNames: workers,
          photoCount: photos,
        );
      }

      final count = parseCompiledWaypointCount(wptBytes);
      final fallback = earliestGpxFileNameDate(names);
      return DistributionReportFolder(
        path: path,
        waypointCount: count,
        earliestStart: fallback,
        dateSource: fallback != null
            ? DistributionDateSource.fileName
            : DistributionDateSource.none,
        workerNames: workers,
        photoCount: photos,
      );
    } catch (e) {
      debugPrint('[DistributionReport] folder read failed for $path: $e');
      return DistributionReportFolder(path: path, error: 'Could not read: $e');
    }
  }

  /// Every file name in [path] and its subfolders (poster photos sometimes
  /// sit in their own subfolder), plus GPX that were moved into an archive
  /// ZIP and live on only in the manifest.
  ///
  /// A failed listing is an empty list, not an error: it only costs the
  /// filename date fallback and the people table, both of which the dialog
  /// shows as missing.
  Future<List<String>> _fileNames(String path, {int depth = 0}) async {
    try {
      final contents = await _storage.listFolderContents(path);
      final names = contents.files.map((f) => f.name).toList();
      if (names.contains(kArchiveManifestFile)) {
        final manifest = await CloudArchiveService().readManifest(path);
        names.addAll(manifest?.files.map((a) => a.name) ?? const []);
      }
      if (depth < 2) {
        for (final sub in contents.folders) {
          names.addAll(await _fileNames(sub.fullPath, depth: depth + 1));
        }
      }
      return names;
    } catch (e) {
      debugPrint('[DistributionReport] folder listing failed for $path: $e');
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Invoice
  // ---------------------------------------------------------------------------

  /// Whether the row's invoice is settled.
  ///
  /// Routed by provider because the two rules genuinely differ: Zoho treats a
  /// zero balance as settled, while Xero must key on the status alone — a Xero
  /// DRAFT also reports `AmountDue: 0`, so Zoho's rule would file every draft
  /// as paid and drop the "invoice attached" line from reports that need it.
  bool _isPaid(JobListItem item) {
    if (!item.hasAccountingInvoice) return false;
    return isInvoiceStatusPaid(
        item.resolvedInvoiceProviderId, item.resolvedInvoiceStatus);
  }
}

class _ResolvedMap {
  final ShareableMap map;
  final String shareCode;
  final String shareUrl;

  const _ResolvedMap({
    required this.map,
    required this.shareCode,
    required this.shareUrl,
  });
}
