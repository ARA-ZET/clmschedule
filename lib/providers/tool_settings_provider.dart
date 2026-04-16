import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/tool_settings.dart';
import '../models/happy_sun_shared.dart';
import '../models/inventory_tool.dart';
import '../services/tool_settings_service.dart';

/// Riverpod provider for ToolSettingsProvider
final toolSettingsRiverpod =
    riverpod.ChangeNotifierProvider<ToolSettingsProvider>((ref) {
  return ToolSettingsProvider();
});

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
  Future<void> removeTeamTool(String baseName) async {
    final updatedSettings = _settings.copyWith(
      teamTools:
          _settings.teamTools.where((t) => t.baseName != baseName).toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Update team tool quantity
  Future<void> updateTeamToolQuantity(String baseName, int quantity) async {
    final updatedSettings = _settings.copyWith(
      teamTools: _settings.teamTools.map((t) {
        if (t.baseName == baseName) {
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
  Future<void> removeIndividualTool(String baseName) async {
    final updatedSettings = _settings.copyWith(
      individualTools: _settings.individualTools
          .where((t) => t.baseName != baseName)
          .toList(),
    );
    await saveSettings(updatedSettings);
  }

  /// Update individual tool quantity
  Future<void> updateIndividualToolQuantity(
      String baseName, int quantity) async {
    final updatedSettings = _settings.copyWith(
      individualTools: _settings.individualTools.map((t) {
        if (t.baseName == baseName) {
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
      toolsMap[tool.baseName] = tool;
    }

    // Add individual tools (multiplied by number of cleaners)
    for (final tool in _settings.individualTools) {
      if (toolsMap.containsKey(tool.baseName)) {
        // Tool already exists, add quantities
        final existing = toolsMap[tool.baseName]!;
        toolsMap[tool.baseName] = existing.copyWith(
          quantity: existing.quantity + (tool.quantity * numberOfCleaners),
        );
      } else {
        // New tool, multiply by cleaners
        toolsMap[tool.baseName] = tool.copyWith(
          quantity: tool.quantity * numberOfCleaners,
        );
      }
    }

    return toolsMap.values.toList();
  }

  /// Convert tool requirements to categorized grouped tools
  /// Creates a preparation list - actual tool IDs assigned at checkout
  CategorizedTools calculateCategorizedTools(
    int numberOfCleaners,
    List<InventoryTool> availableInventory,
  ) {
    // Helper to get base name from tool name
    String getBaseName(String toolName) {
      final hashIndex = toolName.lastIndexOf('#');
      if (hashIndex > 0) {
        return toolName.substring(0, hashIndex).trim();
      }
      return toolName;
    }

    // Map to track all tools including accessories
    final Map<String, _GroupedToolBuilder> allToolsMap = {};

    // Process team tools
    for (final tool in _settings.teamTools) {
      final baseName = tool.baseName;

      if (!allToolsMap.containsKey(baseName)) {
        allToolsMap[baseName] = _GroupedToolBuilder(
          baseName: baseName,
          category: tool.category,
        );
      }

      // Add requested quantity
      for (int i = 0; i < tool.quantity; i++) {
        allToolsMap[baseName]!.addTool('');
      }

      // Find accessories for this tool and add them
      final matchingTools = availableInventory
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final parentTool = matchingTools.first;

        // Get accessories from parent tool using requiredAccessories
        for (final accessoryReq in parentTool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * tool.quantity;

          // Find the category for this accessory
          final accessoryTools = availableInventory
              .where((t) => getBaseName(t.name) == accessoryBaseName)
              .toList();

          if (accessoryTools.isNotEmpty) {
            final accessoryCategory = accessoryTools.first.category;

            if (!allToolsMap.containsKey(accessoryBaseName)) {
              allToolsMap[accessoryBaseName] = _GroupedToolBuilder(
                baseName: accessoryBaseName,
                category: accessoryCategory,
              );
            }

            // Add the required quantity
            for (int j = 0; j < totalQty; j++) {
              allToolsMap[accessoryBaseName]!.addTool('');
            }
          }
        }
      }
    }

    // Process individual tools (multiply by cleaners)
    for (final tool in _settings.individualTools) {
      final baseName = tool.baseName;

      if (!allToolsMap.containsKey(baseName)) {
        allToolsMap[baseName] = _GroupedToolBuilder(
          baseName: baseName,
          category: tool.category,
        );
      }

      final neededCount = tool.quantity * numberOfCleaners;
      for (int i = 0; i < neededCount; i++) {
        allToolsMap[baseName]!.addTool('');
      }

      // Find accessories for this tool and add them
      final matchingTools = availableInventory
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final parentTool = matchingTools.first;

        // Get accessories from parent tool using requiredAccessories
        for (final accessoryReq in parentTool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * neededCount;

          // Find the category for this accessory
          final accessoryTools = availableInventory
              .where((t) => getBaseName(t.name) == accessoryBaseName)
              .toList();

          if (accessoryTools.isNotEmpty) {
            final accessoryCategory = accessoryTools.first.category;

            if (!allToolsMap.containsKey(accessoryBaseName)) {
              allToolsMap[accessoryBaseName] = _GroupedToolBuilder(
                baseName: accessoryBaseName,
                category: accessoryCategory,
              );
            }

            // Add the required quantity
            for (int j = 0; j < totalQty; j++) {
              allToolsMap[accessoryBaseName]!.addTool('');
            }
          }
        }
      }
    }

    // Separate team tools, individual tools, and accessories
    final teamToolsMap = <String, _GroupedToolBuilder>{};
    final individualToolsMap = <String, _GroupedToolBuilder>{};
    final accessoriesMap = <String, _GroupedToolBuilder>{};

    // Collect base names from settings to distinguish tools from accessories
    final teamToolBaseNames =
        _settings.teamTools.map((t) => t.baseName).toSet();
    final individualToolBaseNames =
        _settings.individualTools.map((t) => t.baseName).toSet();

    // Team tools are those from settings
    for (final tool in _settings.teamTools) {
      final baseName = tool.baseName;
      if (allToolsMap.containsKey(baseName)) {
        teamToolsMap[baseName] = allToolsMap[baseName]!;
      }
    }

    // Individual tools are those from settings (not in team)
    for (final tool in _settings.individualTools) {
      final baseName = tool.baseName;
      if (allToolsMap.containsKey(baseName) &&
          !teamToolsMap.containsKey(baseName)) {
        individualToolsMap[baseName] = allToolsMap[baseName]!;
      }
    }

    // Accessories are everything else (not in settings)
    for (final entry in allToolsMap.entries) {
      if (!teamToolBaseNames.contains(entry.key) &&
          !individualToolBaseNames.contains(entry.key)) {
        accessoriesMap[entry.key] = entry.value;
      }
    }

    return CategorizedTools(
      teamTools: teamToolsMap.values.map((builder) => builder.build()).toList()
        ..sort((a, b) => a.baseName.compareTo(b.baseName)),
      individualTools:
          individualToolsMap.values.map((builder) => builder.build()).toList()
            ..sort((a, b) => a.baseName.compareTo(b.baseName)),
      extras: [],
      accessories:
          accessoriesMap.values.map((builder) => builder.build()).toList()
            ..sort((a, b) => a.baseName.compareTo(b.baseName)),
    );
  }

  /// Calculate only individual tools based on number of cleaners
  /// Used when updating an existing job's cleaner count
  List<GroupedToolItem> calculateIndividualTools(
    int numberOfCleaners,
    List<InventoryTool> availableInventory,
  ) {
    // Helper to get base name from tool name
    String getBaseName(String toolName) {
      final hashIndex = toolName.lastIndexOf('#');
      if (hashIndex > 0) {
        return toolName.substring(0, hashIndex).trim();
      }
      return toolName;
    }

    // Map to track all individual tools including accessories
    final individualToolsMap = <String, _GroupedToolBuilder>{};

    for (final tool in _settings.individualTools) {
      final baseName = tool.baseName;

      if (!individualToolsMap.containsKey(baseName)) {
        individualToolsMap[baseName] = _GroupedToolBuilder(
          baseName: baseName,
          category: tool.category,
        );
      }

      final neededCount = tool.quantity * numberOfCleaners;
      for (int i = 0; i < neededCount; i++) {
        individualToolsMap[baseName]!.addTool('');
      }

      // Find accessories for this tool and add them
      final matchingTools = availableInventory
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final parentTool = matchingTools.first;

        // Get accessories from parent tool using requiredAccessories
        for (final accessoryReq in parentTool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * neededCount;

          // Find the category for this accessory
          final accessoryTools = availableInventory
              .where((t) => getBaseName(t.name) == accessoryBaseName)
              .toList();

          if (accessoryTools.isNotEmpty) {
            final accessoryCategory = accessoryTools.first.category;

            if (!individualToolsMap.containsKey(accessoryBaseName)) {
              individualToolsMap[accessoryBaseName] = _GroupedToolBuilder(
                baseName: accessoryBaseName,
                category: accessoryCategory,
              );
            }

            // Add the required quantity
            for (int j = 0; j < totalQty; j++) {
              individualToolsMap[accessoryBaseName]!.addTool('');
            }
          }
        }
      }
    }

    return individualToolsMap.values.map((builder) => builder.build()).toList()
      ..sort((a, b) => a.baseName.compareTo(b.baseName));
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
