import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/user_service.dart';
import '../models/user.dart' as app_user;

/// Real Firebase Authentication service
/// Uses Firebase Auth to create users in Firebase Auth console
/// Handles web compatibility issues with proper error handling
class FirebaseAuthService {
  static final FirebaseAuthService _instance = FirebaseAuthService._internal();
  factory FirebaseAuthService() => _instance;
  FirebaseAuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  late final UserService _userService;

  // Demo accounts for testing
  static const Map<String, String> demoAccounts = {
    'admin@clm.com': 'admin123',
    'manager@clm.com': 'manager123',
    'supervisor@clm.com': 'supervisor123',
    'user@clm.com': 'user123',
    'viewer@clm.com': 'viewer123',
  };

  /// Get the current authenticated user
  User? get currentUser => _auth.currentUser;

  /// Check if user is currently authenticated
  bool get isAuthenticated => _auth.currentUser != null;

  /// Stream of authentication state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Initialize authentication service and set up persistence
  Future<void> initialize() async {
    try {
      // Initialize UserService
      _userService = UserService(FirebaseFirestore.instance);

      // For web platforms, set persistence to LOCAL to maintain login across browser sessions
      if (kIsWeb) {
        try {
          await _auth.setPersistence(Persistence.LOCAL);
        } catch (e) {
          debugPrint('Web persistence setup failed (non-critical): $e');
          // Continue even if persistence setup fails
        }
      }

      debugPrint(
          'FirebaseAuthService initialized. Current user: ${currentUser?.email ?? 'None'}');
    } catch (e) {
      debugPrint('Error initializing FirebaseAuthService: $e');
    }
  }

  /// Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      debugPrint('Attempting Firebase Auth sign in: $email');

      final UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      // Create or update user in database
      if (result.user != null) {
        await _createOrUpdateUserInDatabase(result.user!);
      }

