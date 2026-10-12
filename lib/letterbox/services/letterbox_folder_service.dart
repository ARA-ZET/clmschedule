import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A Cloud Storage folder that holds distribution GPX files.
///
/// Deliberately just a path. Everything the seed needs afterwards comes from
/// Cloud Storage (`{path}/_compiled_waypoints.json`), so the Firestore index is
/// used *only* to answer "which folders exist" — nothing about the document is
/// needed once a folder is chosen.
class WaypointFolder {
  final String path;

  const WaypointFolder(this.path);

  /// Path without the constant `Distribution/` prefix, for display.
  String get label => path.startsWith('Distribution/')
      ? path.substring('Distribution/'.length)
      : path;

  /// The `MMM yyyy` segment, used to group the picker. Paths look like
  /// `Distribution/{year}/{MMM yyyy}/{client}[/Round N]`.
  String get month {
    final parts = path.split('/');
    return parts.length >= 3 ? parts[2] : '';
  }
}

/// Lists the folders worth seeding from.
///
/// **Names only, up front.** Each `fileFolders` document carries a map of every
/// filename in its folder, and distribution filenames are long — pulling all
/// ~340 documents is multiple megabytes to render a list of paths. Since the
/// seed then reads Cloud Storage directly, none of that payload is ever used.
///
/// The Dart Firestore SDK has no `select()`/field mask, so the listing goes
/// through the Firestore REST API with an explicit field mask, authenticated
/// with the signed-in user's ID token. That returns just the paths — a small
/// fraction of the full documents — in one request.
///
/// Per-folder detail ([gpxCountFor]) is fetched only when a folder is actually
/// selected, which is normally one or two documents rather than all of them.
///
/// The index deliberately skips `_compiled_*` files, so an entry lists only
/// source GPX. That is exactly the signal wanted here: the compile trigger
/// writes `_compiled_waypoints.json` into the folder the GPX lives in, so
/// "has GPX" is precisely "can be seeded from".
class LetterboxFolderService {
  static const String collection = 'fileFolders';

  final FirebaseFirestore? _injectedDb;
  final http.Client _http;

  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  LetterboxFolderService({FirebaseFirestore? db, http.Client? httpClient})
      : _injectedDb = db,
        _http = httpClient ?? http.Client();

  /// Document id for a folder path. Must match `fileFolderDocId` in
  /// functions/index.js, which md5-hashes the path (paths contain '/' and so
  /// cannot be document ids directly).
  static String docIdFor(String folderPath) =>
      md5.convert(utf8.encode(folderPath)).toString();

  /// Every indexed folder path, newest first.
  ///
  /// Falls back to the SDK — which downloads whole documents — only if the
  /// REST call fails, so a CORS or token problem degrades to "slow" rather
  /// than "broken".
  Future<List<WaypointFolder>> listFolderPaths() async {
    try {
      final paths = await _listPathsViaRest();
      if (paths != null) {
        debugPrint('[LetterboxFolders] ${paths.length} paths via REST '
            '(field-masked)');
        return paths.map(WaypointFolder.new).toList();
      }
    } catch (e) {
      debugPrint('[LetterboxFolders] REST listing failed, '
          'falling back to full document reads: $e');
    }
    return _listPathsViaSdk();
  }

  /// Field-masked REST query. Returns null when the caller is not signed in,
  /// so the caller can fall back rather than treating it as an error.
  Future<List<String>?> _listPathsViaRest() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) return null;

    final projectId = Firebase.app().options.projectId;
    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$projectId/databases/'
      '(default)/documents:runQuery',
    );

    final response = await _http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'structuredQuery': {
          'from': [
            {'collectionId': collection}
          ],
          // The whole point: ask for one field, not the filename maps.
          'select': {
            'fields': [
              {'fieldPath': 'folderPath'}
            ]
          },
          'orderBy': [
            {
              'field': {'fieldPath': 'folderPath'},
              'direction': 'DESCENDING'
            }
          ],
        }
      }),
    );

    if (response.statusCode != 200) {
      debugPrint('[LetterboxFolders] REST query HTTP ${response.statusCode}: '
          '${response.body.substring(0, response.body.length.clamp(0, 300))}');
      return null;
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;

    final paths = <String>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      final doc = row['document'];
      if (doc is! Map) continue;
      final value = (doc['fields'] as Map?)?['folderPath'];
      final path = (value as Map?)?['stringValue'] as String?;
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    return paths;
  }

  /// Fallback: whole-document reads through the SDK.
  Future<List<WaypointFolder>> _listPathsViaSdk() async {
    final snap = await _db
        .collection(collection)
        .orderBy('folderPath', descending: true)
        .get();
    final folders = <WaypointFolder>[];
    for (final doc in snap.docs) {
      final path = doc.data()['folderPath'] as String?;
      if (path != null && path.isNotEmpty) folders.add(WaypointFolder(path));
    }
    debugPrint('[LetterboxFolders] ${folders.length} paths via SDK fallback');
    return folders;
  }

  /// How many GPX files a folder holds. One document read, done only when the
  /// user actually selects the folder.
  ///
  /// Returns null when the folder has no index entry.
  Future<int?> gpxCountFor(String folderPath) async {
    try {
      final doc =
          await _db.collection(collection).doc(docIdFor(folderPath)).get();
      final data = doc.data();
      if (!doc.exists || data == null) return null;
      final files = (data['files'] as Map?)?.keys ?? const [];
      return files
          .where((n) => n.toString().toLowerCase().endsWith('.gpx'))
          .length;
    } catch (e) {
      debugPrint('[LetterboxFolders] gpxCountFor($folderPath) failed: $e');
      return null;
    }
  }
}
