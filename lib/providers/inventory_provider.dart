import 'package:flutter/material.dart';
import 'dart:async';
import '../models/inventory_tool.dart';
import '../services/inventory_service.dart';
import '../services/inventory_sync_service.dart';

class InventoryProvider extends ChangeNotifier {
  final InventoryService _inventoryService;

  List<InventoryTool> _tools = [];
  String? _selectedCategory;
  String? _selectedAvailability; // null = All, 'available', 'in-use'
  String _searchQuery = '';
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<InventoryTool>>? _toolsSubscription;

  // Offline support (Happy Sun flavor only)
  InventorySyncService? _syncService;
  bool _isOfflineMode = false;

  InventoryProvider(this._inventoryService);

  // Getters for offline support
  InventorySyncService? get syncService => _syncService;
  bool get isOfflineMode => _isOfflineMode;
  bool get isOnline {
    if (_syncService == null) return true;
    return _syncService!.connectivityService.isOnline;
  }

  bool get isSyncing => _syncService?.isSyncing ?? false;
  DateTime? get lastSyncTime => _syncService?.lastSyncTime;

  /// Set offline services (call from main.dart for Happy Sun flavor)
  void setOfflineServices(InventorySyncService? syncService) {
    _syncService = syncService;
    _isOfflineMode = syncService != null;
    debugPrint(
        'InventoryProvider: Offline mode ${_isOfflineMode ? "ENABLED" : "DISABLED"}');
    notifyListeners();
  }

  // Getters
  List<InventoryTool> get tools => _tools;
  String? get selectedCategory => _selectedCategory;
  String? get selectedAvailability => _selectedAvailability;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  String? get error => _error;

  List<InventoryTool> get filteredTools {
    var filtered = _tools;

    // Filter by category
    if (_selectedCategory != null && _selectedCategory != 'All') {
      filtered =
          filtered.where((tool) => tool.category == _selectedCategory).toList();
    }

    // Filter by availability
    if (_selectedAvailability != null && _selectedAvailability != 'All') {
      if (_selectedAvailability == 'available') {
        filtered = filtered.where((tool) => tool.isAvailable).toList();
      } else if (_selectedAvailability == 'in-use') {
        filtered = filtered.where((tool) => !tool.isAvailable).toList();
      }
    }

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((tool) {
        return tool.name.toLowerCase().contains(query) ||
            tool.toolId.toLowerCase().contains(query) ||
            tool.description.toLowerCase().contains(query) ||
            (tool.currentProject?.toLowerCase().contains(query) ?? false);
      }).toList();
    }

