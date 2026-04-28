import 'dart:async';
import 'package:flutter/material.dart';

/// Compact loading card for CLM Maps deep-link resolution.
///
/// 200 × 250 card with map image, branding text, and animated loading
/// status that cycles through: "Loading tracks", "Loading waypoints",
/// "Updating map".
class ClmMapsSplash extends StatefulWidget {
  const ClmMapsSplash({super.key});

  @override
  State<ClmMapsSplash> createState() => _ClmMapsSplashState();
}

class _ClmMapsSplashState extends State<ClmMapsSplash>
    with SingleTickerProviderStateMixin {
  static const _steps = [
    'Loading tracks',
    'Loading waypoints',
    'Updating map',
  ];

  int _stepIndex = 0;
  Timer? _timer;
  late AnimationController _dotController;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() => _stepIndex = (_stepIndex + 1) % _steps.length);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A2E6E),
      body: Stack(
        children: [
          // Decorative background circles
          Positioned(
            top: -60,
            right: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -50,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.04),
              ),
            ),
          ),
          Positioned(
            top: 120,
            left: -30,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD4A017).withValues(alpha: 0.12),
              ),
            ),
          ),
          Positioned(
            bottom: 60,
            right: -20,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD4A017).withValues(alpha: 0.08),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 80,
            child: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          // Card
          Center(
            child: SizedBox(
              width: 275,
              height: 350,
              child: Card(
                elevation: 8,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Map image header
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: SizedBox(
                        height: 220,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                          Image.asset(
                            'assets/map.jpg',
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: const Color(0xFF0A2E6E),
                              child: const Icon(Icons.map,
                                  size: 48, color: Colors.white70),
                            ),
                          ),
                          // Subtle overlay so the LOADING chip is readable
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.15),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                          // LOADING chip
                          Positioned(
                            top: 10,
                            left: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'LOADING',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2C4A6E),
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ],
                          ),
                        ),
                      ),
                    ),
                    // Body
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Flyer Distribution',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF202124),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              '#1 GPS-tracked flyer distribution in Cape Town',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF5F6368),
                                height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const Spacer(),
                            // Loading status row
                            Row(
                              children: [
                                Text(
                                  _steps[_stepIndex],
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF202124),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // Animated dots
                                AnimatedBuilder(
                                  animation: _dotController,
                                  builder: (_, __) {
                                    final dots = '.' *
                                        ((_dotController.value * 3).floor() +
                                            1);
                                    return Text(
                                      dots,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFD4A017),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            // Progress bar
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                backgroundColor: Colors.grey.shade200,
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF2C4A6E),
                                ),
                                minHeight: 3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
