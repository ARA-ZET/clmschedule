import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class EditableTableCell extends StatefulWidget {
  final String value;
  final Function(String) onSave;
  final String? Function(String?)? validator;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int maxLines;
  final double? width;

  const EditableTableCell({
    super.key,
    required this.value,
    required this.onSave,
    this.validator,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.maxLines = 1,
    this.width,
  });

  @override
  State<EditableTableCell> createState() => _EditableTableCellState();
}

class _EditableTableCellState extends State<EditableTableCell> {
  bool _isEditing = false;
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late String _originalValue;

  @override
  void initState() {
    super.initState();
    _originalValue = widget.value;
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    // Capture the original value at the start of editing
    _originalValue = widget.value;
    _controller.text = widget.value;

    setState(() {
      _isEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _saveAndExit() {
    final currentValue = _controller.text;

    // Validate the input
    if (widget.validator != null) {
      final error = widget.validator!(currentValue);
      if (error != null) {
        // Show error and don't save
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    // Only call onSave if the value actually changed
    if (currentValue != _originalValue) {
      widget.onSave(currentValue);
      print(
          'EditableTableCell: Value changed from "$_originalValue" to "$currentValue"');
    } else {
      print('EditableTableCell: No change detected, skipping save');
    }

    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return SizedBox(
        width: widget.width,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          maxLines: widget.maxLines,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _saveAndExit(),
          onTapOutside: (_) => _saveAndExit(),
        ),
      );
    }

    return SizedBox(
      width: widget.width,
      child: InkWell(
        onTap: _startEditing,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            widget.value.isEmpty ? 'Click to edit' : widget.value,
            style: TextStyle(
              fontSize: 12,
              color: widget.value.isEmpty ? Colors.grey : null,
              fontStyle: widget.value.isEmpty ? FontStyle.italic : null,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: widget.maxLines,
          ),
        ),
      ),
    );
  }
}

class EditableDateCell extends StatelessWidget {
  final DateTime value;
  final Function(DateTime) onSave;
  final double? width;

  const EditableDateCell({
    super.key,
    required this.value,
    required this.onSave,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () async {
          final date = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2025),
            lastDate: DateTime(2030),
          );
          if (date != null && date != value) {
            // Only call onSave if the date actually changed
            print(
                'EditableDateCell: Date changed from "${value.toIso8601String()}" to "${date.toIso8601String()}"');
            onSave(date);
          } else if (date != null) {
            print('EditableDateCell: No change detected, skipping save');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('dd MMM').format(value),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.calendar_today, size: 12, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class LinkCell extends StatefulWidget {
  final String value;
  final Function(String) onSave;
  final String? Function(String?)? validator;
  final int maxLines;
  final double? width;

  const LinkCell({
    super.key,
    required this.value,
    required this.onSave,
    this.validator,
    this.maxLines = 1,
    this.width,
  });

  @override
  State<LinkCell> createState() => _LinkCellState();
}

class _LinkCellState extends State<LinkCell> {
  bool _isEditing = false;
  bool _isHovering = false;
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late String _originalValue;

  @override
  void initState() {
    super.initState();
    _originalValue = widget.value;
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _isValidUrl(String url) {
    if (url.isEmpty) return false;
    try {
      // Check if it looks like a URL (contains a domain)
      if (url.contains('.') && !url.contains(' ')) {
        final formattedUrl = _formatUrlForDisplay(url);
        final uri = Uri.parse(formattedUrl);
        return uri.hasScheme &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  String _formatUrlForDisplay(String url) {
    if (url.isEmpty) return url;

    // Add https:// if no scheme is present
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'https://$url';
    }
    return url;
  }

  Future<void> _launchUrl() async {
    final formattedUrl = _formatUrlForDisplay(widget.value);
    if (_isValidUrl(formattedUrl)) {
      final uri = Uri.parse(formattedUrl);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open link: $e')),
          );
        }
      }
    }
  }

  void _startEditing() {
    // Capture the original value at the start of editing
    _originalValue = widget.value;
    _controller.text = widget.value;

    setState(() {
      _isEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _saveAndExit() {
    final currentValue = _controller.text;

    // Validate the input
    if (widget.validator != null) {
      final error = widget.validator!(currentValue);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    // Only call onSave if the value actually changed
    if (currentValue != _originalValue) {
      widget.onSave(currentValue);
      print(
          'LinkCell: Value changed from "$_originalValue" to "$currentValue"');
    } else {
      print('LinkCell: No change detected, skipping save');
    }

    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return SizedBox(
        width: widget.width,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: TextInputType.url,
          maxLines: widget.maxLines,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            border: OutlineInputBorder(),
            hintText: 'Enter URL (e.g., google.com)',
          ),
          onSubmitted: (_) => _saveAndExit(),
          onTapOutside: (_) => _saveAndExit(),
        ),
      );
    }

    final formattedUrl = _formatUrlForDisplay(widget.value);
    final isValidLink = _isValidUrl(formattedUrl);

    return SizedBox(
      width: widget.width,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: Tooltip(
          message: isValidLink
              ? 'Click to open: $formattedUrl'
              : widget.value.isEmpty
                  ? 'Click to add link'
                  : 'Click to edit link',
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            onTap: isValidLink ? _launchUrl : _startEditing,
            onSecondaryTap: _startEditing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: !isValidLink && _isHovering
                    ? Border.all(color: Colors.grey[400]!, width: 1)
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Text(
                      widget.value.isEmpty ? 'Click to add link' : widget.value,
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.value.isEmpty
                            ? Colors.grey[600]
                            : isValidLink
                                ? (_isHovering
                                    ? Colors.blue.shade700
                                    : Colors.blue)
                                : (_isHovering
                                    ? Colors.grey[700]
                                    : Colors.black),
                        fontStyle:
                            widget.value.isEmpty ? FontStyle.italic : null,
                        decoration: isValidLink && _isHovering
                            ? TextDecoration.underline
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: widget.maxLines,
                    ),
                  ),
                  if (isValidLink) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.open_in_new,
                      size: 12,
                      color: _isHovering ? Colors.blue.shade700 : Colors.blue,
                    ),
                  ] else if (!widget.value.isEmpty) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.edit,
                      size: 12,
                      color: _isHovering ? Colors.grey[700] : Colors.grey[500],
                    ),
                  ] else if (_isHovering) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.add_link,
                      size: 12,
                      color: Colors.grey[600],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
