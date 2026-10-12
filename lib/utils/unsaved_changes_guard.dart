// Warns before the browser tab closes while schedule writes are still being
// saved. A no-op off the web; the web implementation is picked by
// conditional import.
export 'unsaved_changes_guard_stub.dart'
    if (dart.library.js_interop) 'unsaved_changes_guard_web.dart';
