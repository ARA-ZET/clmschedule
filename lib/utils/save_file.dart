// Web-specific implementation.
import 'dart:js_interop';
// Provides `has` for feature-detecting showSaveFilePicker on the global.
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web/web.dart' as web;

import 'save_file_types.dart';

export 'save_file_types.dart';

/// Minimal bindings for the File System Access API.
///
/// `package:web` does not expose `showSaveFilePicker`, so the handle and
/// writable-stream types are declared here.
extension type _WritableStream._(JSObject _) implements JSObject {
  external JSPromise write(JSAny data);
  external JSPromise close();
  external JSPromise abort();
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external String get name;
  external JSPromise<_WritableStream> createWritable();
  external JSPromise remove();
}

@JS('window.showSaveFilePicker')
external JSPromise<_FileHandle> _showSaveFilePicker(JSAny options);

/// Open the OS "Save As" dialog (File System Access API — Chrome and Edge).
///
/// **Call this first thing in a click handler**, before awaiting anything
/// slow: Chrome only opens the dialog within ~5 s of the click and otherwise
/// throws `SecurityError`. Fetch the file's bytes after the user has picked.
///
/// Files written this way never appear in the browser's Downloads list —
/// that is the API's design, not something the page can change.
Future<SavePick> pickSaveFile({
  required String suggestedName,
  String mimeType = 'application/pdf',
  String typeDescription = 'PDF document',
  String extension = '.pdf',
}) async {
  // Browsers only offer the dialog on https:// (and localhost) — opening the
  // app by a plain http:// network address silently loses it.
  if (!web.window.isSecureContext) {
    return const SavePick(SavePickStatus.unavailable,
        error: "the page isn't on a secure https:// address");
  }
  // Feature-detect rather than sniff the user agent.
  if (!globalContext.has('showSaveFilePicker')) {
    return const SavePick(SavePickStatus.unavailable,
        error: 'only Chrome and Edge have one');
  }

  final options = {
    'suggestedName': suggestedName,
    'types': [
      {
        'description': typeDescription,
        'accept': {
          mimeType: [extension],
        },
      },
    ],
  }.jsify()!;

  // Chrome closes the dialog itself — with the same AbortError as Cancel —
  // when the tab stops counting as visible (see browserClosedSaveDialog).
  // Watch for that so it isn't reported as the user cancelling.
  var pageWasHidden = web.document.hidden;
  final onVisibility = ((web.Event _) {
    if (web.document.hidden) pageWasHidden = true;
  }).toJS;
  web.document.addEventListener('visibilitychange', onVisibility);
  final clock = Stopwatch()..start();

  try {
    final handle = await _showSaveFilePicker(options).toDart;
    return SavePick(SavePickStatus.picked, target: _WebSaveTarget(handle));
  } catch (e) {
    final elapsed = clock.elapsed;
    final isAbort = e.toString().contains('AbortError');
    if (isAbort && !pageWasHidden) {
      // Chrome sends "page hidden" and "dialog closed" separately, so the
      // visibility news can land just after the rejection.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // Logged so F12 → Console shows Chrome's exact words, plus what is
    // needed to tell a real Cancel from Chrome closing the dialog itself.
    debugPrint('[save] Save dialog rejected after ${elapsed.inMilliseconds} ms '
        '(page hidden meanwhile: $pageWasHidden, '
        'window ${web.window.outerWidth}x${web.window.outerHeight}, '
        '${_browserVersion()}): $e');
    if (!isAbort) return SavePick(SavePickStatus.failed, error: e);

    final chromeDidIt = browserClosedSaveDialog(
        elapsed: elapsed, pageWasHidden: pageWasHidden);
    if (chromeDidIt != null) {
      return SavePick(SavePickStatus.closedByBrowser, error: chromeDidIt);
    }
    // Only the dialog itself reports a dismissal as AbortError. Errors from
    // the later write are real failures and are handled in write().
    //
    // Chrome also says AbortError when the user backs out of its own "can't
    // save to this folder" (Program Files, Windows, AppData) or
    // "dangerous file" prompt — the user saw that prompt, so "cancelled"
    // still fits.
    return const SavePick(SavePickStatus.cancelled);
  } finally {
    web.document.removeEventListener('visibilitychange', onVisibility);
  }
}

/// "Chrome 142" / "Edge 142", for the console log.
String _browserVersion() {
  final match = RegExp(r'(Edg|Chrome)/(\d+)')
      .allMatches(web.window.navigator.userAgent)
      .lastOrNull;
  if (match == null) return 'unknown browser';
  return '${match.group(1) == 'Edg' ? 'Edge' : 'Chrome'} ${match.group(2)}';
}

class _WebSaveTarget implements SaveTarget {
  final _FileHandle _handle;

  _WebSaveTarget(this._handle);

  @override
  String get fileName => _handle.name;

  @override
  Future<void> write(Uint8List bytes, String mimeType) async {
    final writable = await _handle.createWritable().toDart;
    try {
      final blob = web.Blob(
        [bytes.toJS].toJS,
        web.BlobPropertyBag(type: mimeType),
      );
      await writable.write(blob as JSAny).toDart;
      // close() is what commits: Chrome writes to a ".crswap" file beside
      // the target and only moves it into place here.
      await writable.close().toDart;
    } catch (e) {
      debugPrint('[save] Writing "${_handle.name}" failed: $e');
      // Drop the half-written swap file; the stream may already be closed.
      try {
        await writable.abort().toDart;
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<bool> discard() async {
    if (!_handle.has('remove')) return false;
    try {
      await _handle.remove().toDart;
      return true;
    } catch (_) {
      return false;
    }
  }
}
