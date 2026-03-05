import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'config/flavor_config.dart';
import 'shareable_maps/providers/shareable_map_provider.dart';
import 'shareable_maps/providers/shareable_maps_gallery_provider.dart';
import 'shareable_maps/widgets/shareable_maps_gallery.dart';
import 'shareable_maps/widgets/shareable_map_editor.dart';
import 'shareable_maps/adapters/firestore_adapter.dart';
import 'shareable_maps/services/shareable_maps_firestore_service.dart';
import 'shareable_maps/services/map_link_service.dart';
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
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ShareableMapProvider()),
        ChangeNotifierProvider(create: (_) => ShareableMapsGalleryProvider()),
      ],
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

        // Default route — gallery
        return MaterialPageRoute(
          builder: (_) => const ShareableMapsGallery(),
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
  String? _error;

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
        setState(() {
          _loading = false;
          _error = 'Map not found. The link may have expired or been deleted.';
        });
        return;
      }

      if (!mounted) return;

      final service = ShareableMapsFirestoreService();
      final adapter = FirestoreMapAdapter.existing(
        docId: linkData.mapId,
        monthKey: linkData.monthKey,
        service: service,
      );

      final provider = context.read<ShareableMapProvider>();
      await provider.loadFromAdapter(adapter);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to load map: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading shared map...', style: TextStyle(fontSize: 16)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Something went wrong',
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.pushReplacementNamed(context, '/'),
              icon: const Icon(Icons.home),
              label: const Text('Go to Gallery'),
            ),
          ],
        ),
      ),
    );
  }
}
