import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:package_info_plus/package_info_plus.dart';
import 'config/flavor_config.dart';
// import 'providers/toggler_provider.dart'; // Migrated to Riverpod
import 'providers/schedule_provider.dart';
import 'providers/collection_schedule_provider.dart';
import 'providers/job_list_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/inventory_provider.dart';
import 'providers/happy_sun_project_provider.dart';
// import 'providers/job_status_provider.dart'; // Migrated to Riverpod
// import 'providers/job_list_status_provider.dart'; // Migrated to Riverpod
// import 'providers/invoice_status_provider.dart'; // Migrated to Riverpod
// import 'providers/job_list_preferences_provider.dart'; // Migrated to Riverpod
import 'providers/auth_provider.dart';
// import 'providers/vehicle_driver_provider.dart'; // REMOVED: unused provider
// import 'providers/scale_provider.dart'; // Migrated to Riverpod
// import 'providers/map_view_provider.dart'; // Migrated to Riverpod
import 'providers/app_version_provider.dart';
import 'providers/tool_settings_provider.dart';
// import 'providers/job_type_provider.dart'; // Migrated to Riverpod
import 'providers/job_type_provider.dart'
    show JobTypeProvider; // static accessor only
import 'providers/unfinished_work_areas_provider.dart';
import 'shareable_maps/providers/shareable_map_provider.dart';
import 'shareable_maps/widgets/shareable_maps_gallery.dart';
import 'models/happy_sun_project.dart';
import 'models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData
import 'widgets/schedule_grid.dart';
import 'widgets/collection_schedule_grid.dart';
import 'widgets/job_list_grid.dart';
import 'widgets/distributor_management_dialog.dart';
import 'widgets/lazy_loading_indicator.dart';
import 'widgets/scale_settings_dialog.dart';
import 'widgets/job_status_management_dialog.dart';
import 'widgets/job_list_status_management_dialog.dart';
import 'widgets/invoice_status_management_dialog.dart';
import 'widgets/job_type_management_dialog.dart';
import 'widgets/auth_gate.dart';
import 'widgets/chat_dialog.dart';
import 'widgets/chat_admin_panel.dart';
import 'widgets/unfinished_work_areas_panel.dart';
import 'widgets/app_update_dialog.dart';
import 'widgets/happy_sun_inventory_view.dart';
import 'widgets/happy_sun_job_projects_screen.dart';
import 'shareable_maps/widgets/shareable_map_editor.dart';
import 'shareable_maps/adapters/work_area_adapter.dart';
import 'shareable_maps/adapters/firestore_adapter.dart';
import 'shareable_maps/services/shareable_maps_firestore_service.dart';
import 'shareable_maps/services/map_link_service.dart';
import 'shareable_maps/widgets/clm_maps_splash.dart';
import 'widgets/suburb_list_screen.dart';
import 'track_editor/pages/track_editor_screen.dart';
// TE provider imports migrated to Riverpod
// ErfPropertyProvider migrated to Riverpod
import 'erf_property/pages/erf_property_screen.dart';
import 'services/version_service.dart';

// import 'services/work_area_service.dart'; // Migrated to Riverpod
// import 'services/job_list_service.dart'; // Migrated to Riverpod
// import 'services/job_list_preferences_service.dart'; // Migrated to Riverpod
// import 'services/user_service.dart'; // Migrated to Riverpod
// import 'services/chat_service.dart'; // Migrated to Riverpod
// import 'services/ai_chat_service.dart'; // Migrated to Riverpod
// import 'providers/ai_chat_provider.dart'; // Migrated to Riverpod
import 'widgets/ai_chat_dialog.dart';
import 'widgets/dropsheet/dropsheet_tab.dart';
import 'services/inventory_service.dart';
import 'services/connectivity_service.dart';
import 'services/happy_sun_local_storage.dart';
import 'services/happy_sun_sync_service.dart';
import 'services/inventory_local_storage.dart';
import 'services/image_cache_service.dart';
import 'services/inventory_sync_service.dart';
import 'models/command.dart';
import 'firebase_options.dart';
import 'utils/web_reload.dart'
    if (dart.library.io) 'utils/web_reload_stub.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

// Simple test command for debugging undo functionality
class TestCommand extends Command {
  final String _description;

  TestCommand(this._description);

  @override
  String get description => _description;

  @override
  Future<void> execute() async {
    print('Executing: $_description');
  }

