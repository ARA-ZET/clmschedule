import 'package:flutter/material.dart';
import 'dart:async';
import '../models/inventory_tool.dart';
import '../services/inventory_service.dart';

class InventoryProvider extends ChangeNotifier {
  final InventoryService _inventoryService;

  List<InventoryTool> _tools = [];
  String? _selectedCategory;
  String? _selectedAvailability; // null = All, 'available', 'in-use'
  String _searchQuery = '';
  bool _isLoading = false;
  String? _error;
  StreamSubscription<List<InventoryTool>>? _toolsSubscription;

  InventoryProvider(this._inventoryService);

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
      return await _inventoryService.getToolByQrCode(qrCode);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
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

  @override
  void dispose() {
    _toolsSubscription?.cancel();
    super.dispose();
  }
}
