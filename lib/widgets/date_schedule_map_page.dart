import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/distributor.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import '../shareable_maps/adapters/date_schedule_adapter.dart';
import '../shareable_maps/providers/shareable_map_provider.dart';
import '../shareable_maps/widgets/shareable_map_editor.dart';
import '../shareable_maps/services/map_export_service.dart';
import 'print_map_view.dart';

/// A map page launched from the schedule grid that shows all work-area
/// polygons for one date, with tabs for each distributor so the user
/// can quickly switch between them and print/export.
class DateScheduleMapPage extends riverpod.ConsumerStatefulWidget {
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
  riverpod.ConsumerState<DateScheduleMapPage> createState() =>
      _DateScheduleMapPageState();
}

class _DateScheduleMapPageState extends riverpod
    .ConsumerState<DateScheduleMapPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  /// Distributor entries that actually have work-map polygons on this date.
  List<_DistributorTab> _tabs = const [];
  List<Job> _liveJobs = const [];
  List<Distributor> _liveDistributors = const [];
  String _loadedSignature = '';

  @override
  void initState() {
    super.initState();

    _liveJobs = widget.jobs.where((j) => j.workMaps.isNotEmpty).toList();
    _liveDistributors = widget.distributors;
    _tabs = _buildTabs(_liveJobs, _liveDistributors);

    // +1 for the "All" tab at index 0
    _tabController = TabController(length: _tabs.length + 1, vsync: this);
    _tabController.addListener(_onTabChanged);

    // Load live provider data initially with fit-to-bounds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshFromSchedule(ref.read(scheduleRiverpod), force: true);
    });
  }

  List<_DistributorTab> _buildTabs(
    List<Job> jobs,
    List<Distributor> distributors,
  ) {
    final byDistributor = <String, List<Job>>{};
    for (final job in jobs) {
      if (job.workMaps.isNotEmpty) {
        byDistributor.putIfAbsent(job.distributorId, () => []).add(job);
      }
    }

    return byDistributor.entries.map((entry) {
      final dist = distributors.where((d) => d.id == entry.key).firstOrNull;
      return _DistributorTab(
        distributorId: entry.key,
        name: dist?.name ?? 'Unknown',
        jobs: entry.value,
      );
    }).toList();
  }

  void _refreshFromSchedule(
    ScheduleProvider schedule, {
    bool force = false,
  }) {
    if (!mounted) return;

    final jobs = schedule
        .getJobsForDate(widget.date)
        .where((j) => j.workMaps.isNotEmpty)
        .toList();
    final distributors = schedule.distributors.isNotEmpty
        ? schedule.distributors
        : widget.distributors;
    final tabs = _buildTabs(jobs, distributors);
    final signature = _signatureFor(jobs, distributors);

    if (!force && signature == _loadedSignature) return;

    final oldIndex = _tabController.index;
    final newLength = tabs.length + 1;
    if (_tabController.length != newLength) {
      _tabController.removeListener(_onTabChanged);
      _tabController.dispose();
      _tabController = TabController(
        length: newLength,
        vsync: this,
        initialIndex: oldIndex.clamp(0, newLength - 1).toInt(),
      );
      _tabController.addListener(_onTabChanged);
    }

    setState(() {
      _liveJobs = jobs;
      _liveDistributors = distributors;
      _tabs = tabs;
      _loadedSignature = signature;
    });

    _loadTab(_tabController.index);
  }

  String _signatureFor(List<Job> jobs, List<Distributor> distributors) {
    final distributorKey =
        distributors.map((d) => '${d.id}:${d.name}').join(';');
    final jobKey = jobs.map((job) {
      final mapKey = job.workMaps.map((wm) {
        final points = wm.points
            .map((p) =>
                '${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}')
            .join('|');
        return [
          wm.name,
          wm.description,
          wm.type.name,
          wm.pointCategory.id,
          wm.color.toARGB32().toString(),
          wm.fillOpacity.toString(),
          wm.strokeWidth.toString(),
          wm.isDashed.toString(),
          wm.letterBoxEstimate.toString(),
          points,
        ].join('~');
      }).join('#');
      return [
        job.id,
        job.distributorId,
        job.clients.join(','),
        job.workingAreas.join(','),
        mapKey,
      ].join('|');
    }).join(';');
    return '$distributorKey::$jobKey';
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
    final provider = ref.read(shareableMapRiverpod);
    final safeIndex = index.clamp(0, _tabs.length).toInt();

    final List<Job> jobs;
    if (safeIndex == 0) {
      jobs = _liveJobs;
    } else {
      jobs = _tabs[safeIndex - 1].jobs;
    }

    final adapter = DateScheduleAdapter(
      date: widget.date,
      jobs: jobs,
      distributors: _liveDistributors,
    );

    provider.requestFitBoundsOnLoad();
    provider.loadFromAdapter(adapter);
  }

  void _exportKml(BuildContext context) {
    final provider = ref.read(shareableMapRiverpod);
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
    ref.listen<ScheduleProvider>(scheduleRiverpod, (_, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshFromSchedule(next);
      });
    });

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
              ref.read(shareableMapRiverpod).fitMapToBounds();
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
      body: _buildMapBody(),
    );
  }

  Widget _buildMapBody() {
    final provider = ref.watch(shareableMapRiverpod);
    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.currentMap == null) {
      return const MapEditorEmptyState();
    }
    return const MapViewWidget();
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
