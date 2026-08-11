/// Stub (non-web): no-op — browser notifications only apply on web.
Future<void> requestBrowserNotificationPermission() async {}

void showBrowserNotification({
  required String title,
  required String body,
  String? tag,
}) {}
