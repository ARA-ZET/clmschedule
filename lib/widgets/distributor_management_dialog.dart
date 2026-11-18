import 'package:clmschedule/widgets/app_toast.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:image_picker/image_picker.dart';

import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import '../services/storage_upload.dart';
import '../utils/text_search.dart';
import 'digital_id_card.dart';

/// Staff management: the near-fullscreen screen behind the app bar's "Staff"
/// button.
///
/// It is a master/detail screen rather than a list of expanding cards. The
/// roster on the left is in schedule order (drag to reorder) and shows at a
/// glance who is on the schedule and who is not; the pane on the right edits
/// the selected person's every field in place. There is no nested "edit"
/// dialog, no expansion tile and no popup menu — one click selects somebody
/// and everything about them is already on screen.
///
/// Edits are staged locally and committed by the save bar (or ⌘S / Ctrl+S)
/// in one Firestore batch ([ScheduleProvider.saveDistributorChanges]), adds
/// and deletes included, so a whole reshuffle of the roster is one write.
class DistributorManagementDialog extends riverpod.ConsumerStatefulWidget {
  const DistributorManagementDialog({super.key});

  @override
  riverpod.ConsumerState<DistributorManagementDialog> createState() =>
      _DistributorManagementDialogState();
}

/// Below this width the list and the editor share the screen one at a time.
const double _twoPaneBreakpoint = 900;
const double _listPaneWidth = 340;

/// The editor's fields stop stretching past this; a form a metre wide is
/// harder to read, not easier.
const double _editorMaxWidth = 820;

