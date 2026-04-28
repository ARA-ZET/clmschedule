import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_web_plugins/url_strategy.dart';
import 'config/flavor_config.dart';
import 'shareable_maps/providers/shareable_map_provider.dart';
import 'shareable_maps/widgets/shareable_map_editor.dart';
import 'shareable_maps/adapters/firestore_adapter.dart';
import 'shareable_maps/services/shareable_maps_firestore_service.dart';
import 'shareable_maps/services/map_link_service.dart';
import 'shareable_maps/widgets/clm_maps_splash.dart';
import 'firebase_options.dart';

/// Standalone CLM Maps Entry Point
///
/// A fully independent maps app deployed at https://clm-maps.web.app
/// - No authentication required
/// - Gallery view as home screen
/// - Deep link support for shared maps (/map/{shareCode})
/// - Real-time sync across all viewers
/// - Same Firestore backend as CLM Schedule (shareableMaps + mapLinks)
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(
    riverpod.ProviderScope(
      child: const CLMMapApp(),
    ),
  );
}

class CLMMapApp extends StatelessWidget {
  const CLMMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FlavorConfig.instance.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1967D2),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
        ),
      ),
      onGenerateRoute: (settings) {
        final uri = Uri.parse(settings.name ?? '');

        // Handle deep links: /map/{shareCode}
        if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'map') {
          final shareCode = uri.pathSegments[1];
          return MaterialPageRoute(
            builder: (_) => _DeepLinkMapLoader(shareCode: shareCode),
          );
        }

        // Default route — invalid link page (no gallery exposed)
        return MaterialPageRoute(
          builder: (_) => const _InvalidLinkPage(),
        );
      },
    );
  }
}

/// Resolves a share code and opens the map editor — no auth required.
class _DeepLinkMapLoader extends StatefulWidget {
  final String shareCode;
  const _DeepLinkMapLoader({required this.shareCode});

  @override
  State<_DeepLinkMapLoader> createState() => _DeepLinkMapLoaderState();
}

class _DeepLinkMapLoaderState extends State<_DeepLinkMapLoader> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolveAndOpen();
  }

  Future<void> _resolveAndOpen() async {
    try {
      final linkService = MapLinkService();
      final linkData = await linkService.resolveShareCode(widget.shareCode);
      if (linkData == null) {
        setState(() => _loading = false);
        return;
      }

      if (!mounted) return;

      final service = ShareableMapsFirestoreService();
      final adapter = FirestoreMapAdapter.existing(
        docId: linkData.mapId,
        monthKey: linkData.monthKey,
        service: service,
      );

      final provider = riverpod.ProviderScope.containerOf(context)
          .read(shareableMapRiverpod);
      await provider.loadFromAdapter(adapter);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ClmMapsSplash();
    }

    return const _InvalidLinkPage();
  }
}

/// Shown when there is no valid share code — either the user navigated
/// to the root URL or the deep link could not be resolved.
class _InvalidLinkPage extends StatelessWidget {
  const _InvalidLinkPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.link_off_rounded,
                  size: 72, color: Colors.grey.shade400),
              const SizedBox(height: 24),
              const Text(
                'Invalid Map Link',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF202124),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This link is invalid or has expired.\n'
                'Please contact Community Life Media for assistance.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF5F6368),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
