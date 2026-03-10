import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/distributor.dart';
import '../models/job.dart';
import '../shareable_maps/adapters/date_schedule_adapter.dart';
import '../shareable_maps/providers/map_gesture_provider.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';
import '../shareable_maps/services/map_export_service.dart';
import 'print_map_view.dart';

/// A map page launched from the schedule grid that shows all work-area
/// polygons for one date, with tabs for each distributor so the user
/// can quickly switch between them and print/export.
class DateScheduleMapPage extends StatefulWidget {
  final DateTime date;
  final List<Job> jobs;
  final List<Distributor> distributors;

  const DateScheduleMapPage({
    super.key,
    required this.date,
    required this.jobs,
    required this.distributors,
  });

  @override
  State<DateScheduleMapPage> createState() => _DateScheduleMapPageState();
}

class _DateScheduleMapPageState extends State<DateScheduleMapPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Distributor entries that actually have work-map polygons on this date.
  late final List<_DistributorTab> _tabs;

  @override
  void initState() {
    super.initState();

    // Build per-distributor tab data (only those with maps).
    final byDistributor = <String, List<Job>>{};
    for (final job in widget.jobs) {
      if (job.workMaps.isNotEmpty) {
        byDistributor.putIfAbsent(job.distributorId, () => []).add(job);
      }
    }

    _tabs = byDistributor.entries.map((entry) {
      final dist =
          widget.distributors.where((d) => d.id == entry.key).firstOrNull;
      return _DistributorTab(
        distributorId: entry.key,
        name: dist?.name ?? 'Unknown',
        jobs: entry.value,
      );
    }).toList();

    // +1 for the "All" tab at index 0
    _tabController = TabController(length: _tabs.length + 1, vsync: this);
    _tabController.addListener(_onTabChanged);

    // Load the "All" tab initially with fit-to-bounds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTab(0);
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) return;
    _loadTab(_tabController.index);
  }

  /// Load the adapter for the given tab index and request fit-to-bounds.
  void _loadTab(int index) {
    final provider = context.read<ShareableMapProvider>();

    final List<Job> jobs;
    if (index == 0) {
      jobs = widget.jobs;
    } else {
      jobs = _tabs[index - 1].jobs;
    }

    final adapter = DateScheduleAdapter(
      date: widget.date,
      jobs: jobs,
      distributors: widget.distributors,
    );

    provider.requestFitBoundsOnLoad();
    provider.loadFromAdapter(adapter);
  }

  void _exportKml(BuildContext context) {
    final provider = context.read<ShareableMapProvider>();
    final map = provider.currentMap;
    if (map == null) return;

    final kmlString = MapExportService.exportToKml(map);
    final tabName = _tabController.index == 0
        ? 'all_areas'
        : _tabs[_tabController.index - 1]
            .name
            .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')
            .toLowerCase();
    final fileName =
        '${widget.date.toIso8601String().split('T').first}_$tabName.kml';
    MapExportService.downloadKmlFile(kmlString, fileName);
  }

  void _openPrintView(BuildContext context) {
    final tabIndex = _tabController.index;

    if (tabIndex == 0) {
      // "All" tab — if only one distributor, print that; otherwise pick.
      if (_tabs.length == 1) {
        _printJobsForTab(_tabs.first);
      } else {
        _showDistributorPicker(context);
      }
    } else {
      _printJobsForTab(_tabs[tabIndex - 1]);
    }
  }

  void _printJobsForTab(_DistributorTab tab) {
    if (tab.jobs.isEmpty) return;

    if (tab.jobs.length == 1) {
      _navigateToPrint(tab.jobs.first, tab.name);
    } else {
      // Multiple jobs — show picker
      _showJobPicker(context, tab);
    }
  }

  void _navigateToPrint(Job job, String distributorName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrintMapView(
          job: job,
          distributorName: distributorName,
        ),
      ),
    );
  }

  void _showDistributorPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select distributor to print',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ..._tabs.map((tab) => ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(tab.name),
                  subtitle: Text('${tab.jobs.length} job(s)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _printJobsForTab(tab);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showJobPicker(BuildContext context, _DistributorTab tab) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select job to print for ${tab.name}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...tab.jobs.map((job) => ListTile(
                  leading: const Icon(Icons.work),
                  title:
                      Text(job.clients.where((c) => c.isNotEmpty).join(', ')),
                  subtitle: Text('${job.workMaps.length} area(s)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _navigateToPrint(job, tab.name);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String get _dateLabel {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${widget.date.day} ${months[widget.date.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF5F6368)),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Text(
          '$_dateLabel — Work Areas',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF202124),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out_map,
                size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Fit to bounds',
            onPressed: () {
              context.read<ShareableMapProvider>().fitMapToBounds();
            },
          ),
          IconButton(
            icon:
                const Icon(Icons.download, size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Export KML',
            onPressed: () => _exportKml(context),
          ),
          IconButton(
            icon: const Icon(Icons.print, size: 22, color: Color(0xFF5F6368)),
            tooltip: 'Print',
            onPressed: () => _openPrintView(context),
          ),
          const SizedBox(width: 8),
        ],
        bottom: _tabs.length > 1
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                labelColor: const Color(0xFF1967D2),
                unselectedLabelColor: const Color(0xFF5F6368),
                indicatorColor: const Color(0xFF1967D2),
                tabAlignment: TabAlignment.start,
                tabs: [
                  const Tab(text: 'All'),
                  ..._tabs.map((t) => Tab(text: t.name)),
                ],
              )
            : null,
      ),
      body: ChangeNotifierProvider(
        create: (_) => MapGestureProvider(),
        child: Consumer<ShareableMapProvider>(
          builder: (context, provider, child) {
            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (provider.currentMap == null) {
              return const MapEditorEmptyState();
            }
            return const MapViewWidget();
          },
        ),
      ),
    );
  }
}

class _DistributorTab {
  final String distributorId;
  final String name;
  final List<Job> jobs;

  const _DistributorTab({
    required this.distributorId,
    required this.name,
    required this.jobs,
  });
}
