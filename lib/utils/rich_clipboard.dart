// utils/rich_clipboard.dart
//
// Put formatted (HTML) text on the clipboard alongside its plain-text form,
// so pasting into Gmail keeps tables and bold. Exports the web
// implementation when dart:js_interop is available, otherwise a stub that
// copies the plain text only.
export 'rich_clipboard_stub.dart'
    if (dart.library.js_interop) 'rich_clipboard_web.dart';
