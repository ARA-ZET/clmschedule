// utils/web_file_download_web.dart
//
// Web implementation: wraps bytes in a Blob, creates an object URL, and
// programmatically clicks a temporary <a download="..."> element so the
// browser presents its native Save-As / Downloads flow.
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Trigger a browser file-download for [bytes] with [fileName].
/// Returns `null` (there is no saved path on web). Errors are logged and
/// swallowed unless [rethrowErrors] — then the caller can report them
/// instead of claiming a download that never started.
///
/// The browser gives the page no word on whether the download then went
/// ahead: it can still block it (repeated automatic downloads, a site set to
/// "Don't allow downloads").
Future<String?> triggerFileDownload(
  Uint8List bytes,
  String fileName,
  String mimeType, {
  bool rethrowErrors = false,
}) async {
  try {
    // `bytes.toJS`, not `bytes.buffer.toJS`: a Uint8List view shares a
    // larger buffer, and the whole buffer would be written.
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);

    final a = web.document.createElement('a') as web.HTMLAnchorElement;
    a.href = url;
    a.download = fileName;
    web.document.body?.appendChild(a);
    a.click();
    web.document.body?.removeChild(a);
    // Browsers can read the blob well after click() returns — e.g. once the
    // user answers an "Allow downloads?" prompt. Revoking too early fails the
    // download ("no file") with nothing reported to the page.
    Future.delayed(
        const Duration(minutes: 10), () => web.URL.revokeObjectURL(url));
    return null;
  } catch (e) {
    debugPrint('triggerFileDownload (web) error: $e');
    if (rethrowErrors) rethrow;
    return null;
  }
}

/// Start a native browser download of [url] — for server-built files whose
/// response is `Content-Disposition: attachment`, so the page stays put and
/// the browser streams it to disk with its own progress bar.
Future<void> triggerUrlDownload(String url, String fileName) async {
  final a = web.document.createElement('a') as web.HTMLAnchorElement;
  a.href = url;
  a.download = fileName;
  a.rel = 'noopener';
  web.document.body?.appendChild(a);
  a.click();
  web.document.body?.removeChild(a);
}
