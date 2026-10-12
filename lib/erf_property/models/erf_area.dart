import 'csg_region.dart';

/// How an [ErfArea] was pulled from the CSG service.
enum ErfAreaSource {
  /// Every parcel whose MIN_CODE matches a cadastral region.
  region,

  /// Every parcel intersecting a rectangular map extent.
  boundingBox,

  /// Every parcel inside a suburb/township boundary picked on the map.
  ///
  /// The right choice in the Western Cape, where a cadastral region is the
  /// whole metro rather than one suburb.
  township,
}

/// Metadata for a batch of ERF parcels that has been downloaded and cached
/// in Firestore.
///
/// Parcels themselves live in `/erfProperties/{lpiCode}` and carry this
/// area's [id] in their `areaId` field, so a suburb can be loaded (or
/// deleted) without touching the rest of the collection.
class ErfArea {
  final String id;
  final String name;
  final ErfAreaSource source;
  final int propertyCount;
  final DateTime downloadedAt;

  /// Set when [source] is [ErfAreaSource.region].
  final String? minCode;
  final String? minRegion;
  final String? majRegion;
  final String? province;

  /// Set when [source] is [ErfAreaSource.boundingBox], and also recorded for
  /// region downloads so the map can frame the area without loading parcels.
  final ErfBounds? bounds;

  /// Cloud Storage path of the gzipped parcel payload.
  ///
  /// Null only for legacy areas whose parcels are still individual Firestore
  /// documents, which [ErfPropertyProvider.importSavedData] converts.
  final String? storagePath;

  /// Size of that payload, so the UI can show what an area costs without
  /// fetching it.
  final int storageBytes;

  const ErfArea({
    required this.id,
    required this.name,
    required this.source,
    required this.propertyCount,
    required this.downloadedAt,
    this.minCode,
    this.minRegion,
    this.majRegion,
    this.province,
    this.bounds,
    this.storagePath,
    this.storageBytes = 0,
  });

  factory ErfArea.fromMap(String id, Map<String, dynamic> data) {
    return ErfArea(
      id: id,
      name: data['name'] as String? ?? id,
      source: switch (data['source'] as String? ?? 'boundingBox') {
        'region' => ErfAreaSource.region,
        'township' => ErfAreaSource.township,
        _ => ErfAreaSource.boundingBox,
      },
      propertyCount: (data['propertyCount'] as num?)?.toInt() ?? 0,
      downloadedAt:
          DateTime.tryParse(data['downloadedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      minCode: data['minCode'] as String?,
      minRegion: data['minRegion'] as String?,
      majRegion: data['majRegion'] as String?,
      province: data['province'] as String?,
      bounds: ErfBounds.fromMap(
        data['bounds'] == null
            ? null
            : Map<String, dynamic>.from(data['bounds'] as Map),
      ),
      storagePath: data['storagePath'] as String?,
      storageBytes: (data['storageBytes'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'source': switch (source) {
          ErfAreaSource.region => 'region',
          ErfAreaSource.township => 'township',
          ErfAreaSource.boundingBox => 'boundingBox',
        },
        'propertyCount': propertyCount,
        'downloadedAt': downloadedAt.toIso8601String(),
        'minCode': minCode,
        'minRegion': minRegion,
        'majRegion': majRegion,
        'province': province,
        'bounds': bounds?.toMap(),
        'storagePath': storagePath,
        'storageBytes': storageBytes,
      };

  /// True when the parcels live in Cloud Storage rather than as individual
  /// Firestore documents.
  bool get isPacked => storagePath != null && storagePath!.isNotEmpty;

  /// Human-readable payload size, e.g. "1.4 MB".
  String get sizeLabel {
    if (storageBytes <= 0) return '';
    if (storageBytes < 1024) return '$storageBytes B';
    if (storageBytes < 1024 * 1024) {
      return '${(storageBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(storageBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  ErfArea copyWith({
    String? name,
    int? propertyCount,
    DateTime? downloadedAt,
    String? storagePath,
    int? storageBytes,
  }) {
    return ErfArea(
      id: id,
      name: name ?? this.name,
      source: source,
      propertyCount: propertyCount ?? this.propertyCount,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      minCode: minCode,
      minRegion: minRegion,
      majRegion: majRegion,
      province: province,
      bounds: bounds,
      storagePath: storagePath ?? this.storagePath,
      storageBytes: storageBytes ?? this.storageBytes,
    );
  }

  /// Stable area id for a parcel that belongs to no area yet.
  ///
  /// Groups by cadastral region where the parcel has one, falling back to the
  /// suburb it was tagged with.
  static String idForProperty({
    required String minCode,
    required String minRegion,
    String? suburb,
  }) {
    if (minCode.isNotEmpty) {
      return 'region_$minCode'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    }
    final label = (suburb != null && suburb.isNotEmpty) ? suburb : minRegion;
    if (label.isNotEmpty) {
      return 'saved_${label.toLowerCase()}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    }
    return 'saved_unsorted';
  }

  /// Stable document id for a suburb picked on the map.
  static String idForTownship(String code, String name) =>
      'suburb_${code.isNotEmpty ? code : name}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  /// Stable document id for a cadastral region download.
  static String idForRegion(CsgRegion region) =>
      'region_${region.minCode.isNotEmpty ? region.minCode : region.minRegion}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  /// Stable document id for a bounding-box download, derived from the box so
  /// re-downloading the same extent updates rather than duplicates.
  static String idForBounds(ErfBounds b) {
    String f(double v) => v.toStringAsFixed(4).replaceAll('.', 'p');
    return 'box_${f(b.minLat)}_${f(b.minLng)}_${f(b.maxLat)}_${f(b.maxLng)}'
        .replaceAll('-', 'm');
  }
}
