import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../letterbox/models/letterbox_suburb.dart';
import '../../letterbox/pages/letterbox_curation_page.dart';
import '../../providers/auth_provider.dart';
import '../providers/shareable_map_provider.dart';
import 'map_overlay.dart';

/// Amber used everywhere an estimate rests on unverified letterbox data, so
/// the banner, the sidebar row, the alert and the info window read as one
/// signal.
const Color kUnverifiedLetterboxColor = Color(0xFFB45309);
const Color kUnverifiedLetterboxBackground = Color(0xFFFFF4E5);

String letterboxStatusLabel(LetterboxSuburbStatus status) {
  switch (status) {
    case LetterboxSuburbStatus.unseeded:
      return 'Not seeded';
    case LetterboxSuburbStatus.seeded:
      return 'Not reviewed';
    case LetterboxSuburbStatus.inProgress:
      return 'Review in progress';
    case LetterboxSuburbStatus.verified:
      return 'Verified';
  }
}

/// The map-level warning: which areas' letterbox estimates rest on suburbs
/// nobody has verified, and what an admin has to do about it.
///
/// [editorContext] is the editor's own context — the dialog's context sits on
/// the root navigator (see the nested body navigator in main.dart), so the
/// curation page is pushed from the editor's navigator instead.
Future<void> showUnverifiedLetterboxDialog(BuildContext editorContext) {
  return showDialog<void>(
    context: editorContext,
    builder: (dialogContext) => _UnverifiedLetterboxDialog(
      editorContext: editorContext,
    ),
  );
}

class _UnverifiedLetterboxDialog extends riverpod.ConsumerStatefulWidget {
  final BuildContext editorContext;
  const _UnverifiedLetterboxDialog({required this.editorContext});

  @override
  riverpod.ConsumerState<_UnverifiedLetterboxDialog> createState() =>
      _UnverifiedLetterboxDialogState();
}

