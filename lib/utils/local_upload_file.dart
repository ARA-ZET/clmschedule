// utils/local_upload_file.dart
//
// A file from the user's computer waiting to be uploaded — shared by the
// browser drop/folder-pick implementations and their callers.
import 'dart:typed_data';

class LocalUploadFile {
  /// Path relative to where it was dropped or picked: "a.jpg", or
  /// "Photos/a.jpg" when it came inside a folder.
  final String relativePath;
  final int size;

  /// Reads the bytes. Deferred so a large drop is not held in memory all at
  /// once — each file is read only when its upload starts.
  final Future<Uint8List> Function() read;

  const LocalUploadFile({
    required this.relativePath,
    required this.size,
    required this.read,
  });

  String get name => relativePath.split('/').last;
}
