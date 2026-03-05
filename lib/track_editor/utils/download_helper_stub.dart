// track_editor/utils/download_helper_stub.dart
// Non-web stub: save to device storage using path_provider.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> downloadStringAsFile(String content, String fileName) async {
  try {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(content);
    debugPrint('✅ Saved $fileName to ${file.path}');
  } catch (e) {
    debugPrint('❌ Failed to save $fileName: $e');
  }
}
