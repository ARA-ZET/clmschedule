import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../providers/auth_provider.dart';
import 'clm_maps_splash.dart';

class CLMMapsAdminLoginPage extends riverpod.ConsumerStatefulWidget {
  const CLMMapsAdminLoginPage({super.key});

  @override
  riverpod.ConsumerState<CLMMapsAdminLoginPage> createState() =>
      _CLMMapsAdminLoginPageState();
}

class _CLMMapsAdminLoginPageState
    extends riverpod.ConsumerState<CLMMapsAdminLoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isSubmitting = false;
  String? _localError;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _goHome() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _localError = 'Enter your email and password.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _localError = null;
    });

    final auth = ref.read(authRiverpod);
    auth.clearError();
    final success = await auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    if (!mounted) return;

    if (success) {
      _goHome();
      return;
    }

    setState(() {
      _isSubmitting = false;
      _localError = auth.errorMessage ?? 'Sign-in failed.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRiverpod);
    if (!auth.isInitialized) {
      return const ClmMapsSplash();
    }

    if (auth.isAuthenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goHome();
      });
      return const ClmMapsSplash();
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/map.jpg', fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xDD08111F),
                  Color(0xEE101824),
                  Color(0xF7080D14),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: AutofillGroup(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.admin_panel_settings_rounded,
                                  color: Color(0xFF1967D2),
                                  size: 28,
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'CLM Maps Admin',
                                    style: TextStyle(
                                      color: Color(0xFF111827),
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Sign in to manage shareable maps.',
                              style: TextStyle(
                                color: Color(0xFF5F6368),
                                fontSize: 14,
                                letterSpacing: 0,
                              ),
                            ),
                            const SizedBox(height: 26),
                            TextField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.username],
                              enabled: !_isSubmitting,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                prefixIcon: Icon(Icons.alternate_email_rounded),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              enabled: !_isSubmitting,
                              onSubmitted: (_) => _submit(),
                              decoration: const InputDecoration(
                                labelText: 'Password',
                                prefixIcon: Icon(Icons.lock_outline_rounded),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            if (_localError != null) ...[
                              const SizedBox(height: 14),
                              Text(
                                _localError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                            const SizedBox(height: 22),
                            FilledButton.icon(
                              onPressed: _isSubmitting ? null : _submit,
                              icon: _isSubmitting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login_rounded, size: 18),
                              label: const Text('Sign in'),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                textStyle: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
