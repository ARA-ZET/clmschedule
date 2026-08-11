// Platform-conditional export for browser (Web Notification API) alerts.
export 'browser_notification_stub.dart'
    if (dart.library.html) 'browser_notification_web.dart';
