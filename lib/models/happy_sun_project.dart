import 'package:cloud_firestore/cloud_firestore.dart';
import 'happy_sun_shared.dart'; // For CategorizedTools

/// Represents a tool checked out for a project
class CheckedOutTool {
  final String toolId;
  final String toolName;
  final String category;
  final int quantity;

  CheckedOutTool({
    required this.toolId,
    required this.toolName,
    required this.category,
    required this.quantity,
  });

  factory CheckedOutTool.fromMap(Map<String, dynamic> data) {
    return CheckedOutTool(
      toolId: data['toolId'] ?? '',
      toolName: data['toolName'] ?? '',
      category: data['category'] ?? 'General',
      quantity: data['quantity'] ?? 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'toolId': toolId,
      'toolName': toolName,
      'category': category,
      'quantity': quantity,
    };
  }
}

/// Represents the checkout phase when team leaves office
class ProjectCheckout {
  final DateTime? checkoutTime;
  final List<CheckedOutTool> tools;
  final String? notes;
  final String? checkedOutBy; // User ID who performed checkout

  ProjectCheckout({
    this.checkoutTime,
    this.tools = const [],
    this.notes,
    this.checkedOutBy,
  });

  factory ProjectCheckout.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return ProjectCheckout();
    }
    return ProjectCheckout(
      checkoutTime: (data['checkoutTime'] as Timestamp?)?.toDate(),
      tools: (data['tools'] as List<dynamic>?)
              ?.map((tool) =>
                  CheckedOutTool.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      notes: data['notes'],
      checkedOutBy: data['checkedOutBy'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'checkoutTime':
          checkoutTime != null ? Timestamp.fromDate(checkoutTime!) : null,
      'tools': tools.map((tool) => tool.toMap()).toList(),
      'notes': notes,
      'checkedOutBy': checkedOutBy,
    };
  }

  int get totalToolsCount => tools.fold(0, (sum, tool) => sum + tool.quantity);

  Map<String, int> get toolsByCategory {
    final Map<String, int> categoryCount = {};
    for (var tool in tools) {
      categoryCount[tool.category] =
          (categoryCount[tool.category] ?? 0) + tool.quantity;
    }
    return categoryCount;
  }
}

/// Represents a checklist item to verify on-site
class ChecklistItem {
  final String id;
  final String name;
  final bool isChecked;
  final String? notes;

  ChecklistItem({
    required this.id,
    required this.name,
    this.isChecked = false,
    this.notes,
  });

  factory ChecklistItem.fromMap(Map<String, dynamic> data) {
    return ChecklistItem(
      id: data['id'] ?? '',
      name: data['name'] ?? '',
      isChecked: data['isChecked'] ?? false,
      notes: data['notes'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'isChecked': isChecked,
      'notes': notes,
    };
  }

  ChecklistItem copyWith({
    String? id,
    String? name,
    bool? isChecked,
    String? notes,
  }) {
    return ChecklistItem(
      id: id ?? this.id,
      name: name ?? this.name,
      isChecked: isChecked ?? this.isChecked,
      notes: notes ?? this.notes,
    );
  }
}

/// Represents the checklist phase on-site
class ProjectChecklist {
  final DateTime? checklistTime;
  final List<ChecklistItem> items;
  final bool allItemsChecked;
  final String? notes;
  final String? checkedBy; // User ID who performed checklist

  ProjectChecklist({
    this.checklistTime,
    this.items = const [],
    this.allItemsChecked = false,
    this.notes,
    this.checkedBy,
  });

  factory ProjectChecklist.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return ProjectChecklist();
    }
    return ProjectChecklist(
      checklistTime: (data['checklistTime'] as Timestamp?)?.toDate(),
      items: (data['items'] as List<dynamic>?)
              ?.map(
                  (item) => ChecklistItem.fromMap(item as Map<String, dynamic>))
              .toList() ??
          [],
      allItemsChecked: data['allItemsChecked'] ?? false,
      notes: data['notes'],
      checkedBy: data['checkedBy'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'checklistTime':
          checklistTime != null ? Timestamp.fromDate(checklistTime!) : null,
      'items': items.map((item) => item.toMap()).toList(),
      'allItemsChecked': allItemsChecked,
      'notes': notes,
      'checkedBy': checkedBy,
    };
  }

  int get checkedItemsCount => items.where((item) => item.isChecked).length;
  int get totalItemsCount => items.length;
}

/// Represents the checkin phase when returning to office
class ProjectCheckin {
  final DateTime? checkinTime;
  final List<CheckedOutTool> returnedTools;
  final List<String> missingTools; // Tool IDs that weren't returned
  final String? notes;
  final String? checkedInBy; // User ID who performed checkin

