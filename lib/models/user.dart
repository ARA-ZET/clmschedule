import 'package:cloud_firestore/cloud_firestore.dart';

/// User model representing a user in the CLM Schedule application
/// Contains user information and role-based access control
class User {
  final String userId;
  final String name;
  final String email;
  final UserRole role;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? photoUrl;
  final bool isActive;

  const User({
    required this.userId,
    required this.name,
    required this.email,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.photoUrl,
    this.isActive = true,
  });

  /// Create a copy of this user with updated fields
  User copyWith({
    String? userId,
    String? name,
    String? email,
    UserRole? role,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? photoUrl,
    bool? isActive,
  }) {
    return User(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      photoUrl: photoUrl ?? this.photoUrl,
      isActive: isActive ?? this.isActive,
    );
  }

  /// Convert User to JSON for Firestore storage
  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'email': email,
      'role': role.toString().split('.').last,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'photoUrl': photoUrl,
      'isActive': isActive,
    };
  }

  /// Create User from Firestore document
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['userId'] as String,
      name: json['name'] as String,
      email: json['email'] as String,
      role: UserRole.values.firstWhere(
        (role) => role.toString().split('.').last == json['role'],
        orElse: () => UserRole.user,
      ),
      createdAt: (json['createdAt'] as Timestamp).toDate(),
      updatedAt: (json['updatedAt'] as Timestamp).toDate(),
      photoUrl: json['photoUrl'] as String?,
      isActive: json['isActive'] as bool? ?? true,
    );
  }

  /// Create User from Firestore DocumentSnapshot
  factory User.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return User.fromJson(data);
  }

  /// Convert User to Firestore document data
  Map<String, dynamic> toFirestore() {
    return toJson();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is User &&
        other.userId == userId &&
        other.name == name &&
        other.email == email &&
        other.role == role &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        other.photoUrl == photoUrl &&
        other.isActive == isActive;
  }

  @override
  int get hashCode {
    return Object.hash(
      userId,
      name,
      email,
      role,
      createdAt,
      updatedAt,
      photoUrl,
      isActive,
    );
  }

  @override
  String toString() {
    return 'User(userId: $userId, name: $name, email: $email, role: $role, '
        'createdAt: $createdAt, updatedAt: $updatedAt, photoUrl: $photoUrl, '
        'isActive: $isActive)';
  }

  /// Get display name for UI
  String get displayName => name.isNotEmpty ? name : email.split('@').first;

  /// Get role display name
  String get roleDisplayName {
    switch (role) {
      case UserRole.admin:
        return 'Administrator';
      case UserRole.manager:
        return 'Manager';
      case UserRole.supervisor:
        return 'Supervisor';
      case UserRole.user:
        return 'User';
      case UserRole.viewer:
        return 'Viewer';
    }
  }

  /// Check if user has admin privileges
  bool get isAdmin => role == UserRole.admin;

  /// Check if user has management privileges
  bool get isManager => role == UserRole.admin || role == UserRole.manager;

  /// Check if user can edit schedules
  bool get canEdit =>
      role == UserRole.admin ||
      role == UserRole.manager ||
      role == UserRole.supervisor;

  /// Check if user can only view
  bool get isViewOnly => role == UserRole.viewer;
}

/// User roles for access control
enum UserRole {
  admin, // Full access to all features
  manager, // Can manage schedules and users
  supervisor, // Can edit schedules and jobs
  user, // Can view and add jobs
  viewer, // Can only view schedules
}

/// Extension methods for UserRole
extension UserRoleExtension on UserRole {
  /// Get role priority (higher number = more privileges)
  int get priority {
    switch (this) {
      case UserRole.admin:
        return 5;
      case UserRole.manager:
        return 4;
      case UserRole.supervisor:
        return 3;
      case UserRole.user:
        return 2;
      case UserRole.viewer:
        return 1;
    }
  }

  /// Get role color for UI
  String get colorHex {
    switch (this) {
      case UserRole.admin:
        return '#D32F2F'; // Red
      case UserRole.manager:
        return '#F57C00'; // Orange
      case UserRole.supervisor:
        return '#1976D2'; // Blue
      case UserRole.user:
        return '#388E3C'; // Green
      case UserRole.viewer:
        return '#616161'; // Grey
    }
  }

  /// Check if this role has higher or equal privileges than another role
  bool hasAccessLevelOf(UserRole other) {
    return priority >= other.priority;
  }
}
