import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_job.dart'; // For CategorizedTools
import '../providers/happy_sun_project_provider.dart';
import '../providers/inventory_provider.dart';
import '../widgets/happy_sun_project_card.dart';
import 'happy_sun_checkout_dialog.dart';
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
    return Column(
      children: [
        // Top bar with tabs and add button
        Material(
          elevation: 2,
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabs: const [
                          Tab(text: 'All Projects'),
                          Tab(text: 'Pending'),
                          Tab(text: 'In Progress'),
                          Tab(text: 'Completed'),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () => _showAddProjectDialog(context),
                      tooltip: 'Add Project',
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildProjectsList('all'),
              _buildProjectsList('pending'),
              _buildProjectsList('in-progress'),
              _buildProjectsList('completed'),
            ],
          ),
        ),
      ],
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(project.clientName),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailSection('Address', project.address),
              _buildDetailSection('Status', project.status),
              _buildDetailSection(
                  'Team Members', '${project.numberOfTeamMembers}'),
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
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
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

    showDialog(
      context: context,
      builder: (context) => ProjectToolsDialog(
        toolsNeeded: project.toolsNeeded ?? CategorizedTools(),
        availableTools: inventoryProvider.tools,
        onSave: (updatedTools) async {
          final provider = context.read<HappySunProjectProvider>();
          final updatedProject = project.copyWith(toolsNeeded: updatedTools);
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
    showDialog(
      context: context,
      builder: (context) => HappySunCheckoutDialog(project: project),
    );
  }

  void _showChecklistDialog(BuildContext context, HappySunProject project) {
    showDialog(
      context: context,
      builder: (context) => HappySunChecklistDialog(project: project),
    );
  }

  void _showCheckinDialog(BuildContext context, HappySunProject project) {
    showDialog(
      context: context,
      builder: (context) => HappySunCheckinDialog(project: project),
    );
  }
}
