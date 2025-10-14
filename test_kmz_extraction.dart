// Test script for KML/KMZ download functionality
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

Future<void> main() async {
  print('Testing KML/KMZ download with Google My Maps URL...');

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    print('Converting Google My Maps URL to KML format...');

    // Extract map ID from the URL
    final uri = Uri.parse(googleMapsUrl);
    final mid = uri.queryParameters['mid'];

    if (mid == null) {
      throw Exception('Could not extract map ID from URL');
    }

    // Convert to direct KML URL
    final kmlUrl = 'https://www.google.com/maps/d/kml?mid=$mid';
    print('KML URL: $kmlUrl');

    // Download the KML content
    print('Downloading KML/KMZ content...');
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(kmlUrl));
    final response = await request.close();

    print('Response status: ${response.statusCode}');
    print('Content-Type: ${response.headers.contentType}');

    if (response.statusCode == 200) {
      final bytes = await response.fold<List<int>>(
          [], (previous, element) => previous..addAll(element));
      final bodyBytes = Uint8List.fromList(bytes);

      print('Content length: ${bodyBytes.length} bytes');

      final contentType = response.headers.contentType?.mimeType.toLowerCase();

      if (contentType == 'application/vnd.google-earth.kmz' ||
          contentType == 'application/zip') {
        print('📦 KMZ file detected, extracting KML...');

        try {
          final archive = ZipDecoder().decodeBytes(bodyBytes);
          print('Archive contains ${archive.length} files:');

          for (final file in archive) {
            print('  - ${file.name} (${file.size} bytes)');

            if (file.name.toLowerCase().endsWith('.kml')) {
              final kmlContent = utf8.decode(file.content as List<int>);
              print('✅ Found KML file: ${file.name}');
              print('KML content length: ${kmlContent.length} characters');
              print('First 500 characters of KML:');
              print(kmlContent.substring(
                  0, kmlContent.length > 500 ? 500 : kmlContent.length));
              break;
            }
          }
        } catch (e) {
          print('❌ Failed to extract KMZ: $e');
        }
      } else {
        // Try to decode as text
        try {
          final content = utf8.decode(bodyBytes);
          print('First 500 characters:');
          print(content.substring(
              0, content.length > 500 ? 500 : content.length));

          if (content.toLowerCase().contains('<html')) {
            print(
                '⚠️  Response is HTML, not KML. This likely means the map is private or requires authentication.');
          } else if (content.toLowerCase().contains('<kml')) {
            print('✅ Successfully downloaded KML content!');
          } else {
            print('❓ Unknown content type received.');
          }
        } catch (e) {
          print('❌ Could not decode content as text: $e');
        }
      }
    } else {
      print('❌ Failed to download. Status: ${response.statusCode}');
      if (response.statusCode == 403) {
        print('The map might be private or access is restricted.');
      } else if (response.statusCode == 404) {
        print('The map might not exist or the URL is incorrect.');
      }
    }

    client.close();
  } catch (e) {
    print('❌ Error: $e');
  }
}
