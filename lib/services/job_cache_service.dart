import 'dart:convert';
import 'dart:html' as html;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/job.dart';

/// Service for caching jobs in browser storage
class JobCacheService {
  static const String _cachePrefix = 'clm_jobs_';
  static const String _cacheVersionKey = 'clm_cache_version';
  static const String _currentVersion = '1.0';

  /// Initialize cache - clear old versions if needed
  static Future<void> initialize() async {
    final storedVersion = html.window.localStorage[_cacheVersionKey];
    if (storedVersion != _currentVersion) {
      await clearAll();
      html.window.localStorage[_cacheVersionKey] = _currentVersion;
    }
  }

  /// Generate cache key for a month
  static String _getCacheKey(DateTime month) {
    return '$_cachePrefix${month.year}_${month.month.toString().padLeft(2, '0')}';
  }

  /// Convert job data to cache-safe format (handles Timestamps)
  static Map<String, dynamic> _jobToCacheFormat(Job job) {
    final jobMap = job.toMap();
    return _convertTimestampsToStrings(jobMap);
  }

  /// Convert cached job data back to job format (handles timestamp strings)
  static Map<String, dynamic> _jobFromCacheFormat(
      Map<String, dynamic> cachedJobMap) {
    return _convertStringsToTimestamps(cachedJobMap);
  }

  /// Recursively convert Timestamp objects to ISO strings for caching
  static Map<String, dynamic> _convertTimestampsToStrings(
      Map<String, dynamic> data) {
    final converted = <String, dynamic>{};

    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;

      if (value is Timestamp) {
        converted[key] = value.toDate().toIso8601String();
      } else if (value is List) {
        converted[key] = value.map((item) {
          if (item is Map<String, dynamic>) {
            return _convertTimestampsToStrings(item);
          }
          return item;
        }).toList();
      } else if (value is Map<String, dynamic>) {
        converted[key] = _convertTimestampsToStrings(value);
      } else {
        converted[key] = value;
      }
    }

    return converted;
  }

  /// Recursively convert ISO strings back to Timestamp objects when retrieving from cache
  static Map<String, dynamic> _convertStringsToTimestamps(
      Map<String, dynamic> data) {
    final converted = <String, dynamic>{};

    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;

      // Convert date field back to Timestamp
      if (key == 'date' && value is String) {
        try {
          final dateTime = DateTime.parse(value);
          converted[key] = Timestamp.fromDate(dateTime);
        } catch (e) {
          // If parsing fails, keep original value
          converted[key] = value;
        }
      } else if (value is List) {
        converted[key] = value.map((item) {
          if (item is Map<String, dynamic>) {
            return _convertStringsToTimestamps(item);
          }
          return item;
        }).toList();
      } else if (value is Map<String, dynamic>) {
        converted[key] = _convertStringsToTimestamps(value);
      } else {
        converted[key] = value;
      }
    }

    return converted;
  }

  /// Store jobs for a specific month
  static Future<void> cacheJobs(DateTime month, List<Job> jobs) async {
    try {
      final key = _getCacheKey(month);
      final jsonData = {
        'month': '${month.year}-${month.month.toString().padLeft(2, '0')}',
        'cachedAt': DateTime.now().toIso8601String(),
        'jobs': jobs.map((job) => _jobToCacheFormat(job)).toList(),
      };

      html.window.localStorage[key] = jsonEncode(jsonData);
      print('Cached ${jobs.length} jobs for ${month.year}-${month.month}');
    } catch (e) {
      print('Error caching jobs for ${month.year}-${month.month}: $e');
    }
  }

  /// Retrieve cached jobs for a specific month
  static Future<List<Job>?> getCachedJobs(DateTime month) async {
    try {
      final key = _getCacheKey(month);
      final cachedData = html.window.localStorage[key];

      if (cachedData == null) {
        return null;
      }

      final jsonData = jsonDecode(cachedData) as Map<String, dynamic>;
      final jobsJson = jsonData['jobs'] as List<dynamic>;

      final jobs = jobsJson.map((jobData) {
        final jobMap = jobData as Map<String, dynamic>;
        final convertedJobMap = _jobFromCacheFormat(jobMap);
        return Job.fromArrayElement(convertedJobMap);
      }).toList();

      print(
          'Retrieved ${jobs.length} cached jobs for ${month.year}-${month.month}');
      return jobs;
    } catch (e) {
      print(
          'Error retrieving cached jobs for ${month.year}-${month.month}: $e');
      return null;
    }
  }

  /// Check if jobs are cached for a specific month
  static bool hasCache(DateTime month) {
    final key = _getCacheKey(month);
    return html.window.localStorage.containsKey(key);
  }

  /// Get cache info for a specific month
  static Map<String, dynamic>? getCacheInfo(DateTime month) {
    try {
      final key = _getCacheKey(month);
      final cachedData = html.window.localStorage[key];

      if (cachedData == null) {
        return null;
      }

      final jsonData = jsonDecode(cachedData) as Map<String, dynamic>;
      return {
        'month': jsonData['month'],
        'cachedAt': DateTime.parse(jsonData['cachedAt']),
        'jobCount': (jsonData['jobs'] as List).length,
      };
    } catch (e) {
      print('Error getting cache info for ${month.year}-${month.month}: $e');
      return null;
    }
  }

  /// Clear cache for a specific month
  static Future<void> clearMonth(DateTime month) async {
    final key = _getCacheKey(month);
    html.window.localStorage.remove(key);
    print('Cleared cache for ${month.year}-${month.month}');
  }

  /// Clear all cached data
  static Future<void> clearAll() async {
    final keys = html.window.localStorage.keys
        .where((key) => key.startsWith(_cachePrefix))
        .toList();
    for (final key in keys) {
      html.window.localStorage.remove(key);
    }
    print('Cleared all job cache data');
  }

  /// Get all cached months
  static List<DateTime> getCachedMonths() {
    final months = <DateTime>[];

    for (final key in html.window.localStorage.keys) {
      if (key.startsWith(_cachePrefix)) {
        try {
          final monthStr = key.substring(_cachePrefix.length);
          final parts = monthStr.split('_');
          if (parts.length == 2) {
            final year = int.parse(parts[0]);
            final month = int.parse(parts[1]);
            months.add(DateTime(year, month));
          }
        } catch (e) {
          // Skip invalid keys
        }
      }
    }

    return months..sort();
  }

  /// Get total cache size info
  static Map<String, dynamic> getCacheStats() {
    final cachedMonths = getCachedMonths();
    int totalJobs = 0;

    for (final month in cachedMonths) {
      final info = getCacheInfo(month);
      if (info != null) {
        totalJobs += info['jobCount'] as int;
      }
    }

    return {
      'totalMonths': cachedMonths.length,
      'totalJobs': totalJobs,
      'cachedMonths': cachedMonths
          .map((m) => '${m.year}-${m.month.toString().padLeft(2, '0')}')
          .toList(),
    };
  }

  /// Check if cache is expired (older than specified hours)
  static bool isCacheExpired(DateTime month, {int maxAgeHours = 24}) {
    final info = getCacheInfo(month);
    if (info == null) return true;

    final cachedAt = info['cachedAt'] as DateTime;
    final age = DateTime.now().difference(cachedAt);

    return age.inHours > maxAgeHours;
  }
}
