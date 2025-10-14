import 'package:flutter/foundation.dart';
import '../services/mock_auth_service.dart';

/// Provider for managing mock authentication state throughout the app
/// Uses MockAuthService for demonstration purposes
class MockAuthProvider extends ChangeNotifier {
  final MockAuthService _authService = MockAuthService();

  // Private state variables
  MockUser? _user;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isInitialized = false;

  // Public getters
  MockUser? get user => _user;
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

      // Listen to authentication state changes
      _authService.authStateChanges.listen((MockUser? user) {
        _user = user;
        _clearError();
        notifyListeners();

        debugPrint('Auth state changed. User: ${user?.email ?? 'None'}');
      });

      _isInitialized = true;
      debugPrint(
          'MockAuthProvider initialized. Current user: ${_user?.email ?? 'None'}');
    } catch (e) {
      _setError('Failed to initialize authentication: $e');
      debugPrint('Error initializing MockAuthProvider: $e');
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
        debugPrint('Sign in successful via MockAuthProvider');
        return true;
      }

      _setError('Sign in failed. Please try again.');
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Sign in error in MockAuthProvider: $e');
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
        debugPrint('Account creation successful via MockAuthProvider');
        return true;
      }

      _setError('Account creation failed. Please try again.');
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Account creation error in MockAuthProvider: $e');
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
      debugPrint('Sign out successful via MockAuthProvider');
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Sign out error in MockAuthProvider: $e');
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
      debugPrint('Password reset email sent via MockAuthProvider');
      return true;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Password reset error in MockAuthProvider: $e');
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
      debugPrint('Display name updated via MockAuthProvider');
      return true;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Display name update error in MockAuthProvider: $e');
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

  /// Sign in with Google
  Future<bool> signInWithGoogle() async {
    _setLoading(true);
    _clearError();

    try {
      final result = await _authService.signInWithGoogle();

      if (result != null) {
        debugPrint('Google Sign in successful via MockAuthProvider');
        return true;
      }

      _setError('Google Sign in failed. Please try again.');
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      debugPrint('Google Sign in error in MockAuthProvider: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Get demo accounts for testing
  Map<String, String> get demoAccounts => MockAuthService.demoAccounts;

  /// Get mock Google accounts for testing
  Map<String, Map<String, String>> get mockGoogleAccounts =>
      MockAuthService.mockGoogleAccounts;

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

  @override
  void dispose() {
    // Clean up any subscriptions if needed
    super.dispose();
  }
}
