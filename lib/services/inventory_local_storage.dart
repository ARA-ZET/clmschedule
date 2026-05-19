import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/inventory_tool.dart';

/// Local storage service for inventory tools using Hive
/// Provides offline-first data persistence for inventory data
class InventoryLocalStorage {
  static const String _toolsBoxName = 'inventory_tools';
  static const String _imagePathsBoxName = 'inventory_image_paths';

  Box<Map>? _toolsBox;
  Box<String>? _imagePathsBox;

  /// Deep convert dynamic maps to typed maps recursively
  static Map<String, dynamic> _deepConvertMap(dynamic map) {
    if (map == null) return {};
    if (map is Map<String, dynamic>) return map;

    final result = <String, dynamic>{};
    if (map is Map) {
      map.forEach((key, value) {
        final stringKey = key.toString();
        if (value is Map) {
          result[stringKey] = _deepConvertMap(value);
        } else if (value is List) {
          result[stringKey] = _deepConvertList(value);
        } else {
          result[stringKey] = value;
        }
      });
    }
    return result;
  }

  /// Deep convert dynamic lists recursively
  static List<dynamic> _deepConvertList(List<dynamic> list) {
    return list.map((item) {
      if (item is Map) {
        return _deepConvertMap(item);
      } else if (item is List) {
        return _deepConvertList(item);
      }
      return item;
    }).toList();
  }

  bool get isInitialized => _toolsBox != null && _imagePathsBox != null;

  /// Initialize Hive and open boxes
  Future<void> initialize() async {
    try {
      debugPrint('💾 InventoryLocalStorage: Initializing Hive...');

      // Hive.initFlutter() already called by HappySunLocalStorage
      // Open boxes
      _toolsBox = await Hive.openBox<Map>(_toolsBoxName);
      _imagePathsBox = await Hive.openBox<String>(_imagePathsBoxName);

      debugPrint('💾 InventoryLocalStorage: Initialized successfully');
      debugPrint('   - Tools count: ${_toolsBox?.length ?? 0}');
      debugPrint('   - Cached images: ${_imagePathsBox?.length ?? 0}');
    } catch (e) {
      debugPrint('❌ InventoryLocalStorage: Initialization error: $e');
      rethrow;
    }
  }

  /// Save a tool to local storage
  Future<void> saveTool(InventoryTool tool) async {
    if (!isInitialized) {
      throw Exception('InventoryLocalStorage not initialized');
    }

    try {
      final toolMap = _convertToHiveCompatible(tool.toMap());
      await _toolsBox!.put(tool.id, toolMap);
      debugPrint('💾 Saved tool ${tool.toolId} to local storage');
    } catch (e) {
      debugPrint('❌ Error saving tool to local storage: $e');
      rethrow;
    }
  }

  /// Save multiple tools to local storage
  Future<void> saveTools(List<InventoryTool> tools) async {
    if (!isInitialized) {
      throw Exception('InventoryLocalStorage not initialized');
    }

    try {
      final entries = <String, Map>{};
      for (final tool in tools) {
        entries[tool.id] = _convertToHiveCompatible(tool.toMap());
      }
      await _toolsBox!.putAll(entries);
      debugPrint('💾 Saved ${tools.length} tools to local storage');
    } catch (e) {
      debugPrint('❌ Error saving tools to local storage: $e');
      rethrow;
    }
  }

  /// Get a tool from local storage by ID
  InventoryTool? getTool(String toolId) {
    if (!isInitialized) return null;

    try {
      final toolMap = _toolsBox!.get(toolId);
      if (toolMap == null) return null;

      return InventoryTool.fromMap(
        toolId,
        _deepConvertMap(toolMap),
      );
    } catch (e) {
      debugPrint('❌ Error getting tool from local storage: $e');
      return null;
    }
  }

