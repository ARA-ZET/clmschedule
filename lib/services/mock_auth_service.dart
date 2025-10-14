import 'dart:async';
import 'package:flutter/foundation.dart';
// import 'package:google_sign_in/google_sign_in.dart'; // Removed - not using Google Sign-In
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user.dart' as app_user;
import '../services/user_service.dart';

/// Mock authentication service for testing purposes
/// This demonstrates the authentication flow without Firebase Auth dependencies
class MockUser {
  final String uid;
  final String email;
  final String? displayName;
  final DateTime creationTime;
  final DateTime lastSignInTime;
  final bool emailVerified;
  final String? photoUrl;

  MockUser({
    required this.uid,
    required this.email,
    this.displayName,
    required this.creationTime,
    required this.lastSignInTime,
    this.emailVerified = true,
    this.photoUrl,
  });
}

class MockAuthService {
  static final MockAuthService _instance = MockAuthService._internal();
  factory MockAuthService() => _instance;
  MockAuthService._internal();

  MockUser? _currentUser;
  final StreamController<MockUser?> _authStateController =
      StreamController<MockUser?>.broadcast();

  // Services
  late final UserService _userService;
  // late final GoogleSignIn _googleSignIn; // Removed - not using Google Sign-In

  // Demo accounts
  static const Map<String, String> _demoAccounts = {
    'demo@clmschedule.com': 'password123',
    'admin@clmschedule.com': 'admin123',
    'user@test.com': 'test123',
  };

  // Mock Google accounts for demo
  static const Map<String, Map<String, String>> _mockGoogleAccounts = {
    'john.doe@gmail.com': {
      'name': 'John Doe',
      'photoUrl': 'https://lh3.googleusercontent.com/a/default-user=s96-c',
    },
    'jane.smith@gmail.com': {
      'name': 'Jane Smith',
      'photoUrl': 'https://lh3.googleusercontent.com/a/default-user=s96-c',
    },
    'admin@company.com': {
      'name': 'Admin User',
      'photoUrl': 'https://lh3.googleusercontent.com/a/default-user=s96-c',
    },
  };

  /// Get the current authenticated user
  MockUser? get currentUser => _currentUser;

  /// Check if user is currently authenticated
  bool get isAuthenticated => _currentUser != null;

  /// Stream of authentication state changes
  Stream<MockUser?> get authStateChanges => _authStateController.stream;

  /// Initialize service and restore persisted session
  Future<void> initialize() async {
    debugPrint('MockAuthService initializing...');

    // Initialize services
    _userService = UserService(FirebaseFirestore.instance);
    // _googleSignIn = GoogleSignIn(
    //   scopes: ['email', 'profile'],
    // ); // Removed - not using Google Sign-In

    // Simulate checking for persisted user session
    final persistedEmail = _getStoredEmail();
    if (persistedEmail != null && _demoAccounts.containsKey(persistedEmail)) {
      _currentUser = _createUser(persistedEmail);
      _authStateController.add(_currentUser);
    }

    debugPrint(
        'MockAuthService initialized. Current user: ${_currentUser?.email ?? 'None'}');
  }

  /// Sign in with email and password
  Future<MockUser?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    debugPrint('Attempting sign in: $email');

    if (!_demoAccounts.containsKey(email)) {
      throw Exception('No user found with this email address.');
    }

    if (_demoAccounts[email] != password) {
      throw Exception('Incorrect password. Please try again.');
    }

    _currentUser = _createUser(email);

    // Create user in database
    await _createUserInDatabase(_currentUser!);

    _authStateController.add(_currentUser);
    _storeEmail(email); // Simulate persistence

