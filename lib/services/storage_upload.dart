// services/storage_upload.dart
//
// WASM-safe Firebase Storage upload helper.
//
// The `firebase_storage_web 3.9.x` build that resolves with
// `firebase_core ^3.4` throws
// `Type 'Uint8List' is not a subtype of type 'JSValue' in type cast`
// when `Reference.putData(Uint8List)` is invoked under dart2wasm.
// The older base64 `putString` workaround also fails the same cast.
//
// To unblock uploads on WASM we POST directly to the Firebase Storage
// REST upload endpoint via `package:http` (which uses `package:web`
// fetch internally and is WASM-safe).

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class StorageUpload {
  StorageUpload._();

  /// Upload [bytes] to [ref]. On native this uses the regular
  /// `ref.putData(...)` path. On web it falls back to a REST POST to
  /// avoid the dart2wasm JS-interop bug.
  static Future<void> safePutData(
    Reference ref,
    Uint8List bytes, {
    SettableMetadata? metadata,
  }) async {
    if (kIsWeb) {
      await _restUpload(ref, bytes, metadata: metadata);
    } else {
      await ref.putData(bytes, metadata);
    }
  }

  /// Web-only: upload [bytes] to [ref] via the Storage REST API.
  static Future<void> _restUpload(
    Reference ref,
    Uint8List bytes, {
    SettableMetadata? metadata,
  }) async {
    final bucket = ref.bucket;
    final path = ref.fullPath;
    final encodedName = Uri.encodeComponent(path);
    final contentType = metadata?.contentType ?? 'application/octet-stream';

    final uri = Uri.parse(
      'https://firebasestorage.googleapis.com/v0/b/$bucket/o'
      '?uploadType=media&name=$encodedName',
    );

    final headers = <String, String>{
      'Content-Type': contentType,
    };

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final token = await user.getIdToken();
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Firebase $token';
        }
      }
    } catch (e) {
      debugPrint('StorageUpload: token fetch failed: $e');
    }

    final custom = metadata?.customMetadata;
    if (custom != null) {
      for (final entry in custom.entries) {
        headers['x-goog-meta-${entry.key}'] = entry.value;
      }
    }
    final cacheControl = metadata?.cacheControl;
    if (cacheControl != null) headers['Cache-Control'] = cacheControl;
    final contentDisposition = metadata?.contentDisposition;
    if (contentDisposition != null) {
      headers['Content-Disposition'] = contentDisposition;
    }
    final contentEncoding = metadata?.contentEncoding;
    if (contentEncoding != null) {
      headers['Content-Encoding'] = contentEncoding;
    }
    final contentLanguage = metadata?.contentLanguage;
    if (contentLanguage != null) {
      headers['Content-Language'] = contentLanguage;
    }

    final response = await http.post(uri, headers: headers, body: bytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FirebaseException(
        plugin: 'firebase_storage',
        code: 'upload-failed',
        message:
            'REST upload to $path failed: HTTP ${response.statusCode} '
            '${response.body}',
      );
    }
  }
}
