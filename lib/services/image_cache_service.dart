import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Service for downloading and caching images locally for offline access
class ImageCacheService {
  static const String _cacheDirectoryName = 'image_cache';

  Directory? _cacheDirectory;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Initialize the cache directory
  Future<void> initialize() async {
    try {
      debugPrint('🖼️ ImageCacheService: Initializing...');

      final appDir = await getApplicationDocumentsDirectory();
      _cacheDirectory = Directory('${appDir.path}/$_cacheDirectoryName');

      if (!await _cacheDirectory!.exists()) {
        await _cacheDirectory!.create(recursive: true);
        debugPrint('🖼️ Created cache directory: ${_cacheDirectory!.path}');
      }

      _isInitialized = true;
      debugPrint('🖼️ ImageCacheService: Initialized successfully');
      debugPrint('   - Cache directory: ${_cacheDirectory!.path}');
    } catch (e) {
      debugPrint('❌ ImageCacheService: Initialization error: $e');
      rethrow;
    }
  }

  /// Download and cache an image from a URL
  /// Returns the local file path on success, null on failure
  Future<String?> downloadAndCacheImage(String imageUrl, String toolId) async {
    if (!_isInitialized) {
      throw Exception('ImageCacheService not initialized');
    }

    try {
      debugPrint('🖼️ Downloading image for tool $toolId from: $imageUrl');

      // Download image
      final response = await http.get(Uri.parse(imageUrl));

      if (response.statusCode != 200) {
        debugPrint('❌ Failed to download image: HTTP ${response.statusCode}');
        return null;
      }

      // Get file extension from URL or content type
      final extension =
          _getFileExtension(imageUrl, response.headers['content-type']);

      // Generate safe filename using tool ID
      final fileName = '${_sanitizeFileName(toolId)}$extension';
      final localFile = File('${_cacheDirectory!.path}/$fileName');

      // Save to disk
      await localFile.writeAsBytes(response.bodyBytes);

      debugPrint('✅ Cached image for tool $toolId at: ${localFile.path}');
      return localFile.path;
    } catch (e) {
      debugPrint('❌ Error downloading/caching image for tool $toolId: $e');
      return null;
    }
  }

  /// Get cached image file if it exists
  File? getCachedImageFile(String localPath) {
    if (!_isInitialized) return null;

    try {
      final file = File(localPath);
      if (file.existsSync()) {
        return file;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error getting cached image file: $e');
      return null;
    }
  }

  /// Check if image is cached at the given path
  bool isImageCached(String localPath) {
    if (!_isInitialized) return false;

    try {
      final file = File(localPath);
      return file.existsSync();
    } catch (e) {
      return false;
    }
  }

  /// Delete cached image
  Future<void> deleteCachedImage(String localPath) async {
    if (!_isInitialized) return;

    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('🖼️ Deleted cached image: $localPath');
      }
    } catch (e) {
      debugPrint('❌ Error deleting cached image: $e');
    }
  }

  /// Clear all cached images
  Future<void> clearAllCachedImages() async {
    if (!_isInitialized) return;

    try {
      if (await _cacheDirectory!.exists()) {
        final files = _cacheDirectory!.listSync();
        for (final file in files) {
          if (file is File) {
            await file.delete();
          }
        }
        debugPrint('🖼️ Cleared all cached images (${files.length} files)');
      }
    } catch (e) {
      debugPrint('❌ Error clearing cached images: $e');
    }
  }

  /// Get cache size in bytes
  Future<int> getCacheSize() async {
    if (!_isInitialized) return 0;

    try {
      int totalSize = 0;
      if (await _cacheDirectory!.exists()) {
        final files = _cacheDirectory!.listSync();
        for (final file in files) {
          if (file is File) {
            totalSize += await file.length();
          }
        }
      }
      return totalSize;
    } catch (e) {
      debugPrint('❌ Error calculating cache size: $e');
      return 0;
    }
  }

  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    if (!_isInitialized) {
      return {
        'fileCount': 0,
        'totalSizeBytes': 0,
        'totalSizeMB': 0.0,
      };
    }

    try {
      int fileCount = 0;
      int totalSize = 0;

      if (await _cacheDirectory!.exists()) {
        final files = _cacheDirectory!.listSync();
        fileCount = files.whereType<File>().length;
        for (final file in files) {
          if (file is File) {
            totalSize += await file.length();
          }
        }
      }

      return {
        'fileCount': fileCount,
        'totalSizeBytes': totalSize,
        'totalSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
      };
    } catch (e) {
      debugPrint('❌ Error getting cache stats: $e');
      return {
        'fileCount': 0,
        'totalSizeBytes': 0,
        'totalSizeMB': 0.0,
      };
    }
  }

  /// Get file extension from URL or content type
  String _getFileExtension(String url, String? contentType) {
    // Try to get from URL first
    final uri = Uri.parse(url);
    final urlPath = uri.path;
    if (urlPath.contains('.')) {
      final lastDot = urlPath.lastIndexOf('.');
      if (lastDot != -1 && lastDot < urlPath.length - 1) {
        return urlPath.substring(lastDot);
      }
    }

    // Fallback to content type
    if (contentType != null) {
      if (contentType.contains('jpeg') || contentType.contains('jpg')) {
        return '.jpg';
      } else if (contentType.contains('png')) {
        return '.png';
      } else if (contentType.contains('gif')) {
        return '.gif';
      } else if (contentType.contains('webp')) {
        return '.webp';
      }
    }

    // Default to jpg
    return '.jpg';
  }

  /// Sanitize filename to be safe for file system
  String _sanitizeFileName(String fileName) {
    // Remove or replace invalid characters
    return fileName
        .replaceAll(RegExp(r'[^\w\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .toLowerCase();
  }

  /// Generate hash-based filename for a URL (alternative method)
  String _generateHashedFileName(String url, String extension) {
    final bytes = utf8.encode(url);
    final hash = sha256.convert(bytes);
    return '${hash.toString().substring(0, 16)}$extension';
  }
}
