import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'providers/schedule_provider.dart';
import 'providers/job_list_provider.dart';
import 'widgets/schedule_grid.dart';
import 'widgets/job_list_grid.dart';
import 'widgets/distributor_management_dialog.dart';
import 'utils/seed_data.dart';
import 'utils/seed_job_list_data.dart';
import 'services/work_area_service.dart';
import 'services/job_list_service.dart';
import 'firebase_options.dart';

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

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => ScheduleProvider()),
        Provider(
          create: (context) => WorkAreaService(FirebaseFirestore.instance),
        ),
        Provider(
          create: (context) => JobListService(FirebaseFirestore.instance),
        ),
        ChangeNotifierProvider(
          create: (context) => JobListProvider(
            context.read<JobListService>(),
          ),
        ),
      ],
      child: MaterialApp(
        title: 'CLM DASHBOARD',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const DashboardScreen(),
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
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
          tabs: const [
            Tab(text: 'Schedule'),
            Tab(text: 'Job List'),
            Tab(text: 'Collection Schedule'),
            Tab(text: 'Solar Panel Schedule'),
          ],
        ),
        actions: [
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
              try {
                await seedData();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sample schedule data added successfully!'),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error adding schedule data: $e')),
                  );
                }
              }
            },
            tooltip: 'Add sample schedule data',
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            onPressed: () async {
              try {
                await seedJobListData();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sample job list data added successfully!'),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error adding job list data: $e')),
                  );
                }
              }
            },
            tooltip: 'Add sample job list data',
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
      body: TabBarView(
        controller: _tabController,
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

class ScheduleTab extends StatelessWidget {
  const ScheduleTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScheduleGrid();
  }
}

class JobListTab extends StatelessWidget {
  const JobListTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const JobListGrid();
  }
}

class CollectionScheduleTab extends StatelessWidget {
  const CollectionScheduleTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.schedule, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Collection Schedule',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'Collection schedule functionality will be implemented here',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class SolarPanelScheduleTab extends StatelessWidget {
  const SolarPanelScheduleTab({super.key});

  @override
  Widget build(BuildContext context) {
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
