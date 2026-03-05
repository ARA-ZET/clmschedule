// track_editor/widgets/mymaps_link.dart
import 'dart:convert' show utf8;
import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class TEMyMapsKmlDownloader extends StatefulWidget {
  final void Function(Uint8List kmlBytes, String fileName)? onKmlDataRetrieved;

  const TEMyMapsKmlDownloader({
    super.key,
    this.onKmlDataRetrieved,
  });

  @override
  State<TEMyMapsKmlDownloader> createState() => _TEMyMapsKmlDownloaderState();
}

class _TEMyMapsKmlDownloaderState extends State<TEMyMapsKmlDownloader> {
  final TextEditingController _controller = TextEditingController();
  String? _errorMessage;
  bool _isLoading = false;

  String? _extractMapId(String url) {
    if (url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (!(uri.host.contains('google.com') || uri.host.contains('google.co'))) {
        return null;
      }
      return uri.queryParameters['mid'];
    } catch (e) {
      return null;
    }
  }

  void _onDataReady(Uint8List data, String fileName) {
    widget.onKmlDataRetrieved?.call(data, fileName);
    setState(() {
      _controller.clear();
    });
  }

  Future<void> _downloadKml(String kmlExportUrl, String fileName) async {
    if (!kIsWeb) {
      setState(() {
        _errorMessage = 'This downloader is web only.';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(Uri.parse(kmlExportUrl));
      const expectedMime = 'application/vnd.google-earth.kml+xml';

      if (response.statusCode == 200) {
        final mainMime = response.headers['content-type']
            ?.toLowerCase()
            .split(';')
            .first
            .trim();

        if (mainMime == expectedMime) {
          _onDataReady(response.bodyBytes, fileName);
        } else if (mainMime == 'text/html') {
          throw Exception('Server returned HTML. Map may not be public.');
        } else {
          bool looksLikeKml = false;
          if (response.bodyBytes.isNotEmpty) {
            try {
              final sample = utf8
                  .decode(response.bodyBytes.take(150).toList(),
                      allowMalformed: true)
                  .trim()
                  .toLowerCase();
              looksLikeKml =
                  sample.startsWith('<?xml') || sample.startsWith('<kml');
            } catch (_) {}
          }
          if (looksLikeKml) {
            _onDataReady(response.bodyBytes, fileName);
          } else {
            throw Exception(
                'Unexpected Content-Type: "$mainMime". Expected KML.');
          }
        }
      } else {
        throw Exception(
            'Download failed. Status: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _handleDownload() {
    final inputUrl = _controller.text.trim();
    if (inputUrl.isEmpty) {
      setState(() => _errorMessage = 'Please paste a Google My Maps link.');
      return;
    }
    final mapId = _extractMapId(inputUrl);
    if (mapId == null || mapId.isEmpty) {
      setState(
          () => _errorMessage = 'Invalid My Maps URL. Cannot extract Map ID.');
      return;
    }
    _downloadKml(
      'https://www.google.com/maps/d/kml?mid=$mapId&forcekml=1',
      '$mapId.kml',
    );
  }

  @override
  Widget build(BuildContext context) {
    return DottedBorder(
      options: RoundedRectDottedBorderOptions(
        color: Colors.grey.shade400,
        strokeWidth: 1.5,
        dashPattern: const [6, 4],
        radius: const Radius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Download KML from Google My Maps',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Paste public shareable link below.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText:
                    'e.g., https://www.google.com/maps/d/viewer?mid=...',
                labelText: 'My Maps URL',
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                backgroundColor:
                    _isLoading ? Colors.grey : Colors.blueGrey.shade100,
              ),
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, size: 20),
              label:
                  Text(_isLoading ? 'Downloading...' : 'Download & Process KML'),
              onPressed: _isLoading ? null : _handleDownload,
            ),
          ],
        ),
      ),
    );
  }
}
