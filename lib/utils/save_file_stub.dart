// Mobile/desktop stub.
//
// The File System Access API is web-only. Native platforms get the OS share
// or save sheet instead, so this always reports "unavailable" and the caller
// falls back.
import 'save_file_types.dart';

export 'save_file_types.dart';

Future<SavePick> pickSaveFile({
  required String suggestedName,
  String mimeType = 'application/pdf',
  String typeDescription = 'PDF document',
  String extension = '.pdf',
}) async =>
    const SavePick(SavePickStatus.unavailable);