class _DistributorManagementDialogState
    extends riverpod.ConsumerState<DistributorManagementDialog> {
  /// The roster as it should end up, always in position order.
  List<Distributor> _local = [];
  final Set<String> _deletedIds = {};

  /// Ids minted on this device that aren't in Firestore yet.
  final Set<String> _newIds = {};

  /// Photos picked this session, so the avatar updates the moment one is
  /// chosen instead of waiting on (or being cached against) the download URL.
  final Map<String, Uint8List> _photoPreviews = {};
  String? _uploadingPhotoFor;

  bool _hasChanges = false;
  bool _isSaving = false;

  /// Set just before an intentional close so [PopScope] lets it through.
  bool _allowPop = false;

  String? _selectedId;
  String _query = '';
  DistributorStatus? _statusFilter;
  final _searchController = TextEditingController();
  final _listScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _syncFromProvider();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  void _syncFromProvider() {
    final provider = ref.read(scheduleRiverpod);
    _local = provider.distributors.map((d) => d.copyWith()).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  }

  void _markChanged() => _hasChanges = true;

  // ── Roster helpers ────────────────────────────────────────────────────────

  /// Active staff keep their relative order; everyone else falls to the end.
  /// Always leaves sequential, gap-free, duplicate-free indexes.
  void _normalizeIndexes() {
    final active = <Distributor>[];
    final rest = <Distributor>[];
    for (final d in _local) {
      (d.status == DistributorStatus.active ? active : rest).add(d);
    }
    final ordered = [...active, ...rest];
    _local = [
      for (var i = 0; i < ordered.length; i++) ordered[i].copyWith(index: i),
    ];
  }

  Distributor? get _selected {
    for (final d in _local) {
      if (d.id == _selectedId) return d;
    }
    return null;
  }

  /// The list as shown: search and status filter applied.
  List<Distributor> get _visible {
    var list = _local;
    if (_statusFilter != null) {
      list = list.where((d) => d.status == _statusFilter).toList();
    }
    final search = TextSearch(_query);
    if (!search.isEmpty) {
      list = search.rank(
        list,
        (d) => [d.name, d.phone1, d.phone2, d.fullName, d.idNumber],
      );
    }
    return list;
  }

  bool get _canReorder => _query.trim().isEmpty && _statusFilter == null;

  int get _activeCount =>
      _local.where((d) => d.status == DistributorStatus.active).length;

  /// Whether [d] differs from what is saved, position aside — a reorder
  /// shifts everyone's index and would light the whole list up.
  bool _isEdited(Distributor d, Map<String, Distributor> saved) {
    if (_newIds.contains(d.id)) return true;
    final s = saved[d.id];
    if (s == null) return true;
    return s.name != d.name ||
        s.phone1 != d.phone1 ||
        s.phone2 != d.phone2 ||
        s.status != d.status ||
        s.role != d.role ||
        s.imageUrl != d.imageUrl ||
        s.fullName != d.fullName ||
        s.idNumber != d.idNumber ||
        s.homeAddress != d.homeAddress;
  }

  void _replace(Distributor updated, {bool renormalize = false}) {
    setState(() {
      final i = _local.indexWhere((d) => d.id == updated.id);
      if (i == -1) return;
      _local[i] = updated;
      if (renormalize) _normalizeIndexes();
      _markChanged();
    });
  }

  void _move(Distributor d, {required bool up}) {
    setState(() {
      final i = _local.indexWhere((x) => x.id == d.id);
      final j = up ? i - 1 : i + 1;
      if (i == -1 || j < 0 || j >= _local.length) return;
      final tmp = _local[i];
      _local[i] = _local[j];
      _local[j] = tmp;
      _normalizeIndexes();
      _markChanged();
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      // `onReorderItem` already accounts for the removed item, so newIndex is
      // used as given.
      final moved = _local.removeAt(oldIndex);
      _local.insert(newIndex, moved);
      _normalizeIndexes();
      _markChanged();
    });
  }

  void _addStaff() {
    final id = ref.read(scheduleRiverpod).newDistributorId();
    setState(() {
      // A new person starts active, so they land at the end of the active
      // block rather than after the inactive ones.
      _local.add(Distributor(id: id, name: '', index: _local.length));
      _newIds.add(id);
      _normalizeIndexes();
      _selectedId = id;
      _query = '';
      _searchController.clear();
      _statusFilter = null;
      _markChanged();
    });
    // Bring the new row into view once it has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_listScroll.hasClients) return;
      final i = _local.indexWhere((d) => d.id == id);
      if (i == -1) return;
      final target =
          (i * _rowExtent).clamp(0.0, _listScroll.position.maxScrollExtent);
      _listScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  /// Deletes straight away with an Undo toast — nothing has been written yet,
  /// and after the save they sit in the Recycle Bin for 30 days.
  void _delete(Distributor d) {
    final removedAt = _local.indexWhere((x) => x.id == d.id);
    if (removedAt == -1) return;
    final wasNew = _newIds.contains(d.id);

    setState(() {
      _local.removeAt(removedAt);
      if (wasNew) {
        _newIds.remove(d.id);
      } else {
        _deletedIds.add(d.id);
      }
      _normalizeIndexes();
      if (_selectedId == d.id) {
        _selectedId = _local.isEmpty
            ? null
            : _local[removedAt.clamp(0, _local.length - 1)].id;
      }
      _markChanged();
    });

    final name = d.name.trim().isEmpty ? 'Unnamed staff member' : d.name.trim();
    ScaffoldMessenger.of(context).showToast(
      SnackBar(
        content: Text('$name removed — save to confirm'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            setState(() {
              _deletedIds.remove(d.id);
              if (wasNew) _newIds.add(d.id);
              _local.insert(removedAt.clamp(0, _local.length), d);
              _normalizeIndexes();
              _selectedId = d.id;
            });
          },
        ),
      ),
    );
  }

  // ── Photo ─────────────────────────────────────────────────────────────────

  /// Picks and uploads a photo at once. The upload needs an id, which a new
  /// staff member already has (minted locally), so this works before the save.
  /// A photo picked and then discarded leaves an unreferenced file in Storage;
  /// harmless, and worth it for the instant preview.
  Future<void> _pickPhoto(Distributor d) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    setState(() {
      _photoPreviews[d.id] = bytes;
      _uploadingPhotoFor = d.id;
    });

    try {
      final ext = picked.name.split('.').last.toLowerCase();
      final isPng = ext == 'png';
      final ref = FirebaseStorage.instance
          .ref()
          .child('distributor_photos/${d.id}.${isPng ? 'png' : 'jpg'}');
      await StorageUpload.safePutData(
        ref,
        bytes,
        metadata: SettableMetadata(
          contentType: isPng ? 'image/png' : 'image/jpeg',
        ),
      );
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() => _uploadingPhotoFor = null);
      // Read the person back out of the list: they may have been edited while
      // the upload ran.
      final current = _local.firstWhere((x) => x.id == d.id,
          orElse: () => d.copyWith());
      _replace(current.copyWith(imageUrl: url));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingPhotoFor = null;
        _photoPreviews.remove(d.id);
      });
      ScaffoldMessenger.of(context).showToast(
        SnackBar(
          content: Text('Photo upload failed: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Save / discard / close ────────────────────────────────────────────────

  void _discard() {
    setState(() {
      _syncFromProvider();
      _deletedIds.clear();
      _newIds.clear();
      _photoPreviews.clear();
      _hasChanges = false;
      if (_selected == null) _selectedId = null;
    });
  }

  Future<void> _save() async {
    if (_isSaving || !_hasChanges) return;
    final unnamed = _local.where((d) => d.name.trim().isEmpty).toList();
    if (unnamed.isNotEmpty) {
      setState(() => _selectedId = unnamed.first.id);
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Every staff member needs a name'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref.read(scheduleRiverpod).saveDistributorChanges(
            finalState: [
              for (final d in _local) d.copyWith(name: d.name.trim()),
            ],
            deletedIds: Set.of(_deletedIds),
          );
      if (!mounted) return;
      setState(() {
        _deletedIds.clear();
        _newIds.clear();
        _hasChanges = false;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Staff saved'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showToast(
        SnackBar(
          content: Text('Failed to save staff: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Closes for real. [PopScope] reads `_allowPop` from the last build, so
  /// the pop has to wait for the frame that carries the flag.
  void _close() {
    if (_allowPop) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// Every way out — the ✕, Escape, a tap on the dim backdrop — lands here, so
  /// unsaved work is never dropped silently.
  void _handleClose() {
    if (!_hasChanges) {
      _close();
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.edit_note, size: 32),
        title: const Text('Unsaved changes'),
        content: const Text(
            'Close without saving? Your staff changes will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _close();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Discard & close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _save().then((_) {
                if (mounted && !_hasChanges) _close();
              });
            },
            child: const Text('Save & close'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(scheduleRiverpod);
    // Live updates flow in until the first local edit; after that the local
    // copy is the truth until it is saved or discarded.
    if (!_hasChanges) {
      _local = provider.distributors.map((d) => d.copyWith()).toList()
        ..sort((a, b) => a.index.compareTo(b.index));
    }
    final saved = {for (final d in provider.distributors) d.id: d};

    final media = MediaQuery.sizeOf(context);
    final narrow = media.width < _twoPaneBreakpoint;
    final inset = narrow ? 0.0 : 16.0;
    // [Dialog] already shifts itself clear of the on-screen keyboard, so a
    // full-height box has to give the keyboard its space back or it overflows.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    // Two panes: somebody is always open for editing, so the screen is useful
    // the moment it opens. One pane: the roster comes first and the editor is
    // a drill-down, so there is always a way back to the list.
    if (!narrow && _selected == null && _local.isNotEmpty) {
      _selectedId = _local.first.id;
    }
    final selected = _selected;
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: _allowPop || !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleClose();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
            insetPadding: EdgeInsets.all(inset),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(narrow ? 0 : 20),
            ),
            backgroundColor: scheme.surface,
            child: SizedBox(
              width: media.width - inset * 2,
              height: media.height - inset * 2 - keyboard,
              child: Column(
                children: [
                  _buildHeader(context, narrow),
                  Expanded(
                    child: narrow
                        ? (selected == null
                            ? _buildListPane(context, saved, narrow: true)
                            : _buildDetailPane(context, selected,
                                narrow: true))
                        : Row(
                            children: [
                              SizedBox(
                                width: _listPaneWidth,
                                child: _buildListPane(context, saved,
                                    narrow: false),
                              ),
                              VerticalDivider(
                                width: 1,
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.6),
                              ),
                              Expanded(
                                child: ColoredBox(
                                  color: scheme.surfaceContainerLow,
                                  child: AnimatedSwitcher(
                                    duration:
                                        const Duration(milliseconds: 180),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    child: selected == null
                                        ? _buildNoSelection(context)
                                        : _buildDetailPane(context, selected,
                                            narrow: false),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                  _buildSaveBar(context, saved),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool narrow) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.people_alt_rounded,
                size: 20, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Staff',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  '${_local.length} on the roster · $_activeCount active',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _hasChanges
                ? Container(
                    key: const ValueKey('unsaved'),
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: Colors.orange[800],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Unsaved',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange[900],
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('clean')),
          ),
          if (!narrow)
            FilledButton.icon(
              onPressed: _addStaff,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('Add staff'),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: _handleClose,
          ),
        ],
      ),
    );
  }

  Widget _buildListPane(
    BuildContext context,
    Map<String, Distributor> saved, {
    required bool narrow,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visible;
    final canReorder = _canReorder;

    return Column(
      children: [
        // Search
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search name, phone, ID…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
              filled: true,
              fillColor:
                  scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        // Status filters — all visible, nothing behind a menu.
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _filterChip(context, null, 'All', _local.length),
              for (final s in DistributorStatus.values)
                _filterChip(
                  context,
                  s,
                  s.displayName,
                  _local.where((d) => d.status == s).length,
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (!canReorder)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Clear the search or filter to drag-reorder',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? _buildEmptyList(context)
              : canReorder
                  ? ReorderableListView.builder(
                      scrollController: _listScroll,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: visible.length,
                      onReorderItem: _onReorder,
                      proxyDecorator: (child, _, animation) =>
                          _dragProxy(context, child, animation),
                      itemBuilder: (context, i) => _staffRow(
                        context,
                        visible[i],
                        saved,
                        listIndex: i,
                        draggable: true,
                        groupLabel: _groupLabelFor(i),
                      ),
                    )
                  : ListView.builder(
                      controller: _listScroll,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: visible.length,
                      itemBuilder: (context, i) => _staffRow(
                        context,
                        visible[i],
                        saved,
                        listIndex: i,
                        draggable: false,
                        groupLabel: null,
                      ),
                    ),
        ),
        // Add is always one click away, right under the list.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: SizedBox(
            width: double.infinity,
            child: narrow
                ? FilledButton.icon(
                    onPressed: _addStaff,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text('Add staff member'),
                  )
                : OutlinedButton.icon(
                    onPressed: _addStaff,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text('Add staff member'),
                  ),
          ),
        ),
      ],
    );
  }

  /// In the unfiltered roster, a label above the first active and the first
  /// non-active row explains the two blocks the list is kept in.
  String? _groupLabelFor(int i) {
    if (i == 0) {
      return _activeCount > 0 ? 'On the schedule' : 'Not on the schedule';
    }
    if (i == _activeCount) return 'Not on the schedule';
    return null;
  }

  Widget _buildEmptyList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search_rounded,
                size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              _local.isEmpty ? 'No staff yet' : 'Nobody matches that',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (_local.isNotEmpty &&
                (_query.isNotEmpty || _statusFilter != null))
              TextButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _query = '';
                    _statusFilter = null;
                  });
                },
                child: const Text('Show everyone'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(
    BuildContext context,
    DistributorStatus? status,
    String label,
    int count,
  ) {
    final isSelected = _statusFilter == status;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text('$label  $count', style: const TextStyle(fontSize: 11)),
        selected: isSelected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        avatar: status == null
            ? null
            : Icon(_statusIcon(status), size: 14, color: _statusColor(status)),
        onSelected: (_) => setState(
          () => _statusFilter = isSelected ? null : status,
        ),
      ),
    );
  }

  /// Height of a roster row, used to scroll a new person into view.
  static const double _rowExtent = 58;

  Widget _staffRow(
    BuildContext context,
    Distributor d,
    Map<String, Distributor> saved, {
    required int listIndex,
    required bool draggable,
    required String? groupLabel,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = d.id == _selectedId;
    final isNew = _newIds.contains(d.id);
    final edited = !isNew && _isEdited(d, saved);
    final name = d.name.trim().isEmpty ? 'New staff member' : d.name.trim();
    final subtitle = [
      if (d.phone1 != null && d.phone1!.isNotEmpty) d.phone1!,
      d.role.displayName,
    ].join(' · ');

    final row = Material(
      color: isSelected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: scheme.onSurface.withValues(alpha: 0.04),
        onTap: () => setState(() => _selectedId = d.id),
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              // Selection accent.
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 3,
                height: 28,
                margin: const EdgeInsets.only(left: 4, right: 6),
                decoration: BoxDecoration(
                  color: isSelected ? scheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Position in the schedule's distributor column.
              Container(
                width: 24,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? scheme.primary.withValues(alpha: 0.12)
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${d.index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color:
                        isSelected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _avatar(context, d, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              fontStyle: d.name.trim().isEmpty
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                              color: d.name.trim().isEmpty
                                  ? scheme.onSurfaceVariant
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                        if (isNew) _tag(context, 'NEW', scheme.primary),
                        if (edited)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Tooltip(
                              message: 'Edited, not saved yet',
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: Colors.orange[700],
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (d.status != DistributorStatus.active)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Tooltip(
                    message: d.status.displayName,
                    child: Icon(_statusIcon(d.status),
                        size: 15, color: _statusColor(d.status)),
                  ),
                ),
              if (draggable)
                ReorderableDragStartListener(
                  index: listIndex,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.drag_indicator,
                          size: 18, color: scheme.outline),
                    ),
                  ),
                )
              else
                const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );

    return Padding(
      key: ValueKey(d.id),
      padding: const EdgeInsets.only(bottom: 2),
      child: groupLabel == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding:
                      EdgeInsets.fromLTRB(12, listIndex == 0 ? 4 : 14, 12, 6),
                  child: Text(
                    groupLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                row,
              ],
            ),
    );
  }

  /// The row being dragged lifts off the list with a shadow.
  Widget _dragProxy(
      BuildContext context, Widget child, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeOut.transform(animation.value);
        return Material(
          elevation: 6 * t,
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          shadowColor: Colors.black.withValues(alpha: 0.35),
          child: child,
        );
      },
    );
  }

  Widget _tag(BuildContext context, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }

  Widget _buildNoSelection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('none'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.badge_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('Pick someone on the left to edit them',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _addStaff,
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: const Text('Add staff'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPane(BuildContext context, Distributor d,
      {required bool narrow}) {
    final index = _local.indexWhere((x) => x.id == d.id);
    final activeCount = _activeCount;
    final isActive = d.status == DistributorStatus.active;
    // Active staff reorder within the active block; everyone else within the
    // tail, because [_normalizeIndexes] keeps the two apart.
    final canMoveUp = isActive ? index > 0 : index > activeCount;
    final canMoveDown =
        isActive ? index < activeCount - 1 : index < _local.length - 1;

    return _StaffEditor(
      // Rebuilt from scratch when the selection changes so the text fields
      // always hold the selected person's values.
      key: ValueKey(d.id),
      distributor: d,
      isNew: _newIds.contains(d.id),
      narrow: narrow,
      canMoveUp: canMoveUp,
      canMoveDown: canMoveDown,
      photoPreview: _photoPreviews[d.id],
      uploadingPhoto: _uploadingPhotoFor == d.id,
      onChanged: (updated) => _replace(updated),
      onStatusChanged: (updated) => _replace(updated, renormalize: true),
      onPickPhoto: () => _pickPhoto(d),
      onMoveUp: () => _move(d, up: true),
      onMoveDown: () => _move(d, up: false),
      onDelete: () => _delete(d),
      onIdCard: () => showDigitalIdCard(context, d),
      onBack: narrow ? () => setState(() => _selectedId = null) : null,
    );
  }

  /// Slides in only while there is something to save, so a clean screen has
  /// no dead buttons along its bottom edge.
  Widget _buildSaveBar(BuildContext context, Map<String, Distributor> saved) {
    final scheme = Theme.of(context).colorScheme;
    final edited = _local
        .where((d) => !_newIds.contains(d.id) && _isEdited(d, saved))
        .length;
    final summary = <String>[
      if (edited > 0) '$edited edited',
      if (_newIds.isNotEmpty) '${_newIds.length} added',
      if (_deletedIds.isNotEmpty) '${_deletedIds.length} removed',
    ].join(' · ');

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !_hasChanges
          ? const SizedBox(width: double.infinity, height: 0)
          : Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.orange[800],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      summary.isEmpty
                          ? 'Unsaved changes'
                          : 'Unsaved changes · $summary',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _isSaving ? null : _discard,
                    child: const Text('Discard'),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Save (⌘S / Ctrl+S)',
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: Text(_isSaving ? 'Saving…' : 'Save changes'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _avatar(BuildContext context, Distributor d, {double radius = 17}) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _photoPreviews[d.id];
    ImageProvider? image;
    if (preview != null) {
      image = MemoryImage(preview);
    } else if (d.imageUrl != null && d.imageUrl!.isNotEmpty) {
      image = NetworkImage(d.imageUrl!);
    }
    final initial =
        d.name.trim().isEmpty ? '?' : d.name.trim()[0].toUpperCase();

    // A status ring rather than a dot: readable at a glance, and it doesn't
    // cover the photo.
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _statusColor(d.status), width: 2),
      ),
      child: CircleAvatar(
        radius: radius - 2,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        backgroundImage: image,
        child: image == null
            ? Text(
                initial,
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: radius * 0.8,
                ),
              )
            : null,
      ),
    );
  }
}

IconData _statusIcon(DistributorStatus status) {
  switch (status) {
    case DistributorStatus.active:
      return Icons.check_circle;
    case DistributorStatus.inactive:
      return Icons.pause_circle_filled;
    case DistributorStatus.suspended:
      return Icons.block;
    case DistributorStatus.onLeave:
      return Icons.flight_takeoff;
  }
}

Color _statusColor(DistributorStatus status) {
  switch (status) {
    case DistributorStatus.active:
      return Colors.green;
    case DistributorStatus.inactive:
      return Colors.grey;
    case DistributorStatus.suspended:
      return Colors.red;
    case DistributorStatus.onLeave:
      return Colors.orange;
  }
}

IconData _roleIcon(DistributorRole role) {
  switch (role) {
    case DistributorRole.distributor:
      return Icons.directions_walk;
    case DistributorRole.supervisor:
      return Icons.supervisor_account;
    case DistributorRole.teamLeader:
      return Icons.groups;
    case DistributorRole.driver:
      return Icons.local_shipping;
  }
}

/// The right-hand pane: every field of one staff member, edited in place.
///
/// Each keystroke is handed straight to the parent, so the list, the position
/// badges and the save bar all track what is being typed — there is nothing
/// to confirm inside this pane.
class _StaffEditor extends StatefulWidget {
  final Distributor distributor;
  final bool isNew;
  final bool narrow;
  final bool canMoveUp;
  final bool canMoveDown;
  final Uint8List? photoPreview;
  final bool uploadingPhoto;
  final ValueChanged<Distributor> onChanged;
  final ValueChanged<Distributor> onStatusChanged;
  final VoidCallback onPickPhoto;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDelete;
  final VoidCallback onIdCard;
  final VoidCallback? onBack;

  const _StaffEditor({
    super.key,
    required this.distributor,
    required this.isNew,
    required this.narrow,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.photoPreview,
    required this.uploadingPhoto,
    required this.onChanged,
    required this.onStatusChanged,
    required this.onPickPhoto,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onIdCard,
    required this.onBack,
  });

  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final TextEditingController _name;
  late final TextEditingController _phone1;
  late final TextEditingController _phone2;
  late final TextEditingController _fullName;
  late final TextEditingController _idNumber;
  late final TextEditingController _homeAddress;

  @override
  void initState() {
    super.initState();
    final d = widget.distributor;
    _name = TextEditingController(text: d.name);
    _phone1 = TextEditingController(text: d.phone1 ?? '');
    _phone2 = TextEditingController(text: d.phone2 ?? '');
    _fullName = TextEditingController(text: d.fullName ?? '');
    _idNumber = TextEditingController(text: d.idNumber ?? '');
    _homeAddress = TextEditingController(text: d.homeAddress ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone1.dispose();
    _phone2.dispose();
    _fullName.dispose();
    _idNumber.dispose();
    _homeAddress.dispose();
    super.dispose();
  }

  String? _trimmedOrNull(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  /// Pushes the whole form up on every edit. `clear*` flags matter: emptying
  /// a field has to actually remove it, which `copyWith`'s `??` cannot do.
  void _push() {
    widget.onChanged(
      widget.distributor.copyWith(
        name: _name.text,
        phone1: _trimmedOrNull(_phone1),
        phone2: _trimmedOrNull(_phone2),
        fullName: _trimmedOrNull(_fullName),
        idNumber: _trimmedOrNull(_idNumber),
        homeAddress: _trimmedOrNull(_homeAddress),
        clearPhone1: _phone1.text.trim().isEmpty,
        clearPhone2: _phone2.text.trim().isEmpty,
        clearFullName: _fullName.text.trim().isEmpty,
        clearIdNumber: _idNumber.text.trim().isEmpty,
        clearHomeAddress: _homeAddress.text.trim().isEmpty,
      ),
    );
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showToast(
      SnackBar(
        content: Text('$label copied'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.distributor;
    final narrow = widget.narrow;

    return ListView(
      key: ValueKey('editor-${d.id}'),
      padding: EdgeInsets.fromLTRB(
          narrow ? 16 : 28, narrow ? 12 : 24, narrow ? 16 : 28, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _editorMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _profileHeader(context, d),
                const SizedBox(height: 16),
                _card(
                  context,
                  icon: Icons.event_available_outlined,
                  title: 'On the schedule',
                  hint: 'Only active staff hold a schedule position; everyone '
                      'else drops to the end of the roster.',
                  children: [
                    _fieldLabel(context, 'Status'),
                    _picker<DistributorStatus>(
                      context,
                      values: DistributorStatus.values,
                      selected: d.status,
                      label: (s) => s.displayName,
                      icon: _statusIcon,
                      iconColor: _statusColor,
                      onPick: (s) =>
                          widget.onStatusChanged(d.copyWith(status: s)),
                    ),
                    const SizedBox(height: 14),
                    _fieldLabel(context, 'Role · shown on the ID card'),
                    _picker<DistributorRole>(
                      context,
                      values: DistributorRole.values,
                      selected: d.role,
                      label: (r) => r.displayName,
                      icon: _roleIcon,
                      onPick: (r) => widget.onChanged(d.copyWith(role: r)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _card(
                  context,
                  icon: Icons.call_outlined,
                  title: 'Contact',
                  children: [
                    _pair(
                      TextField(
                        controller: _phone1,
                        keyboardType: TextInputType.phone,
                        onChanged: (_) => _push(),
                        decoration: _dec(
                          context,
                          'Phone 1 (primary)',
                          Icons.phone_outlined,
                          suffix: _copyButton('Phone 1', _phone1),
                        ),
                      ),
                      TextField(
                        controller: _phone2,
                        keyboardType: TextInputType.phone,
                        onChanged: (_) => _push(),
                        decoration: _dec(
                          context,
                          'Phone 2 (optional)',
                          Icons.phone_android_outlined,
                          suffix: _copyButton('Phone 2', _phone2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _card(
                  context,
                  icon: Icons.verified_user_outlined,
                  title: 'Official details',
                  hint: 'Used on payslips and the ID card.',
                  children: [
                    _pair(
                      TextField(
                        controller: _fullName,
                        textCapitalization: TextCapitalization.words,
                        onChanged: (_) => _push(),
                        decoration: _dec(
                            context, 'Full legal name', Icons.badge_outlined),
                      ),
                      TextField(
                        controller: _idNumber,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        onChanged: (_) => _push(),
                        decoration:
                            _dec(context, 'ID number', Icons.perm_identity),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _homeAddress,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => _push(),
                      decoration:
                          _dec(context, 'Home address', Icons.home_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Destructive action last and on its own, where it can't be
                // hit by accident while editing.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.onDelete,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.person_remove_outlined, size: 18),
                    label: const Text('Remove from staff'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Pieces ────────────────────────────────────────────────────────────────

  Widget _profileHeader(BuildContext context, Distributor d) {
    final scheme = Theme.of(context).colorScheme;
    final narrow = widget.narrow;

    final actions = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _positionControl(context, d),
        OutlinedButton.icon(
          onPressed: widget.onIdCard,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
          ),
          icon: const Icon(Icons.badge_outlined, size: 16),
          label: const Text('ID card'),
        ),
      ],
    );

    final header = Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: 'Back to the list',
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
            ),
          _photoButton(context, d),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _name,
                  autofocus: widget.isNew,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => _push(),
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                  decoration: _dec(
                    context,
                    'Name on the schedule',
                    null,
                    hint: 'e.g. Barrie',
                    error: _name.text.trim().isEmpty
                        ? 'A name is required'
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(_statusIcon(d.status),
                        size: 14, color: _statusColor(d.status)),
                    const SizedBox(width: 5),
                    Text(
                      d.status.displayName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _statusColor(d.status),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        '  ·  ${d.role.displayName}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!narrow) ...[
                  const SizedBox(height: 10),
                  actions,
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (!narrow) return header;
    // On a phone the actions sit under the card, where there is room.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [header, const SizedBox(height: 10), actions],
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? hint,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 26),
              child: Text(
                hint,
                style:
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// One-of pickers: a segmented control on a wide pane, chips that wrap on
  /// a phone (a four-way segmented control doesn't fit there).
  Widget _picker<T>(
    BuildContext context, {
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required IconData Function(T) icon,
    Color Function(T)? iconColor,
    required ValueChanged<T> onPick,
  }) {
    if (widget.narrow) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            ChoiceChip(
              selected: v == selected,
              showCheckmark: false,
              avatar: Icon(icon(v), size: 16, color: iconColor?.call(v)),
              label: Text(label(v)),
              onSelected: (_) {
                if (v != selected) onPick(v);
              },
            ),
        ],
      );
    }
    return SegmentedButton<T>(
      segments: [
        for (final v in values)
          ButtonSegment<T>(
            value: v,
            icon: Icon(icon(v), size: 16, color: iconColor?.call(v)),
            label: Text(label(v)),
          ),
      ],
      selected: {selected},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      onSelectionChanged: (s) {
        if (s.isNotEmpty && s.first != selected) onPick(s.first);
      },
    );
  }

  InputDecoration _dec(
    BuildContext context,
    String label,
    IconData? icon, {
    String? hint,
    String? error,
    Widget? suffix,
  }) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
      prefixIcon: icon == null ? null : Icon(icon, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      focusedBorder: border(scheme.primary, 1.6),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 1.6),
    );
  }

  Widget? _copyButton(String label, TextEditingController c) {
    if (c.text.trim().isEmpty) return null;
    return IconButton(
      tooltip: 'Copy',
      icon: const Icon(Icons.copy_rounded, size: 16),
      onPressed: () => _copy(label, c.text.trim()),
    );
  }

  /// Two fields side by side on a wide pane, stacked on a narrow one.
  Widget _pair(Widget a, Widget b) {
    if (widget.narrow) {
      return Column(children: [a, const SizedBox(height: 12), b]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ],
    );
  }

  Widget _positionControl(BuildContext context, Distributor d) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Position ${d.index + 1}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Move up',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            onPressed: widget.canMoveUp ? widget.onMoveUp : null,
          ),
          IconButton(
            tooltip: 'Move down',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            onPressed: widget.canMoveDown ? widget.onMoveDown : null,
          ),
        ],
      ),
    );
  }

  Widget _photoButton(BuildContext context, Distributor d) {
    final scheme = Theme.of(context).colorScheme;
    ImageProvider? image;
    if (widget.photoPreview != null) {
      image = MemoryImage(widget.photoPreview!);
    } else if (d.imageUrl != null && d.imageUrl!.isNotEmpty) {
      image = NetworkImage(d.imageUrl!);
    }
    const radius = 40.0;

    return Tooltip(
      message: image == null ? 'Add a photo' : 'Change the photo',
      child: InkWell(
        borderRadius: BorderRadius.circular(radius + 4),
        onTap: widget.uploadingPhoto ? null : widget.onPickPhoto,
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: _statusColor(d.status), width: 2.5),
              ),
              child: CircleAvatar(
                radius: radius,
                backgroundColor: scheme.primary.withValues(alpha: 0.12),
                backgroundImage: image,
                child: widget.uploadingPhoto
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : (image == null
                        ? Icon(Icons.person, size: 38, color: scheme.primary)
                        : null),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary,
                border: Border.all(color: scheme.surface, width: 2),
              ),
              padding: const EdgeInsets.all(5),
              child:
                  Icon(Icons.camera_alt, size: 13, color: scheme.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
