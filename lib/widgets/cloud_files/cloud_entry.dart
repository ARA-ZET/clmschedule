// widgets/cloud_files/cloud_entry.dart
//
// One row of the Cloud Files browser — a Storage folder, a Storage file, or a
// file that was moved into a month archive ZIP — plus the Drive-style type, filter
// and sort rules the list and grid views share.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../providers/cloud_file_manager_provider.dart';
import '../../services/cloud_archive_service.dart';
import '../../services/gpx_storage_service.dart';

enum CloudEntryKind { folder, file, archived }

enum CloudFileType { folder, gpx, mapData, image, kml, pdf, other }

enum TypeFilter { any, folders, gpx, mapData, images, kml, pdf, other }

enum ModifiedFilter { any, today, last7, last30, thisYear, lastYear }

enum LocationFilter { any, cloud, archived }

enum SortField { name, modified, size }

class CloudEntry {
  final CloudEntryKind kind;
  final String name;

  /// Full Storage path (for an archived file, where it used to be).
  final String path;
  final DateTime? modified;
  final int? sizeBytes;
  final StorageFolderItem? folder;
  final StorageFileItem? file;
  final ArchivedFileEntry? archived;
  final FolderStats? stats;

  /// Set for search results: the folder the file is in, shown as Location.
  final String? searchFolder;

  /// For a month or year folder that has been archived: "Archived 19 Oct",
  /// "3 months archived".
  final String? archiveNote;

  const CloudEntry._({
    required this.kind,
    required this.name,
    required this.path,
    this.modified,
    this.sizeBytes,
    this.folder,
    this.file,
    this.archived,
    this.stats,
    this.searchFolder,
    this.archiveNote,
  });

  factory CloudEntry.folder(StorageFolderItem f,
          {FolderStats? stats, String? archiveNote}) =>
      CloudEntry._(
        archiveNote: archiveNote,
        kind: CloudEntryKind.folder,
        name: f.name,
        path: f.fullPath,
        folder: f,
        stats: stats,
        modified: stats?.lastModified,
        sizeBytes: stats?.liveBytes,
      );

  factory CloudEntry.file(StorageFileItem f, {String? searchFolder}) =>
      CloudEntry._(
        kind: CloudEntryKind.file,
        name: f.name,
        path: f.fullPath,
        file: f,
        modified: f.lastModified,
        sizeBytes: f.sizeBytes,
        searchFolder: searchFolder,
      );

  factory CloudEntry.archived(ArchivedFileEntry a, {String? searchFolder}) =>
      CloudEntry._(
        kind: CloudEntryKind.archived,
        name: a.name,
        path: a.fullPath,
        archived: a,
        modified: a.originalUpdated ?? a.archivedAt,
        sizeBytes: a.sizeBytes,
        searchFolder: searchFolder,
      );

  /// Selection key. An archived file and a live file of the same name never
  /// collide.
  String get key => kind == CloudEntryKind.archived ? 'zip:$path' : path;

  bool get isFolder => kind == CloudEntryKind.folder;
  bool get isLiveFile => kind == CloudEntryKind.file;
  bool get isArchived => kind == CloudEntryKind.archived;
  bool get inArchive =>
      isArchived || (isFolder && (stats?.fullyArchived ?? false));

  String get extension =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  CloudFileType get type =>
      isFolder ? CloudFileType.folder : cloudFileTypeOf(name);

  bool get isCompiled => name.startsWith('_compiled_');

  bool get canOpenInTrackEditor =>
      isLiveFile && const ['gpx', 'kml', 'kmz'].contains(extension);
}

CloudFileType cloudFileTypeOf(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('_compiled_')) return CloudFileType.mapData;
  final ext = lower.contains('.') ? lower.split('.').last : '';
  switch (ext) {
    case 'gpx':
      return CloudFileType.gpx;
    case 'kml':
    case 'kmz':
      return CloudFileType.kml;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'webp':
    case 'heic':
    case 'gif':
      return CloudFileType.image;
    case 'pdf':
      return CloudFileType.pdf;
    default:
      return CloudFileType.other;
  }
}

