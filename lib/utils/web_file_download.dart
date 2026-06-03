// utils/web_file_download.dart
//
// Platform-agnostic entry point for triggering a file download/save.
// Exports the web implementation when dart:js_interop is available
// (i.e. when compiling for the browser), otherwise the IO stub.
export 'web_file_download_stub.dart'
    if (dart.library.js_interop) 'web_file_download_web.dart';