    debugPrint('User signed in: $email');
    return _currentUser;
  }

  /// Create new user account with email and password
  Future<MockUser?> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    debugPrint('Attempting account creation: $email');

    if (_demoAccounts.containsKey(email)) {
      throw Exception('An account already exists with this email address.');
    }

    if (password.length < 6) {
      throw Exception(
          'Password is too weak. Please choose a stronger password.');
    }

    // In a real app, this would create the account in the backend
    _currentUser = _createUser(email);

    // Create user in database
    await _createUserInDatabase(_currentUser!);

    _authStateController.add(_currentUser);
    _storeEmail(email); // Simulate persistence

    debugPrint('User account created: $email');
    return _currentUser;
  }

  /// Sign in with Google (mock implementation)
  Future<MockUser?> signInWithGoogle() async {
    try {
      debugPrint('Attempting Google Sign-In...');

      // In a real implementation, this would use GoogleSignIn
      // For demo purposes, we'll simulate the flow
      await Future.delayed(const Duration(seconds: 1));

      // Simulate Google account selection (in real app, this would be handled by Google)
      const selectedEmail = 'john.doe@gmail.com'; // For demo
      final accountInfo = _mockGoogleAccounts[selectedEmail];

      if (accountInfo == null) {
        throw Exception('Google account not found');
      }

      final now = DateTime.now();
      _currentUser = MockUser(
        uid: selectedEmail.hashCode.toString(),
        email: selectedEmail,
        displayName: accountInfo['name'] ?? selectedEmail.split('@').first,
        creationTime: now,
        lastSignInTime: now,
        emailVerified: true,
        photoUrl: accountInfo['photoUrl'],
      );

      // Create or update user in Firestore
      await _createUserInDatabase(_currentUser!);

      _authStateController.add(_currentUser);
      _storeEmail(selectedEmail);

      debugPrint('Google Sign-In successful: $selectedEmail');
      return _currentUser;
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
      throw Exception('Google Sign-In failed: $e');
    }
  }

  /// Sign out the current user
  Future<void> signOut() async {
    debugPrint('Signing out user: ${_currentUser?.email}');

    _currentUser = null;
    _authStateController.add(null);
    _clearStoredEmail(); // Clear persistence

    debugPrint('User signed out successfully');
  }

  /// Send password reset email
  Future<void> sendPasswordResetEmail(String email) async {
    debugPrint('Sending password reset email to: $email');

    if (!_demoAccounts.containsKey(email)) {
      throw Exception('No user found with this email address.');
    }

    // Simulate sending email
    await Future.delayed(const Duration(milliseconds: 500));
    debugPrint('Password reset email sent to: $email');
  }

  /// Update user display name
  Future<void> updateDisplayName(String displayName) async {
    if (_currentUser == null) {
      throw Exception('No user is currently signed in');
    }

    debugPrint('Updating display name to: $displayName');

    _currentUser = MockUser(
      uid: _currentUser!.uid,
      email: _currentUser!.email,
      displayName: displayName,
      creationTime: _currentUser!.creationTime,
      lastSignInTime: _currentUser!.lastSignInTime,
      emailVerified: _currentUser!.emailVerified,
      photoUrl: _currentUser!.photoUrl,
    );

    _authStateController.add(_currentUser);
    debugPrint('Display name updated to: $displayName');
  }

  /// Delete current user account
  Future<void> deleteAccount() async {
    if (_currentUser == null) {
      throw Exception('No user is currently signed in');
    }

    debugPrint('Deleting account: ${_currentUser!.email}');

    _currentUser = null;
    _authStateController.add(null);
    _clearStoredEmail();

    debugPrint('User account deleted');
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
      'emailVerified': user.emailVerified,
      'creationTime': user.creationTime.toIso8601String(),
      'lastSignInTime': user.lastSignInTime.toIso8601String(),
      'photoUrl': user.photoUrl,
    };
  }

  // Private helper methods
  MockUser _createUser(String email) {
    final now = DateTime.now();
    return MockUser(
      uid: email.hashCode.toString(),
      email: email,
      displayName: email.split('@').first,
      creationTime: now,
      lastSignInTime: now,
      emailVerified: true,
    );
  }

  String? _getStoredEmail() {
    // In a real app, this would read from secure storage
    // For demo purposes, we'll use a simple approach
    if (kIsWeb) {
      // Web storage simulation
      return null; // Simplified for demo
    } else {
      // Mobile storage simulation
      return null; // Simplified for demo
    }
  }

  void _storeEmail(String email) {
    debugPrint('Storing email for persistence: $email');
    // In a real app, this would store in secure storage
  }

  void _clearStoredEmail() {
    debugPrint('Clearing stored email');
    // In a real app, this would clear from secure storage
  }

  /// Get demo account information for testing
  static Map<String, String> get demoAccounts => Map.from(_demoAccounts);

  /// Get mock Google accounts for testing
  static Map<String, Map<String, String>> get mockGoogleAccounts =>
      Map.from(_mockGoogleAccounts);

  /// Create or update user in Firestore database
  Future<void> _createUserInDatabase(MockUser mockUser) async {
    try {
      final user = await _userService.createOrUpdateUser(
        userId: mockUser.uid,
        email: mockUser.email,
        name: mockUser.displayName ?? mockUser.email.split('@').first,
        photoUrl: mockUser.photoUrl,
        role: _getDefaultRole(mockUser.email),
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
}
