import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/user.dart';

/// Service for managing user data in Firestore
/// Handles CRUD operations for user accounts and role management
class UserService {
  static const String _collection = 'users';
  final FirebaseFirestore _firestore;

  UserService(this._firestore);

  /// Get collection reference
  CollectionReference<Map<String, dynamic>> get _usersCollection =>
      _firestore.collection(_collection);

  /// Create a new user in the database
  Future<void> createUser(User user) async {
    try {
      await _usersCollection.doc(user.userId).set(user.toFirestore());
      debugPrint('User created successfully: ${user.email}');
    } catch (e) {
      debugPrint('Error creating user: $e');
      throw Exception('Failed to create user: $e');
    }
  }

  /// Get user by ID
  Future<User?> getUserById(String userId) async {
    try {
      final doc = await _usersCollection.doc(userId).get();
      if (doc.exists) {
        return User.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      debugPrint('Error getting user by ID: $e');
      throw Exception('Failed to get user: $e');
    }
  }

  /// Get user by email
  Future<User?> getUserByEmail(String email) async {
    try {
      final query = await _usersCollection
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        return User.fromFirestore(query.docs.first);
      }
      return null;
    } catch (e) {
      debugPrint('Error getting user by email: $e');
      throw Exception('Failed to get user: $e');
    }
  }

  /// Update existing user
  Future<void> updateUser(User user) async {
    try {
      final updatedUser = user.copyWith(updatedAt: DateTime.now());
      await _usersCollection.doc(user.userId).update(updatedUser.toFirestore());
      debugPrint('User updated successfully: ${user.email}');
    } catch (e) {
      debugPrint('Error updating user: $e');
      throw Exception('Failed to update user: $e');
    }
  }

  /// Delete user (soft delete by setting isActive to false)
  Future<void> deleteUser(String userId) async {
    try {
      await _usersCollection.doc(userId).update({
        'isActive': false,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
      debugPrint('User soft deleted: $userId');
    } catch (e) {
      debugPrint('Error deleting user: $e');
      throw Exception('Failed to delete user: $e');
    }
  }

  /// Permanently delete user (hard delete)
  Future<void> permanentlyDeleteUser(String userId) async {
    try {
      await _usersCollection.doc(userId).delete();
      debugPrint('User permanently deleted: $userId');
    } catch (e) {
      debugPrint('Error permanently deleting user: $e');
      throw Exception('Failed to permanently delete user: $e');
    }
  }

  /// Get all active users
  Future<List<User>> getAllUsers({bool includeInactive = false}) async {
    try {
      Query query = _usersCollection.orderBy('name');

      if (!includeInactive) {
        query = query.where('isActive', isEqualTo: true);
      }

      final snapshot = await query.get();
      return snapshot.docs.map((doc) => User.fromFirestore(doc)).toList();
    } catch (e) {
      debugPrint('Error getting all users: $e');
      throw Exception('Failed to get users: $e');
    }
  }

  /// Get users by role
  Future<List<User>> getUsersByRole(UserRole role) async {
    try {
      final snapshot = await _usersCollection
          .where('role', isEqualTo: role.toString().split('.').last)
          .where('isActive', isEqualTo: true)
          .orderBy('name')
          .get();

      return snapshot.docs.map((doc) => User.fromFirestore(doc)).toList();
    } catch (e) {
      debugPrint('Error getting users by role: $e');
      throw Exception('Failed to get users by role: $e');
    }
  }

  /// Update user role (admin only operation)
  Future<void> updateUserRole(String userId, UserRole newRole) async {
    try {
      await _usersCollection.doc(userId).update({
        'role': newRole.toString().split('.').last,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
      debugPrint('User role updated: $userId to $newRole');
    } catch (e) {
      debugPrint('Error updating user role: $e');
      throw Exception('Failed to update user role: $e');
    }
  }

  /// Check if user exists
  Future<bool> userExists(String userId) async {
    try {
      final doc = await _usersCollection.doc(userId).get();
      return doc.exists;
    } catch (e) {
      debugPrint('Error checking if user exists: $e');
      return false;
    }
  }

  /// Check if email is already taken
  Future<bool> emailExists(String email) async {
    try {
      final user = await getUserByEmail(email);
      return user != null;
    } catch (e) {
      debugPrint('Error checking if email exists: $e');
      return false;
    }
  }

  /// Create user or update if exists (for OAuth sign-ins)
  Future<User> createOrUpdateUser({
    required String userId,
    required String email,
    required String name,
    String? photoUrl,
    UserRole? role,
  }) async {
    try {
      final existingUser = await getUserById(userId);
      final now = DateTime.now();

      if (existingUser != null) {
        // Update existing user with latest info
        final updatedUser = existingUser.copyWith(
          name: name.isNotEmpty ? name : existingUser.name,
          email: email,
          photoUrl: photoUrl ?? existingUser.photoUrl,
          updatedAt: now,
          isActive: true, // Reactivate if was inactive
        );

        await updateUser(updatedUser);
        debugPrint('Existing user updated: $email');
        return updatedUser;
      } else {
        // Create new user
        final newUser = User(
          userId: userId,
          name: name.isNotEmpty ? name : email.split('@').first,
          email: email,
          role: role ?? UserRole.user, // Default role for new users
          photoUrl: photoUrl,
          createdAt: now,
          updatedAt: now,
          isActive: true,
        );

        await createUser(newUser);
        debugPrint('New user created: $email');
        return newUser;
      }
    } catch (e) {
      debugPrint('Error creating or updating user: $e');
      throw Exception('Failed to create or update user: $e');
    }
  }

  /// Get user statistics
  Future<Map<String, dynamic>> getUserStats() async {
    try {
      final allUsers = await getAllUsers(includeInactive: true);
      final activeUsers = allUsers.where((user) => user.isActive).toList();

      final roleStats = <String, int>{};
      for (final role in UserRole.values) {
        roleStats[role.toString().split('.').last] =
            activeUsers.where((user) => user.role == role).length;
      }

      return {
        'totalUsers': allUsers.length,
        'activeUsers': activeUsers.length,
        'inactiveUsers': allUsers.length - activeUsers.length,
        'roleStats': roleStats,
        'latestUser': allUsers.isNotEmpty
            ? allUsers
                .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b)
            : null,
      };
    } catch (e) {
      debugPrint('Error getting user stats: $e');
      throw Exception('Failed to get user statistics: $e');
    }
  }

  /// Stream of all users (real-time updates)
  Stream<List<User>> getUsersStream({bool includeInactive = false}) {
    try {
      Query query = _usersCollection.orderBy('name');

      if (!includeInactive) {
        query = query.where('isActive', isEqualTo: true);
      }

      return query.snapshots().map((snapshot) {
        return snapshot.docs.map((doc) => User.fromFirestore(doc)).toList();
      });
    } catch (e) {
      debugPrint('Error getting users stream: $e');
      throw Exception('Failed to get users stream: $e');
    }
  }

  /// Stream of specific user (real-time updates)
  Stream<User?> getUserStream(String userId) {
    try {
      return _usersCollection.doc(userId).snapshots().map((doc) {
        if (doc.exists) {
          return User.fromFirestore(doc);
        }
        return null;
      });
    } catch (e) {
      debugPrint('Error getting user stream: $e');
      throw Exception('Failed to get user stream: $e');
    }
  }
}
