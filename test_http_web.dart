import 'package:flutter/foundation.dart';
// Simple test to verify web compatibility
import 'package:http/http.dart' as http;

Future<void> main() async {
  if (kDebugMode) {
    print('Testing HTTP client web compatibility...');
  }

  try {
    final response =
        await http.get(Uri.parse('https://httpbin.org/status/200'));
    if (kDebugMode) {
      print('✅ HTTP client working! Status: ${response.statusCode}');
    }
  } catch (e) {
    if (kDebugMode) {
      print('❌ HTTP client error: $e');
    }
  }
}
