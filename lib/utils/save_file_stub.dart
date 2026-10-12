// Mobile/desktop stub.
//
// The File System Access API is web-only. Native platforms get the OS share
// or save sheet from the printing package instead, so this always reports
// "unavailable" and the caller falls back.
import 'dart:typed_data';

Future<bool> saveFileWithPicker({
  required String suggestedName,
  required Uint8List bytes,
  String mimeType = 'application/pdf',
  String typeDescription = 'PDF document',
  String extension = '.pdf',
}) async =>
    false;
