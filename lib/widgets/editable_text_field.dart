import 'package:flutter/material.dart';

class EditableTextField extends StatefulWidget {
  final String initialValue;
  final Function(String) onChanged;
  final String? hintText;
  final bool multiline;

  const EditableTextField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.hintText,
    this.multiline = false,
  });

  @override
  State<EditableTextField> createState() => _EditableTextFieldState();
}

class _EditableTextFieldState extends State<EditableTextField> {
  late TextEditingController _controller;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
    });
  }

  void _finishEditing() {
    setState(() {
      _isEditing = false;
    });
    if (_controller.text != widget.initialValue) {
      widget.onChanged(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) {
            _finishEditing();
          }
        },
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: widget.multiline ? null : 1,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white,
          ), // Smaller font size
          decoration: InputDecoration.collapsed(hintText: widget.hintText),
          onSubmitted: (_) => _finishEditing(),
          onEditingComplete: _finishEditing,
        ),
      );
    }

    return GestureDetector(
      onTap: _startEditing,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          widget.initialValue.isEmpty
              ? (widget.hintText ?? '')
              : widget.initialValue,
          style: TextStyle(
            fontSize: 14,
            color: widget.initialValue.isEmpty ? Colors.white70 : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
