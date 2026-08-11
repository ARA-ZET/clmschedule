// Web implementation: fire OS-level notifications via the browser
// Notification API. Only works while the app is open in a tab (no
// service worker/FCM is set up, so this cannot wake a closed tab).
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<void> requestBrowserNotificationPermission() async {
  if (!html.Notification.supported) return;
  if (html.Notification.permission == 'granted') return;
  if (html.Notification.permission == 'denied') return;
  await html.Notification.requestPermission();
}

void showBrowserNotification({
  required String title,
  required String body,
  String? tag,
}) {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') return;

  html.Notification(
    title,
    body: body,
    tag: tag,
    icon: '/icons/Icon-192.png',
  );
}
