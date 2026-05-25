import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/inventory_tool.dart';
import '../services/inventory_service.dart';
import '../services/inventory_local_storage.dart';
import '../services/image_cache_service.dart';
import '../services/connectivity_service.dart';

/// Service to synchronize inventory data between Firebase and local storage
class InventorySyncService {
  final InventoryService _firebaseService;
  final InventoryLocalStorage _localStorage;
  final ImageCacheService _imageCacheService;
  final ConnectivityService connectivityService; // Public for InventoryProvider

  bool _isInitialized = false;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;

  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<List<InventoryTool>>? _firebaseSubscription;

  bool get isInitialized => _isInitialized;
  bool get isSyncing => _isSyncing;
  DateTime? get lastSyncTime => _lastSyncTime;

  InventorySyncService({
    required InventoryService firebaseService,
    required InventoryLocalStorage localStorage,
    required ImageCacheService imageCacheService,
    required this.connectivityService,
  })  : _firebaseService = firebaseService,
        _localStorage = localStorage,
        _imageCacheService = imageCacheService;

  /// Initialize sync service and set up connectivity listener
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('🔄 InventorySyncService: Initializing...');

      // Listen to connectivity changes and sync when online
      _connectivitySubscription =
          connectivityService.connectivityStream.listen((isOnline) {
        debugPrint(
            '🔄 Connectivity changed: ${isOnline ? "ONLINE" : "OFFLINE"}');
        if (isOnline) {
          debugPrint('🔄 Device back online - starting inventory sync');
          syncInventory();
        }
      });

      // If already online, start sync
      if (connectivityService.isOnline) {
        syncInventory();
      }

