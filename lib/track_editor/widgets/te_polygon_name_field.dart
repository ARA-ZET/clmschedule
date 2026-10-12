// track_editor/widgets/te_polygon_name_field.dart
//
// The name field of the "New Polygon" dialog.
//
// The name used to be a plain dropdown of the areas already allocated to the
// distributor, which left no way to name a polygon drawn over ground the
// schedule doesn't know about yet. The field is now free text, with those
// allocated names offered beside it: tap one to fill it in, or type your own.
import 'package:flutter/material.dart';

class TEPolygonNameField extends StatelessWidget {
  const TEPolygonNameField({
    super.key,
    required this.controller,
    required this.suggestions,
    required this.onChanged,
  });

  final TextEditingController controller;

  /// Area names allocated to this distributor on this day, or every work-area
  /// name when the tab isn't tied to a distributor. May be empty.
  final List<String> suggestions;

  /// Lets the dialog clear its validation message as soon as a name appears.
  final VoidCallback onChanged;

  /// Past this many, the names go behind a menu: the fall-back list is every
  /// work area on the books, which would bury the rest of the dialog.
  static const int _maxChips = 8;

  void _use(String name) {
    controller.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    // Listening to the controller keeps the chip highlight and the clear
    // button in step with typing without rebuilding the whole dialog.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final current = value.text.trim();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Polygon Name',
                hintText: suggestions.isEmpty
                    ? 'Enter polygon name'
                    : 'Type a name, or pick a suggestion',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: current.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Clear name',
                        onPressed: () => _use(''),
                      ),
              ),
              onChanged: (_) => onChanged(),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Suggested names',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (suggestions.length <= _maxChips)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in suggestions)
                      ChoiceChip(
                        label: Text(name),
                        selected: current == name,
                        onSelected: (selected) => _use(selected ? name : ''),
                      ),
                  ],
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Pick an existing work-area name',
                  constraints:
                      const BoxConstraints(maxHeight: 320, minWidth: 240),
                  itemBuilder: (_) => [
                    for (final name in suggestions)
                      PopupMenuItem<String>(
                        value: name,
                        child: Text(name,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onSelected: _use,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.playlist_add_check,
                            size: 16, color: Colors.grey.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Pick from ${suggestions.length} work areas',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey.shade700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down,
                            size: 20, color: Colors.grey.shade700),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}