    return filtered;
  }

  List<String> get categories {
    return ['All', ...ToolCategory.all];
  }

  // Initialize and load tools
  Future<void> initialize() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Offline-first approach for Happy Sun flavor
      if (_isOfflineMode && _syncService != null) {
        debugPrint('🔄 Inventory: Loading from local storage first...');

        // Load from local storage immediately (fast)
        final localTools = _syncService!.getLocalTools();
        if (localTools.isNotEmpty) {
          _tools = localTools;
          _isLoading = false;
          notifyListeners();
          debugPrint(
              '✅ Inventory: Loaded ${localTools.length} tools from cache (~instant)');
        }

        // Then listen to Firebase for updates (if online)
        if (isOnline) {
          debugPrint('📡 Inventory: Listening to Firebase for updates...');
          _toolsSubscription?.cancel();
          _toolsSubscription = _inventoryService.getTools().listen(
            (tools) {
              // Inject cached image paths into tools from Firebase
              _tools = _injectCachedImagePaths(tools);
              _isLoading = false;
              _error = null;
              notifyListeners();
              debugPrint(
                  '✅ Inventory: Updated from Firebase (${tools.length} tools)');
            },
            onError: (error) {
              debugPrint('⚠️ Inventory: Firebase error: $error');
              // Keep local data, don't show error if we have cached data
              if (_tools.isEmpty) {
                _error = error.toString();
              }
              _isLoading = false;
              notifyListeners();
            },
          );
        } else {
          debugPrint('📡 Inventory: Offline - using cached data only');
        }
      } else {
        // Standard Firebase-only approach (CLM flavor)
        _toolsSubscription?.cancel();
        _toolsSubscription = _inventoryService.getTools().listen(
          (tools) {
            _tools = tools;
            _isLoading = false;
            _error = null;
            notifyListeners();
          },
          onError: (error) {
            _error = error.toString();
            _isLoading = false;
            notifyListeners();
          },
        );
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  // Set category filter
  void setCategory(String? category) {
    _selectedCategory = category;
    notifyListeners();
  }

  // Set availability filter
  void setAvailability(String? availability) {
    _selectedAvailability = availability;
    notifyListeners();
  }

  // Set search query
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  // Clear all filters
  void clearFilters() {
    _selectedCategory = null;
    _selectedAvailability = null;
    _searchQuery = '';
    notifyListeners();
  }

  // Add new tools
  Future<void> addTools(String name, String description, String? imageUrl,
      String category, int quantity) async {
    try {
      await _inventoryService.addTools(
          name, description, imageUrl, category, quantity);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Add new tools with image upload
  Future<void> addToolsWithImage(String name, String description,
      String? imageUrl, String category, int quantity,
      {ToolType toolType = ToolType.extras}) async {
    try {
      await _inventoryService.addTools(
          name, description, imageUrl, category, quantity,
          toolType: toolType);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Add new tools with image file (uploads image first with proper tool ID)
  Future<void> addToolsWithImageFile(String name, String description,
      dynamic imageFile, String category, int quantity,
      {ToolType toolType = ToolType.extras}) async {
    try {
      await _inventoryService.addToolsWithImageFile(
          name, description, imageFile, category, quantity,
          toolType: toolType);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Upload image to Firebase Storage
  Future<String?> uploadImage(String toolName, dynamic imageFile) async {
    try {
      return await _inventoryService.uploadToolImage(toolName, imageFile);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  // Delete image from Firebase Storage
  Future<void> deleteImage(String imageUrl) async {
    try {
      await _inventoryService.deleteToolImage(imageUrl);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // Update image URL for all tools with the same base name
  Future<void> updateImageForAllToolsWithSameName(
      String toolName, String imageUrl) async {
    try {
      await _inventoryService.updateImageForAllToolsWithSameName(
          toolName, imageUrl);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Update tool
  Future<void> updateTool(InventoryTool tool) async {
    try {
      await _inventoryService.updateTool(tool);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Delete tool
  Future<void> deleteTool(String toolId) async {
    try {
      await _inventoryService.deleteTool(toolId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Get tool by QR code
  Future<InventoryTool?> getToolByQrCode(String qrCode) async {
    try {
      // Offline mode: search in local cache first
      if (_isOfflineMode && !isOnline) {
        debugPrint('🔍 Searching for QR code in local cache: $qrCode');
        final tool = _tools.firstWhere(
          (t) => t.qrCode == qrCode,
          orElse: () => throw Exception('Tool not found'),
        );
        return tool;
      }

      return await _inventoryService.getToolByQrCode(qrCode);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// Get cached image path for a tool (offline support)
  String? getCachedImagePath(String toolId) {
    if (_syncService != null) {
      return _syncService!.getCachedImagePath(toolId);
    }
    return null;
  }

  /// Check if tool has cached image
  bool hasImageCached(String toolId) {
    if (_syncService != null) {
      return _syncService!.hasImageCached(toolId);
    }
    return false;
  }

  /// Force sync inventory (manual refresh)
  Future<void> forceSync() async {
    if (_syncService != null && isOnline) {
      try {
        await _syncService!.syncInventory();
        debugPrint('✅ Inventory: Manual sync completed');
      } catch (e) {
        _error = 'Sync failed: $e';
        notifyListeners();
        rethrow;
      }
    }
  }

  /// Get sync status information
  Map<String, dynamic> getSyncStatus() {
    if (_syncService != null) {
      return _syncService!.getSyncStatus();
    }
    return {
      'isOnline': true,
      'isSyncing': false,
      'lastSyncTime': null,
      'cachedToolsCount': 0,
      'cachedImagesCount': 0,
    };
  }

  // Assign tool to project
  Future<void> assignToolToProject(String toolId, String projectId) async {
    try {
      await _inventoryService.assignToolToProject(toolId, projectId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Return tool from project
  Future<void> returnToolFromProject(String toolId) async {
    try {
      await _inventoryService.returnToolFromProject(toolId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Check out tools (mark as in use for a project)
  Future<void> checkOutTools(List<String> toolIds, String projectId) async {
    try {
      await _inventoryService.checkOutTools(toolIds, projectId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Check in tools (mark as available)
  Future<void> checkInTools(List<String> toolIds) async {
    try {
      await _inventoryService.checkInTools(toolIds);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Get accessories for a tool
  List<InventoryTool> getAccessories(String toolId) {
    final tool = _tools.firstWhere(
      (t) => t.id == toolId,
      orElse: () => throw Exception('Tool not found'),
    );

    return _tools.where((t) => tool.accessoryIds.contains(t.id)).toList();
  }

  // Get all tools with their accessories (flattened list)
  List<String> getToolIdsWithAccessories(List<String> toolIds) {
    final allIds = <String>[];

    for (final toolId in toolIds) {
      allIds.add(toolId);

      try {
        final accessories = getAccessories(toolId);
        allIds.addAll(accessories.map((a) => a.id));
      } catch (e) {
        // Tool might not have accessories
      }
    }

    return allIds;
  }

  // Get parent tool of an accessory
  InventoryTool? getParentTool(String accessoryId) {
    final accessory = _tools.firstWhere(
      (t) => t.id == accessoryId,
      orElse: () => throw Exception('Accessory not found'),
    );

    if (accessory.parentToolId == null) return null;

    try {
      return _tools.firstWhere((t) => t.id == accessory.parentToolId);
    } catch (e) {
      return null;
    }
  }

  // Update tool accessories
  Future<void> updateToolAccessories(
      String toolId, List<String> accessoryIds) async {
    try {
      await _inventoryService.updateToolAccessories(toolId, accessoryIds);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Update tool required accessories (with base names and quantities)
  Future<void> updateToolRequiredAccessories(
      String toolId, List<AccessoryRequirement> requiredAccessories) async {
    try {
      await _inventoryService.updateToolRequiredAccessories(
          toolId, requiredAccessories);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Inject cached image paths into tools for offline display
  List<InventoryTool> _injectCachedImagePaths(List<InventoryTool> tools) {
    if (_syncService == null) return tools;

    return tools.map((tool) {
      final cachedPath = _syncService!.getCachedImagePath(tool.id);
      if (cachedPath != null && tool.localImagePath != cachedPath) {
        return tool.copyWith(localImagePath: cachedPath);
      }
      return tool;
    }).toList();
  }

  @override
  void dispose() {
    _toolsSubscription?.cancel();
    super.dispose();
  }
}
