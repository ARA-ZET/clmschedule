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
import 'dart:collection';

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

  /// A "Save As-Is" / "Trim & Save" upload for this client is running. Held
  /// here rather than in the client tile so it survives the user switching
  /// tabs or a re-resolve mid-upload — see [TECloudSaveUpload].
  bool uploadingAsIs = false;
  bool uploadingTrimmed = false;

  /// Whether the client tile is currently expanded in the UI.
  bool expanded;

  /// Polygon indices currently ticked for the Trim & Save flow.
  final Set<int> selectedPolyIndices;

  /// Added by hand with no schedule job behind it, so a re-resolve (which
  /// only knows the schedule's clients) must keep it rather than drop it.
  final bool manual;

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
    this.manual = false,
    Set<int>? selectedPolyIndices,
  }) : selectedPolyIndices = selectedPolyIndices ?? <int>{};
}

/// Aggregate per-tab state (resolver status + clients list).
class TECloudSaveTabState {
  bool loading = false;
  String? error;

  /// What the running resolve is waiting on, shown under the spinner.
  String? stage;

  /// Bumped by every [TECloudSaveStateProvider.beginResolve] and whenever a
  /// running resolve is abandoned, so a late answer from an old attempt
  /// cannot overwrite (or strand) the state.
  int resolveSeq = 0;

  /// True once [TECloudSaveStateProvider.finishResolveSuccess] has fired at
  /// least once for this tab. Used to know whether the panel should kick
  /// off its first resolve.
  bool resolved = false;

  final List<TECloudSaveClientEntry> clients = [];
}

/// One resolve attempt on a tab's state. It stays bound to the state, not the
/// tab, so it still lands after the live schedule sync swaps the tab
/// ([TECloudSaveStateProvider.markStale]) — unless that abandoned it.
class TECloudSaveResolveTicket {
  final TECloudSaveTabState _state;
  final int _seq;

  TECloudSaveResolveTicket._(this._state, this._seq);

  bool get isCurrent => _state.loading && _state.resolveSeq == _seq;
}

/// One running upload for a client, from
/// [TECloudSaveStateProvider.beginUpload].
///
/// Bound to the tab's state and the client's NAME, not the entry object: a
/// re-resolve replaces every entry, and the live schedule sync re-keys the
/// state to a new tab, so the entry the upload started from may no longer be
/// the one on screen when it finishes.
class TECloudSaveUpload {
  final TECloudSaveTabState _state;
  final String clientName;
  final bool trimmed;

  /// The folder and (for a trim) the ticked areas the file was saved with.
  /// If the user changed either while it uploaded, the client does not
  /// show as saved — what is on screen is not what was saved.
  final String folderPath;
  final Set<int> selection;

  TECloudSaveUpload._(this._state, this.clientName, this.trimmed,
      this.folderPath, this.selection);
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
  String? stageFor(TETabItem tab) => _byTab[tab]?.stage;
  List<TECloudSaveClientEntry> clientsFor(TETabItem tab) {
    final list = _byTab[tab]?.clients;
    if (list == null) return const <TECloudSaveClientEntry>[];
    return UnmodifiableListView(list);
  }

  // ── Resolver lifecycle ──────────────────────────────────────────────

  TECloudSaveResolveTicket beginResolve(TETabItem tab) {
    final state = _stateFor(tab);
    state.loading = true;
    state.error = null;
    state.stage = null;
    notifyListeners();
    return TECloudSaveResolveTicket._(state, ++state.resolveSeq);
  }

  /// Starts a fresh attempt on the same state (after a timeout), abandoning
  /// [ticket]'s. Null when [ticket] was already abandoned.
  TECloudSaveResolveTicket? retryResolve(
    TECloudSaveResolveTicket ticket,
    String stage,
  ) {
    if (!ticket.isCurrent) return null;
    final state = ticket._state..stage = stage;
    notifyListeners();
    return TECloudSaveResolveTicket._(state, ++state.resolveSeq);
  }

  void setResolveStage(TECloudSaveResolveTicket ticket, String stage) {
    if (!ticket.isCurrent || ticket._state.stage == stage) return;
    ticket._state.stage = stage;
    notifyListeners();
  }

