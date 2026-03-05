// track_editor/utils/html_file_reader_web.dart
// Web implementation: reads an html.File dragged into the browser.
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

bool isHtmlFile(Object data) => data is html.File;
String htmlFileName(Object data) => (data as html.File).name;

Future<Uint8List> readHtmlFile(Object data) async {
  final file = data as html.File;
  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  return reader.result as Uint8List;
}
