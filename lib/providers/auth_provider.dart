import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/firebase_auth_service.dart';
import '../models/user.dart' as app_user;

/// Provider for managing Firebase authentication state throughout the app
/// Uses real Firebase Auth to create users in Firebase Auth console
class AuthProvider extends ChangeNotifier {
  final FirebaseAuthService _authService = FirebaseAuthService();

  // Private state variables
  User? _user;
  app_user.User? _appUser;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isInitialized = false;

  // Public getters
  User? get user => _user;
  app_user.User? get appUser => _appUser;
  bool get isAuthenticated => _user != null;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _isInitialized;

  /// Initialize the auth provider and set up authentication listeners
  Future<void> initialize() async {
    if (_isInitialized) return;

    _setLoading(true);

    try {
      // Initialize the auth service
      await _authService.initialize();

      // Set initial user state
      _user = _authService.currentUser;

      // Load app user data if authenticated
      if (_user != null) {
        _appUser = await _authService.getCurrentUserFromDatabase();
      }

      // Listen to authentication state changes
      _authService.authStateChanges.listen((User? user) async {
        _user = user;

        // Load or clear app user data
        if (user != null) {
          try {
            _appUser = await _authService.getCurrentUserFromDatabase();
          } catch (e) {
            debugPrint('Error loading app user data: $e');
            _appUser = null;
          }
        } else {
          _appUser = null;
        }

        _clearError();
        notifyListeners();

        debugPrint('Auth state changed. User: ${user?.email ?? 'None'}');
      });

      _isInitialized = true;
      debugPrint(
          'AuthProvider initialized. Current user: ${_user?.email ?? 'None'}');
    } catch (e) {
      _setError('Failed to initialize authentication: $e');
      debugPrint('Error initializing AuthProvider: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Sign in with email and password
  Future<bool> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      final result = await _authService.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (result != null) {
        debugPrint('Sign in successful via AuthProvider');
        return true;
      }

      _setError('Sign in failed. Please try again.');
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Sign in error in AuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Create new user account with email and password
  Future<bool> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      final result = await _authService.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (result != null) {
        debugPrint('Account creation successful via AuthProvider');
        return true;
      }

      _setError('Account creation failed. Please try again.');
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Account creation error in AuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Sign out the current user
  Future<void> signOut() async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.signOut();
      debugPrint('Sign out successful via AuthProvider');
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Sign out error in AuthProvider: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Send password reset email
  Future<bool> sendPasswordResetEmail(String email) async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.sendPasswordResetEmail(email);
      debugPrint('Password reset email sent via AuthProvider');
      return true;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Password reset error in AuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Update user display name
  Future<bool> updateDisplayName(String displayName) async {
    if (!isAuthenticated) {
      _setError('User must be authenticated to update display name');
      return false;
    }

    _setLoading(true);
    _clearError();

    try {
      await _authService.updateDisplayName(displayName);
      // User object will be updated via auth state listener
      debugPrint('Display name updated via AuthProvider');
      return true;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Display name update error in AuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Delete current user account
  Future<bool> deleteAccount() async {
    if (!isAuthenticated) {
      _setError('User must be authenticated to delete account');
      return false;
    }

    _setLoading(true);
    _clearError();

    try {
      await _authService.deleteAccount();
      debugPrint('Account deleted via AuthProvider');
      return true;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Account deletion error in AuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Clear any current error message
  void clearError() {
    _clearError();
  }

  /// Get comprehensive user information
  Map<String, dynamic> getUserInfo() {
    return _authService.getUserInfo();
  }

  /// Get user display name (prioritizing app user data)
  String get displayName =>
      _appUser?.name ??
      _user?.displayName ??
      _user?.email?.split('@').first ??
      'User';

  /// Get user email
  String get userEmail => _user?.email ?? '';

  /// Get user photo URL
  String? get userPhotoUrl => _appUser?.photoUrl ?? _user?.photoURL;

  /// Get user role (from app user data)
  app_user.UserRole get userRole => _appUser?.role ?? app_user.UserRole.user;

  /// Check if user has admin privileges
  bool get isAdmin => userRole == app_user.UserRole.admin;

  /// Check if user has management privileges
  bool get isManager =>
      userRole == app_user.UserRole.admin ||
      userRole == app_user.UserRole.manager;

  /// Check if user can edit schedules
  bool get canEdit =>
      userRole == app_user.UserRole.admin ||
      userRole == app_user.UserRole.manager ||
      userRole == app_user.UserRole.supervisor;

  /// Check if user can only view
  bool get isViewOnly => userRole == app_user.UserRole.viewer;

  /// Refresh user data from database
  Future<void> refreshUserData() async {
    if (!isAuthenticated) return;

    try {
      _appUser = await _authService.getCurrentUserFromDatabase();
      notifyListeners();
      debugPrint('User data refreshed');
    } catch (e) {
      debugPrint('Error refreshing user data: $e');
    }
  }

  // Private helper methods
  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String error) {
    _errorMessage = error;
    notifyListeners();
  }

  void _clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  /// Get demo accounts for testing
  Map<String, String> get demoAccounts => FirebaseAuthService.demoAccounts;

  @override
  void dispose() {
    // Clean up any subscriptions if needed
    super.dispose();
  }
}
