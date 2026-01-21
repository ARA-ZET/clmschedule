import 'package:flutter/foundation.dart';
import '../models/tool_settings.dart';
import '../models/happy_sun_job.dart';
import '../models/inventory_tool.dart';
import '../services/tool_settings_service.dart';

class ToolSettingsProvider with ChangeNotifier {
  final ToolSettingsService _service = ToolSettingsService();

  ToolSettings _settings = ToolSettings.empty();
  bool _isLoading = false;
  String? _error;

  ToolSettings get settings => _settings;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Load tool settings
  Future<void> loadSettings() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _settings = await _service.getToolSettings();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Save tool settings
  Future<void> saveSettings(ToolSettings settings) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _service.saveToolSettings(settings);
      _settings = settings;
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Add team tool
  Future<void> addTeamTool(ToolRequirement tool) async {
    final updatedSettings = _settings.copyWith(
      teamTools: [..._settings.teamTools, tool],
    );
    await saveSettings(updatedSettings);
  }

  /// Remove team tool
  Future<void> removeTeamTool(String toolId) async {
    final updatedSettings = _settings.copyWith(
      teamTools: _settings.teamTools.where((t) => t.toolId != toolId).toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Update team tool quantity
  Future<void> updateTeamToolQuantity(String toolId, int quantity) async {
    final updatedSettings = _settings.copyWith(
      teamTools: _settings.teamTools.map((t) {
        if (t.toolId == toolId) {
          return t.copyWith(quantity: quantity);
        }
        return t;
      }).toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Add individual tool
  Future<void> addIndividualTool(ToolRequirement tool) async {
    final updatedSettings = _settings.copyWith(
      individualTools: [..._settings.individualTools, tool],
    );
    await saveSettings(updatedSettings);
  }

  /// Remove individual tool
  Future<void> removeIndividualTool(String toolId) async {
    final updatedSettings = _settings.copyWith(
      individualTools:
          _settings.individualTools.where((t) => t.toolId != toolId).toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Update individual tool quantity
  Future<void> updateIndividualToolQuantity(String toolId, int quantity) async {
    final updatedSettings = _settings.copyWith(
      individualTools: _settings.individualTools.map((t) {
        if (t.toolId == toolId) {
          return t.copyWith(quantity: quantity);
        }
        return t;
      }).toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Calculate total tools needed for a job
  List<ToolRequirement> calculateToolsNeeded(int numberOfCleaners) {
    final Map<String, ToolRequirement> toolsMap = {};

    // Add team tools
    for (final tool in _settings.teamTools) {
      toolsMap[tool.toolId] = tool;
    }

    // Add individual tools (multiplied by number of cleaners)
    for (final tool in _settings.individualTools) {
      if (toolsMap.containsKey(tool.toolId)) {
        // Tool already exists, add quantities
        final existing = toolsMap[tool.toolId]!;
        toolsMap[tool.toolId] = existing.copyWith(
          quantity: existing.quantity + (tool.quantity * numberOfCleaners),
        );
      } else {
        // New tool, multiply by cleaners
        toolsMap[tool.toolId] = tool.copyWith(
          quantity: tool.quantity * numberOfCleaners,
        );
      }
    }

    return toolsMap.values.toList();
  }

  /// Convert tool requirements to categorized grouped tools
  /// Groups tools by base name and limits to available inventory
  CategorizedTools calculateCategorizedTools(
    int numberOfCleaners,
    List<InventoryTool> availableInventory,
  ) {
    // Group team tools by base name
    final teamToolsMap = <String, _GroupedToolBuilder>{};
    for (final tool in _settings.teamTools) {
      final matchingTools = availableInventory
          .where((inv) =>
              inv.toolType == ToolType.team && inv.toolId == tool.toolId)
          .toList();

      if (matchingTools.isNotEmpty) {
        final baseName = matchingTools.first.baseName;
        if (!teamToolsMap.containsKey(baseName)) {
          teamToolsMap[baseName] = _GroupedToolBuilder(
            baseName: baseName,
            category: matchingTools.first.category,
          );
        }
        // Add up to requested quantity, limited by availability
        final availableCount = matchingTools.length;
        final neededCount = tool.quantity;
        final takeCount =
            neededCount < availableCount ? neededCount : availableCount;

        for (int i = 0; i < takeCount; i++) {
          teamToolsMap[baseName]!.addTool(matchingTools[i].toolId);
        }
      }
    }

    // Group individual tools by base name (multiply by cleaners)
    final individualToolsMap = <String, _GroupedToolBuilder>{};
    for (final tool in _settings.individualTools) {
      final matchingTools = availableInventory
          .where((inv) =>
              inv.toolType == ToolType.individual && inv.toolId == tool.toolId)
          .toList();

      if (matchingTools.isNotEmpty) {
        final baseName = matchingTools.first.baseName;
        if (!individualToolsMap.containsKey(baseName)) {
          individualToolsMap[baseName] = _GroupedToolBuilder(
            baseName: baseName,
            category: matchingTools.first.category,
          );
        }
        // Multiply by cleaners and limit by availability
        final availableCount = matchingTools.length;
        final neededCount = tool.quantity * numberOfCleaners;
        final takeCount =
            neededCount < availableCount ? neededCount : availableCount;

        for (int i = 0; i < takeCount; i++) {
          individualToolsMap[baseName]!.addTool(matchingTools[i].toolId);
        }
      }
    }

    return CategorizedTools(
      teamTools: teamToolsMap.values.map((builder) => builder.build()).toList()
        ..sort((a, b) => a.baseName.compareTo(b.baseName)),
      individualTools:
          individualToolsMap.values.map((builder) => builder.build()).toList()
            ..sort((a, b) => a.baseName.compareTo(b.baseName)),
      extras: [], // Can be added manually later
    );
  }
}

/// Helper class for building grouped tools
class _GroupedToolBuilder {
  final String baseName;
  final String category;
  final List<String> _toolIds = [];

  _GroupedToolBuilder({
    required this.baseName,
    required this.category,
  });

  void addTool(String toolId) {
    _toolIds.add(toolId);
  }

  GroupedToolItem build() {
    return GroupedToolItem(
      baseName: baseName,
      category: category,
      totalQuantity: _toolIds.length,
      toolIds: _toolIds,
    );
  }
}