  /// Get all tools from local storage
  List<InventoryTool> getAllTools() {
    if (!isInitialized) return [];

    try {
      final tools = <InventoryTool>[];
      for (final key in _toolsBox!.keys) {
        final toolMap = _toolsBox!.get(key);
        if (toolMap != null) {
          try {
            final tool = InventoryTool.fromMap(
              key.toString(),
              _deepConvertMap(toolMap),
            );
            tools.add(tool);
          } catch (e) {
            debugPrint('❌ Error parsing tool $key: $e');
          }
        }
      }
      debugPrint('💾 Retrieved ${tools.length} tools from local storage');
      return tools;
    } catch (e) {
      debugPrint('❌ Error getting all tools from local storage: $e');
      return [];
    }
  }

  /// Save cached image path for a tool
  Future<void> saveCachedImagePath(String toolId, String localPath) async {
    if (!isInitialized) {
      throw Exception('InventoryLocalStorage not initialized');
    }

    try {
      await _imagePathsBox!.put(toolId, localPath);
      debugPrint('💾 Saved cached image path for tool $toolId');
    } catch (e) {
      debugPrint('❌ Error saving cached image path: $e');
      rethrow;
    }
  }

  /// Get cached image path for a tool
  String? getCachedImagePath(String toolId) {
    if (!isInitialized) return null;

    try {
      return _imagePathsBox!.get(toolId);
    } catch (e) {
      debugPrint('❌ Error getting cached image path: $e');
      return null;
    }
  }

  /// Check if image is cached for a tool
  bool hasImageCached(String toolId) {
    return getCachedImagePath(toolId) != null;
  }

  /// Delete a tool from local storage
  Future<void> deleteTool(String toolId) async {
    if (!isInitialized) return;

    try {
      await _toolsBox!.delete(toolId);
      await _imagePathsBox!.delete(toolId);
      debugPrint('💾 Deleted tool $toolId from local storage');
    } catch (e) {
      debugPrint('❌ Error deleting tool from local storage: $e');
    }
  }

  /// Clear all cached tools (keep images)
  Future<void> clearTools() async {
    if (!isInitialized) return;

    try {
      await _toolsBox!.clear();
      debugPrint('💾 Cleared all tools from local storage');
    } catch (e) {
      debugPrint('❌ Error clearing tools: $e');
    }
  }

  /// Clear all cached image paths
  Future<void> clearImagePaths() async {
    if (!isInitialized) return;

    try {
      await _imagePathsBox!.clear();
      debugPrint('💾 Cleared all image paths from local storage');
    } catch (e) {
      debugPrint('❌ Error clearing image paths: $e');
    }
  }

  /// Get cache statistics
  Map<String, int> getCacheStats() {
    return {
      'toolsCount': _toolsBox?.length ?? 0,
      'cachedImagesCount': _imagePathsBox?.length ?? 0,
    };
  }

  /// Dispose and close boxes
  Future<void> dispose() async {
    try {
      await _toolsBox?.close();
      await _imagePathsBox?.close();
      debugPrint('💾 InventoryLocalStorage: Disposed');
    } catch (e) {
      debugPrint('❌ InventoryLocalStorage: Dispose error: $e');
    }
  }

  /// Convert Firestore Timestamps to Hive-compatible format
  Map<String, dynamic> _convertToHiveCompatible(Map<String, dynamic> data) {
    final result = <String, dynamic>{};

    for (final entry in data.entries) {
      final value = entry.value;

      // Convert Timestamp to ISO8601 string
      if (value.runtimeType.toString() == 'Timestamp') {
        final timestamp = value as dynamic;
        final dateTime = DateTime.fromMillisecondsSinceEpoch(
          (timestamp.millisecondsSinceEpoch as num).toInt(),
        );
        result[entry.key] = dateTime.toIso8601String();
      }
      // Recursively handle nested maps
      else if (value is Map<String, dynamic>) {
        result[entry.key] = _convertToHiveCompatible(value);
      }
      // Handle lists
      else if (value is List) {
        result[entry.key] = value.map((item) {
          if (item is Map<String, dynamic>) {
            return _convertToHiveCompatible(item);
          }
          return item;
        }).toList();
      }
      // Keep other types as-is
      else {
        result[entry.key] = value;
      }
    }

    return result;
  }
}
