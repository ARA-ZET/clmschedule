// track_editor/utils/download_helper.dart
// Exports the correct implementation based on platform.
export 'download_helper_stub.dart'
    if (dart.library.html) 'download_helper_web.dart';
