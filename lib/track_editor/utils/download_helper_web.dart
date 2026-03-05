// track_editor/utils/download_helper_web.dart
// Web implementation: triggers a browser file download.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<void> downloadStringAsFile(String content, String fileName) async {
  final blob = html.Blob([content]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}