      _isInitialized = true;
      debugPrint('🔄 InventorySyncService: Initialized successfully');
    } catch (e) {
      debugPrint('❌ InventorySyncService: Initialization error: $e');
      rethrow;
    }
  }

  /// Sync inventory from Firebase to local storage
  Future<void> syncInventory() async {
    if (_isSyncing) {
      debugPrint('⏭️ Sync already in progress, skipping');
      return;
    }

    if (!connectivityService.isOnline) {
      debugPrint('📡 Offline - skipping inventory sync');
      return;
    }

    _isSyncing = true;

    try {
      debugPrint('🔄 Starting inventory sync from Firebase...');

      // Subscribe to Firebase stream (one-time fetch)
      final completer = Completer<List<InventoryTool>>();
      StreamSubscription<List<InventoryTool>>? subscription;

      subscription = _firebaseService.getTools().listen(
        (tools) {
          if (!completer.isCompleted) {
            completer.complete(tools);
            subscription?.cancel();
          }
        },
        onError: (error) {
          if (!completer.isCompleted) {
            completer.completeError(error);
            subscription?.cancel();
          }
        },
      );

      // Wait for data with timeout
      final tools = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          subscription?.cancel();
          throw TimeoutException('Inventory sync timed out');
        },
      );

      debugPrint('✅ Fetched ${tools.length} tools from Firebase');

      // Save tools to local storage
      await _localStorage.saveTools(tools);
      debugPrint('✅ Saved ${tools.length} tools to local storage');

      // Download and cache images for tools with imageUrl
      await _downloadToolImages(tools);

      _lastSyncTime = DateTime.now();
      debugPrint('✅ Inventory sync completed successfully');
      debugPrint('   - Tools synced: ${tools.length}');
      debugPrint('   - Last sync: $_lastSyncTime');
    } catch (e) {
      debugPrint('❌ Error syncing inventory: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// Download and cache images for all tools
  Future<void> _downloadToolImages(List<InventoryTool> tools) async {
    try {
      int downloadedCount = 0;
      int skippedCount = 0;
      int errorCount = 0;

      debugPrint('🖼️ Starting image download for ${tools.length} tools...');

      for (final tool in tools) {
        // Skip if no image URL
        if (tool.imageUrl == null || tool.imageUrl!.isEmpty) {
          skippedCount++;
          continue;
        }

        // Check if already cached
        final existingPath = _localStorage.getCachedImagePath(tool.id);
        if (existingPath != null &&
            _imageCacheService.isImageCached(existingPath)) {
          skippedCount++;
          continue;
        }

        // Download and cache image
        try {
          final localPath = await _imageCacheService.downloadAndCacheImage(
            tool.imageUrl!,
            tool.id,
          );

          if (localPath != null) {
            await _localStorage.saveCachedImagePath(tool.id, localPath);
            downloadedCount++;
          } else {
            errorCount++;
          }
        } catch (e) {
          debugPrint('❌ Error downloading image for tool ${tool.toolId}: $e');
          errorCount++;
        }
      }

      debugPrint('✅ Image download completed:');
      debugPrint('   - Downloaded: $downloadedCount');
      debugPrint('   - Skipped (already cached or no URL): $skippedCount');
      debugPrint('   - Errors: $errorCount');
    } catch (e) {
      debugPrint('❌ Error in _downloadToolImages: $e');
    }
  }

  /// Force full re-sync of all inventory data
  Future<void> forceFullSync() async {
    try {
      debugPrint('🔄 Force full sync requested');

      // Clear local storage
      await _localStorage.clearTools();

      // Re-sync
      await syncInventory();
    } catch (e) {
      debugPrint('❌ Error in force full sync: $e');
      rethrow;
    }
  }

  /// Get local cached tools (offline access)
  /// Automatically injects cached image paths for offline display
  List<InventoryTool> getLocalTools() {
    final tools = _localStorage.getAllTools();

    // Inject cached image paths into tools
    return tools.map((tool) {
      final cachedPath = _localStorage.getCachedImagePath(tool.id);
      if (cachedPath != null && tool.localImagePath != cachedPath) {
        return tool.copyWith(localImagePath: cachedPath);
      }
      return tool;
    }).toList();
  }

  /// Get cached image path for a tool (offline access)
  String? getCachedImagePath(String toolId) {
    return _localStorage.getCachedImagePath(toolId);
  }

  /// Check if an image is cached for a tool
  bool hasImageCached(String toolId) {
    return _localStorage.hasImageCached(toolId);
  }

  /// Get sync status information
  Map<String, dynamic> getSyncStatus() {
    final stats = _localStorage.getCacheStats();
    return {
      'isOnline': connectivityService.isOnline,
      'isSyncing': _isSyncing,
      'lastSyncTime': _lastSyncTime?.toIso8601String(),
      'cachedToolsCount': stats['toolsCount'],
      'cachedImagesCount': stats['cachedImagesCount'],
    };
  }

  /// Get detailed cache statistics
  Future<Map<String, dynamic>> getCacheStatistics() async {
    final toolStats = _localStorage.getCacheStats();
    final imageStats = await _imageCacheService.getCacheStats();

    return {
      'tools': toolStats,
      'images': imageStats,
      'lastSync': _lastSyncTime?.toIso8601String(),
      'isOnline': connectivityService.isOnline,
    };
  }

  /// Clear all cached data (tools and images)
  Future<void> clearAllCache() async {
    try {
      debugPrint('🧹 Clearing all inventory cache...');

      await _localStorage.clearTools();
      await _localStorage.clearImagePaths();
      await _imageCacheService.clearAllCachedImages();

      _lastSyncTime = null;
      debugPrint('✅ All inventory cache cleared');
    } catch (e) {
      debugPrint('❌ Error clearing cache: $e');
      rethrow;
    }
  }

  /// Dispose and clean up resources
  Future<void> dispose() async {
    try {
      await _connectivitySubscription?.cancel();
      await _firebaseSubscription?.cancel();
      debugPrint('🔄 InventorySyncService: Disposed');
    } catch (e) {
      debugPrint('❌ InventorySyncService: Dispose error: $e');
    }
  }
}
