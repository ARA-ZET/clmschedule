import 'dart:convert' show utf8;
import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class MyMapsKmlDownloader extends StatefulWidget {
  // Define a callback that takes the KML bytes and filename
  final void Function(Uint8List kmlBytes, String fileName)? onKmlDataRetrieved;

  const MyMapsKmlDownloader({
    super.key,
    this.onKmlDataRetrieved, // Add callback to constructor
  });

  @override
  State<MyMapsKmlDownloader> createState() => _MyMapsKmlDownloaderState();
}

class _MyMapsKmlDownloaderState extends State<MyMapsKmlDownloader> {
  final TextEditingController _controller = TextEditingController();
  String? _errorMessage;
  bool _isLoading = false;

  String? _extractMapId(String url) {
    if (url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (!(uri.host.contains('google.com') ||
          uri.host.contains('google.co'))) {
        return null;
      }
      return uri.queryParameters['mid'];
    } catch (e) {
      debugPrint("Error parsing URL in _extractMapId: $e");
      return null;
    }
  }

  // Modified to also call the onKmlDataRetrieved callback
  void _triggerWebDownloadAndCallback(
      Uint8List data, String mimeType, String targetFileName) {
    final String finalFileName = targetFileName.endsWith('.kml')
        ? targetFileName
        : '$targetFileName.kml';

    // 1. Call the callback with the data if provided
    widget.onKmlDataRetrieved?.call(data, finalFileName);

    // 2. Proceed with the browser download (user still gets a copy)
    // final blob = html.Blob([data], mimeType);
    // final url = html.Url.createObjectUrlFromBlob(blob);

    // final anchor = html.AnchorElement(href: url)
    //   ..setAttribute('download', finalFileName)
    //   ..click();
    // html.Url.revokeObjectUrl(url);

    setState(() {
      _controller.clear(); // Clear input after successful attempt
    });
  }

  Future<void> _downloadKml(String kmlExportUrl, String fileName) async {
    if (!kIsWeb) {
      setState(() {
        _errorMessage = "This downloader is intended for Flutter Web.";
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
      const String expectedKmlMimeType = 'application/vnd.google-earth.kml+xml';

      if (response.statusCode == 200) {
        String? contentTypeHeader = response.headers['content-type'];
        String? mainMimeType =
            contentTypeHeader?.toLowerCase().split(';').first.trim();

        debugPrint("Attempting to download from: $kmlExportUrl");
        debugPrint("Response Status Code: ${response.statusCode}");
        debugPrint("Received Content-Type header: $contentTypeHeader");
        debugPrint("Interpreted main MIME type: $mainMimeType");

        if (mainMimeType == expectedKmlMimeType) {
          _triggerWebDownloadAndCallback(response.bodyBytes,
              '$expectedKmlMimeType;charset=utf-8', fileName);
        } else if (mainMimeType == 'text/html') {
          throw Exception(
              'Failed to download KML. Server returned HTML. Map might not be public or link is invalid.');
        } else {
          bool looksLikeKml = false;
          if (response.bodyBytes.isNotEmpty) {
            try {
              String bodyStartSample = utf8
                  .decode(response.bodyBytes.take(150).toList(),
                      allowMalformed: true)
                  .trim()
                  .toLowerCase();
              if (bodyStartSample.startsWith('<?xml') ||
                  bodyStartSample.startsWith('<kml')) {
                looksLikeKml = true;
              }
            } catch (e) {/* ignore */}
          }

          if (looksLikeKml) {
            debugPrint(
                "Warning: Content-Type was '$contentTypeHeader', but body appears to be KML. Proceeding.");
            _triggerWebDownloadAndCallback(response.bodyBytes,
                '$expectedKmlMimeType;charset=utf-8', fileName);
          } else {
            throw Exception(
                'Failed to download KML. Unexpected Content-Type: "$contentTypeHeader". Expected "$expectedKmlMimeType" and content did not appear to be KML.');
          }
        }
      } else {
        String errorReason = response.reasonPhrase ?? 'Unknown server error';
        if (response.statusCode == 403) {
          errorReason = "Access Denied (403). Map might not be public.";
        }
        if (response.statusCode == 404) {
          errorReason = "Map Not Found (404). Check link/Map ID.";
        }
        throw Exception(
            'Failed to download KML. Status: ${response.statusCode} ($errorReason)');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
      });
      debugPrint("Download Error: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _handleDownloadButtonPressed() {
    final String inputUrl = _controller.text.trim();
    if (inputUrl.isEmpty) {
      setState(() {
        _errorMessage = 'Please paste a Google My Maps link.';
      });
      return;
    }
    final String? mapId = _extractMapId(inputUrl);
    if (mapId == null || mapId.isEmpty) {
      setState(() {
        _errorMessage = 'Invalid My Maps URL. Could not extract Map ID.';
      });
      return;
    }
    final String kmlExportUrl =
        'https://www.google.com/maps/d/kml?mid=$mapId&forcekml=1';
    final String suggestedFileName = '$mapId.kml';
    _downloadKml(kmlExportUrl, suggestedFileName);
  }

  @override
  Widget build(BuildContext context) {
    return DottedBorder(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Text(
            //   "Download KML from Google My Maps",
            //   textAlign: TextAlign.center,
            //   style: Theme.of(context)
            //       .textTheme
            //       .titleMedium
            //       ?.copyWith(fontWeight: FontWeight.bold),
            // ),
            // const SizedBox(height: 4),
            Text(
              "Paste public shareable link below.",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: "e.g., https://www.google.com/maps/d/viewer?mid=...",
                labelText: "My Maps URL",
                border: const OutlineInputBorder(),
                errorText: _errorMessage,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() {
                    _errorMessage = null;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
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
              label: Text(
                  _isLoading ? "Downloading..." : "Download & Process KML"),
              onPressed: _isLoading ? null : _handleDownloadButtonPressed,
            ),
          ],
        ),
      ),
    );
  }
}
