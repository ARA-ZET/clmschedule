// import 'package:firebase_auth/firebase_auth.dart';
// // import 'package:google_sign_in/google_sign_in.dart'; // Removed - not using Google Sign-In directly
// import 'package:flutter/foundation.dart';
// import 'package:cloud_firestore/cloud_firestore.dart';
// import '../services/user_service.dart';
// import '../models/user.dart' as app_user;

// /// Service for handling Firebase Authentication operations with Google Sign-In
// /// Provides secure login, logout, session persistence, and user creation
// class AuthService {
//   static final AuthService _instance = AuthService._internal();
//   factory AuthService() => _instance;
//   AuthService._internal();

//   final FirebaseAuth _auth = FirebaseAuth.instance;
//   // final GoogleSignIn _googleSignIn = GoogleSignIn(
//   //   scopes: ['email', 'profile'],
//   // ); // Removed - not using Google Sign-In directly
  
//   late final UserService _userService;

//   /// Get the current authenticated user
//   User? get currentUser => _auth.currentUser;

//   /// Check if user is currently authenticated
//   bool get isAuthenticated => _auth.currentUser != null;

//   /// Stream of authentication state changes
//   Stream<User?> get authStateChanges => _auth.authStateChanges();

//   /// Initialize authentication service and set up persistence
//   Future<void> initialize() async {
//     try {
//       // Initialize UserService
//       _userService = UserService(FirebaseFirestore.instance);
      
//       // For web platforms, set persistence to LOCAL to maintain login across browser sessions
//       if (kIsWeb) {
//         await _auth.setPersistence(Persistence.LOCAL);
//       }
      
//       // Firebase Auth automatically handles persistence on mobile platforms
//       debugPrint('AuthService initialized. Current user: ${currentUser?.email ?? 'None'}');
//     } catch (e) {
//       debugPrint('Error initializing AuthService: $e');
//     }
//   }

//   /// Sign in with email and password
//   Future<UserCredential?> signInWithEmailAndPassword({
//     required String email,
//     required String password,
//   }) async {
//     try {
//       final UserCredential result = await _auth.signInWithEmailAndPassword(
//         email: email.trim(),
//         password: password,
//       );
      
//       // Create or update user in database
//       if (result.user != null) {
//         await _createOrUpdateUserInDatabase(result.user!);
//       }
      
//       debugPrint('User signed in: ${result.user?.email}');
//       return result;
//     } on FirebaseAuthException catch (e) {
//       debugPrint('FirebaseAuth error: ${e.code} - ${e.message}');
//       throw _handleAuthException(e);
//     } catch (e) {
//       debugPrint('Unexpected error during sign in: $e');
//       throw Exception('An unexpected error occurred. Please try again.');
//     }
//   }

//   /// Create new user account with email and password
//   Future<UserCredential?> createUserWithEmailAndPassword({
//     required String email,
//     required String password,
//   }) async {
//     try {
//       final UserCredential result = await _auth.createUserWithEmailAndPassword(
//         email: email.trim(),
//         password: password,
//       );
      
//       // Create user in database
//       if (result.user != null) {
//         await _createOrUpdateUserInDatabase(result.user!);
//       }
      
//       debugPrint('User account created: ${result.user?.email}');
//       return result;
//     } on FirebaseAuthException catch (e) {
//       debugPrint('FirebaseAuth error: ${e.code} - ${e.message}');
//       throw _handleAuthException(e);
//     } catch (e) {
//       debugPrint('Unexpected error during account creation: $e');
//       throw Exception('An unexpected error occurred. Please try again.');
//     }
//   }

//   /// Sign in with Google
//   Future<UserCredential?> signInWithGoogle() async {
//     try {
//       debugPrint('Starting Google Sign-In process...');
      