  /// Replace the tab's client list with a fresh resolve. Re-resolves run
  /// whenever the schedule changes, so each client keeps what the user set
  /// on it: its folder, saved ticks, expansion, and ticked areas (matched by
  /// name — the area list itself may have changed). Hand-added clients the
  /// schedule doesn't know are kept.
  void finishResolveSuccess(
    TECloudSaveResolveTicket ticket,
    List<TECloudSaveClientEntry> clients,
  ) {
    if (!ticket.isCurrent) return;
    final state = ticket._state;
    final previous = <String, TECloudSaveClientEntry>{};
    for (final c in state.clients) {
      previous.putIfAbsent(c.clientName, () => c);
    }
    for (final c in clients) {
      final prev = previous.remove(c.clientName);
      if (prev == null) continue;
      // Keep the user's folder, unless it was missing and the client's
      // own folder has since appeared.
      if (prev.folderExists || !c.folderExists) {
        c.folderPath = prev.folderPath;
        c.folderExists = prev.folderExists;
      }
      c.savedAsIs = prev.savedAsIs;
      c.trimmedSaved = prev.trimmedSaved;
      c.uploadingAsIs = prev.uploadingAsIs;
      c.uploadingTrimmed = prev.uploadingTrimmed;
      c.expanded = prev.expanded;
      final ticked = {
        for (final i in prev.selectedPolyIndices)
          if (i >= 0 && i < prev.polygons.length) prev.polygons[i].name,
      };
      c.selectedPolyIndices
        ..clear()
        ..addAll([
          for (var i = 0; i < c.polygons.length; i++)
            if (ticked.contains(c.polygons[i].name)) i,
        ]);
    }
    final keptManual = [
      for (final c in state.clients)
        if (c.manual && !clients.any((n) => n.clientName == c.clientName)) c,
    ];
    state
      ..clients.clear()
      ..clients.addAll(clients)
      ..clients.addAll(keptManual)
      ..loading = false
      ..error = null
      ..stage = null
      ..resolved = true;
    notifyListeners();
  }

  /// Ends the resolve with [error] shown and a Retry button. The panel does
  /// not re-resolve an errored tab by itself — only Retry, or the schedule
  /// changing under it ([markStale]), starts another attempt.
  void finishResolveError(TECloudSaveResolveTicket ticket, String error) {
    if (!ticket.isCurrent) return;
    final state = ticket._state;
    state.loading = false;
    state.stage = null;
    state.error = error;
    state.resolved = false;
    notifyListeners();
  }

  /// The schedule changed under [oldTab], which now lives on as [newTab].
  /// Keeps its client list (and saved ticks) but marks it unresolved, so the
  /// panel re-resolves it the next time it is shown. A resolve still running
  /// read the old schedule, so it is abandoned rather than left to land.
  void markStale(TETabItem oldTab, TETabItem newTab) {
    final state = _byTab.remove(oldTab);
    if (state == null) return;
    state
      ..resolved = false
      ..loading = false
      ..error = null
      ..stage = null
      ..resolveSeq += 1;
    _byTab[newTab] = state;
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

  /// Marks [entry] as uploading and returns the handle to end it with
  /// [finishUpload]. Null when [entry] is not listed on any tab any more.
  TECloudSaveUpload? beginUpload(
    TECloudSaveClientEntry entry, {
    required bool trimmed,
  }) {
    final state =
        _byTab.values.where((s) => s.clients.contains(entry)).firstOrNull;
    if (state == null) return null;
    if (trimmed) {
      entry.uploadingTrimmed = true;
    } else {
      entry.uploadingAsIs = true;
    }
    notifyListeners();
    return TECloudSaveUpload._(state, entry.clientName, trimmed,
        entry.folderPath, {...entry.selectedPolyIndices});
  }

  /// Ends [upload] on whichever entry now stands for its client. With
  /// [saved], the client shows as saved — unless its folder (or, for a
  /// trim, its ticked areas) changed while the file was uploading.
  void finishUpload(TECloudSaveUpload upload, {required bool saved}) {
    final entry = upload._state.clients
        .where((c) => c.clientName == upload.clientName)
        .firstOrNull;
    if (entry == null) return;
    final unchanged = entry.folderPath == upload.folderPath &&
        (!upload.trimmed ||
            setEquals(entry.selectedPolyIndices, upload.selection));
    if (upload.trimmed) {
      entry.uploadingTrimmed = false;
      if (saved && unchanged) entry.trimmedSaved = true;
    } else {
      entry.uploadingAsIs = false;
      if (saved && unchanged) entry.savedAsIs = true;
    }
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
    final state = _byTab.remove(tab);
    if (state == null) return;
    state.resolveSeq += 1;
    notifyListeners();
  }
}
