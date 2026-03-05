// Platform-conditional export for browser URL updates.
export 'url_updater_stub.dart' if (dart.library.html) 'url_updater_web.dart';
