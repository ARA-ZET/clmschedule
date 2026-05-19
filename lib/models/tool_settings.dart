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
                  ToolRequirement.fromMap(Map<String, dynamic>.from(item as Map)))
              .toList() ??
          [],
      individualTools: (data['individualTools'] as List<dynamic>?)
              ?.map((item) =>
                  ToolRequirement.fromMap(Map<String, dynamic>.from(item as Map)))
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
  final String baseName;
  final String category;
  final int quantity;

  ToolRequirement({
    required this.baseName,
    required this.category,
    required this.quantity,
  });

  factory ToolRequirement.fromMap(Map<String, dynamic> data) {
    // Backward compatibility: if old format has 'toolId' and 'name', migrate to baseName
    String baseName;
    if (data.containsKey('baseName')) {
      baseName = data['baseName'] as String? ?? '';
    } else if (data.containsKey('name')) {
      // Old format: extract base name from full name (remove #number suffix)
      final name = data['name'] as String? ?? '';
      final parts = name.split(' #');
      baseName = parts.first;
    } else {
      baseName = '';
    }

    return ToolRequirement(
      baseName: baseName,
      category: data['category'] as String? ?? '',
      quantity: (data['quantity'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'baseName': baseName,
      'category': category,
      'quantity': quantity,
    };
  }

  ToolRequirement copyWith({
    String? baseName,
    String? category,
    int? quantity,
  }) {
    return ToolRequirement(
      baseName: baseName ?? this.baseName,
      category: category ?? this.category,
      quantity: quantity ?? this.quantity,
    );
  }
}
