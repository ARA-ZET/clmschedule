import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/user_service.dart';
import '../models/user.dart' as app_user;

/// Simple authentication user model
class AuthUser {
  final String uid;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final bool emailVerified;
  final DateTime createdAt;
  final DateTime lastSignInAt;

  AuthUser({
    required this.uid,
    required this.email,
    this.displayName,
    this.photoUrl,
    this.emailVerified = false,
    required this.createdAt,
    required this.lastSignInAt,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      uid: json['localId'] ?? json['uid'] ?? '',
      email: json['email'] ?? '',
      displayName: json['displayName'],
      photoUrl: json['photoUrl'],
      emailVerified: json['emailVerified'] ?? false,
      createdAt:
          DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
      lastSignInAt: DateTime.parse(
          json['lastSignInAt'] ?? DateTime.now().toIso8601String()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'emailVerified': emailVerified,
      'createdAt': createdAt.toIso8601String(),
      'lastSignInAt': lastSignInAt.toIso8601String(),
    };
  }
}

/// Custom authentication service using email/password
/// Avoids Firebase Auth Web compatibility issues
class SimpleAuthService {
  static final SimpleAuthService _instance = SimpleAuthService._internal();
  factory SimpleAuthService() => _instance;
  SimpleAuthService._internal();

  final StreamController<AuthUser?> _authStateController =
      StreamController<AuthUser?>.broadcast();
  AuthUser? _currentUser;
  late final UserService _userService;

  // For demo purposes - in production, use Firebase Auth REST API or custom backend
  static const Map<String, Map<String, dynamic>> _demoUsers = {
    'admin@clmschedule.com': {
      'password': 'admin123',
      'name': 'Admin User',
      'role': 'admin',
    },
    'manager@clmschedule.com': {
      'password': 'manager123',
      'name': 'Manager User',
      'role': 'manager',
    },
    'user@clmschedule.com': {
      'password': 'user123',
      'name': 'Regular User',
      'role': 'user',
    },
  };

  /// Get the current authenticated user
  AuthUser? get currentUser => _currentUser;

  /// Check if user is currently authenticated
  bool get isAuthenticated => _currentUser != null;

  /// Stream of authentication state changes
  Stream<AuthUser?> get authStateChanges => _authStateController.stream;

  /// Initialize authentication service
  Future<void> initialize() async {
    try {
      _userService = UserService(FirebaseFirestore.instance);

      // Check for persisted session
      final persistedUser = _getPersistedUser();
      if (persistedUser != null) {
        _currentUser = persistedUser;
        _authStateController.add(_currentUser);
      }

      debugPrint(
          'SimpleAuthService initialized. Current user: ${_currentUser?.email ?? 'None'}');
    } catch (e) {
      debugPrint('Error initializing SimpleAuthService: $e');
    }
  }

  /// Sign in with email and password
  Future<AuthUser?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      debugPrint('Attempting sign in: $email');

      // Validate email format
      if (!_isValidEmail(email)) {
        throw Exception('Please enter a valid email address.');
      }

      // For demo - check against demo users
      // In production, this would call Firebase Auth REST API or your backend
      final userInfo = _demoUsers[email.toLowerCase()];
      if (userInfo == null) {
        throw Exception('No user found with this email address.');
      }

      if (userInfo['password'] != password) {
        throw Exception('Incorrect password. Please try again.');
      }

      // Create auth user
      final now = DateTime.now();
      _currentUser = AuthUser(
        uid: email.hashCode.toString(),
        email: email,
        displayName: userInfo['name'] as String,
        emailVerified: true,
        createdAt: now,
        lastSignInAt: now,
      );

      // Persist session
      _persistUser(_currentUser!);

      // Create or update user in database
      await _createOrUpdateUserInDatabase(
          _currentUser!, userInfo['role'] as String);

      // Notify listeners
      _authStateController.add(_currentUser);

