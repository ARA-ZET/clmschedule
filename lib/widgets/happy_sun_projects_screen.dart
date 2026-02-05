import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_shared.dart'; // For CategorizedTools
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import '../widgets/happy_sun_project_card.dart';
import 'happy_sun_checkout_dialog.dart';
import 'happy_sun_checkout_screen.dart';
import 'happy_sun_checklist_dialog.dart';
import 'happy_sun_checkin_dialog.dart';
import 'happy_sun_add_project_dialog.dart';
import 'project_tools_dialog.dart';

class HappySunProjectsScreen extends StatefulWidget {
  const HappySunProjectsScreen({super.key});

  @override
  State<HappySunProjectsScreen> createState() => _HappySunProjectsScreenState();
}

class _HappySunProjectsScreenState extends State<HappySunProjectsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _selectedStatus = 'all'; // For mobile dropdown

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      // Sync dropdown with tab selection
      setState(() {
        _selectedStatus = _getStatusFromIndex(_tabController.index);
      });
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _getStatusFromIndex(int index) {
    switch (index) {
      case 0:
        return 'all';
      case 1:
        return 'pending';
      case 2:
        return 'in-progress';
      case 3:
        return 'completed';
      default:
        return 'all';
    }
  }

  int _getIndexFromStatus(String status) {
    switch (status) {
      case 'all':
        return 0;
      case 'pending':
        return 1;
      case 'in-progress':
        return 2;
      case 'completed':
        return 3;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isMobile ? 'Projects' : 'Happy Sun Projects',
          style: TextStyle(
            fontSize: isMobile ? 18 : 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        actions: [
          if (screenWidth > 400)
            IconButton(
              icon: const Icon(Icons.calendar_month),
              onPressed: () {
                // TODO: Add month filter functionality
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Month filter coming soon'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              tooltip: 'Filter by Month',
            ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddProjectDialog(context),
            tooltip: 'Add Project',
          ),
          SizedBox(width: isMobile ? 4 : 8),
        ],
        bottom: isMobile
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  color: Colors.orange.shade700,
                  child: Row(
                    children: [
                      const Icon(Icons.filter_list,
                          color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButton<String>(
                            value: _selectedStatus,
                            isExpanded: true,
                            underline: const SizedBox(),
                            icon: const Icon(Icons.arrow_drop_down, size: 24),
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.black87,
                            ),
                            onChanged: (String? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedStatus = newValue;
                                  _tabController
                                      .animateTo(_getIndexFromStatus(newValue));
                                });
                              }
                            },
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('All Projects'),
                              ),
                              DropdownMenuItem(
                                value: 'pending',
                                child: Text('Pending'),
                              ),
                              DropdownMenuItem(
                                value: 'in-progress',
                                child: Text('In Progress'),
                              ),
                              DropdownMenuItem(
                                value: 'completed',
                                child: Text('Completed'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : TabBar(
                controller: _tabController,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: const [
                  Tab(text: 'All Projects'),
                  Tab(text: 'Pending'),
                  Tab(text: 'In Progress'),
                  Tab(text: 'Completed'),
                ],
              ),
      ),
      body: isMobile
          ? _buildProjectsList(_selectedStatus)
          : TabBarView(
              controller: _tabController,
              children: [
                _buildProjectsList('all'),
                _buildProjectsList('pending'),
                _buildProjectsList('in-progress'),
                _buildProjectsList('completed'),
              ],
            ),
    );
  }

  Widget _buildProjectsList(String statusFilter) {
    return Consumer<HappySunProjectProvider>(
      builder: (context, projectProvider, child) {
        if (projectProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        if (projectProvider.error != null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${projectProvider.error}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    // Trigger reload by recreating provider
                    setState(() {});
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        List<HappySunProject> projects = statusFilter == 'all'
            ? projectProvider.projects
            : projectProvider.getProjectsByStatus(statusFilter);

        if (projects.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.inbox_outlined,
                  size: 64,
                  color: Colors.grey[400],
                ),
                const SizedBox(height: 16),
                Text(
                  'No projects found',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.grey[600],
                  ),
                ),
                if (statusFilter == 'all') ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _showAddProjectDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add your first project'),
                  ),
                ],
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            // Provider auto-updates via stream
            await Future.delayed(const Duration(milliseconds: 500));
          },
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: projects.length,
            itemBuilder: (context, index) {
              final project = projects[index];
              return HappySunProjectCard(
                project: project,
                onTap: () => _showProjectDetails(context, project),
                onEditTools: () => _showToolsDialog(context, project),
                onCheckout: !project.hasCheckout
                    ? () => _showCheckoutDialog(context, project)
                    : null,
                onChecklist: project.hasCheckout && !project.hasChecklist
                    ? () => _showChecklistDialog(context, project)
                    : null,
                onCheckin: project.hasChecklist && !project.hasCheckin
                    ? () => _showCheckinDialog(context, project)
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  void _showAddProjectDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const HappySunAddProjectDialog(),
    );
  }

  void _showProjectDetails(BuildContext context, HappySunProject project) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      useSafeArea: true,
      builder: (context) => isMobile
          ? Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  title: Text(project.clientName),
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
                body: _buildProjectDetailsContent(project),
              ),
            )
          : AlertDialog(
              title: Text(project.clientName),
              content: _buildProjectDetailsContent(project),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
    );
  }

  Widget _buildProjectDetailsContent(HappySunProject project) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDetailSection('Address', project.address),
          _buildDetailSection('Status', project.status),
          _buildDetailSection('Team Members', '${project.numberOfTeamMembers}'),
          if (project.hasCheckout) ...[
            const Divider(),
            const Text('Checkout Details',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Tools: ${project.checkout!.totalToolsCount}'),
          ],
          if (project.hasChecklist) ...[
            const Divider(),
            const Text('Checklist Details',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
                'Completed: ${project.checklist!.checkedItemsCount}/${project.checklist!.totalItemsCount}'),
          ],
          if (project.hasCheckin) ...[
            const Divider(),
            const Text('Check-in Details',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Returned: ${project.checkin!.totalReturnedCount}'),
            if (!project.checkin!.hasAllToolsReturned)
              Text('Missing: ${project.checkin!.missingTools.length}',
                  style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailSection(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _showToolsDialog(BuildContext context, HappySunProject project) {
    final inventoryProvider = context.read<InventoryProvider>();
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      useSafeArea: true,
      builder: (context) => isMobile
          ? Dialog.fullscreen(
              child: ProjectToolsDialog(
                toolsNeeded: project.toolsNeeded ?? CategorizedTools(),
                availableTools: inventoryProvider.tools,
                onSave: (updatedTools) async {
                  final provider = context.read<HappySunProjectProvider>();
                  final updatedProject =
                      project.copyWith(toolsNeeded: updatedTools);
                  await provider.updateProject(updatedProject);

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Tools updated successfully'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                },
              ),
            )
          : ProjectToolsDialog(
              toolsNeeded: project.toolsNeeded ?? CategorizedTools(),
              availableTools: inventoryProvider.tools,
              onSave: (updatedTools) async {
                final provider = context.read<HappySunProjectProvider>();
                final updatedProject =
                    project.copyWith(toolsNeeded: updatedTools);
                await provider.updateProject(updatedProject);

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Tools updated successfully'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              },
            ),
    );
  }

  void _showCheckoutDialog(BuildContext context, HappySunProject project) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      // Use full-screen navigation on mobile
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => HappySunCheckoutScreen(project: project),
        ),
      );
    } else {
      // Use dialog on larger screens
      showDialog(
        context: context,
        builder: (context) => HappySunCheckoutDialog(project: project),
      );
    }
  }

  void _showChecklistDialog(BuildContext context, HappySunProject project) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      useSafeArea: true,
      builder: (context) => isMobile
          ? Dialog.fullscreen(
              child: HappySunChecklistDialog(project: project),
            )
          : HappySunChecklistDialog(project: project),
    );
  }

  void _showCheckinDialog(BuildContext context, HappySunProject project) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      useSafeArea: true,
      builder: (context) => isMobile
          ? Dialog.fullscreen(
              child: HappySunCheckinDialog(project: project),
            )
          : HappySunCheckinDialog(project: project),
    );
  }
}
