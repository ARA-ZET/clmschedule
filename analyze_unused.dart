import 'dart:io';

void main() async {
  final libDir = Directory('lib');
  final allDartFiles = await _getAllDartFiles(libDir);

  // Exclude generated and test files
  final excludePatterns = [
    'env.dart',
    'env.g.dart',
    'firebase_options.dart',
    '.g.dart',
  ];

  final dartFiles = allDartFiles.where((file) {
    final path = file.path;
    return !excludePatterns.any((pattern) => path.contains(pattern));
  }).toList();

  print('Total .dart files in lib/: ${dartFiles.length}');
  print('');

  // Build import graph starting from main.dart
  final usedFiles = <String>{};
  final toProcess = ['lib/main.dart'];
  final processed = <String>{};

  while (toProcess.isNotEmpty) {
    final currentFile = toProcess.removeLast();
    if (processed.contains(currentFile)) continue;
    processed.add(currentFile);
    usedFiles.add(currentFile);

    final file = File(currentFile);
    if (!await file.exists()) continue;

    final content = await file.readAsString();
    final imports = _extractImports(content, currentFile);

    for (final importPath in imports) {
      if (!processed.contains(importPath) && !toProcess.contains(importPath)) {
        toProcess.add(importPath);
      }
    }
  }

  print('Total files used (imported): ${usedFiles.length}');
  print('');

  // Find unused files
  final unusedFiles = <String>[];
  for (final file in dartFiles) {
    final relativePath = file.path;
    if (!usedFiles.contains(relativePath)) {
      // Double check by searching for imports of this file
      final fileName = relativePath.split('/').last;
      final baseName = fileName.replaceAll('.dart', '');

      bool isImported = false;
      for (final usedFile in dartFiles) {
        if (usedFile.path == relativePath) continue;
        final content = await usedFile.readAsString();
        if (content.contains("'$fileName'") ||
            content.contains('"$fileName"') ||
            content.contains("'$baseName.dart'") ||
            content.contains('"$baseName.dart"')) {
          isImported = true;
          break;
        }
      }

      if (!isImported) {
        unusedFiles.add(relativePath);
      }
    }
  }

  print('Total UNUSED files: ${unusedFiles.length}');
  print('');

  // Group by directory
  final byDirectory = <String, List<String>>{};
  for (final file in unusedFiles) {
    final parts = file.split('/');
    final dir = parts.length > 2 ? parts[1] : 'root';
    byDirectory.putIfAbsent(dir, () => []).add(file);
  }

  print('=== UNUSED FILES BY DIRECTORY ===\n');
  final sortedDirs = byDirectory.keys.toList()..sort();

  for (final dir in sortedDirs) {
    final files = byDirectory[dir]!..sort();
    print('$dir/ (${files.length} files):');
    for (final file in files) {
      print('  - $file');
    }
    print('');
  }
}

Future<List<File>> _getAllDartFiles(Directory dir) async {
  final files = <File>[];
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity);
    }
  }
  return files;
}

List<String> _extractImports(String content, String currentFilePath) {
  final imports = <String>[];
  final lines = content.split('\n');
  final currentDir =
      currentFilePath.substring(0, currentFilePath.lastIndexOf('/'));

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('import ')) {
      String? importPath;

      // Try single quotes
      var startIdx = trimmed.indexOf("'");
      var endIdx = startIdx >= 0 ? trimmed.indexOf("'", startIdx + 1) : -1;

      // Try double quotes if single quotes not found
      if (startIdx < 0) {
        startIdx = trimmed.indexOf('"');
        endIdx = startIdx >= 0 ? trimmed.indexOf('"', startIdx + 1) : -1;
      }

      if (startIdx >= 0 && endIdx > startIdx) {
        importPath = trimmed.substring(startIdx + 1, endIdx);

        // Only process relative imports
        if (importPath.startsWith('../')) {
          final resolvedPath = _resolvePath(currentDir, importPath);
          imports.add(resolvedPath);
        } else if (!importPath.contains('package:') &&
            !importPath.contains('dart:') &&
            importPath.endsWith('.dart')) {
          // Same directory import
          imports.add('$currentDir/$importPath');
        }
      }
    }
  }

  return imports;
}

String _resolvePath(String currentDir, String relativePath) {
  final parts = currentDir.split('/');
  final importParts = relativePath.split('/');

  for (final part in importParts) {
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (part != '.') {
      parts.add(part);
    }
  }

  return parts.join('/');
}