  ProjectCheckin({
    this.checkinTime,
    this.returnedTools = const [],
    this.missingTools = const [],
    this.notes,
    this.checkedInBy,
  });

  factory ProjectCheckin.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return ProjectCheckin();
    }
    return ProjectCheckin(
      checkinTime: (data['checkinTime'] as Timestamp?)?.toDate(),
      returnedTools: (data['returnedTools'] as List<dynamic>?)
              ?.map((tool) =>
                  CheckedOutTool.fromMap(tool as Map<String, dynamic>))
              .toList() ??
          [],
      missingTools:
          (data['missingTools'] as List<dynamic>?)?.cast<String>() ?? [],
      notes: data['notes'],
      checkedInBy: data['checkedInBy'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'checkinTime':
          checkinTime != null ? Timestamp.fromDate(checkinTime!) : null,
      'returnedTools': returnedTools.map((tool) => tool.toMap()).toList(),
      'missingTools': missingTools,
      'notes': notes,
      'checkedInBy': checkedInBy,
    };
  }

  int get totalReturnedCount =>
      returnedTools.fold(0, (sum, tool) => sum + tool.quantity);
  bool get hasAllToolsReturned => missingTools.isEmpty;
}

/// Main project model for Happy Sun projects
/// Consolidated model combining job execution and project management
/// Stored in /happySunProjects/{YYYY-MM}/projects[] (monthly documents with array)
/// Synced with JobListItem by matching ID
class HappySunProject {
  final String id; // Same ID as JobListItem
  final String jobListItemId; // Reference to jobList item
  final String clientName;
  final String address;
  final DateTime scheduledDate;
  final String? scheduledTime;
  final int numberOfTeamMembers;
  final String status; // 'pending', 'in-progress', 'completed'
  final DateTime createdAt;
  final DateTime? updatedAt;

  // Job type from JobListItem
  final String jobType; // 'windowCleaning' or 'solarPanelCleaning'

  // Tools needed for the project (preparation list)
  final CategorizedTools? toolsNeeded;

  // Tools actually used during execution (from HappySunJob)
  final CategorizedTools? toolsUsedCategorized;

  // Team member IDs for actual execution
  final List<String> teamMemberIds;

  // Time tracking for job execution
  final DateTime? startTime;
  final DateTime? endTime;

  // Notes and observations from job execution
  final String? notes;
  final String? weatherConditions;
  final List<String>? photoUrls; // Legacy field
  final List<String>? beforeImages; // Images before job
  final List<String>? afterImages; // Images after job completion

  // Checklist data from job execution
  final ChecklistData? checklistData;

  // Status sync with JobListItem
  final String statusId; // Synced from JobListItem

  // Three phases for tool management
  final ProjectCheckout? checkout;
  final ProjectChecklist? checklist;
  final ProjectCheckin? checkin;

  HappySunProject({
    required this.id,
    required this.jobListItemId,
    required this.clientName,
    required this.address,
    required this.scheduledDate,
    this.scheduledTime,
    required this.numberOfTeamMembers,
    this.status = 'pending',
    required this.createdAt,
    this.updatedAt,
    required this.jobType,
    this.toolsNeeded,
    this.toolsUsedCategorized,
    this.teamMemberIds = const [],
    this.startTime,
    this.endTime,
    this.notes,
    this.weatherConditions,
    this.photoUrls,
    this.beforeImages,
    this.afterImages,
    this.checklistData,
    required this.statusId,
    this.checkout,
    this.checklist,
    this.checkin,
  });

