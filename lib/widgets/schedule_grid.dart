import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../providers/schedule_provider.dart';
import 'job_card.dart';

class ScheduleGrid extends StatefulWidget {
  const ScheduleGrid({super.key});

  @override
  State<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<ScheduleGrid> {
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  // Number of days to show (2 weeks)
  static const int daysToShow = 14;

  // Generate list of dates starting from today
  List<DateTime> _getDates() {
    final now = DateTime.now();
    return List.generate(daysToShow, (index) {
      return DateTime(now.year, now.month, now.day + index);
    });
  }

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScheduleProvider>(
      builder: (context, scheduleProvider, child) {
        final dates = _getDates();
        final distributors = scheduleProvider.distributors;

        return Column(
          children: [
            // Dates header
            SizedBox(
              height: 60,
              child: Scrollbar(
                controller: _horizontalController,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _horizontalController,
                  scrollDirection: Axis.horizontal,
                  itemCount: dates.length,
                  itemBuilder: (context, index) {
                    final date = dates[index];
                    return SizedBox(
                      width: 200,
                      child: Card(
                        child: Center(
                          child: Text(
                            '${date.month}/${date.day}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Grid with distributors and jobs
            Expanded(
              child: Row(
                children: [
                  // Distributors column
                  SizedBox(
                    width: 150,
                    child: Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _verticalController,
                        itemCount: distributors.length,
                        itemBuilder: (context, index) {
                          final distributor = distributors[index];
                          return SizedBox(
                            height: 200,
                            child: Card(
                              child: Center(
                                child: Text(
                                  distributor.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // Jobs grid
                  Expanded(
                    child: Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _verticalController,
                        itemCount: distributors.length,
                        itemBuilder: (context, distributorIndex) {
                          final distributor = distributors[distributorIndex];

                          return SizedBox(
                            height: 200,
                            child: Scrollbar(
                              controller: _horizontalController,
                              thumbVisibility: true,
                              child: ListView.builder(
                                controller: _horizontalController,
                                scrollDirection: Axis.horizontal,
                                itemCount: dates.length,
                                itemBuilder: (context, dateIndex) {
                                  final date = dates[dateIndex];
                                  final jobs = scheduleProvider
                                      .getJobsForDistributorAndDate(
                                        distributor.id,
                                        date,
                                      );

                                  return DragTarget<Job>(
                                    onAcceptWithDetails: (jobDetails) {
                                      // Update job with new distributor and date
                                      scheduleProvider.updateJob(
                                        jobDetails.data.copyWith(
                                          distributorId: distributor.id,
                                          date: date,
                                        ),
                                      );
                                    },
                                    builder: (context, candidateData, rejectedData) {
                                      return SizedBox(
                                        width: 200,
                                        child: Card(
                                          child: Column(
                                            children: [
                                              Expanded(
                                                child: ListView.builder(
                                                  itemCount: jobs.length,
                                                  itemBuilder:
                                                      (context, jobIndex) {
                                                        final job =
                                                            jobs[jobIndex];
                                                        return Draggable<Job>(
                                                          data: job,
                                                          feedback: SizedBox(
                                                            width: 180,
                                                            child: Opacity(
                                                              opacity: 0.7,
                                                              child: JobCard(
                                                                job: job,
                                                              ),
                                                            ),
                                                          ),
                                                          childWhenDragging:
                                                              const SizedBox(),
                                                          child: JobCard(
                                                            job: job,
                                                          ),
                                                        );
                                                      },
                                                ),
                                              ),
                                              IconButton(
                                                icon: const Icon(Icons.add),
                                                onPressed: () {
                                                  // Create a new job for this slot
                                                  final now = DateTime.now();
                                                  final newJob = Job(
                                                    id: '', // Will be set by Firestore
                                                    client: '',
                                                    workingArea: '',
                                                    mapLink: '',
                                                    distributorId:
                                                        distributor.id,
                                                    date: date,
                                                    startTime: DateTime(
                                                      date.year,
                                                      date.month,
                                                      date.day,
                                                      now.hour,
                                                    ),
                                                    endTime: DateTime(
                                                      date.year,
                                                      date.month,
                                                      date.day,
                                                      now.hour + 1,
                                                    ),
                                                    status: JobStatus.scheduled,
                                                  );
                                                  scheduleProvider.addJob(
                                                    newJob,
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