  @override
  Future<void> undo() async {
    print('Undoing: $_description');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Enable offline persistence for non-web platforms
  // Web platform has different persistence handling
  try {
    if (!kIsWeb) {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    }
  } catch (e) {
    // Settings may have already been applied, continue silently
    print('Firestore settings already configured: $e');
  }

  // All providers migrated to Riverpod - no more MultiProvider needed
  runApp(const riverpod.ProviderScope(child: MyApp()));
}

class MyApp extends riverpod.ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  riverpod.ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends riverpod.ConsumerState<MyApp> {
  late final VersionService _versionService;
  bool _isInitialized = false;

  // Offline services for Happy Sun flavor
  ConnectivityService? _connectivityService;
  HappySunLocalStorage? _localStorage;
  HappySunSyncService? _syncService;

  // Inventory offline services for Happy Sun flavor
  InventoryLocalStorage? _inventoryLocalStorage;
  ImageCacheService? _imageCacheService;
  InventorySyncService? _inventorySyncService;

  @override
  void initState() {
    super.initState();
    _versionService = VersionService(FirebaseFirestore.instance);
    // Initialize all providers asynchronously in parallel
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeProvidersAsync();
      // Set up Happy Sun sync for both flavors (both have Happy Sun features)
      _setupHappySunSync();
    });
  }

  void _setupHappySunSync() {
    // Set up callbacks to sync Happy Sun projects with Job List items
    final jobListProvider = ref.read(jobListRiverpod);
    final happySunProjectProvider = ref.read(happySunProjectRiverpod);
    final toolSettingsProvider = ref.read(toolSettingsRiverpod);
    final inventoryProvider = ref.read(inventoryRiverpod);

    jobListProvider.setHappySunCallbacks(
      onAdded: (jobListItem) async {
        try {
          debugPrint('\n🌞 ========== HAPPY SUN SYNC TRIGGERED ==========');
          debugPrint('🔵 Happy Sun Sync onAdded callback');
          debugPrint('   Job List Item ID: ${jobListItem.id}');
          debugPrint('   Client: ${jobListItem.client}');
          debugPrint('   Job Type: ${jobListItem.jobTypeId}');
          debugPrint('   Date: ${jobListItem.date}');
          debugPrint('   Has Tools: ${jobListItem.toolsNeeded != null}');

          // Check if project already exists to prevent duplicates
          debugPrint('   Checking if project already exists in provider...');
          try {
            final existingProject =
                happySunProjectProvider.getProjectById(jobListItem.id);
            if (existingProject != null) {
              debugPrint(
                  '   ⚠️ Happy Sun project already exists in provider - ABORTING');
              return;
            }
            debugPrint(
                '   No existing project found - proceeding with creation');
          } catch (e) {
            // If there's an error checking (e.g., corrupted old data), proceed anyway
            // The service-level check will prevent actual duplicates
            debugPrint(
                '   ⚠️ Error checking existing project (possibly old data): $e');
            debugPrint(
                '   Proceeding with creation - service will prevent duplicates');
          }

          // Auto-create Happy Sun project for window/solar cleaning jobs
          // Use tools from job item if specified, otherwise calculate based on manDays
          final numberOfCleaners = jobListItem.manDays.ceil();
          debugPrint('   Number of cleaners: $numberOfCleaners');

          CategorizedTools categorizedTools;

          // Check if job item has pre-defined tools
          if (jobListItem.toolsNeeded != null) {
            debugPrint('   Using pre-defined tools from job item');
            categorizedTools = jobListItem.toolsNeeded!;
            debugPrint(
                '   Team tools: ${categorizedTools.teamTools.length} groups');
            debugPrint(
                '   Individual tools: ${categorizedTools.individualTools.length} groups');
            debugPrint('   Extras: ${categorizedTools.extras.length} groups');
            debugPrint(
                '   Accessories: ${categorizedTools.accessories.length} groups');
          } else {
            debugPrint(
                '   No pre-defined tools, auto-calculating based on manDays');

            // Check if tool settings are loaded
            if (toolSettingsProvider.settings.teamTools.isEmpty &&
                toolSettingsProvider.settings.individualTools.isEmpty) {
              debugPrint(
                  '   ⚠️ WARNING: Tool settings are empty! Loading now...');
              await toolSettingsProvider.loadSettings();
            }

            // Check if inventory is loaded
            if (inventoryProvider.tools.isEmpty) {
              debugPrint('   ⚠️ WARNING: Inventory is empty! Loading now...');
              await inventoryProvider.initialize();
            }

            debugPrint(
                '   Tool settings: ${toolSettingsProvider.settings.teamTools.length} team tools, ${toolSettingsProvider.settings.individualTools.length} individual tools');
            debugPrint(
                '   Inventory: ${inventoryProvider.tools.length} tools available');

            // Calculate categorized tools: team tools (constant) + individual tools (per cleaner)
            categorizedTools = toolSettingsProvider.calculateCategorizedTools(
              numberOfCleaners,
              inventoryProvider.tools,
            );

            debugPrint(
                '   Team tools calculated: ${categorizedTools.teamTools.length} groups');
            debugPrint(
                '   Individual tools calculated: ${categorizedTools.individualTools.length} groups (×$numberOfCleaners cleaners)');
            for (final tool in categorizedTools.teamTools) {
              debugPrint(
                  '      Team: ${tool.baseName} × ${tool.totalQuantity}');
            }
            for (final tool in categorizedTools.individualTools) {
              debugPrint(
                  '      Individual: ${tool.baseName} × ${tool.totalQuantity}');
            }
          }

          // Determine job type. We pass the raw jobTypeId through so that
          // any Happy Sun-flagged service (window, solar, or future ones
          // added via Settings) is preserved on the HappySunProject.
          final jobType = jobListItem.jobTypeId;

          // Create HappySunProject with consolidated fields
          final project = HappySunProject(
            id: jobListItem.id,
            jobListItemId: jobListItem.id,
            clientName: jobListItem.client,
            address: jobListItem.collectionAddress.isNotEmpty
                ? jobListItem.collectionAddress
                : jobListItem.area,
            scheduledDate: jobListItem.date,
            numberOfTeamMembers: numberOfCleaners,
            jobType: jobType,
            toolsNeeded: categorizedTools,
            statusId: jobListItem.jobStatusId,
            status: 'pending',
            createdAt: DateTime.now(),
          );

          // Pass jobListItemId to createProject to use as document ID
          debugPrint('   📤 Calling happySunProjectProvider.createProject...');
          debugPrint('   Project ID will be: ${jobListItem.id}');
          await happySunProjectProvider.createProject(project, jobListItem.id);
          debugPrint('   ✅ Happy Sun project created: ${project.clientName}');
          debugPrint('✅ ========== HAPPY SUN SYNC COMPLETE ==========\n');
        } catch (e) {
          debugPrint('❌ Happy Sun Sync Error (onAdded): $e');
        }
      },
      onUpdated: (oldItem, newItem) async {
        try {
          // Update project when JobListItem changes
          if ((oldItem.manDays != newItem.manDays ||
                  oldItem.client != newItem.client ||
                  oldItem.collectionAddress != newItem.collectionAddress ||
                  oldItem.area != newItem.area ||
                  oldItem.jobStatusId != newItem.jobStatusId ||
                  oldItem.toolsNeeded != newItem.toolsNeeded) &&
              (JobTypeProvider.instance?.isHappySunService(newItem.jobTypeId) ??
                  false)) {
            final existingProject =
                happySunProjectProvider.getProjectById(newItem.id);
            if (existingProject != null) {
              final numberOfCleaners = newItem.manDays.ceil();

              // Determine which tools to use
              CategorizedTools? updatedToolsNeeded;
              if (newItem.toolsNeeded != null) {
                // Use pre-defined tools from job item
                debugPrint('   Using updated pre-defined tools from job item');
                updatedToolsNeeded = newItem.toolsNeeded;
              } else if (oldItem.manDays != newItem.manDays) {
                // Recalculate ONLY individual tools when manDays changes
                // Keep team tools, extras, and accessories unchanged
                debugPrint(
                    '   Recalculating ONLY individual tools due to manDays change');
                debugPrint('   Preserving: team tools, extras, accessories');

                // Calculate full tools to get the new individual tools
                final fullCalculation =
                    toolSettingsProvider.calculateCategorizedTools(
                  numberOfCleaners,
                  inventoryProvider.tools,
                );

                // Merge: keep existing team/extras/accessories, use new individual tools
                updatedToolsNeeded = CategorizedTools(
                  teamTools: existingProject.toolsNeeded?.teamTools ?? [],
                  individualTools: fullCalculation.individualTools,
                  extras: existingProject.toolsNeeded?.extras ?? [],
                  accessories: existingProject.toolsNeeded?.accessories ?? [],
                );

                debugPrint(
                    '   Updated individual tools: ${fullCalculation.individualTools.length} groups');
              }

              final updatedProject = existingProject.copyWith(
                clientName: newItem.client,
                address: newItem.collectionAddress.isNotEmpty
                    ? newItem.collectionAddress
                    : newItem.area,
                numberOfTeamMembers: numberOfCleaners,
                toolsNeeded: updatedToolsNeeded ?? existingProject.toolsNeeded,
                statusId: newItem.jobStatusId,
                updatedAt: DateTime.now(),
              );
              await happySunProjectProvider.updateProject(updatedProject);
              debugPrint(
                  '   Happy Sun project updated: ${updatedProject.clientName}');
            }
          }
        } catch (e) {
          debugPrint('❌ Happy Sun Sync Error (onUpdated): $e');
        }
      },
      onDeleted: (jobListItem) async {
        try {
          // Delete corresponding HappySunProject when a Happy Sun-flagged
          // job is deleted.
          if (JobTypeProvider.instance
                  ?.isHappySunService(jobListItem.jobTypeId) ??
              false) {
            await happySunProjectProvider.deleteProject(jobListItem.id);
            debugPrint('   Happy Sun project deleted: ${jobListItem.id}');
          }
        } catch (e) {
          debugPrint('❌ Happy Sun Sync Error (onDeleted): $e');
        }
      },
    );
  }

  Future<void> _initializeProvidersAsync() async {
    if (_isInitialized) return;

    // Initialize offline services for Happy Sun flavor
    if (FlavorConfig.instance.isHappySun) {
      try {
        debugPrint('📱 Initializing offline services for Happy Sun...');

        // Initialize connectivity service
        _connectivityService = ConnectivityService();
        await _connectivityService!.initialize();

        // Initialize project local storage
        _localStorage = HappySunLocalStorage();
        await _localStorage!.initialize();

        // Initialize inventory offline services
        _inventoryLocalStorage = InventoryLocalStorage();
        await _inventoryLocalStorage!.initialize();

        _imageCacheService = ImageCacheService();
        await _imageCacheService!.initialize();

        // Get providers
        final happySunProvider = ref.read(happySunProjectRiverpod);
        final inventoryProvider = ref.read(inventoryRiverpod);
        final inventoryService = ref.read(inventoryServiceRiverpod);

        // Initialize project sync service
        _syncService = HappySunSyncService(
          firebaseService: happySunProvider.projectService,
          localStorage: _localStorage!,
          connectivityService: _connectivityService!,
        );
        _syncService!.initialize();

        // Initialize inventory sync service
        _inventorySyncService = InventorySyncService(
          firebaseService: inventoryService,
          localStorage: _inventoryLocalStorage!,
          imageCacheService: _imageCacheService!,
          connectivityService: _connectivityService!,
        );
        await _inventorySyncService!.initialize();

        // Configure providers with offline services
        happySunProvider.setOfflineServices(
          localStorage: _localStorage!,
          syncService: _syncService!,
          connectivityService: _connectivityService!,
        );

        inventoryProvider.setOfflineServices(_inventorySyncService);

        debugPrint('✅ All offline services initialized and configured');
        debugPrint(
            '   - Projects: ${_localStorage!.getAllProjects().length} cached');
        debugPrint(
            '   - Tools: ${_inventoryLocalStorage!.getAllTools().length} cached');
        debugPrint(
            '   - Images: ${_inventoryLocalStorage!.getCacheStats()['cachedImagesCount']} cached');
      } catch (e) {
        debugPrint('❌ Error initializing offline services: $e');
      }
    }

    // Build initialization list based on flavor
    final List<Future<void>> initializations = [
      ref.read(authRiverpod).initialize(),
      ref.read(jobListRiverpod).initialize(),
      ref.read(inventoryRiverpod).initialize(),
      ref.read(toolSettingsRiverpod).loadSettings(),
    ];

    // Only initialize ScheduleProvider for CLM flavor
    if (FlavorConfig.instance.isCLM) {
      initializations.add(ref.read(scheduleRiverpod).initialize());
      initializations.add(ref.read(unfinishedWorkAreasRiverpod).initialize());
    }

    // Run all provider initializations in parallel for fast startup
    await Future.wait(initializations);

    // Ensure lastCheckedTime is loaded now that auth is guaranteed ready
    await ref.read(jobListRiverpod).ensureLastCheckedTimeLoaded();

    // CollectionScheduleProvider loads lazily when tab opens (depends on JobListProvider data)

    // Initialize version checking for web only
    if (kIsWeb && mounted) {
      _initializeVersionCheck();
      _setupVersionListener();
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _initializeVersionCheck() async {
    final versionProvider = ref.read(appVersionRiverpod);

    // Get current app version from package info
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Initialize with current app version
      versionProvider.initialize(currentVersion);
    } catch (e) {
      print('Error getting package info: $e');
      // Fallback to a default version
      versionProvider.initialize('1.0.0');
    }
  }

  void _setupVersionListener() {
    final versionProvider = ref.read(appVersionRiverpod);

    // Listen for version changes
    versionProvider.addListener(() {
      if (versionProvider.needsUpdate && mounted) {
        _showUpdateDialog(versionProvider);
      }
    });
  }

  void _showUpdateDialog(AppVersionProvider versionProvider) async {
    if (!mounted) return;

    final newVersion = versionProvider.currentVersion;
    final currentVersion = versionProvider.localVersion?.version ?? '0.0.0';

    if (newVersion == null) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: !versionProvider.forceUpdate,
      builder: (context) => AppUpdateDialog(
        newVersion: newVersion,
        currentVersion: currentVersion,
        forceUpdate: versionProvider.forceUpdate,
      ),
    );

    if (result == true && mounted) {
      // Refresh the page
      _refreshApp();
    }
  }

  void _refreshApp() {
    // For web, reload the page
    if (kIsWeb) {
      reloadPage();
    }
  }

  @override
  void dispose() {
    if (kIsWeb) {
      _versionService.dispose();
    }
    // Dispose offline services for Happy Sun
    if (FlavorConfig.instance.isHappySun) {
      _connectivityService?.dispose();
      _localStorage?.dispose();
      _syncService?.dispose();
      _inventoryLocalStorage?.dispose();
      _inventorySyncService?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FlavorConfig.instance.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor:
              FlavorConfig.instance.isHappySun ? Colors.orange : Colors.blue,
        ),
        useMaterial3: true,
      ),
      onGenerateRoute: (settings) {
        final uri = Uri.parse(settings.name ?? '');
        // Handle deep links: /map/{shareCode}
        if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'map') {
          final shareCode = uri.pathSegments[1];
          return MaterialPageRoute(
            builder: (_) => _isInitialized
                ? _DeepLinkMapLoader(shareCode: shareCode)
                : _buildLoadingScaffold(),
          );
        }
        // Default route (dashboard)
        return MaterialPageRoute(
          builder: (_) => _isInitialized
              ? AuthGate(child: const DashboardScreen())
              : _buildLoadingScaffold(),
        );
      },
    );
  }

  Widget _buildLoadingScaffold() {
    return const ClmMapsSplash();
  }
}

