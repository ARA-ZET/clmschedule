// Test script for KML download functionality
// Run with: flutter run test_kml_download.dart

Future<void> main() async {
  print('Testing KML download with Google My Maps URL...');

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    print('Starting download from: $googleMapsUrl');
    // TODO: Update to use new MyMapsKmlDownloader + parseKmlData approach
    print(
        '⚠️  Test disabled - use MyMapsKmlDownloader + KmlParserService.parseKmlData instead');
    return;
    // final polygons = await KmlParserService.downloadAndParseKml(googleMapsUrl);

    /*
    print('Successfully parsed ${polygons.length} polygon(s)');
    for (int i = 0; i < polygons.length; i++) {
      final polygon = polygons[i];
      print('Polygon $i: ${polygon.name}');
      print('  Points: ${polygon.points.length}');
      print('  Color: ${polygon.color}');
      if (polygon.points.isNotEmpty) {
        print('  First point: ${polygon.points.first}');
        print('  Last point: ${polygon.points.last}');
      }
    }
    */
  } catch (e) {
    print('Error downloading/parsing KML: $e');
    if (e.toString().contains('HTML')) {
      print('This appears to be an HTML page instead of KML data.');
      print('The map might be private or require authentication.');
    }
  }
}
