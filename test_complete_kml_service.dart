// Test script to test the complete KML service functionality

Future<void> main() async {
  print('🧪 Testing complete KML service functionality...');

  const googleMapsUrl =
      'https://www.google.com/maps/d/viewer?mid=1-scibuyadDyoH7c_HTF8QhGRUiRGBYM&hl=en_US&ll=26.129052941791833%2C50.55854863281251&z=12';

  try {
    print('📍 Starting download and parsing from: $googleMapsUrl');
    // TODO: Update to use new MyMapsKmlDownloader + parseKmlData approach
    // final polygons = await KmlParserService.downloadAndParseKml(googleMapsUrl);
    print(
        '⚠️  Test disabled - use MyMapsKmlDownloader + KmlParserService.parseKmlData instead');
    return;

    /*
    print('✅ Successfully parsed ${polygons.length} polygon(s)!');

    for (int i = 0; i < polygons.length; i++) {
      final polygon = polygons[i];
      print('\n📐 Polygon ${i + 1}:');
      print('  Name: ${polygon.name}');
      print('  Description: ${polygon.description}');
      print('  Points: ${polygon.points.length}');
      print(
          '  Color: #${polygon.color.value.toRadixString(16).padLeft(8, '0')}');

      if (polygon.points.isNotEmpty) {
        print('  Bounding area:');
        final lats = polygon.points.map((p) => p.latitude);
        final lngs = polygon.points.map((p) => p.longitude);
        print(
            '    Latitude: ${lats.reduce((a, b) => a < b ? a : b).toStringAsFixed(6)} to ${lats.reduce((a, b) => a > b ? a : b).toStringAsFixed(6)}');
        print(
            '    Longitude: ${lngs.reduce((a, b) => a < b ? a : b).toStringAsFixed(6)} to ${lngs.reduce((a, b) => a > b ? a : b).toStringAsFixed(6)}');
        print(
            '  First point: (${polygon.points.first.latitude.toStringAsFixed(6)}, ${polygon.points.first.longitude.toStringAsFixed(6)})');
        print(
            '  Last point: (${polygon.points.last.latitude.toStringAsFixed(6)}, ${polygon.points.last.longitude.toStringAsFixed(6)})');
      }
    }

    if (polygons.isNotEmpty) {
      print('\n🎉 KML service is working correctly!');
      print('📊 Summary:');
      final totalPoints = polygons.fold(0, (sum, p) => sum + p.points.length);
      print('  - ${polygons.length} polygons extracted');
      print('  - $totalPoints total coordinate points');
      print('  - All polygons have names and styling');
      print('  - Ready for map integration!');
    } else {
      print('⚠️  No polygons found in the KML data');
    }
    */
  } catch (e) {
    print('❌ Error: $e');
  }
}
