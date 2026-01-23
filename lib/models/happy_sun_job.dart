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

  ChecklistData({
    required this.items,
    required this.completedAt,
    required this.completedBy,
    required this.totalTools,
    required this.verifiedCount,
    required this.brokenCount,
    required this.missingCount,
    this.summary = '',
  });

  factory ChecklistData.fromMap(Map<String, dynamic> data) {
    return ChecklistData(
      items: (data['items'] as List<dynamic>?)
              ?.map((item) =>
                  ToolChecklistItem.fromMap(item as Map<String, dynamic>))
              .toList() ??
          [],
      completedAt:
          (data['completedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      completedBy: data['completedBy'] ?? '',
      totalTools: data['totalTools'] ?? 0,
      verifiedCount: data['verifiedCount'] ?? 0,
      brokenCount: data['brokenCount'] ?? 0,
      missingCount: data['missingCount'] ?? 0,
      summary: data['summary'] ?? '',
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
      usedAt: (data['usedAt'] as Timestamp?)?.toDate(),
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

  CategorizedTools({
    this.teamTools = const [],
    this.individualTools = const [],
    this.extras = const [],
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
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'teamTools': teamTools.map((tool) => tool.toMap()).toList(),
      'individualTools': individualTools.map((tool) => tool.toMap()).toList(),
      'extras': extras.map((tool) => tool.toMap()).toList(),
    };
  }

  int get totalCount {
    int total = 0;
    total += teamTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    total +=
        individualTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    total += extras.fold<int>(0, (sum, tool) => sum + tool.totalQuantity);
    return total;
  }
}

/// Represents a Happy Sun job (window cleaning or solar panel cleaning)
/// Stored in /happySun/{YYYY-MM}/jobs array
/// Synced with JobListItem by matching ID
class HappySunJob {
  final String id; // Same ID as JobListItem
  final String jobListItemId; // Reference to jobList item
  final DateTime date;
  final String jobType; // 'windowCleaning' or 'solarPanelCleaning'

  // New categorized tool tracking (v2)
  final CategorizedTools? toolsNeededCategorized;
  final CategorizedTools? toolsUsedCategorized;

  // Legacy tool tracking (v1 - for backward compatibility)
  final List<HappySunToolUsage> toolsNeeded; // Planned tools before job starts
  final List<HappySunToolUsage> toolsUsed; // Actual tools used during job

  final List<String> teamMemberIds;

  // Time tracking
  final DateTime? startTime;
  final DateTime? endTime;

  // Notes and observations
  final String? notes;
  final String? weatherConditions;
  final List<String>? photoUrls;

  // Checklist data
  final ChecklistData? checklistData;

  // Status sync with JobListItem
  final String statusId; // Synced from JobListItem

  final DateTime createdAt;
  final DateTime? updatedAt;

  HappySunJob({
    required this.id,
    required this.jobListItemId,
    required this.date,
    required this.jobType,
    this.toolsNeededCategorized,
    this.toolsUsedCategorized,
    this.toolsNeeded = const [],
    this.toolsUsed = const [],
    this.teamMemberIds = const [],
    this.startTime,
    this.endTime,
    this.notes,
    this.weatherConditions,
    this.photoUrls,
    this.checklistData,
    required this.statusId,
    required this.createdAt,
    this.updatedAt,
  });

  factory HappySunJob.fromMap(String id, Map<String, dynamic> data) {
    return HappySunJob(
      id: id,
      jobListItemId: data['jobListItemId'] ?? id,
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      jobType: data['jobType'] ?? 'windowCleaning',
      toolsNeededCategorized: data['toolsNeededCategorized'] != null
          ? CategorizedTools.fromMap(
              data['toolsNeededCategorized'] as Map<String, dynamic>)
          : null,
      toolsUsedCategorized: data['toolsUsedCategorized'] != null
          ? CategorizedTools.fromMap(
              data['toolsUsedCategorized'] as Map<String, dynamic>)
          : null,
      toolsNeeded: (data['toolsNeeded'] as List<dynamic>?)
              ?.map((tool) =>
                  HappySunToolUsage.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      toolsUsed: (data['toolsUsed'] as List<dynamic>?)
              ?.map((tool) =>
                  HappySunToolUsage.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      teamMemberIds:
          (data['teamMemberIds'] as List<dynamic>?)?.cast<String>() ?? [],
      startTime: (data['startTime'] as Timestamp?)?.toDate(),
      endTime: (data['endTime'] as Timestamp?)?.toDate(),
      notes: data['notes'],
      weatherConditions: data['weatherConditions'],
      photoUrls: (data['photoUrls'] as List<dynamic>?)?.cast<String>(),
      checklistData: data['checklistData'] != null
          ? ChecklistData.fromMap(data['checklistData'] as Map<String, dynamic>)
          : null,
      statusId: data['statusId'] ?? 'scheduled',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id, // Include for array storage
      'jobListItemId': jobListItemId,
      'date': Timestamp.fromDate(date),
      'jobType': jobType,
      'toolsNeededCategorized': toolsNeededCategorized?.toMap(),
      'toolsUsedCategorized': toolsUsedCategorized?.toMap(),
      'toolsNeeded': toolsNeeded.map((tool) => tool.toMap()).toList(),
      'toolsUsed': toolsUsed.map((tool) => tool.toMap()).toList(),
      'teamMemberIds': teamMemberIds,
      'startTime': startTime != null ? Timestamp.fromDate(startTime!) : null,
      'endTime': endTime != null ? Timestamp.fromDate(endTime!) : null,
      'notes': notes,
      'weatherConditions': weatherConditions,
      'photoUrls': photoUrls,
      'checklistData': checklistData?.toMap(),
      'statusId': statusId,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
    };
  }

  HappySunJob copyWith({
    String? id,
    String? jobListItemId,
    DateTime? date,
    String? jobType,
    CategorizedTools? toolsNeededCategorized,
    CategorizedTools? toolsUsedCategorized,
    List<HappySunToolUsage>? toolsNeeded,
    List<HappySunToolUsage>? toolsUsed,
    List<String>? teamMemberIds,
    DateTime? startTime,
    DateTime? endTime,
    String? notes,
    String? weatherConditions,
    List<String>? photoUrls,
    ChecklistData? checklistData,
    String? statusId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return HappySunJob(
      id: id ?? this.id,
      jobListItemId: jobListItemId ?? this.jobListItemId,
      date: date ?? this.date,
      jobType: jobType ?? this.jobType,
      toolsNeededCategorized:
          toolsNeededCategorized ?? this.toolsNeededCategorized,
      toolsUsedCategorized: toolsUsedCategorized ?? this.toolsUsedCategorized,
      toolsNeeded: toolsNeeded ?? this.toolsNeeded,
      toolsUsed: toolsUsed ?? this.toolsUsed,
      teamMemberIds: teamMemberIds ?? this.teamMemberIds,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      notes: notes ?? this.notes,
      weatherConditions: weatherConditions ?? this.weatherConditions,
      photoUrls: photoUrls ?? this.photoUrls,
      checklistData: checklistData ?? this.checklistData,
      statusId: statusId ?? this.statusId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // Helper getters
  Duration? get workDuration {
    if (startTime != null && endTime != null) {
      return endTime!.difference(startTime!);
    }
    return null;
  }

  int get totalToolsUsed =>
      toolsUsed.fold(0, (sum, tool) => sum + tool.quantity);

  bool get isWindowCleaning => jobType == 'windowCleaning';
  bool get isSolarPanelCleaning => jobType == 'solarPanelCleaning';
}
