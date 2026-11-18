import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';

import 'package:clmschedule/letterbox/pages/letterbox_curation_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:package_info_plus/package_info_plus.dart';
import 'config/flavor_config.dart';
import 'providers/payroll_provider.dart' show payrollScheduleSyncRiverpod;
// import 'providers/toggler_provider.dart'; // Migrated to Riverpod
import 'providers/schedule_provider.dart';
import 'providers/collection_schedule_provider.dart';
import 'providers/job_list_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/inventory_provider.dart';
import 'providers/happy_sun_project_provider.dart';
import 'providers/job_status_provider.dart' show jobStatusRiverpod;
import 'providers/job_list_status_provider.dart' show jobListStatusRiverpod;
import 'providers/invoice_status_provider.dart' show invoiceStatusRiverpod;
// import 'providers/job_list_preferences_provider.dart'; // Migrated to Riverpod
import 'providers/auth_provider.dart';
// import 'providers/vehicle_driver_provider.dart'; // REMOVED: unused provider
// import 'providers/scale_provider.dart'; // Migrated to Riverpod
// import 'providers/map_view_provider.dart'; // Migrated to Riverpod
import 'providers/app_version_provider.dart';
import 'providers/tool_settings_provider.dart';
// import 'providers/job_type_provider.dart'; // Migrated to Riverpod
import 'providers/job_type_provider.dart'
    show JobTypeProvider, jobTypeRiverpod;
import 'providers/unfinished_work_areas_provider.dart';
import 'providers/day_off_provider.dart';
import 'shareable_maps/providers/shareable_map_provider.dart';
import 'shareable_maps/services/map_bitmap_cache.dart';
import 'shareable_maps/widgets/shareable_maps_gallery.dart';
import 'models/happy_sun_project.dart';
import 'models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData
import 'widgets/schedule_grid.dart';
import 'widgets/collection_schedule_grid.dart';
import 'widgets/job_list_grid.dart';
import 'widgets/job_list_status_views.dart';
import 'widgets/distributor_management_dialog.dart';
import 'widgets/lazy_loading_indicator.dart';
import 'widgets/scale_settings_dialog.dart';
import 'widgets/job_status_management_dialog.dart';
import 'widgets/job_list_status_management_dialog.dart';
import 'widgets/invoice_status_management_dialog.dart';
import 'widgets/job_type_management_dialog.dart';
import 'widgets/company_management_dialog.dart';
import 'widgets/map_instruction_management_dialog.dart';
import 'widgets/vat_settings_dialog.dart';
import 'widgets/auth_gate.dart';
import 'widgets/chat_dialog.dart';
import 'widgets/chat_admin_panel.dart';
import 'widgets/unfinished_work_areas_panel.dart';
import 'widgets/app_update_dialog.dart';
import 'widgets/happy_sun_inventory_view.dart';
import 'widgets/zoho/zoho_customers_view.dart';
import 'widgets/zoho/zoho_invoices_view.dart';
import 'widgets/zoho/zoho_table.dart';
import 'models/company.dart';
import 'utils/zoho_org.dart';
import 'widgets/happy_sun_job_projects_screen.dart';
import 'shareable_maps/widgets/shareable_map_editor.dart';
import 'shareable_maps/adapters/client_area_adapter.dart';
import 'shareable_maps/adapters/work_area_adapter.dart';
import 'shareable_maps/adapters/work_suburbs_adapter.dart';
import 'shareable_maps/adapters/firestore_adapter.dart';
import 'shareable_maps/services/shareable_maps_firestore_service.dart';
import 'shareable_maps/services/map_link_service.dart';
import 'shareable_maps/widgets/clm_maps_splash.dart';
import 'widgets/suburb_list_screen.dart';
import 'track_editor/pages/track_editor_screen.dart';
// TE provider imports migrated to Riverpod
// ErfPropertyProvider migrated to Riverpod
import 'erf_property/pages/erf_property_screen.dart';
import 'widgets/ward_map_screen.dart';
import 'widgets/regular_clients_screen.dart';
import 'widgets/weather/weather_screen.dart';
import 'widgets/fleet/fleet_screen.dart';
import 'widgets/fleet/inspection_alerts.dart';
import 'widgets/fleet/inspection_detail_page.dart';
import 'providers/inspection_alerts_provider.dart';
import 'models/vehicle_inspection.dart';