      debugPrint('Sign in successful: $email');
      return _currentUser;
    } catch (e) {
      debugPrint('Sign in error: $e');
      rethrow;
    }
  }

  /// Create new user account with email and password
  Future<AuthUser?> createUserWithEmailAndPassword({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      debugPrint('Attempting account creation: $email');

      // Validate inputs
      if (!_isValidEmail(email)) {
        throw Exception('Please enter a valid email address.');
      }

      if (password.length < 6) {
        throw Exception('Password must be at least 6 characters long.');
      }

      // Check if user already exists (in demo users or custom storage)
      if (_demoUsers.containsKey(email.toLowerCase())) {
        throw Exception('An account already exists with this email address.');
      }

      // In production, this would call Firebase Auth REST API to create the user
      // For now, we'll create a new user entry
      final now = DateTime.now();
      _currentUser = AuthUser(
        uid: email.hashCode.toString(),
        email: email,
        displayName: displayName ?? email.split('@').first,
        emailVerified: true,
        createdAt: now,
        lastSignInAt: now,
      );

      // Persist session
      _persistUser(_currentUser!);

      // Create user in database with default role
      await _createOrUpdateUserInDatabase(_currentUser!, 'user');

      // Notify listeners
      _authStateController.add(_currentUser);

      debugPrint('Account creation successful: $email');
      return _currentUser;
    } catch (e) {
      debugPrint('Account creation error: $e');
      rethrow;
    }
  }

  /// Send password reset email (mock implementation)
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      if (!_isValidEmail(email)) {
        throw Exception('Please enter a valid email address.');
      }

      // In production, this would call Firebase Auth REST API
      // For demo, just simulate success
      await Future.delayed(const Duration(milliseconds: 500));

      debugPrint('Password reset email sent to: $email');
    } catch (e) {
      debugPrint('Password reset error: $e');
      rethrow;
    }
  }

  /// Sign out the current user
  Future<void> signOut() async {
    try {
      _currentUser = null;
      _clearPersistedUser();
      _authStateController.add(null);

      debugPrint('User signed out successfully');
    } catch (e) {
      debugPrint('Error signing out: $e');
      throw Exception('Error signing out. Please try again.');
    }
  }

  /// Update user display name
  Future<void> updateDisplayName(String displayName) async {
    if (_currentUser == null) {
      throw Exception('No user is currently signed in');
    }

    try {
      _currentUser = AuthUser(
        uid: _currentUser!.uid,
        email: _currentUser!.email,
        displayName: displayName,
        photoUrl: _currentUser!.photoUrl,
        emailVerified: _currentUser!.emailVerified,
        createdAt: _currentUser!.createdAt,
        lastSignInAt: _currentUser!.lastSignInAt,
      );

      // Persist updated user
      _persistUser(_currentUser!);

      // Update in database
      await _createOrUpdateUserInDatabase(_currentUser!, null);

      // Notify listeners
      _authStateController.add(_currentUser);

      debugPrint('Display name updated to: $displayName');
    } catch (e) {
      debugPrint('Error updating display name: $e');
      throw Exception('Error updating display name.');
    }
  }

  /// Delete current user account
  Future<void> deleteAccount() async {
    if (_currentUser == null) {
      throw Exception('No user is currently signed in');
    }

    try {
      final userId = _currentUser!.uid;

      // Delete from database
      await _userService.deleteUser(userId);

      // Clear session
      _currentUser = null;
      _clearPersistedUser();
      _authStateController.add(null);

      debugPrint('User account deleted');
    } catch (e) {
      debugPrint('Error deleting account: $e');
      throw Exception('Error deleting account.');
    }
  }

  /// Create or update user in Firestore database
  Future<void> _createOrUpdateUserInDatabase(
      AuthUser authUser, String? role) async {
    try {
      final userRole = _getRoleFromString(role ?? 'user');

      final user = await _userService.createOrUpdateUser(
        userId: authUser.uid,
        email: authUser.email,
        name: authUser.displayName ?? authUser.email.split('@').first,
        photoUrl: authUser.photoUrl,
        role: userRole,
      );

      debugPrint('User created/updated in database: ${user.email}');
    } catch (e) {
      debugPrint('Error creating user in database: $e');
      // Don't throw error - auth should still work even if database fails
    }
  }

  /// Convert role string to UserRole enum
  app_user.UserRole _getRoleFromString(String roleString) {
    switch (roleString.toLowerCase()) {
      case 'admin':
        return app_user.UserRole.admin;
      case 'manager':
        return app_user.UserRole.manager;
      case 'supervisor':
        return app_user.UserRole.supervisor;
      case 'viewer':
        return app_user.UserRole.viewer;
      default:
        return app_user.UserRole.user;
    }
  }

  /// Get current user from database
  Future<app_user.User?> getCurrentUserFromDatabase() async {
    final authUser = currentUser;
    if (authUser == null) return null;

    try {
      return await _userService.getUserById(authUser.uid);
    } catch (e) {
      debugPrint('Error getting user from database: $e');
      return null;
    }
  }

  /// Validate email format
  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
  }

  /// Persist user session (simple implementation)
  void _persistUser(AuthUser user) {
    // In production, use secure storage
    // For demo, this is a placeholder
    debugPrint('Persisting user session: ${user.email}');
  }

  /// Get persisted user session
  AuthUser? _getPersistedUser() {
    // In production, read from secure storage
    // For demo, return null (no persistence)
    return null;
  }

  /// Clear persisted user session
  void _clearPersistedUser() {
    debugPrint('Clearing persisted user session');
  }

  /// Get user info as a map
  Map<String, dynamic> getUserInfo() {
    final user = currentUser;
    if (user == null) return {'authenticated': false};

    return {
      'authenticated': true,
      'uid': user.uid,
      'email': user.email,
      'displayName': user.displayName,
      'photoUrl': user.photoUrl,
      'emailVerified': user.emailVerified,
      'createdAt': user.createdAt.toIso8601String(),
      'lastSignInAt': user.lastSignInAt.toIso8601String(),
    };
  }

  /// Get demo accounts for testing
  static Map<String, String> get demoAccounts {
    return _demoUsers
        .map((email, info) => MapEntry(email, info['password'] as String));
  }
}
