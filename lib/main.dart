import 'package:clmschedule/providers/toggler_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'providers/schedule_provider.dart';
import 'providers/collection_schedule_provider.dart';
import 'providers/job_list_provider.dart';
import 'providers/job_status_provider.dart';
import 'providers/job_list_status_provider.dart';
import 'providers/scale_provider.dart';
import 'providers/auth_provider.dart';
import 'widgets/schedule_grid.dart';
import 'widgets/collection_schedule_grid.dart';
import 'widgets/job_list_grid.dart';
import 'widgets/distributor_management_dialog.dart';
import 'widgets/lazy_loading_indicator.dart';
import 'widgets/scale_settings_dialog.dart';
import 'widgets/job_status_management_dialog.dart';
import 'widgets/job_list_status_management_dialog.dart';
import 'widgets/undo_redo_widgets.dart';
import 'widgets/auth_gate.dart';
import 'services/keyboard_shortcuts_service.dart';
import 'services/undo_redo_manager.dart';
import 'utils/seed_data.dart';
import 'services/work_area_service.dart';
import 'services/job_list_service.dart';
import 'services/user_service.dart';
import 'models/command.dart';
import 'firebase_options.dart';

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
    ChangeNotifierProvider(create: (context) => UndoRedoManager()),
    ChangeNotifierProxyProvider<UndoRedoManager, ScheduleProvider>(
      create: (context) =>
          ScheduleProvider(undoRedoManager: context.read<UndoRedoManager>()),
      update: (context, undoRedoManager, previous) =>
          previous ?? ScheduleProvider(undoRedoManager: undoRedoManager),
    ),
    ChangeNotifierProvider(create: (context) => ScaleProvider()),
    ChangeNotifierProvider(
      create: (context) => TogglerProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => JobStatusProvider(),
    ),
    ChangeNotifierProvider(
      create: (context) => JobListStatusProvider(),
    ),
    Provider(
      create: (context) => WorkAreaService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => JobListService(FirebaseFirestore.instance),
    ),
    Provider(
      create: (context) => UserService(FirebaseFirestore.instance),
    ),
    ChangeNotifierProxyProvider<UndoRedoManager, JobListProvider>(
      create: (context) => JobListProvider(
        context.read<JobListService>(),
        context.read<UndoRedoManager>(),
      ),
      update: (context, undoRedoManager, previous) =>
          previous ??
          JobListProvider(
            context.read<JobListService>(),
            undoRedoManager,
          ),
    ),
    ChangeNotifierProxyProvider<JobListProvider, CollectionScheduleProvider>(
      create: (context) => CollectionScheduleProvider(
        jobListProvider: context.read<JobListProvider>(),
      ),
      update: (context, jobListProvider, previous) =>
          previous ??
          CollectionScheduleProvider(
            jobListProvider: jobListProvider,
          ),
    ),
  ], child: const MyApp()));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Initialize authentication after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().initialize();
    });
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
      home: AuthGate(
        child: KeyboardShortcutsService.initializeShortcuts(
          child: const DashboardScreen(),
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

    // Set initial context after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final undoRedoManager = context.read<UndoRedoManager>();
        undoRedoManager.setContext(
            UndoRedoContext.scheduleGrid); // Default to schedule tab
      }
    });
  }

  void _handleTabChange() {
    if (_tabController.index != _currentTabIndex) {
      setState(() {
        _currentTabIndex = _tabController.index;
      });

      // Set the appropriate undo/redo context based on the active tab
      final undoRedoManager = context.read<UndoRedoManager>();
      switch (_currentTabIndex) {
        case 0: // Schedule tab (includes map editing)
          undoRedoManager.setContext(UndoRedoContext.scheduleGrid);
          break;
        case 1: // Job List tab
          undoRedoManager.setContext(UndoRedoContext.jobList);
          break;
        case 2: // Collection Schedule tab
        case 3: // Solar Panel Schedule tab
        default:
          undoRedoManager.setContext(UndoRedoContext.global);
          break;
      }
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
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 222, 222, 222),
      appBar: AppBar(
        leading: const Padding(
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
        leadingWidth: 200,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: TabBar(
          controller: _tabController,
          isScrollable: false,
          labelColor: Colors.black,
          unselectedLabelColor: Colors.black54,
          indicatorColor: Colors.black,
          dividerColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory, // Remove tap animation
          overlayColor:
              WidgetStateProperty.all(Colors.transparent), // Remove overlay
          tabs: const [
            Tab(text: 'Schedule'),
            Tab(text: 'Job List'),
            Tab(text: 'Collection Schedule'),
            Tab(text: 'Solar Panel Schedule'),
          ],
        ),
        actions: [
          // Test button for undo functionality
          // IconButton(
          //   icon: const Icon(Icons.add_circle, color: Colors.green),
          //   tooltip: 'Test Undo (Add fake operation)',
          //   onPressed: () async {
          //     final undoManager =
          //         Provider.of<UndoRedoManager>(context, listen: false);
          //     // Add a test command to verify undo system works
          //     final testCommand = TestCommand(
          //         'Test Operation ${DateTime.now().millisecondsSinceEpoch}');
          //     await undoManager.executeCommand(testCommand);
          //     print('Undo stack size: ${undoManager.undoStackSize}');
          //     print('Can undo: ${undoManager.canUndo}');
          //   },
          // ),
          // Undo/Redo buttons
          const UndoRedoButtons(
            showLabels: false,
            padding: EdgeInsets.all(4.0),
            enabledColor: Colors.deepOrange,
          ),
          const VerticalDivider(
            color: Colors.grey,
            thickness: 1,
            width: 20,
          ),
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
          IconButton(
            icon: const Icon(Icons.data_array),
            onPressed: () async {
              // try {
              //   await seedData();
              //   if (context.mounted) {
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       const SnackBar(
              //         content: Text('Sample schedule data added successfully!'),
              //       ),
              //     );
              //   }
              // } catch (e) {
              //   if (context.mounted) {
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       SnackBar(content: Text('Error adding schedule data: $e')),
              //     );
              //   }
              // }
            },
            tooltip: 'Add sample schedule data',
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            onPressed: () async {
              // try {
              //   await seedJobListData();
              //   if (context.mounted) {
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       const SnackBar(
              //         content: Text('Sample job list data added successfully!'),
              //       ),
              //     );
              //   }
              // } catch (e) {
              //   if (context.mounted) {
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       SnackBar(content: Text('Error adding job list data: $e')),
              //     );
              //   }
              // }
            },
            tooltip: 'Add sample job list data',
          ),
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: () async {
              final workAreaService = context.read<WorkAreaService>();
              try {
                final workAreas = await workAreaService.createFromKml(
                  'jl.kml',
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onSelected: (String value) async {
              if (value == 'scale') {
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
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'signout',
                child: ListTile(
                  leading: Icon(Icons.logout, color: Colors.red),
                  title: Text('Sign Out', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentTabIndex,
        children: const [
          ScheduleTab(),
          JobListTab(),
          CollectionScheduleTab(),
          SolarPanelScheduleTab(),
        ],
      ),
    );
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
    return Stack(
      children: [
        Consumer<ScheduleProvider>(
          builder: (context, scheduleProvider, child) {
            final isLoading = scheduleProvider.distributors.isEmpty &&
                scheduleProvider.jobs.isEmpty;

            return LazyLoadingIndicator(
              isLoading: isLoading,
              message: 'Loading Schedule...',
              child: isLoading
                  ? Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const SizedBox.expand(),
                    )
                  : const ScheduleGrid(),
            );
          },
        ),
        // Floating undo/redo button for Schedule tab
        const Positioned(
          bottom: 16,
          right: 16,
          child: UndoRedoFAB(heroTag: "schedule"),
        ),
      ],
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
  bool _isInitialized = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Initialize JobList data asynchronously
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeJobListData();
    });
  }

  Future<void> _initializeJobListData() async {
    if (!_isInitialized && mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    return Consumer<JobListProvider>(
      builder: (context, jobListProvider, child) {
        // Show error state if there's an error
        if (jobListProvider.error != null && _isInitialized) {
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
                    // Retry loading
                    setState(() {
                      _isInitialized = false;
                    });
                    _initializeJobListData();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        // Show loading state
        if (!_isInitialized || jobListProvider.isLoading) {
          return LazyLoadingIndicator(
            isLoading: true,
            message: _isInitialized
                ? 'Loading Job List Data...'
                : 'Initializing Job List...',
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: const SizedBox.expand(),
            ),
          );
        }

        return const Stack(
          children: [
            JobListGrid(),
            // Floating undo/redo button for Job List tab
            Positioned(
              bottom: 16,
              right: 16,
              child: UndoRedoFAB(heroTag: "joblist"),
            ),
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

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Consumer<CollectionScheduleProvider>(
      builder: (context, collectionProvider, child) {
        final isLoading = collectionProvider.collectionJobs.isEmpty &&
            collectionProvider.workAreas.isEmpty;

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
            // Floating undo/redo button for Collection Schedule tab
            const Positioned(
              bottom: 16,
              right: 16,
              child: UndoRedoFAB(heroTag: "collection"),
            ),
          ],
        );
      },
    );
  }
}

class SolarPanelScheduleTab extends StatefulWidget {
  const SolarPanelScheduleTab({super.key});

  @override
  State<SolarPanelScheduleTab> createState() => _SolarPanelScheduleTabState();
}

class _SolarPanelScheduleTabState extends State<SolarPanelScheduleTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.solar_power, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Solar Panel Schedule',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'Solar panel schedule functionality will be implemented here',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
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
                  'maps.kml',
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