// import 'services/work_area_service.dart'; // Migrated to Riverpod
// import 'services/job_list_service.dart'; // Migrated to Riverpod
// import 'services/job_list_preferences_service.dart'; // Migrated to Riverpod
// import 'services/user_service.dart'; // Migrated to Riverpod
// import 'services/chat_service.dart'; // Migrated to Riverpod
// import 'services/ai_chat_service.dart'; // Migrated to Riverpod
// import 'providers/ai_chat_provider.dart'; // Migrated to Riverpod
import 'widgets/ai_chat_dialog.dart';
import 'widgets/dropsheet/dropsheet_tab.dart';
import 'widgets/payroll/payroll_tab.dart';
import 'widgets/cloud_file_manager_screen.dart';
import 'services/inventory_service.dart';
import 'services/connectivity_service.dart';
import 'services/storage_health.dart';
import 'services/sync_status.dart';
import 'widgets/sync_status_banner.dart';
import 'widgets/save_check_dialog.dart';
import 'utils/root_navigator.dart';
import 'services/happy_sun_local_storage.dart';
import 'services/happy_sun_sync_service.dart';
import 'services/inventory_local_storage.dart';
import 'services/image_cache_service.dart';
import 'services/inventory_sync_service.dart';
import 'firebase_options.dart';
import 'utils/web_reload.dart'
    if (dart.library.io) 'utils/web_reload_stub.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'shareable_maps/providers/map_gesture_provider.dart';
