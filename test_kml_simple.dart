import 'package:flutter/foundation.dart';
// Simple Dart test for KML download functionality
import 'dart:io';
import 'dart:convert';

Future<void> main() async {
  if (kDebugMode) {
    print('Testing KML download with Google My Maps URL...');
  }

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    if (kDebugMode) {
      print('Converting Google My Maps URL to KML format...');
    }

    // Extract map ID from the URL
    final uri = Uri.parse(googleMapsUrl);
    final mid = uri.queryParameters['mid'];

    if (mid == null) {
      throw Exception('Could not extract map ID from URL');
    }

    // Convert to direct KML URL
    final kmlUrl = 'https://www.google.com/maps/d/kml?mid=$mid';
    if (kDebugMode) {
      print('KML URL: $kmlUrl');
    }

    // Download the KML content
    if (kDebugMode) {
      print('Downloading KML content...');
    }
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(kmlUrl));
    final response = await request.close();

    if (kDebugMode) {
      print('Response status: ${response.statusCode}');
    }
    if (kDebugMode) {
      print('Content-Type: ${response.headers.contentType}');
    }

    if (response.statusCode == 200) {
      final bytes = await response.fold<List<int>>(
          [], (previous, element) => previous..addAll(element));
      final content = utf8.decode(bytes);

      if (kDebugMode) {
        print('Content length: ${content.length} characters');
      }
      if (kDebugMode) {
        print('First 500 characters:');
      }
      if (kDebugMode) {
        print(
            content.substring(0, content.length > 500 ? 500 : content.length));
      }

      // Check if it's actually KML or HTML
      if (content.toLowerCase().contains('<html')) {
        if (kDebugMode) {
          print(
              '⚠️  Response is HTML, not KML. This likely means the map is private or requires authentication.');
        }
      } else if (content.toLowerCase().contains('<kml')) {
        if (kDebugMode) {
          print('✅ Successfully downloaded KML content!');
        }
      } else {
        if (kDebugMode) {
          print('❓ Unknown content type received.');
        }
      }
    } else {
      if (kDebugMode) {
        print('❌ Failed to download. Status: ${response.statusCode}');
      }
      if (response.statusCode == 403) {
        if (kDebugMode) {
          print('The map might be private or access is restricted.');
        }
      } else if (response.statusCode == 404) {
        if (kDebugMode) {
          print('The map might not exist or the URL is incorrect.');
        }
      }
    }

    client.close();
  } catch (e) {
    if (kDebugMode) {
      print('❌ Error: $e');
    }
  }
}
