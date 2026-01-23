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
    // Group team tools by base name
    final teamToolsMap = <String, _GroupedToolBuilder>{};
    for (final tool in _settings.teamTools) {
      if (!teamToolsMap.containsKey(tool.baseName)) {
        teamToolsMap[tool.baseName] = _GroupedToolBuilder(
          baseName: tool.baseName,
          category: tool.category,
        );
      }
      // Add requested quantity as empty placeholders (IDs assigned at checkout)
      for (int i = 0; i < tool.quantity; i++) {
        teamToolsMap[tool.baseName]!
            .addTool(''); // Empty ID - assigned at checkout
      }
    }

    // Group individual tools by base name (multiply by cleaners)
    final individualToolsMap = <String, _GroupedToolBuilder>{};
    for (final tool in _settings.individualTools) {
      if (!individualToolsMap.containsKey(tool.baseName)) {
        individualToolsMap[tool.baseName] = _GroupedToolBuilder(
          baseName: tool.baseName,
          category: tool.category,
        );
      }
      // Multiply by cleaners and add as placeholders
      final neededCount = tool.quantity * numberOfCleaners;
      for (int i = 0; i < neededCount; i++) {
        individualToolsMap[tool.baseName]!
            .addTool(''); // Empty ID - assigned at checkout
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

  /// Calculate only individual tools based on number of cleaners
  /// Used when updating an existing job's cleaner count
  List<GroupedToolItem> calculateIndividualTools(
    int numberOfCleaners,
    List<InventoryTool> availableInventory,
  ) {
    // Group individual tools by base name (multiply by cleaners)
    final individualToolsMap = <String, _GroupedToolBuilder>{};
    for (final tool in _settings.individualTools) {
      if (!individualToolsMap.containsKey(tool.baseName)) {
        individualToolsMap[tool.baseName] = _GroupedToolBuilder(
          baseName: tool.baseName,
          category: tool.category,
        );
      }
      // Multiply by cleaners
      final neededCount = tool.quantity * numberOfCleaners;
      for (int i = 0; i < neededCount; i++) {
        individualToolsMap[tool.baseName]!
            .addTool(''); // Empty ID - assigned at checkout
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