import 'recycle_bin/recycle_bin_screen.dart';
import 'undo/undo_history.dart';
import 'undo/undo_shortcuts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A full browser storage surfaces as QuotaExceededError from deep inside
  // Firebase, often in an error nobody catches — route every one past
  // StorageHealth so the banner can say why nothing saves.
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    StorageHealth.instance.noteError(details.exception);
    previousFlutterOnError?.call(details);
  };
  final previousPlatformOnError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    StorageHealth.instance.noteError(error);
    return previousPlatformOnError?.call(error, stack) ?? false;
  };
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Enable offline persistence on all platforms.
  if (kIsWeb) {
    // Web: multi-tab IndexedDB persistence, so every open tab shares ONE
    // cache. The SDK elects a primary tab that owns the network connection and
    // runs the listeners for all tabs; the others read from the shared cache,
    // so two tabs on the same schedule month cost one set of reads, not two.
    // (The default single-tab mode drops later tabs to a private memory cache
    // that re-reads everything — the reason web/index.html used to block them.)
    //
    // Must run before any Firestore call and must NOT be combined with
    // `settings =`: cloud_firestore_web 4.4 always sends a localCache with
    // settings, and the JS SDK then rejects this call. That means the web
    // cache uses the SDK default size (40 MB, LRU-collected) instead of
    // unlimited — docs under an active listener are never collected.
    try {
      await FirebaseFirestore.instance.enablePersistence(
        const PersistenceSettings(synchronizeTabs: true),
      );
    } catch (e) {
      // IndexedDB unavailable (private mode, old browser) or a hot restart —
      // the SDK keeps working on a memory cache.
      debugPrint('Firestore multi-tab persistence not enabled: $e');
    }
  } else {
    try {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    } catch (e) {
      // Settings may have already been applied, continue silently
      debugPrint('Firestore settings already configured: $e');
    }
  }

  // Preload shareable-map BitmapDescriptors (vertex, midpoint, firstVertex,
  // category icons, cluster icons, waypoint) before the first frame. The
  // editor consumes these synchronously when building markers, so any
  // mid-load mount caused a visible race where only some icons rendered.
  // Awaiting here adds <100ms to startup and is fully reused across all
  // shareable-map widgets for the rest of the session.
  try {
    await MapBitmapCache.instance.ensureLoaded();
    debugPrint('[WASM-DEBUG] MapBitmapCache preloaded at startup');
  } catch (e) {
    debugPrint('[WASM-DEBUG] MapBitmapCache preload failed: $e');
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
  bool _isInitialized = false;

  /// The update dialog is raised from outside the widget tree, so it needs a
  /// context that actually sits *below* MaterialApp — this state's own context
  /// is above it and has no Navigator.
  // Shared so toast buttons can open dialogs too (utils/root_navigator.dart).
  final GlobalKey<NavigatorState> _rootNavigatorKey = rootNavigatorKey;
  bool _updateDialogOpen = false;

  // Offline services for Happy Sun flavor
  ConnectivityService? _connectivityService;
  HappySunLocalStorage? _localStorage;
  HappySunSyncService? _syncService;

  // Inventory offline services for Happy Sun flavor
  InventoryLocalStorage? _inventoryLocalStorage;
  ImageCacheService? _imageCacheService;
  InventorySyncService? _inventorySyncService;
  AuthProvider? _authProviderForListener;
  bool _authenticatedProvidersInitialized = false;
  bool _authenticatedProvidersInitializing = false;

  @override
  void initState() {
    super.initState();
    // Before anything loads, so a slow first load is reported too.
    SyncStatus.instance.start();
    StorageHealth.instance.start();
    // Initialize all providers asynchronously in parallel
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeProvidersAsync();
    });
  }

  void _handleAuthStateForProviderInit() {
    final authProvider = _authProviderForListener;
    if (authProvider == null || !authProvider.isAuthenticated) return;

    unawaited(_initializeAuthenticatedProviders());
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
      projectRef: (jobListItem) async =>
          (JobTypeProvider.instance?.isHappySunService(jobListItem.jobTypeId) ??
                  false)
              ? happySunProjectProvider.findProjectRef(jobListItem.id)
              : null,
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

    final authProvider = ref.read(authRiverpod);
    await authProvider.initialize();
    _authProviderForListener = authProvider;
    authProvider.addListener(_handleAuthStateForProviderInit);

    if (authProvider.isAuthenticated) {
      // Don't hold the splash for data loads — the dashboard renders as soon
      // as auth is known and each provider notifies when its data lands. On a
      // second tab those reads route through the primary tab's connection, so
      // awaiting them here is what made new tabs feel slow.
      unawaited(_initializeAuthenticatedProviders());
    } else {
      debugPrint('Skipping Firestore provider initialization until sign-in.');
    }

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

  Future<void> _initializeAuthenticatedProviders() async {
    if (_authenticatedProvidersInitialized ||
        _authenticatedProvidersInitializing) {
      return;
    }

    _authenticatedProvidersInitializing = true;

    final List<Future<void>> initializations = [];

    // What the first screen shows goes first: listeners are sent to the
    // server in the order they open, so the schedule month and its status
    // colours no longer queue behind Happy Sun projects and inventory.
    if (FlavorConfig.instance.isCLM) {
      initializations.add(ref.read(scheduleRiverpod).initialize());
      // Reading a reference provider constructs it, which starts its load.
      // Left to the first JobCard / Job List build, the colours only began
      // loading after the jobs had arrived — the last thing to fill in.
      ref.read(jobStatusRiverpod);
      ref.read(jobTypeRiverpod);
      ref.read(jobListStatusRiverpod);
      ref.read(invoiceStatusRiverpod);
      initializations.add(ref.read(unfinishedWorkAreasRiverpod).initialize());
      ref.read(dayOffRiverpod).initialize();
    }

    // Set up Happy Sun sync for both flavors (both have Happy Sun features).
    // This reads HappySunProjectProvider, whose constructor opens Firestore streams.
    _setupHappySunSync();

    // JobListProvider is lazy-initialized — its Firestore stream only starts
    // when the Job List or Collection Schedule tab is first opened. This
    // avoids paying N reads (1 per job item) at login for users who never
    // visit those tabs.
    initializations.addAll([
      ref.read(inventoryRiverpod).initialize(),
      ref.read(toolSettingsRiverpod).loadSettings(),
    ]);

    // Run all provider initializations in parallel for fast startup.
    // Wrap in try/catch + timeout so a hanging network call (common on first
    // web load) never freezes the splash screen indefinitely.
    try {
      await Future.wait(initializations).timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('⚠️ Provider initialization error or timeout: $e');
      // Continue — the app can still function with partial initialization.
    } finally {
      _authenticatedProvidersInitialized = true;
      _authenticatedProvidersInitializing = false;
    }

    // Ensure lastCheckedTime is loaded now that auth is guaranteed ready
    try {
      await ref
          .read(jobListRiverpod)
          .ensureLastCheckedTimeLoaded()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('⚠️ ensureLastCheckedTimeLoaded error or timeout: $e');
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
    if (!mounted || _updateDialogOpen) return;

    final newVersion = versionProvider.currentVersion;
    final currentVersion = versionProvider.localVersion?.version ?? '0.0.0';

    if (newVersion == null) return;

    // Not `context`: this State sits above MaterialApp, so its context has no
    // Navigator and showDialog would throw — which is exactly why the update
    // prompt never appeared. The navigator key gives us a context inside the
    // app. It is null until the first frame is laid out, so retry next frame.
    final navigatorContext = _rootNavigatorKey.currentContext;
    if (navigatorContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && versionProvider.needsUpdate) {
          _showUpdateDialog(versionProvider);
        }
      });
      return;
    }

    _updateDialogOpen = true;
    try {
      final result = await showDialog<bool>(
        context: navigatorContext,
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
    } finally {
      _updateDialogOpen = false;
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
    _authProviderForListener?.removeListener(_handleAuthStateForProviderInit);
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
      navigatorKey: _rootNavigatorKey,
      navigatorObservers: [ref.read(mapModalObserverRiverpod)],
      debugShowCheckedModeBanner: false,
      // Toasts stay above the sync banner's column so they float over the
      // whole app, banner included.
      builder: (context, child) => AppToastHost.builder(
        context,
        SyncStatusBanner(child: child ?? const SizedBox.shrink()),
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor:
              FlavorConfig.instance.isHappySun ? Colors.orange : Colors.blue,
        ),
        useMaterial3: true,
      ),
      // One route per URL. Flutter's default splits '/admin/map?doc=..' into
      // '/', '/admin' and '/admin/map?..' and stacks all three, so every
      // map tab also booted two full dashboards underneath the map.
      onGenerateInitialRoutes: (initialRoute) =>
          [_generateRoute(RouteSettings(name: initialRoute))],
      onGenerateRoute: _generateRoute,
    );
  }

  Route<dynamic> _generateRoute(RouteSettings settings) {
    final uri = Uri.parse(settings.name ?? '');
    // Gallery "open in new tab": /admin/map?doc={docId}&month={monthKey}
    final docId = uri.queryParameters['doc'] ?? '';
    final monthKey = uri.queryParameters['month'] ?? '';
    if (uri.path == '/admin/map' && docId.isNotEmpty && monthKey.isNotEmpty) {
      return MaterialPageRoute(
        builder: (_) => _isInitialized
            ? AuthGate(
                child:
                    _DeepLinkMapLoader.byId(docId: docId, monthKey: monthKey))
            : _buildLoadingScaffold(),
      );
    }
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
  }

  Widget _buildLoadingScaffold() {
    return const ClmMapsSplash();
  }
}

