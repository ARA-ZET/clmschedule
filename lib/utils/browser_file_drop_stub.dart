// utils/browser_file_drop_stub.dart
//
// Non-web: no page to drop onto and no folder input.
import 'dart:ui' show Offset, VoidCallback;

import 'local_upload_file.dart';

abstract class BrowserFileDrop {
  void dispose();
}

BrowserFileDrop? listenForFileDrops({
  required void Function(Offset position) onOver,
  required VoidCallback onLeave,
  required void Function(Offset position, Future<List<LocalUploadFile>> files)
      onDrop,
}) =>
    null;

bool get canPickFolderForUpload => false;

Future<List<LocalUploadFile>?> pickFolderForUpload() async => null;
