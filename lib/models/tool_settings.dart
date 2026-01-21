class ToolSettings {
  final List<ToolRequirement> teamTools;
  final List<ToolRequirement> individualTools;

  ToolSettings({
    required this.teamTools,
    required this.individualTools,
  });

  factory ToolSettings.empty() {
    return ToolSettings(
      teamTools: [],
      individualTools: [],
    );
  }

  factory ToolSettings.fromMap(Map<String, dynamic> data) {
    return ToolSettings(
      teamTools: (data['teamTools'] as List<dynamic>?)
              ?.map((item) =>
                  ToolRequirement.fromMap(item as Map<String, dynamic>))
              .toList() ??
          [],
      individualTools: (data['individualTools'] as List<dynamic>?)
              ?.map((item) =>
                  ToolRequirement.fromMap(item as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'teamTools': teamTools.map((tool) => tool.toMap()).toList(),
      'individualTools': individualTools.map((tool) => tool.toMap()).toList(),
    };
  }

  ToolSettings copyWith({
    List<ToolRequirement>? teamTools,
    List<ToolRequirement>? individualTools,
  }) {
    return ToolSettings(
      teamTools: teamTools ?? this.teamTools,
      individualTools: individualTools ?? this.individualTools,
    );
  }
}

class ToolRequirement {
  final String toolId;
  final String name;
  final String category;
  final int quantity;

  ToolRequirement({
    required this.toolId,
    required this.name,
    required this.category,
    required this.quantity,
  });

  factory ToolRequirement.fromMap(Map<String, dynamic> data) {
    return ToolRequirement(
      toolId: data['toolId'] as String? ?? '',
      name: data['name'] as String? ?? '',
      category: data['category'] as String? ?? '',
      quantity: data['quantity'] as int? ?? 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'toolId': toolId,
      'name': name,
      'category': category,
      'quantity': quantity,
    };
  }

  ToolRequirement copyWith({
    String? toolId,
    String? name,
    String? category,
    int? quantity,
  }) {
    return ToolRequirement(
      toolId: toolId ?? this.toolId,
      name: name ?? this.name,
      category: category ?? this.category,
      quantity: quantity ?? this.quantity,
    );
  }
}
