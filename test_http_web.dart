// Simple test to verify web compatibility
import 'package:http/http.dart' as http;

Future<void> main() async {
  print('Testing HTTP client web compatibility...');

  try {
    final response =
        await http.get(Uri.parse('https://httpbin.org/status/200'));
    print('✅ HTTP client working! Status: ${response.statusCode}');
  } catch (e) {
    print('❌ HTTP client error: $e');
  }
}
