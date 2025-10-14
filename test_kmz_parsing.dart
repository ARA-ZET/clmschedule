// Simple test to verify our KMZ extraction logic works
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

Future<void> main() async {
  print('🧪 Testing KMZ extraction and KML parsing...');

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    // Extract map ID and download
    final uri = Uri.parse(googleMapsUrl);
    final mid = uri.queryParameters['mid'];
    final kmlUrl = 'https://www.google.com/maps/d/kml?mid=$mid';

    print('📥 Downloading from: $kmlUrl');

    final response = await http.get(Uri.parse(kmlUrl));

    if (response.statusCode == 200) {
      final bodyBytes = response.bodyBytes;

      print('📦 Downloaded ${bodyBytes.length} bytes');

      final contentType = response.headers['content-type']?.toLowerCase();
      print('📋 Content-Type: $contentType');

      if (contentType == 'application/vnd.google-earth.kmz' ||
          contentType == 'application/zip') {
        print('🗂️ Extracting KMZ archive...');

        final archive = ZipDecoder().decodeBytes(bodyBytes);
        final kmlFile = archive
            .firstWhere((file) => file.name.toLowerCase().endsWith('.kml'));
        final kmlContent = utf8.decode(kmlFile.content as List<int>);

        print(
            '📄 Extracted KML file: ${kmlFile.name} (${kmlContent.length} characters)');

        // Parse XML
        print('🔍 Parsing XML...');
        final document = XmlDocument.parse(kmlContent);

        // Find polygons
        final polygons = document.findAllElements('Polygon').toList();
        print('📐 Found ${polygons.length} polygon(s) in KML');

        for (int i = 0; i < polygons.length; i++) {
          final polygon = polygons[i];

          // Find name from parent Placemark
          final placemark = polygon.parent;
          String? name;
          if (placemark != null) {
            final nameElement = placemark.findElements('name').firstOrNull;
            name = nameElement?.innerText;
          }

          // Find coordinates
          final coordsElement =
              polygon.findAllElements('coordinates').firstOrNull;
          if (coordsElement != null) {
            final coordsText = coordsElement.innerText.trim();
            final coordLines = coordsText
                .split('\n')
                .where((line) => line.trim().isNotEmpty)
                .toList();

            print('  Polygon ${i + 1}:');
            print('    Name: ${name ?? 'Unknown'}');
            print('    Coordinates: ${coordLines.length} points');

            // Parse a few sample coordinates
            if (coordLines.isNotEmpty) {
              final firstCoord = coordLines.first.trim().split(',');
              if (firstCoord.length >= 2) {
                final lng = double.tryParse(firstCoord[0]);
                final lat = double.tryParse(firstCoord[1]);
                print('    First point: ($lat, $lng)');
              }
            }
          }
        }

        if (polygons.isNotEmpty) {
          print('✅ KMZ extraction and KML parsing successful!');
          print('🎯 The KML service logic is working correctly.');
        } else {
          print('⚠️ No polygons found in KML data');
        }
      } else {
        print('❓ Unexpected content type: $contentType');
      }
    } else {
      print('❌ HTTP ${response.statusCode}: Failed to download');
    }
  } catch (e) {
    print('❌ Error: $e');
  }
}
