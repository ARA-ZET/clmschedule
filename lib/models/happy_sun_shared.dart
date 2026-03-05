import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a single tool's checklist status
class ToolChecklistItem {
  final String toolId;
  final String baseName;
  final String category;
  final String status; // 'present', 'broken', 'missing'
  final String notes;
  final bool isVerified;

  ToolChecklistItem({
    required this.toolId,
    required this.baseName,
    required this.category,
    required this.status,
    this.notes = '',
    required this.isVerified,
  });

  factory ToolChecklistItem.fromMap(Map<String, dynamic> data) {
    return ToolChecklistItem(
      toolId: data['toolId'] ?? '',
      baseName: data['baseName'] ?? '',
      category: data['category'] ?? 'General',
      status: data['status'] ?? 'present',
      notes: data['notes'] ?? '',
      isVerified: data['isVerified'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'toolId': toolId,
      'baseName': baseName,
      'category': category,
      'status': status,
      'notes': notes,
      'isVerified': isVerified,
    };
  }
}

/// Represents the complete checklist data
class ChecklistData {
  final List<ToolChecklistItem> items;
  final DateTime completedAt;
  final String completedBy;
  final int totalTools;
  final int verifiedCount;
  final int brokenCount;
  final int missingCount;
  final String summary;
  final bool
      isCompleted; // True when checklist is completed, false for saved progress

  ChecklistData({
    required this.items,
    required this.completedAt,
    required this.completedBy,
    required this.totalTools,
    required this.verifiedCount,
    required this.brokenCount,
    required this.missingCount,
    this.summary = '',
    this.isCompleted = false,
  });

  /// Helper to parse DateTime from either Timestamp or String
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory ChecklistData.fromMap(Map<String, dynamic> data) {
    return ChecklistData(
      items: (data['items'] as List<dynamic>?)
              ?.map((item) =>
                  ToolChecklistItem.fromMap(item as Map<String, dynamic>))
              .toList() ??
          [],
      completedAt: _parseDateTime(data['completedAt']) ?? DateTime.now(),
      completedBy: data['completedBy'] ?? '',
      totalTools: data['totalTools'] ?? 0,
      verifiedCount: data['verifiedCount'] ?? 0,
      brokenCount: data['brokenCount'] ?? 0,
      missingCount: data['missingCount'] ?? 0,
      summary: data['summary'] ?? '',
      isCompleted: data['isCompleted'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'items': items.map((item) => item.toMap()).toList(),
      'completedAt': Timestamp.fromDate(completedAt),
      'completedBy': completedBy,
      'totalTools': totalTools,
      'verifiedCount': verifiedCount,
      'brokenCount': brokenCount,
      'missingCount': missingCount,
      'summary': summary,
      'isCompleted': isCompleted,
    };
  }
}

/// Represents a tool used in a Happy Sun job
class HappySunToolUsage {
  final String toolId;
  final String toolName;
  final String category;
  final int quantity;
  final DateTime? usedAt;

  HappySunToolUsage({
    required this.toolId,
    required this.toolName,
    required this.category,
    required this.quantity,
    this.usedAt,
  });

  factory HappySunToolUsage.fromMap(Map<String, dynamic> data) {
    return HappySunToolUsage(
      toolId: data['toolId'] ?? '',
      toolName: data['toolName'] ?? '',
      category: data['category'] ?? 'General',
      quantity: data['quantity'] ?? 1,
      usedAt: ChecklistData._parseDateTime(data['usedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'toolId': toolId,
      'toolName': toolName,
      'category': category,
      'quantity': quantity,
      'usedAt': usedAt != null ? Timestamp.fromDate(usedAt!) : null,
    };
  }
}

/// Represents a grouped tool item (tools with same base name)
class GroupedToolItem {
  final String baseName; // Name without #number suffix
  final String category;
  final int totalQuantity; // Total count of this tool type needed
  final List<String> toolIds; // Individual tool IDs (e.g., TOOL#001, TOOL#002)

  GroupedToolItem({
    required this.baseName,
    required this.category,
    required this.totalQuantity,
    required this.toolIds,
  });

  factory GroupedToolItem.fromMap(Map<String, dynamic> data) {
    return GroupedToolItem(
      baseName: data['baseName'] ?? '',
      category: data['category'] ?? 'General',
      totalQuantity: data['totalQuantity'] ?? 0,
      toolIds: (data['toolIds'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'baseName': baseName,
      'category': category,
      'totalQuantity': totalQuantity,
      'toolIds': toolIds,
    };
  }
}

/// Categorized tools structure for Happy Sun jobs
class CategorizedTools {
  final List<GroupedToolItem> teamTools;
  final List<GroupedToolItem> individualTools;
  final List<GroupedToolItem> extras;
  final List<GroupedToolItem> accessories;

  CategorizedTools({
    this.teamTools = const [],
    this.individualTools = const [],
    this.extras = const [],
    this.accessories = const [],
  });

  factory CategorizedTools.fromMap(Map<String, dynamic> data) {
    return CategorizedTools(
      teamTools: (data['teamTools'] as List<dynamic>?)
              ?.map((tool) =>
                  GroupedToolItem.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      individualTools: (data['individualTools'] as List<dynamic>?)
              ?.map((tool) =>
                  GroupedToolItem.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      extras: (data['extras'] as List<dynamic>?)
              ?.map((tool) =>
                  GroupedToolItem.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      accessories: (data['accessories'] as List<dynamic>?)
              ?.map((tool) =>
                  GroupedToolItem.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'teamTools': teamTools.map((tool) => tool.toMap()).toList(),
      'individualTools': individualTools.map((tool) => tool.toMap()).toList(),
      'extras': extras.map((tool) => tool.toMap()).toList(),
      'accessories': accessories.map((tool) => tool.toMap()).toList(),
    };
  }

  int get totalCount {
    int total = 0;
    total += teamTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    total +=
        individualTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    total += extras.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    total += accessories.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    return total;
  }

  // Helper method to get all tools as a flat list
  List<GroupedToolItem> get allTools {
    return [...teamTools, ...individualTools, ...extras, ...accessories];
  }

  // Create an empty instance
  factory CategorizedTools.empty() {
    return CategorizedTools(
      teamTools: [],
      individualTools: [],
      extras: [],
      accessories: [],
    );
  }
}