  // Helper to parse DateTime from either Timestamp or String
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  factory HappySunProject.fromMap(String id, Map<String, dynamic> data) {
    return HappySunProject(
      id: id,
      jobListItemId: data['jobListItemId'] ?? id,
      clientName: data['clientName'] ?? '',
      address: data['address'] ?? '',
      scheduledDate:
          (data['scheduledDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      scheduledTime: data['scheduledTime'],
      numberOfTeamMembers: data['numberOfTeamMembers'] ?? 1,
      status: data['status'] ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: _parseDateTime(data['updatedAt']),
      jobType: data['jobType'] ?? 'windowCleaning',
      toolsNeeded: data['toolsNeeded'] != null
          ? CategorizedTools.fromMap(
              data['toolsNeeded'] as Map<String, dynamic>)
          : null,
      toolsUsedCategorized: data['toolsUsedCategorized'] != null
          ? CategorizedTools.fromMap(
              data['toolsUsedCategorized'] as Map<String, dynamic>)
          : null,
      teamMemberIds:
          (data['teamMemberIds'] as List<dynamic>?)?.cast<String>() ?? [],
      startTime: (data['startTime'] as Timestamp?)?.toDate(),
      endTime: (data['endTime'] as Timestamp?)?.toDate(),
      notes: data['notes'],
      weatherConditions: data['weatherConditions'],
      photoUrls: (data['photoUrls'] as List<dynamic>?)?.cast<String>(),
      beforeImages: (data['beforeImages'] as List<dynamic>?)?.cast<String>(),
      afterImages: (data['afterImages'] as List<dynamic>?)?.cast<String>(),
      checklistData: data['checklistData'] != null
          ? ChecklistData.fromMap(data['checklistData'] as Map<String, dynamic>)
          : null,
      statusId: data['statusId'] ?? data['status'] ?? 'scheduled',
      checkout:
          ProjectCheckout.fromMap(data['checkout'] as Map<String, dynamic>?),
      checklist:
          ProjectChecklist.fromMap(data['checklist'] as Map<String, dynamic>?),
      checkin: ProjectCheckin.fromMap(data['checkin'] as Map<String, dynamic>?),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id, // Include for compatibility
      'jobListItemId': jobListItemId,
      'clientName': clientName,
      'address': address,
      'scheduledDate': Timestamp.fromDate(scheduledDate),
      'scheduledTime': scheduledTime,
      'numberOfTeamMembers': numberOfTeamMembers,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'jobType': jobType,
      'toolsNeeded': toolsNeeded?.toMap(),
      'toolsUsedCategorized': toolsUsedCategorized?.toMap(),
      'teamMemberIds': teamMemberIds,
      'startTime': startTime != null ? Timestamp.fromDate(startTime!) : null,
      'endTime': endTime != null ? Timestamp.fromDate(endTime!) : null,
      'notes': notes,
      'weatherConditions': weatherConditions,
      'photoUrls': photoUrls,
      'beforeImages': beforeImages,
      'afterImages': afterImages,
      'checklistData': checklistData?.toMap(),
      'statusId': statusId,
      'checkout': checkout?.toMap(),
      'checklist': checklist?.toMap(),
      'checkin': checkin?.toMap(),
    };
  }

  HappySunProject copyWith({
    String? id,
    String? jobListItemId,
    String? clientName,
    String? address,
    DateTime? scheduledDate,
    String? scheduledTime,
    int? numberOfTeamMembers,
    String? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? jobType,
    CategorizedTools? toolsNeeded,
    CategorizedTools? toolsUsedCategorized,
    List<String>? teamMemberIds,
    DateTime? startTime,
    DateTime? endTime,
    String? notes,
    String? weatherConditions,
    List<String>? photoUrls,
    List<String>? beforeImages,
    List<String>? afterImages,
    ChecklistData? checklistData,
    String? statusId,
    ProjectCheckout? checkout,
    ProjectChecklist? checklist,
    ProjectCheckin? checkin,
  }) {
    return HappySunProject(
      id: id ?? this.id,
      jobListItemId: jobListItemId ?? this.jobListItemId,
      clientName: clientName ?? this.clientName,
      address: address ?? this.address,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      numberOfTeamMembers: numberOfTeamMembers ?? this.numberOfTeamMembers,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      jobType: jobType ?? this.jobType,
      toolsNeeded: toolsNeeded ?? this.toolsNeeded,
      toolsUsedCategorized: toolsUsedCategorized ?? this.toolsUsedCategorized,
      teamMemberIds: teamMemberIds ?? this.teamMemberIds,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      notes: notes ?? this.notes,
      weatherConditions: weatherConditions ?? this.weatherConditions,
      photoUrls: photoUrls ?? this.photoUrls,
      beforeImages: beforeImages ?? this.beforeImages,
      afterImages: afterImages ?? this.afterImages,
      checklistData: checklistData ?? this.checklistData,
      statusId: statusId ?? this.statusId,
      checkout: checkout ?? this.checkout,
      checklist: checklist ?? this.checklist,
      checkin: checkin ?? this.checkin,
    );
  }

  // Helper getters for project phases
  bool get hasCheckout => checkout != null && checkout!.checkoutTime != null;
  bool get hasChecklist =>
      checklist != null && checklist!.checklistTime != null;
  bool get hasCheckin => checkin != null && checkin!.checkinTime != null;

  // Helper getters from job execution
  Duration? get workDuration {
    if (startTime != null && endTime != null) {
      return endTime!.difference(startTime!);
    }
    return null;
  }

  bool get isWindowCleaning => jobType == 'windowCleaning';
  bool get isSolarPanelCleaning => jobType == 'solarPanelCleaning';

  int get totalToolsUsed {
    if (toolsUsedCategorized != null) {
      return toolsUsedCategorized!.totalCount;
    }
    return 0;
  }
}
