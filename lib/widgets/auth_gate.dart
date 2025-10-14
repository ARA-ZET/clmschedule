import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'login_screen.dart';

/// Authentication gate that controls access to the main app
/// Redirects unauthenticated users to login screen
/// Provides persistent login functionality across app sessions
class AuthGate extends StatelessWidget {
  final Widget child;

  const AuthGate({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Show loading screen while auth is initializing
        if (!authProvider.isInitialized) {
          return const _AuthLoadingScreen();
        }

        // Show main app if user is authenticated
        if (authProvider.isAuthenticated) {
          return child;
        }

        // Show login screen if user is not authenticated
        return const LoginScreen();
      },
    );
  }
}

/// Loading screen shown during authentication initialization
class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Logo/Icon (you can replace with your app's logo)
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.schedule,
                size: 50,
                color: Theme.of(context).primaryColor,
              ),
            ),

            const SizedBox(height: 32),

            // App Title
            Text(
              'CLM Schedule',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
            ),

            const SizedBox(height: 16),

            // Loading indicator
            CircularProgressIndicator(
              strokeWidth: 3,
              color: Theme.of(context).primaryColor,
            ),

            const SizedBox(height: 16),

            // Loading message
            Text(
              'Initializing secure connection...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
