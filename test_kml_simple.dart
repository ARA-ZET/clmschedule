// Simple Dart test for KML download functionality
import 'dart:io';
import 'dart:convert';

Future<void> main() async {
  print('Testing KML download with Google My Maps URL...');

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
    print('Downloading KML content...');
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(kmlUrl));
    final response = await request.close();

    print('Response status: ${response.statusCode}');
    print('Content-Type: ${response.headers.contentType}');

    if (response.statusCode == 200) {
      final bytes = await response.fold<List<int>>(
          [], (previous, element) => previous..addAll(element));
      final content = utf8.decode(bytes);

      print('Content length: ${content.length} characters');
      print('First 500 characters:');
      print(content.substring(0, content.length > 500 ? 500 : content.length));

      // Check if it's actually KML or HTML
      if (content.toLowerCase().contains('<html')) {
        print(
            '⚠️  Response is HTML, not KML. This likely means the map is private or requires authentication.');
      } else if (content.toLowerCase().contains('<kml')) {
        print('✅ Successfully downloaded KML content!');
      } else {
        print('❓ Unknown content type received.');
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
