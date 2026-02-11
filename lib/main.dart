import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'providers/toggler_provider.dart';
import 'providers/schedule_provider.dart';
import 'providers/collection_schedule_provider.dart';
import 'providers/job_list_provider.dart';
import 'providers/job_status_provider.dart';
import 'providers/job_list_status_provider.dart';
import 'providers/invoice_status_provider.dart';
import 'providers/job_list_preferences_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/vehicle_driver_provider.dart';
import 'providers/scale_provider.dart';
import 'providers/map_view_provider.dart';
import 'providers/inventory_provider.dart';
import 'providers/happy_sun_project_provider.dart';
import 'providers/app_version_provider.dart';
import 'providers/tool_settings_provider.dart';
import 'models/job_list_item.dart';
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
import 'widgets/auth_gate.dart';
import 'widgets/chat_dialog.dart';
import 'widgets/chat_admin_panel.dart';
import 'widgets/app_update_dialog.dart';
import 'widgets/happy_sun_inventory_view.dart';
import 'widgets/happy_sun_job_projects_screen.dart';
import 'services/version_service.dart';
import 'utils/seed_data.dart';
import 'services/work_area_service.dart';
import 'services/job_list_service.dart';
import 'services/job_list_preferences_service.dart';
import 'services/user_service.dart';
import 'services/chat_service.dart';
import 'services/inventory_service.dart';
import 'models/command.dart';
import 'firebase_options.dart';
import 'utils/web_reload.dart'
    if (dart.library.io) 'utils/web_reload_stub.dart';

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

  runApp(MultiProvider(providers: [
    // Authentication Provider (must be first for initialization)
    ChangeNotifierProvider(create: (context) => AuthProvider()),

    ChangeNotifierProvider(create: (context) => ScheduleProvider()),
    ChangeNotifierProvider(create: (context) => ScaleProvider()),
    ChangeNotifierProvider(create: (context) => VehicleDriverProvider()),
    ChangeNotifierProvider(create: (context) => MapViewProvider()),
    ChangeNotifierProvider(
      create: (context) => TogglerProvider(),
    ),

    Provider(
      create: (context) => WorkAreaService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => JobListService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) =>
          JobListPreferencesService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => UserService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => ChatService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => InventoryService(FirebaseFirestore.instance),
    ),
    ChangeNotifierProvider(
      create: (context) => JobStatusProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => JobListStatusProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => InvoiceStatusProvider(),
    ),
    ChangeNotifierProxyProvider<AuthProvider, JobListPreferencesProvider>(
      create: (context) => JobListPreferencesProvider(
        context.read<JobListPreferencesService>(),
        context.read<AuthProvider>(),
      ),
      update: (context, authProvider, previous) =>
          previous ??
          JobListPreferencesProvider(
            context.read<JobListPreferencesService>(),
            authProvider,
          ),
    ),
    ChangeNotifierProxyProvider<AuthProvider, JobListProvider>(
      create: (context) => JobListProvider(
        context.read<JobListService>(),
        context.read<AuthProvider>(),
      ),
      update: (context, authProvider, previous) =>
          previous ??
          JobListProvider(
            context.read<JobListService>(),
            authProvider,
          ),
    ),
    ChangeNotifierProxyProvider2<ChatService, AuthProvider, ChatProvider>(
      create: (context) => ChatProvider(
        context.read<ChatService>(),
        context.read<AuthProvider>(),
      ),
      update: (context, chatService, authProvider, previous) =>
          previous ??
          ChatProvider(
            chatService,
            authProvider,
          ),
    ),
    // CollectionScheduleProvider no longer automatically updates with JobListProvider changes
    // It uses lazy loading - only loads data when tab is opened
    ChangeNotifierProxyProvider<JobListProvider, CollectionScheduleProvider>(
      create: (context) => CollectionScheduleProvider(
        jobListProvider: context.read<JobListProvider>(),
      ),
      update: (context, jobListProvider, previous) {
        // Always return the existing instance to prevent rebuilds on every JobListProvider change
        // Collection schedule will manually refresh when needed via refresh() method
        return previous!;
      },
    ),
    ChangeNotifierProvider(
      create: (context) => InventoryProvider(
        context.read<InventoryService>(),
      ),
    ),
    ChangeNotifierProvider(
      create: (context) => HappySunProjectProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => ToolSettingsProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => AppVersionProvider(),
    ),
  ], child: const MyApp()));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final VersionService _versionService;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _versionService = VersionService(FirebaseFirestore.instance);
    // Initialize all providers asynchronously in parallel
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeProvidersAsync();
      _setupHappySunSync();
    });
  }

  void _setupHappySunSync() {
    // Set up callbacks to sync Happy Sun projects with Job List items
    final jobListProvider = context.read<JobListProvider>();
    final happySunProjectProvider = context.read<HappySunProjectProvider>();
    final toolSettingsProvider = context.read<ToolSettingsProvider>();
    final inventoryProvider = context.read<InventoryProvider>();

    jobListProvider.setHappySunCallbacks(
      onAdded: (jobListItem) async {
        try {
          debugPrint('\n🌞 ========== HAPPY SUN SYNC TRIGGERED ==========');
          debugPrint('🔵 Happy Sun Sync onAdded callback');
          debugPrint('   Job List Item ID: ${jobListItem.id}');
          debugPrint('   Client: ${jobListItem.client}');
          debugPrint('   Job Type: ${jobListItem.jobType.displayName}');
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

          // Determine job type
          final jobType = jobListItem.jobType == JobType.windowCleaning
              ? 'windowCleaning'
              : 'solarPanelCleaning';

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
              (newItem.jobType == JobType.windowCleaning ||
                  newItem.jobType == JobType.solarPanelCleaning)) {
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
          // Delete corresponding HappySunProject when window/solar cleaning job is deleted
          if (jobListItem.jobType == JobType.windowCleaning ||
              jobListItem.jobType == JobType.solarPanelCleaning) {
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

    // Run all provider initializations in parallel for fast startup
    await Future.wait([
      context.read<AuthProvider>().initialize(),
      context.read<ScheduleProvider>().initialize(),
      context.read<JobListProvider>().initialize(),
      context.read<InventoryProvider>().initialize(),
      context.read<ToolSettingsProvider>().loadSettings(),
      // CollectionScheduleProvider loads lazily when tab opens (depends on JobListProvider data)
    ]);

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
    final versionProvider = context.read<AppVersionProvider>();

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
    final versionProvider = context.read<AppVersionProvider>();

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CLM DASHBOARD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: _isInitialized
          ? AuthGate(
              child: const DashboardScreen(),
            )
          : const Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Loading CLM Dashboard...',
                      style: TextStyle(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
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
        appBar: AppBar(
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
              Tab(text: isSmallScreen ? 'Collection' : 'Collection Schedule'),
              Tab(text: isSmallScreen ? 'Solar' : 'Happy Sun'),
            ],
          ),
          actions: [
            // Distributor management - always visible
            if (!isMediumScreen)
              IconButton(
                icon: const Icon(Icons.people),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => const DistributorManagementDialog(),
                  );
                },
                tooltip: 'Manage Distributors',
              ),
            // Hide debug/seed buttons on mobile
            if (!isSmallScreen) ...[
              IconButton(
                icon: const Icon(Icons.data_array),
                onPressed: () async {},
                tooltip: 'Add sample schedule data',
              ),
              IconButton(
                icon: const Icon(Icons.list_alt),
                onPressed: () async {},
                tooltip: 'Add sample job list data',
              ),
              IconButton(
                icon: const Icon(Icons.map),
                onPressed: () async {
                  final workAreaService = context.read<WorkAreaService>();
                  try {
                    final workAreas = await workAreaService.createFromKml(
                      'craig.kml',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Imported ${workAreas.length} work areas from KML file',
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error importing KML data: $e')),
                      );
                    }
                  }
                },
                tooltip: 'Import KML data',
              ),
            ],
            // Settings menu - always visible
            PopupMenuButton<String>(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onSelected: (String value) async {
                if (value == 'distributors' && isMediumScreen) {
                  showDialog(
                    context: context,
                    builder: (context) => const DistributorManagementDialog(),
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
                    builder: (context) => const JobListStatusManagementDialog(),
                  );
                } else if (value == 'invoice_status') {
                  showDialog(
                    context: context,
                    builder: (context) => const InvoiceStatusManagementDialog(),
                  );
                } else if (value == 'signout') {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Sign Out'),
                      content: const Text('Are you sure you want to sign out?'),
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
                    await context.read<AuthProvider>().signOut();
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
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'signout',
                  child: ListTile(
                    leading: Icon(Icons.logout, color: Colors.red),
                    title:
                        Text('Sign Out', style: TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: IndexedStack(
          index: _currentTabIndex,
          children: [
            const ScheduleTab(),
            const JobListTab(),
            const CollectionScheduleTab(),
            const HappySunTab(),
          ],
        ),
        floatingActionButton: Consumer2<ChatProvider, AuthProvider>(
          builder: (context, chatProvider, authProvider, child) {
            return Stack(
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
            );
          },
        ));
  }
}

class ScheduleTab extends StatefulWidget {
  const ScheduleTab({super.key});

  @override
  State<ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<ScheduleTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    return Consumer<ScheduleProvider>(
      builder: (context, scheduleProvider, child) {
        // No initialization needed - provider is preloaded in main.dart
        final isLoading = scheduleProvider.distributors.isEmpty &&
            scheduleProvider.jobs.isEmpty;

        return Stack(
          children: [
            LazyLoadingIndicator(
              isLoading: isLoading,
              message: 'Loading Schedule...',
              child: isLoading
                  ? Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const SizedBox.expand(),
                    )
                  : const ScheduleGrid(),
            ),
          ],
        );
      },
    );
  }
}

class JobListTab extends StatefulWidget {
  const JobListTab({super.key});

  @override
  State<JobListTab> createState() => _JobListTabState();
}

class _JobListTabState extends State<JobListTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    return Consumer<JobListProvider>(
      builder: (context, jobListProvider, child) {
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
      },
    );
  }
}

class CollectionScheduleTab extends StatefulWidget {
  const CollectionScheduleTab({super.key});

  @override
  State<CollectionScheduleTab> createState() => _CollectionScheduleTabState();
}

class _CollectionScheduleTabState extends State<CollectionScheduleTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _hasInitialized = false;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Consumer<CollectionScheduleProvider>(
      builder: (context, collectionProvider, child) {
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
      },
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
        actions: [
          IconButton(
            icon: const Icon(Icons.data_array),
            onPressed: () async {
              try {
                await seedData();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sample data added successfully!'),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error adding sample data: $e')),
                  );
                }
              }
            },
            tooltip: 'Add sample data',
          ),
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: () async {
              final workAreaService = context.read<WorkAreaService>();
              try {
                final workAreas = await workAreaService.createFromKml(
                  'craig.kml',
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Imported ${workAreas.length} work areas from KML file',
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error importing KML data: $e')),
                  );
                }
              }
            },
            tooltip: 'Import KML data',
          ),
        ],
      ),
      body: const ScheduleGrid(),
    );
  }
}