      debugPrint('Firebase Auth sign in successful: ${result.user?.email}');
      return result;
    } on FirebaseAuthException catch (e) {
      debugPrint('FirebaseAuth error: ${e.code} - ${e.message}');
      throw _handleAuthException(e);
    } catch (e) {
      debugPrint('Unexpected error during sign in: $e');
      throw Exception('An unexpected error occurred. Please try again.');
    }
  }

  /// Create new user account with email and password
  Future<UserCredential?> createUserWithEmailAndPassword({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      debugPrint('Attempting Firebase Auth account creation: $email');

      final UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      // Update display name if provided
      if (displayName != null &&
          displayName.isNotEmpty &&
          result.user != null) {
        try {
          await result.user!.updateDisplayName(displayName);
          await result.user!.reload();
        } catch (e) {
          debugPrint('Failed to update display name: $e');
          // Continue even if display name update fails
        }
      }

      // Create user in database
      if (result.user != null) {
        await _createOrUpdateUserInDatabase(
          result.user!,
          displayName: displayName,
        );
      }

      debugPrint(
          'Firebase Auth account creation successful: ${result.user?.email}');
      return result;
    } on FirebaseAuthException catch (e) {
      debugPrint('FirebaseAuth error: ${e.code} - ${e.message}');
      throw _handleAuthException(e);
    } catch (e) {
      debugPrint('Unexpected error during account creation: $e');
      throw Exception('An unexpected error occurred. Please try again.');
    }
  }

  /// Send password reset email
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      debugPrint('Password reset email sent to: $email');
    } on FirebaseAuthException catch (e) {
      debugPrint(
          'Error sending password reset email: ${e.code} - ${e.message}');
      throw _handleAuthException(e);
    } catch (e) {
      debugPrint('Unexpected error sending password reset email: $e');
      throw Exception('An unexpected error occurred. Please try again.');
    }
  }

  /// Sign out the current user
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      debugPrint('Firebase Auth sign out successful');
    } catch (e) {
      debugPrint('Error signing out: $e');
      throw Exception('Error signing out. Please try again.');
    }
  }

  /// Update user display name
  Future<void> updateDisplayName(String displayName) async {
    try {
      await currentUser?.updateDisplayName(displayName);
      await currentUser?.reload();

      // Update in database as well
      if (currentUser != null) {
        await _createOrUpdateUserInDatabase(
          currentUser!,
          displayName: displayName,
        );
      }

      debugPrint('Display name updated to: $displayName');
    } catch (e) {
      debugPrint('Error updating display name: $e');
      throw Exception('Error updating display name.');
    }
  }

  /// Delete current user account
  Future<void> deleteAccount() async {
    try {
      final userId = currentUser?.uid;

      // Soft delete from database first
      if (userId != null) {
        await _userService.deleteUser(userId);
      }

      // Delete from Firebase Auth
      await currentUser?.delete();

      debugPrint('Firebase Auth account deleted');
    } on FirebaseAuthException catch (e) {
      debugPrint('Error deleting account: ${e.code} - ${e.message}');
      throw _handleAuthException(e);
    } catch (e) {
      debugPrint('Unexpected error deleting account: $e');
      throw Exception('An unexpected error occurred. Please try again.');
    }
  }

  /// Create or update user in Firestore database
  Future<void> _createOrUpdateUserInDatabase(
    User firebaseUser, {
    String? displayName,
    String? photoUrl,
  }) async {
    try {
      final user = await _userService.createOrUpdateUser(
        userId: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        name: displayName ??
            firebaseUser.displayName ??
            firebaseUser.email?.split('@').first ??
            'User',
        photoUrl: photoUrl ?? firebaseUser.photoURL,
        role: _getDefaultRole(firebaseUser.email ?? ''),
      );
      debugPrint('User created/updated in database: ${user.email}');
    } catch (e) {
      debugPrint('Error creating user in database: $e');
      // Don't throw error - auth should still work even if database fails
    }
  }

  /// Get default role based on email
  app_user.UserRole _getDefaultRole(String email) {
    if (email.contains('admin')) {
      return app_user.UserRole.admin;
    } else if (email.contains('manager')) {
      return app_user.UserRole.manager;
    } else {
      return app_user.UserRole.user;
    }
  }

  /// Get current user from database
  Future<app_user.User?> getCurrentUserFromDatabase() async {
    final firebaseUser = currentUser;
    if (firebaseUser == null) return null;

    try {
      return await _userService.getUserById(firebaseUser.uid);
    } catch (e) {
      debugPrint('Error getting user from database: $e');
      return null;
    }
  }

  /// Handle Firebase Auth exceptions and return user-friendly error messages
  Exception _handleAuthException(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return Exception('No user found with this email address.');
      case 'wrong-password':
        return Exception('Incorrect password. Please try again.');
      case 'email-already-in-use':
        return Exception('An account already exists with this email address.');
      case 'weak-password':
        return Exception(
            'Password is too weak. Please choose a stronger password.');
      case 'invalid-email':
        return Exception('Please enter a valid email address.');
      case 'user-disabled':
        return Exception(
            'This account has been disabled. Please contact support.');
      case 'too-many-requests':
        return Exception('Too many failed attempts. Please try again later.');
      case 'operation-not-allowed':
        return Exception(
            'This sign-in method is not enabled. Please contact support.');
      case 'network-request-failed':
        return Exception(
            'Network error. Please check your internet connection.');
      case 'requires-recent-login':
        return Exception(
            'Please sign out and sign back in to perform this action.');
      case 'invalid-credential':
        return Exception('The provided credentials are invalid.');
      case 'credential-already-in-use':
        return Exception(
            'This credential is already associated with a different user account.');
      default:
        return Exception(
            'Authentication error: ${e.message ?? 'Unknown error'}');
    }
  }

  /// Get user info as a map (useful for debugging or logging)
  Map<String, dynamic> getUserInfo() {
    final user = currentUser;
    if (user == null) return {'authenticated': false};

    return {
      'authenticated': true,
      'uid': user.uid,
      'email': user.email,
      'displayName': user.displayName,
      'photoURL': user.photoURL,
      'emailVerified': user.emailVerified,
      'creationTime': user.metadata.creationTime?.toIso8601String(),
      'lastSignInTime': user.metadata.lastSignInTime?.toIso8601String(),
      'providerData': user.providerData
          .map((info) => {
                'providerId': info.providerId,
                'uid': info.uid,
                'displayName': info.displayName,
                'email': info.email,
                'photoURL': info.photoURL,
              })
          .toList(),
    };
  }
}
