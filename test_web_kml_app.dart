// Web-compatible test for KML service
import 'package:flutter/material.dart';

void main() {
  runApp(const KmlTestApp());
}

class KmlTestApp extends StatelessWidget {
  const KmlTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'KML Service Test',
      home: KmlTestPage(),
    );
  }
}

class KmlTestPage extends StatefulWidget {
  const KmlTestPage({super.key});

  @override
  State<KmlTestPage> createState() => _KmlTestPageState();
}

class _KmlTestPageState extends State<KmlTestPage> {
  String _status = 'Ready to test KML service';
  bool _isLoading = false;

  Future<void> _testKmlService() async {
    setState(() {
      _isLoading = true;
      _status = 'Testing KML service...';
    });

    try {
      final polygons =
          // TODO: Update to use MyMapsKmlDownloader + parseKmlData
          // await KmlParserService.downloadAndParseKml(googleMapsUrl);
          [];

      setState(() {
        _status =
            'SUCCESS! Downloaded ${polygons.length} polygon(s):\n\n${polygons.asMap().entries.map((entry) {
          final i = entry.key;
          final polygon = entry.value;
          return 'Polygon ${i + 1}: ${polygon.name} (${polygon.points.length} points)';
        }).join('\n')}';
      });
    } catch (e) {
      setState(() {
        _status = 'ERROR: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KML Service Test'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ElevatedButton(
              onPressed: _isLoading ? null : _testKmlService,
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Test KML Download'),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _status,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