//       // Trigger the Google Sign-In flow
//       throw UnimplementedError('Google Sign-In removed. Use FirebaseAuthService instead.');
//       // final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
//       if (googleUser == null) {
//         // User canceled the sign-in
//         debugPrint('Google Sign-In canceled by user');
//         return null;
//       }
      
//       debugPrint('Google Sign-In account obtained: ${googleUser.email}');
      
//       // Obtain the auth details from the request
//       final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      
//       // Create a new credential
//       final credential = GoogleAuthProvider.credential(
//         accessToken: googleAuth.accessToken,
//         idToken: googleAuth.idToken,
//       );
      
//       // Sign in to Firebase with the Google credential
//       final UserCredential result = await _auth.signInWithCredential(credential);
      
//       // Create or update user in database with Google profile info
//       if (result.user != null) {
//         await _createOrUpdateUserInDatabase(
//           result.user!,
//           displayName: googleUser.displayName,
//           photoUrl: googleUser.photoUrl,
//         );
//       }
      
//       debugPrint('Google Sign-In successful: ${result.user?.email}');
//       return result;
      
//     } on FirebaseAuthException catch (e) {
//       debugPrint('Firebase Auth error during Google Sign-In: ${e.code} - ${e.message}');
//       throw _handleAuthException(e);
//     } catch (e) {
//       debugPrint('Unexpected error during Google Sign-In: $e');
//       throw Exception('Google Sign-In failed. Please try again.');
//     }
//   }

//   /// Sign out the current user
//   Future<void> signOut() async {
//     try {
//       // Sign out from Google if signed in with Google
//       // Google Sign-In removed
//       // if (await _googleSignIn.isSignedIn()) {
//       //   await _googleSignIn.signOut();
//       // }
      
//       // Sign out from Firebase
//       await _auth.signOut();
//       debugPrint('User signed out successfully');
//     } catch (e) {
//       debugPrint('Error signing out: $e');
//       throw Exception('Error signing out. Please try again.');
//     }
//   }

//   /// Send password reset email
//   Future<void> sendPasswordResetEmail(String email) async {
//     try {
//       await _auth.sendPasswordResetEmail(email: email.trim());
//       debugPrint('Password reset email sent to: $email');
//     } on FirebaseAuthException catch (e) {
//       debugPrint('Error sending password reset email: ${e.code} - ${e.message}');
//       throw _handleAuthException(e);
//     } catch (e) {
//       debugPrint('Unexpected error sending password reset email: $e');
//       throw Exception('An unexpected error occurred. Please try again.');
//     }
//   }

//   /// Update user display name
//   Future<void> updateDisplayName(String displayName) async {
//     try {
//       await currentUser?.updateDisplayName(displayName);
//       await currentUser?.reload();
      
//       // Update in database as well
//       if (currentUser != null) {
//         await _createOrUpdateUserInDatabase(
//           currentUser!,
//           displayName: displayName,
//         );
//       }
      
//       debugPrint('Display name updated to: $displayName');
//     } catch (e) {
//       debugPrint('Error updating display name: $e');
//       throw Exception('Error updating display name.');
//     }
//   }

//   /// Delete current user account
//   Future<void> deleteAccount() async {
//     try {
//       final userId = currentUser?.uid;
      
//       // Delete from Firebase Auth
//       await currentUser?.delete();
      
//       // Soft delete from database
//       if (userId != null) {
//         await _userService.deleteUser(userId);
//       }
      
//       debugPrint('User account deleted');
//     } on FirebaseAuthException catch (e) {
//       debugPrint('Error deleting account: ${e.code} - ${e.message}');
//       throw _handleAuthException(e);
//     } catch (e) {
//       debugPrint('Unexpected error deleting account: $e');
//       throw Exception('An unexpected error occurred. Please try again.');
//     }
//   }