class _UnverifiedLetterboxDialogState
    extends riverpod.ConsumerState<_UnverifiedLetterboxDialog> {
  bool _refreshing = false;

  Future<void> _refresh(ShareableMapProvider provider) async {
    setState(() => _refreshing = true);
    await provider.refreshLetterboxStatuses(force: true);
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(shareableMapRiverpod);
    final auth = ref.watch(authRiverpod);
    final isAdmin = auth.isAdmin;
    // Setting a number by hand is for signed-in users only — never a
    // shared-link viewer.
    final canSetCount = auth.isAuthenticated && !provider.capabilities.readOnly;
    final areas = provider.unverifiedLetterboxAreas;
    final unchecked = provider.uncheckedLetterboxAreaCount;

    // Distinct suburbs across every flagged area — the admin's to-do list.
    final suburbs = <String, LetterboxSuburb>{
      for (final a in areas)
        for (final s in a.suburbs) s.suburbId: s,
    }.values.toList()
      ..sort((a, b) => a.suburbName.compareTo(b.suburbName));

    return MapOverlay(
      child: AlertDialog(
        titlePadding: EdgeInsets.zero,
        title: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          decoration: const BoxDecoration(
            color: kUnverifiedLetterboxBackground,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: kUnverifiedLetterboxColor, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Letterbox estimates need admin attention',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: kUnverifiedLetterboxColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        content: SizedBox(
          width: 460,
          child: areas.isEmpty
              ? Text(
                  unchecked > 0
                      ? 'No flagged areas. $unchecked area'
                          '${unchecked == 1 ? ' was' : 's were'} counted before '
                          'suburb checks existed — recheck to be sure.'
                      : 'Every counted area on this map uses verified '
                          'letterbox data.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    Text(
                      '${areas.length} area${areas.length == 1 ? '' : 's'} '
                      'on this map ${areas.length == 1 ? 'is' : 'are'} counted '
                      'from suburbs whose letterboxes have not been verified. '
                      'Do not quote a client or judge a distributor on these '
                      'numbers until the suburbs below are verified.',
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                    const SizedBox(height: 14),
                    _sectionLabel('Suburbs to verify (${suburbs.length})'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in suburbs) _suburbChip(s),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _sectionLabel('Affected areas'),
                    const SizedBox(height: 4),
                    for (final a in areas)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.warning_amber_rounded,
                            color: kUnverifiedLetterboxColor),
                        title: Text(a.displayName,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text(
                          'Est. ${a.polygon.letterBoxEstimate} letter boxes · '
                          '${a.suburbs.map((s) => s.suburbName).join(', ')}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (canSetCount)
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: kUnverifiedLetterboxColor,
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () =>
                                    _setCount(provider, a, auth.userEmail),
                                icon: const Icon(Icons.edit_note, size: 18),
                                label: const Text('Set count'),
                              ),
                            const Icon(Icons.center_focus_strong, size: 18),
                          ],
                        ),
                        onTap: () {
                          provider.focusOnPolygon(a.layerId, a.polygonIndex);
                          Navigator.of(context).pop();
                        },
                      ),
                    if (unchecked > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Plus $unchecked area${unchecked == 1 ? '' : 's'} '
                        'counted before suburb checks existed.',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF5F6368)),
                      ),
                    ],
                    if (!isAdmin) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Ask an admin to verify these suburbs in the '
                        'Letterbox Index.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: kUnverifiedLetterboxColor,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        actions: [
          if (unchecked > 0 && !provider.capabilities.readOnly)
            TextButton(
              onPressed: () {
                provider.recheckUncheckedLetterboxAreas();
                Navigator.of(context).pop();
              },
              child: Text('Recheck $unchecked'),
            ),
          TextButton.icon(
            onPressed: _refreshing ? null : () => _refresh(provider),
            icon: _refreshing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh status'),
          ),
          if (isAdmin && areas.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: kUnverifiedLetterboxColor),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(widget.editorContext).push(MaterialPageRoute(
                  builder: (_) => const LetterboxCurationPage(),
                ));
              },
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('Open Letterbox Index'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Ask for the checked number, then lock it on the area. The area drops
  /// off this list as soon as it is saved — it is resolved.
  Future<void> _setCount(
    ShareableMapProvider provider,
    UnverifiedLetterboxArea area,
    String setBy,
  ) async {
    final controller = TextEditingController(
      text: area.polygon.letterBoxEstimate > 0
          ? area.polygon.letterBoxEstimate.toString()
          : '',
    );
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) {
        void submit() {
          final v = int.tryParse(controller.text.trim());
          if (v != null && v >= 0) Navigator.of(ctx).pop(v);
        }

        return AlertDialog(
          title: Text('Set letterboxes for ${area.displayName}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Counted ${area.polygon.letterBoxEstimate} from unverified '
                  'data (${area.suburbs.map((s) => s.suburbName).join(', ')}).',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Letter boxes',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 10),
                const Text(
                  'This number is locked: later edits to the area will not '
                  'recount it. Unlock it from the area\'s info window.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: submit,
              child: const Text('Save & resolve'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (value == null || !mounted) return;
    provider.setManualLetterboxEstimate(
      area.layerId,
      area.polygonIndex,
      value,
      setBy: setBy,
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
          color: Color(0xFF5F6368),
        ),
      );

  Widget _suburbChip(LetterboxSuburb s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: kUnverifiedLetterboxBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: kUnverifiedLetterboxColor.withValues(alpha: 0.35)),
        ),
        child: Text(
          '${s.suburbName} · ${letterboxStatusLabel(s.status)}',
          style:
              const TextStyle(fontSize: 12, color: kUnverifiedLetterboxColor),
        ),
      );
}

/// The always-visible banner on the map for editors.
class UnverifiedLetterboxBanner extends StatelessWidget {
  /// Areas counted from unverified suburbs — the loud case.
  final int count;

  /// Areas counted before suburbs were recorded — shown quietly, only when
  /// nothing is flagged, so old maps still offer a way to recheck.
  final int unchecked;

  const UnverifiedLetterboxBanner({
    super.key,
    required this.count,
    this.unchecked = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return Material(
        color: Colors.white.withValues(alpha: 0.95),
        elevation: 2,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showUnverifiedLetterboxDialog(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(
              '$unchecked area${unchecked == 1 ? '' : 's'} not yet checked '
              'for unverified letterbox data · Check',
              style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
            ),
          ),
        ),
      );
    }
    return Material(
      color: kUnverifiedLetterboxBackground,
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showUnverifiedLetterboxDialog(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kUnverifiedLetterboxColor, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: kUnverifiedLetterboxColor, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '$count area${count == 1 ? '' : 's'} counted from '
                  'unverified letterbox data — needs admin review',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kUnverifiedLetterboxColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'REVIEW',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: kUnverifiedLetterboxColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
