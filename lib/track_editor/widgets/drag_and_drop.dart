// track_editor/widgets/drag_and_drop.dart
import 'dart:io' as io;
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gpx/gpx.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/tab_item.dart';
import '../providers/te_files_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_tracks_provider.dart';
import '../providers/te_waypoints_provider.dart';
import '../utils/html_file_reader.dart';
import 'mymaps_link.dart';

class TEDragAndDrop extends riverpod.ConsumerStatefulWidget {
  final void Function(List<({Uint8List bytes, String name})>) onFilesPicked;

  const TEDragAndDrop({super.key, required this.onFilesPicked});

  @override
  riverpod.ConsumerState<TEDragAndDrop> createState() => _TEDragAndDropState();
}

class _TEDragAndDropState extends riverpod.ConsumerState<TEDragAndDrop> {
  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: ['kml', 'gpx', 'kmz'],
      withData: true,
    );
    if (result != null) await _processPlatformFiles(result.files);
  }

  Future<void> _processPlatformFiles(List<PlatformFile> platformFiles) async {
    final filesData = <({Uint8List bytes, String name})>[];
    for (final file in platformFiles) {
      final bytes = file.bytes;
      final name = file.name;
      if (bytes == null) continue;
      await _processFileContent(bytes, name, filesData);
    }
    _finalizeFileProcessing(filesData);
  }

  Future<void> _processFileContent(
    Uint8List bytes,
    String name,
    List<({Uint8List bytes, String name})> collector,
  ) async {
    if (name.toLowerCase().endsWith('.gpx')) {
      _readGpxFile(bytes, name);
      collector.add((bytes: bytes, name: name));
    } else if (name.toLowerCase().endsWith('.kmz')) {
      final extracted = _extractKmlFromKmz(bytes, name);
      if (extracted != null) collector.add(extracted);
    } else if (name.toLowerCase().endsWith('.kml')) {
      collector.add((bytes: bytes, name: name));
    } else {
      debugPrint('Unsupported file type: $name');
    }
  }

  void _finalizeFileProcessing(
      List<({Uint8List bytes, String name})> filesData) {
    if (filesData.isNotEmpty) {
      ref
          .read(teFilesRiverpod)
          .addFileNames(filesData.map((e) => e.name).toList());
      widget.onFilesPicked(filesData);
    }
  }

  ({Uint8List bytes, String name})? _extractKmlFromKmz(
      Uint8List kmzBytes, String originalName) {
    try {
      final archive = ZipDecoder().decodeBytes(kmzBytes);
      for (final file in archive) {
        if (file.name.toLowerCase().endsWith('.kml')) {
          return (
            bytes: Uint8List.fromList(file.content as List<int>),
            name: originalName.replaceAll(
                RegExp(r'\.kmz$', caseSensitive: false), '.kml'),
          );
        }
      }
      debugPrint('❌ No KML found in $originalName');
    } catch (e) {
      debugPrint('❌ Failed to extract KMZ ($originalName): $e');
    }
    return null;
  }

  void _readGpxFile(Uint8List bytes, String name) {
    try {
      final xml = String.fromCharCodes(bytes);
      final gpx = GpxReader().fromString(xml);
      ref.read(teWaypointsRiverpod).addWaypoints(gpx.wpts);
      ref.read(teTracksRiverpod).addTracks(gpx.trks);
      ref.read(teTabsRiverpod).addData(
            TETabItem(
              title: name,
              polygons: [],
              tracks: gpx.trks,
              waypoints: gpx.wpts,
              targetPolygons: [],
            ),
          );
      debugPrint(
          '✅ Read ${gpx.wpts.length} waypoints and ${gpx.trks.length} tracks from $name');
    } catch (e) {
      debugPrint('❌ Error parsing GPX $name: $e');
    }
  }

  bool _isSupportedExtension(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    return ['kml', 'gpx', 'kmz'].contains(ext);
  }

  Future<void> _handleDownloadedKml(Uint8List kmlBytes, String fileName) async {
    debugPrint('✅ KML received from MyMapsDownloader: $fileName');
    final collector = <({Uint8List bytes, String name})>[];
    await _processFileContent(kmlBytes, fileName, collector);
    _finalizeFileProcessing(collector);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(teFilesRiverpod).selectedFileNames;

    return DragTarget<Object>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) async {
        final data = details.data;
        final collector = <({Uint8List bytes, String name})>[];

        if (kIsWeb && isHtmlFile(data)) {
          final name = htmlFileName(data);
          if (!_isSupportedExtension(name)) {
            debugPrint('Unsupported file (drag-drop web): $name');
            return;
          }
          final bytes = await readHtmlFile(data);
          await _processFileContent(bytes, name, collector);
        } else if (!kIsWeb && data is String) {
          final file = io.File(data);
          if (await file.exists()) {
            final name = file.uri.pathSegments.last;
            if (!_isSupportedExtension(name)) return;
            final bytes = await file.readAsBytes();
            await _processFileContent(bytes, name, collector);
          }
        }
        _finalizeFileProcessing(collector);
      },
      builder: (context, candidateData, rejectedData) {
        return Container(
          width: 400,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withValues(alpha: 0.1),
                spreadRadius: 1,
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            spacing: 8,
            children: [
              TEMyMapsKmlDownloader(onKmlDataRetrieved: _handleDownloadedKml),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_present_outlined, size: 18),
                label: const Text('Select Files from Device'),
                onPressed: _pickFiles,
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                  side: BorderSide(color: Colors.grey.shade400),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
