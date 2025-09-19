import 'package:flutter/material.dart';

class MonthNavigationWidget extends StatelessWidget {
  final String currentMonthDisplay;
  final VoidCallback onPreviousMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onCurrentMonth;
  final Function(String monthId) onMonthSelected;
  final Future<List<String>> availableMonths;

  const MonthNavigationWidget({
    super.key,
    required this.currentMonthDisplay,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onCurrentMonth,
    required this.onMonthSelected,
    required this.availableMonths,
  });

  /// Generate a list of month IDs (2 before current, current, 2 after current)
  List<String> _generateMonthRange(String currentMonth) {
    final months = [
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
      'Dec'
    ];

    // Parse current month
    final parts = currentMonth.split(' ');
    if (parts.length != 2) return [currentMonth];

    final currentMonthName = parts[0];
    final currentYear = int.tryParse(parts[1]) ?? DateTime.now().year;
    final currentMonthIndex = months.indexOf(currentMonthName);

    if (currentMonthIndex == -1) return [currentMonth];

    // Generate 5 months: 2 before, current, 2 after
    final List<String> monthRange = [];

    for (int i = -2; i <= 2; i++) {
      final monthIndex = (currentMonthIndex + i) % 12;
      final yearOffset = (currentMonthIndex + i) < 0
          ? -1
          : (currentMonthIndex + i) >= 12
              ? 1
              : 0;

      final monthName = months[monthIndex < 0 ? monthIndex + 12 : monthIndex];
      final year = currentYear + yearOffset;

      monthRange.add('$monthName $year');
    }

    return monthRange;
  }

  @override
  Widget build(BuildContext context) {
    final monthRange = _generateMonthRange(currentMonthDisplay);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Previous Month Button
          IconButton(
            onPressed: onPreviousMonth,
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous month',
            style: IconButton.styleFrom(
              backgroundColor: Colors.blue.shade50,
              foregroundColor: Colors.blue.shade700,
            ),
          ),

          const SizedBox(width: 8),

          // Month Range Display (5 months)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: monthRange.map((monthId) {
                final isCurrent = monthId == currentMonthDisplay;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => onMonthSelected(monthId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? Colors.blue.shade100
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isCurrent
                              ? Colors.blue.shade300
                              : Colors.grey.shade300,
                          width: isCurrent ? 2 : 1,
                        ),
                      ),
                      child: Text(
                        monthId,
                        style: TextStyle(
                          fontSize: isCurrent ? 14 : 12,
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent
                              ? Colors.blue.shade800
                              : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          // Next Month Button
          IconButton(
            onPressed: onNextMonth,
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next month',
            style: IconButton.styleFrom(
              backgroundColor: Colors.blue.shade50,
              foregroundColor: Colors.blue.shade700,
            ),
          ),

          const SizedBox(width: 16),

          // Current Month Button
          ElevatedButton.icon(
            onPressed: onCurrentMonth,
            icon: const Icon(Icons.today, size: 18),
            label: const Text('Current'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade100,
              foregroundColor: Colors.green.shade800,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.green.shade300),
              ),
            ),
          ),

          const Spacer(),

          // Available Months Dropdown
          FutureBuilder<List<String>>(
            future: availableMonths,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const SizedBox.shrink();
              }

              return PopupMenuButton<String>(
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_month),
                    const SizedBox(width: 4),
                    Text(
                      'All Months',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
                tooltip: 'Select month',
                onSelected: (monthId) {
                  onMonthSelected(monthId);
                },
                itemBuilder: (context) {
                  return snapshot.data!.map((monthId) {
                    return PopupMenuItem<String>(
                      value: monthId,
                      child: Row(
                        children: [
                          Icon(
                            monthId == currentMonthDisplay
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 16,
                            color: monthId == currentMonthDisplay
                                ? Colors.blue
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(monthId),
                        ],
                      ),
                    );
                  }).toList();
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