/// Stateful widget that resolves a share code and opens the map editor.
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

      // Load the map via the Firestore adapter
      final service = ShareableMapsFirestoreService();
      final container = riverpod.ProviderScope.containerOf(context);
      final unfinishedProvider = FlavorConfig.instance.isMaps
          ? null
          : container.read(unfinishedWorkAreasRiverpod);
      final adapter = FirestoreMapAdapter.existing(
        docId: linkData.mapId,
        monthKey: linkData.monthKey,
        service: service,
        unfinishedProvider: unfinishedProvider,
      );

      final provider = container.read(shareableMapRiverpod);
      await provider.loadFromAdapter(adapter);

      if (mounted) {
        // Replace the deep-link loader with the editor
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
      return const ClmMapsSplash();
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
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}

class DashboardScreen extends riverpod.ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  riverpod.ConsumerState<DashboardScreen> createState() =>
      _DashboardScreenState();
}

class _DashboardScreenState extends riverpod.ConsumerState<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentTabIndex = 0;
  bool _showAiChat = false;

  // Dynamic tab count based on flavor
  int get _tabCount {
    // CLM flavor: Schedule + Job List + Collection Schedule + Dropsheet + Happy Sun = 5 tabs
    // Dropsheet flavor: Dropsheet only = 1 tab
    // Happy Sun flavor: Happy Sun only = 1 tab (simplified for solar projects only)
    if (FlavorConfig.instance.isCLM) return 5;
    return 1;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      animationDuration: Duration.zero, // Remove tab animation
    );
    _tabController.addListener(_handleTabChange);

    // Initial setup complete
  }

  void _handleTabChange() {
    if (_tabController.index != _currentTabIndex) {
      setState(() {
        _currentTabIndex = _tabController.index;
      });
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    final isMediumScreen = MediaQuery.of(context).size.width < 900;

    return Scaffold(
        backgroundColor: const Color.fromARGB(255, 222, 222, 222),
        appBar: FlavorConfig.instance.isHappySun ||
                FlavorConfig.instance.isDropsheet
            ? null // No AppBar for Happy Sun or Dropsheet flavors (each tab provides its own header)
            : AppBar(
                leading: isSmallScreen
                    ? null
                    : const Padding(
                        padding: EdgeInsets.only(left: 16.0),
                        child: Center(
                          child: Text(
                            'CLM DASHBOARD',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                leadingWidth: isSmallScreen ? 0 : 200,
                automaticallyImplyLeading: false,
                backgroundColor: Theme.of(context).colorScheme.inversePrimary,
                title: TabBar(
                  controller: _tabController,
                  isScrollable: isSmallScreen, // Scrollable on mobile
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.black54,
                  indicatorColor: Colors.black,
                  dividerColor: Colors.transparent,
                  splashFactory: NoSplash.splashFactory,
                  overlayColor: WidgetStateProperty.all(Colors.transparent),
                  tabAlignment:
                      isSmallScreen ? TabAlignment.start : TabAlignment.fill,
                  labelPadding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 12 : 16,
                  ),
                  tabs: [
                    Tab(text: isSmallScreen ? 'Schedule' : 'Schedule'),
                    Tab(text: isSmallScreen ? 'Jobs' : 'Job List'),
                    Tab(
                        text: isSmallScreen
                            ? 'Collection'
                            : 'Collection Schedule'),
                    Tab(text: isSmallScreen ? 'Drop' : 'Dropsheet'),
                    Tab(text: isSmallScreen ? 'Solar' : 'Happy Sun'),
                  ],
                ),
                actions: [
                  // Track Editor
                  IconButton(
                    icon: const Icon(Icons.route),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TrackEditorScreen(),
                        ),
                      );
                    },
                    tooltip: 'Track Editor',
                  ),
                  // Shareable Maps - open gallery / dashboard
                  IconButton(
                    icon: const Icon(Icons.map_outlined),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ShareableMapsGallery(),
                        ),
                      );
                    },
                    tooltip: 'My Maps',
                  ),
                  // Work Areas - open map editor with all work area polygons
                  IconButton(
                    icon: const Icon(Icons.layers),
                    onPressed: () async {
                      final provider =
                          riverpod.ProviderScope.containerOf(context)
                              .read(shareableMapRiverpod);
                      try {
                        await provider
                            .loadFromAdapter(WorkAreaCollectionAdapter());
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ShareableMapEditor(),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to load work areas: $e'),
                              backgroundColor: Colors.red.shade800,
                            ),
                          );
                        }
                      }
                    },
                    tooltip: 'Edit Work Areas',
                  ),
                  // Geocoding tool
                  IconButton(
                    icon: const Icon(Icons.location_searching),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SuburbListScreen(),
                        ),
                      );
                    },
                    tooltip: 'Geocoding Tool',
                  ),
                  // Distributor management - always visible
                  if (!isMediumScreen)
                    IconButton(
                      icon: const Icon(Icons.people),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              const DistributorManagementDialog(),
                        );
                      },
                      tooltip: 'Manage Distributors',
                    ),
                  IconButton(
                    icon: const Icon(Icons.location_city),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ErfPropertyScreen(),
                        ),
                      );
                    },
                    tooltip: 'ERF Property Viewer',
                  ),
                  // Settings menu - always visible
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.settings),
                    tooltip: 'Settings',
                    onSelected: (String value) async {
                      if (value == 'distributors' && isMediumScreen) {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              const DistributorManagementDialog(),
                        );
                      } else if (value == 'scale') {
                        showDialog(
                          context: context,
                          builder: (context) => const ScaleSettingsDialog(),
                        );
                      } else if (value == 'status') {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              const JobStatusManagementDialog(),
                        );
                      } else if (value == 'job_list_status') {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              const JobListStatusManagementDialog(),
                        );
                      } else if (value == 'invoice_status') {
                        showDialog(
                          context: context,
                          builder: (context) =>
                              const InvoiceStatusManagementDialog(),
                        );
                      } else if (value == 'job_types') {
                        showDialog(
                          context: context,
                          builder: (context) => const JobTypeManagementDialog(),
                        );
                      } else if (value == 'signout') {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Sign Out'),
                            content: const Text(
                                'Are you sure you want to sign out?'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Sign Out'),
                              ),
                            ],
                          ),
                        );

                        if (confirmed == true && context.mounted) {
                          await riverpod.ProviderScope.containerOf(context)
                              .read(authRiverpod)
                              .signOut();
                        }
                      }
                    },
                    itemBuilder: (BuildContext context) => [
                      // Add Distributors to menu on mobile/tablet
                      if (isMediumScreen)
                        const PopupMenuItem<String>(
                          value: 'distributors',
                          child: ListTile(
                            leading: Icon(Icons.people),
                            title: Text('Manage Distributors'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      if (isMediumScreen) const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: 'scale',
                        child: ListTile(
                          leading: Icon(Icons.zoom_in),
                          title: Text('Interface Scale'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'status',
                        child: ListTile(
                          leading: Icon(Icons.label),
                          title: Text('Job Statuses'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'job_list_status',
                        child: ListTile(
                          leading: Icon(Icons.list_alt),
                          title: Text('Job List Statuses'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'invoice_status',
                        child: ListTile(
                          leading: Icon(Icons.receipt),
                          title: Text('Invoice Statuses'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'job_types',
                        child: ListTile(
                          leading: Icon(Icons.category),
                          title: Text('Job Types'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: 'signout',
                        child: ListTile(
                          leading: Icon(Icons.logout, color: Colors.red),
                          title: Text('Sign Out',
                              style: TextStyle(color: Colors.red)),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        body: Stack(
          children: [
            // Main content fills the entire area
            IndexedStack(
              index: _currentTabIndex,
              children: [
                // CLM flavor has all tabs: Schedule, Job List, Collection Schedule, Dropsheet, Happy Sun
                if (FlavorConfig.instance.isCLM) ...[
                  const ScheduleTab(),
                  const JobListTab(),
                  const CollectionScheduleTab(),
                  const DropsheetTab(),
                  const HappySunTab(),
                ],
                // Dropsheet flavor only has the Dropsheet tab
                if (FlavorConfig.instance.isDropsheet)
                  const SafeArea(child: DropsheetTab()),
                // Happy Sun flavor only has Happy Sun tab (Job List filtered in background)
                // Wrap in SafeArea to avoid system UI overlays (status bar, navigation bar)
                if (FlavorConfig.instance.isHappySun)
                  const SafeArea(
                    child: HappySunTab(),
                  ),
              ],
            ),
            // AI Chat panel floats above everything
            if (_showAiChat)
              Positioned(
                top: 8,
                bottom: 72,
                right: 8,
                width: MediaQuery.of(context).size.width * 0.20,
                child: Material(
                  elevation: 12,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: AiChatPanel(
                    onClose: () => setState(() => _showAiChat = false),
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: Builder(
          builder: (context) {
            final chatProvider = ref.watch(chatRiverpod);
            final authProvider = ref.watch(authRiverpod);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // AI Assistant FAB
                FloatingActionButton.small(
                  heroTag: 'ai_chat',
                  onPressed: () {
                    setState(() => _showAiChat = !_showAiChat);
                  },
                  tooltip: _showAiChat ? 'Close Pelisa' : 'Open Pelisa',
                  backgroundColor: _showAiChat
                      ? Colors.deepPurple.shade400
                      : Colors.deepPurple.shade600,
                  child: Icon(
                      _showAiChat ? Icons.close_rounded : Icons.auto_awesome,
                      color: Colors.white,
                      size: 20),
                ),
                const SizedBox(width: 8),
                // Team Chat FAB
                Stack(
                  children: [
                    GestureDetector(
                      onLongPress: authProvider.isAdmin
                          ? () {
                              showDialog(
                                context: context,
                                builder: (context) => const ChatAdminPanel(),
                              );
                            }
                          : null,
                      child: FloatingActionButton(
                        heroTag: 'team_chat',
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const ChatDialog(),
                          );
                        },
                        tooltip: authProvider.isAdmin
                            ? 'Chat (Long press for admin panel)'
                            : 'Team Chat',
                        child: const Icon(Icons.chat),
                      ),
                    ),
                    if (chatProvider.hasUnreadMessages)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          child: Text(
                            '${chatProvider.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ));
  }
}

class ScheduleTab extends riverpod.ConsumerStatefulWidget {
  const ScheduleTab({super.key});

  @override
  riverpod.ConsumerState<ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends riverpod.ConsumerState<ScheduleTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final scheduleProvider = ref.watch(scheduleRiverpod);
    final unfinishedProvider = ref.watch(unfinishedWorkAreasRiverpod);
    // No initialization needed - provider is preloaded in main.dart
    final isLoading =
        scheduleProvider.distributors.isEmpty && scheduleProvider.jobs.isEmpty;

    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: LazyLoadingIndicator(
                isLoading: isLoading,
                message: 'Loading Schedule...',
                child: isLoading
                    ? Container(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: const SizedBox.expand(),
                      )
                    : const ScheduleGrid(),
              ),
            ),
            // Unfinished Work Areas side panel
            if (unfinishedProvider.isPanelVisible)
              const UnfinishedWorkAreasPanel(),
          ],
        ),
      ],
    );
  }
}

class JobListTab extends riverpod.ConsumerStatefulWidget {
  const JobListTab({super.key});

  @override
  riverpod.ConsumerState<JobListTab> createState() => _JobListTabState();
}

class _JobListTabState extends riverpod.ConsumerState<JobListTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final jobListProvider = ref.watch(jobListRiverpod);
    // Show error state if there's an error
    if (jobListProvider.error != null && jobListProvider.isInitialized) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            Text(
              'Error loading Job List',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              jobListProvider.error!,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                // Retry by reinitializing
                jobListProvider.initialize();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Show loading state only if not initialized yet
    if (!jobListProvider.isInitialized) {
      return LazyLoadingIndicator(
        isLoading: true,
        message: 'Initializing Job List...',
        child: Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: const SizedBox.expand(),
        ),
      );
    }

    return const Stack(
      children: [
        JobListGrid(),
      ],
    );
  }
}

class CollectionScheduleTab extends riverpod.ConsumerStatefulWidget {
  const CollectionScheduleTab({super.key});

  @override
  riverpod.ConsumerState<CollectionScheduleTab> createState() =>
      _CollectionScheduleTabState();
}

class _CollectionScheduleTabState extends riverpod
    .ConsumerState<CollectionScheduleTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _hasInitialized = false;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final collectionProvider = ref.watch(collectionScheduleRiverpod);
    // Initialize the provider when the tab is first opened
    if (!_hasInitialized) {
      _hasInitialized = true;
      // Call initialize after the current frame to avoid calling during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        collectionProvider.initialize();
      });
    }

    final isLoading = collectionProvider.isLoading ||
        (!collectionProvider.isInitialized &&
            collectionProvider.collectionJobs.isEmpty);

    return Stack(
      children: [
        LazyLoadingIndicator(
          isLoading: isLoading,
          message: 'Loading Collection Schedule...',
          child: isLoading
              ? Container(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: const SizedBox.expand(),
                )
              : const CollectionScheduleGrid(),
        ),
      ],
    );
  }
}

class HappySunTab extends StatefulWidget {
  const HappySunTab({super.key});

  @override
  State<HappySunTab> createState() => _HappySunTabState();
}

class _HappySunTabState extends State<HappySunTab>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  late TabController _subTabController;

  @override
  void initState() {
    super.initState();
    _subTabController = TabController(
      length: 2,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _subTabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    return Column(
      children: [
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _subTabController,
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.blue,
            tabs: const [
              Tab(text: 'Projects'),
              Tab(text: 'Tools/Inventory'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _subTabController,
            children: const [
              HappySunJobProjectsScreen(),
              HappySunInventoryView(),
            ],
          ),
        ),
      ],
    );
  }
}

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 222, 222, 222),
      appBar: AppBar(
        leading: const Text(
          '  CLM DASHBOARD',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          children: [
            TextButton(onPressed: () {}, child: const Text("Job List"))
          ],
        ),
      ),
      body: const ScheduleGrid(),
    );
  }
}
