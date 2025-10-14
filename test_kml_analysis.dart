// Test script to check what's inside the KML file
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

Future<void> main() async {
  print('Analyzing KML content from Google My Maps...');

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    // Extract map ID and download
    final uri = Uri.parse(googleMapsUrl);
    final mid = uri.queryParameters['mid'];
    final kmlUrl = 'https://www.google.com/maps/d/kml?mid=$mid';

    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(kmlUrl));
    final response = await request.close();

    if (response.statusCode == 200) {
      final bytes = await response.fold<List<int>>(
          [], (previous, element) => previous..addAll(element));
      final bodyBytes = Uint8List.fromList(bytes);

      // Extract KML from KMZ
      final archive = ZipDecoder().decodeBytes(bodyBytes);
      final kmlFile = archive
          .firstWhere((file) => file.name.toLowerCase().endsWith('.kml'));
      final kmlContent = utf8.decode(kmlFile.content as List<int>);

      // Analyze KML content
      print('🔍 Analyzing KML structure...');

      // Count different types of elements
      int placemarkCount = RegExp('<Placemark', caseSensitive: false)
          .allMatches(kmlContent)
          .length;
      int pointCount =
          RegExp('<Point>', caseSensitive: false).allMatches(kmlContent).length;
      int lineStringCount = RegExp('<LineString>', caseSensitive: false)
          .allMatches(kmlContent)
          .length;
      int polygonCount = RegExp('<Polygon>', caseSensitive: false)
          .allMatches(kmlContent)
          .length;
      int multiGeometryCount = RegExp('<MultiGeometry>', caseSensitive: false)
          .allMatches(kmlContent)
          .length;

      print('📊 KML Content Analysis:');
      print('  Total Placemarks: $placemarkCount');
      print('  Points: $pointCount');
      print('  LineStrings: $lineStringCount');
      print('  Polygons: $polygonCount');
      print('  MultiGeometry: $multiGeometryCount');

      // Look for polygon coordinates
      if (polygonCount > 0) {
        print('\n🔸 Found polygon data! Extracting sample coordinates...');
        final polygonMatch = RegExp(
                r'<Polygon>.*?<coordinates>(.*?)</coordinates>.*?</Polygon>',
                caseSensitive: false,
                dotAll: true)
            .firstMatch(kmlContent);
        if (polygonMatch != null) {
          final coordinates = polygonMatch.group(1)?.trim() ?? '';
          final coordLines = coordinates
              .split('\n')
              .where((line) => line.trim().isNotEmpty)
              .toList();
          print('  Sample coordinates (first 5 points):');
          for (int i = 0; i < coordLines.length && i < 5; i++) {
            print('    ${coordLines[i].trim()}');
          }
          print('  ... and ${coordLines.length - 5} more points');
        }
      }

      // Look for style information
      int styleCount =
          RegExp('<Style', caseSensitive: false).allMatches(kmlContent).length;
      print('\n🎨 Styles found: $styleCount');

      // Check for folders/organization
      int folderCount = RegExp('<Folder>', caseSensitive: false)
          .allMatches(kmlContent)
          .length;
      print('📁 Folders: $folderCount');
    }

    client.close();
  } catch (e) {
    print('❌ Error: $e');
  }
}
