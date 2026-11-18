// recycle_bin/recycle_bin_payload_store.dart
//
// A deleted document too big to copy into its bin entry (Firestore caps a
// document at 1 MiB, and a busy map can come close on its own) is kept in
// Storage instead, gzipped, at `recycleBin/payloads/{entryId}.json.gz`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'recycle_bin_entry.dart';

/// Above this many characters of JSON, the payload goes to Storage.
const int kInlinePayloadLimit = 700 * 1024;

String payloadPathFor(String entryId) =>
    '${kRecycleBinStoragePrefix}payloads/$entryId.json.gz';

/// Whether [data] is small enough to store inside the bin entry.
bool fitsInline(Map<String, dynamic> data) =>
    jsonEncode(data, toEncodable: _encode).length <= kInlinePayloadLimit;

Future<String> uploadPayload(String entryId, Map<String, dynamic> data) async {
  final path = payloadPathFor(entryId);
  final json = utf8.encode(jsonEncode(data, toEncodable: _encode));
  await FirebaseStorage.instance.ref(path).putData(
        Uint8List.fromList(const GZipEncoder().encode(json)),
        SettableMetadata(contentType: 'application/gzip'),
      );
  return path;
}

/// The entry's payload, downloading it when it was kept in Storage.
Future<Map<String, dynamic>> resolvePayload(RecycleBinEntry entry) async {
  final ref = entry.payloadRef;
  if (ref == null) return entry.payload;
  final bytes = await FirebaseStorage.instance.ref(ref).getData(64 << 20);
  if (bytes == null) throw StateError('Deleted item data is missing');
  final json = utf8.decode(const GZipDecoder().decodeBytes(bytes));
  return Map<String, dynamic>.from(
      _decode(jsonDecode(json)) as Map<dynamic, dynamic>);
}

// Firestore values that JSON can't hold, tagged so they come back as such.
Object? _encode(Object? v) {
  if (v is Timestamp) return {'__ts': v.microsecondsSinceEpoch};
  if (v is GeoPoint) {
    return {
      '__geo': [v.latitude, v.longitude],
    };
  }
  if (v is DateTime) return {'__ts': v.microsecondsSinceEpoch};
  return v.toString();
}

Object? _decode(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v['__ts'] is int) {
      return Timestamp.fromMicrosecondsSinceEpoch(v['__ts'] as int);
    }
    if (v.length == 1 && v['__geo'] is List) {
      final g = v['__geo'] as List;
      return GeoPoint((g[0] as num).toDouble(), (g[1] as num).toDouble());
    }
    return {for (final e in v.entries) e.key as String: _decode(e.value)};
  }
  if (v is List) return [for (final x in v) _decode(x)];
  return v;
}
