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
import 'shareable_maps/widgets/clm_advert_page.dart';
import 'shareable_maps/widgets/clm_maps_admin_login_page.dart';
import 'shareable_maps/widgets/clm_maps_splash.dart';
import 'shareable_maps/widgets/shareable_maps_gallery.dart';
import 'providers/auth_provider.dart';
import 'firebase_options.dart';

/// Standalone CLM Maps Entry Point
///
/// A fully independent maps app deployed at https://clm-maps.web.app
/// - No client sign-in UI exposed
/// - Deep link support for shared maps (/map/{shareCode})
/// - Website advert fallback at /, with invalid-link messaging for bad links
/// - Direct-only admin login routes (/login, /admin, /admin/login)
/// - Real-time sync across all viewers
/// - Same Firestore backend as CLM Schedule (shareableMaps + mapLinks)
/// - Any valid signed-in Firebase Auth user is treated as a maps admin and
///   gets the gallery/editing tools through the persisted auth session.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final container = riverpod.ProviderContainer();
  // Restore any persisted Firebase Auth session so the editor can detect
  // authenticated users and unlock admin tools. Fire-and-forget: the UI
  // listens via `authRiverpod` and rebuilds when state changes.
  // ignore: unawaited_futures
  container.read(authRiverpod).initialize();

  runApp(
    riverpod.UncontrolledProviderScope(
      container: container,
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

        if (_isAdminLoginRoute(uri)) {
          return MaterialPageRoute(
            builder: (_) => const CLMMapsAdminLoginPage(),
          );
        }

        // Handle deep links: /map/{shareCode}
        if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'map') {
          final shareCode = uri.pathSegments[1];
          return MaterialPageRoute(
            builder: (_) => _DeepLinkMapLoader(shareCode: shareCode),
          );
        }

        // Default route: authenticated admins go to the gallery; everyone
        // else sees the CLM website advert as a clean home fallback.
        return MaterialPageRoute(
          builder: (_) => const _MapsRootGate(),
        );
      },
    );
  }
}

bool _isAdminLoginRoute(Uri uri) {
  final segments = uri.pathSegments.map((s) => s.toLowerCase()).toList();
  if (segments.length == 1) {
    return segments.first == 'login' || segments.first == 'admin';
  }
  return segments.length == 2 &&
      segments.first == 'admin' &&
      segments.last == 'login';
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

    return const CLMAdvertPage(showInvalidBanner: true);
  }
}

/// Root gate at "/" — shows the gallery to authenticated users and the
/// CLM advert home page to everyone else. The public page does not link to
/// the direct-only admin login routes.
class _MapsRootGate extends riverpod.ConsumerWidget {
  const _MapsRootGate();

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final auth = ref.watch(authRiverpod);
    if (!auth.isInitialized) {
      return const ClmMapsSplash();
    }
    if (auth.isAuthenticated) {
      return const ShareableMapsGallery();
    }
    return const CLMAdvertPage();
  }
}
