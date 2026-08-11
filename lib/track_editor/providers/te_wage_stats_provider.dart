// track_editor/providers/te_wage_stats_provider.dart
//
// Tracks whether the embedded "wage stats" entry box shown in the
// processing panel (once a tab has a matched distributor) has unsaved
// edits, keyed by [TETabItem] identity — same convention as
// [TECloudSaveStateProvider] — so the tab-close flow can warn before
// discarding unsaved payroll data, and so switching tabs shows each tab's
// own dirty state rather than a shared one.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/tab_item.dart';

final teWageStatsRiverpod =
    riverpod.ChangeNotifierProvider<TEWageStatsProvider>(
  (ref) => TEWageStatsProvider(),
);

class TEWageStatsProvider extends ChangeNotifier {
  final Set<TETabItem> _dirtyTabs = {};

  bool isDirty(TETabItem tab) => _dirtyTabs.contains(tab);

  void setDirty(TETabItem tab, bool dirty) {
    final changed = dirty ? _dirtyTabs.add(tab) : _dirtyTabs.remove(tab);
    if (changed) notifyListeners();
  }

  void clearTab(TETabItem tab) {
    if (_dirtyTabs.remove(tab)) notifyListeners();
  }
}
