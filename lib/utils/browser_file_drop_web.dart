// utils/browser_file_drop_web.dart
//
// Web: page-wide dragover/drop listeners, walking dropped folders through
// the File and Directory Entries API, and an <input webkitdirectory> for
// picking a whole folder.
import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' show Offset, VoidCallback;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'local_upload_file.dart';

abstract class BrowserFileDrop {
  void dispose();
}

BrowserFileDrop? listenForFileDrops({
  required void Function(Offset position) onOver,
  required VoidCallback onLeave,
  required void Function(Offset position, Future<List<LocalUploadFile>> files)
      onDrop,
}) =>
    _WebFileDrop(onOver, onLeave, onDrop);

class _WebFileDrop implements BrowserFileDrop {
  _WebFileDrop(this._onOver, this._onLeave, this._onDrop) {
    for (final type in const ['dragenter', 'dragover']) {
      web.window.addEventListener(type, _over, true.toJS);
    }
    web.window.addEventListener('drop', _drop, true.toJS);
  }

  final void Function(Offset) _onOver;
  final VoidCallback _onLeave;
  final void Function(Offset, Future<List<LocalUploadFile>>) _onDrop;

  late final JSFunction _over = ((web.DragEvent e) => _handleOver(e)).toJS;
  late final JSFunction _drop = ((web.DragEvent e) => _handleDrop(e)).toJS;

  /// dragover repeats every ~50 ms while files hover over the page, and
  /// browsers disagree on when dragleave means "left the window" — so the
  /// drag counts as over once the repeats stop.
  Timer? _leaveTimer;

  static bool _hasFiles(web.DragEvent e) =>
      e.dataTransfer?.types.toDart.any((t) => t.toDart == 'Files') ?? false;

  void _handleOver(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    // Without this the browser opens the dropped file in the tab.
    e.preventDefault();
    e.dataTransfer?.dropEffect = 'copy';
    _onOver(Offset(e.clientX.toDouble(), e.clientY.toDouble()));
    _leaveTimer?.cancel();
    _leaveTimer = Timer(const Duration(milliseconds: 250), _onLeave);
  }

  void _handleDrop(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    _leaveTimer?.cancel();

    // The items are only readable during the event, so take the entries now
    // and walk them afterwards.
    final items = e.dataTransfer!.items;
    final entries = <web.FileSystemEntry>[];
    final loose = <web.File>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind != 'file') continue;
      final entry = item.webkitGetAsEntry();
      if (entry != null) {
        entries.add(entry);
      } else if (item.getAsFile() case final file?) {
        loose.add(file);
      }
    }
    _onDrop(
      Offset(e.clientX.toDouble(), e.clientY.toDouble()),
      _collect(entries, loose),
    );
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    for (final type in const ['dragenter', 'dragover']) {
      web.window.removeEventListener(type, _over, true.toJS);
    }
    web.window.removeEventListener('drop', _drop, true.toJS);
  }
}

Future<List<LocalUploadFile>> _collect(
  List<web.FileSystemEntry> entries,
  List<web.File> loose,
) async {
  final out = <LocalUploadFile>[];

  Future<void> walk(web.FileSystemEntry entry, String prefix) async {
    if (_isHidden(entry.name)) return;
    if (entry.isFile) {
      final file = await _fileOf(entry as web.FileSystemFileEntry);
      out.add(_wrap(file, '$prefix${entry.name}'));
    } else if (entry.isDirectory) {
      final reader = (entry as web.FileSystemDirectoryEntry).createReader();
      // readEntries hands back at most ~100 at a time; empty means done.
      while (true) {
        final batch = await _readBatch(reader);
        if (batch.isEmpty) break;
        for (final child in batch) {
          await walk(child, '$prefix${entry.name}/');
        }
      }
    }
  }

  for (final entry in entries) {
    try {
      await walk(entry, '');
    } catch (e) {
      debugPrint('browser_file_drop: could not read ${entry.name}: $e');
    }
  }
  for (final file in loose) {
    if (!_isHidden(file.name)) out.add(_wrap(file, file.name));
  }
  return out;
}

/// .DS_Store, desktop.ini-style dot files — never wanted in Cloud Files.
bool _isHidden(String name) => name.startsWith('.');

Future<web.File> _fileOf(web.FileSystemFileEntry entry) {
  final done = Completer<web.File>();
  entry.file(
    ((web.File f) => done.complete(f)).toJS,
    ((JSAny? err) => done.completeError('$err')).toJS,
  );
  return done.future;
}

Future<List<web.FileSystemEntry>> _readBatch(
    web.FileSystemDirectoryReader reader) {
  final done = Completer<List<web.FileSystemEntry>>();
  reader.readEntries(
    ((JSArray<web.FileSystemEntry> list) => done.complete(list.toDart)).toJS,
    ((JSAny? err) => done.completeError('$err')).toJS,
  );
  return done.future;
}

LocalUploadFile _wrap(web.File file, String relativePath) => LocalUploadFile(
      relativePath: relativePath,
      size: file.size,
      read: () async {
        final buffer = await file.arrayBuffer().toDart;
        return buffer.toDart.asUint8List();
      },
    );

bool get canPickFolderForUpload => true;

/// Drive's "Folder upload": the browser's own folder chooser. Paths keep the
/// chosen folder's name ("Photos/a.jpg"), so the folder is recreated.
/// Null when the user cancels.
Future<List<LocalUploadFile>?> pickFolderForUpload() {
  final done = Completer<List<LocalUploadFile>?>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..multiple = true
    ..webkitdirectory = true;

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      final out = <LocalUploadFile>[];
      for (var i = 0; i < (files?.length ?? 0); i++) {
        final f = files!.item(i);
        if (f == null || _isHidden(f.name)) continue;
        final path = f.webkitRelativePath.isEmpty ? f.name : f.webkitRelativePath;
        out.add(_wrap(f, path));
      }
      if (!done.isCompleted) done.complete(out);
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!done.isCompleted) done.complete(null);
    }).toJS,
  );
  input.click();
  return done.future;
}