IconData cloudTypeIcon(CloudFileType t) {
  switch (t) {
    case CloudFileType.folder:
      return Icons.folder;
    case CloudFileType.gpx:
      return Icons.route;
    case CloudFileType.mapData:
      return Icons.data_object;
    case CloudFileType.image:
      return Icons.image;
    case CloudFileType.kml:
      return Icons.map;
    case CloudFileType.pdf:
      return Icons.picture_as_pdf;
    case CloudFileType.other:
      return Icons.insert_drive_file;
  }
}

Color cloudTypeColor(CloudFileType t, ColorScheme scheme) {
  switch (t) {
    case CloudFileType.folder:
      return scheme.onSurfaceVariant;
    case CloudFileType.gpx:
      return const Color(0xFF1E8E3E);
    case CloudFileType.mapData:
      return const Color(0xFF8E44AD);
    case CloudFileType.image:
      return const Color(0xFFE37400);
    case CloudFileType.kml:
      return const Color(0xFF1A73E8);
    case CloudFileType.pdf:
      return const Color(0xFFD93025);
    case CloudFileType.other:
      return scheme.outline;
  }
}

String cloudTypeLabel(CloudEntry e) {
  switch (e.type) {
    case CloudFileType.folder:
      return 'Folder';
    case CloudFileType.gpx:
      return 'GPX track';
    case CloudFileType.mapData:
      return 'Compiled map data';
    case CloudFileType.image:
      return 'Image';
    case CloudFileType.kml:
      return e.extension.toUpperCase();
    case CloudFileType.pdf:
      return 'PDF';
    case CloudFileType.other:
      return e.extension.isEmpty ? 'File' : e.extension.toUpperCase();
  }
}

String typeFilterLabel(TypeFilter f) => const {
      TypeFilter.any: 'Type',
      TypeFilter.folders: 'Folders',
      TypeFilter.gpx: 'GPX tracks',
      TypeFilter.mapData: 'Compiled map data',
      TypeFilter.images: 'Photos & images',
      TypeFilter.kml: 'KML / KMZ',
      TypeFilter.pdf: 'PDFs',
      TypeFilter.other: 'Other files',
    }[f]!;

IconData typeFilterIcon(TypeFilter f) => const {
      TypeFilter.any: Icons.category_outlined,
      TypeFilter.folders: Icons.folder_outlined,
      TypeFilter.gpx: Icons.route,
      TypeFilter.mapData: Icons.data_object,
      TypeFilter.images: Icons.image_outlined,
      TypeFilter.kml: Icons.map_outlined,
      TypeFilter.pdf: Icons.picture_as_pdf_outlined,
      TypeFilter.other: Icons.insert_drive_file_outlined,
    }[f]!;

String modifiedFilterLabel(ModifiedFilter f) {
  final now = DateTime.now();
  return {
    ModifiedFilter.any: 'Modified',
    ModifiedFilter.today: 'Today',
    ModifiedFilter.last7: 'Last 7 days',
    ModifiedFilter.last30: 'Last 30 days',
    ModifiedFilter.thisYear: 'This year (${now.year})',
    ModifiedFilter.lastYear: 'Last year (${now.year - 1})',
  }[f]!;
}

String locationFilterLabel(LocationFilter f) => const {
      LocationFilter.any: 'Location',
      LocationFilter.cloud: 'In Cloud Files',
      LocationFilter.archived: 'Archived (ZIP)',
    }[f]!;

bool _typeMatches(CloudEntry e, TypeFilter f) {
  switch (f) {
    case TypeFilter.any:
      return true;
    case TypeFilter.folders:
      return e.isFolder;
    case TypeFilter.gpx:
      return e.type == CloudFileType.gpx;
    case TypeFilter.mapData:
      return e.type == CloudFileType.mapData;
    case TypeFilter.images:
      return e.type == CloudFileType.image;
    case TypeFilter.kml:
      return e.type == CloudFileType.kml;
    case TypeFilter.pdf:
      return e.type == CloudFileType.pdf;
    case TypeFilter.other:
      return e.type == CloudFileType.other;
  }
}

