// track_editor/providers/te_cloud_save_state_provider.dart
//
// Per-tab state for the Track Editor's "Save to Cloud" panel.
//
// The cloud-save panel's widgets used to hold all of their data locally
// (resolved client list, `savedAsIs` / `trimmedSaved` flags, chosen
// folder, expansion, polygon selection). That meant switching tabs
// either wiped the save confirmation that had just appeared, or left
// the previous tab's clients visible for a split-second while the new
// tab's resolver ran asynchronously. Both felt like a state leak.
//
// This provider stores that state per [TETabItem] (keyed by object
// identity, same way [TETabsProvider] holds its per-tab data), so
// flipping between paired tabs shows each tab's own client list,
// folder picks and save status — without cross-contamination.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';

final teCloudSaveRiverpod =
    riverpod.ChangeNotifierProvider<TECloudSaveStateProvider>(
  (ref) => TECloudSaveStateProvider(),
);

/// One client row inside a tab's cloud-save panel.
///
/// Mutable on purpose — the provider updates fields in place and calls
/// `notifyListeners()`. Widgets always read via the provider.
class TECloudSaveClientEntry {
  final String clientName;
  final String distributorName;
  final DateTime date;
  final List<TEStyledPolygon> polygons;

  String folderPath;
  bool folderExists;

  /// True once the user has successfully pressed "Save As-Is" for this
  /// client in the current tab/session.
  bool savedAsIs;

  /// True once the user has successfully pressed "Trim & Save".
  bool trimmedSaved;

  /// Whether the client tile is currently expanded in the UI.
  bool expanded;

  /// Polygon indices currently ticked for the Trim & Save flow.
  final Set<int> selectedPolyIndices;

  TECloudSaveClientEntry({
    required this.clientName,
    required this.distributorName,
    required this.date,
    required this.polygons,
    required this.folderPath,
    this.folderExists = true,
    this.savedAsIs = false,
    this.trimmedSaved = false,
    this.expanded = false,
    Set<int>? selectedPolyIndices,
  }) : selectedPolyIndices = selectedPolyIndices ?? <int>{};

  /// Stable match key used to preserve user-visible flags across a manual
  /// "Refresh" that re-resolves the client list.
  String get matchKey => '$clientName|$folderPath';
}

/// Aggregate per-tab state (resolver status + clients list).
class TECloudSaveTabState {
  bool loading = false;
  String? error;

  /// True once [TECloudSaveStateProvider.finishResolveSuccess] has fired at
  /// least once for this tab. Used to know whether the panel should kick
  /// off its first resolve.
  bool resolved = false;

  final List<TECloudSaveClientEntry> clients = [];
}

class TECloudSaveStateProvider extends ChangeNotifier {
  // Keyed by TETabItem identity. Entries persist until [clearTab] is
  // called (or the provider itself is disposed). Tab removal is not
  // watched here — a few stale keys for closed tabs is harmless.
  final Map<TETabItem, TECloudSaveTabState> _byTab = {};

  TECloudSaveTabState _stateFor(TETabItem tab) =>
      _byTab.putIfAbsent(tab, TECloudSaveTabState.new);

  // ── Reads ───────────────────────────────────────────────────────────

  bool isResolved(TETabItem tab) => _byTab[tab]?.resolved ?? false;
  bool isLoading(TETabItem tab) => _byTab[tab]?.loading ?? false;
  String? errorFor(TETabItem tab) => _byTab[tab]?.error;
  List<TECloudSaveClientEntry> clientsFor(TETabItem tab) =>
      _byTab[tab]?.clients ?? const <TECloudSaveClientEntry>[];

  // ── Resolver lifecycle ──────────────────────────────────────────────

  void beginResolve(TETabItem tab) {
    final state = _stateFor(tab);
    state.loading = true;
    state.error = null;
    notifyListeners();
  }

  /// Replace the tab's client list, preserving per-client flags (saved
  /// indicators, expansion, selections) for any entry that matches an
  /// existing one via [TECloudSaveClientEntry.matchKey].
  void finishResolveSuccess(
    TETabItem tab,
    List<TECloudSaveClientEntry> clients,
  ) {
    final state = _stateFor(tab);
    final preserved = <String, TECloudSaveClientEntry>{
      for (final c in state.clients) c.matchKey: c,
    };
    for (final c in clients) {
      final prev = preserved[c.matchKey];
      if (prev != null) {
        c.savedAsIs = prev.savedAsIs;
        c.trimmedSaved = prev.trimmedSaved;
        c.expanded = prev.expanded;
        c.selectedPolyIndices
          ..clear()
          ..addAll(prev.selectedPolyIndices);
      }
    }
    state
      ..clients.clear()
      ..clients.addAll(clients)
      ..loading = false
      ..error = null
      ..resolved = true;
    notifyListeners();
  }

  void finishResolveError(TETabItem tab, String error) {
    final state = _stateFor(tab);
    state.loading = false;
    state.error = error;
    state.resolved = false;
    notifyListeners();
  }

  // ── Per-client mutations ────────────────────────────────────────────

  void addClient(TETabItem tab, TECloudSaveClientEntry entry) {
    _stateFor(tab).clients.add(entry);
    notifyListeners();
  }

  void setFolder(
    TECloudSaveClientEntry entry,
    String path, {
    required bool exists,
  }) {
    entry.folderPath = path;
    entry.folderExists = exists;
    // Changing folder invalidates the previous save confirmation.
    entry.savedAsIs = false;
    entry.trimmedSaved = false;
    notifyListeners();
  }

  void setExpanded(TECloudSaveClientEntry entry, bool v) {
    entry.expanded = v;
    notifyListeners();
  }

  void markSavedAsIs(TECloudSaveClientEntry entry, bool v) {
    entry.savedAsIs = v;
    notifyListeners();
  }

  void markTrimmedSaved(TECloudSaveClientEntry entry, bool v) {
    entry.trimmedSaved = v;
    notifyListeners();
  }

  void toggleSelectedPoly(TECloudSaveClientEntry entry, int polyIndex) {
    if (!entry.selectedPolyIndices.add(polyIndex)) {
      entry.selectedPolyIndices.remove(polyIndex);
    }
    // Selection change means the next trim will differ → reset saved flag.
    entry.trimmedSaved = false;
    notifyListeners();
  }

  void setSelectedPolys(TECloudSaveClientEntry entry, Set<int> selection) {
    entry.selectedPolyIndices
      ..clear()
      ..addAll(selection);
    entry.trimmedSaved = false;
    notifyListeners();
  }

  /// Drop cached state for [tab]. Call when the tab is removed or when
  /// its underlying track/waypoint data changes enough that a fresh
  /// resolve is warranted.
  void clearTab(TETabItem tab) {
    if (_byTab.remove(tab) != null) notifyListeners();
  }
}
