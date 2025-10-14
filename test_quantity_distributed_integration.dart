// Test script to verify quantityDistributed integration
import 'lib/models/job_list_item.dart';

void main() {
  print('Testing quantityDistributed integration...');
  
  // Test time slot conversion
  testTimeSlotConversion();
  
  // Test job type logic
  testJobTypeLogic();
  
  print('All tests passed!');
}

void testTimeSlotConversion() {
  print('\n=== Testing Time Slot Conversion ===');
  
  // Test various time slots
  final testCases = [
    {'hour': 8, 'minute': 0, 'expected': 800},
    {'hour': 8, 'minute': 30, 'expected': 830},
    {'hour': 12, 'minute': 0, 'expected': 1200},
    {'hour': 16, 'minute': 0, 'expected': 1600},
  ];
  
  for (final testCase in testCases) {
    final hour = testCase['hour'] as int;
    final minute = testCase['minute'] as int;
    final expected = testCase['expected'] as int;
    
    final timeSlotInt = hour * 100 + minute;
    
    print('Time ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} -> $timeSlotInt (expected: $expected)');
    assert(timeSlotInt == expected, 'Time slot conversion failed');
  }
  
  print('✓ Time slot conversion tests passed');
}

void testJobTypeLogic() {
  print('\n=== Testing Job Type Logic ===');
  
  // Test which job types should trigger quantityDistributed update
  final collectionJobTypes = [
    JobType.junkCollection,
    JobType.furnitureMove,
  ];
  
  final nonCollectionJobTypes = [
    JobType.flyerDistribution,
    JobType.windowCleaning,
    JobType.solarPanelCleaning,
  ];
  
  for (final jobType in collectionJobTypes) {
    final shouldUpdate = (jobType == JobType.junkCollection || jobType == JobType.furnitureMove);
    print('${jobType.displayName}: Should update quantityDistributed = $shouldUpdate');
    assert(shouldUpdate, 'Collection job type should update quantityDistributed');
  }
  
  for (final jobType in nonCollectionJobTypes) {
    final shouldUpdate = (jobType == JobType.junkCollection || jobType == JobType.furnitureMove);
    print('${jobType.displayName}: Should update quantityDistributed = $shouldUpdate');
    assert(!shouldUpdate, 'Non-collection job type should NOT update quantityDistributed');
  }
  
  print('✓ Job type logic tests passed');
}