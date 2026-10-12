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
//
// Metadata cannot travel as request headers here. `Cache-Control` and
// `x-goog-meta-*` are not CORS-safelisted, so the browser preflights them and
// the bucket's CORS configuration does not list them in
// Access-Control-Allow-Headers — the upload is then rejected before any bytes
// are sent. Anything beyond `Content-Type` therefore goes in the request body
// as a `multipart/related` document, which is what the Firebase JS SDK does.
//
// The multipart request must be shaped EXACTLY as the JS SDK shapes it: the
// `X-Goog-Upload-Protocol: multipart` header is what makes the endpoint read
// the body as two parts. A `?uploadType=multipart` query parameter — the
// spelling the *GCS JSON* API uses — is silently ignored here, and the
// endpoint then stores the JSON metadata part as the file's entire contents.
// That fails silently: the POST returns 200 and a normal metadata response,
// `getDownloadURL()` hands back a working URL, and only whatever tries to
// decode the bytes later ever finds out. Verified against the live bucket:
// with the query param and no header a PNG upload stored 99 bytes of
// `application/json`; with the header and no query param it stored the image.

import 'dart:convert';
import 'dart:math';

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
    final contentType = metadata?.contentType ?? 'application/octet-stream';

    final extras = _metadataFields(metadata);

    // Only Content-Type can safely be a header. With nothing else to send,
    // keep the simple `media` upload; otherwise switch to `multipart` so the
    // metadata rides in the body instead of in blocked headers.
    final useMultipart = extras.isNotEmpty;

    final String boundary;
    final Uint8List body;
    if (useMultipart) {
      boundary = _boundary();
      body = buildMultipartBody(
        metadata: {'name': path, 'contentType': contentType, ...extras},
        bytes: bytes,
        boundary: boundary,
        contentType: contentType,
      );
    } else {
      boundary = '';
      body = bytes;
    }

    final request = buildUploadRequest(
      bucket: bucket,
      path: path,
      contentType: contentType,
      useMultipart: useMultipart,
      boundary: boundary,
    );
    final uri = request.uri;
    final headers = Map<String, String>.from(request.headers);

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

    final response = await http.post(uri, headers: headers, body: body);
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

  /// The URL and headers for an upload POST — everything about the request
  /// except the body and the caller's auth token.
  ///
  /// Exposed for testing because this envelope, not the body, is where the
  /// format is load-bearing and silently so. A wrong `Content-Type` or a
  /// missing `X-Goog-Upload-Protocol` still returns HTTP 200 and still yields
  /// a working download URL; the only symptom is that the stored object holds
  /// the wrong bytes. There is nothing to assert after the fact, so it has to
  /// be asserted here.
  @visibleForTesting
  static ({Uri uri, Map<String, String> headers}) buildUploadRequest({
    required String bucket,
    required String path,
    required String contentType,
    required bool useMultipart,
    required String boundary,
  }) {
    // `name` is the only query parameter the v0 endpoint wants. Notably NOT
    // `uploadType` — that is the GCS JSON API's spelling and is ignored here.
    final uri = Uri.parse(
      'https://firebasestorage.googleapis.com/v0/b/$bucket/o'
      '?name=${Uri.encodeComponent(path)}',
    );

    return (
      uri: uri,
      headers: <String, String>{
        'Content-Type': useMultipart
            ? 'multipart/related; boundary=$boundary'
            : contentType,
        // The switch between a one-part and a two-part body. Without it the
        // endpoint keeps only the metadata part — see the note at the top.
        if (useMultipart) 'X-Goog-Upload-Protocol': 'multipart',
      },
    );
  }

  /// Metadata fields that cannot be sent as headers, in the JSON shape the
  /// Storage API expects. Custom entries live under `metadata`, matching
  /// `SettableMetadata.customMetadata`.
  static Map<String, dynamic> _metadataFields(SettableMetadata? metadata) {
    if (metadata == null) return const {};

    final fields = <String, dynamic>{};
    final cacheControl = metadata.cacheControl;
    if (cacheControl != null) fields['cacheControl'] = cacheControl;
    final contentDisposition = metadata.contentDisposition;
    if (contentDisposition != null) {
      fields['contentDisposition'] = contentDisposition;
    }
    final contentEncoding = metadata.contentEncoding;
    if (contentEncoding != null) fields['contentEncoding'] = contentEncoding;
    final contentLanguage = metadata.contentLanguage;
    if (contentLanguage != null) fields['contentLanguage'] = contentLanguage;
    final custom = metadata.customMetadata;
    if (custom != null && custom.isNotEmpty) fields['metadata'] = custom;
    return fields;
  }

  /// Build a `multipart/related` body: a JSON metadata part, then the file.
  ///
  /// Exposed for testing — the wire format is fiddly and a malformed body is
  /// rejected by the server rather than caught by the type system.
  @visibleForTesting
  static Uint8List buildMultipartBody({
    required Map<String, dynamic> metadata,
    required Uint8List bytes,
    required String boundary,
    required String contentType,
  }) {
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Type: application/json; charset=utf-8\r\n\r\n'
      '${jsonEncode(metadata)}\r\n'
      '--$boundary\r\n'
      'Content-Type: $contentType\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--');

    final body = Uint8List(head.length + bytes.length + tail.length);
    body.setAll(0, head);
    body.setAll(head.length, bytes);
    body.setAll(head.length + bytes.length, tail);
    return body;
  }

  /// A boundary that will not occur inside the payload. 128 random bits makes
  /// a collision with arbitrary binary content vanishingly unlikely, which is
  /// the same bet the Firebase JS SDK makes.
  static String _boundary() {
    final random = Random.secure();
    final hex = List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return 'clm$hex';
  }
}