//   /// Create or update user in Firestore database
//   Future<void> _createOrUpdateUserInDatabase(
//     User firebaseUser, {
//     String? displayName,
//     String? photoUrl,
//   }) async {
//     try {
//       final user = await _userService.createOrUpdateUser(
//         userId: firebaseUser.uid,
//         email: firebaseUser.email ?? '',
//         name: displayName ?? 
//               firebaseUser.displayName ?? 
//               firebaseUser.email?.split('@').first ?? 
//               'User',
//         photoUrl: photoUrl ?? firebaseUser.photoURL,
//         role: _getDefaultRole(firebaseUser.email ?? ''),
//       );
//       debugPrint('User created/updated in database: ${user.email}');
//     } catch (e) {
//       debugPrint('Error creating user in database: $e');
//       // Don't throw error - auth should still work even if database fails
//     }
//   }

//   /// Get default role based on email
//   app_user.UserRole _getDefaultRole(String email) {
//     if (email.contains('admin')) {
//       return app_user.UserRole.admin;
//     } else if (email.contains('manager')) {
//       return app_user.UserRole.manager;
//     } else {
//       return app_user.UserRole.user;
//     }
//   }

//   /// Handle Firebase Auth exceptions and return user-friendly error messages
//   Exception _handleAuthException(FirebaseAuthException e) {
//     switch (e.code) {
//       case 'user-not-found':
//         return Exception('No user found with this email address.');
//       case 'wrong-password':
//         return Exception('Incorrect password. Please try again.');
//       case 'email-already-in-use':
//         return Exception('An account already exists with this email address.');
//       case 'weak-password':
//         return Exception('Password is too weak. Please choose a stronger password.');
//       case 'invalid-email':
//         return Exception('Please enter a valid email address.');
//       case 'user-disabled':
//         return Exception('This account has been disabled. Please contact support.');
//       case 'too-many-requests':
//         return Exception('Too many failed attempts. Please try again later.');
//       case 'operation-not-allowed':
//         return Exception('This sign-in method is not enabled. Please contact support.');
//       case 'network-request-failed':
//         return Exception('Network error. Please check your internet connection.');
//       case 'requires-recent-login':
//         return Exception('Please sign out and sign back in to perform this action.');
//       case 'account-exists-with-different-credential':
//         return Exception('An account already exists with the same email but different sign-in credentials.');
//       case 'invalid-credential':
//         return Exception('The provided credentials are invalid or have expired.');
//       case 'credential-already-in-use':
//         return Exception('This credential is already associated with a different user account.');
//       default:
//         return Exception('Authentication error: ${e.message ?? 'Unknown error'}');
//     }
//   }

//   /// Get user info as a map (useful for debugging or logging)
//   Map<String, dynamic> getUserInfo() {
//     final user = currentUser;
//     if (user == null) return {'authenticated': false};
    
//     return {
//       'authenticated': true,
//       'uid': user.uid,
//       'email': user.email,
//       'displayName': user.displayName,
//       'photoURL': user.photoURL,
//       'emailVerified': user.emailVerified,
//       'creationTime': user.metadata.creationTime?.toIso8601String(),
//       'lastSignInTime': user.metadata.lastSignInTime?.toIso8601String(),
//       'providerData': user.providerData.map((info) => {
//         'providerId': info.providerId,
//         'uid': info.uid,
//         'displayName': info.displayName,
//         'email': info.email,
//         'photoURL': info.photoURL,
//       }).toList(),
//     };
//   }

//   /// Check if user signed in with Google
//   bool get isSignedInWithGoogle {
//     final user = currentUser;
//     if (user == null) return false;
    
//     return user.providerData.any((info) => info.providerId == 'google.com');
//   }

//   /// Get the current user from database
//   Future<app_user.User?> getCurrentUserFromDatabase() async {
//     final firebaseUser = currentUser;
//     if (firebaseUser == null) return null;
    
//     try {
//       return await _userService.getUserById(firebaseUser.uid);
//     } catch (e) {
//       debugPrint('Error getting user from database: $e');
//       return null;
//     }
//   }
// }