// utils/web_file_download_web.dart
//
// Web implementation: wraps bytes in a Blob, creates an object URL, and
// programmatically clicks a temporary <a download="..."> element so the
// browser presents its native Save-As / Downloads flow.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Trigger a browser file-download for [bytes] with [fileName].
/// Returns `null` (there is no saved path on web).
Future<String?> triggerFileDownload(
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  try {
    final blob = web.Blob(
      [bytes.buffer.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);

    final a = web.document.createElement('a') as web.HTMLAnchorElement;
    a.href = url;
    a.download = fileName;
    web.document.body?.appendChild(a);
    a.click();
    web.document.body?.removeChild(a);
    web.URL.revokeObjectURL(url);
    return null;
  } catch (e) {
    debugPrint('triggerFileDownload (web) error: $e');
    return null;
  }
}
