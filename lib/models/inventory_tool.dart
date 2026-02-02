import 'package:cloud_firestore/cloud_firestore.dart';

// Tool type enumeration
enum ToolType {
  team,
  individual,
  extras,
  accessories;

  String get displayName {
    switch (this) {
      case ToolType.team:
        return 'Team Tool';
      case ToolType.individual:
        return 'Individual Tool';
      case ToolType.extras:
        return 'Extras';
      case ToolType.accessories:
        return 'Accessories';
    }
  }
}

class InventoryTool {
  final String id;
  final String name;
  final String description;
  final String? imageUrl;
  final String category;
  final String toolId; // Unique TOOL#ID like TOOL#001
  final String qrCode;
  final DateTime createdAt;
  final DateTime? lastUsed;
  final bool isInUse;
  final String? currentProject; // Project ID where tool is currently assigned
  final ToolType toolType; // Type of tool: team, individual, or extras
  final List<String>
      accessoryIds; // IDs of tools that are accessories to this main tool
  final String? parentToolId; // ID of parent tool if this is an accessory
  final bool isAccessory; // True if this is an accessory tool

  InventoryTool({
    required this.id,
    required this.name,
    required this.description,
    this.imageUrl,
    required this.category,
    required this.toolId,
    required this.qrCode,
    required this.createdAt,
    this.lastUsed,
    this.isInUse = false,
    this.currentProject,
    this.toolType = ToolType.extras,
    this.accessoryIds = const [],
    this.parentToolId,
    this.isAccessory = false,
  });

  factory InventoryTool.fromMap(String id, Map<String, dynamic> data) {
    return InventoryTool(
      id: id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      imageUrl: data['imageUrl'],
      category: data['category'] ?? 'General',
      toolId: data['toolId'] ?? id,
      qrCode: data['qrCode'] ?? id,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastUsed: (data['lastUsed'] as Timestamp?)?.toDate(),
      isInUse: data['isInUse'] ?? false,
      currentProject: data['currentProject'],
      toolType: _parseToolType(data),
      accessoryIds: (data['accessoryIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      parentToolId: data['parentToolId'],
      isAccessory: data['isAccessory'] ?? false,
    );
  }

  static ToolType _parseToolType(Map<String, dynamic> data) {
    // Check for new toolType field
    if (data.containsKey('toolType')) {
      final value = data['toolType'];
      if (value is String) {
        switch (value) {
          case 'team':
            return ToolType.team;
          case 'individual':
            return ToolType.individual;
          case 'extras':
            return ToolType.extras;
          case 'accessories':
            return ToolType.accessories;
        }
      }
    }

    // Legacy support: check old boolean fields
    if (data['isTeamTool'] == true) return ToolType.team;
    if (data['isIndividualTool'] == true) return ToolType.individual;

    // Check if it's an accessory based on isAccessory field
    if (data['isAccessory'] == true) return ToolType.accessories;

    return ToolType.extras;
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'imageUrl': imageUrl,
      'category': category,
      'toolId': toolId,
      'qrCode': qrCode,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastUsed': lastUsed != null ? Timestamp.fromDate(lastUsed!) : null,
      'isInUse': isInUse,
      'currentProject': currentProject,
      'toolType': toolType.name,
      'accessoryIds': accessoryIds,
      'parentToolId': parentToolId,
      'isAccessory': isAccessory,
    };
  }

  InventoryTool copyWith({
    String? id,
    String? name,
    String? description,
    String? imageUrl,
    String? category,
    String? toolId,
    String? qrCode,
    DateTime? createdAt,
    DateTime? lastUsed,
    bool? isInUse,
    String? currentProject,
    ToolType? toolType,
    List<String>? accessoryIds,
    String? parentToolId,
    bool? isAccessory,
  }) {
    return InventoryTool(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      category: category ?? this.category,
      toolId: toolId ?? this.toolId,
      qrCode: qrCode ?? this.qrCode,
      createdAt: createdAt ?? this.createdAt,
      lastUsed: lastUsed ?? this.lastUsed,
      isInUse: isInUse ?? this.isInUse,
      currentProject: currentProject ?? this.currentProject,
      toolType: toolType ?? this.toolType,
      accessoryIds: accessoryIds ?? this.accessoryIds,
      parentToolId: parentToolId ?? this.parentToolId,
      isAccessory: isAccessory ?? this.isAccessory,
    );
  }

  bool get isAvailable => !isInUse;

  // Helper getters for backward compatibility
  bool get isTeamTool => toolType == ToolType.team;
  bool get isIndividualTool => toolType == ToolType.individual;

  // Get the base name without #number suffix for grouping
  String get baseName {
    final parts = name.split(' #');
    return parts.first;
  }
}

// Categories for tools
class ToolCategory {
  static const String squeegees = 'Squeegees';
  static const String buckets = 'Buckets';
  static const String ladders = 'Ladders';
  static const String poles = 'Poles';
  static const String cloths = 'Cloths';
  static const String chemicals = 'Chemicals';
  static const String safety = 'Safety Equipment';
  static const String uniform = 'Uniform';
  static const String other = 'Other';

  static List<String> get all => [
        squeegees,
        buckets,
        ladders,
        poles,
        cloths,
        chemicals,
        safety,
        uniform,
        other,
      ];
}
