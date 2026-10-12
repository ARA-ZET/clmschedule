// Web-specific implementation.
import 'dart:js_interop';
// Provides `has` for feature-detecting showSaveFilePicker on the global.
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Minimal bindings for the File System Access API.
///
/// `package:web` does not expose `showSaveFilePicker`, so the handle and
/// writable-stream types are declared here.
extension type _WritableStream._(JSObject _) implements JSObject {
  external JSPromise write(JSAny data);
  external JSPromise close();
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<_WritableStream> createWritable();
}

@JS('window.showSaveFilePicker')
external JSPromise<_FileHandle> _showSaveFilePicker(JSAny options);

/// Save [bytes] letting the user choose the folder and filename.
///
/// Uses the File System Access API, which opens the OS "Save As" dialog.
/// Supported in Chrome and Edge; absent in Firefox and Safari.
///
/// Returns **false** when the picker is unavailable, so the caller can fall
/// back to an ordinary download. Returns **true** when the file was saved, and
/// also when the user cancelled — a deliberate cancel must not then dump the
/// file into the default folder behind their back.
Future<bool> saveFileWithPicker({
  required String suggestedName,
  required Uint8List bytes,
  String mimeType = 'application/pdf',
  String typeDescription = 'PDF document',
  String extension = '.pdf',
}) async {
  // Feature-detect rather than sniff the user agent.
  if (!globalContext.has('showSaveFilePicker')) return false;

  try {
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

    final handle = await _showSaveFilePicker(options).toDart;
    final writable = await handle.createWritable().toDart;
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    await writable.write(blob as JSAny).toDart;
    await writable.close().toDart;
    return true;
  } catch (e) {
    // AbortError is thrown when the user dismisses the dialog — that is a
    // completed interaction, not a failure to fall back from.
    if (e.toString().contains('AbortError')) return true;
    // Anything else (permission denied, disk error) falls back to a plain
    // download so the user still gets the file.
    return false;
  }
}
