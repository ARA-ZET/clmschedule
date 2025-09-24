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

  @override
  void initState() {
    super.initState();
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
    if (widget.validator != null) {
      final error = widget.validator!(_controller.text);
      if (error != null) {
        // Show error and don't save
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    widget.onSave(_controller.text);
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
          if (date != null) {
            onSave(date);
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

  @override
  void initState() {
    super.initState();
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
      final uri = Uri.parse(url);
      return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
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
    if (widget.validator != null) {
      final error = widget.validator!(_controller.text);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    widget.onSave(_controller.text);
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
              : 'Right-click to edit',
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            onTap: isValidLink ? _launchUrl : null,
            onSecondaryTap: _startEditing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Text(
                      widget.value.isEmpty
                          ? 'Right-click to add link'
                          : widget.value,
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.value.isEmpty
                            ? Colors.grey
                            : isValidLink
                                ? (_isHovering
                                    ? Colors.blue.shade700
                                    : Colors.blue)
                                : Colors.black,
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
