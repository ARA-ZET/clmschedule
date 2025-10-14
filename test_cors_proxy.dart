// Test CORS proxy for Google My Maps
import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  print('Testing CORS proxy for Google My Maps...');

  const kmlUrl =
      'https://www.google.com/maps/d/kml?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM';
  final proxyUrl =
      'https://api.allorigins.win/raw?url=${Uri.encodeComponent(kmlUrl)}';

  print('Original URL: $kmlUrl');
  print('Proxy URL: $proxyUrl');

  try {
    final response = await http.get(Uri.parse(proxyUrl));

    print('Response status: ${response.statusCode}');
    print('Content length: ${response.bodyBytes.length} bytes');
    print('Content-Type: ${response.headers['content-type']}');

    if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
      // Check if it's binary (KMZ) or text (KML)
      final firstBytes = response.bodyBytes.take(10).toList();
      if (firstBytes.length >= 4 &&
          firstBytes[0] == 0x50 &&
          firstBytes[1] == 0x4B) {
        print(
            '✅ CORS proxy successfully returned KMZ data (${response.bodyBytes.length} bytes)');
      } else {
        try {
          final content = utf8.decode(response.bodyBytes);
          if (content.toLowerCase().contains('<kml')) {
            print('✅ CORS proxy successfully returned KML data');
          } else {
            print('⚠️ CORS proxy returned unexpected content');
            print(
                'First 200 chars: ${content.substring(0, content.length > 200 ? 200 : content.length)}');
          }
        } catch (e) {
          print('❌ Could not decode response as text: $e');
        }
      }
    } else {
      print('❌ CORS proxy failed: ${response.statusCode}');
    }
  } catch (e) {
    print('❌ Error using CORS proxy: $e');
  }
}
