// track_editor/utils/html_file_reader.dart
// Exports the correct implementation based on platform.
export 'html_file_reader_stub.dart'
    if (dart.library.html) 'html_file_reader_web.dart';
