import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/distributor.dart';
import '../models/vehicle.dart';
import '../providers/schedule_provider.dart';
import '../providers/vehicle_driver_provider.dart';

class GoogleSheetsTrackingView extends StatefulWidget {
  const GoogleSheetsTrackingView({super.key});

  @override
  State<GoogleSheetsTrackingView> createState() =>
      _GoogleSheetsTrackingViewState();
}

class _GoogleSheetsTrackingViewState extends State<GoogleSheetsTrackingView> {
  DateTime _selectedDate = DateTime.now();
  final TextEditingController _bagOutController = TextEditingController();
  final TextEditingController _bagInController = TextEditingController();
  final TextEditingController _specialInstructionsController =
      TextEditingController();

  // Track dragging state
  int? _draggedIndex;

  // Track assignments for the current date
  Map<String, String> _driverAssignments = {}; // distributorId -> driverId
  Map<String, String> _vehicleAssignments = {}; // distributorId -> vehicleId

  @override
  void initState() {
    super.initState();
    // Initialize vehicle and driver data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final vehicleDriverProvider = context.read<VehicleDriverProvider>();
      vehicleDriverProvider.initialize();
      vehicleDriverProvider.loadTrackingEntries(_selectedDate);
      _loadAssignments();
    });
  }

  Future<void> _loadAssignments() async {
    try {
      final vehicleDriverProvider = context.read<VehicleDriverProvider>();
      await vehicleDriverProvider.loadDailyAssignments(_selectedDate);

      final assignments = vehicleDriverProvider.dailyAssignments;
      setState(() {
        _driverAssignments = Map.fromEntries(
          assignments.entries.where((e) => !e.key.startsWith('vehicle_')),
        );
        _vehicleAssignments = Map.fromEntries(
          assignments.entries
              .where((e) => e.key.startsWith('vehicle_'))
              .map((e) => MapEntry(e.key.substring(8), e.value)),
        );
      });
    } catch (e) {
      print('Error loading assignments: $e');
    }
  }

  @override
  void dispose() {
    _bagOutController.dispose();
    _bagInController.dispose();
    _specialInstructionsController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
      // Load tracking entries for the new date
      if (mounted) {
        context
            .read<VehicleDriverProvider>()
            .loadTrackingEntries(_selectedDate);
        _loadAssignments();
      }
    }
  }

  Future<void> _callPhone(String? phoneNumber) async {
    if (phoneNumber == null || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available')),
      );
      return;
    }

    final Uri phoneUri = Uri(scheme: 'tel', path: phoneNumber);
    try {
      if (await canLaunchUrl(phoneUri)) {
        await launchUrl(phoneUri);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error calling: $e')),
        );
      }
    }
  }

  Widget _buildDriverDropdown({
    required String? selectedDriverId,
    required VehicleDriverProvider vehicleDriverProvider,
    required Function(String?) onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: selectedDriverId,
      isExpanded: true,
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.bold,
        color: Colors.black,
      ),
      items: [
        const DropdownMenuItem<String>(
          value: null,
          child: Text('Select Driver', style: TextStyle(fontSize: 10)),
        ),
        ...vehicleDriverProvider.activeDrivers.map(
          (driver) => DropdownMenuItem<String>(
            value: driver.id,
            child: Text(driver.name, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _buildVehicleDropdown({
    required String? selectedVehicleId,
    required VehicleDriverProvider vehicleDriverProvider,
    required Function(String?) onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: selectedVehicleId,
      isExpanded: true,
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.bold,
        color: Colors.black,
      ),
      items: [
        const DropdownMenuItem<String>(
          value: null,
          child: Text('Select Vehicle', style: TextStyle(fontSize: 10)),
        ),
        ...vehicleDriverProvider.activeVehicles.map(
          (vehicle) => DropdownMenuItem<String>(
            value: vehicle.id,
            child: Text(vehicle.name, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _buildEditableField({
    required String initialValue,
    required Function(String) onChanged,
  }) {
    return TextFormField(
      initialValue: initialValue,
      onChanged: onChanged,
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(4),
      ),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
      textAlign: TextAlign.center,
    );
  }

  Future<void> _saveAssignments() async {
    try {
      final vehicleDriverProvider = context.read<VehicleDriverProvider>();
      // Save driver and vehicle assignments for this date
      final allAssignments = <String, String>{
        ..._driverAssignments,
        ..._vehicleAssignments.map((k, v) => MapEntry('vehicle_$k', v)),
      };
      await vehicleDriverProvider.saveVehicleAssignments(
          _selectedDate, allAssignments);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving assignments: $e')),
        );
      }
    }
  }

  Future<void> _updateTrackingEntry(
      String distributorId, String field, int? value) async {
    try {
      final vehicleDriverProvider = context.read<VehicleDriverProvider>();
      final scheduleProvider = context.read<ScheduleProvider>();

      // Get existing entry or create new one
      var trackingEntry =
          vehicleDriverProvider.getTrackingEntry(distributorId, _selectedDate);

      if (trackingEntry == null) {
        // Create new entry
        final jobs = scheduleProvider.getJobsForDistributorAndDate(
            distributorId, _selectedDate);
        final workingAreas =
            jobs.expand((job) => job.workingAreas).toSet().join(', ');

        trackingEntry = DailyTrackingEntry(
          id: '',
          date: _selectedDate,
          distributorId: distributorId,
          area: workingAreas.isEmpty ? 'No assignment' : workingAreas,
          bagOut: field == 'bagOut' ? value : null,
          bagIn: field == 'bagIn' ? value : null,
          createdAt: DateTime.now(),
        );
      } else {
        // Update existing entry
        trackingEntry = DailyTrackingEntry(
          id: trackingEntry.id,
          date: trackingEntry.date,
          driverId: trackingEntry.driverId,
          vehicleId: trackingEntry.vehicleId,
          distributorId: trackingEntry.distributorId,
          area: trackingEntry.area,
          bagOut: field == 'bagOut' ? value : trackingEntry.bagOut,
          bagIn: field == 'bagIn' ? value : trackingEntry.bagIn,
          specialInstructions: trackingEntry.specialInstructions,
          createdAt: trackingEntry.createdAt,
        );
      }

      await vehicleDriverProvider.saveTrackingEntry(trackingEntry);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating tracking entry: $e')),
        );
      }
    }
  }

  Widget _buildGoogleSheetsHeader() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.grey.shade400),
      ),
      child: Table(
        columnWidths: const {
          0: FixedColumnWidth(80), // Driver
          1: FixedColumnWidth(100), // Vehicle
          2: FixedColumnWidth(120), // Distributor
          3: FixedColumnWidth(200), // Area
          4: FixedColumnWidth(80), // Bag Out
          5: FixedColumnWidth(80), // Bag In
          6: FixedColumnWidth(150), // Name & Phone
        },
        border: TableBorder.all(color: Colors.grey.shade400, width: 1),
        children: [
          // Date header row
          TableRow(
            decoration: BoxDecoration(color: Colors.blue.shade100),
            children: [
              TableCell(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child: InkWell(
                    onTap: _selectDate,
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          DateFormat('dd/MM/yyyy').format(_selectedDate),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const TableCell(child: SizedBox()),
              const TableCell(child: SizedBox()),
              const TableCell(child: SizedBox()),
              const TableCell(child: SizedBox()),
              const TableCell(child: SizedBox()),
              const TableCell(child: SizedBox()),
            ],
          ),
          // Column headers
          TableRow(
            decoration: BoxDecoration(color: Colors.grey.shade200),
            children: [
              _buildHeaderCell('Driver'),
              _buildHeaderCell('Vehicle'),
              _buildHeaderCell('Distributor'),
              _buildHeaderCell('Area'),
              _buildHeaderCell('Bag Out'),
              _buildHeaderCell('Bag In'),
              _buildHeaderCell('Name & Phone'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(String text) {
    return TableCell(
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildDataTable() {
    return Consumer2<ScheduleProvider, VehicleDriverProvider>(
      builder: (context, scheduleProvider, vehicleDriverProvider, child) {
        final activeDistributors = scheduleProvider.distributors
            .where((d) => d.status == DistributorStatus.active)
            .toList();

        if (activeDistributors.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(32),
            child: const Center(
              child: Text('No active distributors found'),
            ),
          );
        }

        // Build distributor-area pairs from schedule
        final distributorAreaPairs = <Map<String, dynamic>>[];
        for (final distributor in activeDistributors) {
          final jobs = scheduleProvider.getJobsForDistributorAndDate(
              distributor.id, _selectedDate);
          final workingAreas =
              jobs.expand((job) => job.workingAreas).toSet().toList();

          if (workingAreas.isEmpty) {
            distributorAreaPairs.add({
              'distributor': distributor,
              'area': 'No assignment',
              'driverId': _driverAssignments[distributor.id],
              'vehicleId': _vehicleAssignments[distributor.id],
            });
          } else {
            for (final area in workingAreas) {
              distributorAreaPairs.add({
                'distributor': distributor,
                'area': area,
                'driverId': _driverAssignments[distributor.id],
                'vehicleId': _vehicleAssignments[distributor.id],
              });
            }
          }
        }

        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
          ),
          child: Column(
            children: [
              // Fixed header
              Table(
                columnWidths: const {
                  0: FixedColumnWidth(80),
                  1: FixedColumnWidth(100),
                  2: FixedColumnWidth(120),
                  3: FixedColumnWidth(200),
                  4: FixedColumnWidth(80),
                  5: FixedColumnWidth(80),
                  6: FixedColumnWidth(150),
                },
                border: TableBorder.all(color: Colors.grey.shade400, width: 1),
                children: [
                  // DROP-OFFS section header
                  TableRow(
                    decoration: BoxDecoration(color: Colors.yellow.shade100),
                    children: [
                      _buildSectionHeader('DROP-OFFS'),
                      const TableCell(child: SizedBox()),
                      const TableCell(child: SizedBox()),
                      const TableCell(child: SizedBox()),
                      const TableCell(child: SizedBox()),
                      const TableCell(child: SizedBox()),
                      const TableCell(child: SizedBox()),
                    ],
                  ),
                ],
              ),
              // Reorderable data rows
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: distributorAreaPairs.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (oldIndex < newIndex) {
                      newIndex -= 1;
                    }
                    final item = distributorAreaPairs.removeAt(oldIndex);
                    distributorAreaPairs.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) {
                  final pair = distributorAreaPairs[index];
                  return _buildDraggableDistributorRow(
                    key: ValueKey('${pair['distributor'].id}_$index'),
                    pair: pair,
                    index: index,
                    scheduleProvider: scheduleProvider,
                    vehicleDriverProvider: vehicleDriverProvider,
                  );
                },
              ),
              // Special instructions row
              Table(
                columnWidths: const {
                  0: FixedColumnWidth(80),
                  1: FixedColumnWidth(100),
                  2: FixedColumnWidth(120),
                  3: FixedColumnWidth(200),
                  4: FixedColumnWidth(80),
                  5: FixedColumnWidth(80),
                  6: FixedColumnWidth(150),
                },
                border: TableBorder.all(color: Colors.grey.shade400, width: 1),
                children: [
                  _buildSpecialInstructionsRow(),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String text) {
    return TableCell(
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildDraggableDistributorRow({
    required Key key,
    required Map<String, dynamic> pair,
    required int index,
    required ScheduleProvider scheduleProvider,
    required VehicleDriverProvider vehicleDriverProvider,
  }) {
    final distributor = pair['distributor'] as Distributor;
    final area = pair['area'] as String;
    final driverId = pair['driverId'] as String?;
    final vehicleId = pair['vehicleId'] as String?;

    // Get tracking entry for this distributor
    final trackingEntry =
        vehicleDriverProvider.getTrackingEntry(distributor.id, _selectedDate);

    return Container(
      key: key,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400, width: 1),
        color: _draggedIndex == index ? Colors.blue.shade50 : Colors.white,
      ),
      child: Row(
        children: [
          // Driver dropdown
          Container(
            width: 80,
            padding: const EdgeInsets.all(4),
            child: _buildDriverDropdown(
              selectedDriverId: driverId,
              vehicleDriverProvider: vehicleDriverProvider,
              onChanged: (newDriverId) {
                setState(() {
                  _driverAssignments[distributor.id] = newDriverId ?? '';
                });
                _saveAssignments();
              },
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Vehicle dropdown
          Container(
            width: 100,
            padding: const EdgeInsets.all(4),
            child: _buildVehicleDropdown(
              selectedVehicleId: vehicleId,
              vehicleDriverProvider: vehicleDriverProvider,
              onChanged: (newVehicleId) {
                setState(() {
                  _vehicleAssignments[distributor.id] = newVehicleId ?? '';
                });
                _saveAssignments();
              },
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Distributor (read-only)
          Container(
            width: 120,
            padding: const EdgeInsets.all(8),
            alignment: Alignment.centerLeft,
            child: Text(
              distributor.name,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Area (read-only)
          Container(
            width: 200,
            padding: const EdgeInsets.all(8),
            alignment: Alignment.centerLeft,
            child: Text(
              area,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Bag Out
          Container(
            width: 80,
            padding: const EdgeInsets.all(4),
            child: _buildEditableField(
              initialValue: trackingEntry?.bagOut?.toString() ?? '',
              onChanged: (value) => _updateTrackingEntry(
                distributor.id,
                'bagOut',
                int.tryParse(value),
              ),
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Bag In
          Container(
            width: 80,
            padding: const EdgeInsets.all(4),
            child: _buildEditableField(
              initialValue: trackingEntry?.bagIn?.toString() ?? '',
              onChanged: (value) => _updateTrackingEntry(
                distributor.id,
                'bagIn',
                int.tryParse(value),
              ),
            ),
          ),
          Container(width: 1, height: 40, color: Colors.grey.shade400),
          // Name & Phone
          Container(
            width: 150,
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  distributor.name,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (distributor.phone1 != null &&
                    distributor.phone1!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  InkWell(
                    onTap: () => _callPhone(distributor.phone1!),
                    child: Text(
                      distributor.phone1!,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                if (distributor.phone2 != null &&
                    distributor.phone2!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  InkWell(
                    onTap: () => _callPhone(distributor.phone2!),
                    child: Text(
                      distributor.phone2!,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Drag handle
          SizedBox(
            width: 20,
            child: ReorderableDragStartListener(
              index: index,
              child: const Icon(
                Icons.drag_handle,
                size: 16,
                color: Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  TableRow _buildSpecialInstructionsRow() {
    return TableRow(
      decoration: BoxDecoration(color: Colors.orange.shade50),
      children: [
        TableCell(
          child: Container(
            padding: const EdgeInsets.all(8),
            child: const Text(
              'NB',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        TableCell(
          verticalAlignment: TableCellVerticalAlignment.middle,
          child: Container(
            padding: const EdgeInsets.all(4),
            child: const Text(
              'Take 2 pictures of each Distributor handing out flyers to cars',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const TableCell(child: SizedBox()),
        const TableCell(child: SizedBox()),
        const TableCell(child: SizedBox()),
        const TableCell(child: SizedBox()),
        const TableCell(child: SizedBox()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Dropsheet Sheet'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: () {
              // TODO: Implement print functionality
            },
            tooltip: 'Print Sheet',
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: () {
              // TODO: Implement export to CSV/Excel
            },
            tooltip: 'Export Sheet',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildGoogleSheetsHeader(),
                _buildDataTable(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
