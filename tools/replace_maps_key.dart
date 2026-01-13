import 'dart:io';

void main() async {
  try {
    // Read the API key from .env file
    final envFile = File('.env');
    if (!await envFile.exists()) {
      print('Error: .env file not found');
      exit(1);
    }

    final envContents = await envFile.readAsString();
    final apiKeyMatch = RegExp(r'GOOGLE_MAPS_API_KEY=(.+)').firstMatch(envContents);
    
    if (apiKeyMatch == null) {
      print('Error: Could not find GOOGLE_MAPS_API_KEY in .env file');
      exit(1);
    }

    final apiKey = apiKeyMatch.group(1)?.trim();
    
    if (apiKey == null || apiKey.isEmpty) {
      print('Error: GOOGLE_MAPS_API_KEY is empty in .env file');
      exit(1);
    }

    // Create the maps config content
    final configContent = '''// This file is auto-generated. Do not edit.
window.GOOGLE_MAPS_API_KEY = '$apiKey';''';

    // Write the new config
    final configFile = File('web/maps_config.js');
    await configFile.writeAsString(configContent);
    
    print('Successfully updated Google Maps API key in web/maps_config.js');
  } catch (e) {
    print('Error updating Google Maps API key: $e');
    exit(1);
  }
}
