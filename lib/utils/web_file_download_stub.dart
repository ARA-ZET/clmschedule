// utils/web_file_download_stub.dart
//
// Non-web (dart:io) implementation: saves bytes to the downloads directory
// or the app documents directory as a fallback.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Save [bytes] as [fileName] to the device downloads folder.
/// Returns the saved file path on success, or `null` on failure.
/// On web this file is never used — see `web_file_download_web.dart`.
Future<String?> triggerFileDownload(
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  try {
    Directory? dir;
    if (Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux) {
      dir = await getDownloadsDirectory();
    }
    dir ??= await getApplicationDocumentsDirectory();

    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    debugPrint('triggerFileDownload: saved to ${file.path}');
    return file.path;
  } catch (e) {
    debugPrint('triggerFileDownload error: $e');
    return null;
  }
}
