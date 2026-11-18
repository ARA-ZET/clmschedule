// utils/browser_file_drop.dart
//
// Files and folders dragged in from the computer, and Drive-style "Folder
// upload". Exports the web implementation when dart:js_interop is
// available; elsewhere both are unavailable (null).
export 'local_upload_file.dart';
export 'browser_file_drop_stub.dart'
    if (dart.library.js_interop) 'browser_file_drop_web.dart';