/// Stateful widget that resolves a share code (or takes a map's Firestore
/// id/month directly) and opens the map editor.
class _DeepLinkMapLoader extends StatefulWidget {
  final String? shareCode;
  final String? docId;
  final String? monthKey;
  const _DeepLinkMapLoader({required String this.shareCode})
      : docId = null,
        monthKey = null;
  const _DeepLinkMapLoader.byId(
      {required String this.docId, required String this.monthKey})
      : shareCode = null;

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
      var docId = widget.docId;
      var monthKey = widget.monthKey;
      if (docId == null || monthKey == null) {
        final linkService = MapLinkService();
        final linkData = await linkService.resolveShareCode(widget.shareCode!);
        if (linkData == null) {
          setState(() {
            _loading = false;
            _error =
                'Map not found. The link may have expired or been deleted.';
          });
          return;
        }
        docId = linkData.mapId;
        monthKey = linkData.monthKey;
      }

      if (!mounted) return;

      // Load the map via the Firestore adapter
      final service = ShareableMapsFirestoreService();
      // listen: false — on the byId path this runs synchronously inside
      // initState, where a dependency lookup asserts in debug builds.
      final container =
          riverpod.ProviderScope.containerOf(context, listen: false);
      final unfinishedProvider = FlavorConfig.instance.isMaps
          ? null
          : container.read(unfinishedWorkAreasRiverpod);
      final adapter = FirestoreMapAdapter.existing(
        docId: docId,
        monthKey: monthKey,
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
              // A deep-link tab has nothing underneath to pop back to.
              onPressed: () {
                final navigator = Navigator.of(context);
                if (navigator.canPop()) {
                  navigator.pop();
                } else {
                  navigator.pushReplacementNamed('/');
                }
              },
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
  final _bodyNavKey = GlobalKey<NavigatorState>();

  /// Holds map gestures for dialogs pushed onto the nested Navigator
  /// (`useRootNavigator: false`); the root one has its own observer.
  late final _bodyNavMapObserver =
      MapModalGestureObserver(ref.read(mapGestureRiverpod));

  // Dynamic tab count based on flavor
  int get _tabCount {
    // CLM flavor: Schedule + Job List + Collection Schedule + Dropsheet +
    // Happy Sun + Payroll = 6 tabs
    // Dropsheet flavor: Dropsheet only = 1 tab
    // Happy Sun flavor: Happy Sun only = 1 tab (simplified for solar projects only)
    if (FlavorConfig.instance.isCLM) return 6;
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

  // Note: dismissing a pushed sub-page (Track Editor etc.) on tab change
  // is handled solely by the TabBar's `onTap` below — NOT here. `onTap`
  // fires on every tap (including re-tapping the already-selected tab),
  // strictly after this listener already ran for the same tap when the
  // index actually changed (TabController.animateTo updates the index and
  // calls notifyListeners synchronously before TabBar invokes onTap, since
  // this controller's animationDuration is zero). Calling popUntil from
  // both places back-to-back pops the same still-transitioning route
  // twice in one synchronous tick, which trips Navigator's reentrancy
  // guard and leaves `_bodyNavKey`'s Navigator locked — every subsequent
  // tab switch AND action-button push then silently does nothing (the
  // app-wide "freeze" this caused). Keep this listener to just track the
  // index for the guard above; the pop lives only in `onTap`.
  void _handleTabChange() {
    if (_tabController.index != _currentTabIndex) {
      setState(() {
        _currentTabIndex = _tabController.index;
      });
    }
  }

  // ── Tab helpers ────────────────────────────────────────────────────────────

  static const _tabConfigs = [
    (label: 'Schedule', icon: Icons.calendar_month, color: Color(0xFF1565C0)),
    (label: 'Job List', icon: Icons.list_alt, color: Color(0xFF2E7D32)),
    (label: 'Collection', icon: Icons.local_shipping, color: Color(0xFFE65100)),
    (
      label: 'Dropsheet',
      icon: Icons.assignment,
      color: Color.fromARGB(255, 0, 178, 197)
    ),
    (
      label: 'Happy Sun',
      icon: Icons.wb_sunny,
      color: Color.fromARGB(255, 231, 223, 0)
    ),
    (label: 'Payroll', icon: Icons.payments, color: Color(0xFF6A1B9A)),
  ];

  Widget _buildTab(int index) {
    final cfg = _tabConfigs[index];
    final isSelected = _tabController.index == index;
    final color = isSelected ? cfg.color : Colors.black;
    return Tab(
      height: 48,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(cfg.icon, size: 18, color: color),
          const SizedBox(height: 2),
          Text(
            cfg.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ── Action button helper ───────────────────────────────────────────────────

  void _openFleet() {
    _bodyNavKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const FleetScreen()),
    );
  }

  void _openInspection(VehicleInspection inspection) {
    final alerts = ref.read(inspectionAlertsRiverpod);
    _bodyNavKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => InspectionDetailPage(
          inspection: inspection,
          history: alerts.recent,
          depot: alerts.depot,
          service: alerts.service,
        ),
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    final fg = color ?? Colors.black;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 1),
              Text(
                label,
                style: TextStyle(
                    fontSize: 9,
                    color: fg,
                    height: 1.1,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keeps payroll in step with the schedule while an admin is signed in.
    if (FlavorConfig.instance.isCLM) ref.watch(payrollScheduleSyncRiverpod);
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
              title: ListenableBuilder(
                listenable: _tabController,
                builder: (context, _) => TabBar(
                  controller: _tabController,
                  // The SOLE place a tab tap dismisses a pushed sub-page
                  // (Track Editor etc.) — fires on every tap, even
                  // re-tapping the already-selected tab (unlike the
                  // TabController listener in _handleTabChange, which
                  // only fires when the index actually changes). Needed
                  // so tapping the CURRENT tab (e.g. "Payroll" while
                  // Track Editor is pushed on top of it) still dismisses
                  // the pushed sub-page in one click. See the comment on
                  // _handleTabChange for why this must NOT also be called
                  // from there (duplicate back-to-back popUntil calls
                  // locked the Navigator and froze the whole app).
                  onTap: (_) =>
                      _bodyNavKey.currentState?.popUntil((r) => r.isFirst),
                  isScrollable: isSmallScreen, // Scrollable on mobile
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.black,
                  indicatorColor: _tabConfigs[_tabController.index].color,
                  indicatorWeight: 3,
                  dividerColor: Colors.transparent,
                  splashFactory: NoSplash.splashFactory,
                  overlayColor: WidgetStateProperty.all(Colors.transparent),
                  tabAlignment:
                      isSmallScreen ? TabAlignment.start : TabAlignment.fill,
                  labelPadding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 8 : 12,
                  ),
                  tabs: List.generate(_tabCount, _buildTab),
                ),
              ),
              actions: [
                // Cloud Files
                _actionBtn(
                  icon: Icons.cloud,
                  label: 'Files',
                  onPressed: () {
                    final container =
                        riverpod.ProviderScope.containerOf(context);
                    _bodyNavKey.currentState?.push(
                      MaterialPageRoute(
                        builder: (_) => CloudFileManagerScreen(
                          onOpenInTrackEditor: (fileName, bytes, sourcePath) {
                            // Load file into update mode providers first
                            // (providers are root-scoped and always alive).
                            loadCloudFileIntoTrackEditor(
                              container: container,
                              fileName: fileName,
                              bytes: bytes,
                              sourcePath: sourcePath,
                            );
                            // Close file manager then open Track Editor.
                            _bodyNavKey.currentState
                              ?..pop()
                              ..push(MaterialPageRoute(
                                builder: (_) => const TrackEditorScreen(),
                              ));
                          },
                        ),
                      ),
                    );
                  },
                ),
                // Track Editor
                _actionBtn(
                  icon: Icons.route,
                  label: 'Editor',
                  onPressed: () {
                    _bodyNavKey.currentState?.push(
                      MaterialPageRoute(
                        builder: (_) => const TrackEditorScreen(),
                      ),
                    );
                  },
                ),
                // Shareable Maps - open gallery / dashboard
                _actionBtn(
                  icon: Icons.map_outlined,
                  label: 'My Maps',
                  onPressed: () {
                    _bodyNavKey.currentState?.push(
                      MaterialPageRoute(
                        builder: (_) => const ShareableMapsGallery(),
                      ),
                    );
                  },
                ),
                // Work Areas - open map editor with all work area polygons
                _actionBtn(
                  icon: Icons.layers,
                  label: 'Work Areas',
                  onPressed: () async {
                    final provider = riverpod.ProviderScope.containerOf(context)
                        .read(shareableMapRiverpod);
                    try {
                      await provider
                          .loadFromAdapter(WorkAreaCollectionAdapter());
                      if (context.mounted) {
                        _bodyNavKey.currentState?.push(
                          MaterialPageRoute(
                            builder: (_) => const ShareableMapEditor(),
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showToast(
                          SnackBar(
                            content: Text('Failed to load work areas: $e'),
                            backgroundColor: Colors.red.shade800,
                          ),
                        );
                      }
                    }
                  },
                ),

                // Client Maps - the client-facing twin of Work Areas
                _actionBtn(
                  icon: Icons.business_center_outlined,
                  label: 'Client Maps',
                  onPressed: () async {
                    final provider = riverpod.ProviderScope.containerOf(context)
                        .read(shareableMapRiverpod);
                    try {
                      await provider
                          .loadFromAdapter(ClientAreaCollectionAdapter());
                      if (context.mounted) {
                        _bodyNavKey.currentState?.push(
                          MaterialPageRoute(
                            builder: (_) => const ShareableMapEditor(),
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showToast(
                          SnackBar(
                            content: Text('Failed to load client maps: $e'),
                            backgroundColor: Colors.red.shade800,
                          ),
                        );
                      }
                    }
                  },
                ),

                // Work Suburbs - open map editor with single-document suburb polygons
                _actionBtn(
                  icon: Icons.layers_outlined,
                  label: 'Suburbs',
                  onPressed: () async {
                    final provider = riverpod.ProviderScope.containerOf(context)
                        .read(shareableMapRiverpod);
                    try {
                      await provider.loadFromAdapter(WorkSuburbsAdapter());
                      if (context.mounted) {
                        _bodyNavKey.currentState?.push(
                          MaterialPageRoute(
                            builder: (_) => const ShareableMapEditor(),
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showToast(
                          SnackBar(
                            content: Text('Failed to load work suburbs: $e'),
                            backgroundColor: Colors.red.shade800,
                          ),
                        );
                      }
                    }
                  },
                ),

                // Distributor management - always visible
                if (!isMediumScreen)
                  _actionBtn(
                    icon: Icons.people,
                    label: 'Staff',
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) =>
                            const DistributorManagementDialog(),
                      );
                    },
                  ),

                // Fleet — admins only; badged with inspections to review.
                FleetAlertButton(onPressed: _openFleet),

                // Apps menu — Pelisa, team chat, and less-frequently-used
                // tools. Scoped in a Consumer so unread-count changes
                // rebuild only this button, not the whole dashboard.
                riverpod.Consumer(
                  builder: (context, appsRef, _) {
                    final chatProvider = appsRef.watch(chatRiverpod);
                    final authProvider = appsRef.watch(authRiverpod);
                    final unread = chatProvider.hasUnreadMessages
                        ? chatProvider.unreadCount
                        : 0;

                    return PopupMenuButton<String>(
                      tooltip: 'Apps',
                      offset: const Offset(0, 48),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.apps,
                                    size: 20, color: Color(0xFF202124)),
                                SizedBox(height: 1),
                                Text('Apps',
                                    style: TextStyle(
                                        fontSize: 9,
                                        color: Color(0xFF202124),
                                        height: 1.1)),
                              ],
                            ),
                          ),
                          // Unread chat is otherwise invisible once the
                          // chat button lives inside a closed menu.
                          if (unread > 0)
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
                                    minWidth: 16, minHeight: 16),
                                child: Text(
                                  '$unread',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      onSelected: (String value) {
                        if (value == 'pelisa') {
                          setState(() => _showAiChat = !_showAiChat);
                        } else if (value == 'team_chat') {
                          showDialog(
                            context: context,
                            builder: (context) => const ChatDialog(),
                          );
                        } else if (value == 'chat_admin') {
                          showDialog(
                            context: context,
                            builder: (context) => const ChatAdminPanel(),
                          );
                        } else if (value == 'geocode') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const SuburbListScreen()),
                          );
                        } else if (value == 'erf') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const AuthGate(child: ErfPropertyScreen())),
                          );
                        } else if (value == 'regular_clients') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const RegularClientsScreen()),
                          );
                        } else if (value == 'weather') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const WeatherScreen()),
                          );
                        } else if (value == 'fleet') {
                          _openFleet();
                        } else if (value == 'ward_maps') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const WardMapScreen()),
                          );
                        } else if (value == 'Letterbox Indexing') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const LetterboxCurationPage()),
                          );
                        } else if (value == 'recycle_bin') {
                          _bodyNavKey.currentState?.push(
                            MaterialPageRoute(
                                builder: (_) => const RecycleBinScreen()),
                          );
                        }
                      },
                      itemBuilder: (BuildContext context) => [
                        PopupMenuItem<String>(
                          value: 'pelisa',
                          child: ListTile(
                            leading: Icon(
                              _showAiChat
                                  ? Icons.close_rounded
                                  : Icons.auto_awesome,
                              color: Colors.deepPurple.shade600,
                            ),
                            title: Text(
                                _showAiChat ? 'Close Pelisa' : 'Open Pelisa'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'team_chat',
                          child: ListTile(
                            leading: const Icon(Icons.chat),
                            title: const Text('Team Chat'),
                            trailing: unread == 0
                                ? null
                                : Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$unread',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        // Was a long-press on the chat FAB, which a popup
                        // menu cannot offer — promoted to its own entry.
                        if (authProvider.isAdmin)
                          const PopupMenuItem<String>(
                            value: 'chat_admin',
                            child: ListTile(
                              leading: Icon(Icons.admin_panel_settings),
                              title: Text('Chat Admin Panel'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<String>(
                          value: 'weather',
                          child: ListTile(
                            leading: Icon(Icons.wb_sunny_outlined),
                            title: Text('Weather'),
                            subtitle: Text(
                              '9-day forecast for distribution (yr.no)',
                              style: TextStyle(fontSize: 11),
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'fleet',
                          child: ListTile(
                            leading: Icon(Icons.fact_check_outlined),
                            title: Text('Fleet'),
                            subtitle: Text(
                              'Daily vehicle inspections from clmgpx',
                              style: TextStyle(fontSize: 11),
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'geocode',
                          child: ListTile(
                            leading: Icon(Icons.route_outlined),
                            title: Text('Geocoding & Routes'),
                            subtitle: Text(
                              'Locate addresses, optimise runs, export KML',
                              style: TextStyle(fontSize: 11),
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'erf',
                          child: ListTile(
                            leading: Icon(Icons.location_city),
                            title: Text('ERF Property Viewer'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'regular_clients',
                          child: ListTile(
                            leading: Icon(Icons.groups_outlined),
                            title: Text('Regular Clients'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'ward_maps',
                          child: ListTile(
                            leading: Icon(Icons.how_to_vote_outlined),
                            title: Text('SA Ward Mapper'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'Letterbox Indexing',
                          child: ListTile(
                            leading: Icon(Icons.house_outlined),
                            title: Text('Letterbox Indexing'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<String>(
                          value: 'recycle_bin',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Recycle Bin'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    );
                  },
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
                        builder: (context) => const JobStatusManagementDialog(),
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
                    } else if (value == 'vat_settings') {
                      showDialog(
                        context: context,
                        builder: (context) => const VatSettingsDialog(),
                      );
                    } else if (value == 'job_types') {
                      showDialog(
                        context: context,
                        builder: (context) => const JobTypeManagementDialog(),
                      );
                    } else if (value == 'companies') {
                      showDialog(
                        context: context,
                        builder: (context) => const CompanyManagementDialog(),
                      );
                    } else if (value == 'save_check') {
                      showSaveCheckDialog(context);
                    } else if (value == 'map_instructions') {
                      showDialog(
                        context: context,
                        builder: (context) =>
                            const MapInstructionManagementDialog(),
                      );
                    } else if (value == 'signout') {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Sign Out'),
                          content:
                              const Text('Are you sure you want to sign out?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
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
                      value: 'vat_settings',
                      child: ListTile(
                        leading: Icon(Icons.percent),
                        title: Text('VAT Settings'),
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
                    const PopupMenuItem<String>(
                      value: 'companies',
                      child: ListTile(
                        leading: Icon(Icons.business),
                        title: Text('Companies'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'map_instructions',
                      child: ListTile(
                        leading: Icon(Icons.library_books_outlined),
                        title: Text('Map Instructions'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    // Web only: tests Chrome's Save dialog on this PC.
                    if (kIsWeb)
                      const PopupMenuItem<String>(
                        value: 'save_check',
                        child: ListTile(
                          leading: Icon(Icons.save_alt),
                          title: Text('Check saving files'),
                          subtitle: Text(
                            "Test this computer's Save dialog",
                            style: TextStyle(fontSize: 11),
                          ),
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
          // Nested Navigator — sub-pages render here so the AppBar above
          // stays visible on every screen. ListenableBuilder wires
          // _tabController into the Navigator's isolated element tree
          // (outer setState does not propagate through Navigator boundaries).
          Navigator(
            key: _bodyNavKey,
            observers: [_bodyNavMapObserver],
            onGenerateRoute: (_) => MaterialPageRoute(
              builder: (_) => ListenableBuilder(
                listenable: _tabController,
                builder: (_, __) => IndexedStack(
                  index: _tabController.index,
                  children: [
                    if (FlavorConfig.instance.isCLM) ...[
                      const ScheduleTab(),
                      const JobListTab(),
                      const CollectionScheduleTab(),
                      const DropsheetTab(),
                      const HappySunTab(),
                      const _PayrollTabGate(),
                    ],
                    if (FlavorConfig.instance.isDropsheet)
                      const SafeArea(child: DropsheetTab()),
                    if (FlavorConfig.instance.isHappySun)
                      const SafeArea(child: HappySunTab()),
                  ],
                ),
              ),
            ),
          ),
          // Morning vehicle inspections as drivers submit them (admins).
          Positioned(
            top: 8,
            right: 8,
            width: isSmallScreen ? MediaQuery.of(context).size.width - 16 : 380,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height - 140),
              child: InspectionAlertCards(
                onReview: _openInspection,
                onOpenFleet: _openFleet,
              ),
            ),
          ),
          // AI Chat panel floats above everything
          if (_showAiChat)
            Positioned(
              top: 8,
              // Was 72 to clear the chat/Pelisa FABs, which have moved to
              // the Apps menu — the panel can now use the full height.
              bottom: 8,
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
      // Pelisa and Team Chat used to live here as FABs; both now sit in the
      // Apps menu in the app bar, with the unread badge carried across.
    );
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

    return UndoShortcuts(
      undoKey: UndoKey.schedule,
      child: Stack(
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
      ),
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

  bool _hasInitialized = false;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final jobListProvider = ref.watch(jobListRiverpod);

    // Lazy-initialize: start the Firestore stream only when this tab is
    // first opened, not at login, to avoid unnecessary reads for users who
    // never visit the Job List tab.
    if (!_hasInitialized) {
      _hasInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        jobListProvider.initialize();
      });
    }
    // Nothing to show yet and loading failed (or is reconnecting): a full
    // screen. With data on screen, problems go in a banner instead, so the
    // list stays usable.
    final hasItems = jobListProvider.allJobListItems.isNotEmpty;
    if (jobListProvider.isInitialized &&
        !hasItems &&
        (jobListProvider.error != null || jobListProvider.isReconnecting)) {
      return JobListLoadProblem(
        reconnecting: jobListProvider.isReconnecting,
        message: jobListProvider.error,
        detail: jobListProvider.errorDetail,
        onRetry: jobListProvider.resetAndInitialize,
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

    return Column(
      children: [
        if (jobListProvider.isReconnecting)
          JobListStatusBanner(
            icon: Icons.sync,
            color: Colors.blue.shade700,
            busy: true,
            message: 'Reconnecting to the Job List… You are seeing the last '
                "loaded jobs; changes made elsewhere will appear once it's "
                'back.',
          )
        else if (jobListProvider.error != null)
          JobListStatusBanner(
            icon: Icons.cloud_off,
            color: Colors.orange.shade800,
            message: '${jobListProvider.error} You are seeing the last '
                'loaded jobs.',
            detail: jobListProvider.errorDetail,
            actionLabel: 'Try again',
            onAction: jobListProvider.resetAndInitialize,
          ),
        if (jobListProvider.actionError != null)
          JobListStatusBanner(
            icon: Icons.error_outline,
            color: Colors.red.shade700,
            message: jobListProvider.actionError!,
            detail: jobListProvider.actionErrorDetail,
            onDismiss: jobListProvider.clearActionError,
          ),
        const Expanded(
          child: UndoShortcuts(
            undoKey: UndoKey.jobList,
            child: JobListGrid(),
          ),
        ),
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
          child: const CollectionScheduleGrid(),
        ),
      ],
    );
  }
}

/// Gates [PayrollTab] behind admin access — wages and bank details are
/// sensitive, so non-admins see a restricted message instead of the tab
/// content. The tab itself stays in the tab bar for every CLM user since
/// the [TabController] length is fixed at construction (see [_tabCount]);
/// only the content is access-controlled.
class _PayrollTabGate extends riverpod.ConsumerWidget {
  const _PayrollTabGate();

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final authProvider = ref.watch(authRiverpod);
    if (!authProvider.isAdmin) {
      return const Center(
        child: Text('Payroll is only available to admins.'),
      );
    }
    return const PayrollTab();
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
      length: 4,
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
            // Invoices and Customers are Happy Sun's own Zoho Books
            // organisation — separate from Junk & Stuff's, under one login.
            isScrollable: MediaQuery.sizeOf(context).width < 600,
            tabs: const [
              Tab(text: 'Projects'),
              Tab(text: 'Tools/Inventory'),
              Tab(text: 'Invoices'),
              Tab(text: 'Customers'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _subTabController,
            children: [
              const HappySunJobProjectsScreen(),
              const HappySunInventoryView(),
              ZohoPanel(
                child: ZohoInvoicesView(
                    orgId: ZohoOrg.forCompanyId(Company.happySunId)),
              ),
              ZohoPanel(
                child: ZohoCustomersView(
                    orgId: ZohoOrg.forCompanyId(Company.happySunId)),
              ),
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