bool _modifiedMatches(CloudEntry e, ModifiedFilter f) {
  if (f == ModifiedFilter.any) return true;
  final d = e.modified;
  if (d == null) return false;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (f) {
    case ModifiedFilter.any:
      return true;
    case ModifiedFilter.today:
      return !d.isBefore(today);
    case ModifiedFilter.last7:
      return !d.isBefore(today.subtract(const Duration(days: 6)));
    case ModifiedFilter.last30:
      return !d.isBefore(today.subtract(const Duration(days: 29)));
    case ModifiedFilter.thisYear:
      return d.year == now.year;
    case ModifiedFilter.lastYear:
      return d.year == now.year - 1;
  }
}

bool _locationMatches(CloudEntry e, LocationFilter f) {
  switch (f) {
    case LocationFilter.any:
      return true;
    case LocationFilter.cloud:
      return e.isLiveFile || (e.isFolder && !(e.stats?.fullyArchived ?? false));
    case LocationFilter.archived:
      return e.isArchived ||
          (e.isFolder &&
              ((e.stats?.archivedFiles ?? 0) > 0 || e.archiveNote != null));
  }
}

/// Filter then sort the way Drive does: folders always on top.
List<CloudEntry> filterAndSort(
  List<CloudEntry> entries, {
  required TypeFilter type,
  required ModifiedFilter modified,
  required LocationFilter location,
  required SortField sort,
  required bool ascending,
}) {
  final out = entries
      .where((e) =>
          _typeMatches(e, type) &&
          _modifiedMatches(e, modified) &&
          _locationMatches(e, location))
      .toList();
  int cmp(CloudEntry a, CloudEntry b) {
    if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
    int r;
    switch (sort) {
      case SortField.name:
        r = compareNatural(a.name, b.name);
        break;
      case SortField.modified:
        r = (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0));
        if (r == 0) r = compareNatural(a.name, b.name);
        break;
      case SortField.size:
        r = (a.sizeBytes ?? -1).compareTo(b.sizeBytes ?? -1);
        if (r == 0) r = compareNatural(a.name, b.name);
        break;
    }
    return ascending ? r : -r;
  }

  out.sort(cmp);
  return out;
}

final RegExp _chunk = RegExp(r'(\d+|\D+)');
final RegExp _monthFolder = RegExp(r'^([A-Za-z]{3}) (\d{4})$');
const _months = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec'
];

/// Month folders ("Oct 2026") as yyyymm, so they sort by date, not A–Z.
int? _monthKey(String name) {
  final m = _monthFolder.firstMatch(name);
  if (m == null) return null;
  final i = _months.indexOf(m[1]!.toLowerCase());
  return i < 0 ? null : int.parse(m[2]!) * 100 + i;
}

/// "Round 2" before "Round 10", "Sep 2026" before "Oct 2026";
/// case-insensitive.
int compareNatural(String a, String b) {
  final ma = _monthKey(a), mb = _monthKey(b);
  if (ma != null && mb != null) return ma.compareTo(mb);
  final ca = _chunk.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final cb = _chunk.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < ca.length && i < cb.length; i++) {
    final x = ca[i], y = cb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final r = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (r != 0) return r;
  }
  return ca.length.compareTo(cb.length);
}

/// Drive's short date: a time today, "16 Oct" this year, else "16 Oct 2025".
String formatDriveDate(DateTime? d) {
  if (d == null) return '—';
  final local = d.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return DateFormat('HH:mm').format(local);
  }
  if (local.year == now.year) return DateFormat('d MMM').format(local);
  return DateFormat('d MMM yyyy').format(local);
}

String formatFullDate(DateTime? d) =>
    d == null ? '—' : DateFormat('d MMM yyyy, HH:mm').format(d.toLocal());
